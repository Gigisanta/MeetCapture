// PendingContract.swift
// Producer v3 retains the v2 base fields for downstream consumers and adds
// frozen evidence. Published atomically as <meetingId>.pending.

import CryptoKit
import Foundation

struct PendingContract: Equatable, Sendable {
    var session: MeetingSession
    var endedAt: Date
    var transcriptPath: String
    var transcriptText: String
    /// nil when the app keeps the audio for itself (a transcript with gaps).
    var audioPath: String?
    var engine: ASREngine
    var model: String
    var language: String
    var segments: [Segment]
    var quality: TranscriptionQuality? = nil

    var speakerCount: Int { TranscriptFormatter.speakerCount(segments) }

    /// Labels in order of first appearance, so the summary names "Yo" and
    /// "Participante N" instead of inventing attendees.
    var speakers: [String] { Self.speakers(of: segments) }

    static func speakers(of segments: [Segment]) -> [String] {
        var seen = Set<String>()
        return segments.compactMap(\.speaker).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    enum ContractError: LocalizedError {
        case invalidDuration

        var errorDescription: String? {
            switch self {
            case .invalidDuration:
                return "La duración de la reunión es inválida"
            }
        }
    }

    func encode(audioExists: Bool) throws -> Data {
        let duration = endedAt.timeIntervalSince(session.startedAt)
        guard duration.isFinite, duration >= 0 else { throw ContractError.invalidDuration }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Payload(value: self, audioExists: audioExists, duration: duration))
    }

    private struct Payload: Encodable {
        var value: PendingContract
        var audioExists: Bool
        var duration: TimeInterval

        enum CodingKeys: String, CodingKey {
            case version, meetingId, title, startedAt, endedAt, durationSec
            case transcriptPath, audioPath, engine, model, language, segments
            case speakerCount, speakers, checksum, calendarEvent, calendarMatch
            case platform, platformEvidence, timeZone, speakerMap, quality, supersedesMeetingId
        }

        enum SegmentKeys: String, CodingKey { case start, end, text, speaker }

        func encode(to encoder: Encoder) throws {
            var root = encoder.container(keyedBy: CodingKeys.self)
            let context = value.session.context
            let speakers = value.speakers
            try root.encode(3, forKey: .version)
            try root.encode(value.session.id, forKey: .meetingId)
            try root.encode(value.session.displayTitle, forKey: .title)
            try root.encode(ISO8601.string(from: value.session.startedAt), forKey: .startedAt)
            try root.encode(ISO8601.string(from: value.endedAt), forKey: .endedAt)
            try root.encode(duration, forKey: .durationSec)
            try root.encode(value.transcriptPath, forKey: .transcriptPath)
            try root.encode(audioExists ? value.audioPath : nil, forKey: .audioPath)
            try root.encode(value.engine.rawValue, forKey: .engine)
            try root.encode(value.model, forKey: .model)
            try root.encode(value.language, forKey: .language)
            var turns = root.nestedUnkeyedContainer(forKey: .segments)
            for segment in value.segments {
                var turn = turns.nestedContainer(keyedBy: SegmentKeys.self)
                try turn.encode(segment.start, forKey: .start)
                try turn.encode(segment.end, forKey: .end)
                try turn.encode(segment.text, forKey: .text)
                if let speaker = segment.speaker, !speaker.isEmpty {
                    try turn.encode(speaker, forKey: .speaker)
                }
            }
            try root.encode(value.speakerCount, forKey: .speakerCount)
            try root.encode(speakers, forKey: .speakers)
            try root.encode(PendingContract.sha256Hex(value.transcriptText), forKey: .checksum)
            try root.encode(context.calendarEvent, forKey: .calendarEvent)
            try root.encode(context.calendarMatch, forKey: .calendarMatch)
            try root.encode(context.platform, forKey: .platform)
            try root.encode(context.platformEvidence, forKey: .platformEvidence)
            try root.encode(context.timeZone, forKey: .timeZone)
            try root.encode(context.speakerMap(for: speakers, remoteSpeakerCount: value.quality?.remoteSpeakerCount),
                            forKey: .speakerMap)
            try root.encode(value.quality, forKey: .quality)
            try root.encodeIfPresent(value.session.supersedesMeetingId, forKey: .supersedesMeetingId)
        }
    }

    /// Atomic write; throws on failure (the caller must not delete audio then).
    func write(to pendingPath: String) throws {
        let fm = FileManager.default
        let pendingURL = URL(fileURLWithPath: pendingPath)
        try AppPaths.ensurePrivateDirectory(pendingURL.deletingLastPathComponent().path)
        let data = try encode(audioExists: audioPath.map { fm.fileExists(atPath: $0) } ?? false)
        let tmpURL = pendingURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmpURL) }
        try data.write(to: tmpURL, options: .atomic)
        if fm.fileExists(atPath: pendingPath) {
            // Replacing in place preserves the old handoff if this operation
            // fails, which makes a retry safe after an interrupted write.
            try fm.replaceItemAt(pendingURL, withItemAt: tmpURL)
        } else {
            try fm.moveItem(at: tmpURL, to: pendingURL)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pendingPath)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum ProcessedMarker {
    static let schema = "meetcapture.processed.v1"

    enum MarkerError: LocalizedError {
        case pathIsDirectory(String)

        var errorDescription: String? {
            switch self {
            case .pathIsDirectory(let path):
                return "El marker no puede escribirse porque la ruta es un directorio: \(path)"
            }
        }
    }

    static func path(forTranscript transcriptPath: String) -> String {
        transcriptPath.hasSuffix(".txt")
            ? String(transcriptPath.dropLast(4)) + ".processed.json"
            : transcriptPath + ".processed.json"
    }

    /// Idempotent: never overwrites an existing marker.
    static func write(transcriptPath: String, title: String, now: Date = Date()) throws {
        let markerPath = path(forTranscript: transcriptPath)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: markerPath, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw MarkerError.pathIsDirectory(markerPath) }
            return
        }
        let marker: [String: Any] = [
            "schema": schema,
            "processed_at": ISO8601.string(from: now),
            "transcript_path": transcriptPath,
            "meeting_title": title,
            "retention": "handoff_complete",
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: markerPath)
    }
}

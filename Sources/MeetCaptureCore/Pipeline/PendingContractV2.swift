// PendingContractV2.swift
// The handoff file the summary dispatcher (tools/summary) consumes:
// <meetingsDir>/meet-<epoch>-<uuid>.pending. Byte-stable: sorted keys, pretty
// printed, written to a temp file and renamed into place.

import CryptoKit
import Foundation

struct PendingContractV2: Equatable, Sendable {
    var session: MeetingSession
    var endedAt: Date
    var transcriptPath: String
    var transcriptText: String
    var audioPath: String
    var engine: ASREngine
    var model: String
    var language: String
    var segments: [Segment]

    var speakerCount: Int { TranscriptFormatter.speakerCount(segments) }

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
        var segmentDicts: [[String: Any]] = []
        segmentDicts.reserveCapacity(segments.count)
        for s in segments {
            var d: [String: Any] = ["start": s.start, "end": s.end, "text": s.text]
            if let speaker = s.speaker, !speaker.isEmpty { d["speaker"] = speaker }
            segmentDicts.append(d)
        }
        let contract: [String: Any] = [
            "version": 2,
            "meetingId": session.id,
            "title": session.displayTitle,
            "startedAt": ISO8601.string(from: session.startedAt),
            "endedAt": ISO8601.string(from: endedAt),
            "durationSec": duration,
            "transcriptPath": transcriptPath,
            "audioPath": audioExists ? audioPath : NSNull(),
            "engine": engine.rawValue,
            "model": model,
            "language": language,
            "segments": segmentDicts,
            "speakerCount": speakerCount,
            "checksum": Self.sha256Hex(transcriptText),
        ]
        return try JSONSerialization.data(withJSONObject: contract, options: [.prettyPrinted, .sortedKeys])
    }

    /// Atomic write; throws on failure (the caller must not delete audio then).
    func write(to pendingPath: String) throws {
        let fm = FileManager.default
        let pendingURL = URL(fileURLWithPath: pendingPath)
        try AppPaths.ensurePrivateDirectory(pendingURL.deletingLastPathComponent().path)
        let data = try encode(audioExists: fm.fileExists(atPath: audioPath))
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

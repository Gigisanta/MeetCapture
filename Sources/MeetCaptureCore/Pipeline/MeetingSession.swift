// MeetingSession.swift
// Identity and frozen evidence of a capture or derived import. Capture retries
// keep their id; an intentional derived job explicitly names the original.

import Foundation

struct MeetingSession: Codable, Equatable, Sendable {
    var startedAt: Date
    var title: String?
    var context: MeetingContext
    var supersedesMeetingId: String?
    /// End-only clock evidence: `startedAt` is provisional until measured audio
    /// duration reconstructs it. Copied with derived imports, then cleared.
    var sourceAudioEndedAt: Date?
    /// Only a measured timeline or restored history accredits the start.
    /// Older metadata and a capture's pre-driver timestamp remain unknown.
    var startedAtIsAuthoritative: Bool?
    /// Stable for capture retries; unique for a new capture or derived import.
    let id: String

    init(startedAt: Date, title: String? = nil, context: MeetingContext = .unmatched(),
         supersedesMeetingId: String? = nil, sourceAudioEndedAt: Date? = nil,
         startedAtIsAuthoritative: Bool? = nil) {
        self.startedAt = startedAt
        self.title = title
        self.context = context
        self.supersedesMeetingId = supersedesMeetingId
        self.sourceAudioEndedAt = sourceAudioEndedAt
        self.startedAtIsAuthoritative = startedAtIsAuthoritative
        let epoch = Int64(startedAt.timeIntervalSince1970)
        self.id = "meet-\(epoch)-\(UUID().uuidString.lowercased())"
    }

    /// Redoing a capture keeps the id it was recorded under, so the result
    /// replaces its transcript, history row and handoff.
    init(id: String, startedAt: Date, title: String?, context: MeetingContext = .unmatched(),
         supersedesMeetingId: String? = nil, sourceAudioEndedAt: Date? = nil,
         startedAtIsAuthoritative: Bool? = nil) {
        self.startedAt = startedAt
        self.title = title
        self.context = context
        self.supersedesMeetingId = supersedesMeetingId
        self.sourceAudioEndedAt = sourceAudioEndedAt
        self.startedAtIsAuthoritative = startedAtIsAuthoritative
        self.id = id
    }

    var displayTitle: String {
        if let title = Self.meaningfulTitle(title) { return title }
        if context.calendarMatch == .matched,
           let title = Self.meaningfulTitle(context.calendarEvent?.title) { return title }
        return "\(context.platform.displayName) · \(ISO8601.string(from: startedAt))"
    }

    static let untitled = "Untitled Meeting"

    func pendingPath(in meetingsDir: String) -> String { "\(meetingsDir)/\(id).pending" }

    private static func meaningfulTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.caseInsensitiveCompare(untitled) != .orderedSame else { return nil }
        return title
    }

    static func metadataPath(forAudio audioPath: String) -> String { audioPath + ".meeting.json" }

    private struct Metadata: Codable {
        var schema: String
        var session: MeetingSession
    }

    private static let metadataSchema = "meetcapture.meeting.v1"

    enum MetadataError: LocalizedError {
        case unsupportedSchema

        var errorDescription: String? { "Los metadatos de la reunión no son compatibles" }
    }

    /// Kept beside the audio so a crash, import or retry cannot bind it to a
    /// different calendar event or the machine's later time zone.
    func write(forAudio audioPath: String) throws {
        let url = URL(fileURLWithPath: Self.metadataPath(forAudio: audioPath))
        try AppPaths.ensurePrivateDirectory(url.deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Internal dates retain their full precision; wire dates are ISO 8601.
        try encoder.encode(Metadata(schema: Self.metadataSchema, session: self)).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(forAudio audioPath: String) throws -> MeetingSession? {
        let path = metadataPath(forAudio: audioPath)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard metadata.schema == metadataSchema else { throw MetadataError.unsupportedSchema }
        return metadata.session
    }
}

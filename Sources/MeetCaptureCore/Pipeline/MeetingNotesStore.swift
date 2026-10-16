// Private notes typed during a recording. The summary dispatcher reads the
// sidecar after the app publishes the matching v2 handoff.

import Foundation

enum MeetingNotesStore {
    static let maxBytes = 64 * 1024

    static func path(meetingId: String, meetingsDir: String) -> String {
        meetingsDir + "/" + meetingId + ".notes.md"
    }

    static func save(_ text: String, meetingId: String, meetingsDir: String) throws {
        guard text.utf8.count <= maxBytes else { throw NotesError.tooLong }
        try AppPaths.ensurePrivateDirectory(meetingsDir)
        let path = path(meetingId: meetingId, meetingsDir: meetingsDir)
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    enum NotesError: LocalizedError {
        case tooLong
        var errorDescription: String? { "Las notas alcanzaron el límite de 64 KiB." }
    }
}

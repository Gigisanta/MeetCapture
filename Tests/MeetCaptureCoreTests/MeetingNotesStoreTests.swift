import Foundation
import XCTest
@testable import MeetCaptureCore

final class MeetingNotesStoreTests: XCTestCase {
    func testNotesArePrivateAndReplaceAtomically() throws {
        let dir = TestSupport.makeTempDir(self, "notes") + "/meetings"
        let id = "meet-fixture"
        try MeetingNotesStore.save("Primer apunte", meetingId: id, meetingsDir: dir)
        try MeetingNotesStore.save("Apunte corregido", meetingId: id, meetingsDir: dir)
        let path = MeetingNotesStore.path(meetingId: id, meetingsDir: dir)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "Apunte corregido")
        let perms = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(perms & 0o777, 0o600)
    }

    func testOversizedNotesDoNotOverwritePreviousVersion() throws {
        let dir = TestSupport.makeTempDir(self, "notes-size")
        let id = "meet-fixture"
        try MeetingNotesStore.save("Conservar", meetingId: id, meetingsDir: dir)
        XCTAssertThrowsError(try MeetingNotesStore.save(
            String(repeating: "x", count: MeetingNotesStore.maxBytes + 1),
            meetingId: id, meetingsDir: dir))
        let path = MeetingNotesStore.path(meetingId: id, meetingsDir: dir)
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "Conservar")
    }
}

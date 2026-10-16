import XCTest
@testable import MeetCaptureCore

final class PendingContractV2Tests: XCTestCase {
    private let session = MeetingSession(startedAt: TestSupport.fixedDate, title: "Reunión de prueba")

    private func contract(segments: [Segment], audioPath: String = "/nonexistent/recording.pcm") -> PendingContractV2 {
        PendingContractV2(session: session, endedAt: TestSupport.fixedDate.addingTimeInterval(90.5),
                          transcriptPath: "/tmp/x.txt", transcriptText: TranscriptFormatter.text(for: segments),
                          audioPath: audioPath, engine: .whisper, model: "medium-q5_0", language: "es",
                          segments: segments)
    }

    /// Golden shape: exactly the 14 keys the real `.done` files in ~/meetings carry, in sorted order.
    func testEncodesExactlyTheV2KeysSorted() throws {
        let data = try contract(segments: [Segment(start: 0, end: 1.5, text: "hola")]).encode(audioExists: false)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let expected = ["audioPath", "checksum", "durationSec", "endedAt", "engine", "language", "meetingId",
                        "model", "segments", "speakerCount", "startedAt", "title", "transcriptPath", "version"]
        XCTAssertEqual(root.keys.sorted(), expected)
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual(root["meetingId"] as? String, session.id)
        XCTAssertTrue((root["meetingId"] as? String)?.hasPrefix("meet-1788271709-") == true)
        XCTAssertEqual(root["startedAt"] as? String, "2026-09-01T14:08:29Z")
        XCTAssertEqual(root["durationSec"] as? Double, 90.5)
        XCTAssertTrue(root["audioPath"] is NSNull, "audioPath must be JSON null when the file is gone")
        XCTAssertEqual(root["speakerCount"] as? Int, 0)
        // Sorted keys + pretty printing is what the dispatcher and diffs rely on.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\n  \"audioPath\""))
        let segKeys = try XCTUnwrap((root["segments"] as? [[String: Any]])?.first?.keys.sorted())
        XCTAssertEqual(segKeys, ["end", "start", "text"], "speaker key is omitted when nil")
    }

    func testChecksumIsSHA256OfTranscriptText() throws {
        let segments = [Segment(start: 0, end: 1, text: "uno", speaker: "A"), Segment(start: 1, end: 2, text: "dos", speaker: "B")]
        let c = contract(segments: segments)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: c.encode(audioExists: true)) as? [String: Any])
        XCTAssertEqual(root["checksum"] as? String, PendingContractV2.sha256Hex("[A]: uno\n[B]: dos"))
        XCTAssertEqual(PendingContractV2.sha256Hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(root["speakerCount"] as? Int, 2)
        XCTAssertEqual((root["segments"] as? [[String: Any]])?.first?["speaker"] as? String, "A")
    }

    func testWriteIsAtomicAndLeavesNoTempFiles() throws {
        let dir = TestSupport.makeTempDir(self, "pending")
        let audio = dir + "/recording.pcm"
        TestSupport.write("x", to: audio)
        let path = session.pendingPath(in: dir + "/meetings")
        try contract(segments: [Segment(start: 0, end: 1, text: "hola")], audioPath: audio).write(to: path)
        XCTAssertEqual(path, dir + "/meetings/\(session.id).pending")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir + "/meetings")
        XCTAssertEqual(names, ["\(session.id).pending"])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(root["audioPath"] as? String, audio)
        // Overwrite is allowed (re-transcription of the same session).
        try contract(segments: [Segment(start: 0, end: 1, text: "otra")], audioPath: audio).write(to: path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir + "/meetings").count, 1)
    }

    func testProcessedMarkerIsIdempotent() throws {
        let dir = TestSupport.makeTempDir(self, "marker")
        let transcript = dir + "/recording-1.txt"
        let marker = ProcessedMarker.path(forTranscript: transcript)
        XCTAssertEqual(marker, dir + "/recording-1.processed.json")
        try ProcessedMarker.write(transcriptPath: transcript, title: "A", now: TestSupport.fixedDate)
        let first = try Data(contentsOf: URL(fileURLWithPath: marker))
        try ProcessedMarker.write(transcriptPath: transcript, title: "B", now: TestSupport.fixedDate.addingTimeInterval(60))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: marker)), first, "existing marker must never be rewritten")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(root["schema"] as? String, "meetcapture.processed.v1")
        XCTAssertEqual(root["retention"] as? String, "handoff_complete")
        XCTAssertEqual(root["meeting_title"] as? String, "A")
    }

    func testSessionIdentityShapesPendingPath() {
        let s = MeetingSession(startedAt: Date(timeIntervalSince1970: 1_788_271_709.93))
        XCTAssertTrue(s.id.hasPrefix("meet-1788271709-"))
        XCTAssertEqual(s.displayTitle, "Untitled Meeting")
        XCTAssertEqual(s.pendingPath(in: "/m"), "/m/\(s.id).pending")
    }
}

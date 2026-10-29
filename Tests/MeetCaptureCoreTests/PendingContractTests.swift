import XCTest
@testable import MeetCaptureCore

final class PendingContractTests: XCTestCase {
    private let session = MeetingSession(startedAt: TestSupport.fixedDate, title: "Reunión de prueba")

    private func contract(segments: [Segment], audioPath: String = "/nonexistent/recording.pcm") -> PendingContract {
        PendingContract(session: session, endedAt: TestSupport.fixedDate.addingTimeInterval(90.5),
                          transcriptPath: "/tmp/x.txt", transcriptText: TranscriptFormatter.text(for: segments),
                          audioPath: audioPath, engine: .parakeet, model: "parakeet-tdt-0.6b-ultra", language: "es",
                          segments: segments)
    }

    func testMissingAudioCannotInviteCleanupAndAnonymousTurnHasNoInventedSpeaker() throws {
        let data = try contract(segments: [Segment(start: 0, end: 1.5, text: "hola")]).encode(audioExists: false)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(root["audioPath"] is NSNull)
        let turn = try XCTUnwrap((root["segments"] as? [[String: Any]])?.first)
        XCTAssertNil(turn["speaker"])
        XCTAssertEqual(root["speakerCount"] as? Int, 0)
        XCTAssertEqual(root["speakers"] as? [String], [])
    }

    func testChecksumIsSHA256OfTranscriptText() throws {
        let segments = [Segment(start: 0, end: 1, text: "uno", speaker: "A"), Segment(start: 1, end: 2, text: "dos", speaker: "B")]
        let c = contract(segments: segments)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: c.encode(audioExists: true)) as? [String: Any])
        XCTAssertEqual(root["checksum"] as? String, "97e605e07510dd42e348253627db72f8a7973ce31b85ed0b24b97355c3ef9b82")
        XCTAssertEqual(contract(segments: segments + [Segment(start: 2, end: 3, text: "tres", speaker: "A")]).speakers,
                       ["A", "B"], "first appearance order, no repeats")
        XCTAssertEqual(root["speakerCount"] as? Int, 2)
    }

    func testRetranscriptionPublishesReplacementForTheSameMeetingId() throws {
        let dir = TestSupport.makeTempDir(self, "pending")
        let audio = dir + "/recording.pcm"
        TestSupport.write("x", to: audio)
        let path = session.pendingPath(in: dir + "/meetings")
        try contract(segments: [Segment(start: 0, end: 1, text: "hola")], audioPath: audio).write(to: path)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(root["audioPath"] as? String, audio)
        // Overwrite is allowed (re-transcription of the same session).
        try contract(segments: [Segment(start: 0, end: 1, text: "otra")], audioPath: audio).write(to: path)
        let replacement = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        XCTAssertEqual(replacement["meetingId"] as? String, session.id)
        XCTAssertEqual(replacement["checksum"] as? String, "a138a1bc2fcb7314e0bb69dff5ff32c32851554476e3f65742649f2b7ae8beff")
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

}

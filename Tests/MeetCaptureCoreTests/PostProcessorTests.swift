import XCTest
@testable import MeetCaptureCore

final class PostProcessorTests: XCTestCase {
    func testPipelineWritesTranscriptPendingMarkerAppliesRetentionAndIndexes() async throws {
        let dir = TestSupport.makeTempDir(self, "post")
        let capture = dir + "/recording-1.pcm"
        TestSupport.write("pcm", to: capture)
        try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "t").write(forAudio: capture)
        let store = MeetingStore(path: dir + "/meetcapture.db")
        let session = MeetingSession(startedAt: TestSupport.fixedDate, title: "Demo")
        try session.write(forAudio: capture)
        let input = PostProcessInput(
            session: session, segments: [Segment(start: 0, end: 1, text: "hola", speaker: "A")],
            transcriptPath: dir + "/recording-1.txt", capturePath: capture, durableAudioPath: capture,
            engine: .parakeet, model: "medium-q5_0", language: "es", applyRetention: true,
            retention: .deleteAfterHandoff, meetingsDir: dir)
        let result = try await PostProcessor(store: store).run(input, now: TestSupport.fixedDate.addingTimeInterval(30))

        XCTAssertEqual(result.transcriptText, "[A]: hola")
        XCTAssertEqual(result.speakerCount, 1)
        XCTAssertEqual(result.pendingPath, dir + "/\(result.record.id).pending")
        XCTAssertEqual(try String(contentsOfFile: dir + "/recording-1.txt", encoding: .utf8), "[A]: hola")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/recording-1.processed.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture), "deleteAfterHandoff removes the raw capture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture + ".format.json"), "and its sidecar")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingSession.metadataPath(forAudio: capture)),
                       "retention removes the frozen private context with its audio")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: result.pendingPath))) as? [String: Any])
        XCTAssertEqual(root["audioPath"] as? String, capture, "the contract was written before retention ran")
        XCTAssertEqual(root["durationSec"] as? Double, 30)
        let stored = try XCTUnwrap(store.record(id: result.record.id))
        XCTAssertEqual(stored.id, result.record.id)
        XCTAssertEqual(stored.transcriptText, result.record.transcriptText)
        XCTAssertEqual(stored.speakerCount, result.record.speakerCount)
    }

    func testAudioDurationExcludesASRProcessingTime() async throws {
        let dir = TestSupport.makeTempDir(self, "audio-duration")
        let end = TestSupport.fixedDate.addingTimeInterval(60)
        let input = PostProcessInput(session: MeetingSession(startedAt: TestSupport.fixedDate),
            segments: [Segment(start: 0, end: 5, text: "audio real")], transcriptPath: dir + "/result.txt",
            capturePath: dir + "/audio.wav", durableAudioPath: dir + "/audio.wav",
            engine: .parakeet, model: "fixture", language: "es", applyRetention: false,
            retention: .keep, meetingsDir: dir, audioDurationSec: 5.639875, audioEndedAt: end)
        let result = try await PostProcessor(store: MeetingStore(path: dir + "/history.db"))
            .run(input, now: end.addingTimeInterval(120))
        XCTAssertEqual(result.record.durationSec, 5.639875, accuracy: 0.000001)
        XCTAssertEqual(result.record.endedAt, end)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: result.pendingPath))) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(json["durationSec"] as? Double), 5.639875, accuracy: 0.000001)
    }

    func testKeepPolicyAndRetentionSweep() throws {
        let dir = TestSupport.makeTempDir(self, "retention")
        let old = dir + "/recording-old.pcm", fresh = dir + "/recording-new.pcm", other = dir + "/imports.pcm"
        let orphan = dir + "/recording-orphan.pcm"
        for p in [old, fresh, other, orphan] { TestSupport.write("x", to: p) }
        TestSupport.write("{}", to: old + ".format.json")
        TestSupport.write("{}", to: orphan + ".format.json")
        TestSupport.write("{}", to: dir + "/recording-old.processed.json")
        let past = Date().addingTimeInterval(-90_000)
        for p in [old, old + ".format.json", other, orphan, orphan + ".format.json"] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: p)
        }

        Retention.apply(policy: .keep, audioPath: fresh)
        Retention.apply(policy: .keep24h, audioPath: fresh)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))

        Retention.cleanupOldRecordings(in: dir, policy: .keep)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old), "sweep only runs for the 24h policy")
        Retention.cleanupOldRecordings(in: dir, policy: .keep24h)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old + ".format.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other), "only recording-*.pcm names are swept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan), "a capture never transcribed is kept for recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan + ".format.json"))
    }

    func testDaySweepKeepsACaptureWithGapsToRedo() throws {
        let dir = TestSupport.makeTempDir(self, "retention-gaps")
        let done = dir + "/recording-done.pcm", gapped = dir + "/recording-gapped.pcm"
        let rerun = dir + "/recording-rerun.pcm"
        for audio in [done, gapped, rerun] {
            TestSupport.write("x", to: audio)
            try ProcessedMarker.write(transcriptPath: RecordingRecovery.transcriptPath(forAudio: audio), title: "x")
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)],
                                                  ofItemAtPath: audio)
        }
        try RecordingRecovery.markGaps(audioPath: gapped, chunks: 1)
        try FileManager.default.createDirectory(atPath: ChunkedTranscription.workDirectory(forAudio: rerun),
                                                withIntermediateDirectories: true)

        Retention.cleanupOldRecordings(in: dir, policy: .keep24h)

        XCTAssertFalse(FileManager.default.fileExists(atPath: done))
        XCTAssertFalse(FileManager.default.fileExists(atPath: rerun), "a failed re-run of a complete capture has no gaps")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChunkedTranscription.workDirectory(forAudio: rerun)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: gapped), "a capture with gaps keeps its audio for the retry")
    }

    func testPartialHandoffKeepsAudioAndLeavesItOutOfTheContract() async throws {
        let dir = TestSupport.makeTempDir(self, "postprocess-partial")
        let audio = dir + "/recording-partial.pcm"
        TestSupport.write("x", to: audio)
        let session = MeetingSession(startedAt: Date(), title: "Parcial")
        var input = PostProcessInput(
            session: session, segments: [Segment(start: 0, end: 1, text: "hola")],
            transcriptPath: RecordingRecovery.transcriptPath(forAudio: audio), capturePath: audio,
            durableAudioPath: audio, engine: .parakeet, model: "fixture", language: "es",
            applyRetention: true, retention: .deleteAfterHandoff, meetingsDir: dir, audioDurationSec: 1)
        input.partial = true

        let result = try await PostProcessor(store: MeetingStore(path: dir + "/m.db")).run(input)

        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
        let contract = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: result.pendingPath))) as? [String: Any])
        XCTAssertTrue(contract["audioPath"] is NSNull)
    }

}

import XCTest
@testable import MeetCaptureCore

final class RecoveryAndCaptureHealthTests: XCTestCase {
    // MARK: - Recording recovery

    private func makeCapture(_ dir: String, _ name: String, bytes: Int = RecordingRecovery.minimumBytes,
                             strategy: String = "global", modified: Date? = nil) throws -> String {
        let path = "\(dir)/\(name).pcm"
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
        try AudioFormatSidecar.capture(tapStrategy: strategy, tapInfo: "t").write(forAudio: path)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: path)
        }
        return path
    }

    func testFindReturnsOnlyUnprocessedCapturesNewestFirst() throws {
        let dir = TestSupport.makeTempDir(self, "recovery")
        let now = Date()
        let newer = try makeCapture(dir, "recording-2", modified: now.addingTimeInterval(-60))
        let older = try makeCapture(dir, "recording-1", modified: now.addingTimeInterval(-3_600))
        let transcribed = try makeCapture(dir, "recording-3")
        let oldTranscript = RecordingRecovery.transcriptPath(forAudio: transcribed)
        TestSupport.write("hola", to: oldTranscript)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)],
                                              ofItemAtPath: oldTranscript)
        let marked = try makeCapture(dir, "recording-4")
        try ProcessedMarker.write(transcriptPath: RecordingRecovery.transcriptPath(forAudio: marked), title: "x")
        _ = try makeCapture(dir, "recording-5", bytes: 100)
        _ = try makeCapture(dir, "recording-6", strategy: "import")
        let noSidecar = "\(dir)/recording-7.pcm"
        try Data(count: RecordingRecovery.minimumBytes).write(to: URL(fileURLWithPath: noSidecar))
        let busy = try makeCapture(dir, "recording-8")

        let found = RecordingRecovery.find(in: dir, excluding: [busy])

        XCTAssertEqual(found.map(\.audioPath), [newer, older], "today's meeting never waits behind an orphan")
        XCTAssertEqual(found.last?.transcriptPath, "\(dir)/recording-1.txt")
    }

    func testAutomaticRecoveryIsLimitedToRecentCapturesUnderTheRetryCap() throws {
        let dir = TestSupport.makeTempDir(self, "recovery-auto")
        let now = Date()
        let recent = try makeCapture(dir, "recording-1", modified: now.addingTimeInterval(-3_600))
        _ = try makeCapture(dir, "recording-2", modified: now.addingTimeInterval(-3 * 86_400))
        let exhausted = try makeCapture(dir, "recording-3", modified: now.addingTimeInterval(-60))
        for _ in 0..<RecordingRecovery.maxAutomaticAttempts {
            RecordingRecovery.recordFailure(audioPath: exhausted, reason: "engine failed")
        }

        let all = RecordingRecovery.find(in: dir)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(RecordingRecovery.automatic(all, now: now).map(\.audioPath), [recent])
        XCTAssertEqual(RecordingRecovery.attempts(forAudio: exhausted), RecordingRecovery.maxAutomaticAttempts)
    }

    func testFailureAfterAnAttemptStartIsCountedOnce() throws {
        let dir = TestSupport.makeTempDir(self, "recovery-count")
        let audio = try makeCapture(dir, "recording-1")
        RecordingRecovery.recordFailure(audioPath: audio, reason: "attempt started")
        RecordingRecovery.recordFailure(audioPath: audio, reason: "engine failed", countsAsAttempt: false)
        XCTAssertEqual(RecordingRecovery.attempts(forAudio: audio), 1)
    }

    func testRecentTranscriptWithoutMarkerIsRetriedButOldOneIsLeftAlone() throws {
        let dir = TestSupport.makeTempDir(self, "recovery-stranded")
        let now = Date()
        let stranded = try makeCapture(dir, "recording-1")
        TestSupport.write("hola", to: RecordingRecovery.transcriptPath(forAudio: stranded))
        let legacy = try makeCapture(dir, "recording-2")
        let legacyTranscript = RecordingRecovery.transcriptPath(forAudio: legacy)
        TestSupport.write("viejo", to: legacyTranscript)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30 * 86_400)],
                                              ofItemAtPath: legacyTranscript)

        XCTAssertEqual(RecordingRecovery.find(in: dir, now: now).map(\.audioPath), [stranded])
    }

    // MARK: - Channel levels

    private func stereo(_ frames: [(Int16, Int16)]) -> Data {
        var data = Data()
        for (l, r) in frames {
            withUnsafeBytes(of: l.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: r.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    func testChannelLevelsSeparateSilentSystemFromLiveMic() throws {
        let dir = TestSupport.makeTempDir(self, "levels")
        let path = dir + "/capture.pcm"
        let frames = (0..<32_000).map { i in (Int16(0), Int16(i % 2 == 0 ? 900 : -1_200)) }
        try stereo(frames).write(to: URL(fileURLWithPath: path))

        let levels = try XCTUnwrap(ChannelLevels.measureTail(path: path, seconds: 1))
        XCTAssertTrue(levels.systemSilent)
        XCTAssertFalse(levels.micSilent)
        XCTAssertEqual(levels.micPeak, 1_200)
    }

    func testChannelLevelsNeedAtLeastOneSecond() throws {
        let dir = TestSupport.makeTempDir(self, "levels-short")
        let path = dir + "/capture.pcm"
        try stereo(Array(repeating: (100, 100), count: 8_000)).write(to: URL(fileURLWithPath: path))
        XCTAssertNil(ChannelLevels.measureTail(path: path, seconds: 10))
    }

    // MARK: - Menu-bar placement

    func testPlacementRequiresAHostedWindowAndAvoidsTheNotch() {
        let button = CGRect(x: 1_000, y: 849, width: 30, height: 29)
        let hosted = [CGRect(x: 1_000, y: 0, width: 30, height: 29)]
        let notch = CGRect(x: 593, y: 849, width: 166, height: 29)

        XCTAssertEqual(StatusItemPlacement.evaluate(frame: button, notch: notch, hostedWindowFrames: hosted), .visible)
        XCTAssertEqual(StatusItemPlacement.evaluate(frame: button, notch: notch, hostedWindowFrames: []), .notHosted)
        XCTAssertEqual(
            StatusItemPlacement.evaluate(frame: button, notch: nil,
                                         hostedWindowFrames: [CGRect(x: 1_200, y: 0, width: 30, height: 29)]),
            .notHosted)
        let behind = CGRect(x: 650, y: 849, width: 30, height: 29)
        XCTAssertEqual(
            StatusItemPlacement.evaluate(frame: behind, notch: notch,
                                         hostedWindowFrames: [CGRect(x: 650, y: 0, width: 30, height: 29)]),
            .behindNotch)
    }
}

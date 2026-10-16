import XCTest
@testable import MeetCaptureCore

final class PipelineRegressionTests: XCTestCase {
    private func input(
        session: MeetingSession,
        directory: String,
        capture: String,
        meetingsDir: String,
        segments: [Segment] = [Segment(start: 0, end: 1, text: "hola")],
        storeRetention: RetentionPolicy = .keep
    ) -> PostProcessInput {
        PostProcessInput(
            session: session,
            segments: segments,
            transcriptPath: directory + "/recording.txt",
            capturePath: capture,
            durableAudioPath: capture,
            engine: .whisper,
            model: "fake",
            language: "es",
            applyRetention: true,
            retention: storeRetention,
            meetingsDir: meetingsDir)
    }

    func testSessionsInTheSameSecondHaveStableUniqueIDs() {
        let start = TestSupport.fixedDate
        let first = MeetingSession(startedAt: start, title: "A")
        let second = MeetingSession(startedAt: start, title: "B")

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertTrue(first.id.hasPrefix("meet-1788271709-"))
        XCTAssertTrue(second.id.hasPrefix("meet-1788271709-"))
    }

    func testEmptyTranscriptRejectsBeforeAnyDurableOrDestructiveEffect() async throws {
        let dir = TestSupport.makeTempDir(self, "empty-post")
        let capture = dir + "/recording.pcm"
        TestSupport.write("pcm", to: capture)
        try AudioFormatSidecar.capture(tapStrategy: "fake", tapInfo: "fixture").write(forAudio: capture)
        let session = MeetingSession(startedAt: TestSupport.fixedDate)
        let store = MeetingStore(path: dir + "/meetcapture.db")
        let post = PostProcessor(store: store)
        let value = input(session: session, directory: dir, capture: capture, meetingsDir: dir,
                          segments: [Segment(start: 0, end: 1, text: " \n\t")],
                          storeRetention: .deleteAfterHandoff)

        do {
            _ = try await post.run(value, now: TestSupport.fixedDate.addingTimeInterval(30))
            XCTFail("an empty transcript must be rejected")
        } catch let error as PostProcessError {
            XCTAssertTrue(error.localizedDescription.contains("no produjo texto"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: capture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioFormatSidecar.path(forAudio: capture)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/recording.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: dir + "/recording.txt")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".pending") }.count, 0)
        XCTAssertEqual(store.count(), 0)
    }

    func testStoreFailureDoesNotPublishHandoffOrDeleteAudio() async throws {
        let dir = TestSupport.makeTempDir(self, "store-failure")
        let capture = dir + "/recording.pcm"
        TestSupport.write("pcm", to: capture)
        try AudioFormatSidecar.capture(tapStrategy: "fake", tapInfo: "fixture").write(forAudio: capture)
        let invalidDatabasePath = dir + "/database-directory"
        try FileManager.default.createDirectory(atPath: invalidDatabasePath, withIntermediateDirectories: false)
        let store = MeetingStore(path: invalidDatabasePath)
        let session = MeetingSession(startedAt: TestSupport.fixedDate)
        let transcript = dir + "/recording.txt"
        let value = input(session: session, directory: dir, capture: capture, meetingsDir: dir)

        do {
            _ = try await PostProcessor(store: store).run(value, now: TestSupport.fixedDate.addingTimeInterval(30))
            XCTFail("the invalid store must reject the durable write")
        } catch let error as PostProcessError {
            XCTAssertTrue(error.localizedDescription.contains("historial"))
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: capture))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioFormatSidecar.path(forAudio: capture)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript), "the local transcript is recoverable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: transcript)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".pending") }.count, 0)
    }

    func testMarkerFailureDoesNotPublishHandoffOrDeleteAudio() async throws {
        let dir = TestSupport.makeTempDir(self, "marker-failure")
        let capture = dir + "/recording.pcm"
        let transcript = dir + "/recording.txt"
        TestSupport.write("pcm", to: capture)
        try AudioFormatSidecar.capture(tapStrategy: "fake", tapInfo: "fixture").write(forAudio: capture)
        try FileManager.default.createDirectory(atPath: ProcessedMarker.path(forTranscript: transcript), withIntermediateDirectories: false)
        let store = MeetingStore(path: dir + "/meetcapture.db")
        let value = input(session: MeetingSession(startedAt: TestSupport.fixedDate), directory: dir,
                          capture: capture, meetingsDir: dir)

        do {
            _ = try await PostProcessor(store: store).run(value, now: TestSupport.fixedDate.addingTimeInterval(30))
            XCTFail("a marker path that is a directory must fail")
        } catch let error as PostProcessError {
            XCTAssertTrue(error.localizedDescription.contains("marker"))
        }

        XCTAssertEqual(store.count(), 1, "the store write precedes marker publication")
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/\(value.session.id).pending"))
    }

    func testSuccessfulPostProcessIsIdempotentForTheSameJob() async throws {
        let dir = TestSupport.makeTempDir(self, "post-retry")
        let capture = dir + "/recording.pcm"
        TestSupport.write("pcm", to: capture)
        try AudioFormatSidecar.capture(tapStrategy: "fake", tapInfo: "fixture").write(forAudio: capture)
        let session = MeetingSession(startedAt: TestSupport.fixedDate)
        let value = input(session: session, directory: dir, capture: capture, meetingsDir: dir)
        let store = MeetingStore(path: dir + "/meetcapture.db")
        let post = PostProcessor(store: store)

        let first = try await post.run(value, now: TestSupport.fixedDate.addingTimeInterval(30))
        let second = try await post.run(value, now: TestSupport.fixedDate.addingTimeInterval(30))

        XCTAssertEqual(first.record.id, second.record.id)
        XCTAssertEqual(first.pendingPath, second.pendingPath)
        XCTAssertEqual(store.count(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.pendingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: capture))
    }

    func testPCMImportKeepsACompletedCopyAndAvoidsSameMinuteCollision() async throws {
        let dir = TestSupport.makeTempDir(self, "import-copy")
        let source = dir + "/source.pcm"
        TestSupport.write("pcm", to: source)
        let imports = dir + "/imports"

        let first = try await AudioImporter.prepare(url: URL(fileURLWithPath: source), importsDir: imports,
                                                     now: TestSupport.fixedDate)
        let second = try await AudioImporter.prepare(url: URL(fileURLWithPath: source), importsDir: imports,
                                                      now: TestSupport.fixedDate)

        XCTAssertEqual(first.workPath, first.durableAudioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.durableAudioPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioFormatSidecar.path(forAudio: first.durableAudioPath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        XCTAssertNotEqual(first.durableAudioPath, second.durableAudioPath)
        XCTAssertNotEqual(first.transcriptPath, second.transcriptPath)
    }

    func testCancelledConversionRemovesPartialAudioAndRetryPublishesOnlyCompleteWAV() async throws {
        let dir = TestSupport.makeTempDir(self, "import-cancel")
        let source = dir + "/source.aiff"
        TestSupport.write("source stays intact", to: source)
        let imports = dir + "/imports"
        let now = TestSupport.fixedDate

        do {
            _ = try await AudioImporter.prepare(
                url: URL(fileURLWithPath: source), importsDir: imports, now: now,
                converter: { spec in
                    try Data(repeating: 0x2a, count: 4096).write(
                        to: URL(fileURLWithPath: spec.arguments.last!))
                    throw CancellationError()
                })
            XCTFail("cancelled conversion must not publish audio")
        } catch is CancellationError {
            // The real converter can be cancelled after writing a partial WAV.
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))

        let imported = try await AudioImporter.prepare(
            url: URL(fileURLWithPath: source), importsDir: imports, now: now,
            converter: { spec in
                var wav = PCMToWAV.header(dataSize: 2)
                wav.append(contentsOf: [0, 0])
                try wav.write(to: URL(fileURLWithPath: spec.arguments.last!))
            })
        XCTAssertTrue(PCMToWAV.is16kMonoWAV(imported.durableAudioPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports),
                       [URL(fileURLWithPath: imported.durableAudioPath).lastPathComponent])
    }

    func testRealAFConvertImportPublishesOneCompleteWAV() async throws {
        let dir = TestSupport.makeTempDir(self, "import-afconvert")
        let original = dir + "/original.wav"
        let source = dir + "/source-8k.wav"
        let sampleCount = 16_000
        var wav = PCMToWAV.header(dataSize: UInt32(sampleCount * 2))
        wav.append(Data(repeating: 0, count: sampleCount * 2))
        try wav.write(to: URL(fileURLWithPath: original))
        _ = try await ProcessRunner.runChecked(ProcessSpec(
            executable: "/usr/bin/afconvert",
            arguments: ["-f", "WAVE", "-d", "LEI16@8000", "-c", "1", original, source],
            timeout: 15))
        XCTAssertFalse(PCMToWAV.is16kMonoWAV(source))

        let imports = dir + "/imports"
        let imported = try await AudioImporter.prepare(
            url: URL(fileURLWithPath: source), importsDir: imports, now: TestSupport.fixedDate)

        XCTAssertTrue(PCMToWAV.is16kMonoWAV(imported.durableAudioPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imports),
                       [URL(fileURLWithPath: imported.durableAudioPath).lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        XCTAssertEqual(PCMToWAV.wavDurationSeconds(imported.durableAudioPath), 1, accuracy: 0.01)
    }

    func testWAVReimportReservesTranscriptAndMarkerAfterAudioRetention() async throws {
        let dir = TestSupport.makeTempDir(self, "wav-reimport")
        let source = dir + "/meeting.wav"
        var wav = PCMToWAV.header(dataSize: 2)
        wav.append(contentsOf: [0, 0])
        try wav.write(to: URL(fileURLWithPath: source))
        let imports = dir + "/imports"
        let now = TestSupport.fixedDate
        let store = MeetingStore(path: dir + "/meetcapture.db")
        let post = PostProcessor(store: store)

        let first = try await AudioImporter.prepare(url: URL(fileURLWithPath: source), importsDir: imports, now: now)
        let firstSession = MeetingSession(startedAt: now, title: "meeting")
        let firstInput = PostProcessInput(
            session: firstSession, segments: [Segment(start: 0, end: 1, text: "first")],
            transcriptPath: first.transcriptPath, capturePath: first.durableAudioPath,
            durableAudioPath: first.durableAudioPath, engine: .whisper, model: "fake", language: "es",
            applyRetention: true, retention: .deleteAfterHandoff, meetingsDir: dir)
        let firstResult = try await post.run(firstInput, now: now.addingTimeInterval(30))

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.durableAudioPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.transcriptPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: first.transcriptPath)))
        XCTAssertEqual(try String(contentsOfFile: first.transcriptPath, encoding: .utf8), "first")
        XCTAssertEqual(store.record(id: firstSession.id)?.transcriptText, "first")

        let second = try await AudioImporter.prepare(url: URL(fileURLWithPath: source), importsDir: imports, now: now)
        XCTAssertNotEqual(first.durableAudioPath, second.durableAudioPath)
        XCTAssertNotEqual(first.transcriptPath, second.transcriptPath)

        let secondSession = MeetingSession(startedAt: now, title: "meeting")
        let secondInput = PostProcessInput(
            session: secondSession, segments: [Segment(start: 0, end: 1, text: "second")],
            transcriptPath: second.transcriptPath, capturePath: second.durableAudioPath,
            durableAudioPath: second.durableAudioPath, engine: .whisper, model: "fake", language: "es",
            applyRetention: true, retention: .deleteAfterHandoff, meetingsDir: dir)
        let secondResult = try await post.run(secondInput, now: now.addingTimeInterval(30))

        XCTAssertEqual(try String(contentsOfFile: first.transcriptPath, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOfFile: second.transcriptPath, encoding: .utf8), "second")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: first.transcriptPath)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: second.transcriptPath)))
        XCTAssertEqual(store.record(id: firstSession.id)?.transcriptPath, first.transcriptPath)
        XCTAssertEqual(store.record(id: firstSession.id)?.transcriptText, "first")
        XCTAssertEqual(store.record(id: secondSession.id)?.transcriptPath, second.transcriptPath)
        XCTAssertEqual(store.record(id: secondSession.id)?.transcriptText, "second")
        XCTAssertNotEqual(firstResult.pendingPath, secondResult.pendingPath)
        XCTAssertEqual(store.count(), 2)
    }
}

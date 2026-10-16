import Foundation
import XCTest
@testable import MeetCaptureCore

@MainActor
final class AppStateRegressionTests: XCTestCase {
    func testRecordingNotesAreSavedForMatchingHandoff() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-notes")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        let defaults = UserDefaults.standard
        let key = Settings.Key.notifyHermes.rawValue
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath),
            recordingDriver: backend.driver,
            transcriptionRunner: { _, _ in
                TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 1, text: "Hablamos del plan")],
                                         engineUsed: .whisper, modelUsed: "fixture")
            })
        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.meetingNotes = "Pedir confirmación del cliente."
        let id = try XCTUnwrap(backend.outputPath)
            .replacingOccurrences(of: "recording-", with: "")
            .replacingOccurrences(of: ".pcm", with: "")
            .components(separatedBy: "/").last!
        let notesPath = MeetingNotesStore.path(meetingId: id, meetingsDir: outputDir)
        XCTAssertEqual(try String(contentsOfFile: notesPath, encoding: .utf8), state.meetingNotes)
        state.stopRecording()
        try await waitUntil { state.phase == .done }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir + "/" + id + ".pending"))
        XCTAssertEqual(try String(contentsOfFile: notesPath, encoding: .utf8), "Pedir confirmación del cliente.")
    }

    func testStopDuringSuspendedStartWaitsThenStopsOnceAndPublishesAudioResult() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-cycle")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let store = MeetingStore(path: paths.databasePath)
        let backend = FakeRecordingBackend()
        let defaults = UserDefaults.standard
        let notifyKey = Settings.Key.notifyHermes.rawValue
        let previousNotify = defaults.object(forKey: notifyKey)
        defaults.set(false, forKey: notifyKey)
        defer {
            if let previousNotify { defaults.set(previousNotify, forKey: notifyKey) }
            else { defaults.removeObject(forKey: notifyKey) }
        }

        let appState = AppState(
            paths: paths,
            store: store,
            recordingDriver: backend.driver,
            transcriptionRunner: { _, progress in
                progress(1)
                return TranscriptionJob.Outcome(
                    segments: [Segment(start: 0, end: 1, text: "audio entregado", speaker: "A")],
                    engineUsed: .whisper, modelUsed: "fixture")
            })

        appState.startRecording()
        try await waitUntil { backend.startCallCount == 1 && backend.startIsSuspended }
        XCTAssertEqual(appState.phase, .recording)
        XCTAssertTrue(appState.isStartingRecording)
        XCTAssertEqual(appState.recordingDuration, 0)

        appState.stopRecording()
        XCTAssertEqual(appState.phase, .transcribing)
        XCTAssertTrue(appState.isStartingRecording, "The UI must keep showing pending start until the driver resolves")
        XCTAssertEqual(backend.stopCallCount, 0, "Stop must wait for the suspended start")

        backend.resumeStart()
        try await waitUntil { backend.stopCallCount == 1 }
        try await waitUntil { appState.phase == .done }

        XCTAssertEqual(backend.stopCallCount, 1)
        XCTAssertFalse(appState.isStartingRecording)
        XCTAssertEqual(backend.lastStoppedPath, backend.outputPath)
        XCTAssertNotEqual(appState.phase, .recording)
        XCTAssertEqual(store.count(), 1)
        let record = try XCTUnwrap(store.recent(limit: 1).first)
        XCTAssertEqual((backend.lastStoppedPath! as NSString).lastPathComponent,
                       "recording-\(record.id).pcm", "raw audio must share the unique job identity")
        XCTAssertEqual(appState.lastSegments.first?.text, "audio entregado")
        XCTAssertNotNil(appState.lastTranscriptPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appState.lastTranscriptPath!))
    }

    func testCaptureStartCancellationReturnsIdleWithoutShowingRecordingError() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-start-cancel")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let backend = FakeRecordingBackend()
        backend.cancelStart = true
        let appState = AppState(paths: paths, store: MeetingStore(path: paths.databasePath), recordingDriver: backend.driver)

        appState.startRecording()
        try await waitUntil { appState.phase == .idle && backend.startCallCount == 1 }

        XCTAssertFalse(appState.isStartingRecording)
        XCTAssertNil(appState.errorMessage)
        XCTAssertFalse(backend.isRecording)
    }

    func testCaptureStartFailureClearsPendingStateAndAllowsRetry() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-start-failure")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let backend = FakeRecordingBackend()
        backend.startError = CaptureError.ioProcCreationFailed(-1)
        let appState = AppState(paths: paths, store: MeetingStore(path: paths.databasePath), recordingDriver: backend.driver)

        appState.startRecording()
        try await waitUntil { backend.startCallCount == 1 && appState.phase == .idle }

        XCTAssertFalse(appState.isStartingRecording)
        XCTAssertTrue(appState.errorMessage?.contains("No se pudo grabar") == true)

        backend.startError = nil
        backend.suspendStart = false
        appState.startRecording()
        try await waitUntil { backend.startCallCount == 2 && backend.isRecording }

        XCTAssertEqual(appState.phase, .recording)
        XCTAssertFalse(appState.isStartingRecording)
        _ = try? await backend.stop()
    }

    func testCaptureStartTimeoutClearsPendingStateAndPublishesCurrentError() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-start-timeout")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let backend = FakeRecordingBackend()
        backend.startError = CaptureStartError.timedOut
        let appState = AppState(paths: paths, store: MeetingStore(path: paths.databasePath), recordingDriver: backend.driver)

        appState.startRecording()
        try await waitUntil { backend.startCallCount == 1 && appState.phase == .idle }

        XCTAssertFalse(appState.isStartingRecording)
        XCTAssertTrue(appState.errorMessage?.contains("no respondió a tiempo") == true)
        XCTAssertFalse(backend.isRecording)
    }

    func testCaptureWriteFailureStopsImmediatelyAndDoesNotPublishPartialAudio() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-write-failure")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let store = MeetingStore(path: paths.databasePath)
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        let transcriptions = TranscriptionCallCounter()
        let defaults = UserDefaults.standard
        let notifyKey = Settings.Key.notifyHermes.rawValue
        let previousNotify = defaults.object(forKey: notifyKey)
        defaults.set(false, forKey: notifyKey)
        defer {
            if let previousNotify { defaults.set(previousNotify, forKey: notifyKey) }
            else { defaults.removeObject(forKey: notifyKey) }
        }
        let appState = AppState(
            paths: paths,
            store: store,
            recordingDriver: backend.driver,
            transcriptionRunner: { _, _ in
                transcriptions.increment()
                return TranscriptionJob.Outcome(
                    segments: [Segment(start: 0, end: 1, text: "no debe publicarse")],
                    engineUsed: .whisper, modelUsed: "fixture")
            },
            errorDismissalDelay: 300)

        appState.startRecording()
        try await waitUntil { backend.isRecording }
        let partialPath = try XCTUnwrap(backend.outputPath)
        let partialAudio = try XCTUnwrap(FileManager.default.contents(atPath: partialPath))
        backend.stopError = PCMFileWriter.WriterError.writeFailed(path: partialPath, reason: "fixture failure")

        appState.handleCaptureFailure("La captura dejó de guardar audio")
        try await waitUntil { appState.phase == .idle && backend.stopCallCount == 1 }

        XCTAssertEqual(transcriptions.value, 0)
        XCTAssertEqual(store.count(), 0)
        XCTAssertNil(appState.lastTranscriptPath)
        XCTAssertTrue(appState.lastSegments.isEmpty)
        XCTAssertTrue(appState.errorMessage?.contains(partialPath) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: partialPath))
        XCTAssertEqual(FileManager.default.contents(atPath: partialPath), partialAudio)
    }

    func testStartingStringsDoNotReportActiveRecording() {
        XCTAssertEqual(Strings.phase(.recording, isStartingRecording: true), "Iniciando audio…")
        XCTAssertEqual(Strings.headline(.recording, meeting: nil, isStartingRecording: true), "Iniciando audio…")
        XCTAssertFalse(Strings.headline(.recording, meeting: nil, isStartingRecording: true).contains("Grabando"))
    }

    func testSharedHistoryQueryKeepsResultsFilteredAcrossRefresh() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-history-query")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let store = MeetingStore(path: paths.databasePath)
        let startedAt = TestSupport.fixedDate
        for (id, title) in [("alpha", "Alpha"), ("beta", "Beta")] {
            XCTAssertTrue(store.insert(MeetingRecord(
                id: id, title: title, startedAt: startedAt,
                endedAt: startedAt.addingTimeInterval(60), durationSec: 60,
                engine: "whisper", model: "fixture", language: "en",
                transcriptPath: "\(outputDir)/\(id).txt", summaryPath: nil,
                speakerCount: 1, transcriptText: title)))
        }
        let appState = AppState(paths: paths, store: store)
        appState.historyQuery = "Alpha"
        appState.historyQuery = "Beta"
        try await waitUntil { appState.history.map(\.id) == ["beta"] }

        XCTAssertTrue(store.insert(MeetingRecord(
            id: "beta-new", title: "Beta follow-up", startedAt: startedAt.addingTimeInterval(120),
            endedAt: startedAt.addingTimeInterval(180), durationSec: 60,
            engine: "whisper", model: "fixture", language: "en",
            transcriptPath: "\(outputDir)/beta-new.txt", summaryPath: nil,
            speakerCount: 1, transcriptText: "Beta follow-up")))
        appState.refreshHistory()
        XCTAssertEqual(appState.historyQuery, "Beta")
        try await waitUntil { Set(appState.history.map(\.id)) == Set(["beta", "beta-new"]) }

        appState.historyQuery = ""
        try await waitUntil { Set(appState.history.map(\.id)) == Set(["alpha", "beta", "beta-new"]) }
    }

    func testNewErrorSurvivesPreviousDismissalSchedule() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-error")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let appState = AppState(
            paths: paths,
            store: MeetingStore(path: paths.databasePath),
            errorDismissalDelay: 0.06)

        appState.errorMessage = "old error"
        try await Task.sleep(nanoseconds: 30_000_000)
        appState.errorMessage = "new error"
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(appState.errorMessage, "new error")

        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertNil(appState.errorMessage)
    }

    func testRepeatedRetranscriptionKeepsSeparateHistoryArtifacts() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-retranscribe")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let store = MeetingStore(path: paths.databasePath)
        let audio = outputDir + "/source.wav"
        var wav = PCMToWAV.header(dataSize: 2)
        wav.append(contentsOf: [0, 0])
        try wav.write(to: URL(fileURLWithPath: audio))
        let defaults = UserDefaults.standard
        let key = Settings.Key.notifyHermes.rawValue
        let previous = defaults.object(forKey: key)
        defaults.set(false, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let appState = AppState(paths: paths, store: store, transcriptionRunner: { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 1, text: "fixture")],
                                     engineUsed: .whisper, modelUsed: "fixture")
        })
        appState.lastAudioPath = audio
        appState.errorMessage = "previous transcription failed"
        await appState.retranscribeLastAudio()
        XCTAssertNil(appState.errorMessage)
        let firstPath = try XCTUnwrap(appState.lastTranscriptPath)
        let firstData = try Data(contentsOf: URL(fileURLWithPath: firstPath))
        await appState.retranscribeLastAudio()
        let secondPath = try XCTUnwrap(appState.lastTranscriptPath)
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(store.count(), 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: firstPath)), firstData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
    }

    func testFailedImportThenValidImportClearsError() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-import-recovery")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let store = MeetingStore(path: paths.databasePath)
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain([Settings.Key.notifyHermes.rawValue: false], forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let appState = AppState(paths: paths, store: store, transcriptionRunner: { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 1, text: "recovered")],
                                     engineUsed: .whisper, modelUsed: "fixture", audioDurationSec: 1)
        }, errorDismissalDelay: 300)
        await appState.importAudio(url: URL(fileURLWithPath: outputDir + "/missing.wav"))
        XCTAssertNotNil(appState.errorMessage)
        XCTAssertEqual(store.count(), 0)

        let source = URL(fileURLWithPath: outputDir + "/voice.wav")
        var wav = PCMToWAV.header(dataSize: 32_000)
        wav.append(Data(repeating: 0, count: 32_000))
        try wav.write(to: source)
        await appState.importAudio(url: source)
        XCTAssertEqual(appState.phase, .done)
        XCTAssertNil(appState.errorMessage)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(appState.lastSegments.first?.text, "recovered")
    }

    func testQuittingMidRecordingStopsCaptureWithoutTranscribing() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-quit")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        var transcriptions = 0
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath),
            recordingDriver: backend.driver,
            transcriptionRunner: { _, _ in
                await MainActor.run { transcriptions += 1 }
                return TranscriptionJob.Outcome(segments: [], engineUsed: .whisper, modelUsed: "fixture")
            })
        state.startRecording()
        try await waitUntil { backend.isRecording }
        XCTAssertTrue(state.needsGracefulShutdown)

        await state.shutdownGracefully()

        XCTAssertEqual(backend.stopCallCount, 1)
        XCTAssertFalse(state.needsGracefulShutdown)
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(transcriptions, 0, "the capture is left for startup recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(backend.outputPath)))
    }

    func testRecoveryTranscribesOrphanInBackgroundWithoutChangingPhase() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-recovery")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        try FileManager.default.createDirectory(atPath: paths.transcriptsDir, withIntermediateDirectories: true)
        let orphan = paths.transcriptsDir + "/recording-1789474169.pcm"
        try Data(count: RecordingRecovery.minimumBytes).write(to: URL(fileURLWithPath: orphan))
        try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "t").write(forAudio: orphan)
        let store = MeetingStore(path: paths.databasePath)
        let state = AppState(
            paths: paths, store: store, recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: { job, _ in
                XCTAssertEqual(job.audioPath, orphan)
                return TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 1, text: "Recuperado")],
                                                engineUsed: .whisper, modelUsed: "fixture")
            })

        state.recoverRecordings(automaticOnly: true)
        XCTAssertTrue(state.isRecovering)
        XCTAssertEqual(state.phase, .idle)
        try await waitUntil { !state.isRecovering }

        let transcript = RecordingRecovery.transcriptPath(forAudio: orphan)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ProcessedMarker.path(forTranscript: transcript)))
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(state.pendingRecordingCount, 0)
        XCTAssertEqual(state.phase, .idle)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            if Date() >= deadline { XCTFail("Timed out waiting for AppState transition"); return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

@MainActor
private final class FakeRecordingBackend {
    var startCallCount = 0
    var stopCallCount = 0
    var isRecording = false
    var cancelStart = false
    var suspendStart = true
    var startError: Error?
    var stopError: Error?
    var outputPath: String?
    var lastStoppedPath: String?
    var startIsSuspended = false
    private var startContinuation: CheckedContinuation<Void, Error>?

    var driver: AppStateRecordingDriver {
        AppStateRecordingDriver(
            checkPermission: { true },
            openPrivacySettings: {},
            isRecording: { self.isRecording },
            currentSampleRate: { 16_000 },
            start: { [self] outputPath, _ in try await self.start(path: outputPath) },
            stop: { [self] in try await self.stop() })
    }

    func start(path: String) async throws {
        startCallCount += 1
        outputPath = path
        if let startError { throw startError }
        try Data("fixture pcm".utf8).write(to: URL(fileURLWithPath: path))
        if cancelStart {
            throw CaptureError.startCancelled
        }
        guard suspendStart else {
            isRecording = true
            return
        }
        startIsSuspended = true
        try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
        }
        startIsSuspended = false
        isRecording = true
    }

    func resumeStart() {
        guard let continuation = startContinuation else {
            XCTFail("Expected a suspended capture start")
            return
        }
        startContinuation = nil
        continuation.resume()
    }

    func stop() async throws -> String? {
        stopCallCount += 1
        lastStoppedPath = outputPath
        isRecording = false
        if let stopError { throw stopError }
        return outputPath
    }
}

private final class TranscriptionCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _value += 1
    }
}

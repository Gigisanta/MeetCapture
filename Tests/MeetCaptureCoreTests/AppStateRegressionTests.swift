import Combine
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
                                         engineUsed: .parakeet, modelUsed: "fixture")
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
        backend.writesRecoverableCapture = true
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
                    engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
            })

        appState.startRecording()
        try await waitUntil { backend.startCallCount == 1 && backend.startIsSuspended }
        XCTAssertEqual(appState.phase, .recording)
        XCTAssertTrue(appState.isStartingRecording)
        XCTAssertEqual(appState.recordingDuration, 0)
        let audioPath = try XCTUnwrap(backend.outputPath)
        let initialSession = try XCTUnwrap(try MeetingSession.read(forAudio: audioPath))
        // The initial metadata predates the driver's delayed start. The PCM's
        // final write and measured duration, not the button press, date the audio.
        let audioEndedAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 60)
        XCTAssertGreaterThan(audioEndedAt, initialSession.startedAt.addingTimeInterval(5))
        try FileManager.default.setAttributes([.modificationDate: audioEndedAt], ofItemAtPath: audioPath)

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
        XCTAssertEqual(record.endedAt, audioEndedAt)
        XCTAssertEqual(record.startedAt, audioEndedAt.addingTimeInterval(-5))
        XCTAssertEqual(record.durationSec, 5)
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
                    engineUsed: .parakeet, modelUsed: "fixture")
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
        let dismissed = expectation(description: "replacement error dismissed")
        var replacedAt: ContinuousClock.Instant?
        var visibleFor: Duration?
        let observation = appState.$errorMessage.dropFirst().sink { message in
            if message == "new error" { replacedAt = .now }
            guard message == nil, let replacedAt else { return }
            visibleFor = replacedAt.duration(to: .now)
            dismissed.fulfill()
        }
        defer { observation.cancel() }
        appState.errorMessage = "new error"

        await fulfillment(of: [dismissed], timeout: 5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(visibleFor), .milliseconds(60),
                                    "the previous error must not shorten the replacement's lifetime")
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
                                     engineUsed: .parakeet, modelUsed: "fixture")
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
                                     engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 1)
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
                return TranscriptionJob.Outcome(segments: [], engineUsed: .parakeet, modelUsed: "fixture")
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
                                                engineUsed: .parakeet, modelUsed: "fixture")
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

    // MARK: - Transcripts with gaps

    private nonisolated static let gappedOutcome = TranscriptionJob.Outcome(
        segments: [Segment(start: 0, end: 1, text: "Arrancamos"),
                   Segment(start: 300, end: 600, text: "[fragmento sin transcribir 00:05:00–00:10:00]")],
        engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 600, failedChunks: 1)
    private nonisolated static let completeOutcome = TranscriptionJob.Outcome(
        segments: [Segment(start: 0, end: 1, text: "Arrancamos"), Segment(start: 300, end: 301, text: "y cerramos")],
        engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 600)

    /// Like the real job, a run leaves its chunk checkpoints behind.
    private static func runner(_ calls: TranscriptionCallCounter,
                               outcome: @escaping @Sendable (Int) -> TranscriptionJob.Outcome)
        -> AppStateTranscriptionRunner {
        { job, _ in
            calls.increment()
            try FileManager.default.createDirectory(
                atPath: ChunkedTranscription.workDirectory(forAudio: job.audioPath), withIntermediateDirectories: true)
            return outcome(calls.value)
        }
    }

    private func useSettings(_ values: [String: Any]) {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defaults.setVolatileDomain(previous.merging(values) { $1 }, forName: UserDefaults.argumentDomain)
        addTeardownBlock { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    }

    private func pendingFiles(in dir: String) throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".pending") }.map {
            try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: dir + "/" + $0))) as? [String: Any])
        }
    }

    func testLegacyHandoffRootSurvivesReimportWithoutInventingCalendar() async throws {
        let output = TestSupport.makeTempDir(self, "legacy-import-lineage")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": output], home: output)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep.rawValue])
        let id = "meet-1788271709-11111111-1111-4111-8111-111111111111"
        let audio = paths.transcriptsDir + "/recording-\(id).pcm"
        let transcript = RecordingRecovery.transcriptPath(forAudio: audio)
        TestSupport.write("original pcm", to: audio)
        TestSupport.write("original transcript", to: transcript)
        try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "fixture").write(forAudio: audio)
        let store = MeetingStore(path: paths.databasePath)
        XCTAssertTrue(store.insert(MeetingRecord(
            id: id, title: "Agenda original", startedAt: TestSupport.fixedDate,
            endedAt: TestSupport.fixedDate.addingTimeInterval(5), durationSec: 5,
            engine: "parakeet", model: "fixture", language: "es", transcriptPath: transcript,
            summaryPath: nil, speakerCount: 0, transcriptText: "original transcript")))
        let rootId = "meet-1788271000-22222222-2222-4222-8222-222222222222"
        let done: [String: Any] = ["version": 2, "meetingId": id, "transcriptPath": transcript,
                                  "supersedesMeetingId": rootId]
        let donePath = output + "/\(id).done"
        let doneData = try JSONSerialization.data(withJSONObject: done)
        try doneData.write(to: URL(fileURLWithPath: donePath))
        let state = AppState(paths: paths, store: store, transcriptionRunner: { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 5, text: "transcripción mejorada")],
                                     engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
        })

        await state.importAudio(url: URL(fileURLWithPath: audio))

        let handoff = try XCTUnwrap(try pendingFiles(in: output).first)
        XCTAssertNotEqual(handoff["meetingId"] as? String, id)
        XCTAssertEqual(handoff["supersedesMeetingId"] as? String, rootId)
        XCTAssertEqual(handoff["startedAt"] as? String, ISO8601.string(from: TestSupport.fixedDate))
        XCTAssertEqual(handoff["title"] as? String, "Agenda original")
        XCTAssertTrue(handoff["calendarEvent"] is NSNull)
        XCTAssertEqual(handoff["calendarMatch"] as? String, "none")
        XCTAssertEqual(try String(contentsOfFile: audio, encoding: .utf8), "original pcm")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingSession.metadataPath(forAudio: audio)),
                       "import must not add metadata to its original source")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: donePath)), doneData)
    }

    func testMismatchedLegacyHandoffCannotSupplyAncestry() async throws {
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep.rawValue])
        for (suffix, mismatch) in [("done", "meetingId"), ("done", "transcriptPath"),
                                   ("pending", "meetingId"), ("pending", "transcriptPath"),
                                   ("done", "externalAudio")] {
            let output = TestSupport.makeTempDir(self, "legacy-mismatch-\(suffix)-\(mismatch)")
            let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": output], home: output)
            let id = "meet-1788271709-11111111-1111-4111-8111-111111111111"
            let canonicalAudio = paths.transcriptsDir + "/recording-\(id).pcm"
            let transcript = RecordingRecovery.transcriptPath(forAudio: canonicalAudio)
            let audio = mismatch == "externalAudio"
                ? output + "/external/recording-\(id).pcm" : canonicalAudio
            try FileManager.default.createDirectory(
                atPath: (audio as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            TestSupport.write("original pcm", to: audio)
            let store = MeetingStore(path: paths.databasePath)
            XCTAssertTrue(store.insert(MeetingRecord(
                id: id, title: "Agenda original", startedAt: TestSupport.fixedDate,
                endedAt: TestSupport.fixedDate.addingTimeInterval(5), durationSec: 5,
                engine: "parakeet", model: "fixture", language: "es", transcriptPath: transcript,
                summaryPath: nil, speakerCount: 0, transcriptText: "original transcript")))
            let legacy: [String: Any] = [
                "version": 2, "meetingId": mismatch == "meetingId" ? "unrelated-meeting" : id,
                "transcriptPath": mismatch == "transcriptPath" ? output + "/unrelated.txt" : transcript,
                "supersedesMeetingId": "meet-1788271000-22222222-2222-4222-8222-222222222222",
            ]
            let legacyPath = output + "/\(id).\(suffix)"
            let legacyData = try JSONSerialization.data(withJSONObject: legacy)
            try legacyData.write(to: URL(fileURLWithPath: legacyPath))
            let state = AppState(paths: paths, store: store, transcriptionRunner: { _, _ in
                TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 5, text: "transcripción")],
                                         engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
            })

            await state.importAudio(url: URL(fileURLWithPath: audio))

            let derived = try XCTUnwrap(try MeetingSession.read(forAudio: XCTUnwrap(state.lastAudioPath)))
            let handoff = try XCTUnwrap(try pendingFiles(in: output).first { $0["meetingId"] as? String == derived.id })
            XCTAssertEqual(handoff["supersedesMeetingId"] as? String,
                           mismatch == "externalAudio" ? nil : id, "\(suffix): \(mismatch)")
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: legacyPath)), legacyData)
        }
    }

    func testLegacyImportUsesOriginalPCMEndWhenSidecarWasRecreated() async throws {
        let output = TestSupport.makeTempDir(self, "legacy-import-clock")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": output], home: output)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep.rawValue])
        let audio = try writeCapture(paths, "unknown-start")
        let originalEnd = TestSupport.fixedDate.addingTimeInterval(600)
        try FileManager.default.setAttributes([.modificationDate: originalEnd], ofItemAtPath: audio)
        try FileManager.default.setAttributes([.modificationDate: originalEnd.addingTimeInterval(3600)],
                                             ofItemAtPath: AudioFormatSidecar.path(forAudio: audio))
        let state = AppState(paths: paths, store: MeetingStore(path: paths.databasePath),
                             transcriptionRunner: { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 5, text: "transcripción")],
                                     engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
        })

        await state.importAudio(url: URL(fileURLWithPath: audio))

        let handoff = try XCTUnwrap(try pendingFiles(in: output).first)
        XCTAssertEqual(handoff["endedAt"] as? String, ISO8601.string(from: originalEnd))
        XCTAssertEqual(handoff["startedAt"] as? String, ISO8601.string(from: originalEnd.addingTimeInterval(-5)))
    }

    func testImportOfUnprocessedNativeCaptureUsesOriginalPCMEndInsteadOfInitialMetadataStart() async throws {
        let output = TestSupport.makeTempDir(self, "native-import-clock")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": output], home: output)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep.rawValue])
        let audio = try writeCapture(paths, "unprocessed-native")
        let originalId = try XCTUnwrap(RecordingRecovery.sessionId(forAudio: audio))
        let initialSession = MeetingSession(id: originalId, startedAt: TestSupport.fixedDate, title: nil)
        try initialSession.write(forAudio: audio)
        let metadataURL = URL(fileURLWithPath: MeetingSession.metadataPath(forAudio: audio))
        let originalMetadata = try Data(contentsOf: metadataURL)
        let originalEnd = TestSupport.fixedDate.addingTimeInterval(600)
        try FileManager.default.setAttributes([.modificationDate: originalEnd], ofItemAtPath: audio)
        try FileManager.default.setAttributes([.modificationDate: TestSupport.fixedDate],
                                             ofItemAtPath: AudioFormatSidecar.path(forAudio: audio))
        let state = AppState(paths: paths, store: MeetingStore(path: paths.databasePath),
                             transcriptionRunner: { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 5, text: "transcripción")],
                                     engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
        })

        await state.importAudio(url: URL(fileURLWithPath: audio))

        let handoff = try XCTUnwrap(try pendingFiles(in: output).first)
        XCTAssertNotEqual(handoff["meetingId"] as? String, originalId)
        XCTAssertEqual(handoff["supersedesMeetingId"] as? String, originalId)
        XCTAssertEqual(handoff["endedAt"] as? String, ISO8601.string(from: originalEnd))
        XCTAssertEqual(handoff["startedAt"] as? String, ISO8601.string(from: originalEnd.addingTimeInterval(-5)))
        XCTAssertEqual(try Data(contentsOf: metadataURL), originalMetadata)
        XCTAssertEqual(RecordingRecovery.modificationDate(audio), originalEnd)
    }

    func testNestedDerivedRestartRetainsEndEvidenceUntilDurationIsMeasured() async throws {
        let output = TestSupport.makeTempDir(self, "legacy-nested-clock")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": output], home: output)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep.rawValue])
        let audio = try writeCapture(paths, "nested-clock")
        let originalId = try XCTUnwrap(RecordingRecovery.sessionId(forAudio: audio))
        let originalEnd = TestSupport.fixedDate.addingTimeInterval(600)
        try FileManager.default.setAttributes([.modificationDate: originalEnd], ofItemAtPath: audio)
        try FileManager.default.setAttributes([.modificationDate: originalEnd.addingTimeInterval(3600)],
                                             ofItemAtPath: AudioFormatSidecar.path(forAudio: audio))
        let store = MeetingStore(path: paths.databasePath)
        var attemptedAudio: String?
        let failingRunner: AppStateTranscriptionRunner = { job, _ in
            await MainActor.run { attemptedAudio = job.audioPath }
            throw FakeEngineError()
        }
        let first = AppState(paths: paths, store: store, transcriptionRunner: failingRunner)
        await first.importAudio(url: URL(fileURLWithPath: audio))
        let firstCopy = try XCTUnwrap(attemptedAudio)
        let firstDerived = try XCTUnwrap(try MeetingSession.read(forAudio: firstCopy))
        XCTAssertEqual(firstDerived.sourceAudioEndedAt, originalEnd)
        try FileManager.default.setAttributes([.modificationDate: originalEnd.addingTimeInterval(7200)],
                                             ofItemAtPath: firstCopy)

        attemptedAudio = nil
        let second = AppState(paths: paths, store: store, transcriptionRunner: failingRunner)
        await second.importAudio(url: URL(fileURLWithPath: firstCopy))
        let secondCopy = try XCTUnwrap(attemptedAudio)
        let secondDerived = try XCTUnwrap(try MeetingSession.read(forAudio: secondCopy))
        XCTAssertNotEqual(secondDerived.id, firstDerived.id)
        XCTAssertEqual(secondDerived.sourceAudioEndedAt, originalEnd)
        XCTAssertEqual(secondDerived.supersedesMeetingId, originalId)
        XCTAssertEqual(store.count(), 0, "failed imports have not established an authoritative start")

        let measuredRunner: AppStateTranscriptionRunner = { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 5, text: "transcripción")],
                                     engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
        }
        let restarted = AppState(paths: paths, store: store, transcriptionRunner: measuredRunner)
        restarted.lastAudioPath = secondCopy
        await restarted.retranscribeLastAudio()
        let corrected = try XCTUnwrap(try MeetingSession.read(forAudio: secondCopy))
        let correctedTranscript = try XCTUnwrap(restarted.lastTranscriptPath)
        let correctedText = try Data(contentsOf: URL(fileURLWithPath: correctedTranscript))
        XCTAssertNil(corrected.sourceAudioEndedAt, "measured duration established the persisted source start")
        XCTAssertEqual(corrected.startedAtIsAuthoritative, true)
        XCTAssertEqual(corrected.startedAt, originalEnd.addingTimeInterval(-5))
        let correctedHandoff = try XCTUnwrap(try pendingFiles(in: output).first { $0["meetingId"] as? String == corrected.id })
        XCTAssertEqual(correctedHandoff["endedAt"] as? String, ISO8601.string(from: originalEnd))
        XCTAssertEqual(correctedHandoff["supersedesMeetingId"] as? String, originalId)

        let afterCorrection = AppState(paths: paths, store: store, transcriptionRunner: measuredRunner)
        await afterCorrection.importAudio(url: URL(fileURLWithPath: secondCopy))
        let finalDerived = try XCTUnwrap(try MeetingSession.read(forAudio: XCTUnwrap(afterCorrection.lastAudioPath)))
        let finalHandoff = try XCTUnwrap(try pendingFiles(in: output).first { $0["meetingId"] as? String == finalDerived.id })
        XCTAssertEqual(finalHandoff["startedAt"] as? String, ISO8601.string(from: originalEnd.addingTimeInterval(-5)))
        XCTAssertEqual(finalHandoff["endedAt"] as? String, ISO8601.string(from: originalEnd))
        XCTAssertEqual(finalHandoff["supersedesMeetingId"] as? String, originalId)
        XCTAssertEqual(store.count(), 2)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: correctedTranscript)), correctedText)
        XCTAssertEqual(RecordingRecovery.modificationDate(audio), originalEnd)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingSession.metadataPath(forAudio: audio)))
    }

    func testDerivedImportKeepsFrozenContextAndRootAncestryAcrossRestart() async throws {
        let output = TestSupport.makeTempDir(self, "frozen-import-lineage")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": output], home: output)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep.rawValue])
        let sourceAudio = output + "/source.pcm"
        TestSupport.write("pcm", to: sourceAudio)
        let event = CalendarEventSnapshot(
            id: "calendar-original", title: "Agenda original", start: TestSupport.fixedDate.addingTimeInterval(-30),
            end: TestSupport.fixedDate.addingTimeInterval(300), url: URL(string: "https://meet.google.com/abc-defg-hij"),
            notes: "fixture", attendees: [])
        let context = MeetingContext.capture(events: [event], at: TestSupport.fixedDate,
                                             activeBundleIDs: [], timeZone: "America/Argentina/Buenos_Aires")
        let original = MeetingSession(startedAt: TestSupport.fixedDate, context: context,
                                      startedAtIsAuthoritative: true)
        try original.write(forAudio: sourceAudio)
        let store = MeetingStore(path: paths.databasePath)
        let runner: AppStateTranscriptionRunner = { _, _ in
            TranscriptionJob.Outcome(segments: [Segment(start: 0, end: 5, text: "transcripción")],
                                     engineUsed: .parakeet, modelUsed: "fixture", audioDurationSec: 5)
        }
        let first = AppState(paths: paths, store: store, transcriptionRunner: runner)
        await first.importAudio(url: URL(fileURLWithPath: sourceAudio))
        let copiedAudio = try XCTUnwrap(first.lastAudioPath)
        let firstDerived = try XCTUnwrap(try MeetingSession.read(forAudio: copiedAudio))
        var changedOriginal = original
        changedOriginal.title = "Agenda posterior"
        changedOriginal.context = .unmatched(timeZone: "Europe/Madrid")
        try changedOriginal.write(forAudio: sourceAudio)

        let restarted = AppState(paths: paths, store: store, transcriptionRunner: runner)
        await restarted.importAudio(url: URL(fileURLWithPath: copiedAudio))

        let derived = try XCTUnwrap(try MeetingSession.read(forAudio: XCTUnwrap(restarted.lastAudioPath)))
        let handoff = try XCTUnwrap(try pendingFiles(in: output).first { $0["meetingId"] as? String == derived.id })
        XCTAssertNotEqual(derived.id, firstDerived.id)
        XCTAssertEqual(handoff["supersedesMeetingId"] as? String, original.id)
        XCTAssertEqual(handoff["title"] as? String, "Agenda original")
        XCTAssertEqual(handoff["timeZone"] as? String, "America/Argentina/Buenos_Aires")
        XCTAssertEqual((handoff["calendarEvent"] as? [String: Any])?["id"] as? String, "calendar-original")
        XCTAssertEqual(handoff["version"] as? Int, 3)
        XCTAssertEqual(handoff["startedAt"] as? String, ISO8601.string(from: TestSupport.fixedDate))
        XCTAssertEqual(handoff["endedAt"] as? String, ISO8601.string(from: TestSupport.fixedDate.addingTimeInterval(5)))
    }


    func testPartialTranscriptKeepsAudioAndCheckpointsAndShowsError() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-partial")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.deleteAfterHandoff.rawValue])
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath), recordingDriver: backend.driver,
            transcriptionRunner: Self.runner(calls) { _ in Self.gappedOutcome },
            errorDismissalDelay: 300, recoveryRetryDelays: [3_600, 3_600])

        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.stopRecording()
        try await waitUntil { state.phase == .done }

        let audio = try XCTUnwrap(backend.outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio), "retention must not delete audio with gaps")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ChunkedTranscription.workDirectory(forAudio: audio)))
        XCTAssertTrue(RecordingRecovery.hasGaps(audioPath: audio))
        XCTAssertEqual(RecordingRecovery.attempts(forAudio: audio), 1, "the gapped run counts as an attempt")
        let pending = try XCTUnwrap(try pendingFiles(in: outputDir).first)
        XCTAssertTrue(pending["audioPath"] is NSNull, "the dispatcher must not delete audio a retry needs")
        XCTAssertEqual(state.lastAudioPath, audio)
    }

    func testGappedCaptureIsRetriedAndReplacesItsTranscriptRowAndHandoff() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-gap-retry")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.deleteAfterHandoff.rawValue])
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        backend.writesRecoverableCapture = true
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: backend.driver,
            transcriptionRunner: Self.runner(calls) { $0 == 1 ? Self.gappedOutcome : Self.completeOutcome },
            errorDismissalDelay: 300, recoveryRetryDelays: [0.05, 0.05])

        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.stopRecording()
        try await waitUntil { state.phase == .done }
        let audio = try XCTUnwrap(backend.outputPath)
        let id = try XCTUnwrap(RecordingRecovery.sessionId(forAudio: audio))
        let title = try XCTUnwrap(store.record(id: id)).title

        try await waitUntil { calls.value == 2 && !state.isRecovering }

        XCTAssertEqual(store.count(), 1, "the retry replaces the meeting instead of adding one")
        let record = try XCTUnwrap(store.record(id: id))
        XCTAssertEqual(record.title, title)
        XCTAssertFalse(record.transcriptText.contains("fragmento sin transcribir"))
        let transcript = try String(contentsOfFile: RecordingRecovery.transcriptPath(forAudio: audio), encoding: .utf8)
        XCTAssertTrue(transcript.contains("y cerramos"))
        let pendings = try pendingFiles(in: outputDir)
        XCTAssertEqual(pendings.count, 1)
        XCTAssertEqual(pendings.first?["meetingId"] as? String, id)
        XCTAssertEqual(pendings.first?["audioPath"] as? String, audio)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChunkedTranscription.workDirectory(forAudio: audio)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingRecovery.attemptsPath(forAudio: audio)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio), "complete now: retention applies")
        XCTAssertTrue(state.recoverableRecordings.isEmpty)
    }

    func testGapRetriesStopAtTheAttemptCap() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-gap-cap")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        try FileManager.default.createDirectory(atPath: paths.transcriptsDir, withIntermediateDirectories: true)
        let audio = paths.transcriptsDir + "/recording-meet-1789474169-cap.pcm"
        try Data(count: RecordingRecovery.minimumBytes).write(to: URL(fileURLWithPath: audio))
        try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "t").write(forAudio: audio)
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: Self.runner(calls) { _ in Self.gappedOutcome },
            recoveryRetryDelays: [0.05, 0.05, 0.05, 0.05])

        state.recoverRecordings(automaticOnly: true)
        try await waitUntil { calls.value == RecordingRecovery.maxAutomaticAttempts && !state.isRecovering }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(calls.value, RecordingRecovery.maxAutomaticAttempts, "no automatic attempt past the cap")
        XCTAssertEqual(RecordingRecovery.attempts(forAudio: audio), RecordingRecovery.maxAutomaticAttempts)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(try pendingFiles(in: outputDir).map { $0["meetingId"] as? String }, ["meet-1789474169-cap"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
        XCTAssertEqual(state.recoverableRecordings.map(\.audioPath), [audio], "still offered for a manual retry")
        XCTAssertTrue(RecordingRecovery.automatic(state.recoverableRecordings).isEmpty)
        XCTAssertEqual(state.exhaustedRecordingCount, 1)
        XCTAssertNil(RecordingRecovery.nextAttemptAt(forAudio: audio))
    }

    /// Silence is terminal: one attempt, audio kept, no history, no retries.
    func testSilentCaptureIsSettledWithoutHistoryOrRetries() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-silent")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.deleteAfterHandoff.rawValue])
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        backend.writesRecoverableCapture = true
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: backend.driver,
            transcriptionRunner: { job, _ in
                calls.increment()
                try FileManager.default.createDirectory(
                    atPath: ChunkedTranscription.workDirectory(forAudio: job.audioPath),
                    withIntermediateDirectories: true)
                throw TranscriptionError.noSpeech
            },
            errorDismissalDelay: 300, recoveryRetryDelays: [0.05, 0.05])

        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.stopRecording()
        try await waitUntil { state.phase == .idle && state.errorMessage != nil }
        try await Task.sleep(nanoseconds: 400_000_000)

        let audio = try XCTUnwrap(backend.outputPath)
        XCTAssertEqual(calls.value, 1, "silence is never retried automatically")
        XCTAssertEqual(state.errorMessage, TranscriptionError.noSpeech.errorDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio), "the audio is kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChunkedTranscription.workDirectory(forAudio: audio)))
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(try pendingFiles(in: outputDir).isEmpty)
        XCTAssertTrue(RecordingRecovery.isSilent(forAudio: audio))
        XCTAssertNil(RecordingRecovery.nextAttemptAt(forAudio: audio))
        XCTAssertEqual(state.recoverableRecordings.map(\.audioPath), [audio], "still offered for a manual run")
        XCTAssertEqual(state.exhaustedRecordingCount, 0, "silence is not an exhausted failure")
    }

    func testRecoveryOfASilentOrphanSettlesItInOneAttempt() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-silent-recovery")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let audio = try writeCapture(paths, "silent")
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: { _, _ in calls.increment(); throw TranscriptionError.noSpeech },
            recoveryRetryDelays: [0.05, 0.05])

        state.recoverRecordings(automaticOnly: true)
        try await waitUntil { calls.value == 1 && !state.isRecovering }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(calls.value, 1)
        XCTAssertTrue(RecordingRecovery.isSilent(forAudio: audio))
        XCTAssertTrue(RecordingRecovery.automatic(state.recoverableRecordings).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(state.errorMessage, TranscriptionError.noSpeech.errorDescription)
    }

    func testSilentRetryOfPartialCaptureKeepsAudioAndAllowsManualCompletion() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-gap-to-silence")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false,
                     Settings.Key.retention.rawValue: RetentionPolicy.keep24h.rawValue])
        let audio = try writeCapture(paths, "gap-to-silence")
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: { _, _ in
                calls.increment()
                if calls.value == 1 {
                    return TranscriptionJob.Outcome(
                        segments: [Segment(start: 0, end: 10, text: "[fragmento sin transcribir]")],
                        engineUsed: .parakeet, modelUsed: "fixture", failedChunks: 1)
                }
                if calls.value == 2 || calls.value == 3 { throw TranscriptionError.noSpeech }
                if calls.value == 4 { throw FakeEngineError() }
                if calls.value == 5 { throw CancellationError() }
                return Self.completeOutcome
            }, recoveryRetryDelays: [3_600, 3_600])

        state.recoverRecordings(automaticOnly: true)
        try await waitUntil { calls.value == 1 && !state.isRecovering }
        for attempt in 2...5 {
            state.recoverRecordings(automaticOnly: false)
            try await waitUntil { calls.value == attempt && !state.isRecovering }

            XCTAssertTrue(RecordingRecovery.isSilent(forAudio: audio))
            XCTAssertTrue(RecordingRecovery.needsTranscript(audioPath: audio))
            let available = try XCTUnwrap(state.recoverableRecordings.first)
            XCTAssertEqual(available.audioPath, audio)
            XCTAssertTrue(RecordingRecovery.automatic(state.recoverableRecordings).isEmpty)
            Retention.cleanupOldRecordings(in: paths.transcriptsDir, policy: .keep24h,
                                          now: Date().addingTimeInterval(90_000))
            XCTAssertTrue(FileManager.default.fileExists(atPath: audio), "a partial marker must not authorize deletion")
            XCTAssertEqual(store.count(), 1, "silence and failed attempts create no replacement history row")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ChunkedTranscription.workDirectory(forAudio: audio)))

        state.recoverRecordings(automaticOnly: false)
        try await waitUntil { !state.isRecovering }
        XCTAssertEqual(calls.value, 6, "the silent capture remains available through failed manual attempts")
        XCTAssertFalse(RecordingRecovery.needsTranscript(audioPath: audio))
        XCTAssertTrue(state.recoverableRecordings.isEmpty)
        XCTAssertEqual(store.count(), 1)
    }

    private func writeCapture(_ paths: AppPaths, _ suffix: String) throws -> String {
        try FileManager.default.createDirectory(atPath: paths.transcriptsDir, withIntermediateDirectories: true)
        let audio = paths.transcriptsDir + "/recording-meet-1789474169-\(suffix).pcm"
        try Data(count: RecordingRecovery.minimumBytes).write(to: URL(fileURLWithPath: audio))
        try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "t").write(forAudio: audio)
        return audio
    }

    func testPersistedRetryTimeSurvivesARelaunch() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-retry-relaunch")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let audio = try writeCapture(paths, "relaunch")
        // The previous process failed it and saved the next retry time.
        RecordingRecovery.recordFailure(audioPath: audio, reason: "engine failed", retryDelays: [1.0])
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath),
            recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: Self.runner(calls) { _ in Self.completeOutcome },
            recoveryRetryDelays: [3_600, 3_600])

        state.recoverRecordings(automaticOnly: true)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(calls.value, 0, "not before the saved retry time")

        try await waitUntil { calls.value == 1 && !state.isRecovering }
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingRecovery.attemptsPath(forAudio: audio)))
    }

    func testEachCaptureIsRetriedAtItsOwnTime() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-retry-own-time")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let a = try writeCapture(paths, "a"), b = try writeCapture(paths, "b"), c = try writeCapture(paths, "c")
        RecordingRecovery.recordFailure(audioPath: a, reason: "engine failed", retryDelays: [0.2])
        // Comes due while a's job runs.
        RecordingRecovery.recordFailure(audioPath: b, reason: "engine failed", retryDelays: [0.5])
        RecordingRecovery.recordFailure(audioPath: c, reason: "engine failed", retryDelays: [3_600])
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath),
            recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: { job, _ in
                calls.increment()
                try FileManager.default.createDirectory(
                    atPath: ChunkedTranscription.workDirectory(forAudio: job.audioPath),
                    withIntermediateDirectories: true)
                if job.audioPath == a { try await Task.sleep(nanoseconds: 800_000_000) }
                return Self.completeOutcome
            },
            recoveryRetryDelays: [3_600, 3_600])

        state.recoverRecordings(automaticOnly: true)
        try await waitUntil { calls.value == 2 && !state.isRecovering }
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(calls.value, 2, "c is not due yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingRecovery.attemptsPath(forAudio: a)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingRecovery.attemptsPath(forAudio: b)))
        XCTAssertEqual(RecordingRecovery.attempts(forAudio: c), 1)
    }

    func testQueuedCaptureIsRecheckedBeforeItsTurn() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-retry-recheck")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let a = try writeCapture(paths, "a"), b = try writeCapture(paths, "b")
        // Older audio goes second in the pass.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: b)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath),
            recordingDriver: FakeRecordingBackend().driver,
            transcriptionRunner: { job, _ in
                calls.increment()
                try FileManager.default.createDirectory(
                    atPath: ChunkedTranscription.workDirectory(forAudio: job.audioPath),
                    withIntermediateDirectories: true)
                if job.audioPath == a { try await Task.sleep(nanoseconds: 600_000_000) }
                return Self.completeOutcome
            },
            recoveryRetryDelays: [3_600, 3_600])

        state.recoverRecordings(automaticOnly: true)
        try await waitUntil { calls.value == 1 }
        // Meanwhile another job on b failed and moved its retry time.
        RecordingRecovery.recordFailure(audioPath: b, reason: "engine failed", retryDelays: [3_600])
        try await waitUntil { !state.isRecovering }

        XCTAssertEqual(calls.value, 1, "b waits for its new retry time")
        XCTAssertEqual(RecordingRecovery.attempts(forAudio: b), 1)
    }

    func testFailedRerunOfACompleteCaptureIsNotARecoveryAttempt() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-rerun-complete")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: MeetingStore(path: paths.databasePath), recordingDriver: backend.driver,
            transcriptionRunner: { _, _ in
                calls.increment()
                guard calls.value == 1 else { throw FakeEngineError() }
                return Self.completeOutcome
            },
            errorDismissalDelay: 300, recoveryRetryDelays: [3_600, 3_600])
        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.stopRecording()
        try await waitUntil { state.phase == .done }
        let audio = try XCTUnwrap(backend.outputPath)

        for _ in 0..<RecordingRecovery.maxAutomaticAttempts { await state.retranscribeLastAudio() }

        XCTAssertEqual(calls.value, 1 + RecordingRecovery.maxAutomaticAttempts)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingRecovery.attemptsPath(forAudio: audio)))
        XCTAssertTrue(state.recoverableRecordings.isEmpty)
        XCTAssertEqual(state.exhaustedRecordingCount, 0)
    }

    func testRetranscribingAGappedCaptureReplacesItInPlace() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-gap-manual")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: backend.driver,
            transcriptionRunner: Self.runner(calls) { $0 == 1 ? Self.gappedOutcome : Self.completeOutcome },
            errorDismissalDelay: 300, recoveryRetryDelays: [3_600, 3_600])
        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.stopRecording()
        try await waitUntil { state.phase == .done }
        let audio = try XCTUnwrap(backend.outputPath)

        await state.retranscribeLastAudio()

        XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(state.lastTranscriptPath, RecordingRecovery.transcriptPath(forAudio: audio))
        XCTAssertEqual(try pendingFiles(in: outputDir).map { $0["meetingId"] as? String },
                       [RecordingRecovery.sessionId(forAudio: audio)])
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(RecordingRecovery.hasGaps(audioPath: audio))
    }

    func testRetranscribeWaitsForABackgroundRecoveryOfTheSameCapture() async throws {
        let outputDir = TestSupport.makeTempDir(self, "app-gap-race")
        let paths = AppPaths(environment: ["MEETCAPTURE_TEST_OUTPUT_DIR": outputDir], home: outputDir)
        useSettings([Settings.Key.notifyHermes.rawValue: false])
        let backend = FakeRecordingBackend()
        backend.suspendStart = false
        backend.writesRecoverableCapture = true
        let store = MeetingStore(path: paths.databasePath)
        let calls = TranscriptionCallCounter()
        let gate = TranscriptionCallCounter()
        let state = AppState(
            paths: paths, store: store, recordingDriver: backend.driver,
            transcriptionRunner: { job, _ in
                calls.increment()
                try FileManager.default.createDirectory(
                    atPath: ChunkedTranscription.workDirectory(forAudio: job.audioPath),
                    withIntermediateDirectories: true)
                guard calls.value > 1 else { return Self.gappedOutcome }
                while gate.value == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
                return Self.completeOutcome
            },
            errorDismissalDelay: 300, recoveryRetryDelays: [0.05, 0.05])
        state.startRecording()
        try await waitUntil { backend.isRecording }
        state.stopRecording()
        try await waitUntil { state.phase == .done }
        try await waitUntil { calls.value == 2 && state.isRecovering }

        await state.retranscribeLastAudio()

        XCTAssertEqual(calls.value, 2, "no second job on a capture being recovered")
        gate.increment()
        try await waitUntil { !state.isRecovering }
        XCTAssertEqual(store.count(), 1)
        XCTAssertFalse(RecordingRecovery.hasGaps(audioPath: try XCTUnwrap(backend.outputPath)))
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
    /// Writes a capture big enough, with its sidecar, for recovery to pick up.
    var writesRecoverableCapture = false
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
        if writesRecoverableCapture {
            try Data(count: RecordingRecovery.minimumBytes).write(to: URL(fileURLWithPath: path))
            try AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "t").write(forAudio: path)
        } else {
            try Data("fixture pcm".utf8).write(to: URL(fileURLWithPath: path))
        }
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

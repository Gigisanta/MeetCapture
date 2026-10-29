// AppState.swift
// Single source of truth for the UI. Owns the services, applies the
// detection policy, and orchestrates record → transcribe → post-process.

import AppKit
import Combine
import Foundation
import SwiftUI

typealias AppStateTranscriptionRunner =
    @Sendable (TranscriptionJob, @escaping @Sendable (Double) -> Void) async throws -> TranscriptionJob.Outcome

@MainActor
struct AppStateRecordingDriver {
    let checkPermission: () -> Bool
    let openPrivacySettings: () -> Void
    let isRecording: () -> Bool
    let currentSampleRate: () -> Double
    let start: (String, TapConfiguration) async throws -> Void
    let stop: () async throws -> String?

    static func live(recorder: RecordingCoordinator) -> Self {
        Self(
            checkPermission: { recorder.audioCapture.checkPermission() },
            openPrivacySettings: { recorder.audioCapture.openPrivacySettings() },
            isRecording: { recorder.isRecording },
            currentSampleRate: { recorder.audioCapture.currentSampleRate },
            start: { outputPath, configuration in
                try await recorder.start(outputPath: outputPath, configuration: configuration)
            },
            stop: { try await recorder.stop() })
    }
}

@MainActor
final class AppState: ObservableObject {
    // MARK: - Published

    @Published var phase: AppPhase = .idle
    @Published var currentMeeting: Meeting?
    @Published var errorMessage: String? {
        didSet {
            errorDismissalTask?.cancel()
            errorDismissalTask = nil
            guard let message = errorMessage else { return }
            errorDismissalTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64((self?.errorDismissalDelay ?? 10) * 1_000_000_000))
                } catch {
                    return
                }
                guard let self, self.errorMessage == message else { return }
                self.errorMessage = nil
            }
        }
    }
    @Published var hasCalendarAccess = false
    @Published var hasAudioPermission = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var transcriptionProgress: Double = 0
    @Published var lastTranscriptPath: String?
    @Published var lastSegments: [Segment] = []
    @Published var lastAudioPath: String?
    @Published var history: [MeetingSummary] = []
    @Published var historyQuery = "" {
        didSet {
            guard historyQuery != oldValue else { return }
            searchHistory(historyQuery)
        }
    }
    @Published var meetingNotes = "" {
        didSet {
            guard meetingNotes != oldValue, phase == .recording, let session else { return }
            do {
                try MeetingNotesStore.save(meetingNotes, meetingId: session.id, meetingsDir: paths.meetingsDir)
            } catch {
                meetingNotes = oldValue
                errorMessage = error.localizedDescription
            }
        }
    }
    @Published private(set) var recordingOrigin: RecordingOrigin?
    @Published private(set) var isStartingRecording = false
    /// A channel of the current capture that has delivered only digital
    /// silence: a missing permission or a dead device, not a quiet room.
    @Published private(set) var captureWarning: CaptureWarning?
    /// Captures that never reached a transcript (quit, crash, failed job).
    @Published private(set) var recoverableRecordings: [RecoverableRecording] = []
    @Published private(set) var isRecovering = false

    // MARK: - Services

    let paths: AppPaths
    let calendarService: CalendarService
    let callDetector: CallDetector
    let recorder: RecordingCoordinator
    let store: MeetingStore
    var audioCapture: AudioCaptureService { recorder.audioCapture }

    private let postProcessor: PostProcessor
    private let recordingDriver: AppStateRecordingDriver
    private let transcriptionRunner: AppStateTranscriptionRunner
    private var session: MeetingSession?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingStopTask: Task<Void, Never>?
    private var stopRequested = false
    private var scheduledStart: DispatchWorkItem?
    private var historySearchTask: Task<Void, Never>?
    private var historySearchGeneration: UInt = 0
    private var errorDismissalTask: Task<Void, Never>?
    private let errorDismissalDelay: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var activeCapturePath: String?
    private var recoveringPath: String?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryWakeTask: Task<Void, Never>?
    private let recoveryRetryDelays: [TimeInterval]
    private var systemAudioHeard = false
    private var lastLevelCheck: TimeInterval = 0
    private let logger = AppInfo.logger("AppState")

    init(paths: AppPaths = .current, store: MeetingStore = .shared,
         recordingDriver: AppStateRecordingDriver? = nil,
         transcriptionRunner: AppStateTranscriptionRunner? = nil,
         errorDismissalDelay: TimeInterval = 10,
         recoveryRetryDelays: [TimeInterval] = RecordingRecovery.retryDelays) {
        self.paths = paths
        self.calendarService = CalendarService()
        self.callDetector = CallDetector()
        let recorder = RecordingCoordinator()
        self.recorder = recorder
        self.store = store
        postProcessor = PostProcessor(store: store)
        self.recordingDriver = recordingDriver ?? .live(recorder: recorder)
        self.transcriptionRunner = transcriptionRunner ?? { job, progress in
            try await TranscriptionWorkerClient.shared.run(job, progress: progress)
        }
        self.errorDismissalDelay = max(0, errorDismissalDelay)
        self.recoveryRetryDelays = recoveryRetryDelays
        bind()
    }

    // MARK: - Lifecycle

    func startup() async {
        // The microphone gates recording; the calendar only feeds
        // auto-start, so its prompt must never delay the mic check.
        refreshPermissions()
        if !hasAudioPermission, audioCapture.canRequestPermission() { requestMicAccess() }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.calendarService.requestAccess()
            self.hasCalendarAccess = self.calendarService.isAuthorized
        }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshPermissions() }
            .store(in: &cancellables)
        Notifier.requestAuthorization()
        callDetector.start()
        Retention.cleanupOldRecordings(in: paths.transcriptsDir, policy: Settings.retention)
        refreshHistory()
        recoverRecordings(automaticOnly: true)
    }

    func shutdown() {
        callDetector.stop()
        if phase == .recording { stopRecording() }
    }

    /// True while quitting would cut a capture short.
    var needsGracefulShutdown: Bool { recordingStartTask != nil || recordingDriver.isRecording() }

    /// Finishes the PCM file and its sidecar without transcribing: the
    /// capture stays an orphan that startup recovery picks up next launch.
    func shutdownGracefully(timeout: TimeInterval = 15) async {
        callDetector.stop()
        recoveryTask?.cancel()
        if let start = recordingStartTask { await start.value }
        if recordingStopTask == nil, recordingDriver.isRecording() {
            _ = try? await recordingDriver.stop()
        } else {
            let deadline = Date().addingTimeInterval(timeout)
            while recordingDriver.isRecording(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        recordingStopTask?.cancel()
        resetRecordingState()
    }

    func refreshPermissions() {
        hasAudioPermission = recordingDriver.checkPermission()
    }

    /// Asks when macOS still can; after a denial only System Settings can
    /// grant it, so the button opens the Microphone pane instead.
    func requestMicAccess(thenStart origin: RecordingOrigin? = nil) {
        guard audioCapture.canRequestPermission() else {
            recordingDriver.openPrivacySettings()
            return
        }
        audioCapture.requestPermission { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasAudioPermission = granted
                if granted, let origin { self.startRecording(origin: origin) }
            }
        }
    }

    // MARK: - Recording

    func startRecording(origin: RecordingOrigin = .manual) {
        guard phase != .recording, phase != .transcribing,
              recordingStartTask == nil, recordingStopTask == nil else { return }
        errorMessage = nil
        hasAudioPermission = recordingDriver.checkPermission()
        guard hasAudioPermission else {
            errorMessage = Strings.errorNoMicPermission
            requestMicAccess(thenStart: origin)
            return
        }
        let startedAt = Date()
        let context = calendarService.captureContext(at: startedAt, activeBundleIDs: callDetector.activeCallBundleIDs())
        let session = MeetingSession(startedAt: startedAt, title: context.calendarEvent?.title, context: context)
        self.session = session
        meetingNotes = ""
        isStartingRecording = true
        phase = .recording
        recordingOrigin = origin
        recordingDuration = 0
        captureWarning = nil
        systemAudioHeard = false
        lastLevelCheck = 0
        if origin != .liveCall { callDetector.reconcileSuspended = true }

        let outputPath = "\(paths.transcriptsDir)/recording-\(session.id).pcm"
        activeCapturePath = outputPath
        let configuration = TapConfiguration(
            micOnly: Settings.micOnlyMode, inputDeviceUID: Settings.inputDeviceUID)
        stopRequested = false
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if !FileManager.default.fileExists(atPath: outputPath) {
                    try? FileManager.default.removeItem(atPath: MeetingSession.metadataPath(forAudio: outputPath))
                }
            }
            do {
                try session.write(forAudio: outputPath)
                try await self.recordingDriver.start(outputPath, configuration)
            } catch is CancellationError {
                guard self.session?.id == session.id else { return }
                self.recordingStartTask = nil
                self.isStartingRecording = false
                self.resetRecordingState()
                return
            } catch let error as CaptureError {
                guard self.session?.id == session.id else { return }
                self.recordingStartTask = nil
                self.isStartingRecording = false
                if case .startCancelled = error {
                    self.resetRecordingState()
                } else {
                    self.errorMessage = Strings.errorRecording(error.localizedDescription)
                    self.resetRecordingState()
                }
                return
            } catch {
                guard self.session?.id == session.id else { return }
                self.recordingStartTask = nil
                self.isStartingRecording = false
                self.errorMessage = Strings.errorRecording(error.localizedDescription)
                self.resetRecordingState()
                return
            }

            guard self.session?.id == session.id else {
                // A stale start must never outlive the state that requested it.
                self.recordingStartTask = nil
                self.isStartingRecording = false
                if self.recordingDriver.isRecording() { _ = try? await self.recordingDriver.stop() }
                return
            }
            self.recordingStartTask = nil
            self.isStartingRecording = false
            if self.stopRequested {
                self.stopRequested = false
                self.beginStopRecording(session: session)
            }
        }
    }

    func stopRecording() {
        guard let session else { return }
        let decision = RecordingStopDecision.decide(
            phase: phase, hasSession: true,
            startPending: recordingStartTask != nil, recorderIsRecording: recordingDriver.isRecording())
        guard decision != .ignored else { return }
        phase = .transcribing
        transcriptionProgress = 0
        recordingOrigin = nil
        captureWarning = nil
        callDetector.reconcileSuspended = false
        stopRequested = true
        if decision == .beginStop {
            stopRequested = false
            beginStopRecording(session: session)
        }
    }

    private func beginStopRecording(session: MeetingSession) {
        guard recordingStopTask == nil else { return }
        recordingStopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.recordingStopTask = nil
                self.stopRequested = false
            }
            guard self.session?.id == session.id else { return }
            let audioPath: String?
            do {
                audioPath = try await self.recordingDriver.stop()
            } catch {
                self.errorMessage = Strings.errorRecording(error.localizedDescription)
                self.resetRecordingState()
                return
            }
            guard let audioPath else {
                self.errorMessage = Strings.errorNoRecording
                self.resetRecordingState()
                return
            }
            await self.transcribe(session: session, audioPath: audioPath, durableAudioPath: audioPath,
                                  transcriptPath: RecordingRecovery.transcriptPath(forAudio: audioPath),
                                  applyRetention: true)
            if self.activeCapturePath == audioPath { self.activeCapturePath = nil }
            self.scanRecoverableRecordings()
            self.scheduleRecoveryWake()
        }
    }

    private func resetRecordingState() {
        phase = .idle
        recordingOrigin = nil
        isStartingRecording = false
        callDetector.reconcileSuspended = false
        stopRequested = false
        session = nil
        meetingNotes = ""
        activeCapturePath = nil
        captureWarning = nil
    }

    // MARK: - Transcription


    private func makeJob(audioPath: String, captureSampleRate: Double) -> TranscriptionJob {
        TranscriptionJob(audioPath: audioPath, captureSampleRate: captureSampleRate,
                         language: Settings.asrLanguage, diarize: Settings.diarize,
                         aliases: LocalConfig.load(path: paths.configFile).aliases)
    }

    private func transcribe(session: MeetingSession, audioPath: String, durableAudioPath: String,
                            transcriptPath: String, applyRetention: Bool) async {
        errorMessage = nil
        phase = .transcribing
        transcriptionProgress = 0
        let job = makeJob(audioPath: audioPath, captureSampleRate: recordingDriver.currentSampleRate())
        let input = PostProcessInput(
            session: session, segments: [], transcriptPath: transcriptPath, capturePath: audioPath,
            durableAudioPath: durableAudioPath, engine: .parakeet, model: ParakeetEngine.modelName,
            language: Settings.asrLanguage, applyRetention: applyRetention,
            retention: Settings.retention, meetingsDir: paths.meetingsDir,
            audioEndedAt: applyRetention ? RecordingRecovery.modificationDate(audioPath) : Date())
        do {
            let progressSink: @Sendable (Double) -> Void = { [weak self] progress in
                guard let self else { return }
                Task { @MainActor in self.transcriptionProgress = progress }
            }
            let outcome = try await transcriptionRunner(job, progressSink)
            try Task.checkCancellation()
            var finalInput = input
            finalInput.segments = outcome.segments
            finalInput.engine = outcome.engineUsed
            finalInput.model = outcome.modelUsed
            finalInput.audioDurationSec = outcome.audioDurationSec
            finalInput.quality = outcome.quality
            finalInput.partial = outcome.failedChunks > 0
            if finalInput.partial { try RecordingRecovery.markGaps(audioPath: audioPath, chunks: outcome.failedChunks) }
            let result = try await postProcessor.run(finalInput)
            if outcome.failedChunks > 0 {
                errorMessage = Strings.errorPartialTranscript(outcome.failedChunks)
                // A capture with gaps is retried like a failed one; the
                // checkpoints let the retry redo only the gaps.
                if applyRetention {
                    await recordRecoveryFailure(audioPath: audioPath, reason: Self.gapReason(outcome.failedChunks),
                                                countsAsAttempt: true, title: session.displayTitle)
                }
            } else {
                ChunkedTranscription.removeWork(forAudio: audioPath)
                if applyRetention { try? FileManager.default.removeItem(atPath: RecordingRecovery.attemptsPath(forAudio: audioPath)) }
            }
            Retention.cleanupOldRecordings(in: paths.transcriptsDir, policy: Settings.retention)

            lastTranscriptPath = transcriptPath
            lastSegments = outcome.segments
            lastAudioPath = FileManager.default.fileExists(atPath: durableAudioPath) ? durableAudioPath : nil
            transcriptionProgress = 1
            phase = .done
            refreshHistory()
            logger.info("transcripción lista: \(result.pendingPath, privacy: .public)")
            if Settings.notifyHermes { await Notifier.transcriptReady(title: session.displayTitle) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.phase == .done else { return }
                self.phase = .idle
                self.currentMeeting = nil
            }
        } catch is CancellationError {
            logger.info("transcripción cancelada")
            phase = .idle
            transcriptionProgress = 0
            recordingOrigin = nil
            callDetector.reconcileSuspended = false
            self.session = nil
        } catch TranscriptionError.noSpeech {
            logger.info("transcripción sin habla")
            errorMessage = TranscriptionError.noSpeech.errorDescription
            phase = .idle
            transcriptionProgress = 0
            self.session = nil
            settleSilent(audioPath: audioPath, isCapture: applyRetention)
        } catch {
            logger.error("transcripción falló: \(error.localizedDescription, privacy: .public)")
            errorMessage = Strings.errorTranscription(error.localizedDescription)
            phase = .idle
            self.session = nil
            // A capture that failed is a recovery like any other: count it
            // and retry later, resuming from the chunks already done.
            if applyRetention {
                await recordRecoveryFailure(audioPath: audioPath, reason: error.localizedDescription,
                                            countsAsAttempt: true, title: session.displayTitle)
            }
        }
    }

    func importAudio(url: URL) async {
        guard phase == .idle || phase == .done else { return }
        errorMessage = nil
        phase = .transcribing
        transcriptionProgress = 0
        do {
            let source = try existingSession(audioPath: url.path, startedAt: Date(), fallbackTitle: nil)
            let prepared = try await AudioImporter.prepare(url: url, importsDir: paths.importsDir)
            let importedAt = Date()
            let session = MeetingSession(
                startedAt: source?.startedAt ?? importedAt,
                title: source == nil ? prepared.title : source?.title,
                context: source?.context ?? .unmatched(),
                supersedesMeetingId: source.map { $0.supersedesMeetingId ?? $0.id },
                sourceAudioEndedAt: source?.sourceAudioEndedAt ?? (source == nil ? importedAt : nil),
                startedAtIsAuthoritative: source?.startedAtIsAuthoritative)
            try session.write(forAudio: prepared.durableAudioPath)
            self.session = session
            await transcribe(session: session, audioPath: prepared.workPath,
                             durableAudioPath: prepared.durableAudioPath,
                             transcriptPath: prepared.transcriptPath, applyRetention: false)
        } catch is CancellationError {
            phase = .idle
            transcriptionProgress = 0
            self.session = nil
        } catch {
            errorMessage = Strings.errorImport(error.localizedDescription)
            phase = .idle
            self.session = nil
        }
    }

    func retranscribeLastAudio() async {
        guard phase == .idle || phase == .done else { return }
        guard let audio = lastAudioPath else { errorMessage = Strings.errorNoAudio; return }
        guard FileManager.default.fileExists(atPath: audio) else { errorMessage = Strings.errorAudioGone; return }
        // Two jobs on one capture would share and delete each other's channel WAVs.
        guard audio != recoveringPath else { errorMessage = Strings.errorAudioRecovering; return }
        do {
            let source = try existingSession(audioPath: audio, startedAt: Date(), fallbackTitle: nil)
            let isCapture = (audio as NSString).deletingLastPathComponent == paths.transcriptsDir
                && RecordingRecovery.sessionId(forAudio: audio) != nil
            let session: MeetingSession
            let transcript: String
            if isCapture {
                session = source ?? MeetingSession(startedAt: Date())
                transcript = RecordingRecovery.transcriptPath(forAudio: audio)
                activeCapturePath = audio
            } else {
                let importedAt = Date()
                session = MeetingSession(
                    startedAt: source?.startedAt ?? importedAt, title: source?.title,
                    context: source?.context ?? .unmatched(),
                    supersedesMeetingId: source.map { $0.supersedesMeetingId ?? $0.id },
                    sourceAudioEndedAt: source?.sourceAudioEndedAt ?? (source == nil ? importedAt : nil),
                    startedAtIsAuthoritative: source?.startedAtIsAuthoritative)
                transcript = "\(paths.transcriptsDir)/\(session.id).txt"
                try session.write(forAudio: audio)
            }
            self.session = session
            await transcribe(session: session, audioPath: audio, durableAudioPath: audio,
                             transcriptPath: transcript, applyRetention: isCapture)
            if activeCapturePath == audio { activeCapturePath = nil }
            scanRecoverableRecordings()
            scheduleRecoveryWake()
        } catch {
            errorMessage = Strings.errorImport(error.localizedDescription)
        }
    }

    // MARK: - Recovery

    func scanRecoverableRecordings() {
        let busy = Set([activeCapturePath, recoveringPath].compactMap { $0 })
        recoverableRecordings = RecordingRecovery.find(in: paths.transcriptsDir, excluding: busy)
    }

    /// Transcribes orphaned captures in the background, one at a time,
    /// without touching `phase`: recording stays available meanwhile.
    /// `automaticOnly` limits it to recent captures under the retry cap.
    func recoverRecordings(automaticOnly: Bool) {
        scanRecoverableRecordings()
        guard recoveryTask == nil else { return }
        let targets = automaticOnly
            ? RecordingRecovery.automatic(recoverableRecordings) : recoverableRecordings
        guard !targets.isEmpty else { scheduleRecoveryWake(); return }
        recoveryWakeTask?.cancel()
        recoveryWakeTask = nil
        isRecovering = true
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for recording in targets where !Task.isCancelled {
                // One job at a time: wait for the foreground one.
                while self.phase == .transcribing, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard !Task.isCancelled else { break }
                // A job that ran meanwhile (Re-transcribir) may have moved its
                // retry time or used up its attempts: re-read them before its turn.
                if automaticOnly {
                    var current = recording
                    current.attempts = RecordingRecovery.attempts(forAudio: recording.audioPath)
                    current.nextAttemptAt = RecordingRecovery.nextAttemptAt(forAudio: recording.audioPath)
                    guard !RecordingRecovery.automatic([current]).isEmpty else { continue }
                }
                await self.recover(recording)
            }
            self.recoveringPath = nil
            self.isRecovering = false
            self.recoveryTask = nil
            self.scanRecoverableRecordings()
            self.refreshHistory()
            guard !Task.isCancelled else { return }
            self.scheduleRecoveryWake(justTried: Set(targets.map(\.audioPath)))
        }
    }

    private func recover(_ recording: RecoverableRecording) async {
        // A foreground re-transcription may have completed it meanwhile.
        guard recording.audioPath != activeCapturePath,
              FileManager.default.fileExists(atPath: recording.audioPath),
              RecordingRecovery.needsTranscript(audioPath: recording.audioPath) else { return }
        recoveringPath = recording.audioPath
        // Count the attempt up front so a crash mid-job also counts.
        RecordingRecovery.recordFailure(audioPath: recording.audioPath, reason: "attempt started",
                                        retryDelays: recoveryRetryDelays)
        var recoveryTitle = Strings.recoveredRecording
        do {
            let session = try existingSession(audioPath: recording.audioPath, startedAt: recording.startedAt, fallbackTitle: nil)
                ?? MeetingSession(startedAt: recording.startedAt)
            recoveryTitle = session.displayTitle
            let job = makeJob(audioPath: recording.audioPath, captureSampleRate: 16_000)
            let outcome = try await transcriptionRunner(job) { _ in }
            try Task.checkCancellation()
            let input = PostProcessInput(
                session: session, segments: outcome.segments, transcriptPath: recording.transcriptPath,
                capturePath: recording.audioPath, durableAudioPath: recording.audioPath,
                engine: outcome.engineUsed, model: outcome.modelUsed, language: Settings.asrLanguage,
                applyRetention: true, retention: Settings.retention, meetingsDir: paths.meetingsDir,
                audioDurationSec: outcome.audioDurationSec, audioEndedAt: recording.endedAt)
            var finalInput = input
            finalInput.quality = outcome.quality
            finalInput.partial = outcome.failedChunks > 0
            if finalInput.partial {
                try RecordingRecovery.markGaps(audioPath: recording.audioPath, chunks: outcome.failedChunks)
            }
            let result = try await postProcessor.run(finalInput)
            if outcome.failedChunks > 0 {
                // Handed off with gaps: keep the checkpoints and the attempt
                // count (already taken) and try again later.
                await recordRecoveryFailure(audioPath: recording.audioPath, reason: Self.gapReason(outcome.failedChunks),
                                            countsAsAttempt: false, title: session.displayTitle)
            } else {
                ChunkedTranscription.removeWork(forAudio: recording.audioPath)
                try? FileManager.default.removeItem(atPath: RecordingRecovery.attemptsPath(forAudio: recording.audioPath))
            }
            logger.info("grabación recuperada: \(result.pendingPath, privacy: .public)")
        } catch is CancellationError {
            logger.info("recuperación cancelada")
        } catch TranscriptionError.noSpeech {
            logger.info("grabación recuperada sin habla")
            errorMessage = TranscriptionError.noSpeech.errorDescription
            settleSilent(audioPath: recording.audioPath, isCapture: true)
        } catch {
            logger.error("recuperación falló: \(error.localizedDescription, privacy: .public)")
            // The attempt was already counted when it started.
            await recordRecoveryFailure(audioPath: recording.audioPath, reason: error.localizedDescription,
                                        countsAsAttempt: false, title: recoveryTitle)
        }
        recoveringPath = nil
    }

    /// Silence is a final result, not a failure: the audio stays, the chunk
    /// checkpoints go, and a capture without a transcript stops being retried
    /// automatically. No history row, handoff or "exhausted" notice.
    private func settleSilent(audioPath: String, isCapture: Bool) {
        do {
            // Preserve terminal state before removing gaps.json: an earlier
            // partial handoff may already have a processed marker.
            if isCapture, RecordingRecovery.needsTranscript(audioPath: audioPath) {
                try RecordingRecovery.recordTerminal(audioPath: audioPath, reason: TranscriptionError.noSpeech.rawValue)
            }
            ChunkedTranscription.removeWork(forAudio: audioPath)
        } catch {
            errorMessage = Strings.errorTranscription(error.localizedDescription)
            logger.error("no se pudo conservar el estado sin habla: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Records a failed or gapped attempt with its next retry time; the attempt
    /// that uses up the automatic ones tells the user once. A failed re-run of
    /// a complete capture leaves its transcript intact and is not a recovery.
    private func recordRecoveryFailure(audioPath: String, reason: String, countsAsAttempt: Bool, title: String) async {
        guard RecordingRecovery.needsTranscript(audioPath: audioPath) else { return }
        RecordingRecovery.recordFailure(audioPath: audioPath, reason: reason,
                                        countsAsAttempt: countsAsAttempt, retryDelays: recoveryRetryDelays)
        if RecordingRecovery.attempts(forAudio: audioPath) == RecordingRecovery.maxAutomaticAttempts,
           Settings.notifyHermes {
            await Notifier.recordingExhausted(title: title)
        }
    }

    /// One timer for every capture waiting for a retry, aimed at the earliest
    /// `nextAttemptAt`. A capture the last pass just tried waits at least the first
    /// retry delay even if its time is already past, so a `.recovery.json` that
    /// cannot be written never turns into a tight loop.
    private func scheduleRecoveryWake(justTried: Set<String> = [], now: Date = Date()) {
        recoveryWakeTask?.cancel()
        recoveryWakeTask = nil
        guard recoveryTask == nil else { return }   // the pass schedules when it ends
        let floor = recoveryRetryDelays.first ?? RecordingRecovery.retryDelays[0]
        let due = RecordingRecovery.retryable(recoverableRecordings, now: now).compactMap { r -> Date? in
            guard let next = r.nextAttemptAt else { return nil }
            return justTried.contains(r.audioPath) ? max(next, now.addingTimeInterval(floor)) : next
        }.min()
        guard let due else { return }
        let delay = max(0, due.timeIntervalSince(now))
        recoveryWakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.recoveryWakeTask = nil
            self.recoverRecordings(automaticOnly: true)
        }
    }

    /// Persisted evidence wins over today's calendar. Legacy audio may reuse
    /// an identity only when its exact transcript or canonical capture is known.
    private func existingSession(audioPath: String, startedAt: Date, fallbackTitle: String?) throws -> MeetingSession? {
        if var saved = try MeetingSession.read(forAudio: audioPath) {
            if let existing = store.summary(id: saved.id) {
                saved.startedAt = existing.startedAt
                saved.title = existing.title
                saved.startedAtIsAuthoritative = true
                saved.sourceAudioEndedAt = nil
            } else if saved.startedAtIsAuthoritative != true, saved.sourceAudioEndedAt == nil,
                      audioPath.hasSuffix(".pcm") {
                saved.sourceAudioEndedAt = RecordingRecovery.modificationDate(audioPath)
            }
            return saved
        }
        let transcript = URL(fileURLWithPath: audioPath).deletingPathExtension().appendingPathExtension("txt").path
        if let existing = store.summary(transcriptPath: transcript) {
            return MeetingSession(
                id: existing.id, startedAt: existing.startedAt, title: existing.title,
                supersedesMeetingId: existingSupersedesMeetingId(id: existing.id, transcriptPath: transcript),
                startedAtIsAuthoritative: true)
        }
        guard (audioPath as NSString).deletingLastPathComponent == paths.transcriptsDir,
              let id = RecordingRecovery.sessionId(forAudio: audioPath) else { return nil }
        let existing = store.summary(id: id)
        let audioEndedAt = RecordingRecovery.modificationDate(audioPath)
        // The sidecar may have been recreated. Without saved metadata/history,
        // only the PCM's last write can anchor the measured audio span.
        let capturedAt = existing?.startedAt ?? min(
            RecordingRecovery.modificationDate(AudioFormatSidecar.path(forAudio: audioPath)) ?? startedAt,
            audioEndedAt ?? startedAt)
        return MeetingSession(
            id: id, startedAt: capturedAt, title: existing?.title ?? fallbackTitle,
            supersedesMeetingId: existingSupersedesMeetingId(id: id, transcriptPath: transcript),
            sourceAudioEndedAt: existing == nil ? audioEndedAt : nil,
            startedAtIsAuthoritative: existing != nil)
    }

    private struct ExistingHandoff: Decodable {
        var version: Int
        var meetingId: String
        var transcriptPath: String
        var supersedesMeetingId: String?
    }

    /// A legacy handoff supplies ancestry, not calendar or clock evidence.
    /// Read only the known id's files, and require their exact transcript link.
    private func existingSupersedesMeetingId(id: String, transcriptPath: String) -> String? {
        guard !id.isEmpty, id != ".", id != "..",
              (id as NSString).lastPathComponent == id else { return nil }
        var root: String?
        for suffix in ["pending", "done"] {
            let url = URL(fileURLWithPath: paths.meetingsDir).appendingPathComponent("\(id).\(suffix)")
            guard let data = try? Data(contentsOf: url),
                  let handoff = try? JSONDecoder().decode(ExistingHandoff.self, from: data),
                  (2...3).contains(handoff.version), handoff.meetingId == id,
                  handoff.transcriptPath == transcriptPath,
                  let supersedes = handoff.supersedesMeetingId,
                  !supersedes.isEmpty, supersedes != id,
                  supersedes != ".", supersedes != "..",
                  (supersedes as NSString).lastPathComponent == supersedes else { continue }
            if let root, root != supersedes { return nil }
            root = supersedes
        }
        return root
    }

    private static func gapReason(_ chunks: Int) -> String { "\(chunks) fragmento(s) sin transcribir" }

    // MARK: - History

    func refreshHistory() {
        historySearchGeneration &+= 1
        historySearchTask?.cancel()
        if historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history = store.recent(limit: 20)
        } else {
            searchHistory(historyQuery)
        }
    }

    /// The SQLite lock is thread-safe, but a large full-text search must not
    /// run on the MainActor that drives the popover.
    func searchHistory(_ query: String) {
        historySearchGeneration &+= 1
        let generation = historySearchGeneration
        historySearchTask?.cancel()
        historySearchTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.historySearchGeneration == generation else { return }
            let store = self.store
            let work = Task.detached(priority: .userInitiated) { store.search(query) }
            let result = await work.value
            guard !Task.isCancelled, self.historySearchGeneration == generation else { return }
            self.history = result
            self.historySearchTask = nil
        }
    }

    // MARK: - Detection

    private func bind() {
        recorder.onTick = { [weak self] elapsed in self?.tick(elapsed) }
        audioCapture.$lastError
            .compactMap { $0 }
            .sink { [weak self] message in self?.handleCaptureFailure(message) }
            .store(in: &cancellables)
        calendarService.$upcomingMeetings.receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in self?.evaluateMeetings(meetings) }
            .store(in: &cancellables)
        callDetector.$isCallActive.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] active in self?.handleCallActivity(active) }
            .store(in: &cancellables)
    }

    /// A failed capture cannot keep displaying an active recording: stopping
    /// drains the writer and prevents incomplete audio from being transcribed.
    func handleCaptureFailure(_ message: String) {
        errorMessage = message
        if phase == .recording { stopRecording() }
    }

    private func tick(_ elapsed: TimeInterval) {
        recordingDuration = elapsed
        guard phase == .recording else { return }
        checkChannelLevels(elapsed: elapsed)
        if MeetingDetectionPolicy.shouldStopForMaxDuration(elapsed: elapsed, maximum: Settings.maxRecordingDuration) {
            logger.info("duración máxima alcanzada")
            stopRecording()
        } else if recordingOrigin == .calendar, let meeting = currentMeeting {
            switch MeetingDetectionPolicy.calendarEndAction(meeting: meeting, now: Date(),
                                                           callActive: callDetector.isCallActive) {
            case .stop:
                logger.info("reunión de calendario terminada")
                stopRecording()
            case .handOffToLiveCall:
                recordingOrigin = .liveCall
                callDetector.reconcileSuspended = false
                logger.info("Calendar event ended with call active: continuing as live call")
            case nil:
                break
            }
        }
    }

    /// A global tap delivers exact zeros while nothing plays, so the system
    /// channel only warns if it has never carried signal; the mic always has
    /// analog noise, so zeros there mean a denied or dead input.
    private func checkChannelLevels(elapsed: TimeInterval) {
        guard elapsed - lastLevelCheck >= 5, let path = activeCapturePath else { return }
        lastLevelCheck = elapsed
        guard let levels = ChannelLevels.measureTail(path: path, seconds: 10) else { return }
        if !levels.systemSilent { systemAudioHeard = true }
        let micOnly = Settings.micOnlyMode
        if !micOnly, !systemAudioHeard, elapsed >= 20 {
            captureWarning = .systemSilent
        } else if levels.micSilent, elapsed >= 10 {
            captureWarning = .micSilent
        } else {
            captureWarning = nil
        }
    }

    private func handleCallActivity(_ active: Bool) {
        switch MeetingDetectionPolicy.action(callActive: active, phase: phase, origin: recordingOrigin,
                                             autoRecord: Settings.autoRecord) {
        case .start(let origin): if hasAudioPermission { startRecording(origin: origin) }
        case .stop: stopRecording()
        case nil: break
        }
    }

    private func evaluateMeetings(_ meetings: [Meeting]) {
        guard phase == .idle || phase == .approaching, Settings.autoRecord else { return }
        let now = Date()
        guard let next = MeetingDetectionPolicy.approachingMeeting(in: meetings, now: now) else {
            if phase == .approaching { phase = .idle; currentMeeting = nil; scheduledStart?.cancel() }
            return
        }
        guard phase != .approaching else { return }
        phase = .approaching
        currentMeeting = next
        scheduledStart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if case .start(let origin) = MeetingDetectionPolicy.startAtScheduledTime(
                phase: self.phase, callActive: self.callDetector.isCallActive, autoRecord: Settings.autoRecord) {
                self.startRecording(origin: origin)
            } else if !Settings.autoRecord {
                self.phase = .idle
                self.currentMeeting = nil
            }
        }
        scheduledStart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, next.timeUntilStart(now: now)), execute: work)
    }

}

enum CaptureWarning: Equatable, Sendable {
    case systemSilent
    case micSilent
}

/// Decision made when Stop arrives while a capture start may still be
/// awaiting Core Audio. Keeping this pure makes the re-entrancy contract
/// explicit and regression-testable without touching a microphone.
enum RecordingStopDecision: Equatable, Sendable {
    case ignored
    case waitForStart
    case beginStop

    static func decide(phase: AppPhase, hasSession: Bool, startPending: Bool,
                       recorderIsRecording: Bool) -> Self {
        guard phase == .recording, hasSession else { return .ignored }
        if startPending && !recorderIsRecording { return .waitForStart }
        return .beginStop
    }
}

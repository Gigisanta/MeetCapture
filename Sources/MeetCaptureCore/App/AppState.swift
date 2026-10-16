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
    let start: (String, TapConfiguration, RecordingCoordinator.LiveOptions?) async throws -> Void
    let stop: () async throws -> String?

    static func live(recorder: RecordingCoordinator) -> Self {
        Self(
            checkPermission: { recorder.audioCapture.checkPermission() },
            openPrivacySettings: { recorder.audioCapture.openPrivacySettings() },
            isRecording: { recorder.isRecording },
            currentSampleRate: { recorder.audioCapture.currentSampleRate },
            start: { outputPath, configuration, live in
                try await recorder.start(outputPath: outputPath, configuration: configuration, live: live)
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
    @Published var livePartialText = ""
    @Published var liveSegments: [LiveASRSegment] = []
    @Published var liveASRState: LiveASRState = .cold
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
    @Published var toolchain: Toolchain = .unavailable
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
    private var warmTimer: Timer?
    private var historySearchTask: Task<Void, Never>?
    private var historySearchGeneration: UInt = 0
    private var errorDismissalTask: Task<Void, Never>?
    private let errorDismissalDelay: TimeInterval
    private var cancellables = Set<AnyCancellable>()
    private var activeCapturePath: String?
    private var recoveringPath: String?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryRetryTask: Task<Void, Never>?
    private var systemAudioHeard = false
    private var lastLevelCheck: TimeInterval = 0
    private let logger = AppInfo.logger("AppState")

    init(paths: AppPaths = .current, store: MeetingStore = .shared,
         recordingDriver: AppStateRecordingDriver? = nil,
         transcriptionRunner: AppStateTranscriptionRunner? = nil,
         errorDismissalDelay: TimeInterval = 10) {
        self.paths = paths
        self.calendarService = CalendarService()
        self.callDetector = CallDetector()
        let recorder = RecordingCoordinator()
        self.recorder = recorder
        self.store = store
        postProcessor = PostProcessor(store: store)
        self.recordingDriver = recordingDriver ?? .live(recorder: recorder)
        self.transcriptionRunner = transcriptionRunner ?? { job, progress in
            try await Task.detached(priority: .userInitiated) {
                try await job.run(progress: progress)
            }.value
        }
        self.errorDismissalDelay = max(0, errorDismissalDelay)
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
        await refreshToolchain()
        recoverRecordings(automaticOnly: true)
        // Keep the heavyweight recognizer cold until a call, an imminent
        // meeting or an explicit recording actually needs it.
        applyWarmPolicy()
        warmTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.applyWarmPolicy() }
        }
    }

    func shutdown() {
        callDetector.stop()
        warmTimer?.invalidate()
        if phase == .recording { stopRecording() }
        recorder.unloadLive()
    }

    /// True while quitting would cut a capture short.
    var needsGracefulShutdown: Bool { recordingStartTask != nil || recordingDriver.isRecording() }

    /// Finishes the PCM file and its sidecar without transcribing: the
    /// capture stays an orphan that startup recovery picks up next launch.
    func shutdownGracefully(timeout: TimeInterval = 15) async {
        callDetector.stop()
        warmTimer?.invalidate()
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
        recorder.unloadLive()
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

    /// Re-resolves python + scripts (Settings › ASR changes, startup).
    func refreshToolchain() async {
        toolchain = await ToolchainResolver.validated(ToolchainResolver.resolve())
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
        let session = MeetingSession(startedAt: Date(), title: currentMeeting?.title)
        self.session = session
        meetingNotes = ""
        isStartingRecording = true
        phase = .recording
        recordingOrigin = origin
        recordingDuration = 0
        captureWarning = nil
        systemAudioHeard = false
        lastLevelCheck = 0
        liveSegments = []
        livePartialText = ""
        if origin != .liveCall { callDetector.reconcileSuspended = true }

        let outputPath = "\(paths.transcriptsDir)/recording-\(session.id).pcm"
        activeCapturePath = outputPath
        let configuration = TapConfiguration(
            micOnly: Settings.micOnlyMode, inputDeviceUID: Settings.inputDeviceUID)
        let live = Settings.liveTranscribe
            ? RecordingCoordinator.LiveOptions(model: Settings.liveModel, toolchain: toolchain) : nil
        stopRequested = false
        recordingStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.recordingDriver.start(outputPath, configuration, live)
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
                self.livePartialText = ""
                self.liveSegments = []
                self.errorMessage = Strings.errorRecording(error.localizedDescription)
                self.resetRecordingState()
                return
            }
            guard let audioPath else {
                self.errorMessage = Strings.errorNoRecording
                self.resetRecordingState()
                return
            }
            self.livePartialText = ""
            await self.transcribe(session: session, audioPath: audioPath, durableAudioPath: audioPath,
                                  transcriptPath: RecordingRecovery.transcriptPath(forAudio: audioPath),
                                  applyRetention: true)
            if self.activeCapturePath == audioPath { self.activeCapturePath = nil }
            self.scanRecoverableRecordings()
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

    private func transcribe(session: MeetingSession, audioPath: String, durableAudioPath: String,
                            transcriptPath: String, applyRetention: Bool) async {
        errorMessage = nil
        phase = .transcribing
        transcriptionProgress = 0
        let prompt = LocalConfig.load(path: paths.configFile).domainPrompt ?? WhisperCLI.defaultPrompt
        let job = TranscriptionJob(
            audioPath: audioPath, captureSampleRate: recordingDriver.currentSampleRate(),
            engine: Settings.engine, model: Settings.asrModel, language: Settings.asrLanguage,
            diarize: Settings.diarize, prompt: prompt, toolchain: toolchain)
        let input = PostProcessInput(
            session: session, segments: [], transcriptPath: transcriptPath, capturePath: audioPath,
            durableAudioPath: durableAudioPath, engine: Settings.engine, model: Settings.asrModel,
            language: Settings.asrLanguage, applyRetention: applyRetention,
            retention: Settings.retention, meetingsDir: paths.meetingsDir,
            audioEndedAt: applyRetention ? RecordingRecovery.modificationDate(audioPath) : Date())
        do {
            let progressSink: @Sendable (Double) -> Void = { [weak self] progress in
                guard let self else { return }
                Task { @MainActor in self.transcriptionProgress = progress }
            }
            let outcome = try await transcriptionRunner(job, progressSink)
            var finalInput = input
            finalInput.segments = outcome.segments
            finalInput.engine = outcome.engineUsed
            finalInput.model = outcome.modelUsed
            finalInput.audioDurationSec = outcome.audioDurationSec
            // A gap in the transcript keeps the audio for a later retranscription.
            if outcome.failedChunks > 0 { finalInput.applyRetention = false }
            let result = try await postProcessor.run(finalInput)
            if outcome.failedChunks > 0 {
                // The checkpoints let a retranscription redo only the gaps.
                errorMessage = Strings.errorPartialTranscript(outcome.failedChunks)
            } else {
                ChunkedTranscription.removeWork(forAudio: audioPath)
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
        } catch {
            logger.error("transcripción falló: \(error.localizedDescription, privacy: .public)")
            errorMessage = Strings.errorTranscription(error.localizedDescription)
            phase = .idle
            self.session = nil
            // A capture that failed is a recovery like any other: count it
            // and retry later, resuming from the chunks already done.
            if applyRetention {
                RecordingRecovery.recordFailure(audioPath: audioPath, reason: error.localizedDescription)
                scheduleRecoveryRetry(attempts: RecordingRecovery.attempts(forAudio: audioPath))
            }
        }
    }

    func importAudio(url: URL) async {
        guard phase == .idle || phase == .done else { return }
        errorMessage = nil
        phase = .transcribing
        transcriptionProgress = 0
        do {
            let prepared = try await AudioImporter.prepare(url: url, importsDir: paths.importsDir)
            let session = MeetingSession(startedAt: Date(), title: prepared.title)
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
        let session = MeetingSession(startedAt: Date(), title: session?.title ?? Strings.retranscription)
        self.session = session
        await transcribe(session: session, audioPath: audio, durableAudioPath: audio,
                         transcriptPath: "\(paths.transcriptsDir)/\(session.id).txt",
                         applyRetention: false)
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
        guard !targets.isEmpty else { return }
        isRecovering = true
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for recording in targets where !Task.isCancelled {
                // One whisper at a time: wait for the foreground job.
                while self.phase == .transcribing, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                guard !Task.isCancelled else { break }
                await self.recover(recording)
            }
            self.recoveringPath = nil
            self.isRecovering = false
            self.recoveryTask = nil
            self.scanRecoverableRecordings()
            self.refreshHistory()
        }
    }

    private func recover(_ recording: RecoverableRecording) async {
        guard FileManager.default.fileExists(atPath: recording.audioPath) else { return }
        recoveringPath = recording.audioPath
        // Count the attempt up front so a crash mid-job also counts.
        RecordingRecovery.recordFailure(audioPath: recording.audioPath, reason: "attempt started")
        let session = MeetingSession(startedAt: recording.startedAt, title: Strings.recoveredRecording)
        let prompt = LocalConfig.load(path: paths.configFile).domainPrompt ?? WhisperCLI.defaultPrompt
        let job = TranscriptionJob(
            audioPath: recording.audioPath, captureSampleRate: 16_000,
            engine: Settings.engine, model: Settings.asrModel, language: Settings.asrLanguage,
            diarize: Settings.diarize, prompt: prompt, toolchain: toolchain)
        do {
            let outcome = try await transcriptionRunner(job) { _ in }
            let input = PostProcessInput(
                session: session, segments: outcome.segments, transcriptPath: recording.transcriptPath,
                capturePath: recording.audioPath, durableAudioPath: recording.audioPath,
                engine: outcome.engineUsed, model: outcome.modelUsed, language: Settings.asrLanguage,
                applyRetention: true, retention: Settings.retention, meetingsDir: paths.meetingsDir,
                audioDurationSec: outcome.audioDurationSec, audioEndedAt: recording.endedAt)
            var finalInput = input
            if outcome.failedChunks > 0 { finalInput.applyRetention = false }
            let result = try await postProcessor.run(finalInput)
            if outcome.failedChunks == 0 { ChunkedTranscription.removeWork(forAudio: recording.audioPath) }
            try? FileManager.default.removeItem(atPath: RecordingRecovery.attemptsPath(forAudio: recording.audioPath))
            logger.info("grabación recuperada: \(result.pendingPath, privacy: .public)")
        } catch is CancellationError {
            logger.info("recuperación cancelada")
        } catch {
            logger.error("recuperación falló: \(error.localizedDescription, privacy: .public)")
            // The attempt was already counted when it started.
            RecordingRecovery.recordFailure(audioPath: recording.audioPath, reason: error.localizedDescription,
                                            countsAsAttempt: false)
            scheduleRecoveryRetry(attempts: RecordingRecovery.attempts(forAudio: recording.audioPath))
        }
        recoveringPath = nil
    }

    /// Automatic retry after 5, 20 and 60 min; `RecordingRecovery.automatic`
    /// stops picking a capture once it reaches the attempt cap.
    private func scheduleRecoveryRetry(attempts: Int) {
        let delays: [UInt64] = [300, 1_200, 3_600]
        guard attempts >= 1, attempts <= delays.count else { return }
        recoveryRetryTask?.cancel()
        recoveryRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delays[attempts - 1] * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.recoveryRetryTask = nil
            self.recoverRecordings(automaticOnly: true)
        }
    }

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
        recorder.liveASR.onState = { [weak self] state in
            Task { @MainActor [weak self] in self?.liveASRState = state }
        }
        recorder.liveASR.onPartial = { [weak self] text in
            Task { @MainActor [weak self] in self?.livePartialText = text }
        }
        recorder.liveASR.onFinal = { [weak self] seg in
            Task { @MainActor [weak self] in
                self?.liveSegments.append(seg)
                self?.livePartialText = ""
            }
        }
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
        } else if recordingOrigin == .calendar, let meeting = currentMeeting,
                  MeetingDetectionPolicy.shouldStopCalendarRecording(meeting: meeting, now: Date()) {
            logger.info("reunión de calendario terminada")
            stopRecording()
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
        if active { warmLive() }
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
        warmLive()
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

    // MARK: - Live ASR warm policy

    private var warmPolicy: LiveASRWarmPolicy { LiveASRWarmPolicy(idleUnloadMinutes: Settings.liveIdleUnloadMinutes) }

    private func warmLive() {
        guard Settings.liveTranscribe, toolchain.isUsable else { return }
        recorder.warmLive(.init(model: Settings.liveModel, toolchain: toolchain))
    }

    private func applyWarmPolicy() {
        guard phase != .recording else { return }
        let now = Date()
        let next = calendarService.nextMeeting?.startDate
        if recorder.liveASR.isRunning {
            if warmPolicy.shouldUnload(idleSince: recorder.liveIdleSince, now: now,
                                       callActive: callDetector.isCallActive, nextMeetingStart: next) {
                logger.info("live ASR descargado por inactividad")
                recorder.unloadLive()
            }
        } else if warmPolicy.shouldWarm(callActive: callDetector.isCallActive, nextMeetingStart: next, now: now) {
            warmLive()
        }
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

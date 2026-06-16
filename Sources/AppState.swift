// AppState.swift
// MeetCapture v4 — Central observable state

import SwiftUI
import Combine
import UserNotifications
import os

/// Central app state — single source of truth
@MainActor
final class AppState: ObservableObject {
    static var shared: AppState?

    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "AppState")
    
    // MARK: - Published State
    
    @Published var phase: AppPhase = .idle
    @Published var currentMeeting: Meeting?
    @Published var errorMessage: String?
    @Published var hasCalendarAccess = false
    @Published var hasAudioPermission = false
    @Published var isDaemonRunning = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var transcriptionProgress: Double = 0
    @Published var lastTranscriptPath: String?
    @Published var liveTranscriptBuffer: String = ""
    
    // MARK: - Services
    
    let calendarService = CalendarService()
    let audioCapture = AudioCaptureService()
    let daemonManager = DaemonManager()
    let whisperManager = WhisperModelManager.shared
    let socketClient = SocketClient()
    let healthMonitor = HealthMonitor()
    
    // MARK: - Private
    
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private let transcriptDir: String
    private var energyActivity: NSObjectProtocol?
    private var lastRecordingPath: String?
    
    // MARK: - Init

    // nonisolated because SwiftUI's @main App.init() runs before the
    // main actor isolation guarantees kick in. The body of init() is
    // pure synchronous setup (logger, file paths) that does not touch
    // any actor-isolated state. All mutations to @Published properties
    // happen later, on the main actor.
    nonisolated init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        transcriptDir = "\(home)/.hermes/TechPartners/MaatWork/meetings/transcripts"

        Task { @MainActor in
            AppState.shared = self
            // Defer setupMethods (which are @MainActor-isolated) until
            // the next main-actor tick.
            self.setupBindings()
            self.setupMeetingDetection()
        }
    }
    
    // MARK: - Menu Bar
    
    var menuBarTitle: String {
        switch phase {
        case .idle: return ""
        case .approaching: return ""
        case .recording: return ""
        case .transcribing: return ""
        case .done: return ""
        }
    }
    
    var menuBarIcon: String {
        switch phase {
        case .idle: return "mic"
        case .approaching: return "mic.badge.plus"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .done: return "mic.badge.checkmark"
        }
    }
    
    var menuBarColor: Color? {
        switch phase {
        case .recording: return .red
        case .transcribing: return .orange
        case .done: return .green
        default: return nil
        }
    }
    
    // MARK: - Lifecycle
    
    func startup() async {
        let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "appstate")
        logger.info("startup() called — initializing services")

        await requestPermissions()
        logger.info("Permissions: calendar=\(self.hasCalendarAccess) audio=\(self.hasAudioPermission)")

        daemonManager.registerIfNeeded()
        requestNotificationPermission()

        // Ping daemon to verify IPC and refresh status indicator
        await refreshDaemonStatus()

        healthMonitor.start(socketClient: socketClient, appState: self)

        phase = .idle

        // Test-only: MEETCAPTURE_SELFTEST_SECS=N records N seconds then stops
        // (and transcribes) without any UI interaction. Never set in production;
        // lets the harness exercise the real capture→transcript path headlessly.
        if let raw = ProcessInfo.processInfo.environment["MEETCAPTURE_SELFTEST_SECS"],
           let secs = Double(raw), secs > 0 {
            logger.warning("SELFTEST: recording \(secs)s")
            startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
                self?.stopRecording()
            }
        }
    }

    /// Ping the daemon via SocketClient. Updates `isDaemonRunning` accordingly.
    /// Retries with backoff up to ~10s to handle the startup race where
    /// launchctl loads the daemon AFTER the app has already started.
    func refreshDaemonStatus() async {
        var attempts = 0
        let maxAttempts = 15
        while attempts < maxAttempts {
            do {
                let resp = try await socketClient.send(command: "ping", timeout: 1.0)
                if (resp["data"] as? [String: Any])?["pong"] as? Bool == true {
                    isDaemonRunning = true
                    return
                }
            } catch {
                // ignore, will retry
            }
            attempts += 1
            // 500ms, 750ms, 1s, 1.25s, ... up to 2s cap
            let sleepMs = min(2000, 500 + attempts * 250)
            try? await Task.sleep(nanoseconds: UInt64(sleepMs) * 1_000_000)
        }
        isDaemonRunning = false
        logger.warning("Daemon not reachable after \(maxAttempts) attempts (~10s)")
    }
    
    func shutdown() {
        if phase == .recording {
            stopRecording()
        }
        endRecordingActivity()
    }
    
    // MARK: - Permissions
    
    private func requestPermissions() async {
        await calendarService.requestAccess()
        hasCalendarAccess = calendarService.isAuthorized
        
        hasAudioPermission = audioCapture.checkPermission()
        if !hasAudioPermission {
            // Update the UI once the user answers the prompt (otherwise the
            // "Microphone access required" banner sticks until app restart).
            audioCapture.requestPermission { [weak self] granted in
                self?.hasAudioPermission = granted
            }
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    // MARK: - Meeting Detection
    
    private func setupMeetingDetection() {
        calendarService.$upcomingMeetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in
                self?.evaluateMeetings(meetings)
            }
            .store(in: &cancellables)
    }
    
    private func evaluateMeetings(_ meetings: [Meeting]) {
        guard phase == .idle || phase == .approaching else { return }
        
        if let next = meetings.first(where: { $0.timeUntilStart <= 300 && $0.timeUntilStart > -60 }) {
            if phase != .approaching {
                phase = .approaching
                currentMeeting = next
                scheduleRecording(for: next)
            }
        }
    }
    
    private func scheduleRecording(for meeting: Meeting) {
        let delay = max(0, meeting.timeUntilStart)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.phase == .approaching else { return }
            self.startRecording()
        }
    }
    
    // MARK: - Recording Control
    
    func startRecording() {
        guard phase != .recording else { return }

        hasAudioPermission = audioCapture.checkPermission()
        guard hasAudioPermission else {
            errorMessage = "Microphone permission required. Click the banner to open System Settings."
            audioCapture.openPrivacySettings()
            return
        }

        let outputPath = "\(transcriptDir)/recording-\(Date().timeIntervalSince1970).pcm"
        lastRecordingPath = outputPath
        beginRecordingActivity()

        Task {
            do {
                try await audioCapture.startCapture(outputPath: outputPath)
                do {
                    try whisperManager.startRecording()
                } catch {
                    logger.warning("Whisper preload failed (non-fatal): \(error.localizedDescription)")
                }

                phase = .recording
                recordingStartDate = Date()
                startRecordingTimer()

                // Tell daemon we are recording (fire-and-forget, for status/badge)
                socketClient.sendFireAndForget(
                    command: "start_recording",
                    payload: ["meeting_title": currentMeeting?.title ?? "Manual recording"]
                )
            } catch {
                errorMessage = "Recording failed: \(error.localizedDescription)"
                phase = .idle
                endRecordingActivity()
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }

        phase = .transcribing
        transcriptionProgress = 0
        stopRecordingTimer()

        let recordedPath = lastRecordingPath

        Task {
            await audioCapture.stopCapture()
            endRecordingActivity()
            whisperManager.stopRecording()
            socketClient.sendFireAndForget(command: "stop_recording")

            guard let recordedPath else {
                errorMessage = "No recording path found."
                phase = .idle
                return
            }

            // The kill-shot fix: transcribe() was never called.
            await transcribe(audioPath: recordedPath)
        }
    }
    
    // MARK: - Transcription

    /// Stream-transcribe a PCM file in 30s chunks. Phase 3 fix: bounded RAM.
    private func transcribe(audioPath: String) async {
        // WhisperTranscriber loads the model on demand; free it (and stop the
        // memory-monitor timer) once we're done so an idle app doesn't sit on
        // 150MB–1.4GB of model after every meeting.
        defer { whisperManager.stopRecording() }
        do {
            let outputPath = audioPath.replacingOccurrences(of: ".pcm", with: ".txt")
            let outputURL = URL(fileURLWithPath: outputPath)
            let outputBase = audioPath.replacingOccurrences(of: ".pcm", with: "")
            _ = outputBase

            // Try streaming transcription first (Phase 3). Pass the actual
            // capture rate so the transcriber resamples correctly (48k or 44.1k).
            let captureRate = audioCapture.currentSampleRate
            if let stream = WhisperTranscriber(audioPath: audioPath, sampleRate: captureRate, whisperManager: whisperManager) {
                let progressStream = stream.progress
                let textStream = stream.text

                // Forward progress to @Published
                Task { @MainActor in
                    for await p in progressStream {
                        self.transcriptionProgress = p
                    }
                }

                // Forward text chunks to @Published live buffer
                Task { @MainActor in
                    for await chunk in textStream {
                        self.appendLiveTranscript(chunk)
                    }
                }

                let finalText = try await stream.run()
                try finalText.write(to: outputURL, atomically: true, encoding: .utf8)
            } else {
                // Fallback: file missing, log and bail
                throw WhisperError.transcriptionFailed(reason: "Could not open \(audioPath)")
            }

            lastTranscriptPath = outputPath
            liveTranscriptBuffer = ""
            transcriptionProgress = 1.0
            phase = .done
            notifyHermes(transcriptPath: outputPath, meetingTitle: currentMeeting?.title)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.phase = .idle
                self?.currentMeeting = nil
            }
        } catch {
            logger.error("Transcribe failed: \(error.localizedDescription)")
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            phase = .idle
        }
    }

    /// Append incremental text from streaming whisper to the live buffer.
    func appendLiveTranscript(_ chunk: String) {
        liveTranscriptBuffer += chunk + " "
    }
    
    // MARK: - Energy Management (inline from EnergyManager)

    private func beginRecordingActivity() {
        guard energyActivity == nil else { return }
        energyActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording Google Meet audio"
        )
    }

    private func endRecordingActivity() {
        if let activity = energyActivity {
            ProcessInfo.processInfo.endActivity(activity)
            energyActivity = nil
        }
    }

    // MARK: - Helpers

    private func setupBindings() {
        $errorMessage
            .compactMap { $0 }
            .delay(for: .seconds(10), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.errorMessage = nil
            }
            .store(in: &cancellables)
    }

    private func startRecordingTimer() {
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.recordingStartDate else { return }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    private func notifyHermes(transcriptPath: String, meetingTitle: String?) {
        let title = meetingTitle ?? "Google Meet"
        let notificationText = "Meeting transcript ready: \(title)"

        let content = UNMutableNotificationContent()
        content.title = "MeetCapture"
        content.body = notificationText
        content.sound = UNNotificationSound.default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - App Phase

enum AppPhase: String, CaseIterable {
    case idle          // Polling calendar, no meeting
    case approaching   // Meeting in <5 min, preparing
    case recording     // Actively capturing audio
    case transcribing  // Meeting ended, processing
    case done          // Transcript ready, notifying
}

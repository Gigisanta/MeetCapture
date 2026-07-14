// AppState.swift
// MeetCapture v4 — Central observable state

import SwiftUI
import Combine
import UserNotifications
import os

// MARK: - Recording Origin

/// Why this recording was started — controls auto-stop logic.
enum RecordingOrigin: String, Codable, Equatable {
    case manual    // User clicked Record — never auto-stopped
    case liveCall  // CallDetector detected mic-in-use — auto-stop when call ends
    case calendar  // Calendar meeting — auto-stop at endDate+grace, only if isCallActive
}

// MARK: - Retention Policy

enum RetentionPolicy: String, CaseIterable, Codable {
    case deleteAfterHandoff = "deleteAfterHandoff"
    case keep24h = "24h"
    case keep = "keep"

    var label: String {
        switch self {
        case .deleteAfterHandoff: return "Delete after handoff"
        case .keep24h: return "Keep 24 hours"
        case .keep: return "Keep forever"
        }
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

// MARK: - AppState

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
    @Published var recordingDuration: TimeInterval = 0
    @Published var transcriptionProgress: Double = 0
    @Published var lastTranscriptPath: String?
    @Published var liveTranscriptBuffer: String = ""

    // MARK: - Services

    lazy var calendarService = CalendarService()
    lazy var callDetector = CallDetector()
    lazy var audioCapture = AudioCaptureService()
    let whisperManager = WhisperModelManager.shared

    // MARK: - Private

    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private let transcriptDir: String
    private let pendingPath: String
    private var energyActivity: NSObjectProtocol?
    private var lastRecordingPath: String?
    /// Why the *current* recording was started — drives auto-stop behavior.
    private var recordingOrigin: RecordingOrigin?
    /// Safety limit for every recording origin. User-configurable, clamped to 30m…8h.
    private var maxRecordingDuration: TimeInterval {
        let configured = UserDefaults.standard.double(forKey: "maxRecordingDuration")
        return min(max(configured > 0 ? configured : 10_800, 1_800), 28_800)
    }
    /// Grace period after a calendar meeting's endDate before auto-stopping (seconds).
    private let calendarEndGrace: TimeInterval = 120  // 2 min

    // MARK: - Init

    // nonisolated because SwiftUI's @main App.init() runs before the
    // main actor isolation guarantees kick in. The body of init() is
    // pure synchronous setup (logger, file paths) that does not touch
    // any actor-isolated state. All mutations to @Published properties
    // happen later, on the main actor.
    nonisolated init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let base = "\(home)/.hermes/TechPartners/MaatWork/meetings"

        // MEETCAPTURE_TEST_OUTPUT_DIR overrides all output paths for isolated testing.
        if let testDir = ProcessInfo.processInfo.environment["MEETCAPTURE_TEST_OUTPUT_DIR"],
           !testDir.isEmpty {
            transcriptDir = testDir
            pendingPath = "\(testDir)/.pending"
        } else {
            transcriptDir = "\(base)/transcripts"
            pendingPath = "\(base)/.pending"
        }

        Task { @MainActor in
            AppState.shared = self
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
        logger.info("startup() called — initializing services")

        await requestPermissions()
        logger.info("Permissions: calendar=\(self.hasCalendarAccess) audio=\(self.hasAudioPermission)")

        requestNotificationPermission()

        // Begin watching for live calls
        audioCapture.callDetector = callDetector
        callDetector.start()

        phase = .idle

        // Launch cleanup for 24h retention
        cleanupOldRecordings()

        // Test-only: MEETCAPTURE_SELFTEST_SECS=N records N seconds then stops
        if let raw = ProcessInfo.processInfo.environment["MEETCAPTURE_SELFTEST_SECS"],
           let secs = Double(raw), secs > 0 {
            logger.warning("SELFTEST: recording \(secs)s")
            Task { @MainActor in
                self.startRecording(origin: .manual)
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                self.stopRecording()

                let deadline = Date().addingTimeInterval(90)
                while Date() < deadline {
                    if self.phase == .done || self.phase == .idle {
                        NSApp.terminate(nil)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                self.logger.error("SELFTEST: timed out waiting for transcription")
                NSApp.terminate(nil)
            }
        }
    }

    func shutdown() {
        callDetector.stop()
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
            audioCapture.requestPermission { [weak self] granted in
                Task { @MainActor in self?.hasAudioPermission = granted }
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

        callDetector.$isCallActive
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                self?.handleCallActivity(active)
            }
            .store(in: &cancellables)
    }

    /// Handle live-call detection events.
    private func handleCallActivity(_ active: Bool) {
        guard UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true else { return }

        if active {
            // Call starting:
            // 1. Idle → start with liveCall origin
            // 2. Approaching with no recording yet (calendar didn't fire) → start with calendar origin
            //    because the approaching meeting may have started. The calendar fires when isCallActive.
            if phase == .idle {
                guard hasAudioPermission else { return }
                logger.info("Auto-starting recording — live call detected")
                startRecording(origin: .liveCall)
            } else if phase == .approaching {
                guard hasAudioPermission else { return }
                logger.info("Call active during approaching — starting calendar recording")
                startRecording(origin: .calendar)
            }
        } else {
            // Call ending: only stop if origin was .liveCall
            if phase == .recording, recordingOrigin == .liveCall {
                logger.info("Auto-stopping recording — live call ended")
                stopRecording()
            }
        }
    }

    private func evaluateMeetings(_ meetings: [Meeting]) {
        guard phase == .idle || phase == .approaching else { return }
        guard UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true else { return }

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
            // Re-check autoRecord at fire time — user may have toggled it off
            guard UserDefaults.standard.object(forKey: "autoRecord") as? Bool ?? true else {
                self.phase = .idle
                self.currentMeeting = nil
                return
            }

            // Only start recording if a call is actually active at fire time.
            // If not, stay .approaching — handleCallActivity will start with
            // origin .calendar when the mic goes live.
            if self.callDetector.isCallActive {
                self.startRecording(origin: .calendar)
            }
            // else: stay .approaching, handleCallActivity will promote when call starts
        }
    }

    // MARK: - Recording Control

    func startRecording(origin: RecordingOrigin = .manual) {
        // Don't start while already recording OR transcribing
        guard phase != .recording, phase != .transcribing else { return }

        hasAudioPermission = audioCapture.checkPermission()
        guard hasAudioPermission else {
            errorMessage = "Microphone permission required. Click the banner to open System Settings."
            audioCapture.openPrivacySettings()
            return
        }

        // Claim the recording phase synchronously
        phase = .recording
        recordingOrigin = origin
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

                recordingStartDate = Date()
                startRecordingTimer()
            } catch {
                errorMessage = "Recording failed: \(error.localizedDescription)"
                phase = .idle
                recordingOrigin = nil
                endRecordingActivity()
            }
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }

        recordingOrigin = nil
        phase = .transcribing
        transcriptionProgress = 0
        stopRecordingTimer()

        let recordedPath = lastRecordingPath

        Task {
            await audioCapture.stopCapture()
            endRecordingActivity()
            whisperManager.stopRecording()

            guard let recordedPath else {
                errorMessage = "No recording path found."
                phase = .idle
                return
            }

            await transcribe(audioPath: recordedPath)
        }
    }

    // MARK: - Transcription

    /// Stream-transcribe a PCM file in 30s chunks.
    private func transcribe(audioPath: String) async {
        defer { whisperManager.stopRecording() }
        do {
            let outputPath = audioPath.replacingOccurrences(of: ".pcm", with: ".txt")
            let outputURL = URL(fileURLWithPath: outputPath)

            let captureRate = audioCapture.currentSampleRate
            if let stream = WhisperTranscriber(audioPath: audioPath, sampleRate: captureRate, whisperManager: whisperManager) {
                let progressStream = stream.progress
                let textStream = stream.text

                Task { @MainActor in
                    for await p in progressStream {
                        self.transcriptionProgress = p
                    }
                }

                Task { @MainActor in
                    for await chunk in textStream {
                        self.appendLiveTranscript(chunk)
                    }
                }

                let finalText = try await stream.run()
                try finalText.write(to: outputURL, atomically: true, encoding: .utf8)
            } else {
                throw WhisperError.transcriptionFailed(reason: "Could not open \(audioPath)")
            }

            lastTranscriptPath = outputPath

            // Read transcript content for .pending contract
            let transcriptContent = try String(contentsOf: outputURL, encoding: .utf8)
            let meetingTitle = currentMeeting?.title

            // --- Critical path: write .pending contract (throws on failure) ---
            // This must succeed before we delete anything.
            try await writePendingContract(
                transcriptPath: outputPath,
                transcriptContent: transcriptContent,
                meetingTitle: meetingTitle,
                audioPath: audioPath
            )

            // --- Write processed marker (no audio path — audio may be deleted) ---
            writeProcessedMarker(transcriptPath: outputPath, meetingTitle: meetingTitle)

            // --- Apply retention after durable handoff ---
            await applyRetention(audioPath: audioPath, transcriptPath: outputPath)

            liveTranscriptBuffer = ""
            transcriptionProgress = 1.0
            phase = .done

            // --- Local notification (gated by notifyHermes) ---
            let showNotification = UserDefaults.standard.object(forKey: "notifyHermes") as? Bool ?? true
            if showNotification {
                await sendLocalNotification(title: meetingTitle ?? "Google Meet")
            }

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

    // MARK: - Max Duration Enforcement

    private func checkMaxDuration() {
        guard self.phase == .recording, let start = self.recordingStartDate else { return }
        let elapsed = Date().timeIntervalSince(start)
        if elapsed >= self.maxRecordingDuration {
            self.logger.info("Max recording duration reached (\(Int(self.maxRecordingDuration))s) — auto-stopping")
            self.stopRecording()
        }
    }

    // MARK: - Meeting End Detection

    /// Check if the current calendar meeting has ended. Only applies to .calendar origin.
    func checkMeetingEnd() {
        guard self.phase == .recording, self.recordingOrigin == .calendar, let meeting = self.currentMeeting else { return }
        let graceEnd = meeting.endDate.addingTimeInterval(self.calendarEndGrace)
        if Date() > graceEnd {
            self.logger.info("Calendar meeting ended (grace elapsed) — auto-stopping recording")
            self.stopRecording()
        }
    }

    /// Append incremental text from streaming whisper to the live buffer.
    func appendLiveTranscript(_ chunk: String) {
        liveTranscriptBuffer += chunk + " "
    }

    // MARK: - Energy Management

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

    // MARK: - .pending Handoff Contract

    /// Writes the canonical .pending contract consumed by HerMaatOS/scripts/meet_summary_dispatcher.py.
    /// - Throws: on write failure — caller MUST NOT delete audio if this throws.
    private func writePendingContract(transcriptPath: String, transcriptContent: String, meetingTitle: String?, audioPath: String) async throws {
        let fm = FileManager.default
        let pendingURL = URL(fileURLWithPath: pendingPath)
        try fm.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // meeting_id: deterministic/idempotent — uses eventIdentifier for calendar, path hash for others
        let meetingID: String
        if let mid = currentMeeting?.id {
            meetingID = "meet-\(mid)"
        } else {
            // Stable ID from the audio path's timestamp portion
            let baseName = (audioPath as NSString).lastPathComponent
                .replacingOccurrences(of: ".pcm", with: "")
            meetingID = "rec-\(baseName)"
        }

        let created = ISO8601DateFormatter().string(from: Date())

        // Canonical contract — no audio path (audio will be deleted)
        let contract: [String: Any] = [
            "type": "meeting.processed",
            "state": "transcribed",
            "meeting_id": meetingID,
            "transcript": transcriptPath,
            "title": meetingTitle ?? "Untitled Meeting",
            "source": "meetcapture",
            "created": created,
            "metadata": [
                "transcript_path": transcriptPath,
                "transcript_characters": transcriptContent.count,
                "app_version": "5.0.0"
            ]
        ]

        let data = try JSONSerialization.data(withJSONObject: contract, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: pendingURL, options: .atomic)

        logger.info("Pending handoff written: \(self.pendingPath)")
    }

    // MARK: - Retention

    /// Apply the configured retention policy for the recording.
    private func applyRetention(audioPath: String, transcriptPath: String) async {
        let policy = UserDefaults.standard.string(forKey: "retention") ?? RetentionPolicy.deleteAfterHandoff.rawValue
        switch policy {
        case RetentionPolicy.deleteAfterHandoff.rawValue:
            deleteRawPCM(at: audioPath)
        case RetentionPolicy.keep24h.rawValue:
            // Audio stays for now; periodic cleanup at startup handles it.
            // We keep the audio until the next launch's cleanup pass.
            break
        case RetentionPolicy.keep.rawValue:
            break
        default:
            deleteRawPCM(at: audioPath)
        }
    }

    /// Deletes only the exact raw PCM and its exact format sidecar.
    private func deleteRawPCM(at path: String) {
        for candidate in [path, path + ".format.json"] {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            do {
                try FileManager.default.removeItem(atPath: candidate)
                logger.info("Deleted raw audio artifact (retention): \(candidate)")
            } catch {
                logger.warning("Could not delete raw artifact \(candidate): \(error.localizedDescription)")
            }
        }
    }

    /// Periodic cleanup for 24h retention: scan recording files by exact path and age at launch.
    /// Never uses a destructive glob — iterates known files, checks age, deletes individually.
    private func cleanupOldRecordings() {
        let policy = UserDefaults.standard.string(forKey: "retention") ?? RetentionPolicy.deleteAfterHandoff.rawValue
        guard policy == RetentionPolicy.keep24h.rawValue else { return }

        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400) // 24 hours ago

        do {
            let contents = try fm.contentsOfDirectory(atPath: transcriptDir)
            for name in contents {
                let path = "\(transcriptDir)/\(name)"
                guard name.hasPrefix("recording-"),
                      (name.hasSuffix(".pcm") || name.hasSuffix(".pcm.format.json")) else { continue }

                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }

                let attrs = try fm.attributesOfItem(atPath: path)
                if let modDate = attrs[.modificationDate] as? Date, modDate < cutoff {
                    try fm.removeItem(atPath: path)
                    logger.info("Cleaned up old recording (24h): \(path)")
                }
            }
        } catch {
            logger.warning("Cleanup scan failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Processed Marker (atomic, idempotent)

    /// Writes a `.processed.json` marker BEFORE cleanup so the marker never points to a deleted file.
    private func writeProcessedMarker(transcriptPath: String, meetingTitle: String?) {
        let markerPath = transcriptPath.replacingOccurrences(of: ".txt", with: ".processed.json")
        guard !FileManager.default.fileExists(atPath: markerPath) else {
            logger.info("Processed marker already exists, skipping: \(markerPath)")
            return
        }

        let marker: [String: Any] = [
            "schema": "meetcapture.processed.v1",
            "processed_at": ISO8601DateFormatter().string(from: Date()),
            "transcript_path": transcriptPath,
            "meeting_title": meetingTitle ?? "Untitled Meeting",
            "retention": "handoff_complete"
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: markerPath), options: .atomic)
            logger.info("Processed marker written: \(markerPath)")
        } catch {
            logger.error("Failed to write processed marker: \(error.localizedDescription)")
        }
    }

    // MARK: - Local Notification

    private func sendLocalNotification(title: String) async {
        let content = UNMutableNotificationContent()
        content.title = "MeetCapture"
        content.body = "Meeting transcript ready: \(title)"
        content.sound = UNNotificationSound.default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.warning("Failed to show notification: \(error.localizedDescription)")
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
                self.checkMaxDuration()
                self.checkMeetingEnd()
            }
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }
}

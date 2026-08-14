// AppState.swift
// MeetCapture v4 — Central observable state

import SwiftUI
import Combine
import UserNotifications
import CryptoKit
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
    /// Live in-call streaming ASR (sherpa online): current partial text.
    @Published var livePartialText: String = ""
    /// Sentences finalized by the streaming recognizer while recording.
    @Published var liveSegments: [LiveASRSegment] = []
    /// Human-readable live-ASR status shown in the popover while recording
    /// ("" = live transcription disabled).
    @Published var liveTranscribeStatus: String = ""
    /// Timed segments of the latest transcription (timestamps + speakers).
    @Published var lastSegments: [Segment] = []
    /// Durable audio of the latest transcription (for Re-transcribir).
    @Published var lastAudioPath: String?
    /// Recent meetings from the SQLite store.
    @Published var history: [MeetingRecord] = []

    // MARK: - Services

    lazy var calendarService = CalendarService()
    lazy var callDetector = CallDetector()
    lazy var audioCapture = AudioCaptureService()
    let whisperManager = WhisperModelManager.shared
    let store = MeetingStore.shared

    // MARK: - Private

    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private let transcriptDir: String
    private let meetingsDir: String
    /// Handoff .pending POR REUNIÓN: meet-<epoch>.pending (contrato v2 del
    /// dispatcher: un archivo por reunión, nombre = meetingId). Ruta canónica
    /// ~/meetings, la misma que vigila launchd (com.maatwork.meetcapture-summary).
    private var pendingPath: String {
        let epoch = Int64((recordingStartDate ?? Date()).timeIntervalSince1970)
        return "\(meetingsDir)/meet-\(epoch).pending"
    }
    private var energyActivity: NSObjectProtocol?
    private var lastRecordingPath: String?
    /// In-call streaming ASR preview (best-effort; nil when disabled/failed).
    private var liveASR: LiveASRService?
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
        setvbuf(stdout, nil, _IONBF, 0)  // timing prints survive pipe redirection
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Ruta canónica: ~/meetings — la misma que vigila el launchd
        // (com.maatwork.meetcapture-summary, WatchPaths). La ruta legacy
        // ~/.hermes/TechPartners/MaatWork/meetings ya NO existe: los .pending
        // escritos ahí jamás los vería el dispatcher (bug corregido en v6.0.1).
        let base = "\(home)/meetings"

        // MEETCAPTURE_TEST_OUTPUT_DIR overrides all output paths for isolated testing.
        if let testDir = ProcessInfo.processInfo.environment["MEETCAPTURE_TEST_OUTPUT_DIR"],
           !testDir.isEmpty {
            transcriptDir = testDir
            meetingsDir = testDir
        } else {
            transcriptDir = "\(base)/transcripts"
            meetingsDir = base
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
        case .done: return "checkmark.circle.fill" // mic.badge.checkmark NO existe en macOS 26 -> glifo invisible
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

        // Preload the live streaming ASR process (model load takes seconds;
        // with warmup the recognizer is ready the moment a call starts).
        setupLiveASR()

        phase = .idle

        // Launch cleanup for 24h retention
        cleanupOldRecordings()

        // Load recent meetings from SQLite store
        refreshHistory()

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
                let t0 = Date()
                try await audioCapture.startCapture(outputPath: outputPath)
                print("TIMING startCapture took \(Date().timeIntervalSince(t0))s")
                let t1 = Date()
                startLiveTranscription()
                print("TIMING startLiveTranscription took \(Date().timeIntervalSince(t1))s")
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
            audioCapture.liveSink = nil
            liveASR?.stop()
            liveASR = nil
            livePartialText = ""
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

    // MARK: - Live Transcription (streaming, in-call)

    /// Create the persistent LiveASRService, wire its callbacks and warm the
    /// recognizer at app startup so the live preview is ready instantly when
    /// a call starts. Any failure only disables the preview.
    private func setupLiveASR() {
        let enabled = UserDefaults.standard.object(forKey: "liveTranscribe") as? Bool ?? true
        liveASR = nil
        guard enabled else { return }
        let svc = LiveASRService()
        svc.onPartial = { [weak appState = self] text in
            let owner = appState
            DispatchQueue.main.async { owner?.livePartialText = text }
        }
        svc.onFinal = { [weak appState = self] seg in
            let owner = appState
            DispatchQueue.main.async {
                guard let owner else { return }
                owner.liveSegments.append(seg)
                owner.livePartialText = ""
            }
        }
        svc.onFailure = { [weak appState = self] msg in
            let owner = appState
            DispatchQueue.main.async {
                guard let owner else { return }
                owner.liveTranscribeStatus = "En vivo no disponible"
                owner.logger.warning("Live ASR failure: \(msg)")
            }
        }
        liveASR = svc
        let model = UserDefaults.standard.string(forKey: "liveModel") ?? "zipformer-es"
        svc.warmup(model: model)
        logger.info("Live ASR warmup scheduled (\(model))")
    }

    /// Start the in-call streaming ASR preview (best-effort): feeds the
    /// 16 kHz mono mix from AudioCapture to the (warm) sherpa recognizer and
    /// surfaces partial/final text in the popover while the call runs.
    private func startLiveTranscription() {
        let enabled = UserDefaults.standard.object(forKey: "liveTranscribe") as? Bool ?? true
        liveSegments = []
        livePartialText = ""
        guard enabled, let svc = liveASR else {
            liveTranscribeStatus = enabled ? "En vivo no disponible" : ""
            return
        }
        let model = UserDefaults.standard.string(forKey: "liveModel") ?? "zipformer-es"
        svc.start(model: model)  // reuses the warm process
        audioCapture.liveSink = { [weak svc] samples in svc?.feed(samples) }
        liveTranscribeStatus = "En vivo · \(model)"
        logger.info("Live transcription started (\(model))")
    }

    // MARK: - Transcription

    /// Stream-transcribe a PCM file and run the full post-processing chain:
    /// segments → .txt → .pending v2 → retention → SQLite → notification.
    private func transcribe(audioPath: String) async {
        let outputPath = audioPath.replacingOccurrences(of: ".pcm", with: ".txt")
        await runTranscriptionPipeline(
            audioPath: audioPath,
            sampleRate: audioCapture.currentSampleRate,
            title: currentMeeting?.title,
            outputPath: outputPath,
            shouldApplyRetention: true,
            durableAudioPath: audioPath
        )
    }

    /// Shared transcription pipeline used by recordings, imports and
    /// re-transcriptions. Engine (whisper/sherpa with fallback), language,
    /// diarization and model all come from the current Settings.
    private func runTranscriptionPipeline(
        audioPath: String,
        sampleRate: Double,
        title: String?,
        outputPath: String,
        shouldApplyRetention: Bool,
        durableAudioPath: String
    ) async {
        phase = .transcribing
        transcriptionProgress = 0
        liveTranscriptBuffer = ""
        defer { whisperManager.stopRecording() }

        do {
            let engine = ASREngine.current()
            let diarize = UserDefaults.standard.object(forKey: "diarize") as? Bool ?? true

            guard let stream = WhisperTranscriber(
                audioPath: audioPath,
                sampleRate: sampleRate,
                whisperManager: whisperManager
            ) else {
                throw WhisperError.transcriptionFailed(reason: "Could not open \(audioPath)")
            }

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

            let segments = try await stream.runWithSegments(engine: engine, diarize: diarize)

            // Final .txt: one line per segment, "[Speaker X]: text" prefix
            // when a speaker label exists.
            let lines = segments.map { seg -> String in
                let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let speaker = seg.speaker, !speaker.isEmpty else { return text }
                return "[\(speaker)]: \(text)"
            }
            let finalText = lines.joined(separator: "\n")
            let outputURL = URL(fileURLWithPath: outputPath)
            try finalText.write(to: outputURL, atomically: true, encoding: .utf8)

            lastTranscriptPath = outputPath
            lastSegments = segments
            lastAudioPath = durableAudioPath

            // --- Critical path: .pending v2 contract (throws on failure) ---
            let speakerCount = Set(segments.compactMap(\.speaker)).count
            try await writePendingContractV2(
                transcriptPath: outputPath,
                transcriptContent: finalText,
                meetingTitle: title,
                audioPath: durableAudioPath,
                segments: segments,
                engine: engine,
                speakerCount: speakerCount
            )

            // --- Processed marker (no audio path — audio may be deleted) ---
            writeProcessedMarker(transcriptPath: outputPath, meetingTitle: title)

            // --- Retention only for fresh recordings (never imports) ---
            if shouldApplyRetention {
                await applyRetention(audioPath: audioPath, transcriptPath: outputPath)
            }

            // --- SQLite history ---
            let model = Self.currentModelString(engine: engine)
            let language = UserDefaults.standard.string(forKey: "asrLanguage") ?? "es"
            let started = recordingStartDate ?? Date()
            let ended = Date()
            store.insert(MeetingRecord(
                id: "meet-\(Int64(started.timeIntervalSince1970))",
                title: title ?? "Untitled Meeting",
                startedAt: started,
                endedAt: ended,
                durationSec: ended.timeIntervalSince(started),
                engine: engine.rawValue,
                model: model,
                language: language,
                transcriptPath: outputPath,
                summaryPath: nil,
                speakerCount: speakerCount,
                transcriptText: finalText
            ))
            refreshHistory()

            liveTranscriptBuffer = ""
            liveSegments = []
            livePartialText = ""
            transcriptionProgress = 1.0
            phase = .done

            // --- Local notification (gated by notifyHermes) ---
            let showNotification = UserDefaults.standard.object(forKey: "notifyHermes") as? Bool ?? true
            if showNotification {
                await sendLocalNotification(title: title ?? "Google Meet")
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

    // MARK: - Import & Enhance

    /// Import an audio file (wav/m4a/aiff/caf/pcm), normalize to 16kHz mono
    /// WAV, transcribe with the configured engine/model, save the transcript
    /// to ~/meetings/imports/ and write a .pending so the summary flow
    /// picks it up exactly like a live recording.
    func importAudio(url: URL) async {
        phase = .transcribing
        transcriptionProgress = 0
        do {
            let workPath: String
            var durableAudio: String

            if url.pathExtension.lowercased() == "pcm" {
                // Raw PCM without container — assume MeetCapture v5 on-disk
                // format (Int16 stereo 16kHz) and provide a format.json
                // sidecar so the transcriber can decode it.
                let tmpDir = FileManager.default.temporaryDirectory
                let tmpPCM = tmpDir.appendingPathComponent("import-\(UUID().uuidString).pcm")
                try FileManager.default.copyItem(at: url, to: tmpPCM)
                let sidecar: [String: Any] = [
                    "schema": "meetcapture.audio.v5",
                    "sample_rate": 16000,
                    "sample_format": "int16",
                    "channels": 2,
                    "layout": "interleaved",
                    "tap_strategy": "import",
                    "tap_info": "",
                ]
                try JSONSerialization.data(withJSONObject: sidecar)
                    .write(to: tmpPCM.appendingPathExtension("format.json"))
                workPath = tmpPCM.path
                durableAudio = url.path
            } else if WhisperTranscriber.is16kMonoWAV(url.path) {
                // Already normalized — use directly, keep the original.
                workPath = url.path
                durableAudio = url.path
            } else {
                // Normalize via afconvert (wav/m4a/aiff/caf → 16k mono WAV).
                let tmpWAV = FileManager.default.temporaryDirectory
                    .appendingPathComponent("import-\(UUID().uuidString).wav")
                try await convertWithAfconvert(input: url.path, output: tmpWAV.path)
                workPath = tmpWAV.path
                durableAudio = tmpWAV.path
            }

            // Destination: ~/meetings/imports/<fecha>-<nombre>.txt (+ .wav)
            let importsDir = importsDirectory()
            try FileManager.default.createDirectory(
                atPath: importsDir, withIntermediateDirectories: true)
            let base = "\(importsDir)/\(importStamp(for: url))"
            let outputPath = base + ".txt"

            // Keep a durable copy of the normalized WAV next to the
            // transcript so Re-transcribir can re-run it later.
            if workPath != url.path, workPath.hasSuffix(".wav") {
                try? FileManager.default.copyItem(atPath: workPath, toPath: base + ".wav")
                durableAudio = base + ".wav"
            }

            let title = url.deletingPathExtension().lastPathComponent
            await runTranscriptionPipeline(
                audioPath: workPath,
                sampleRate: audioCapture.currentSampleRate,
                title: title,
                outputPath: outputPath,
                shouldApplyRetention: false,
                durableAudioPath: durableAudio
            )
        } catch {
            logger.error("Import failed: \(error.localizedDescription)")
            errorMessage = "Import failed: \(error.localizedDescription)"
            phase = .idle
        }
    }

    /// Re-run transcription of the last saved audio with the current
    /// settings (engine/model/language/diarization).
    func retranscribeLastAudio() async {
        guard let audio = lastAudioPath else {
            errorMessage = "No saved audio to re-transcribe."
            return
        }
        guard FileManager.default.fileExists(atPath: audio) else {
            errorMessage = "Saved audio no longer exists (retention policy deleted it)."
            return
        }
        let outputPath = (audio as NSString).deletingPathExtension + "-retranscribed.txt"
        await runTranscriptionPipeline(
            audioPath: audio,
            sampleRate: audioCapture.currentSampleRate,
            title: currentMeeting?.title ?? "Re-transcripción",
            outputPath: outputPath,
            shouldApplyRetention: false,
            durableAudioPath: audio
        )
    }

    // MARK: - History

    /// Reload recent meetings from the store (respects current search).
    func searchHistory(_ query: String) {
        history = store.search(query)
    }

    private func refreshHistory() {
        history = store.recent(limit: 20)
    }

    private func importsDirectory() -> String {
        if let testDir = ProcessInfo.processInfo.environment["MEETCAPTURE_TEST_OUTPUT_DIR"],
           !testDir.isEmpty {
            return "\(testDir)/imports"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/meetings/imports"
    }

    private func importStamp(for url: URL) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmm"
        let stamp = df.string(from: Date())
        let name = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "\(stamp)-\(name)"
    }

    private func convertWithAfconvert(input: String, output: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input, output]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                cont.resume(throwing: error)
                return
            }
            guard process.terminationStatus == 0 else {
                cont.resume(throwing: WhisperError.transcriptionFailed(
                    reason: "afconvert failed (\(process.terminationStatus)) for \(input)"))
                return
            }
            cont.resume(returning: ())
        }
    }

    /// Model string reported in .pending / SQLite: the asrModel setting
    /// as-is ("medium-q5_0" for whisper, "parakeet"/"zipformer-es" for
    /// sherpa), with a sane default when unset.
    static func currentModelString(engine: ASREngine) -> String {
        let setting = UserDefaults.standard.string(forKey: "asrModel")
            ?? UserDefaults.standard.string(forKey: "whisperModel")
            ?? ""
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return engine == .sherpa ? "parakeet" : "medium-q5_0"
        }
        return trimmed
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

    // MARK: - .pending Handoff Contract (v2)

    /// Writes the v2 .pending contract consumed by
    /// HerMaatOS/bin/meetcapture_summary_dispatcher.py (external).
    /// Atomic write: tmp file + rename. Throws on failure — caller MUST
    /// NOT delete audio if this throws.
    private func writePendingContractV2(
        transcriptPath: String,
        transcriptContent: String,
        meetingTitle: String?,
        audioPath: String,
        segments: [Segment],
        engine: ASREngine,
        speakerCount: Int
    ) async throws {
        let fm = FileManager.default
        let pendingURL = URL(fileURLWithPath: pendingPath)
        try fm.createDirectory(
            at: pendingURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let iso = ISO8601DateFormatter()
        let started = recordingStartDate ?? Date()
        let ended = Date()
        let epoch = Int64(started.timeIntervalSince1970)

        var segmentDicts: [[String: Any]] = []
        segmentDicts.reserveCapacity(segments.count)
        for s in segments {
            var d: [String: Any] = ["start": s.start, "end": s.end, "text": s.text]
            if let speaker = s.speaker, !speaker.isEmpty {
                d["speaker"] = speaker
            }
            segmentDicts.append(d)
        }

        let audioExists = fm.fileExists(atPath: audioPath)

        // Canonical v2 contract — exact schema.
        let contract: [String: Any] = [
            "version": 2,
            "meetingId": "meet-\(epoch)",
            "title": meetingTitle ?? "Untitled Meeting",
            "startedAt": iso.string(from: started),
            "endedAt": iso.string(from: ended),
            "durationSec": ended.timeIntervalSince(started),
            "transcriptPath": transcriptPath,
            "audioPath": audioExists ? audioPath : NSNull(),
            "engine": engine.rawValue,
            "model": Self.currentModelString(engine: engine),
            "language": UserDefaults.standard.string(forKey: "asrLanguage") ?? "es",
            "segments": segmentDicts,
            "speakerCount": speakerCount,
            "checksum": Self.sha256Hex(transcriptContent),
        ]

        let data = try JSONSerialization.data(withJSONObject: contract, options: [.prettyPrinted, .sortedKeys])

        // Atomic: write tmp, then rename over the destination.
        let tmpURL = pendingURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        try data.write(to: tmpURL, options: .atomic)
        _ = try? fm.removeItem(at: pendingURL)
        try fm.moveItem(at: tmpURL, to: pendingURL)

        logger.info("Pending handoff v2 written: \(self.pendingPath)")
    }

    /// SHA-256 hex digest of the transcript text (CryptoKit).
    static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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

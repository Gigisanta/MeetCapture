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
    
    // MARK: - Services
    
    let calendarService = CalendarService()
    let audioCapture = AudioCaptureService()
    let daemonManager = DaemonManager()
    let whisperManager = WhisperModelManager.shared
    let socketClient = SocketClient()
    let energyManager = EnergyManager()
    
    // MARK: - Private
    
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private let transcriptDir: String
    
    // MARK: - Init
    
    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        transcriptDir = "\(home)/.hermes/TechPartners/MaatWork/meetings/transcripts"
        
        AppState.shared = self
        
        setupBindings()
        setupMeetingDetection()
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
        
        // Request permissions
        await requestPermissions()
        logger.info("Permissions: calendar=\(self.hasCalendarAccess) audio=\(self.hasAudioPermission)")
        
        // Register daemon
        daemonManager.registerIfNeeded()
        
        // Connect to daemon (best effort)
        do {
            try socketClient.connect()
        } catch {
            // Non-fatal: daemon might not be running yet
        }
        
        // Request notification permission
        requestNotificationPermission()
        
        phase = .idle
    }
    
    func shutdown() {
        if phase == .recording {
            stopRecording()
        }
        socketClient.disconnect()
        energyManager.endRecordingActivity()
    }
    
    // MARK: - Permissions
    
    private func requestPermissions() async {
        // Calendar
        await calendarService.requestAccess()
        hasCalendarAccess = calendarService.isAuthorized
        
        // Audio (Screen Recording)
        hasAudioPermission = audioCapture.checkPermission()
        if !hasAudioPermission {
            audioCapture.requestPermission()
        }
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    
    // MARK: - Meeting Detection
    
    private func setupMeetingDetection() {
        // React to calendar changes
        calendarService.$upcomingMeetings
            .receive(on: DispatchQueue.main)
            .sink { [weak self] meetings in
                self?.evaluateMeetings(meetings)
            }
            .store(in: &cancellables)
    }
    
    private func evaluateMeetings(_ meetings: [Meeting]) {
        guard phase == .idle || phase == .approaching else { return }
        
        // Find next meeting within 5 minutes
        if let next = meetings.first(where: { $0.timeUntilStart <= 300 && $0.timeUntilStart > -60 }) {
            if phase != .approaching {
                phase = .approaching
                currentMeeting = next
                // Auto-start recording when meeting starts
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
        
        // Re-check permission (user may have just granted it in System Settings)
        hasAudioPermission = audioCapture.checkPermission()

        guard hasAudioPermission else {
            audioCapture.requestPermission()
            errorMessage = "Grant Screen Recording permission, then try again"
            return
        }
        
        let outputPath = "\(transcriptDir)/recording-\(Date().timeIntervalSince1970).pcm"

        // Begin energy assertion
        energyManager.beginRecordingActivity()
        
        // Start audio capture
        Task {
            do {
                try await audioCapture.startCapture(outputPath: outputPath)

                // Load whisper model for transcription
                do {
                    try whisperManager.startRecording()
                } catch {
                    // Non-fatal: transcription will fall back to daemon
                }
                
                phase = .recording
                recordingStartDate = Date()
                startRecordingTimer()
                
                // Notify daemon via socket (best effort)
                do {
                    _ = try socketClient.startRecording(meetingTitle: currentMeeting?.title ?? "Unknown")
                } catch {
                    // Socket failure is non-fatal — recording continues locally
                }
            } catch {
                errorMessage = "Recording failed: \(error.localizedDescription)"
                phase = .idle
                energyManager.endRecordingActivity()
            }
        }
    }
    
    func stopRecording() {
        guard phase == .recording else { return }
        
        phase = .transcribing
        stopRecordingTimer()
        
        Task {
            // Stop audio capture
            await audioCapture.stopCapture()
            
            // Notify daemon (best effort)
            do {
                _ = try socketClient.stopRecording()
            } catch {
                // Socket failure is non-fatal
            }
            
            // Start transcription
            if let pcmPath = audioCapture.currentOutputPath {
                await transcribe(audioPath: pcmPath)
            }
            
            // End energy assertion
            energyManager.endRecordingActivity()
            
            // Unload whisper model to free memory
            whisperManager.stopRecording()
        }
    }
    
    // MARK: - Transcription
    
    private func transcribe(audioPath: String) async {
        do {
            let outputPath = audioPath.replacingOccurrences(of: ".pcm", with: ".txt")
            
            // Use whisper to transcribe
            let pcmData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
            let samples = pcmToFloat32(pcmData)
            
            let text = try whisperManager.transcribe(samples: samples)
            
            // Write transcript
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            
            lastTranscriptPath = outputPath
            phase = .done
            
            // Notify Hermes
            notifyHermes(transcriptPath: outputPath, meetingTitle: currentMeeting?.title)
            
            // Return to idle after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.phase = .idle
                self?.currentMeeting = nil
            }
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            phase = .idle
        }
    }
    
    // MARK: - Helpers
    
    private func setupBindings() {
        // Reset error after 10 seconds
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
    
    private func pcmToFloat32(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(count))
        }
    }
    
    private func notifyHermes(transcriptPath: String, meetingTitle: String?) {
        let title = meetingTitle ?? "Google Meet"
        let notificationText = "Meeting transcript ready: \(title)"
        
        // macOS local notification via UserNotifications framework
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

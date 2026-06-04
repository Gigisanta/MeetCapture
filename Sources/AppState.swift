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
    
    // MARK: - Private
    
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var cancellables = Set<AnyCancellable>()
    private let transcriptDir: String
    private var energyActivity: NSObjectProtocol?
    
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
        
        await requestPermissions()
        logger.info("Permissions: calendar=\(self.hasCalendarAccess) audio=\(self.hasAudioPermission)")
        
        daemonManager.registerIfNeeded()
        requestNotificationPermission()
        
        phase = .idle
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
            audioCapture.requestPermission()
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
            audioCapture.requestPermission()
            errorMessage = "Grant Screen Recording permission, then try again"
            return
        }
        
        let outputPath = "\(transcriptDir)/recording-\(Date().timeIntervalSince1970).pcm"
        beginRecordingActivity()
        
        Task {
            do {
                try await audioCapture.startCapture(outputPath: outputPath)
                do {
                    try whisperManager.startRecording()
                } catch {
                    // Non-fatal
                }
                
                phase = .recording
                recordingStartDate = Date()
                startRecordingTimer()
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
        stopRecordingTimer()
        
        Task {
            await audioCapture.stopCapture()
            endRecordingActivity()
            whisperManager.stopRecording()
        }
    }
    
    // MARK: - Transcription
    
    private func transcribe(audioPath: String) async {
        do {
            let outputPath = audioPath.replacingOccurrences(of: ".pcm", with: ".txt")
            let pcmData = try Data(contentsOf: URL(fileURLWithPath: audioPath))
            let samples = pcmToFloat32(pcmData)
            let text = try whisperManager.transcribe(samples: samples)
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            
            lastTranscriptPath = outputPath
            phase = .done
            notifyHermes(transcriptPath: outputPath, meetingTitle: currentMeeting?.title)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.phase = .idle
                self?.currentMeeting = nil
            }
        } catch {
            errorMessage = "Transcription failed: \(error.localizedDescription)"
            phase = .idle
        }
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
    
    private func pcmToFloat32(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(count))
        }
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

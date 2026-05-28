// StatusView.swift
// MeetCapture v4 — Menu bar dropdown content

import SwiftUI

struct StatusView: View {
    @ObservedObject var appState: AppState
    
    var body: some View {
        // Header
        Section {
            HStack {
                Image(systemName: appState.menuBarIcon)
                    .foregroundColor(appState.menuBarColor)
                    .font(.title3)
                Text("MeetCapture")
                    .font(.headline)
                Spacer()
                Text(appState.phase.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        
        Divider()
        
        // Current status
        Section {
            switch appState.phase {
            case .idle:
                idleView
            case .approaching:
                approachingView
            case .recording:
                recordingView
            case .transcribing:
                transcribingView
            case .done:
                doneView
            }
        }
        
        Divider()
        
        // Calendar info
        Section {
            if let next = appState.calendarService.nextMeeting {
                Label(next.title, systemImage: "calendar")
                    .font(.caption)
                Text("in \(next.timeUntilStartFormatted)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("No upcoming meetings", systemImage: "calendar.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        
        Divider()
        
        // Actions
        Section {
            Button(action: { appState.startRecording() }) {
                Label("Start Recording", systemImage: "record.circle")
            }
            .disabled(appState.phase == .recording || appState.phase == .transcribing)
            
            Button(action: { appState.stopRecording() }) {
                Label("Stop Recording", systemImage: "stop.circle")
            }
            .disabled(appState.phase != .recording)
            
            if let path = appState.lastTranscriptPath {
                Button(action: { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }) {
                    Label("Show Last Transcript", systemImage: "doc.text")
                }
            }
        }
        
        Divider()
        
        // Settings & Quit
        Section {
            Button(action: { appState.daemonManager.openSystemSettings() }) {
                Label("Login Items", systemImage: "gear")
            }
            
            Button(action: { NSApp.terminate(nil) }) {
                Label("Quit MeetCapture", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
    }
    
    // MARK: - Phase Views
    
    private var idleView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Waiting for meeting", systemImage: "moon.zzz")
                .font(.caption)
            Text("Monitoring calendar for Google Meet calls")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    private var approachingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let meeting = appState.currentMeeting {
                Label(meeting.title, systemImage: "video.fill")
                    .font(.caption)
                Text("Starting in \(meeting.timeUntilStartFormatted)")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
    }
    
    private var recordingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .opacity(appState.recordingDuration.truncatingRemainder(dividingBy: 2) < 1 ? 1 : 0.3)
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(.caption, design: .monospaced))
            }
            if let meeting = appState.currentMeeting {
                Text(meeting.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var transcribingView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Transcribing...", systemImage: "waveform")
                .font(.caption)
                .foregroundColor(.orange)
            ProgressView(value: appState.transcriptionProgress)
                .progressViewStyle(.linear)
        }
    }
    
    private var doneView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Transcript ready", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
            if let path = appState.lastTranscriptPath {
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

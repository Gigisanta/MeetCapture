// SettingsView.swift
// MeetCapture v4 — Preferences window

import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage("autoRecord") private var autoRecord = true
    @AppStorage("whisperModel") private var whisperModel = "large-v3-turbo"
    @AppStorage("notifyHermes") private var notifyHermes = true
    @AppStorage("transcriptDir") private var transcriptDir = ""
    
    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gear") }
            
            audioSettings
                .tabItem { Label("Audio", systemImage: "speaker.wave.3") }
            
            calendarSettings
                .tabItem { Label("Calendar", systemImage: "calendar") }
            
            aboutView
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 450, height: 300)
    }
    
    // MARK: - General
    
    private var generalSettings: some View {
        Form {
            Toggle("Auto-record when meeting detected", isOn: $autoRecord)
            
            Toggle("Notify Hermes on transcript ready", isOn: $notifyHermes)
            
            HStack {
                Text("Daemon status:")
                Spacer()
                Circle()
                    .fill(appState.isDaemonRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.isDaemonRunning ? "Running" : "Stopped")
                    .font(.caption)
            }
            
            Button("Open Login Items") {
                appState.daemonManager.openSystemSettings()
            }
        }
        .padding()
    }
    
    // MARK: - Audio
    
    private var audioSettings: some View {
        Form {
            Picker("Whisper Model", selection: $whisperModel) {
                Text("tiny (75MB, fastest)").tag("tiny")
                Text("base (142MB, fast)").tag("base")
                Text("small (461MB, balanced)").tag("small")
                Text("large-v3-turbo (1.6GB, best)").tag("large-v3-turbo")
            }
            
            HStack {
                Text("Screen Recording permission:")
                Spacer()
                Circle()
                    .fill(appState.hasAudioPermission ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.hasAudioPermission ? "Granted" : "Required")
                    .font(.caption)
            }
            
            if !appState.hasAudioPermission {
                Button("Grant Permission") {
                    appState.audioCapture.requestPermission()
                }
            }
        }
        .padding()
    }
    
    // MARK: - Calendar
    
    private var calendarSettings: some View {
        Form {
            HStack {
                Text("Calendar access:")
                Spacer()
                Circle()
                    .fill(appState.hasCalendarAccess ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.hasCalendarAccess ? "Granted" : "Required")
                    .font(.caption)
            }
            
            if !appState.hasCalendarAccess {
                Button("Grant Access") {
                    Task {
                        await appState.calendarService.requestAccess()
                    }
                }
            }
            
            Text("Whitelisted emails:")
                .font(.caption)
            ForEach(Array(CalendarService.whitelistedEmails), id: \.self) { email in
                Text(email)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
    
    // MARK: - About
    
    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("MeetCapture")
                .font(.title2)
            
            Text("v4.0.0")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            Text("Automatic Google Meet transcription")
                .font(.caption)
            
            Link("GitHub", destination: URL(string: "https://github.com/Gigisanta/MeetCapture")!)
                .font(.caption)
        }
        .padding()
    }
}

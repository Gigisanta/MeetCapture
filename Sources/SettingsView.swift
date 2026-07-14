// SettingsView.swift
// MeetCapture v4 — Preferences window

import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @AppStorage("autoRecord") private var autoRecord = true
    @AppStorage("whisperModel") private var whisperModel = "medium"
    @AppStorage("notifyHermes") private var notifyHermes = true
    @AppStorage("transcriptDir") private var transcriptDir = ""
    @AppStorage("retention") private var retention = RetentionPolicy.deleteAfterHandoff.rawValue

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
        .frame(width: 450, height: 350)
    }

    // MARK: - General

    private var generalSettings: some View {
        Form {
            Toggle("Auto-record live calls & calendar meetings", isOn: $autoRecord)
            Text("Starts recording when a browser, Zoom, Teams or FaceTime is using the mic — even for ad-hoc calls not on your calendar.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("Show local notification on transcript ready", isOn: $notifyHermes)

            Divider()

            Picker("Retention", selection: $retention) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy.rawValue)
                }
            }
            Text("Controls how long raw audio is kept after transcription. 'Delete after handoff' removes it immediately. 'Keep 24h' defers cleanup to the next launch. 'Keep forever' preserves everything.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    // MARK: - Audio

    private var audioSettings: some View {
        Form {
            Picker("Whisper Model", selection: $whisperModel) {
                Text("tiny (75MB, fastest)").tag("tiny")
                Text("base (142MB, fast — safe on 8GB)").tag("base")
                Text("small (461MB, balanced)").tag("small")
                Text("medium (1.4GB, high accuracy)").tag("medium")
                Text("large-v3-turbo (1.6GB, best)").tag("large-v3-turbo")
            }
            Text("Auto-downgrades if free RAM is low. Undownloaded models fall back to the best available.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Text("Microphone permission:")
                Spacer()
                Circle()
                    .fill(appState.hasAudioPermission ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.hasAudioPermission ? "Granted" : "Required")
                    .font(.caption)
            }

            if !appState.hasAudioPermission {
                Button("Grant Permission") {
                    appState.audioCapture.requestPermission { granted in
                        appState.hasAudioPermission = granted
                    }
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

            Text("v4.4.0")
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

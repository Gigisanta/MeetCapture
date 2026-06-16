// PopoverContent.swift
// MeetCapture v4 — minimal, native popover.
// Compact and content-sized: a status line, one primary action that toggles
// Record/Stop, and a thin footer. Uses system materials instead of a heavy
// custom gradient so it reads as a native macOS menu-bar popover.

import SwiftUI
import AppKit

struct PopoverContent: View {
    @ObservedObject var appState: AppState
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !appState.hasAudioPermission { permissionRow }
            statusRow
            if appState.phase == .transcribing || !appState.liveTranscriptBuffer.isEmpty {
                liveTranscript
            }
            if let next = appState.calendarService.nextMeeting, appState.phase != .recording {
                upcomingRow(next)
            }
            primaryButton
            Divider()
            footer
        }
        .padding(14)
        .frame(width: Self.width)
        .background(.regularMaterial)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(phaseColor)
                .frame(width: 8, height: 8)
            Text("MeetCapture")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(appState.phase.rawValue.capitalized)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permission

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(Brand.warnAmber)
            VStack(alignment: .leading, spacing: 1) {
                Text("Microphone access needed")
                    .font(.system(size: 12, weight: .medium))
                Text("Captures your voice + the call audio.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant") {
                appState.audioCapture.requestPermission { granted in
                    appState.hasAudioPermission = granted
                }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Brand.warnAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Status

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: appState.menuBarIcon)
                .font(.system(size: 18))
                .foregroundStyle(phaseColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(statusHeadline)
                    .font(.system(size: 12, weight: .medium))
                Text(statusSubline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if appState.phase == .recording {
                Text(formatDuration(appState.recordingDuration))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Brand.recordingRed)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Live transcript

    private var liveTranscript: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(appState.liveTranscriptBuffer.isEmpty ? "Listening…" : appState.liveTranscriptBuffer)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            if appState.phase == .transcribing {
                ProgressView(value: appState.transcriptionProgress)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Upcoming

    private func upcomingRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(meeting.title)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            Text(meetingCountdown(for: meeting))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Primary action (toggles)

    @ViewBuilder
    private var primaryButton: some View {
        switch appState.phase {
        case .recording:
            Button(role: .destructive) { appState.stopRecording() } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(Brand.recordingRed)
        case .transcribing:
            Button {} label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Transcribing…")
                }
                .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(true)
        default:
            Button { appState.startRecording() } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Brand.recordingRed)
            .disabled(!appState.hasAudioPermission)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let path = appState.lastTranscriptPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Last transcript", systemImage: "doc.text")
                        .font(.system(size: 11))
                }
                .buttonStyle(.link)
            }
            Spacer()
            HStack(spacing: 4) {
                Circle()
                    .fill(appState.isDaemonRunning ? Brand.successGreen : .secondary)
                    .frame(width: 5, height: 5)
                Text("v4.2.0")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help("Quit (⌘Q)")
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Derived

    private var phaseColor: Color {
        switch appState.phase {
        case .recording:    return Brand.recordingRed
        case .transcribing: return Brand.transcribingOrange
        case .done:         return Brand.successGreen
        case .approaching:  return Brand.pastelViolet
        case .idle:         return .secondary
        }
    }

    private var statusHeadline: String {
        switch appState.phase {
        case .idle:         return "Ready"
        case .approaching:  return appState.currentMeeting?.title ?? "Meeting starting"
        case .recording:    return "Recording"
        case .transcribing: return "Transcribing"
        case .done:         return "Transcript ready"
        }
    }

    private var statusSubline: String {
        switch appState.phase {
        case .idle:         return "Watching for Google Meet calls"
        case .approaching:  return "Auto-record starts when it begins"
        case .recording:    return "Capturing mic + call audio"
        case .transcribing: return "Generating transcript locally"
        case .done:         return "Saved to your transcripts folder"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let m = Int(duration) / 60, s = Int(duration) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private func meetingCountdown(for meeting: Meeting) -> String {
        let interval = meeting.startDate.timeIntervalSince(now)
        if interval < 0 && meeting.endDate > now { return "now" }
        if interval < 0 { return "ended" }
        let m = Int(interval) / 60
        if m >= 60 { return "in \(m / 60)h \(m % 60)m" }
        return "in \(m)m"
    }
}

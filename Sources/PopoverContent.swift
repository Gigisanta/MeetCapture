// PopoverContent.swift
// MeetCapture v4 — Phase 4 premium popover UI
// Replaces the cramped MenuBarExtra menu with a 360x520 branded popover.

import SwiftUI
import AppKit

struct PopoverContent: View {
    @ObservedObject var appState: AppState
    @State private var now: Date = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Layered background for proper glassmorphism depth
            Brand.heroGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                heroHeader
                Divider().opacity(0.3)
                ScrollView {
                    VStack(spacing: 12) {
                        permissionBanner
                        liveTranscriptCard
                        currentStatusCard
                        upcomingMeetingCard
                        actionsCard
                    }
                    .padding(14)
                }
                Divider().opacity(0.3)
                footerBar
            }
        }
        .frame(width: 360, height: 520)
        .background(WindowAccessor())
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Brand.pastelViolet, Brand.pastelVioletDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 38, height: 38)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("MeetCapture")
                    .font(Brand.heroTitle)
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.isDaemonRunning ? Brand.successGreen : Brand.warnAmber)
                        .frame(width: 6, height: 6)
                    Text(appState.isDaemonRunning ? "Daemon online" : "Daemon offline")
                        .font(Brand.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("v4.2.0")
                    .font(Brand.label)
                    .foregroundStyle(.white.opacity(0.5))
                Text(appState.phase.rawValue.capitalized)
                    .font(Brand.label)
                    .foregroundStyle(phaseColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Permission Banner

    @ViewBuilder
    private var permissionBanner: some View {
        if !appState.hasAudioPermission {
            Brand.glassCard(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(height: 96)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Brand.warnAmber)
                            Text("Screen Recording required")
                                .font(Brand.cardTitle)
                                .foregroundStyle(.white)
                        }
                        Text("MeetCapture captures system audio from your Google Meet calls. Grant access in System Settings.")
                            .font(Brand.cardSubtitle)
                            .foregroundStyle(.white.opacity(0.75))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Open System Settings") {
                                appState.audioCapture.openPrivacySettings()
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Brand.pastelViolet)
                            .controlSize(.small)
                            Button("Retry") {
                                appState.hasAudioPermission = appState.audioCapture.checkPermission()
                            }
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.6))
                            .controlSize(.small)
                        }
                    }
                    .padding(12),
                    alignment: .topLeading
                )
        }
    }

    // MARK: - Live Transcript

    @ViewBuilder
    private var liveTranscriptCard: some View {
        if appState.phase == .transcribing || !appState.liveTranscriptBuffer.isEmpty {
            Brand.glassCard(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(minHeight: 80, maxHeight: 140)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "waveform")
                                .foregroundStyle(Brand.transcribingOrange)
                            Text("Live transcript")
                                .font(Brand.cardTitle)
                                .foregroundStyle(.white)
                            Spacer()
                            if appState.phase == .transcribing {
                                Text("\(Int(appState.transcriptionProgress * 100))%")
                                    .font(Brand.label)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        Text(appState.liveTranscriptBuffer.isEmpty ? "Listening…" : appState.liveTranscriptBuffer)
                            .font(Brand.cardSubtitle)
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(4)
                            .truncationMode(.tail)
                        if appState.phase == .transcribing {
                            ProgressView(value: appState.transcriptionProgress)
                                .progressViewStyle(.linear)
                                .tint(Brand.pastelViolet)
                        }
                    }
                    .padding(12),
                    alignment: .topLeading
                )
        }
    }

    // MARK: - Current Status

    private var currentStatusCard: some View {
        Brand.glassCard(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(minHeight: 80)
            .overlay(
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(phaseColor.opacity(0.18))
                            .frame(width: 48, height: 48)
                        Image(systemName: appState.menuBarIcon)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(phaseColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(statusHeadline)
                            .font(Brand.cardTitle)
                            .foregroundStyle(.white)
                        Text(statusSubline)
                            .font(Brand.cardSubtitle)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                    Spacer()
                    if appState.phase == .recording {
                        VStack(alignment: .trailing) {
                            Text(formatDuration(appState.recordingDuration))
                                .font(Brand.monoCountdown)
                                .foregroundStyle(Brand.recordingRed)
                            Text("REC")
                                .font(Brand.label)
                                .foregroundStyle(Brand.recordingRed.opacity(0.8))
                        }
                    }
                }
                .padding(14),
                alignment: .leading
            )
    }

    // MARK: - Upcoming Meeting

    @ViewBuilder
    private var upcomingMeetingCard: some View {
        if let next = appState.calendarService.nextMeeting {
            Brand.glassCard(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(minHeight: 60)
                .overlay(
                    HStack(spacing: 12) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Brand.pastelVioletSoft)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.title)
                                .font(Brand.cardTitle)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(meetingCountdown(for: next))
                                .font(Brand.cardSubtitle)
                                .foregroundStyle(Brand.pastelVioletSoft)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(formattedTimeOfDay(next.startDate))
                                .font(Brand.label)
                                .foregroundStyle(.white.opacity(0.8))
                            if !next.externalAttendees.isEmpty {
                                Text("\(next.externalAttendees.count) externos")
                                    .font(Brand.caption)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .padding(12),
                    alignment: .leading
                )
        }
    }

    // MARK: - Actions

    private var actionsCard: some View {
        HStack(spacing: 10) {
            Button(action: { appState.startRecording() }) {
                Label("Record", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.recordingRed)
            .controlSize(.large)
            .disabled(!appState.hasAudioPermission || appState.phase == .recording || appState.phase == .transcribing)

            Button(action: { appState.stopRecording() }) {
                Label("Stop", systemImage: "stop.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.white.opacity(0.8))
            .controlSize(.large)
            .disabled(appState.phase != .recording)
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 14) {
            if let path = appState.lastTranscriptPath {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }) {
                    Label("Open transcript", systemImage: "doc.text")
                        .font(Brand.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.pastelVioletSoft)
            }
            Spacer()
            Button(action: { appState.daemonManager.openSystemSettings() }) {
                Image(systemName: "gear")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

// MARK: - Helpers

/// Enables the .window MenuBarExtra style to be visually transparent so
/// the gradient + glassmorphism underneath actually shows through.
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            if let w = v.window {
                w.isOpaque = false
                w.backgroundColor = .clear
                w.titlebarAppearsTransparent = true
                w.hasShadow = true
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

    private var phaseColor: Color {
        switch appState.phase {
        case .recording:    return Brand.recordingRed
        case .transcribing: return Brand.transcribingOrange
        case .done:         return Brand.successGreen
        case .approaching:  return Brand.pastelViolet
        case .idle:         return .white.opacity(0.5)
        }
    }

    private var statusHeadline: String {
        switch appState.phase {
        case .idle:         return "Waiting for meeting"
        case .approaching:  return appState.currentMeeting?.title ?? "Meeting approaching"
        case .recording:    return "Recording in progress"
        case .transcribing: return "Transcribing audio"
        case .done:         return "Transcript ready"
        }
    }

    private var statusSubline: String {
        switch appState.phase {
        case .idle:         return "Monitoring your calendar for Google Meet calls"
        case .approaching:  return "Auto-record will start when the meeting begins"
        case .recording:    return "Capturing system audio to disk"
        case .transcribing: return "Whisper is generating your transcript"
        case .done:         return "Saved to your transcripts folder"
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func meetingCountdown(for meeting: Meeting) -> String {
        let interval = meeting.startDate.timeIntervalSince(now)
        if interval < 0 && meeting.endDate > now { return "In progress" }
        if interval < 0 { return "Ended" }
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        if m > 60 {
            let h = m / 60
            return "in \(h)h \(m % 60)m"
        }
        return "in \(m)m \(s)s"
    }

    private func formattedTimeOfDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

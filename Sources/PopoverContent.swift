// PopoverContent.swift
// MeetCapture v5.1 — native popover with live transcript (timestamps +
// speakers + Copy), Import & Enhance, and SQLite-backed history/search.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct PopoverContent: View {
    @ObservedObject var appState: AppState
    @State private var now: Date = Date()
    @State private var searchText = ""
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let width: CGFloat = 360

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !appState.hasAudioPermission { permissionRow }
                statusRow
                if appState.phase == .transcribing || !appState.liveTranscriptBuffer.isEmpty || !appState.lastSegments.isEmpty {
                    liveTranscript
                }
                if let next = appState.calendarService.nextMeeting, appState.phase != .recording {
                    upcomingRow(next)
                }
                primaryButton
                Divider()
                historySection
                Divider()
                footer
            }
            .padding(14)
        }
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
                    Task { @MainActor in appState.hasAudioPermission = granted }
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
            HStack {
                Text(appState.phase == .transcribing ? "Transcribing…" : "Transcript")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !transcriptDisplay.isEmpty {
                    Button("Copy") { copyTranscript() }
                        .controlSize(.small)
                        .help("Copy full transcript to clipboard")
                }
            }
            ScrollView {
                Text(transcriptDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            if appState.phase == .transcribing {
                ProgressView(value: appState.transcriptionProgress)
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Segments with [mm:ss] timestamps + [Speaker] prefix when present;
    /// falls back to the raw live buffer while streaming.
    private var transcriptDisplay: String {
        if !appState.lastSegments.isEmpty {
            return appState.lastSegments.map { seg in
                var line = "[\(formatTimestamp(seg.start))]"
                if let speaker = seg.speaker, !speaker.isEmpty {
                    line += " [\(speaker)]:"
                }
                line += " " + seg.text
                return line
            }.joined(separator: "\n")
        }
        return appState.liveTranscriptBuffer
    }

    private func copyTranscript() {
        let text: String
        if let path = appState.lastTranscriptPath,
           let content = try? String(contentsOfFile: path, encoding: .utf8),
           !content.isEmpty {
            text = content
        } else {
            text = transcriptDisplay
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
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

    // MARK: - History (SQLite)

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if appState.lastAudioPath != nil {
                    Button("Re-transcribe") {
                        Task { await appState.retranscribeLastAudio() }
                    }
                    .controlSize(.small)
                    .help("Re-run transcription of the last saved audio with current settings")
                }
            }
            TextField("Search meetings…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onChange(of: searchText) { _, newValue in
                    appState.searchHistory(newValue)
                }
            if appState.history.isEmpty {
                Text("No meetings yet")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.history) { record in
                            historyRow(record)
                        }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
    }

    private func historyRow(_ record: MeetingRecord) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text("\(record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.engine)\(record.speakerCount > 0 ? " · \(record.speakerCount) speakers" : "")")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: record.transcriptPath)])
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.plain)
            .help(record.transcriptPath)
        }
        .padding(4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                importAudio()
            } label: {
                Label("Import audio…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.link)
            .help("Transcribe an audio file (wav, m4a, aiff, caf, pcm)")
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
                Text("v6.0.0")
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

    // MARK: - Import

    private func importAudio() {
        let panel = NSOpenPanel()
        panel.title = "Import audio to transcribe"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let extra = ["caf", "pcm"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = [.wav, .mpeg4Audio, .aiff] + extra
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await appState.importAudio(url: url)
        }
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

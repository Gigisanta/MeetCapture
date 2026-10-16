// PopoverContent.swift
// The menu-bar popover: one scroll view, state first, primary action
// right under it, then next meeting, transcript, history and footer.

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
protocol PopoverStateModel: ObservableObject {
    var phase: AppPhase { get }
    var currentMeeting: Meeting? { get }
    var nextMeeting: Meeting? { get }
    var errorMessage: String? { get }
    var hasAudioPermission: Bool { get }
    var recordingDuration: TimeInterval { get }
    var transcriptionProgress: Double { get }
    var lastTranscriptPath: String? { get }
    var lastSegments: [Segment] { get }
    var lastAudioPath: String? { get }
    var history: [MeetingSummary] { get }
    var historyQuery: String { get set }
    var meetingNotes: String { get set }
    var isStartingRecording: Bool { get }
    var canRequestAudioPermission: Bool { get }
    var captureWarning: CaptureWarning? { get }
    var pendingRecordingCount: Int { get }
    var isRecovering: Bool { get }

    func requestAudioPermission()
    func openSystemAudioSettings()
    func transcribePendingRecordings()
    func startRecording()
    func stopRecording()
    func importAudioPicker()
    func retranscribeLastAudio() async
    func showTranscript(_ record: MeetingSummary)
    func openSettings()
    func quit()
}

@MainActor
struct PopoverContent<Model: PopoverStateModel>: View {
    @ObservedObject var appState: Model
    @AppStorage(Settings.Key.micOnlyMode.rawValue) private var micOnlyMode = Settings.Default.micOnlyMode
    @State private var now = Date()
    private let allowsSettings: Bool
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    static var width: CGFloat { 360 }

    init(appState: Model, settingsStore: UserDefaults = .standard, allowsSettings: Bool = true) {
        self._appState = ObservedObject(wrappedValue: appState)
        self.allowsSettings = allowsSettings
        self._micOnlyMode = AppStorage(
            wrappedValue: Settings.Default.micOnlyMode,
            Settings.Key.micOnlyMode.rawValue, store: settingsStore)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if !appState.hasAudioPermission { permissionBanner }
                statusCard
                primaryButton
                if let warning = appState.captureWarning { captureWarningBanner(warning) }
                if appState.isRecovering || appState.pendingRecordingCount > 0 { recoveryRow }
                if appState.phase == .recording, !appState.isStartingRecording { meetingNotesCard }
                if let error = appState.errorMessage { errorRow(error) }
                if let next = appState.nextMeeting,
                   appState.phase == .idle || appState.phase == .approaching {
                    nextMeetingRow(next)
                }
                if !appState.isStartingRecording,
                   appState.phase == .transcribing || appState.phase == .done || !appState.lastSegments.isEmpty {
                    transcriptCard
                }
                Divider()
                historySection
                Divider()
                footer
            }
            .padding(14)
        }
        .frame(width: Self.width)
        .frame(minHeight: 320)
        .background(.regularMaterial)
        .onReceive(tick) { now = $0 }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text(Strings.appName)
                .font(.system(size: 13, weight: .semibold))
            Text(Strings.phase(appState.phase, isStartingRecording: appState.isStartingRecording))
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(phaseColor.opacity(0.15), in: Capsule())
                .foregroundStyle(phaseColor)
            Spacer()
            Text("v\(AppInfo.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Permission

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash.fill").foregroundStyle(Brand.warnAmber)
            VStack(alignment: .leading, spacing: 1) {
                Text(Strings.micPermissionTitle).font(.system(size: 12, weight: .medium))
                Text(appState.canRequestAudioPermission ? Strings.micPermissionBody : Strings.micPermissionDenied)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(appState.canRequestAudioPermission ? Strings.grant : Strings.openPrivacySettings) {
                appState.requestAudioPermission()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Brand.warnAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func captureWarningBanner(_ warning: CaptureWarning) -> some View {
        HStack(spacing: 8) {
            Image(systemName: warning == .systemSilent ? "speaker.slash.fill" : "mic.slash.fill")
                .foregroundStyle(Brand.warnAmber)
            VStack(alignment: .leading, spacing: 1) {
                Text(warning == .systemSilent ? Strings.systemAudioSilentTitle : Strings.micSilentTitle)
                    .font(.system(size: 12, weight: .medium))
                Text(warning == .systemSilent ? Strings.systemAudioSilentBody : Strings.micSilentBody)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if warning == .systemSilent {
                Button(Strings.openPrivacySettings) { appState.openSystemAudioSettings() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(Brand.warnAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var recoveryRow: some View {
        HStack(spacing: 8) {
            if appState.isRecovering {
                ProgressView().controlSize(.small)
                Text(Strings.recovering).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                Text(Strings.pendingRecordings(appState.pendingRecordingCount)).font(.system(size: 11))
                Spacer()
                Button(Strings.transcribePending) { appState.transcribePendingRecordings() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: menuBarIcon(for: appState.phase,
                                              isStartingRecording: appState.isStartingRecording))
                    .font(.system(size: 18))
                    .foregroundStyle(phaseColor)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Strings.headline(appState.phase, meeting: appState.currentMeeting,
                                          isStartingRecording: appState.isStartingRecording))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(Strings.subline(appState.phase, micOnly: micOnlyMode,
                                         isStartingRecording: appState.isStartingRecording))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if appState.phase == .recording, !appState.isStartingRecording {
                    Text(formatDuration(appState.recordingDuration))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Brand.recordingRed)
                        .monospacedDigit()
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Primary action

    private var meetingNotesCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(Strings.myNotes).font(.system(size: 11, weight: .semibold))
            ZStack(alignment: .topLeading) {
                if appState.meetingNotes.isEmpty {
                    Text(Strings.notesPlaceholder)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $appState.meetingNotes)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(Strings.myNotes)
            }
            .frame(height: 80)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var primaryButton: some View {
        if appState.isStartingRecording {
            Button(role: .destructive) { appState.stopRecording() } label: {
                Label(Strings.stop, systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .tint(Brand.recordingRed)
        } else {
            switch appState.phase {
            case .recording:
                Button(role: .destructive) { appState.stopRecording() } label: {
                    Label(Strings.stop, systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .tint(Brand.recordingRed)
            case .transcribing:
                Button {} label: {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(Strings.transcribing) }
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(true)
            default:
                Button { appState.startRecording() } label: {
                    Label(Strings.record, systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Brand.recordingRed)
            }
        }
    }

    private func errorRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 11))
            .foregroundStyle(Brand.recordingRed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Next meeting

    private func nextMeetingRow(_ meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(.secondary)
            Text(meeting.title).font(.system(size: 11)).lineLimit(1)
            Spacer()
            Text(countdown(for: meeting)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcript

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(appState.phase == .transcribing ? Strings.transcribing : Strings.transcript)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if !appState.lastSegments.isEmpty {
                    Button(Strings.copy) { copyTranscript() }.controlSize(.small)
                }
                if appState.lastAudioPath != nil, appState.phase != .transcribing {
                    Button(Strings.retranscribe) { Task { await appState.retranscribeLastAudio() } }
                        .controlSize(.small)
                }
            }
            if appState.phase == .transcribing {
                ProgressView(value: appState.transcriptionProgress).controlSize(.small)
            }
            if !transcriptDisplay.isEmpty {
                ScrollView {
                    Text(transcriptDisplay)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var transcriptDisplay: String {
        appState.lastSegments.map { seg in
            var line = "[\(formatTimestamp(seg.start))]"
            if let speaker = seg.speaker, !speaker.isEmpty { line += " [\(speaker)]:" }
            return line + " " + seg.text
        }.joined(separator: "\n")
    }

    private func copyTranscript() {
        let text: String
        if let path = appState.lastTranscriptPath,
           let content = try? String(contentsOfFile: path, encoding: .utf8), !content.isEmpty {
            text = content
        } else {
            text = transcriptDisplay
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(Strings.history).font(.system(size: 11, weight: .semibold))
                Spacer()
                Button { appState.importAudioPicker() } label: {
                    Label(Strings.importAudio, systemImage: "square.and.arrow.down").font(.system(size: 11))
                }
                .buttonStyle(.link)
                .disabled(appState.phase == .recording || appState.phase == .transcribing)
            }
            TextField(Strings.searchPlaceholder, text: $appState.historyQuery)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .accessibilityLabel(Strings.searchPlaceholder)
            if appState.history.isEmpty {
                Text(appState.historyQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? Strings.noMeetings : Strings.noSearchResults)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(appState.history) { historyRow($0) }
                    }
                }
                .frame(maxHeight: 130)
            }
        }
    }

    private func historyRow(_ record: MeetingSummary) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                Text(historySubtitle(record)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            let noteURL = URL(fileURLWithPath: AppPaths.current.meetingsDir)
                .appendingPathComponent(record.id + ".summary.md")
            if FileManager.default.fileExists(atPath: noteURL.path) {
                Button {
                    NSWorkspace.shared.open(noteURL)
                } label: {
                    Image(systemName: "note.text")
                }
                .buttonStyle(.plain)
                .help(Strings.openMeetingNote)
                .accessibilityLabel(Strings.openMeetingNote)
            }
            Button {
                appState.showTranscript(record)
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.plain)
            .help(Strings.showTranscript)
            .accessibilityLabel(Strings.showTranscript)
        }
        .padding(4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func historySubtitle(_ record: MeetingSummary) -> String {
        var parts = [record.startedAt.formatted(date: .abbreviated, time: .shortened), record.engine]
        if record.speakerCount > 0 { parts.append(Strings.speakers(record.speakerCount)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button { appState.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .disabled(!allowsSettings)
                .help(Strings.settings)
                .accessibilityLabel(Strings.settings)
            Button { appState.quit() } label: { Image(systemName: "power") }
                .buttonStyle(.plain)
                .keyboardShortcut("q")
                .help("\(Strings.quit) (⌘Q)")
                .accessibilityLabel(Strings.quit)
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Derived

    private var phaseColor: Color {
        if appState.isStartingRecording { return Brand.transcribingOrange }
        switch appState.phase {
        case .recording: return Brand.recordingRed
        case .transcribing: return Brand.transcribingOrange
        case .done: return Brand.successGreen
        case .approaching: return Brand.pastelViolet
        case .idle: return .secondary
        }
    }

    func menuBarIcon(for phase: AppPhase, isStartingRecording: Bool = false) -> String {
        isStartingRecording ? "hourglass" : MenuBarGlyph.icon(for: phase)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600, m = (Int(duration) % 3600) / 60, s = Int(duration) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func countdown(for meeting: Meeting) -> String {
        let interval = meeting.startDate.timeIntervalSince(now)
        if interval < 0 { return Strings.now }
        return Strings.inMinutes(Int(interval) / 60)
    }
}

extension AppState: PopoverStateModel {
    var nextMeeting: Meeting? { calendarService.nextMeeting }

    var canRequestAudioPermission: Bool { audioCapture.canRequestPermission() }
    var pendingRecordingCount: Int { recoverableRecordings.count }

    func requestAudioPermission() { requestMicAccess() }

    func openSystemAudioSettings() { audioCapture.openSystemAudioSettings() }

    func transcribePendingRecordings() { recoverRecordings(automaticOnly: false) }

    func startRecording() { startRecording(origin: .manual) }

    func importAudioPicker() {
        let panel = NSOpenPanel()
        panel.title = Strings.importTitle
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let extra = ["caf", "pcm"].compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = [.wav, .mpeg4Audio, .aiff] + extra
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in await importAudio(url: url) }
    }

    func showTranscript(_ record: MeetingSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.transcriptPath)])
    }

    func openSettings() { SettingsWindow.open(appState: self) }

    func quit() { NSApp.terminate(nil) }
}

enum MenuBarGlyph {
    static func icon(for phase: AppPhase) -> String {
        switch phase {
        case .idle: return "mic"
        case .approaching: return "mic.badge.plus"
        case .recording: return "mic.fill"
        case .transcribing: return "waveform"
        case .done: return "checkmark.circle.fill"  // mic.badge.checkmark is invisible on macOS 26
        }
    }
}

/// On-demand settings window; the menu-bar status item is the primary interface.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?

    static func open(appState: AppState) {
        NSApp.activate()
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "\(AppInfo.name) · \(Strings.settings)"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(appState: appState))
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

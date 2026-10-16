// PopoverSnapshot.swift
// Headless render and isolated interactive fixture for the popover. Both use
// the production PopoverContent view with synthetic state only.

import AppKit
import Combine
import Foundation
import SwiftUI

public enum PopoverSnapshot {
    /// Tall enough for the recording layout; the render is cropped to the
    /// fitting height afterwards.
    static let maxHeight: CGFloat = 700

    /// Handles the opt-in UI harness before the real menu-bar App is created.
    /// Both test modes require an isolated output directory as an explicit
    /// guard against accidentally running beside the user's meeting data.
    @MainActor
    public static func runIfRequested() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["MEETCAPTURE_UI_TEST"] == "1" {
            do {
                let outputDir = try isolatedOutputDirectory(environment)
                try runInteractive(outputDir: outputDir)
            } catch {
                FileHandle.standardError.write(Data("ui fixture failed: \(error)\n".utf8))
                exit(1)
            }
            return true
        }

        guard let path = environment["MEETCAPTURE_SNAPSHOT_PATH"], !path.isEmpty else {
            return false
        }
        do {
            _ = try isolatedOutputDirectory(environment)
            try render(to: path)
            print("SNAPSHOT_PATH=\(path)")
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
        return true
    }

    @MainActor
    static func render(to path: String) throws {
        let state = demoState(scenario: .recording)
        let defaults = isolatedSettingsStore()
        Settings.registerDefaults(defaults)
        let host = NSHostingView(rootView: PopoverContent(appState: state, settingsStore: defaults))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = NSSize(width: PopoverContent<UIFixtureState>.width, height: maxHeight)
        host.frame = NSRect(origin: .zero, size: size)
        // A real (offscreen) window so AppKit performs the SwiftUI layout pass.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let fitted = min(maxHeight, max(320, host.fittingSize.height.rounded(.up)))
        window.setContentSize(NSSize(width: size.width, height: fitted))
        host.frame = NSRect(x: 0, y: 0, width: size.width, height: fitted)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw SnapshotError.noImage }
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw SnapshotError.noImage }
        try png.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private static func runInteractive(outputDir: String) throws {
        let state = demoState(scenario: .interactive)
        let defaults = isolatedSettingsStore()
        Settings.registerDefaults(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "MeetCapture · UI fixture"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: PopoverContent(appState: state, settingsStore: defaults)
                .frame(minHeight: 320, alignment: .top))
        window.center()
        let delegate = UIFixtureApplicationDelegate(window: window, outputDir: outputDir)
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.delegate = delegate
        window.delegate = delegate
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        print("UI_FIXTURE_READY=1")
        application.run()
    }

    private static func isolatedOutputDirectory(_ environment: [String: String]) throws -> String {
        guard let raw = environment["MEETCAPTURE_TEST_OUTPUT_DIR"], !raw.isEmpty else {
            throw SnapshotError.missingIsolatedOutput
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: raw, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SnapshotError.outputIsNotDirectory(raw)
        }
        return raw
    }

    private static func isolatedSettingsStore() -> UserDefaults {
        UserDefaults(suiteName: "com.maatwork.meetcapture.ui-test.\(UUID().uuidString)")!
    }

    enum SnapshotError: Error {
        case noImage
        case missingIsolatedOutput
        case outputIsNotDirectory(String)
    }

    @MainActor
    private static func demoState(scenario: UIFixtureScenario) -> UIFixtureState {
        UIFixtureState(scenario: scenario)
    }
}

enum UIFixtureScenario {
    case recording
    case interactive
}

/// A UI-only model. It intentionally has no AppState, AppPaths, MeetingStore,
/// permissions, calendar, capture, ASR or summary configuration dependencies.
@MainActor
private final class UIFixtureState: ObservableObject, PopoverStateModel {
    @Published var phase: AppPhase = .idle
    @Published var currentMeeting: Meeting?
    @Published var nextMeeting: Meeting?
    @Published var errorMessage: String?
    @Published var hasAudioPermission = true
    @Published var recordingDuration: TimeInterval = 0
    @Published var transcriptionProgress: Double = 0
    @Published var lastTranscriptPath: String?
    @Published var lastSegments: [Segment] = []
    @Published var lastAudioPath: String?
    @Published var livePartialText = ""
    @Published var liveSegments: [LiveASRSegment] = []
    @Published var liveASRState: LiveASRState = .ready
    @Published var history: [MeetingSummary] = []
    @Published var historyQuery = "" {
        didSet {
            guard historyQuery != oldValue else { return }
            searchHistory(historyQuery)
        }
    }
    @Published var meetingNotes = ""
    @Published var isStartingRecording = false
    @Published var captureWarning: CaptureWarning?
    @Published var pendingRecordingCount = 0
    @Published var isRecovering = false
    var canRequestAudioPermission: Bool { true }

    private var allHistory: [MeetingSummary] = []

    init(scenario: UIFixtureScenario) {
        let base = Date(timeIntervalSince1970: 1_788_271_709)
        allHistory = [
            Self.summary(id: "fixture-sprint", title: "Sprint review", startedAt: base.addingTimeInterval(-86_400), speakers: 2),
            Self.summary(id: "fixture-onboarding", title: "Onboarding Sofía", startedAt: base.addingTimeInterval(-2 * 86_400), speakers: 3),
            Self.summary(id: "fixture-roadmap", title: "Roadmap Q4", startedAt: base.addingTimeInterval(-4 * 86_400), speakers: 2),
        ]
        history = allHistory
        lastSegments = [
            Segment(start: 0, end: 7, text: "La captura de prueba está aislada y no toca reuniones reales.", speaker: "A"),
            Segment(start: 8, end: 15, text: "Podemos buscar el historial y probar los estados desde esta ventana.", speaker: "B"),
        ]

        switch scenario {
        case .recording:
            phase = .recording
            recordingDuration = 12 * 60 + 34
            liveSegments = [
                LiveASRSegment(start: 11 * 60 + 48, end: 11 * 60 + 55,
                               text: "El objetivo es cerrar los pendientes del sprint."),
                LiveASRSegment(start: 11 * 60 + 57, end: 12 * 60 + 4,
                               text: "La estabilidad del proceso de captura es crítica."),
            ]
            livePartialText = "Si me dan el acceso al repositorio, pruebo la diarización"
        case .interactive:
            phase = .idle
            currentMeeting = nil
            nextMeeting = Meeting(
                id: "fixture-next", title: "Synthetic customer call",
                startDate: Date().addingTimeInterval(180), endDate: Date().addingTimeInterval(2_000),
                meetURL: URL(string: "https://meet.google.com/aaa-bbbb-ccc")!,
                externalAttendees: ["fixture@example.test"])
            errorMessage = "Fixture: error sintético visible; no se inició ningún servicio."
        }
    }

    func requestAudioPermission() {
        hasAudioPermission = true
        errorMessage = "Fixture: permiso sintético concedido."
    }

    func openSystemAudioSettings() {
        errorMessage = "Fixture: no se abren Ajustes reales."
    }

    func transcribePendingRecordings() {
        pendingRecordingCount = 0
        errorMessage = "Fixture: recuperación simulada sin audio real."
    }

    func startRecording() {
        guard phase != .transcribing else { return }
        phase = .recording
        recordingDuration = 3
        currentMeeting = nil
        liveSegments = []
        livePartialText = "Grabación sintética en curso"
        errorMessage = nil
    }

    func stopRecording() {
        guard phase == .recording else { return }
        phase = .done
        recordingDuration = 4
        transcriptionProgress = 1
        livePartialText = ""
        lastAudioPath = nil
        errorMessage = "Fixture: transcripción sintética lista; no se escribió ningún archivo."
    }

    func importAudioPicker() {
        errorMessage = "Fixture: importación deshabilitada; elegí una fila del historial para probar interacción."
    }

    func retranscribeLastAudio() async {
        errorMessage = "Fixture: re-transcripción simulada sin audio real."
    }

    func searchHistory(_ query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            history = allHistory
            return
        }
        history = allHistory.filter {
            [$0.title, $0.engine, $0.model, $0.language]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(needle)
        }
    }

    func showTranscript(_ record: MeetingSummary) {
        errorMessage = "Fixture: seleccionaste el transcript de «\(record.title)»."
    }

    func openSettings() {
        errorMessage = "Fixture: Settings no se abre en modo aislado."
    }

    func quit() { NSApp.terminate(nil) }

    private static func summary(id: String, title: String, startedAt: Date, speakers: Int) -> MeetingSummary {
        MeetingSummary(
            id: id, title: title, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(1_800),
            durationSec: 1_800, engine: "whisper", model: "medium-q5_0", language: "es",
            transcriptPath: "/fixture/\(id).txt", summaryPath: nil, speakerCount: speakers)
    }
}

@MainActor
private final class UIFixtureApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let window: NSWindow
    private let outputDir: String

    init(window: NSWindow, outputDir: String) {
        self.window = window
        self.outputDir = outputDir
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = (window, outputDir)
    }
}

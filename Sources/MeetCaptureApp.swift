// MeetCaptureApp.swift
// MeetCapture v4 — macOS menu bar app for Google Meet transcription
// @main entry point with SwiftUI MenuBarExtra

import SwiftUI

@main
struct MeetCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The AppState is owned by the AppDelegate (created as early as possible
    // so it's available via AppState.shared before any Scene body runs).
    // We hold it as @ObservedObject so SwiftUI subscribes to its @Published
    // changes and re-renders the menu bar icon / popover as state evolves.
    @ObservedObject var appState: AppState

    init() {
        // AppDelegate is created synchronously by NSApplicationDelegateAdaptor
        // *before* MeetCaptureApp.init runs, so its appState is already
        // initialized and AppState.shared is set.
        self._appState = ObservedObject(wrappedValue: AppDelegate.sharedAppState)
    }

    var body: some Scene {
        // Phase 4: custom branded popover instead of plain menu
        MenuBarExtra {
            PopoverContent(appState: appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(appState.phase == .recording ? Brand.recordingRed : Brand.pastelViolet)
        }
        .menuBarExtraStyle(.window)

        // Settings window (accessed via menu)
        Settings {
            SettingsView(appState: appState)
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    // CRITICAL: own the AppState and create it as early as possible so the
    // @main App can grab it from `init()` (NSApplicationDelegateAdaptor
    // instantiates AppDelegate synchronously before MeetCaptureApp.init runs).
    static let sharedAppState = AppState()
    private let appState = AppDelegate.sharedAppState

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only app
        NSApp.setActivationPolicy(.accessory)

        // Initialize services (permissions, calendar, call detection)
        Task { @MainActor in
            await self.appState.startup()
        }
    }
}

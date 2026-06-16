// MeetCaptureApp.swift
// MeetCapture v4 — macOS menu bar app for Google Meet transcription
// @main entry point with SwiftUI MenuBarExtra

import SwiftUI
import ServiceManagement

@main
struct MeetCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // The AppState is owned by the AppDelegate (created as early as possible
    // so it's available via AppState.shared before any Scene body runs).
    // We hold it as @ObservedObject so SwiftUI subscribes to its @Published
    // changes and re-renders the menu bar icon / popover as state evolves.
    //
    // (BUG #12 fix: @StateObject was created lazily AFTER
    //  applicationDidFinishLaunching tried to call AppState.shared?.startup(),
    //  which was nil. The startup() task never ran, the SocketClient never
    //  connected, the app showed up in the menu bar but was inert.)
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
    // AppState is @MainActor-isolated (hence Sendable) and its init() is a
    // non-isolated synchronous setup; the actual startup() call happens on the
    // main actor in applicationDidFinishLaunching.
    static let sharedAppState = AppState()
    private let appState = AppDelegate.sharedAppState

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only app
        NSApp.setActivationPolicy(.accessory)

        // Initialize services (permissions, daemon, calendar, socket)
        // AppState.shared is set (init() ran when sharedAppState was created)
        Task { @MainActor in
            await self.appState.startup()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when settings window closes — stay in menu bar
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clean shutdown
        self.appState.shutdown()
        return .terminateNow
    }
}

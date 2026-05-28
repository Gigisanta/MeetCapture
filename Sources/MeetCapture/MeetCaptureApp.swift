// MeetCaptureApp.swift
// MeetCapture v4 — macOS menu bar app for Google Meet transcription
// @main entry point with SwiftUI MenuBarExtra

import SwiftUI
import ServiceManagement

@main
struct MeetCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        // Menu bar extra — primary UI surface
        MenuBarExtra {
            StatusView(appState: appState)
        } label: {
            Label(appState.menuBarTitle, systemImage: appState.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
        
        // Settings window (accessed via menu)
        Settings {
            SettingsView(appState: appState)
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon — menu bar only app
        NSApp.setActivationPolicy(.accessory)
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when settings window closes — stay in menu bar
        return false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Clean shutdown
        AppState.shared?.shutdown()
        return .terminateNow
    }
}

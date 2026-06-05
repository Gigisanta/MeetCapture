// StatusView.swift
// MeetCapture v4 — DEPRECATED, replaced by PopoverContent.swift (Phase 4).
// Kept as a stub to satisfy any leftover references; all UI lives in PopoverContent.

import SwiftUI

struct StatusView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        PopoverContent(appState: appState)
    }
}

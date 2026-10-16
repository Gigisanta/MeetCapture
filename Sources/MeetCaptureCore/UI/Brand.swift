// Brand.swift
// MeetCapture v4 — minimal color tokens.
// The UI uses native system materials/typography; these are just the few
// accent/status colors layered on top.

import SwiftUI

enum Brand {
    /// MaatWork primary accent (pastel violet, hue 261°).
    static let pastelViolet = Color(hue: 0.725, saturation: 0.45, brightness: 0.95)

    /// Phase/status colors.
    static let recordingRed = Color(red: 0.95, green: 0.30, blue: 0.35)
    static let transcribingOrange = Color(red: 0.98, green: 0.65, blue: 0.20)
    static let successGreen = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warnAmber = Color(red: 0.98, green: 0.75, blue: 0.20)
}

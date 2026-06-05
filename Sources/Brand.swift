// Brand.swift
// MeetCapture v4 — Visual identity tokens
// Premium dark glassmorphism, MaatWork pastel violet palette.

import SwiftUI

enum Brand {
    /// Pastel violet — hue 261°, MaatWork primary brand color.
    static let pastelViolet = Color(hue: 0.725, saturation: 0.45, brightness: 0.95)
    static let pastelVioletDeep = Color(hue: 0.725, saturation: 0.65, brightness: 0.70)
    static let pastelVioletSoft = Color(hue: 0.725, saturation: 0.30, brightness: 1.0)

    /// Reinnova accent (warm gold)
    static let reinnovaGold = Color(hue: 0.13, saturation: 0.55, brightness: 0.95)

    /// Status colors
    static let recordingRed = Color(red: 0.95, green: 0.30, blue: 0.35)
    static let transcribingOrange = Color(red: 0.98, green: 0.65, blue: 0.20)
    static let successGreen = Color(red: 0.30, green: 0.85, blue: 0.55)
    static let warnAmber = Color(red: 0.98, green: 0.75, blue: 0.20)

    /// Background gradient
    static let heroGradient = LinearGradient(
        colors: [
            Color(hue: 0.725, saturation: 0.55, brightness: 0.20),
            Color(hue: 0.70, saturation: 0.45, brightness: 0.08)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Card backgrounds (glassmorphism with backdrop blur)
    static func glassCard<S: Shape>(_ shape: S) -> some View {
        ZStack {
            // Frosted backdrop layer (real glassmorphism)
            shape.fill(.ultraThinMaterial)
            // Tinted gradient overlay for premium dark feel
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            // Soft inner highlight
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.30), Color.white.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }

    /// Typography scale
    static let heroTitle = Font.system(size: 22, weight: .bold, design: .rounded)
    static let cardTitle = Font.system(size: 14, weight: .semibold, design: .rounded)
    static let cardSubtitle = Font.system(size: 12, weight: .regular, design: .rounded)
    static let monoCountdown = Font.system(size: 28, weight: .bold, design: .monospaced)
    static let label = Font.system(size: 11, weight: .medium, design: .rounded)
    static let caption = Font.system(size: 10, weight: .regular, design: .rounded)
}

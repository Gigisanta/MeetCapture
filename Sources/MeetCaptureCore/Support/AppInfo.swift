// AppInfo.swift
// Single source of truth for identity strings. The version comes from the
// bundle's Info.plist (Resources/Info.plist at build time), never a literal.

import Foundation
import os

enum AppInfo {
    static let bundleID = "com.maatwork.meetcapture"
    static let name = "MeetCapture"
    static let repositoryURL = URL(string: "https://github.com/Gigisanta/MeetCapture")!
    static let websiteURL = URL(string: "https://meetcapture.maat.work")!

    /// CFBundleShortVersionString when running from a bundle; "dev" from
    /// `swift run` or the bare binary.
    static let version: String = {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
    }()

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: bundleID, category: category)
    }
}

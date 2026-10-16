// Signposts.swift
// Replaces the old `print("TIMING …")` lines: intervals show up in
// Instruments (os_signpost) and cost nothing when nobody is listening.

import os

enum Signposts {
    static let capture = OSSignposter(subsystem: AppInfo.bundleID, category: "Capture")
    static let asr = OSSignposter(subsystem: AppInfo.bundleID, category: "ASR")
    static let pipeline = OSSignposter(subsystem: AppInfo.bundleID, category: "Pipeline")
}

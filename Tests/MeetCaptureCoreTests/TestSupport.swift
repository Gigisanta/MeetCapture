// TestSupport.swift
// Small helpers shared by the suite: a per-test temp dir and fixed dates.

import Foundation
import XCTest

enum TestSupport {
    /// Fresh temp directory (0700) removed by the caller's `addTeardownBlock`.
    static func makeTempDir(_ test: XCTestCase, _ name: String = "mc") -> String {
        let dir = NSTemporaryDirectory() + "meetcapture-tests-\(name)-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        test.addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// 2026-09-01T14:08:29Z
    static let fixedDate = Date(timeIntervalSince1970: 1_788_271_709)

    static func write(_ text: String, to path: String) {
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Creates an executable shell script at `path` with the given body.
    static func writeExecutable(_ body: String, to path: String) {
        write("#!/bin/sh\n" + body + "\n", to: path)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}

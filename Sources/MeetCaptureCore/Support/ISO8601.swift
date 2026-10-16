// ISO8601.swift
// Shared ISO 8601 formatter (thread-safe per Apple docs). Same output as the
// per-call `ISO8601DateFormatter()` instances used before: "2026-09-01T14:08:29Z".

import Foundation

enum ISO8601 {
    nonisolated(unsafe) private static let formatter = ISO8601DateFormatter()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func date(from string: String) -> Date? { formatter.date(from: string) }
}

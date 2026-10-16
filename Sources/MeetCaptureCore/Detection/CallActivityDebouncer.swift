// CallActivityDebouncer.swift
// A call is "over" only after `confirmCount` consecutive inactive
// observations, so a brief mic release (device switch) does not end it.

import Foundation

struct CallActivityDebouncer: Equatable, Sendable {
    let confirmCount: Int
    private(set) var isActive = false
    private(set) var inactiveStreak = 0

    init(confirmCount: Int = 2) {
        self.confirmCount = max(1, confirmCount)
    }

    /// Feeds one observation; returns the new state when it changed.
    mutating func observe(active: Bool) -> Bool? {
        if active {
            inactiveStreak = 0
            if !isActive { isActive = true; return true }
            return nil
        }
        inactiveStreak += 1
        if isActive && inactiveStreak >= confirmCount {
            isActive = false
            return false
        }
        return nil
    }

    /// An inactive observation was seen but not yet confirmed.
    var needsConfirmation: Bool { isActive && inactiveStreak > 0 }
}

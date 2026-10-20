// AudioRingBuffer.swift
// Fixed pool of preallocated slots between the Core Audio IOProc (real-time
// thread, must never allocate or block) and the consumer thread. Each slot
// holds one callback's worth of mono system + mono mic audio.

import Foundation
import os

final class AudioRingBuffer: @unchecked Sendable {
    /// Max frames a tap callback delivers (~170 ms at 48 kHz).
    static let maxFrames = 8192

    final class Slot {
        let system: UnsafeMutablePointer<Float>
        let mic: UnsafeMutablePointer<Float>
        var frames = 0

        init(capacity: Int) {
            system = .allocate(capacity: capacity)
            mic = .allocate(capacity: capacity)
            system.initialize(repeating: 0, count: capacity)
            mic.initialize(repeating: 0, count: capacity)
        }

        deinit {
            system.deallocate()
            mic.deallocate()
        }
    }

    let capacity: Int
    private let slots: [Slot]
    private struct Cursor { var head = 0; var tail = 0; var count = 0; var dropped = 0; var accepted = 0 }
    private let cursor = OSAllocatedUnfairLock(initialState: Cursor())
    /// Signalled once per committed slot; the consumer waits on it.
    let available = DispatchSemaphore(value: 0)

    init(capacity: Int = 64, frameCapacity: Int = AudioRingBuffer.maxFrames) {
        self.capacity = capacity
        slots = (0..<capacity).map { _ in Slot(capacity: frameCapacity) }
    }

    var droppedCallbacks: Int { cursor.withLock { $0.dropped } }
    var acceptedCallbacks: Int { cursor.withLock { $0.accepted } }
    var count: Int { cursor.withLock { $0.count } }

    /// Producer side (real-time thread). `fill` runs outside the lock on a
    /// slot nobody else touches. Returns false (and counts a drop) when full.
    @discardableResult
    func write(_ fill: (Slot) -> Void) -> Bool {
        let index: Int? = cursor.withLock { c in
            guard c.count < capacity else { c.dropped += 1; return nil }
            return c.head
        }
        guard let index else { return false }
        fill(slots[index])
        cursor.withLock { c in
            c.head = (c.head + 1) % capacity
            c.count += 1
            c.accepted += 1
        }
        available.signal()
        return true
    }

    /// Consumer side. Returns false when empty.
    @discardableResult
    func read(_ consume: (Slot) -> Void) -> Bool {
        let index: Int? = cursor.withLock { c in c.count > 0 ? c.tail : nil }
        guard let index else { return false }
        consume(slots[index])
        cursor.withLock { c in
            c.tail = (c.tail + 1) % capacity
            c.count -= 1
        }
        return true
    }
}

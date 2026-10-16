// LiveASRWarmPolicy.swift
// When the streaming recognizer (a python process holding a model in RAM)
// should be alive. Pure so it is testable.

import Foundation

struct LiveASRWarmPolicy: Equatable, Sendable {
    /// 0 = never unload.
    var idleUnloadMinutes: Int
    /// Keep the recognizer warm this long before a calendar meeting.
    var preMeetingWindow: TimeInterval = 300

    var idleUnloadInterval: TimeInterval? {
        idleUnloadMinutes > 0 ? TimeInterval(idleUnloadMinutes) * 60 : nil
    }

    /// Something that needs the recognizer soon: a call in progress or a
    /// meeting starting within the window.
    func demand(callActive: Bool, nextMeetingStart: Date?, now: Date) -> Bool {
        if callActive { return true }
        if let start = nextMeetingStart, start.timeIntervalSince(now) <= preMeetingWindow { return true }
        return false
    }

    func shouldUnload(idleSince: Date, now: Date, callActive: Bool, nextMeetingStart: Date?) -> Bool {
        guard let interval = idleUnloadInterval else { return false }
        if demand(callActive: callActive, nextMeetingStart: nextMeetingStart, now: now) { return false }
        return now.timeIntervalSince(idleSince) >= interval
    }

    func shouldWarm(callActive: Bool, nextMeetingStart: Date?, now: Date) -> Bool {
        demand(callActive: callActive, nextMeetingStart: nextMeetingStart, now: now)
    }
}

// MeetingDetectionPolicy.swift
// Pure rules for auto-record: when a call or calendar meeting starts or
// stops a recording. AppState applies the decisions.

import Foundation

enum RecordingOrigin: String, Equatable, Sendable {
    case manual    // user clicked Record: never auto-stopped
    case liveCall  // mic in use by a call app: stops when the call ends
    case calendar  // calendar meeting: stops or hands off at endDate + grace
}

enum AppPhase: String, CaseIterable, Sendable {
    case idle
    case approaching
    case recording
    case transcribing
    case done
}

enum MeetingDetectionPolicy {
    static let approachWindow: TimeInterval = 300
    static let startGrace: TimeInterval = 60
    static let calendarEndGrace: TimeInterval = 120

    enum Action: Equatable {
        case start(RecordingOrigin)
        case stop
    }

    /// A meeting starting within 5 min (or started less than a minute ago).
    static func approachingMeeting(in meetings: [Meeting], now: Date) -> Meeting? {
        meetings.first { m in
            let t = m.timeUntilStart(now: now)
            return t <= approachWindow && t > -startGrace
        }
    }

    static func action(callActive: Bool, phase: AppPhase, origin: RecordingOrigin?, autoRecord: Bool) -> Action? {
        guard autoRecord else { return nil }
        if callActive {
            switch phase {
            case .idle: return .start(.liveCall)
            case .approaching: return .start(.calendar)
            default: return nil
            }
        }
        return phase == .recording && origin == .liveCall ? .stop : nil
    }

    /// When the scheduled start fires: record only if a call is really active.
    static func startAtScheduledTime(phase: AppPhase, callActive: Bool, autoRecord: Bool) -> Action? {
        guard phase == .approaching, autoRecord, callActive else { return nil }
        return .start(.calendar)
    }

    enum CalendarEnd: Equatable {
        case stop
        case handOffToLiveCall
    }

    static func calendarEndAction(meeting: Meeting, now: Date, callActive: Bool) -> CalendarEnd? {
        guard now >= meeting.endDate.addingTimeInterval(calendarEndGrace) else { return nil }
        return callActive ? .handOffToLiveCall : .stop
    }

    static func shouldStopForMaxDuration(elapsed: TimeInterval, maximum: TimeInterval) -> Bool {
        elapsed >= maximum
    }
}

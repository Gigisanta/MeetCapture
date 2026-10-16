// MeetingFilter.swift
// Which calendar events count as meetings to record: a Google Meet link
// and at least one attendee who is neither the user nor on the internal
// whitelist (config.json). Pure over a snapshot so it is testable.

import Foundation

struct Meeting: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let meetURL: URL
    let externalAttendees: [String]

    func timeUntilStart(now: Date = Date()) -> TimeInterval { startDate.timeIntervalSince(now) }
    func isActive(now: Date = Date()) -> Bool { startDate <= now && endDate > now }
}

struct CalendarEventSnapshot: Equatable, Sendable {
    struct Attendee: Equatable, Sendable {
        var email: String
        var isCurrentUser: Bool
    }
    var id: String
    var title: String?
    var start: Date
    var end: Date
    var url: URL?
    var notes: String?
    var attendees: [Attendee]
}

enum MeetingFilter {
    static let meetURLPattern = #"https?://meet\.google\.com/[a-z0-9]+-[a-z0-9]+-[a-z0-9]+"#

    static func meeting(from event: CalendarEventSnapshot, whitelist: Set<String>) -> Meeting? {
        guard let url = meetURL(in: event) else { return nil }
        let external = event.attendees.compactMap { attendee -> String? in
            let email = attendee.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !email.isEmpty, !attendee.isCurrentUser, !whitelist.contains(email) else { return nil }
            return email
        }
        guard !external.isEmpty else { return nil }
        return Meeting(id: event.id, title: event.title ?? MeetingSession.untitled,
                       startDate: event.start, endDate: event.end, meetURL: url, externalAttendees: external)
    }

    static func meetURL(in event: CalendarEventSnapshot) -> URL? {
        if let url = event.url,
           let host = url.host?.lowercased(),
           host == "meet.google.com" {
            return url
        }
        guard let notes = event.notes,
              let range = notes.range(of: meetURLPattern, options: .regularExpression) else { return nil }
        return URL(string: String(notes[range]))
    }

    /// Meetings sorted by start, dropping the ones that already ended.
    static func upcoming(_ meetings: [Meeting], now: Date) -> [Meeting] {
        meetings.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
    }
}

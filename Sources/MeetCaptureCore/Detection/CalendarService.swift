// CalendarService.swift
// EventKit source of upcoming meetings. Refreshes on EKEventStoreChanged
// (no polling) and wakes AppState at the moments that matter: five
// minutes before the next meeting and at its start.

import Combine
import EventKit
import Foundation
import os

@MainActor
final class CalendarService: ObservableObject {
    @Published private(set) var upcomingMeetings: [Meeting] = []
    @Published private(set) var isAuthorized = false
    @Published var lastError: String?
    private(set) var eventSnapshots: [CalendarEventSnapshot] = []

    static let approachWindow: TimeInterval = 300

    private let eventStore = EKEventStore()
    private var cancellables = Set<AnyCancellable>()
    private var scheduled: [DispatchWorkItem] = []
    private let logger = AppInfo.logger("Calendar")
    var whitelist: Set<String>

    init(whitelist: Set<String> = Set(LocalConfig.load().whitelistedEmails)) {
        self.whitelist = whitelist
        NotificationCenter.default
            .publisher(for: .EKEventStoreChanged, object: eventStore)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshMeetings() }
            }
            .store(in: &cancellables)
    }

    var nextMeeting: Meeting? { upcomingMeetings.first }

    func requestAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            isAuthorized = granted
            if granted {
                refreshMeetings()
            } else {
                lastError = "Acceso al calendario denegado."
            }
        } catch {
            isAuthorized = false
            lastError = "No se pudo pedir acceso al calendario: \(error.localizedDescription)"
        }
    }

    /// Today + tomorrow, filtered by MeetingFilter.
    func refreshMeetings(now: Date = Date()) {
        guard isAuthorized else { return }
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        eventSnapshots = eventStore.events(matching: predicate).map { Self.snapshot($0) }
        let meetings = eventSnapshots.compactMap { MeetingFilter.meeting(from: $0, whitelist: whitelist) }
        upcomingMeetings = MeetingFilter.upcoming(meetings, now: now)
        scheduleNextEvaluation(now: now)
    }

    /// Query the recording instant, not a cached upcoming title. Imports and
    /// recovery use their persisted context (or unmatched), never this method.
    func captureContext(at date: Date, activeBundleIDs: [String],
                        timeZone: String = TimeZone.current.identifier) -> MeetingContext {
        guard isAuthorized else {
            return MeetingContext.capture(events: [], at: date, activeBundleIDs: activeBundleIDs, timeZone: timeZone)
        }
        let predicate = eventStore.predicateForEvents(withStart: date, end: date.addingTimeInterval(1), calendars: nil)
        let snapshots = eventStore.events(matching: predicate).map { Self.snapshot($0) }
        return MeetingContext.capture(events: snapshots, at: date, activeBundleIDs: activeBundleIDs, timeZone: timeZone)
    }

    /// Re-publishes `upcomingMeetings` (which wakes AppState's sink) at
    /// max(now, start - 5 min) and at start of the next meeting.
    private func scheduleNextEvaluation(now: Date) {
        scheduled.forEach { $0.cancel() }
        scheduled = []
        guard let next = upcomingMeetings.first(where: { $0.startDate > now }) ?? upcomingMeetings.first else { return }
        let moments = [next.startDate.addingTimeInterval(-Self.approachWindow), next.startDate, next.endDate]
        for moment in moments where moment > now {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.upcomingMeetings = MeetingFilter.upcoming(self.upcomingMeetings, now: Date())
                self.scheduleNextEvaluation(now: Date())
            }
            scheduled.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + moment.timeIntervalSince(now) + 0.5, execute: work)
        }
    }

    static func snapshot(_ event: EKEvent) -> CalendarEventSnapshot {
        let identifier: String? = event.eventIdentifier
        return CalendarEventSnapshot(id: identifier.flatMap { $0.isEmpty ? nil : $0 }, title: event.title,
                                     start: event.startDate, end: event.endDate, url: event.url,
                                     notes: event.notes, attendees: (event.attendees ?? []).map { attendee($0) },
                                     organizer: event.organizer.map { attendee($0) }, isAllDay: event.isAllDay)
    }

    private static func attendee(_ participant: EKParticipant) -> CalendarEventSnapshot.Attendee {
        // A participant URL need not be mailto. Preserve the participant even
        // when its real name or email is unavailable, instead of inventing one.
        var email: String?
        if participant.url.scheme?.lowercased() == "mailto",
           let address = URLComponents(url: participant.url, resolvingAgainstBaseURL: false)?.path,
           !address.isEmpty, address.contains("@"), !address.contains(where: { $0.isWhitespace }) {
            email = address
        }
        let name = participant.name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return .init(name: name, email: email, isCurrentUser: participant.isCurrentUser)
    }
}

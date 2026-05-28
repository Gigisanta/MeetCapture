//
//  CalendarService.swift
//  MeetCapture
//
//  Created for MeetCapture v4 - macOS Menu Bar App
//  Detects Google Meet meetings with external attendees via EventKit.
//

import Foundation
import EventKit
import Combine

// MARK: - Meeting Model

/// Represents a detected Google Meet meeting with external attendees.
struct Meeting: Identifiable, Equatable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let meetURL: URL
    let externalAttendees: [String]

    /// Time interval (in seconds) until the meeting starts.
    /// Positive = future, negative = already started or passed.
    var timeUntilStart: TimeInterval {
        startDate.timeIntervalSinceNow
    }

    /// Human-readable string for time until meeting.
    var timeUntilStartFormatted: String {
        let interval = timeUntilStart
        if interval < 0 {
            return "In progress or ended"
        }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    /// True if the meeting is currently active (started but not yet ended).
    var isActive: Bool {
        let now = Date()
        return startDate <= now && endDate > now
    }
}

// MARK: - CalendarService

/// Service that monitors the system calendar for Google Meet meetings
/// involving external (non-whitelisted) attendees.
///
/// Uses EKEventStore notifications for real-time updates — no polling.
@MainActor
final class CalendarService: ObservableObject {

    // MARK: - Published Properties

    /// Upcoming meetings (starting from now) that have a Google Meet link
    /// and at least one external attendee. Sorted by start date ascending.
    @Published private(set) var upcomingMeetings: [Meeting] = []

    /// Whether calendar access has been granted.
    @Published private(set) var isAuthorized: Bool = false

    /// The most recent error encountered, if any.
    @Published var lastError: String?

    // MARK: - Private Properties

    private let eventStore = EKEventStore()
    private var cancellables = Set<AnyCancellable>()

    /// Whitelisted (internal) email addresses — these are excluded from
    /// the "external attendees" filter.
    static let whitelistedEmails: Set<String> = {
        let emails = [
            "giolivosantarelli@gmail.com",
            "giogametodraggg@gmail.com"
        ]
        return Set(emails.map { $0.lowercased() })
    }()

    /// Regex pattern to match Google Meet URLs in event notes.
    private let meetURLPattern = #"https?://meet\.google\.com/[a-z0-9]+-[a-z0-9]+-[a-z0-9]+"#

    // MARK: - Initialization

    init() {
        setupNotificationListener()
    }

    // MARK: - Authorization

    /// Requests full read-only access to the user's calendar data.
    /// On macOS 14+, this triggers the system permission dialog.
    func requestAccess() async {
        do {
            let granted = try await eventStore.requestFullAccessToEvents()
            await MainActor.run {
                self.isAuthorized = granted
                if granted {
                    self.refreshMeetings()
                } else {
                    self.lastError = "Calendar access denied by user."
                }
            }
        } catch {
            await MainActor.run {
                self.isAuthorized = false
                self.lastError = "Failed to request calendar access: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Notification Listener (No Polling)

    /// Observes `EKEventStoreChanged` to refresh meeting data whenever
    /// the calendar database changes. This replaces polling entirely.
    private func setupNotificationListener() {
        NotificationCenter.default
            .publisher(for: .EKEventStoreChanged, object: eventStore)
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.refreshMeetings()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Meeting Detection

    /// Scans the calendar for today's and tomorrow's events,
    /// filters for Google Meet links with external attendees.
    func refreshMeetings() {
        guard isAuthorized else { return }

        let calendar = Calendar.current
        let now = Date()

        // Search window: from now through the end of tomorrow.
        let startDate = now
        guard let endDate = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else {
            lastError = "Could not compute search window."
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        let rawEvents = eventStore.events(matching: predicate)

        let detected = rawEvents.compactMap { event -> Meeting? in
            self.processEvent(event)
        }

        upcomingMeetings = detected.sorted { $0.startDate < $1.startDate }
    }

    /// Extracts a `Meeting` from an `EKEvent` if it qualifies:
    /// 1. Has a meet.google.com URL in its notes or URL field.
    /// 2. Has at least one attendee whose email is NOT whitelisted.
    private func processEvent(_ event: EKEvent) -> Meeting? {
        // --- 1. Extract Google Meet URL ---
        guard let meetURL = extractMeetURL(from: event) else {
            return nil
        }

        // --- 2. Identify external (non-whitelisted) attendees ---
        let external = externalAttendees(for: event)
        guard !external.isEmpty else {
            return nil
        }

        return Meeting(
            id: event.eventIdentifier,
            title: event.title ?? "Untitled Meeting",
            startDate: event.startDate,
            endDate: event.endDate,
            meetURL: meetURL,
            externalAttendees: external
        )
    }

    /// Looks for a `meet.google.com` link in the event's notes or URL property.
    private func extractMeetURL(from event: EKEvent) -> URL? {
        // Check the dedicated URL field first.
        if let url = event.url,
           url.host?.contains("meet.google.com") == true {
            return url
        }

        // Fall back to scanning the notes body.
        guard let notes = event.notes else { return nil }

        if let range = notes.range(of: meetURLPattern, options: .regularExpression) {
            let urlString = String(notes[range])
            return URL(string: urlString)
        }

        return nil
    }

    /// Returns emails of attendees that are NOT in the whitelist.
    private func externalAttendees(for event: EKEvent) -> [String] {
        guard let attendees = event.attendees, !attendees.isEmpty else {
            return []
        }

        return attendees.compactMap { attendee -> String? in
            guard let email = attendee.emailAddress?.lowercased(),
                  !email.isEmpty else {
                return nil
            }
            // Skip whitelisted (internal) emails.
            if whitelistedEmails.contains(email) {
                return nil
            }
            return email
        }
    }

    // MARK: - Convenience

    /// The next upcoming meeting, or nil if none detected.
    var nextMeeting: Meeting? {
        upcomingMeetings.first
    }

    /// Refreshes time-until-start values. Call periodically from the UI
    /// (e.g., a 1-minute Timer) to keep displayed times current.
    func tick() {
        // Trigger a re-evaluation so @Published picks up changed timeUntilStart values.
        upcomingMeetings = upcomingMeetings
    }
}

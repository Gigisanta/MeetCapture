import XCTest
@testable import MeetCaptureCore

final class MeetingFilterTests: XCTestCase {
    let now = TestSupport.fixedDate
    func event(url: URL? = nil, notes: String? = nil, attendees: [CalendarEventSnapshot.Attendee]) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: "e1", title: "Sync", start: now.addingTimeInterval(600), end: now.addingTimeInterval(2_400),
                              url: url, notes: notes, attendees: attendees)
    }

    func testRequiresMeetLinkFromURLOrNotes() {
        let external = [CalendarEventSnapshot.Attendee(email: "Ana@Cliente.com", isCurrentUser: false)]
        XCTAssertNil(MeetingFilter.meeting(from: event(attendees: external), whitelist: []))
        let byURL = MeetingFilter.meeting(from: event(url: URL(string: "https://meet.google.com/abc-defg-hij"), attendees: external), whitelist: [])
        XCTAssertEqual(byURL?.externalAttendees, ["ana@cliente.com"])
        let byNotes = MeetingFilter.meeting(from: event(notes: "Join: https://meet.google.com/xyz-abcd-efg?authuser=0", attendees: external), whitelist: [])
        XCTAssertEqual(byNotes?.meetURL.absoluteString, "https://meet.google.com/xyz-abcd-efg")
        XCTAssertNil(MeetingFilter.meeting(from: event(url: URL(string: "https://zoom.us/j/1"), attendees: external), whitelist: []))
    }

    func testCurrentUserAndWhitelistAreNotExternal() {
        let attendees = [
            CalendarEventSnapshot.Attendee(email: "me@example.com", isCurrentUser: true),
            CalendarEventSnapshot.Attendee(email: "Colleague@Example.com", isCurrentUser: false),
            CalendarEventSnapshot.Attendee(email: "  ", isCurrentUser: false),
        ]
        let e = event(url: URL(string: "https://meet.google.com/abc-defg-hij"), attendees: attendees)
        XCTAssertNil(MeetingFilter.meeting(from: e, whitelist: ["colleague@example.com"]), "internal-only events are not meetings")
        XCTAssertEqual(MeetingFilter.meeting(from: e, whitelist: [])?.externalAttendees, ["colleague@example.com"])
    }

    func testMissingCalendarIDAndUnknownAttendeeDoNotDisableAutomaticPolicy() throws {
        var snapshot = event(url: URL(string: "https://meet.google.com/abc-defg-hij"), attendees: [
            .init(name: "Unknown account", email: nil, isCurrentUser: false),
            .init(email: "Guest@Client.test", isCurrentUser: false),
        ])
        snapshot.id = nil
        snapshot.start = now.addingTimeInterval(60)
        let meeting = try XCTUnwrap(MeetingFilter.meeting(from: snapshot, whitelist: []))
        XCTAssertNil(meeting.id, "an absent calendar ID is never replaced by a fabricated identifier")
        XCTAssertEqual(meeting.externalAttendees, ["guest@client.test"])
        XCTAssertNotNil(MeetingDetectionPolicy.approachingMeeting(in: [meeting], now: now))
    }

    func testUpcomingDropsEndedAndSortsByStart() {
        func m(_ id: String, _ start: TimeInterval, _ end: TimeInterval) -> Meeting {
            Meeting(id: id, title: id, startDate: now.addingTimeInterval(start), endDate: now.addingTimeInterval(end),
                    meetURL: URL(string: "https://meet.google.com/abc-defg-hij")!, externalAttendees: ["a@b.c"])
        }
        let list = MeetingFilter.upcoming([m("late", 600, 1200), m("ended", -1200, -1), m("active", -300, 300)], now: now)
        XCTAssertEqual(list.map(\.id), ["active", "late"])
        XCTAssertTrue(list[0].isActive(now: now))
        XCTAssertEqual(list[1].timeUntilStart(now: now), 600)
    }
}

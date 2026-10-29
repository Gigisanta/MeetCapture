import EventKit
import XCTest
@testable import MeetCaptureCore

final class MeetingContextTests: XCTestCase {
    private let now = TestSupport.fixedDate
    private let local = CalendarEventSnapshot.Attendee(name: "Gio", email: "gio@example.test", isCurrentUser: true)
    private let guest = CalendarEventSnapshot.Attendee(name: "Ana", email: "ana@client.test", isCurrentUser: false)

    private func event(id: String? = "calendar-real-id", url: String? = "https://meet.google.com/abc-defg-hij",
                       notes: String? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: id, title: "Revisión", start: now.addingTimeInterval(-60),
                              end: now.addingTimeInterval(60), url: url.flatMap(URL.init(string:)),
                              notes: notes, attendees: [local, guest], organizer: guest)
    }

    private func capture(_ events: [CalendarEventSnapshot], bundles: [String] = []) -> MeetingContext {
        MeetingContext.capture(events: events, at: now, activeBundleIDs: bundles, timeZone: "America/Argentina/Buenos_Aires")
    }

    func testOnlyOneActiveConferenceEventCanBeMatched() {
        var upcoming = event(id: "future")
        upcoming.start = now.addingTimeInterval(1)
        var ended = event(id: "ended")
        ended.end = now
        let ordinary = event(id: "ordinary", url: "https://example.test/agenda")
        let context = capture([upcoming, ended, ordinary])
        XCTAssertEqual(context.calendarMatch, .none)
        XCTAssertNil(context.calendarEvent, "an upcoming title or an ended event is not this recording")
        XCTAssertEqual(context.platform, .unknown)

        var starting = event()
        starting.start = now
        let matched = capture([upcoming, starting, ended, ordinary])
        XCTAssertEqual(matched.calendarMatch, .matched)
        XCTAssertEqual(matched.calendarEvent?.id, "calendar-real-id")
        XCTAssertEqual(matched.platform, .meet)
    }

    func testOverlappingEventsStayAmbiguousRegardlessOfCalendarOrder() {
        let first = event(id: "first")
        let second = event(id: "second")
        for events in [[first, second], [second, first]] {
            let context = capture(events, bundles: ["com.google.Chrome"])
            XCTAssertEqual(context.calendarMatch, .ambiguous)
            XCTAssertNil(context.calendarEvent)
            XCTAssertEqual(context.platform, .unknown, "ambiguous calendar links cannot identify a browser call")
            XCTAssertEqual(Set(context.platformEvidence.compactMap(\.calendarEventId)), ["first", "second"])
            XCTAssertTrue(context.speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
        }
    }

    func testMissingCalendarIdentifiersNeverBecomeInventedMatches() {
        for id in [nil, "", "  "] as [String?] {
            let context = capture([event(id: id)])
            XCTAssertEqual(context.calendarMatch, .none)
            XCTAssertNil(context.calendarEvent)
        }
    }

    func testRecognizedURLsIdentifyPlatformAndRetainTheirSource() {
        let cases: [(String, MeetingPlatform)] = [
            ("https://meet.google.com/abc-defg-hij", .meet),
            ("https://us02web.zoom.us/j/123", .zoom),
            ("https://zoom.us/j/123", .zoom),
            ("https://teams.microsoft.com/l/meetup-join/123", .teams),
            ("https://teams.live.com/meet/123", .teams),
            ("https://teams.cloud.microsoft/meet/123", .teams),
            ("https://whereby.com/room", .other),
            ("https://meet.jit.si/room", .other),
            ("https://client.webex.com/meet/ana", .other),
        ]
        for (url, platform) in cases {
            let direct = capture([event(url: url)], bundles: ["com.google.Chrome.helper"])
            XCTAssertEqual(direct.calendarMatch, .matched, url)
            XCTAssertEqual(direct.platform, platform, url)
            XCTAssertTrue(direct.platformEvidence.contains {
                $0.source == .calendarURL && $0.platform == platform && $0.value == url && $0.calendarEventId == "calendar-real-id"
            }, url)
            let notes = capture([event(url: nil, notes: "Ingresar: <\(url)>.")])
            XCTAssertEqual(notes.calendarMatch, .matched, url)
            XCTAssertEqual(notes.platform, platform, url)
            XCTAssertEqual(notes.platformEvidence.first?.source, .calendarNotes, url)
            XCTAssertEqual(notes.platformEvidence.first?.value, url, url)
        }
    }

    func testLookalikeAndEmbeddedURLsAreNotConferenceEvidence() {
        let urls = [
            "https://meet.google.com.evil.test/abc-defg-hij",
            "https://notmeet.google.com/abc-defg-hij",
            "https://zoom.us.evil.test/j/123",
            "https://notzoom.us/j/123",
            "https://teams.microsoft.com.evil.test/l/meetup-join/123",
            "https://evilteams.microsoft.com/l/meetup-join/123",
            "https://evil.test/?next=https://meet.google.com/abc-defg-hij",
            "https://evil.test/https://zoom.us/j/123",
            "https://meet.google.com@evil.test/abc-defg-hij",
            "https://evil.test@meet.google.com/abc-defg-hij",
            "ftp://meet.google.com/abc-defg-hij",
        ]
        for url in urls {
            for input in [event(url: url), event(url: nil, notes: "Join: \(url)")] {
                let context = capture([input], bundles: ["com.apple.Safari"])
                XCTAssertEqual(context.calendarMatch, .none, url)
                XCTAssertNil(context.calendarEvent, url)
                XCTAssertEqual(context.platform, .unknown, url)
                XCTAssertEqual(context.platformEvidence.map(\.source), [.activeMicrophoneBundle], url)
            }
        }
    }

    func testNativeMicrophoneEvidenceDistinguishesKnownOtherFromBrowserUnknown() {
        let cases: [(String, MeetingPlatform)] = [
            ("Us.Zoom.Xos", .zoom), ("us.zoom.xos.helper", .zoom),
            ("com.microsoft.teams2", .teams), ("com.google.meet", .meet),
            ("com.tinyspeck.slackmacgap", .other), ("com.apple.facetime", .other),
            ("com.google.Chrome", .unknown), ("com.apple.WebKit.GPU", .unknown),
            ("com.microsoft.edgemac", .unknown), ("org.mozilla.firefox", .unknown),
            ("us.zoom.xosmalware", .unknown), ("x.com.microsoft.teams2", .unknown),
        ]
        for (bundle, platform) in cases {
            let context = capture([], bundles: [bundle])
            XCTAssertEqual(context.calendarMatch, .none, bundle)
            XCTAssertNil(context.calendarEvent, bundle)
            XCTAssertEqual(context.platform, platform, bundle)
            XCTAssertEqual(context.platformEvidence.count, 1, bundle)
            XCTAssertEqual(context.platformEvidence.first?.source, .activeMicrophoneBundle, bundle)
            XCTAssertEqual(context.platformEvidence.first?.value, bundle, bundle)
        }
        let compatible: [(String, [String], MeetingPlatform)] = [
            ("https://zoom.us/j/123", ["us.zoom.xos", "us.zoom.xos.helper"], .zoom),
            ("https://client.webex.com/meet/ana",
             ["com.cisco.webexmeetingsapp", "COM.CISCO.WEBEXMEETINGSAPP.helper"], .other),
        ]
        for (url, bundles, platform) in compatible {
            let sameProvider = capture([event(url: url, notes: "Join: \(url)")], bundles: bundles)
            XCTAssertEqual(sameProvider.calendarMatch, .matched,
                           "same-provider helpers and a repeated conference link are compatible")
            XCTAssertEqual(sameProvider.platform, platform)
        }
    }

    func testConflictingPlatformEvidenceDoesNotCreateAFalseCalendarMatch() {
        let calendarConflict = capture([event()], bundles: ["us.zoom.xos"])
        XCTAssertEqual(calendarConflict.calendarMatch, .none)
        XCTAssertNil(calendarConflict.calendarEvent)
        XCTAssertEqual(calendarConflict.platform, .unknown)
        XCTAssertEqual(Set(calendarConflict.platformEvidence.map(\.platform)), [.meet, .zoom])
        XCTAssertTrue(calendarConflict.speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)

        let competingNative = capture([], bundles: ["us.zoom.xos", "com.microsoft.teams2"])
        XCTAssertEqual(competingNative.platform, .unknown)
        XCTAssertEqual(Set(competingNative.platformEvidence.map(\.platform)), [.zoom, .teams])

        let competingOther = capture([], bundles: ["com.tinyspeck.slackmacgap", "com.cisco.webexmeetingsapp"])
        XCTAssertEqual(competingOther.platform, .unknown, "other is not a shared provider identity")
        XCTAssertEqual(competingOther.platformEvidence.count, 2)
        XCTAssertEqual(Set(competingOther.platformEvidence.map(\.platform)), [.other],
                       "keep the observed public category even when providers conflict")

        let competingLinks = capture([event(notes: "Fallback: https://zoom.us/j/123")])
        XCTAssertEqual(competingLinks.calendarMatch, .none)
        XCTAssertNil(competingLinks.calendarEvent)
        XCTAssertEqual(competingLinks.platform, .unknown)
        XCTAssertEqual(Set(competingLinks.platformEvidence.map(\.source)), [.calendarURL, .calendarNotes])
    }

    func testDifferentOtherProvidersCannotSupplyCalendarIdentity() {
        let webex = "https://client.webex.com/meet/ana"
        let slack = "com.tinyspeck.slackmacgap"
        let whereby = "https://whereby.com/other"
        let inputs: [(CalendarEventSnapshot, [String], Set<String>)] = [
            (event(url: webex), [slack], [webex, slack]),
            (event(url: webex, notes: whereby), [], [webex, whereby]),
        ]
        for (event, bundles, values) in inputs {
            let context = capture([event], bundles: bundles)
            XCTAssertNil(context.calendarEvent)
            XCTAssertEqual(context.calendarMatch, .none)
            XCTAssertEqual(Set(context.platformEvidence.map(\.value)), values,
                           "conflicting evidence is retained rather than rewritten as unknown")
            XCTAssertEqual(Set(context.platformEvidence.map(\.platform)), [.other])
            XCTAssertEqual(context.platform, .unknown)
            XCTAssertTrue(context.speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
        }
    }

    @MainActor
    func testAllDayCalendarSnapshotCannotSupplyTimedMeetingIdentity() {
        let raw = EKEvent(eventStore: EKEventStore())
        raw.title = "Fixture de día completo"
        raw.startDate = Calendar(identifier: .gregorian).startOfDay(for: now)
        raw.endDate = raw.startDate.addingTimeInterval(86_400)
        raw.isAllDay = true
        raw.url = URL(string: "https://meet.google.com/abc-defg-hij")
        var snapshot = CalendarService.snapshot(raw)
        XCTAssertEqual(snapshot.isAllDay, true, "the EventKit boundary must preserve date-only semantics")
        snapshot.id = "fixture-real-id"
        snapshot.attendees = [local, guest]
        let context = capture([snapshot])
        XCTAssertNil(context.calendarEvent)
        XCTAssertEqual(context.calendarMatch, .none)
        XCTAssertEqual(context.platform, .unknown)
        XCTAssertEqual(context.platformEvidence.map(\.value), ["https://meet.google.com/abc-defg-hij"],
                       "the calendar link was observed but does not identify a timed call")
        XCTAssertTrue(context.speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
    }

    func testOneToOneAttributionUsesActualCalendarNamesAndObservedDiarizedLabels() {
        let speakers = ["Yo", "Participante 1", "Yo"]
        let context = capture([event()])
        let map = context.speakerMap(for: speakers, remoteSpeakerCount: 1)
        XCTAssertEqual(Set(map.keys), ["Yo", "Participante 1"])
        XCTAssertEqual(map["Yo"]?.name, "Gio")
        XCTAssertEqual(map["Yo"]?.email, "gio@example.test")
        XCTAssertEqual(map["Yo"]?.evidence, [.calendarCurrentUser, .localMicrophone])
        XCTAssertEqual(map["Participante 1"]?.name, "Ana")
        XCTAssertEqual(map["Participante 1"]?.email, "ana@client.test")
        XCTAssertEqual(map["Participante 1"]?.evidence, [.calendarOneToOne, .singleRemoteDiarization])
        XCTAssertEqual(Set(context.speakerMap(for: ["Participante 1"], remoteSpeakerCount: 1).keys), ["Participante 1"],
                       "do not emit unobserved local labels")
        var organizedByUser = event()
        organizedByUser.attendees = [guest]
        organizedByUser.organizer = local
        XCTAssertEqual(capture([organizedByUser]).speakerMap(for: speakers, remoteSpeakerCount: 1)["Yo"]?.email,
                       "gio@example.test", "the known calendar account may be the organizer")
    }

    func testAttributionExcludesMissingDiarizationAndNonCanonicalLabels() {
        let context = capture([event()])
        for count in [nil, 0, 2] as [Int?] {
            XCTAssertTrue(context.speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: count).isEmpty)
        }
        for labels in [["Yo", "Participante"], ["Yo", "Participante 2"], ["Yo"],
                       ["Yo", "Participante 1", "Participante 2"], ["Ana", "Participante 1"]] {
            XCTAssertTrue(context.speakerMap(for: labels, remoteSpeakerCount: 1).isEmpty, labels.description)
        }
        XCTAssertTrue(MeetingContext.unmatched().speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
    }

    func testAttributionExcludesMultiPartyUnknownAndConflictingIdentities() {
        var multiParty = event()
        multiParty.attendees.append(.init(name: "Luis", email: "luis@client.test", isCurrentUser: false))
        var unnamed = event()
        unnamed.attendees[1].name = nil
        unnamed.organizer = nil
        var unidentified = event()
        unidentified.attendees[1].email = nil
        unidentified.organizer = nil
        var noCurrentUser = event()
        noCurrentUser.attendees[0].isCurrentUser = false
        var unidentifiedCurrentUser = event()
        unidentifiedCurrentUser.attendees[0].email = nil
        var unknownInvitee = event()
        unknownInvitee.attendees.append(.init(name: nil, email: nil, isCurrentUser: false))
        var conflictingName = event()
        conflictingName.organizer?.name = "Otra persona"
        var thirdPartyOrganizer = event()
        thirdPartyOrganizer.organizer = .init(name: "Luis", email: "luis@client.test", isCurrentUser: false)
        for input in [multiParty, unnamed, unidentified, noCurrentUser, unidentifiedCurrentUser,
                      unknownInvitee, conflictingName, thirdPartyOrganizer] {
            XCTAssertTrue(capture([input]).speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
        }
        for email in ["not-an-email", "@client.test", "ana@", "ana@client.test,luis@other.test"] {
            var invalidIdentity = event()
            invalidIdentity.attendees[1].email = email
            invalidIdentity.organizer = nil
            XCTAssertTrue(capture([invalidIdentity]).speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
        }

        var noLocalName = event()
        noLocalName.attendees[0].name = nil
        let localIdentity = capture([noLocalName]).speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1)["Yo"]
        XCTAssertNil(localIdentity?.name, "an account email never becomes a fabricated display name")
        XCTAssertEqual(localIdentity?.email, "gio@example.test")
    }

    func testCodableMetadataPreservesFullSnapshotAndExplicitUnknowns() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let context = capture([event(notes: "Agenda original")])
        let encoded = try encoder.encode(context)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let calendar = try XCTUnwrap(json["calendarEvent"] as? [String: Any])
        XCTAssertEqual(calendar["id"] as? String, "calendar-real-id")
        XCTAssertEqual(calendar["title"] as? String, "Revisión")
        XCTAssertEqual(calendar["start"] as? String, "2026-09-01T14:07:29Z")
        XCTAssertEqual(calendar["end"] as? String, "2026-09-01T14:09:29Z")
        XCTAssertEqual(calendar["url"] as? String, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(calendar["notes"] as? String, "Agenda original")
        XCTAssertEqual(calendar["isAllDay"] as? Bool, false)
        let attendees = try XCTUnwrap(calendar["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees[0]["name"] as? String, "Gio")
        XCTAssertEqual(attendees[0]["email"] as? String, "gio@example.test")
        XCTAssertEqual(attendees[0]["isCurrentUser"] as? Bool, true)
        XCTAssertEqual((calendar["organizer"] as? [String: Any])?["name"] as? String, "Ana")
        XCTAssertEqual(json["timeZone"] as? String, "America/Argentina/Buenos_Aires")
        XCTAssertEqual(try decoder.decode(MeetingContext.self, from: encoded), context)

        let unmatchedData = try encoder.encode(MeetingContext.unmatched(timeZone: "UTC"))
        let unmatched = try XCTUnwrap(JSONSerialization.jsonObject(with: unmatchedData) as? [String: Any])
        XCTAssertTrue(unmatched["calendarEvent"] is NSNull)
        XCTAssertEqual(unmatched["calendarMatch"] as? String, "none")
        XCTAssertEqual(unmatched["platform"] as? String, "unknown")
        var unknown = event(id: nil, url: nil)
        unknown.title = nil
        unknown.notes = nil
        unknown.organizer = nil
        unknown.attendees = [.init(name: nil, email: nil, isCurrentUser: false)]
        let unknownJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(unknown)) as? [String: Any])
        for key in ["id", "title", "url", "notes", "organizer"] { XCTAssertTrue(unknownJSON[key] is NSNull, key) }
        let unknownAttendees = try XCTUnwrap(unknownJSON["attendees"] as? [[String: Any]])
        XCTAssertTrue(unknownAttendees[0]["name"] is NSNull)
        XCTAssertTrue(unknownAttendees[0]["email"] is NSNull)
        var noLocalName = event()
        noLocalName.attendees[0].name = nil
        let attributionData = try encoder.encode(capture([noLocalName]).speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1))
        let attributions = try XCTUnwrap(JSONSerialization.jsonObject(with: attributionData) as? [String: [String: Any]])
        XCTAssertTrue(attributions["Yo"]?["name"] is NSNull)
        XCTAssertEqual(attributions["Yo"]?["email"] as? String, "gio@example.test")
        XCTAssertEqual(attributions["Participante 1"]?["evidence"] as? [String],
                       ["calendar_one_to_one", "single_remote_diarization"])
    }

    func testUnknownOrDateOnlyCalendarMetadataCannotRestoreTimedIdentity() throws {
        let context = capture([event()])
        let encoded = try JSONEncoder().encode(context)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let calendar = try XCTUnwrap(original["calendarEvent"] as? [String: Any])
        let kinds: [Any?] = [nil, NSNull(), true]
        for kind in kinds {
            var snapshot = calendar
            if let kind {
                snapshot["isAllDay"] = kind
            } else {
                snapshot.removeValue(forKey: "isAllDay")
            }
            let eventData = try JSONSerialization.data(withJSONObject: snapshot)
            let event = try JSONDecoder().decode(CalendarEventSnapshot.self, from: eventData)
            XCTAssertEqual(event.isAllDay, kind as? Bool,
                           "an absent/null old field stays unknown, not implicitly timed")
            XCTAssertNil(capture([event]).calendarEvent)

            var archived = original
            archived["calendarEvent"] = snapshot
            let data = try JSONSerialization.data(withJSONObject: archived)
            let restored = try JSONDecoder().decode(MeetingContext.self, from: data)
            XCTAssertNil(restored.calendarEvent)
            XCTAssertEqual(restored.calendarMatch, .none)
            XCTAssertEqual(restored.platform, .unknown)
            XCTAssertTrue(restored.speakerMap(for: ["Yo", "Participante 1"], remoteSpeakerCount: 1).isEmpty)
            XCTAssertEqual(restored.platformEvidence, context.platformEvidence,
                           "older metadata remains readable without discarding observed evidence")
        }
    }
}

import XCTest
@testable import MeetCaptureCore

final class CallActivityDebouncerTests: XCTestCase {
    func testCallEndsOnlyAfterConfirmedInactivity() {
        var d = CallActivityDebouncer(confirmCount: 2)
        XCTAssertEqual(d.observe(active: true), true)
        XCTAssertNil(d.observe(active: true))
        XCTAssertNil(d.observe(active: false), "first inactive sample is not conclusive")
        XCTAssertTrue(d.needsConfirmation)
        XCTAssertNil(d.observe(active: true), "a blip resets the streak")
        XCTAssertFalse(d.needsConfirmation)
        XCTAssertNil(d.observe(active: false))
        XCTAssertEqual(d.observe(active: false), false)
        XCTAssertFalse(d.isActive)
        XCTAssertNil(d.observe(active: false), "no repeated 'ended' events")
    }

    func testConfirmCountIsAtLeastOne() {
        var d = CallActivityDebouncer(confirmCount: 0)
        XCTAssertEqual(d.observe(active: true), true)
        XCTAssertEqual(d.observe(active: false), false)
    }
}

final class MeetingDetectionPolicyTests: XCTestCase {
    let now = TestSupport.fixedDate
    func meeting(startIn offset: TimeInterval, length: TimeInterval = 1_800) -> Meeting {
        Meeting(id: "m", title: "t", startDate: now.addingTimeInterval(offset), endDate: now.addingTimeInterval(offset + length),
                meetURL: URL(string: "https://meet.google.com/abc-defg-hij")!, externalAttendees: ["x@y.z"])
    }

    func testApproachingWindowIs5MinBeforeTo1MinAfter() {
        XCTAssertNotNil(MeetingDetectionPolicy.approachingMeeting(in: [meeting(startIn: 300)], now: now))
        XCTAssertNil(MeetingDetectionPolicy.approachingMeeting(in: [meeting(startIn: 301)], now: now))
        XCTAssertNotNil(MeetingDetectionPolicy.approachingMeeting(in: [meeting(startIn: -59)], now: now))
        XCTAssertNil(MeetingDetectionPolicy.approachingMeeting(in: [meeting(startIn: -60)], now: now))
    }

    func testCallActivityActions() {
        typealias P = MeetingDetectionPolicy
        XCTAssertNil(P.action(callActive: true, phase: .idle, origin: nil, autoRecord: false))
        XCTAssertEqual(P.action(callActive: true, phase: .idle, origin: nil, autoRecord: true), .start(.liveCall))
        XCTAssertEqual(P.action(callActive: true, phase: .approaching, origin: nil, autoRecord: true), .start(.calendar))
        XCTAssertNil(P.action(callActive: true, phase: .recording, origin: .manual, autoRecord: true))
        XCTAssertEqual(P.action(callActive: false, phase: .recording, origin: .liveCall, autoRecord: true), .stop)
        XCTAssertNil(P.action(callActive: false, phase: .recording, origin: .manual, autoRecord: true), "manual recordings are never auto-stopped")
        XCTAssertNil(P.action(callActive: false, phase: .recording, origin: .calendar, autoRecord: true), "calendar recordings stop by end time, not by mic")
        XCTAssertNil(P.action(callActive: false, phase: .transcribing, origin: .liveCall, autoRecord: true))
    }

    func testScheduledStartNeedsRealCall() {
        typealias P = MeetingDetectionPolicy
        XCTAssertEqual(P.startAtScheduledTime(phase: .approaching, callActive: true, autoRecord: true), .start(.calendar))
        XCTAssertNil(P.startAtScheduledTime(phase: .approaching, callActive: false, autoRecord: true))
        XCTAssertNil(P.startAtScheduledTime(phase: .idle, callActive: true, autoRecord: true))
        XCTAssertNil(P.startAtScheduledTime(phase: .approaching, callActive: true, autoRecord: false))
    }

    func testCalendarEndGraceAndMaxDuration() {
        let m = meeting(startIn: -1_800, length: 1_800) // ends now
        XCTAssertFalse(MeetingDetectionPolicy.shouldStopCalendarRecording(meeting: m, now: now.addingTimeInterval(120)))
        XCTAssertTrue(MeetingDetectionPolicy.shouldStopCalendarRecording(meeting: m, now: now.addingTimeInterval(121)))
        XCTAssertTrue(MeetingDetectionPolicy.shouldStopForMaxDuration(elapsed: 10_800, maximum: 10_800))
        XCTAssertFalse(MeetingDetectionPolicy.shouldStopForMaxDuration(elapsed: 10_799, maximum: 10_800))
    }
}

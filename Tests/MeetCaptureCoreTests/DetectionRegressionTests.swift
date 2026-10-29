import XCTest
@testable import MeetCaptureCore

final class DetectionRegressionTests: XCTestCase {
    func testCallAppMatcherRejectsLookalikeBundleIDs() {
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "com.google.chromeos"))
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "us.zoom.xosmalware"))
        XCTAssertTrue(CallAppMatcher.isCallApp(bundleID: "com.google.chrome.helper"))
    }

    func testMeetingFilterRejectsLookalikeAndEmbeddedMeetHosts() {
        let now = TestSupport.fixedDate
        for address in [
            "https://notmeet.google.com/abc-defg-hij",
            "https://meet.google.com.evil.test/abc-defg-hij",
            "https://evil.test/path/https://meet.google.com/abc-defg-hij",
        ] {
            var event = CalendarEventSnapshot(
                id: "lookalike", title: "External", start: now.addingTimeInterval(300),
                end: now.addingTimeInterval(1_800), url: URL(string: address), notes: nil,
                attendees: [.init(email: "guest@example.com", isCurrentUser: false)])
            XCTAssertNil(MeetingFilter.meeting(from: event, whitelist: []), address)
            event.url = nil
            event.notes = "Join: \(address)"
            XCTAssertNil(MeetingFilter.meeting(from: event, whitelist: []), address)
        }
    }
}

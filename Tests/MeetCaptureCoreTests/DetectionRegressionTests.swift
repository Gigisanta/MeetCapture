import XCTest
@testable import MeetCaptureCore

final class DetectionRegressionTests: XCTestCase {
    func testCallAppMatcherRejectsLookalikeBundleIDs() {
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "com.google.chromeos"))
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "us.zoom.xosmalware"))
        XCTAssertTrue(CallAppMatcher.isCallApp(bundleID: "com.google.chrome.helper"))
    }

    func testMeetingFilterRejectsLookalikeMeetHost() {
        let now = TestSupport.fixedDate
        let event = CalendarEventSnapshot(
            id: "lookalike",
            title: "External",
            start: now.addingTimeInterval(300),
            end: now.addingTimeInterval(1_800),
            url: URL(string: "https://notmeet.google.com/abc-defg-hij"),
            notes: nil,
            attendees: [.init(email: "guest@example.com", isCurrentUser: false)])

        XCTAssertNil(MeetingFilter.meeting(from: event, whitelist: []))
    }
}

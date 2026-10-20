import XCTest
@testable import MeetCaptureCore

final class CallAppMatcherTests: XCTestCase {
    func testEmptyAndNilNeverMatch() {
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: nil))
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: ""))
    }

    func testNonCallAppsIgnored() {
        for bid in ["com.spotify.client", "com.apple.dt.Xcode", "com.apple.Terminal", "com.meetcapture"] {
            XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: bid), bid)
        }
    }

    func testMatchIsCaseInsensitive() {
        for bid in ["COM.GOOGLE.CHROME", "Us.Zoom.Xos", "com.Apple.Safari", "com.google.Chrome.helper"] {
            XCTAssertTrue(CallAppMatcher.isCallApp(bundleID: bid), bid)
        }
    }

    func testEveryRegisteredPrefixMatchesItself() {
        for prefix in CallAppMatcher.prefixes {
            XCTAssertTrue(CallAppMatcher.isCallApp(bundleID: prefix), prefix)
        }
    }

    func testSafariCallsAndNewTeamsAreDetected() {
        // Safari captures the mic from WebKit's GPU helper, not from Safari;
        // the current Teams client is a separate bundle, not a Teams helper.
        for bid in ["com.apple.WebKit.GPU", "com.microsoft.teams2"] {
            XCTAssertTrue(CallAppMatcher.isCallApp(bundleID: bid), bid)
        }
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "com.apple.WebKit.Networking"))
    }

    func testPrefixMustBeAtStart() {
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "x.us.zoom.xos"))
        XCTAssertFalse(CallAppMatcher.isCallApp(bundleID: "chrome"))
    }
}

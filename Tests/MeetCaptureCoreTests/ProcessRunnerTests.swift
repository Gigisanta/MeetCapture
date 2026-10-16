import XCTest
@testable import MeetCaptureCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStdoutAndExitCode() async throws {
        let r = try await ProcessRunner.run(ProcessSpec(executable: "/bin/sh", arguments: ["-c", "echo out; echo err 1>&2; exit 3"], timeout: 10))
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self), "out\n")
        XCTAssertEqual(r.stderrText, "err")
        XCTAssertEqual(r.exitCode, 3)
        XCTAssertFalse(r.succeeded)
        XCTAssertFalse(r.timedOut)
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        // 1 MB on both pipes: more than the 64 KB kernel buffer, so unread pipes would hang.
        let script = "head -c 1048576 /dev/zero | tr '\\0' a; head -c 1048576 /dev/zero | tr '\\0' b 1>&2"
        let r = try await ProcessRunner.run(ProcessSpec(executable: "/bin/sh", arguments: ["-c", script], timeout: 30))
        XCTAssertEqual(r.stdout.count, 1_048_576)
        XCTAssertEqual(r.stderr.count, 1_048_576)
        XCTAssertTrue(r.succeeded)
    }

    func testTimeoutTerminatesTheChild() async throws {
        let start = Date()
        let r = try await ProcessRunner.run(ProcessSpec(executable: "/bin/sleep", arguments: ["30"], timeout: 0.5))
        XCTAssertTrue(r.timedOut)
        XCTAssertFalse(r.exitedNormally)
        XCTAssertFalse(r.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testRunCheckedThrowsOnFailure() async {
        do {
            _ = try await ProcessRunner.runChecked(ProcessSpec(executable: "/bin/sh", arguments: ["-c", "exit 2"], timeout: 10))
            XCTFail("expected an error")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        do {
            _ = try await ProcessRunner.run(ProcessSpec(executable: "/nonexistent/binary", arguments: [], timeout: 10))
            XCTFail("expected a launch error")
        } catch {}
    }
}

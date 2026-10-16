import XCTest
@testable import MeetCaptureCore

final class ProcessCancellationTests: XCTestCase {
    func testCancellationClosesPipesAfterParentHasExited() async throws {
        let dir = TestSupport.makeTempDir(self, "orphan-pipe")
        let marker = dir + "/pids"
        let task = Task {
            try await ProcessRunner.run(ProcessSpec(executable: "/bin/sh", arguments: [
                "-c", "sleep 2 & printf '%s %s' \"$$\" \"$!\" > \"$1\"; exit 0", "worker", marker
            ], timeout: 10))
        }
        let deadline = Date().addingTimeInterval(1)
        var pids: [Int32] = []
        while Date() < deadline {
            pids = ((try? String(contentsOfFile: marker, encoding: .utf8)) ?? "")
                .split(separator: " ").compactMap { Int32($0) }
            if pids.count == 2, kill(pids[0], 0) != 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(pids.count, 2)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
        if pids.count == 2 { XCTAssertNotEqual(kill(pids[1], 0), 0, "child must be terminated") }
    }

    func testTimeoutClosesInheritedPipesAfterParentExits() async throws {
        let start = Date()
        let result = try await ProcessRunner.run(ProcessSpec(
            executable: "/bin/sh", arguments: ["-c", "sleep 2 & exit 0"], timeout: 0.1))
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testCancellationEscalatesForDescendantsIgnoringTermination() async throws {
        let start = Date()
        let task = Task {
            try await ProcessRunner.run(ProcessSpec(executable: "/bin/sh", arguments: [
                "-c", "trap '' TERM; sleep 8 & wait"
            ], timeout: 15))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), ProcessRunner.killGrace + 2)
    }

    func testAlreadyCancelledTaskNeverLaunchesProcess() async throws {
        let dir = TestSupport.makeTempDir(self, "cancelled-process")
        let marker = dir + "/launched"
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.runChecked(ProcessSpec(
                executable: "/usr/bin/touch", arguments: [marker], timeout: 10))
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled transcription must not launch a process or report success")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testCancellingRunningProcessReturnsCancellation() async throws {
        let dir = TestSupport.makeTempDir(self, "running-process")
        let marker = dir + "/started"
        let executable = dir + "/worker"
        TestSupport.writeExecutable("touch \"$1\"\nexec /bin/sleep 30", to: executable)
        let task = Task {
            try await ProcessRunner.runChecked(ProcessSpec(
                executable: executable, arguments: [marker], timeout: 10))
        }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancellation must not be reported as success")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 8)
    }
}

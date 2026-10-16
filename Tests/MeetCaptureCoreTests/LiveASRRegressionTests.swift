import Foundation
import XCTest
@testable import MeetCaptureCore

@MainActor
final class LiveASRRegressionTests: XCTestCase {
    func testBacklogCannotCrossRestartAndPendingLimitRemainsBounded() async throws {
        let directory = TestSupport.makeTempDir(self, "live-asr-backlog")
        let feedQueue = DispatchQueue(label: "meetcapture.tests.live-asr-feed")
        let oldRelease = directory + "/old-release"
        let newRelease = directory + "/new-release"
        let oldOutput = directory + "/old-input"
        let newOutput = directory + "/new-input"
        let oldToolchain = try makeFixtureToolchain(directory: directory, name: "old",
                                                    output: oldOutput, release: oldRelease)
        let newToolchain = try makeFixtureToolchain(directory: directory, name: "new",
                                                    output: newOutput, release: newRelease)
        let service = LiveASRService(feedQueue: feedQueue)
        var firstBarrier: DispatchSemaphore?
        var limitBarrier: DispatchSemaphore?
        defer {
            firstBarrier?.signal()
            limitBarrier?.signal()
            touch(oldRelease)
            touch(newRelease)
            service.unload()
            cleanupFixtureProcessGroups([
                directory + "/old-recognizer",
                directory + "/new-recognizer"
            ])
        }

        try await beginAndWaitForReady(service, toolchain: oldToolchain, started: oldOutput + ".started")
        firstBarrier = try startBarrier(on: feedQueue)
        let staleSamples = [Int16](repeating: 0x1111, count: 4)
        service.feed(staleSamples)
        service.endSession()
        service.unload()

        try await beginAndWaitForReady(service, toolchain: newToolchain, started: newOutput + ".started")
        let oldFeedDrained = DispatchSemaphore(value: 0)
        feedQueue.async { oldFeedDrained.signal() }
        firstBarrier?.signal()
        XCTAssertEqual(oldFeedDrained.wait(timeout: .now() + 3), .success,
                       "the queued old feed must drain without blocking shutdown")
        touch(oldRelease)

        limitBarrier = try startBarrier(on: feedQueue)
        let maxSamples = 64 * 1024 / MemoryLayout<Int16>.stride
        let boundedSamples = [Int16](repeating: 0x2222, count: maxSamples)
        service.feed(boundedSamples)
        service.feed([0x3333])
        touch(newRelease)

        let limitFeedDrained = DispatchSemaphore(value: 0)
        feedQueue.async { limitFeedDrained.signal() }
        limitBarrier?.signal()
        XCTAssertEqual(limitFeedDrained.wait(timeout: .now() + 3), .success,
                       "the bounded feed must drain without hanging")

        service.unload()
        let expected = data(for: boundedSamples).dropFirst()
        try waitUntil(timeout: 3) {
            guard let actual = try? Data(contentsOf: URL(fileURLWithPath: newOutput)) else { return false }
            return actual == expected
        }
        let actual = try Data(contentsOf: URL(fileURLWithPath: newOutput))
        XCTAssertEqual(actual, expected, "old-session bytes or bytes over the 64 KiB limit reached the new child")
        XCTAssertFalse(actual.contains(0x11), "old-session marker must not reach the new child")
    }

    func testWarmReadyAndEOFStillDeliverFinalLine() async throws {
        let directory = TestSupport.makeTempDir(self, "live-asr-eof")
        let release = directory + "/release"
        let output = directory + "/input"
        let finalLine = "{\"type\":\"partial\",\"text\":\"eof fixture\"}"
        let toolchain = try makeFixtureToolchain(directory: directory, name: "eof",
                                                 output: output, release: release, eofLine: finalLine)
        let service = LiveASRService()
        let partial = expectation(description: "EOF partial")
        service.onPartial = { text in
            if text == "eof fixture" { partial.fulfill() }
        }
        defer {
            touch(release)
            service.unload()
            cleanupFixtureProcessGroups([directory + "/eof-recognizer"])
        }

        try await beginAndWaitForReady(service, toolchain: toolchain, started: output + ".started")
        let started = Date()
        touch(release)
        service.unload()

        await fulfillment(of: [partial], timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1,
                          "unload must not wait for the fixture subprocess")
    }

    func testLateOutputFromReplacedChildIsDiscarded() async throws {
        let directory = TestSupport.makeTempDir(self, "live-asr-generation")
        let oldRelease = directory + "/old-release"
        let newRelease = directory + "/new-release"
        let oldOutput = directory + "/old-input"
        let newOutput = directory + "/new-input"
        let oldLine = "{\"type\":\"partial\",\"text\":\"old-late\"}"
        let oldToolchain = try makeFixtureToolchain(directory: directory, name: "old",
                                                    output: oldOutput, release: oldRelease,
                                                    eofLine: oldLine)
        let newToolchain = try makeFixtureToolchain(directory: directory, name: "new",
                                                    output: newOutput, release: newRelease)
        let service = LiveASRService()
        let stale = expectation(description: "late output from old child")
        stale.isInverted = true
        service.onPartial = { text in
            if text == "old-late" { stale.fulfill() }
        }
        defer {
            touch(oldRelease)
            touch(newRelease)
            service.unload()
            cleanupFixtureProcessGroups([
                directory + "/old-recognizer",
                directory + "/new-recognizer"
            ])
        }

        try await beginAndWaitForReady(service, toolchain: oldToolchain, started: oldOutput + ".started")
        try await beginAndWaitForReady(service, toolchain: newToolchain, started: newOutput + ".started")
        touch(oldRelease)
        await fulfillment(of: [stale], timeout: 0.5)
    }

    private func beginAndWaitForReady(_ service: LiveASRService, toolchain: Toolchain,
                                      started: String) async throws {
        let ready = expectation(description: "live ASR ready")
        service.onState = { state in
            if state == .ready { ready.fulfill() }
        }
        service.beginSession(model: "fixture", toolchain: toolchain)
        await fulfillment(of: [ready], timeout: 3)
        guard service.state == .ready else {
            let launched = FileManager.default.fileExists(atPath: started)
            throw FixtureError.state("\(service.state) started=\(launched)")
        }
    }

    private func startBarrier(on queue: DispatchQueue) throws -> DispatchSemaphore {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        queue.async {
            entered.signal()
            gate.wait()
        }
        guard entered.wait(timeout: .now() + 3) == .success else {
            throw FixtureError.timeout("feed queue barrier")
        }
        return gate
    }

    private func makeFixtureToolchain(directory: String, name: String, output: String,
                                      release: String, eofLine: String? = nil) throws -> Toolchain {
        let scripts = directory + "/\(name)-scripts"
        try FileManager.default.createDirectory(atPath: scripts, withIntermediateDirectories: true)
        TestSupport.write("", to: scripts + "/meetcapture_stream_asr.py")
        let executable = directory + "/\(name)-recognizer"
        let started = output + ".started"
        let pidPath = executable + ".pid"
        let eofCommand = eofLine.map { "printf '%s' \(shellQuote($0))" } ?? ":"
        let body = """
        set -eu
        printf '%s\\n' "$$" > \(shellQuote(pidPath))
        : > \(shellQuote(started))
        /bin/echo '{"type":"ready"}'
        dd bs=1 count=1 of=/dev/null 2>/dev/null || true
        while [ ! -e \(shellQuote(release)) ]; do sleep 0.01; done
        cat > \(shellQuote(output))
        \(eofCommand)
        """
        TestSupport.writeExecutable(body, to: executable)
        return Toolchain(python: executable, pythonSource: .settings,
                         scriptsDir: scripts, scriptsSource: .settings)
    }

    private func cleanupFixtureProcessGroups(_ executables: [String]) {
        for executable in executables {
            guard let group = fixtureProcessGroup(for: executable) else { continue }
            _ = runProcess("/bin/kill", arguments: ["-TERM", "-\(group.pgid)"])
            if waitForFixtureExit(group.pid, executable, timeout: 1) { continue }
            _ = runProcess("/bin/kill", arguments: ["-KILL", "-\(group.pgid)"])
            _ = waitForFixtureExit(group.pid, executable, timeout: 1)
        }
    }

    private func fixtureProcessGroup(for executable: String) -> FixtureProcessGroup? {
        let pidPath = executable + ".pid"
        guard let rawPID = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = Int32(rawPID.trimmingCharacters(in: .whitespacesAndNewlines)),
              let row = runProcess("/bin/ps", arguments: ["-p", "\(pid)", "-o", "pgid=,args="]) else {
            return nil
        }
        let columns = row.split(maxSplits: 1, omittingEmptySubsequences: true,
                               whereSeparator: { $0 == " " || $0 == "\t" })
        guard columns.count == 2,
              let pgid = Int32(columns[0]),
              pgid == pid,
              String(columns[1]).contains(executable) else {
            return nil
        }
        return FixtureProcessGroup(pid: pid, pgid: pgid)
    }

    private func waitForFixtureExit(_ pid: Int32, _ executable: String,
                                    timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fixtureProcessGroup(for: executable) == nil { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return fixtureProcessGroup(for: executable) == nil || pid <= 0
    }

    private func runProcess(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func data(for samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private func touch(_ path: String) {
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw FixtureError.timeout("fixture output")
    }
}

private enum FixtureError: Error {
    case timeout(String)
    case state(String)
}

private struct FixtureProcessGroup {
    let pid: Int32
    let pgid: Int32
}

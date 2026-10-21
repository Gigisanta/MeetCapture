import Foundation
import XCTest
@testable import MeetCaptureCore

final class TranscriptionWorkerTests: XCTestCase {
    private static let outcomeLine = #"MCW1 {"outcome":{"segments":[{"start":0.25,"end":1.5,"text":"Hola, Simón.","speaker":"Participante"}],"engineUsed":"parakeet","modelUsed":"fake-worker","audioDurationSec":2.5,"failedChunks":1}}"#
    private static var expectedOutcome: TranscriptionJob.Outcome {
        .init(segments: [Segment(start: 0.25, end: 1.5, text: "Hola, Simón.", speaker: "Participante")],
              engineUsed: .parakeet, modelUsed: "fake-worker", audioDurationSec: 2.5, failedChunks: 1)
    }

    private func client(_ script: String, in directory: String, environment: [String: String] = [:],
                        cancellationGrace: TimeInterval = 0.1) -> TranscriptionWorkerClient {
        let path = directory + "/child-\(UUID().uuidString).sh"
        TestSupport.writeExecutable(script, to: path)
        return TranscriptionWorkerClient(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "exec /bin/sh \"$1\"", "worker-test", path],
                                         baseEnvironment: environment, cancellationGrace: cancellationGrace)
    }

    private func job(_ name: String = "input.wav") -> TranscriptionJob {
        TranscriptionJob(audioPath: name, captureSampleRate: 16_000, language: "es", diarize: false,
                         aliases: ["MaatWork": ["maat work", "Maat\nWork"]])
    }

    func testStreamsProgressIgnoresForeignLinesAndRoundTripsOutcomeAndRequest() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-roundtrip")
        let requestPath = directory + "/request.json"
        let values = ProgressValues()
        let client = client("""
            IFS= read -r request
            printf '%s' "$request" > "$REQUEST_PATH"
            printf 'unrelated SDK output\\nMCW1 {"progress":0.25}\\n'
            /usr/bin/head -c 131072 /dev/zero >&2
            printf 'MC'
            printf 'W1 {"progress":1}\\n'
            printf '%s\\n' '\(Self.outcomeLine)'
            printf 'unrelated shutdown output\\n'
            """, in: directory, environment: ["REQUEST_PATH": requestPath])
        let input = job("/tmp/audio with spaces.wav")
        let result = try await client.run(input) { values.append($0) }
        XCTAssertEqual(result, Self.expectedOutcome)
        XCTAssertEqual(values.snapshot, [0.25, 1])
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: requestPath))) as? [String: Any])
        XCTAssertEqual(sent["audioPath"] as? String, input.audioPath)
        XCTAssertEqual(sent["captureSampleRate"] as? Double, 16_000)
        XCTAssertEqual(sent["language"] as? String, "es")
        XCTAssertEqual(sent["diarize"] as? Bool, false)
        XCTAssertEqual(sent["aliases"] as? [String: [String]], input.aliases)
    }

    func testTranscriptionErrorsRoundTripIncludingNoSpeech() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-errors")
        for expected in [TranscriptionError.emptyAudio, .emptyOutput, .noSpeech] {
            let client = client("""
                IFS= read -r request
                printf '%s\\n' 'MCW1 {"error":{"kind":"\(expected.rawValue)","message":"mensaje del hijo"}}'
                """, in: directory)
            do {
                _ = try await client.run(job()) { _ in }
                XCTFail("Expected \(expected)")
            } catch let error as TranscriptionError {
                XCTAssertEqual(error, expected)
            }
        }
        let cancelled = client("""
            IFS= read -r request
            printf '%s\\n' 'MCW1 {"error":{"kind":"cancelled","message":"cancelado"}}'
            """, in: directory)
        do {
            _ = try await cancelled.run(job()) { _ in }
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let failed = client("""
            IFS= read -r request
            printf '%s\\n' 'MCW1 {"error":{"kind":"other","message":"falló el modelo"}}'
            """, in: directory)
        do {
            _ = try await failed.run(job()) { _ in }
            XCTFail("Expected worker failure")
        } catch let error as TranscriptionWorkerError {
            XCTAssertEqual(error, .failed("falló el modelo"))
        }
    }

    func testExitWithoutResultIsRecoverableCrash() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-crash")
        let client = client("""
            IFS= read -r request
            printf 'no protocol result\\n'
            printf 'model failed\\n' >&2
            exit 7
            """, in: directory)
        do {
            _ = try await client.run(job()) { _ in }
            XCTFail("Expected crash")
        } catch let error as TranscriptionWorkerError {
            XCTAssertEqual(error, .crashed(7))
            XCTAssertTrue(error.localizedDescription.contains("se conserva el audio"))
        }
    }

    func testExitedWorkerWithInheritedPipesDoesNotBlockTheQueue() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-inherited-pipes")
        let client = client("""
            IFS= read -r request
            case "$request" in
              *first.wav*)
                /bin/sleep 30 &
                exit 7
                ;;
            esac
            printf '%s\\n' '\(Self.outcomeLine)'
            """, in: directory)
        let input = job("first.wav")
        let start = Date()
        let first = Task { try await client.run(input) { _ in } }
        let deadline = Task {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            first.cancel()
        }
        defer { deadline.cancel(); first.cancel() }
        do {
            _ = try await first.value
            XCTFail("Expected the worker's exit status")
        } catch let error as TranscriptionWorkerError {
            XCTAssertEqual(error, .crashed(7))
        } catch {
            XCTFail("Inherited pipes must not require caller cancellation: \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let next = try await client.run(job("next.wav")) { _ in }
        XCTAssertEqual(next, Self.expectedOutcome)
    }

    func testCancellationKillsChildIgnoringStdinEOFWithinGrace() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-cancel")
        let pidPath = directory + "/pid"
        let started = expectation(description: "child is ignoring EOF and termination")
        let client = client("""
            IFS= read -r request
            trap '' TERM
            printf '%s' "$$" > "$PID_PATH"
            printf '%s\\n' 'MCW1 {"progress":0.1}'
            exec /bin/sleep 30
            """, in: directory, environment: ["PID_PATH": pidPath], cancellationGrace: 0.1)
        let input = job()
        let task = Task { try await client.run(input) { _ in started.fulfill() } }
        defer { task.cancel() }
        await fulfillment(of: [started], timeout: 3)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidPath, encoding: .utf8)))
        let start = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(kill(pid, 0), -1, "the child must be reaped, not left to consume model memory")
        XCTAssertEqual(errno, ESRCH)
    }

    func testChildEnvironmentRemovesEveryAppModeTrigger() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-environment")
        let environmentPath = directory + "/environment"
        let modes = ["MEETCAPTURE_REAL_CHECK", "MEETCAPTURE_PREFETCH_MODELS", "MEETCAPTURE_UI_TEST",
                     "MEETCAPTURE_LAUNCH_PROBE", "MEETCAPTURE_SNAPSHOT_PATH", "MEETCAPTURE_CHECK_INPUT",
                     "MEETCAPTURE_CHECK_LANGUAGE", "MEETCAPTURE_CHECK_FUTURE_MODE"]
        var environment = Dictionary(uniqueKeysWithValues: modes.map { ($0, "trigger") })
        environment["MEETCAPTURE_TRANSCRIPTION_WORKER"] = "0"
        environment["ENVIRONMENT_PATH"] = environmentPath
        environment["WORKER_SENTINEL"] = "preserved"
        let client = client("""
            IFS= read -r request
            /usr/bin/env > "$ENVIRONMENT_PATH"
            printf '%s\\n' '\(Self.outcomeLine)'
            """, in: directory, environment: environment)
        _ = try await client.run(job()) { _ in }
        let received = Dictionary(uniqueKeysWithValues: try String(contentsOfFile: environmentPath, encoding: .utf8)
            .split(separator: "\n").map { line -> (String, String) in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                return (String(parts[0]), parts.count == 2 ? String(parts[1]) : "")
            })
        for mode in modes { XCTAssertNil(received[mode], "mode leaked: \(mode)") }
        XCTAssertEqual(received["MEETCAPTURE_TRANSCRIPTION_WORKER"], "1")
        XCTAssertEqual(received["WORKER_SENTINEL"], "preserved")
    }

    func testFIFOAndCancelledQueuedWaiterNeverLaunches() async throws {
        let directory = TestSupport.makeTempDir(self, "worker-fifo")
        let log = directory + "/launches.jsonl"
        let release = directory + "/release"
        let firstStarted = expectation(description: "first worker started")
        let secondQueued = expectation(description: "second call entered client actor")
        let thirdQueued = expectation(description: "third call entered client actor")
        let fourthQueued = expectation(description: "fourth call entered client actor")
        let client = client("""
            IFS= read -r request
            printf '%s\\n' "$request" >> "$LAUNCH_LOG"
            case "$request" in
              *first.wav*)
                printf '%s\\n' 'MCW1 {"progress":0.1}'
                while [ ! -f "$RELEASE_PATH" ]; do /bin/sleep 0.01; done
                ;;
            esac
            printf '%s\\n' '\(Self.outcomeLine)'
            """, in: directory, environment: ["LAUNCH_LOG": log, "RELEASE_PATH": release])
        let firstInput = job("first.wav"), secondInput = job("cancelled.wav")
        let thirdInput = job("third.wav"), fourthInput = job("fourth.wav")
        let first = Task { try await client.run(firstInput) { _ in firstStarted.fulfill() } }
        defer { first.cancel() }
        await fulfillment(of: [firstStarted], timeout: 3)
        let second = Task { try await Self.queuedRun(secondInput, client: client, entered: secondQueued) }
        defer { second.cancel() }
        await fulfillment(of: [secondQueued], timeout: 3)
        let third = Task { try await Self.queuedRun(thirdInput, client: client, entered: thirdQueued) }
        defer { third.cancel() }
        await fulfillment(of: [thirdQueued], timeout: 3)
        second.cancel()
        do {
            _ = try await second.value
            XCTFail("Expected cancellation before the first worker is released")
        } catch is CancellationError {}
        let fourth = Task { try await Self.queuedRun(fourthInput, client: client, entered: fourthQueued) }
        defer { fourth.cancel() }
        await fulfillment(of: [fourthQueued], timeout: 3)
        XCTAssertEqual(try launchedAudioPaths(log), ["first.wav"], "workers must not overlap")
        TestSupport.write("", to: release)
        let firstResult = try await first.value
        let thirdResult = try await third.value
        let fourthResult = try await fourth.value
        XCTAssertEqual(firstResult, Self.expectedOutcome)
        XCTAssertEqual(thirdResult, Self.expectedOutcome)
        XCTAssertEqual(fourthResult, Self.expectedOutcome)
        XCTAssertEqual(try launchedAudioPaths(log), ["first.wav", "third.wav", "fourth.wav"])
    }

    // Enter the actor before acknowledging each call, so request ordering does
    // not depend on sleeps or the scheduler's ordering of unrelated Tasks.
    private static func queuedRun(_ job: TranscriptionJob, client: isolated TranscriptionWorkerClient,
                                  entered: XCTestExpectation) async throws -> TranscriptionJob.Outcome {
        entered.fulfill()
        return try await client.run(job) { _ in }
    }

    private func launchedAudioPaths(_ path: String) throws -> [String] {
        try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").map { line in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["audioPath"] as? String)
        }
    }
}

private final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    var snapshot: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

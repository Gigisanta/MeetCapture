import Foundation
import AVFoundation
import XCTest
@testable import MeetCaptureCore

private final class BlockingCaptureEngine: CaptureEngineBackend, @unchecked Sendable {
    let blockStart: Bool
    let queue = DispatchQueue(label: "meetcapture.tests.blocking-capture")
    let startEntered = DispatchSemaphore(value: 0)
    let allowStart = DispatchSemaphore(value: 0)
    let stopEntered = DispatchSemaphore(value: 0)
    let cleanupCompleted = DispatchSemaphore(value: 0)

    var onRebuildFailure: (@Sendable (String) -> Void)?
    var acceptedCallbacks = 0
    var droppedCallbacks = 0
    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _stopError: Error?
    private var liveSink: (@Sendable ([Int16]) -> Void)?
    private var pendingAudioPath: String?
    private var pendingSidecarPath: String?

    var startCount: Int { withLock { _startCount } }
    var stopCount: Int { withLock { _stopCount } }
    var stopError: Error? {
        get { withLock { _stopError } }
        set { withLock { _stopError = newValue } }
    }

    init(blockStart: Bool = true) {
        self.blockStart = blockStart
    }

    func start(outputPath: String, configuration: TapConfiguration) throws {
        withLock { _startCount += 1 }
        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        if FileManager.default.fileExists(atPath: outputPath) {
            throw PCMFileWriter.WriterError.alreadyExists(outputPath)
        }
        if FileManager.default.fileExists(atPath: sidecarPath) {
            throw PCMFileWriter.WriterError.alreadyExists(sidecarPath)
        }
        guard FileManager.default.createFile(atPath: outputPath, contents: Data([1, 2, 3])) else {
            throw PCMFileWriter.WriterError.cannotCreate(outputPath)
        }
        do {
            try AudioFormatSidecar.capture(tapStrategy: "fixture", tapInfo: "fixture")
                .write(forAudio: outputPath)
        } catch {
            try? FileManager.default.removeItem(atPath: outputPath)
            try? FileManager.default.removeItem(atPath: sidecarPath)
            throw error
        }
        withLock {
            pendingAudioPath = outputPath
            pendingSidecarPath = sidecarPath
        }
        startEntered.signal()
        if blockStart {
            _ = allowStart.wait(timeout: .now() + 2)
        }
    }

    func commitStart() {
        withLock {
            pendingAudioPath = nil
            pendingSidecarPath = nil
        }
    }

    func discardStart() {
        let (audioPath, sidecarPath) = withLock { () -> (String?, String?) in
            let paths = (pendingAudioPath, pendingSidecarPath)
            pendingAudioPath = nil
            pendingSidecarPath = nil
            return paths
        }
        if let audioPath { try? FileManager.default.removeItem(atPath: audioPath) }
        if let sidecarPath { try? FileManager.default.removeItem(atPath: sidecarPath) }
        cleanupCompleted.signal()
    }

    func stop() throws {
        let error = withLock { () -> Error? in
            _stopCount += 1
            return _stopError
        }
        stopEntered.signal()
        if let error { throw error }
    }

    func getLiveSink() -> (@Sendable ([Int16]) -> Void)? { liveSink }

    func setLiveSink(_ sink: (@Sendable ([Int16]) -> Void)?) {
        liveSink = sink
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class CaptureRegressionTests: XCTestCase {
    func testClosedFileHandleWriteFailurePreservesBoundedPCMBuffer() throws {
        let path = TestSupport.makeTempDir(self, "capture-closed-writer") + "/capture.pcm"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        let writer = PCMFileWriter(path: path, fileHandle: handle)

        try writer.write([Int16](repeating: 7, count: PCMFileWriter.bufferSize / 2))
        let partialData = try Data(contentsOf: URL(fileURLWithPath: path))
        try handle.close()

        XCTAssertThrowsError(try writer.write(
            [Int16](repeating: 9, count: PCMFileWriter.bufferSize / 2))) { error in
            XCTAssertTrue(error.localizedDescription.contains(path))
        }

        XCTAssertEqual(writer.bytesWritten, PCMFileWriter.bufferSize)
        XCTAssertEqual(writer.bufferedByteCount, PCMFileWriter.bufferSize,
                       "a failed flush must keep its PCM for diagnostics or retry")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), partialData)
        XCTAssertThrowsError(try writer.write([Int16](repeating: 1, count: PCMFileWriter.bufferSize)))
        XCTAssertEqual(writer.bufferedByteCount, PCMFileWriter.bufferSize,
                       "further capture input must not grow memory after a write failure")
    }

    func testClosedFileHandleFlushFailureKeepsBufferedPCMAndReportsError() throws {
        let path = TestSupport.makeTempDir(self, "capture-closed-flush") + "/capture.pcm"
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        let writer = PCMFileWriter(path: path, fileHandle: handle)
        let samples = [Int16](repeating: 3, count: 128)
        try writer.write(samples)
        try handle.close()

        XCTAssertThrowsError(try writer.flush()) { error in
            XCTAssertTrue(error.localizedDescription.contains(path))
        }

        XCTAssertEqual(writer.bufferedByteCount, samples.count * MemoryLayout<Int16>.size)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertThrowsError(try writer.close())
        XCTAssertEqual(writer.bufferedByteCount, samples.count * MemoryLayout<Int16>.size)
    }

    func testUpsamplingAFullRingSlotDoesNotTruncateOutput() throws {
        let inputRate = 8_000.0
        let inputFrames = AudioRingBuffer.maxFrames
        let resampler = try XCTUnwrap(
            AudioResampler(inputRate: inputRate, outputRate: 16_000, channels: 1))
        let samples = [Float](repeating: 0.25, count: inputFrames)

        var output = samples.withUnsafeBufferPointer { buffer in
            resampler.resample(interleaved: buffer.baseAddress!, frameCount: inputFrames)
        }
        output += resampler.flush()

        XCTAssertLessThan(abs(output.count - inputFrames * 2), 100)
        XCTAssertGreaterThan(output.map { abs(Int($0)) }.max() ?? 0, 5_000)
    }

    // The Core Audio IO callback is private and hardware-backed; this fixture
    // covers the declared mic-only layout, while real sample-level capture
    // remains a hardware/QA check.
    func testMicOnlySidecarDescribesDuplicatedMicrophoneChannels() {
        let sidecar = AudioFormatSidecar.capture(tapStrategy: "mic-only", tapInfo: "mic-only")

        XCTAssertEqual(sidecar.channels, 2)
        XCTAssertEqual(sidecar.layout, "L=mic,R=mic")
        XCTAssertEqual(AudioFormatSidecar.capture(tapStrategy: "global", tapInfo: "global").layout,
                       "L=system,R=mic")
    }

    func testStopDuringStartDiscardsOnlyCancelledArtifacts() async {
        let engine = BlockingCaptureEngine()
        let stopWaitingForStart = DispatchSemaphore(value: 0)
        let service = await AudioCaptureService(testEngine: engine, onStopWaitingForStart: {
            stopWaitingForStart.signal()
        })
        let outputPath = TestSupport.makeTempDir(self, "capture-lifecycle") + "/capture.pcm"
        let configuration = TapConfiguration(micOnly: true, inputDeviceUID: nil)

        let startTask: Task<String, Never> = Task { @MainActor in
            do {
                try await service.startCapture(outputPath: outputPath, configuration: configuration)
                return "started"
            } catch let error as CaptureError {
                if case .startCancelled = error { return "cancelled" }
                return "capture-error"
            } catch {
                return "other-error"
            }
        }

        XCTAssertEqual(engine.startEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: AudioFormatSidecar.path(forAudio: outputPath)))
        let stopTask = Task { @MainActor in try? await service.stopCapture() }
        XCTAssertEqual(stopWaitingForStart.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(engine.stopEntered.wait(timeout: .now()), .timedOut)

        engine.allowStart.signal()
        let startResult = await startTask.value
        XCTAssertEqual(startResult, "cancelled")
        await stopTask.value
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AudioFormatSidecar.path(forAudio: outputPath)))
        let finalState = await service.state
        XCTAssertEqual(finalState, .idle)
    }

    func testBlockedStartTimesOutRejectsRetryAndCleansLateOnEngineQueue() async {
        let engine = BlockingCaptureEngine()
        let service = await AudioCaptureService(
            testEngine: engine,
            startTimeoutNanoseconds: 50_000_000)
        let outputPath = TestSupport.makeTempDir(self, "capture-start-timeout") + "/capture.pcm"
        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        let configuration = TapConfiguration(micOnly: true, inputDeviceUID: nil)

        let startTask: Task<CaptureStartError?, Never> = Task { @MainActor in
            do {
                try await service.startCapture(outputPath: outputPath, configuration: configuration)
                return nil
            } catch let error as CaptureStartError {
                return error
            } catch {
                return nil
            }
        }

        XCTAssertEqual(engine.startEntered.wait(timeout: .now() + 2), .success)
        let startError = await startTask.value
        XCTAssertEqual(startError, .timedOut)
        XCTAssertTrue(startError?.localizedDescription.contains("reiniciá") == true)
        let stateAfterTimeout = await service.state
        XCTAssertEqual(stateAfterTimeout, .idle)
        let publishedPathAfterTimeout = await service.currentOutputPath
        XCTAssertNil(publishedPathAfterTimeout, "a timed-out start must not publish its partial capture")
        XCTAssertEqual(engine.stopCount, 0, "timeout must not stop a HAL call that is still blocked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))

        let retryPath = TestSupport.makeTempDir(self, "capture-start-timeout-retry") + "/capture.pcm"
        let retrySidecarPath = AudioFormatSidecar.path(forAudio: retryPath)
        do {
            try await service.startCapture(outputPath: retryPath, configuration: configuration)
            XCTFail("a timed-out engine must reject a second start")
        } catch let error as CaptureStartError {
            XCTAssertEqual(error, .engineBlocked)
        } catch {
            XCTFail("unexpected retry error: \(error)")
        }
        XCTAssertEqual(engine.startCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retryPath), "a rejected retry must not write PCM")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retrySidecarPath), "a rejected retry must not write a sidecar")

        engine.allowStart.signal()
        XCTAssertEqual(engine.cleanupCompleted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))
        let finalState = await service.state
        XCTAssertEqual(finalState, .idle)
    }

    func testStopWaitingForBlockedStartReturnsAfterTimeoutBeforeLateCleanup() async {
        let engine = BlockingCaptureEngine()
        let stopWaitingForStart = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let service = await AudioCaptureService(
            testEngine: engine,
            onStopWaitingForStart: { stopWaitingForStart.signal() },
            startTimeoutNanoseconds: 50_000_000)
        let outputPath = TestSupport.makeTempDir(self, "capture-stop-timeout") + "/capture.pcm"
        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        let configuration = TapConfiguration(micOnly: true, inputDeviceUID: nil)

        let startTask: Task<CaptureStartError?, Never> = Task { @MainActor in
            do {
                try await service.startCapture(outputPath: outputPath, configuration: configuration)
                return nil
            } catch let error as CaptureStartError {
                return error
            } catch {
                return nil
            }
        }

        XCTAssertEqual(engine.startEntered.wait(timeout: .now() + 2), .success)
        let stopTask = Task { @MainActor in
            try? await service.stopCapture()
            stopReturned.signal()
        }
        XCTAssertEqual(stopWaitingForStart.wait(timeout: .now() + 2), .success)

        let waitStartedAt = Date()
        XCTAssertEqual(stopReturned.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 1.0)
        XCTAssertEqual(engine.stopCount, 0, "stopCapture must not stop a HAL call still blocked in start")
        XCTAssertEqual(engine.stopEntered.wait(timeout: .now()), .timedOut)

        let startError = await startTask.value
        XCTAssertEqual(startError, .timedOut)
        engine.allowStart.signal()
        XCTAssertEqual(engine.cleanupCompleted.wait(timeout: .now() + 2), .success)
        await stopTask.value
        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarPath))
    }

    func testCompletedStartAndNormalStopKeepsCaptureArtifacts() async throws {
        let engine = BlockingCaptureEngine(blockStart: false)
        let service = await AudioCaptureService(testEngine: engine)
        let outputPath = TestSupport.makeTempDir(self, "capture-valid") + "/capture.pcm"
        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        let configuration = TapConfiguration(micOnly: true, inputDeviceUID: nil)

        try await service.startCapture(outputPath: outputPath, configuration: configuration)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))

        try await service.stopCapture()

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))
    }

    func testStopWriteFailurePropagatesAndKeepsPartialCaptureArtifacts() async throws {
        let engine = BlockingCaptureEngine(blockStart: false)
        let service = await AudioCaptureService(testEngine: engine)
        let outputPath = TestSupport.makeTempDir(self, "capture-write-failure") + "/capture.pcm"
        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        let writeError = PCMFileWriter.WriterError.writeFailed(path: outputPath, reason: "fixture failure")
        engine.stopError = writeError

        try await service.startCapture(
            outputPath: outputPath,
            configuration: TapConfiguration(micOnly: true, inputDeviceUID: nil))
        do {
            try await service.stopCapture()
            XCTFail("a failed final write must fail stopCapture")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(outputPath))
        }

        let stateAfterFailure = await service.state
        let lastError = await service.lastError
        let retainedOutputPath = await service.currentOutputPath
        XCTAssertEqual(stateAfterFailure, .error(writeError.localizedDescription))
        XCTAssertEqual(lastError, writeError.localizedDescription)
        XCTAssertEqual(retainedOutputPath, outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))
    }

    func testRealServiceRejectsPreexistingCaptureArtifactsWithoutTouchingThem() async {
        let service = await AudioCaptureService()
        let outputPath = TestSupport.makeTempDir(self, "capture-preexisting") + "/capture.pcm"
        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        let originalAudio = Data([9, 8, 7, 6])
        let originalSidecar = AudioFormatSidecar.capture(tapStrategy: "preexisting", tapInfo: "fixture")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputPath, contents: originalAudio))
        XCTAssertNoThrow(try originalSidecar.write(forAudio: outputPath))

        do {
            try await service.startCapture(
                outputPath: outputPath,
                configuration: TapConfiguration(micOnly: true, inputDeviceUID: nil))
            XCTFail("preexisting capture artifacts must reject start")
        } catch {
            // Expected: the service rejects both paths before touching Core Audio.
        }

        XCTAssertEqual(FileManager.default.contents(atPath: outputPath), originalAudio)
        XCTAssertEqual(AudioFormatSidecar.read(forAudio: outputPath), originalSidecar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarPath))
        let finalState = await service.state
        XCTAssertEqual(finalState, .idle)

        let sidecarOnlyAudioPath = TestSupport.makeTempDir(self, "capture-preexisting-sidecar") + "/capture.pcm"
        let sidecarOnlyPath = AudioFormatSidecar.path(forAudio: sidecarOnlyAudioPath)
        let sidecarOnly = AudioFormatSidecar.capture(tapStrategy: "preexisting-sidecar", tapInfo: "fixture")
        XCTAssertNoThrow(try sidecarOnly.write(forAudio: sidecarOnlyAudioPath))

        let sidecarOnlyService = await AudioCaptureService()
        do {
            try await sidecarOnlyService.startCapture(
                outputPath: sidecarOnlyAudioPath,
                configuration: TapConfiguration(micOnly: true, inputDeviceUID: nil))
            XCTFail("a preexisting sidecar must reject start")
        } catch {
            // Expected: the service must not create a PCM beside it.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarOnlyAudioPath))
        XCTAssertEqual(AudioFormatSidecar.read(forAudio: sidecarOnlyAudioPath), sidecarOnly)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarOnlyPath))
    }
}

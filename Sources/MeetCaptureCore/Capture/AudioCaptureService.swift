// AudioCaptureService.swift
// Records the meeting: system audio (Core Audio process tap) + microphone
// → 16 kHz Int16 stereo interleaved raw PCM (L=system, R=mic) plus a
// `.format.json` sidecar.
//
// Threads:
//   real-time IOProc  → mixes each track to mono into a preallocated ring slot
//   consumer Thread   → resample, interleave, buffered file write
//   rebuildQueue      → Core Audio graph build/teardown, device-change rebuilds
//   main actor        → published state

import AVFoundation
import AppKit
import CoreAudio
import Foundation
import os

enum CaptureState: Equatable, Sendable {
    case idle
    case recording
    case error(String)

    var isRecording: Bool { self == .recording }
}

enum CaptureStartError: LocalizedError, Equatable, Sendable {
    case timedOut
    case engineBlocked

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "La inicialización de audio no respondió a tiempo. La grabación no comenzó; reiniciá la app antes de volver a intentar."
        case .engineBlocked:
            return "La captura de audio quedó bloqueada durante un inicio anterior. Reiniciá la app antes de volver a intentar."
        }
    }
}

private final class CaptureStartAttempt: @unchecked Sendable {
    private enum Phase {
        case waiting
        case timedOut
        case completed
    }

    private let lock = NSLock()
    private var phase: Phase = .waiting
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingResult: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        switch phase {
        case .waiting:
            self.continuation = continuation
            lock.unlock()
        case .timedOut:
            lock.unlock()
            continuation.resume(throwing: CaptureStartError.timedOut)
        case .completed:
            let result = pendingResult
            pendingResult = nil
            lock.unlock()
            if let result { Self.resume(continuation, with: result) }
        }
    }

    @discardableResult
    func timeout() -> Bool {
        lock.lock()
        guard phase == .waiting else {
            lock.unlock()
            return false
        }
        phase = .timedOut
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: CaptureStartError.timedOut)
        return true
    }

    /// Returns true when the caller owns the successful/error result. A false
    /// result means the timeout already won and the engine queue must clean up.
    @discardableResult
    func resolve(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        guard phase == .waiting else {
            lock.unlock()
            return false
        }
        phase = .completed
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        lock.unlock()
        if let continuation { Self.resume(continuation, with: result) }
        return true
    }

    private static func resume(_ continuation: CheckedContinuation<Void, Error>,
                               with result: Result<Void, Error>) {
        switch result {
        case .success:
            continuation.resume()
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

protocol CaptureEngineBackend: AnyObject, Sendable {
    var queue: DispatchQueue { get }
    var onRebuildFailure: (@Sendable (String) -> Void)? { get set }
    var acceptedCallbacks: Int { get }
    var droppedCallbacks: Int { get }

    func start(outputPath: String, configuration: TapConfiguration) throws
    func commitStart()
    func discardStart()
    func stop() throws
}

@MainActor
final class AudioCaptureService: ObservableObject {
    nonisolated static let targetSampleRate: Double = 16_000
    /// Stack for the capture and ASR worker threads (same as the main thread).
    nonisolated static let workerStackSize = 8 << 20
    nonisolated fileprivate static let headroom: Float = 0.75
    nonisolated static let defaultStartTimeoutNanoseconds: UInt64 = 15_000_000_000

    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var lastError: String?
    private(set) var currentOutputPath: String?

    var currentSampleRate: Double { Self.targetSampleRate }
    var droppedCallbacks: Int { engine.droppedCallbacks }

    private let engine: any CaptureEngineBackend
    private let logger = AppInfo.logger("AudioCapture")
    private var startInFlight = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopRequested = false
    private var stopInFlight = false
    private var engineBlocked = false
    private let onStopWaitingForStart: (() -> Void)?
    private let startTimeoutNanoseconds: UInt64

    init() {
        engine = CaptureEngine()
        onStopWaitingForStart = nil
        startTimeoutNanoseconds = Self.defaultStartTimeoutNanoseconds
    }

    /// Test seam for the lifecycle contract. Production always uses the real
    /// Core Audio engine through `init()`.
    init(testEngine: any CaptureEngineBackend, onStopWaitingForStart: (() -> Void)? = nil,
         startTimeoutNanoseconds: UInt64 = AudioCaptureService.defaultStartTimeoutNanoseconds) {
        engine = testEngine
        self.onStopWaitingForStart = onStopWaitingForStart
        self.startTimeoutNanoseconds = startTimeoutNanoseconds
    }

    // MARK: - Permission

    func checkPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermission(completion: @escaping @Sendable (Bool) -> Void = { _ in }) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// After a denial macOS never shows the prompt again; only Settings can grant it.
    func canRequestPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Settings › Privacy › Screen & System Audio Recording, where the
    /// process tap is granted. There is no public preflight for it: a denied
    /// tap just delivers silence.
    func openSystemAudioSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Lifecycle

    func startCapture(outputPath: String, configuration: TapConfiguration) async throws {
        guard !engineBlocked else {
            throw CaptureStartError.engineBlocked
        }
        guard state != .recording, !startInFlight, !stopInFlight else {
            throw CaptureError.alreadyRecording
        }
        lastError = nil
        startInFlight = true
        stopRequested = false
        engine.onRebuildFailure = { [weak self] message in
            guard let self else { return }
            Task { @MainActor in self.lastError = message }
        }
        let engine = self.engine
        let attempt = CaptureStartAttempt()
        let timeoutTask = Task { [attempt, timeout = startTimeoutNanoseconds] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            _ = attempt.timeout()
        }
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                attempt.install(cont)
                engine.queue.async {
                    do {
                        try engine.start(outputPath: outputPath, configuration: configuration)
                        if !attempt.resolve(.success(())) {
                            do {
                                try engine.stop()
                                engine.discardStart()
                            } catch {
                                engine.commitStart()
                                engine.onRebuildFailure?("No se pudo finalizar la captura: \(error.localizedDescription)")
                            }
                        }
                    } catch {
                        let startError = error
                        do {
                            try engine.stop()
                        } catch {
                            engine.commitStart()
                            if !attempt.resolve(.failure(error)) {
                                engine.onRebuildFailure?("No se pudo finalizar la captura: \(error.localizedDescription)")
                            }
                            return
                        }
                        if !attempt.resolve(.failure(startError)) {
                            engine.discardStart()
                        }
                    }
                }
            }
        } catch {
            timeoutTask.cancel()
            if let error = error as? CaptureStartError, error == .timedOut {
                engineBlocked = true
                currentOutputPath = nil
                state = .idle
                finishStart()
                throw error
            }
            finishStart()
            throw error
        }
        timeoutTask.cancel()

        if stopRequested || Task.isCancelled {
            do {
                try await stopEngine()
            } catch {
                engine.commitStart()
                currentOutputPath = outputPath
                let message = error.localizedDescription
                lastError = message
                state = .error(message)
                finishStart()
                throw error
            }
            engine.discardStart()
            currentOutputPath = nil
            state = .idle
            finishStart()
            throw CaptureError.startCancelled
        }

        currentOutputPath = outputPath
        state = .recording
        engine.commitStart()
        finishStart()
        logger.info("captura iniciada → \(outputPath, privacy: .public)")
    }

    /// Stops the graph, drains the ring, flushes the file, then reports idle.
    func stopCapture() async throws {
        if startInFlight {
            stopRequested = true
            onStopWaitingForStart?()
            await waitForStartToFinish()
        }

        guard state == .recording, !stopInFlight else { return }
        stopInFlight = true
        let engine = self.engine
        defer { stopInFlight = false }
        do {
            try await stopEngine()
        } catch {
            let message = error.localizedDescription
            lastError = message
            state = .error(message)
            throw error
        }
        state = .idle
        currentOutputPath = nil
        logger.info("captura detenida (\(engine.acceptedCallbacks) callbacks, \(engine.droppedCallbacks) descartados)")
    }

    private func stopEngine() async throws {
        let engine = self.engine
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            engine.queue.async {
                do {
                    try engine.stop()
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func waitForStartToFinish() async {
        guard startInFlight else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            startWaiters.append(cont)
        }
    }

    private func finishStart() {
        startInFlight = false
        stopRequested = false
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: true)
        waiters.forEach { $0.resume() }
    }
}

/// Everything below the main actor: owned by `queue` except the ring
/// (IOProc + consumer).
final class CaptureEngine: CaptureEngineBackend, @unchecked Sendable {
    private struct PendingStartArtifacts: Sendable {
        let audioPath: String
        let sidecarPath: String
    }

    let queue = DispatchQueue(label: AppInfo.bundleID + ".capture", qos: .userInitiated)
    let ring = AudioRingBuffer()
    var onRebuildFailure: (@Sendable (String) -> Void)?

    var acceptedCallbacks: Int { ring.acceptedCallbacks }
    var droppedCallbacks: Int { ring.droppedCallbacks }

    private var tap: CoreAudioTap?
    private var configuration: TapConfiguration?
    private var writer: PCMFileWriter?
    private var consumer: Consumer?
    private var rebuildError: Error?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let logger = AppInfo.logger("CaptureEngine")
    private let pendingStart = OSAllocatedUnfairLock<PendingStartArtifacts?>(initialState: nil)

    // MARK: - queue-confined

    func start(outputPath: String, configuration: TapConfiguration) throws {
        let signpost = Signposts.capture.beginInterval("start")
        defer { Signposts.capture.endInterval("start", signpost) }
        rebuildError = nil

        let sidecarPath = AudioFormatSidecar.path(forAudio: outputPath)
        if FileManager.default.fileExists(atPath: outputPath) {
            throw PCMFileWriter.WriterError.alreadyExists(outputPath)
        }
        if FileManager.default.fileExists(atPath: sidecarPath) {
            throw PCMFileWriter.WriterError.alreadyExists(sidecarPath)
        }
        let writer = try PCMFileWriter(path: outputPath)
        self.writer = writer
        self.configuration = configuration
        pendingStart.withLock {
            $0 = PendingStartArtifacts(audioPath: outputPath, sidecarPath: sidecarPath)
        }
        do {
            let tap = try buildTap(configuration)
            let sidecar = AudioFormatSidecar.capture(tapStrategy: tap.strategy, tapInfo: tap.tapInfo)
            try sidecar.write(forAudio: outputPath)

            let consumer = try Consumer(ring: ring, writer: writer, inputRate: tap.sampleRate,
                                        onWriteFailure: onRebuildFailure)
            self.consumer = consumer
            consumer.start()
            try startIOProc(tap, micOnly: configuration.micOnly)
            installDeviceListeners()
        } catch {
            do {
                try stop()
            } catch {
                commitStart()
                throw error
            }
            discardStart()
            throw error
        }
    }

    func commitStart() {
        pendingStart.withLock { $0 = nil }
    }

    func discardStart() {
        let artifacts = pendingStart.withLock { pending -> PendingStartArtifacts? in
            let artifacts = pending
            pending = nil
            return artifacts
        }
        guard let artifacts else { return }
        try? FileManager.default.removeItem(atPath: artifacts.audioPath)
        try? FileManager.default.removeItem(atPath: artifacts.sidecarPath)
    }

    func stop() throws {
        removeDeviceListeners()
        tap?.stop()
        tap = nil
        var stopError = rebuildError
        rebuildError = nil
        do {
            try consumer?.finish()
        } catch {
            stopError = error
        }
        consumer = nil
        do {
            try writer?.close()
        } catch {
            if stopError == nil { stopError = error }
        }
        writer = nil
        configuration = nil
        if let stopError { throw stopError }
    }

    private func buildTap(_ configuration: TapConfiguration) throws -> CoreAudioTap {
        let tap = try CoreAudioTap(configuration: configuration)
        self.tap = tap
        return tap
    }

    /// The real-time callback: mix each buffer to mono into a ring slot.
    /// `micOnly` is captured as a constant; nothing here allocates.
    private func startIOProc(_ tap: CoreAudioTap, micOnly: Bool) throws {
        let ring = self.ring
        let headroom = AudioCaptureService.headroom
        let maxFrames = AudioRingBuffer.maxFrames
        try tap.start { _, inInputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard abl.count > 0 else { return }
            let systemIndex = tap.tapBufferIndex ?? 0
            guard systemIndex < abl.count else { return }
            let first = abl[systemIndex]
            let sysCh = max(1, Int(first.mNumberChannels))
            let sysFrames = Int(first.mDataByteSize) / (4 * sysCh)
            guard sysFrames > 0, sysFrames <= maxFrames else { return }

            ring.write { slot in
                slot.frames = sysFrames
                if micOnly {
                    Self.mixdown(first, channels: sysCh, frames: sysFrames, headroom: headroom, into: slot.mic)
                    // Mic-only leaves L silent; ChannelReader then keeps R alone.
                    slot.system.update(repeating: 0, count: sysFrames)
                } else {
                    Self.mixdown(first, channels: sysCh, frames: sysFrames, headroom: headroom, into: slot.system)
                    if let micIndex = tap.micBufferIndex, micIndex < abl.count, abl[micIndex].mDataByteSize > 0 {
                        let mic = abl[micIndex]
                        let micCh = max(1, Int(mic.mNumberChannels))
                        let micFrames = min(sysFrames, Int(mic.mDataByteSize) / (4 * micCh))
                        Self.mixdown(mic, channels: micCh, frames: micFrames, headroom: headroom, into: slot.mic)
                        if micFrames < sysFrames {
                            (slot.mic + micFrames).update(repeating: 0, count: sysFrames - micFrames)
                        }
                    } else {
                        slot.mic.update(repeating: 0, count: sysFrames)
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func mixdown(_ buffer: AudioBuffer, channels: Int, frames: Int, headroom: Float,
                                into out: UnsafeMutablePointer<Float>) {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
            out.update(repeating: 0, count: frames); return
        }
        let ch = min(channels, 2)
        let scale = headroom / Float(ch)
        for f in 0..<frames {
            var acc: Float = 0
            for c in 0..<ch { acc += data[f * channels + c] }
            out[f] = acc * scale
        }
    }

    // MARK: - Device changes

    private func installDeviceListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.rebuild() }
        listenerBlock = block
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
    }

    private func removeDeviceListeners() {
        guard let block = listenerBlock else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, queue, block)
        }
        listenerBlock = nil
    }

    /// Runs on `queue` (listener dispatch queue). Rebuilds the graph while recording.
    private func rebuild() {
        guard let configuration, let writer, tap != nil else { return }
        logger.warning("dispositivo de audio cambiado; reconstruyendo el tap")
        Signposts.capture.emitEvent("rebuild")
        tap?.stop()
        tap = nil
        do {
            let tap = try buildTap(configuration)
            if let consumer, consumer.inputRate != tap.sampleRate {
                // A finished consumer cannot be waited on twice: its done
                // semaphore has already been consumed, even if flush throws.
                self.consumer = nil
                try consumer.finish()
                let fresh = try Consumer(ring: ring, writer: writer, inputRate: tap.sampleRate,
                                         onWriteFailure: onRebuildFailure)
                self.consumer = fresh
                fresh.start()
            }
            try startIOProc(tap, micOnly: configuration.micOnly)
        } catch {
            tap?.stop()
            tap = nil
            rebuildError = error
            logger.error("rebuild falló: \(error.localizedDescription, privacy: .public)")
            onRebuildFailure?("El dispositivo de audio cambió y la captura no pudo reiniciarse.")
        }
    }

    /// QA runtime diagnostic at the real ring → consumer → PCM boundary. It
    /// intentionally bypasses IOProc/devices, so it cannot establish live-capture
    /// callback delivery or the audibility of any measured converter tail.
    static func diagnoseConsumer(outputDirectory: URL) throws -> [String: Any] {
        let environment = ProcessInfo.processInfo.environment
        func refused(_ message: String) -> NSError {
            NSError(domain: "MeetCapture.ConsumerDiagnostic", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard QATrace.isEnabled, environment["MEETCAPTURE_REAL_CHECK"] == "resampler",
              let output = environment["MEETCAPTURE_TEST_OUTPUT_DIR"],
              !output.isEmpty, (output as NSString).isAbsolutePath else {
            throw refused("consumer diagnosis requires QA resampler mode, tracing and isolated output")
        }
        let root = URL(fileURLWithPath: output, isDirectory: true).resolvingSymlinksInPath()
        guard outputDirectory.resolvingSymlinksInPath().path == root.path else {
            throw refused("consumer diagnosis output must be the configured isolated QA root")
        }
        let traces = root.appendingPathComponent("qa-traces", isDirectory: true)
        guard traces.resolvingSymlinksInPath().path == traces.path else {
            throw refused("qa-traces must not redirect outside the isolated output")
        }
        let directory = traces.appendingPathComponent("consumer-diagnostic-" + UUID().uuidString,
                                                     isDirectory: true)
        try AppPaths.ensurePrivateDirectory(directory.path)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw refused("consumer diagnosis output changed while creating it")
        }
        var measurements: [[String: Any]] = []
        var errors: [String] = []
        for inputRate in [16_000.0, 44_100.0, 48_000.0] {
            do {
                let measurement = try diagnoseConsumerFixture(inputRate: inputRate, directory: directory)
                measurements.append(measurement)
                let caseErrors = measurement["errors"] as? [String] ?? []
                errors.append(contentsOf: caseErrors.map { "\(Int(inputRate)) Hz: \($0)" })
            } catch {
                let message = error.localizedDescription
                measurements.append(["inputSampleRate": inputRate, "status": "failed", "errors": [message]])
                errors.append("\(Int(inputRate)) Hz: \(message)")
            }
        }
        return [
            "status": errors.isEmpty ? "passed" : "failed", "mode": "resampler",
            "acceptance_status": "not_evaluated",
            "evidence_scope": "synthetic ring-to-PCM through actual Consumer; not IOProc, devices or live capture",
            "fixtureDirectory": directory.path, "measurements": measurements, "errors": errors,
        ]
    }

    /// Fixture channels have a known 2:1 amplitude ratio. Threshold crossings
    /// are amplitude-dependent; compare the scaled waveform, not its first
    /// sample above an arbitrary level. Equal costs prefer zero displacement.
    static func diagnosticWaveformLag(system: [Int16], mic: [Int16], maxLag: Int = 8)
        -> (frames: Int, meanSquaredResidual: Double)? {
        guard maxLag >= 0, system.count == mic.count, system.count > 2 * maxLag else { return nil }
        let range = maxLag..<(system.count - maxLag)
        var bestLag = 0
        var bestCost = Double.infinity
        for lag in (-maxLag)...maxLag {
            var squared = 0.0
            for index in range {
                let residual = Double(Int(system[index]) - 2 * Int(mic[index + lag]))
                squared += residual * residual
            }
            let cost = squared / Double(range.count)
            if cost < bestCost || (cost == bestCost && abs(lag) < abs(bestLag)) {
                bestCost = cost
                bestLag = lag
            }
        }
        return (bestLag, bestCost)
    }

    private static func diagnoseConsumerFixture(inputRate: Double, directory: URL) throws -> [String: Any] {
        let outputRate = AudioCaptureService.targetSampleRate
        let pattern = [1, 7, 73, 1023, 4093, 31, 8192, 127, 257]
        let inputFrames = Int(inputRate) / 3 + 37
        let waveformFrames = Int(inputRate) / 50
        var slotFrames: [Int] = []
        var plannedFrames = 0
        while plannedFrames < inputFrames {
            let count = min(pattern[slotFrames.count % pattern.count], inputFrames - plannedFrames)
            slotFrames.append(count)
            plannedFrames += count
        }
        // Preload the complete fixture with capacity to spare. Callback drops
        // must not depend on how quickly the OS schedules the consumer thread.
        let ring = AudioRingBuffer(capacity: slotFrames.count + 1)
        let pcmURL = directory.appendingPathComponent("capture-\(Int(inputRate)).pcm")
        let writer = try PCMFileWriter(path: pcmURL.path)
        var writerClosed = false
        defer { if !writerClosed { try? writer.close() } }
        let consumer = try Consumer(ring: ring, writer: writer, inputRate: inputRate, onWriteFailure: nil)
        var offset = 0
        for count in slotFrames {
            ring.write { slot in
                slot.frames = count
                for index in 0..<count {
                    let frame = offset + index
                    let t = Double(frame - (inputFrames - 1)) / inputRate
                    let waveform: Float = frame >= inputFrames - waveformFrames
                        ? Float(cos(2 * .pi * 1_000 * t)) : 0
                    slot.system[index] = 0.5 * waveform
                    slot.mic[index] = 0.25 * waveform
                }
            }
            offset += count
        }
        consumer.start()
        var errors: [String] = []
        do { try consumer.finish() } catch { errors.append("consumer finish: \(error.localizedDescription)") }
        do { try writer.close() } catch { errors.append("writer close: \(error.localizedDescription)") }
        writerClosed = true
        let data = try Data(contentsOf: pcmURL)
        let frameBytes = 2 * MemoryLayout<Int16>.size
        let frames = data.count / frameBytes
        var systemSamples: [Int16] = []
        var micSamples: [Int16] = []
        systemSamples.reserveCapacity(frames)
        micSamples.reserveCapacity(frames)
        data.withUnsafeBytes { bytes in
            for frame in 0..<frames {
                systemSamples.append(Int16(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: frame * frameBytes, as: Int16.self)))
                micSamples.append(Int16(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: frame * frameBytes + MemoryLayout<Int16>.size, as: Int16.self)))
            }
        }
        func channelMeasurement(_ samples: [Int16], amplitude: Double) -> [String: Any] {
            let tail = samples.suffix(64)
            let energy = tail.reduce(0.0) { $0 + Double($1) * Double($1) }
            let rms = tail.isEmpty ? 0 : sqrt(energy / Double(tail.count))
            // Four cycles of the injected 1 kHz waveform, allowing 50% RMS
            // attenuation for conversion/endpoint filtering rather than exact
            // samples from a second copy of the implementation.
            let minimumRMS = amplitude * Double(Int16.max) / sqrt(2) / 2
            let first = samples.firstIndex { abs(Int($0)) > 32 }
            let last = samples.lastIndex { abs(Int($0)) > 32 }
            return [
                "frames": samples.count, "tailFrames": tail.count, "tailRMS": rms,
                "minimumTailRMS": minimumRMS, "tailWaveformPresent": rms > minimumRMS,
                "tailSamples": tail.map(Int.init), "nonzeroThreshold": 32,
                "firstNonzeroFrame": first.map { $0 as Any } ?? NSNull(),
                "lastNonzeroFrame": last.map { $0 as Any } ?? NSNull(),
            ]
        }
        let systemMeasurement = channelMeasurement(systemSamples, amplitude: 0.5)
        let micMeasurement = channelMeasurement(micSamples, amplitude: 0.25)
        let idealFrames = Double(inputFrames) * outputRate / inputRate
        // Fractional rate conversion can round one final output frame. This
        // tolerance applies once to the stream, never once per ring slot.
        let frameTolerance = 1.0
        let frameError = Double(frames) - idealFrames
        if abs(frameError) > frameTolerance { errors.append("PCM duration differs by \(frameError) frames") }
        if data.count % frameBytes != 0 { errors.append("PCM has an incomplete stereo frame") }
        if ring.droppedCallbacks != 0 { errors.append("synthetic ring dropped \(ring.droppedCallbacks) slots") }
        if ring.acceptedCallbacks != slotFrames.count { errors.append("synthetic ring accepted an unexpected slot count") }
        if ring.count != 0 { errors.append("consumer left \(ring.count) ring slots queued") }
        if systemMeasurement["tailWaveformPresent"] as? Bool != true { errors.append("system final waveform is absent") }
        if micMeasurement["tailWaveformPresent"] as? Bool != true { errors.append("microphone final waveform is absent") }
        let scaleMismatch = zip(systemSamples, micSamples).reduce(0) {
            max($0, abs(Int($1.0) - 2 * Int($1.1)))
        }
        if scaleMismatch > 2 { errors.append("stereo waveform violates the injected 2:1 amplitude ratio") }
        let waveformLag = diagnosticWaveformLag(system: systemSamples, mic: micSamples)
        if let waveformLag {
            if waveformLag.frames != 0 {
                errors.append("microphone/system waveforms differ by \(waveformLag.frames) frames")
            }
        } else {
            errors.append("insufficient stereo samples to measure waveform lag")
        }
        let systemFirst = systemSamples.firstIndex { abs(Int($0)) > 32 }
        let micFirst = micSamples.firstIndex { abs(Int($0)) > 32 }
        let firstNonzeroLag: Any
        if let systemFirst, let micFirst {
            let lag = micFirst - systemFirst
            firstNonzeroLag = lag
        } else {
            firstNonzeroLag = NSNull()
            errors.append("cannot measure threshold onset without both final waveforms")
        }
        return [
            "status": errors.isEmpty ? "passed" : "failed", "errors": errors,
            "inputSampleRate": inputRate, "outputSampleRate": outputRate,
            "systemInputFrames": inputFrames, "micInputFrames": inputFrames,
            "inputScope": "deterministic mono ring slots; no hardware callback",
            "slotFramePattern": pattern, "slotFrames": slotFrames, "ringCapacity": ring.capacity,
            "acceptedCallbacks": ring.acceptedCallbacks, "droppedCallbacks": ring.droppedCallbacks,
            "ringSlotsRemaining": ring.count, "consumerStopReturned": true,
            "pcmPath": pcmURL.path, "pcmBytes": data.count, "pcmFrames": frames,
            "pcmFormat": "16 kHz stereo Int16 little-endian; L=system,R=mic",
            "idealOutputFrames": idealFrames, "allowedFrameError": frameTolerance,
            "outputFrameError": frameError, "writerBytesWritten": writer.bytesWritten,
            "writerBufferedBytes": writer.bufferedByteCount,
            "consumerBuffers": consumer.diagnosticBufferCounts(),
            "system": systemMeasurement, "mic": micMeasurement,
            "micMinusSystemFirstNonzeroLagFrames": firstNonzeroLag,
            "micRelativeWaveformLagFrames": waveformLag.map { $0.frames as Any } ?? NSNull(),
            "waveformLagMeanSquaredResidual": waveformLag.map { $0.meanSquaredResidual as Any } ?? NSNull(),
            "waveformLagMethod": "minimum L-minus-2R squared residual, lags -8...8, common sample interval",
            "maximumSystemMinusTwiceMicMagnitude": scaleMismatch,
        ]
    }

    // MARK: - Consumer thread

    /// Drains ring slots: resample both tracks, interleave L/R, feed the
    /// buffered writer. Owns the resamplers.
    private final class Consumer: @unchecked Sendable {
        private enum IntegrityError: LocalizedError {
            case unpairedFrames(system: Int, mic: Int)
            case pendingLimitExceeded(system: Int, mic: Int, limit: Int)
            case incompleteDrain(channel: String, calls: Int)

            var errorDescription: String? {
                switch self {
                case .unpairedFrames(let system, let mic):
                    return "La captura terminó con frames sin pareja estéreo (sistema: \(system), micrófono: \(mic)); no se descartaron ni rellenaron silenciosamente. El audio ya escrito se conserva."
                case .pendingLimitExceeded(let system, let mic, let limit):
                    return "Los frames pendientes de captura excedieron el límite por canal \(limit) (sistema: \(system), micrófono: \(mic)). El audio ya escrito se conserva."
                case .incompleteDrain(let channel, let calls):
                    return "El conversor de \(channel) no confirmó fin de stream después de \(calls) intentos. El audio ya escrito se conserva."
                }
            }
        }

        /// Consumer-owned, fixed-capacity FIFO; never touched by the IOProc.
        private final class PendingFrames {
            let capacity: Int
            private var storage: [Int16]
            private var head = 0
            private(set) var count = 0

            init(capacity: Int) {
                self.capacity = capacity
                storage = [Int16](repeating: 0, count: capacity)
            }

            func append(_ samples: [Int16]) {
                precondition(samples.count <= capacity - count)
                guard !samples.isEmpty else { return }
                let tail = (head + count) % capacity
                let firstCount = min(samples.count, capacity - tail)
                samples.withUnsafeBufferPointer { source in
                    storage.withUnsafeMutableBufferPointer { destination in
                        destination.baseAddress!.advanced(by: tail)
                            .update(from: source.baseAddress!, count: firstCount)
                        let remaining = samples.count - firstCount
                        if remaining > 0 {
                            destination.baseAddress!.update(
                                from: source.baseAddress!.advanced(by: firstCount), count: remaining)
                        }
                    }
                }
                count += samples.count
            }

            subscript(index: Int) -> Int16 {
                let position = head + index
                return storage[position < capacity ? position : position - capacity]
            }

            func consume(_ frames: Int) {
                precondition(frames <= count)
                count -= frames
                head = count == 0 ? 0 : (head + frames) % capacity
            }
        }

        /// Input counts are mono frames delivered by the ring, including any
        /// silence the IOProc already inserted. They are not device-frame counts.
        private struct QAMetrics: Encodable {
            let schemaVersion = 2
            let inputSampleRate: Double
            let outputSampleRate = AudioCaptureService.targetSampleRate
            let pcmPath: String
            let writerByteOffsetAtStart: Int
            let captureRepairEnabled = QAExperiment.repairCapture
            let systemOutputFrameCapacity: Int
            let micOutputFrameCapacity: Int
            let pendingFrameLimitPerChannel: Int
            var consumedSlots = 0
            var systemInputFrames = 0
            var micInputFrames = 0
            var inputFramesPerChannelSkippedAfterWriteFailure = 0
            var inputFramesPerChannelSkippedAfterCaptureFailure = 0
            var system16FramesProduced = 0
            var mic16FramesProduced = 0
            var systemUnpairedFramesDiscarded = 0
            var micUnpairedFramesDiscarded = 0
            var systemPendingFramesHighWater = 0
            var micPendingFramesHighWater = 0
            var systemUnpairedFramesHighWater = 0
            var micUnpairedFramesHighWater = 0
            var systemPendingFramesAtFinish = 0
            var micPendingFramesAtFinish = 0
            var systemFramesRejectedAtPendingLimit = 0
            var micFramesRejectedAtPendingLimit = 0
            var systemOutputFramesMaximum = 0
            var micOutputFramesMaximum = 0
            var interleavedFramesMaximum = 0
            var pairedFramesSubmittedToWriter = 0
            var pairedFramesAcceptedByWriter = 0
            var pairedFramesInFailedWrite = 0
            var stopRequested = false
            var consumerCompleted = false
            var ringSlotsRemainingAtFinish = 0
            var ringAcceptedCallbacksCumulative = 0
            var ringDroppedCallbacksCumulative = 0
            var writerByteOffsetAtFinish = 0
            var pairedFramesWrittenToFile = 0
            var writerBufferedBytesAtFinish = 0
            var writeError: String?
            var writerFlushError: String?
            var captureIntegrityError: String?
            var systemConversionError: String?
            var micConversionError: String?
            var captureResamplersDrainedToPCM = false
            let qaTailProbeIncludedInPCM = false
            var systemBufferedTailProbe: QATailProbe?
            var micBufferedTailProbe: QATailProbe?
            var systemDrainedTail: QATailProbe?
            var micDrainedTail: QATailProbe?
        }

        private struct QATailProbe: Encodable {
            var frames = 0
            var nonzeroFrames = 0
            var peakMagnitude = 0
            var flushCalls = 0
            var stoppedAfterEmptyOutput = false
            let converterStatusAvailable = true
            var lastConverterStatus: String?
            var reachedEndOfStream = false
            var error: String?

            mutating func record(_ samples: [Int16], status: AVAudioConverterOutputStatus) {
                flushCalls += 1
                frames += samples.count
                lastConverterStatus = String(describing: status)
                reachedEndOfStream = status == .endOfStream
                stoppedAfterEmptyOutput = samples.isEmpty
                for sample in samples {
                    let magnitude = abs(Int(sample))
                    if magnitude > 0 { nonzeroFrames += 1 }
                    peakMagnitude = max(peakMagnitude, magnitude)
                }
            }
        }

        let inputRate: Double
        private let ring: AudioRingBuffer
        private let writer: PCMFileWriter
        private let onWriteFailure: (@Sendable (String) -> Void)?
        private let system: AudioResampler
        private let mic: AudioResampler
        private let repairCapture = QAExperiment.repairCapture
        private static let drainCallLimit = 8
        private let pendingFrameLimit: Int
        private let systemPending: PendingFrames?
        private let micPending: PendingFrames?
        private let stopFlag = OSAllocatedUnfairLock(initialState: false)
        private let done = DispatchSemaphore(value: 0)
        private var system16: [Int16] = []
        private var mic16: [Int16] = []
        private var interleaved: [Int16] = []
        private var writeError: Error?
        private var captureError: Error?
        private var completionError: Error?
        private var qaMetrics: QAMetrics?

        init(ring: AudioRingBuffer, writer: PCMFileWriter, inputRate: Double,
             onWriteFailure: (@Sendable (String) -> Void)?) throws {
            guard let system = AudioResampler(inputRate: inputRate, outputRate: AudioCaptureService.targetSampleRate, channels: 1),
                  let mic = AudioResampler(inputRate: inputRate, outputRate: AudioCaptureService.targetSampleRate, channels: 1)
            else { throw CaptureError.resamplerInitFailed }
            self.ring = ring
            self.writer = writer
            self.inputRate = inputRate
            self.onWriteFailure = onWriteFailure
            self.system = system
            self.mic = mic
            // A converter batch plus one retained batch. Persistent divergence
            // fails explicitly rather than growing a meeting-sized queue.
            let pendingLimit = 2 * max(system.outputFrameCapacity, mic.outputFrameCapacity)
            pendingFrameLimit = pendingLimit
            systemPending = QAExperiment.repairCapture ? PendingFrames(capacity: pendingLimit) : nil
            micPending = QAExperiment.repairCapture ? PendingFrames(capacity: pendingLimit) : nil
            system16.reserveCapacity(repairCapture ? system.outputFrameCapacity : AudioRingBuffer.maxFrames)
            mic16.reserveCapacity(repairCapture ? mic.outputFrameCapacity : AudioRingBuffer.maxFrames)
            interleaved.reserveCapacity((repairCapture ? pendingLimit : AudioRingBuffer.maxFrames) * 2)
            if QATrace.isEnabled {
                qaMetrics = QAMetrics(
                    inputSampleRate: inputRate, pcmPath: writer.path,
                    writerByteOffsetAtStart: writer.bytesWritten + writer.bufferedByteCount,
                    systemOutputFrameCapacity: system.outputFrameCapacity,
                    micOutputFrameCapacity: mic.outputFrameCapacity,
                    pendingFrameLimitPerChannel: repairCapture ? pendingFrameLimit : 0)
            }
        }

        func diagnosticBufferCounts() -> [String: Any] {
            [
                "captureRepairEnabled": repairCapture,
                "pendingFrameLimitPerChannel": repairCapture ? pendingFrameLimit : 0,
                "systemPendingFramesAtFinish": systemPending?.count ?? 0,
                "micPendingFramesAtFinish": micPending?.count ?? 0,
                "systemPendingFramesHighWater": qaMetrics?.systemPendingFramesHighWater ?? 0,
                "micPendingFramesHighWater": qaMetrics?.micPendingFramesHighWater ?? 0,
                "systemUnpairedFramesHighWater": qaMetrics?.systemUnpairedFramesHighWater ?? 0,
                "micUnpairedFramesHighWater": qaMetrics?.micUnpairedFramesHighWater ?? 0,
                "systemOutputFrameCapacity": system.outputFrameCapacity,
                "micOutputFrameCapacity": mic.outputFrameCapacity,
                "systemOutputCacheCapacity": system16.capacity,
                "micOutputCacheCapacity": mic16.capacity,
                "systemOutputFramesMaximum": qaMetrics?.systemOutputFramesMaximum ?? 0,
                "micOutputFramesMaximum": qaMetrics?.micOutputFramesMaximum ?? 0,
                "interleavedCacheCapacityFrames": interleaved.capacity / 2,
                "interleavedFramesMaximum": qaMetrics?.interleavedFramesMaximum ?? 0,
                "system16FramesProduced": qaMetrics?.system16FramesProduced ?? 0,
                "mic16FramesProduced": qaMetrics?.mic16FramesProduced ?? 0,
                "systemFramesRejectedAtPendingLimit": qaMetrics?.systemFramesRejectedAtPendingLimit ?? 0,
                "micFramesRejectedAtPendingLimit": qaMetrics?.micFramesRejectedAtPendingLimit ?? 0,
                "systemUnpairedFramesDiscarded": qaMetrics?.systemUnpairedFramesDiscarded ?? 0,
                "micUnpairedFramesDiscarded": qaMetrics?.micUnpairedFramesDiscarded ?? 0,
                "drainCallLimitPerChannel": Self.drainCallLimit,
            ]
        }

        func start() {
            let thread = Thread { [self] in run() }
            thread.name = "meetcapture.capture.consumer"
            thread.qualityOfService = .userInitiated
            // Foundation gives block threads 512 KB; the resampler path
            // overflowed that on real calls (three SIGBUS on 2026-09-11).
            thread.stackSize = AudioCaptureService.workerStackSize
            thread.start()
        }

        /// Signals the thread, waits until every queued slot is written and flushed.
        func finish() throws {
            stopFlag.withLock { $0 = true }
            ring.available.signal()
            done.wait()
            var traceError: Error?
            if var metrics = qaMetrics {
                metrics.stopRequested = true
                metrics.consumerCompleted = true
                metrics.ringSlotsRemainingAtFinish = ring.count
                metrics.ringAcceptedCallbacksCumulative = ring.acceptedCallbacks
                metrics.ringDroppedCallbacksCumulative = ring.droppedCallbacks
                metrics.writerByteOffsetAtFinish = writer.bytesWritten
                metrics.pairedFramesWrittenToFile =
                    (writer.bytesWritten - metrics.writerByteOffsetAtStart) / (2 * MemoryLayout<Int16>.size)
                metrics.writerBufferedBytesAtFinish = writer.bufferedByteCount
                metrics.systemPendingFramesAtFinish = systemPending?.count ?? 0
                metrics.micPendingFramesAtFinish = micPending?.count ?? 0
                metrics.captureIntegrityError = captureError?.localizedDescription
                metrics.writeError = writeError?.localizedDescription
                metrics.writerFlushError = completionError?.localizedDescription
                // Baseline-only observation must never consume the repair's
                // tail. The repaired consumer already drained both converters
                // on its own thread, before the writer flush.
                if !repairCapture {
                    metrics.systemBufferedTailProbe = probeBufferedTail(system)
                    metrics.micBufferedTailProbe = probeBufferedTail(mic)
                }
                do {
                    try QATrace.write(metrics, name: "capture-consumer")
                } catch {
                    traceError = error
                }
            }
            if repairCapture, let captureError { throw captureError }
            if let completionError { throw completionError }
            if repairCapture, let writeError { throw writeError }
            if let traceError { throw traceError }
        }

        private func run() {
            while true {
                _ = ring.available.wait(timeout: .now() + 0.5)
                while ring.read({ process($0) }) {}
                if stopFlag.withLock({ $0 }) {
                    while ring.read({ process($0) }) {}
                    break
                }
            }
            if repairCapture { drainResamplers() }
            do {
                try writer.flush()
            } catch {
                completionError = error
                qaMetrics?.captureResamplersDrainedToPCM = false
            }
            done.signal()
        }

        private func probeBufferedTail(_ resampler: AudioResampler) -> QATailProbe {
            var probe = QATailProbe()
            var tail: [Int16] = []
            tail.reserveCapacity(resampler.outputFrameCapacity)
            // Preserve the baseline's post-stop observation without writing
            // these samples. Converter failures are evidence, not empty tails.
            for _ in 0..<Self.drainCallLimit {
                do {
                    let status = try resampler.flush(into: &tail)
                    probe.record(tail, status: status)
                    if tail.isEmpty { break }
                } catch {
                    probe.flushCalls += 1
                    probe.error = error.localizedDescription
                    break
                }
            }
            return probe
        }

        private func recordCaptureFailure(_ error: Error) {
            guard captureError == nil else { return }
            captureError = error
            onWriteFailure?("La captura no pudo conservar todo el audio: \(error.localizedDescription). Detené la grabación.")
        }

        private func recordConversionFailure(_ error: Error, channel: String) {
            if channel == "sistema" { qaMetrics?.systemConversionError = error.localizedDescription }
            else { qaMetrics?.micConversionError = error.localizedDescription }
            // Keep the actual NSError from AVAudioConverter for stopCapture().
            recordCaptureFailure(error)
        }

        private func updatePendingMetrics() {
            guard let systemPending, let micPending, qaMetrics != nil else { return }
            let systemHighWater = max(qaMetrics?.systemPendingFramesHighWater ?? 0, systemPending.count)
            let micHighWater = max(qaMetrics?.micPendingFramesHighWater ?? 0, micPending.count)
            let systemUnpaired = max(qaMetrics?.systemUnpairedFramesHighWater ?? 0,
                                     systemPending.count - micPending.count)
            let micUnpaired = max(qaMetrics?.micUnpairedFramesHighWater ?? 0,
                                  micPending.count - systemPending.count)
            qaMetrics?.systemPendingFramesHighWater = systemHighWater
            qaMetrics?.micPendingFramesHighWater = micHighWater
            qaMetrics?.systemUnpairedFramesHighWater = systemUnpaired
            qaMetrics?.micUnpairedFramesHighWater = micUnpaired
        }

        private func pairConvertedOutput() {
            guard let systemPending, let micPending else { return }
            if systemPending.count == 0, micPending.count == 0, system16.count == mic16.count {
                // No copies through the FIFOs for the usual equal-output slot.
                interleaveConvertedOutput(frames: system16.count)
                _ = submitInterleaved(frames: system16.count)
                return
            }
            let systemCount = systemPending.count + system16.count
            let micCount = micPending.count + mic16.count
            guard systemCount <= pendingFrameLimit, micCount <= pendingFrameLimit else {
                qaMetrics?.systemFramesRejectedAtPendingLimit += system16.count
                qaMetrics?.micFramesRejectedAtPendingLimit += mic16.count
                recordCaptureFailure(IntegrityError.pendingLimitExceeded(
                    system: systemCount, mic: micCount, limit: pendingFrameLimit))
                return
            }
            systemPending.append(system16)
            micPending.append(mic16)
            updatePendingMetrics()
            pairPendingOutput()
        }

        private func pairPendingOutput() {
            guard writeError == nil, let systemPending, let micPending else { return }
            let frames = min(systemPending.count, micPending.count)
            guard frames > 0 else { return }
            interleaved.removeAll(keepingCapacity: true)
            for index in 0..<frames {
                interleaved.append(systemPending[index])
                interleaved.append(micPending[index])
            }
            if submitInterleaved(frames: frames) {
                systemPending.consume(frames)
                micPending.consume(frames)
            }
        }

        private func drainResamplers() {
            guard let systemPending, let micPending else { return }
            // Attempt BOTH even when one converter or the writer has failed.
            // There are no more ring slots and the writer is still open.
            let systemTail = drain(system, pending: systemPending, channel: "sistema")
            let micTail = drain(mic, pending: micPending, channel: "micrófono")
            qaMetrics?.systemDrainedTail = systemTail
            qaMetrics?.micDrainedTail = micTail
            pairPendingOutput()
            if writeError == nil, systemPending.count > 0 || micPending.count > 0 {
                recordCaptureFailure(IntegrityError.unpairedFrames(
                    system: systemPending.count, mic: micPending.count))
            }
            qaMetrics?.captureResamplersDrainedToPCM =
                systemTail.reachedEndOfStream && micTail.reachedEndOfStream
                && systemPending.count == 0 && micPending.count == 0
                && captureError == nil && writeError == nil
        }

        private func drain(_ resampler: AudioResampler, pending: PendingFrames,
                           channel: String) -> QATailProbe {
            var probe = QATailProbe()
            // Reuse one conversion cache after ring consumption is complete.
            for _ in 0..<Self.drainCallLimit {
                let status: AVAudioConverterOutputStatus
                do {
                    status = try resampler.flush(into: &system16)
                } catch {
                    probe.flushCalls += 1
                    probe.error = error.localizedDescription
                    recordConversionFailure(error, channel: channel)
                    return probe
                }
                probe.record(system16, status: status)
                if channel == "sistema" {
                    qaMetrics?.system16FramesProduced += system16.count
                    let maximum = max(qaMetrics?.systemOutputFramesMaximum ?? 0, system16.count)
                    qaMetrics?.systemOutputFramesMaximum = maximum
                } else {
                    qaMetrics?.mic16FramesProduced += system16.count
                    let maximum = max(qaMetrics?.micOutputFramesMaximum ?? 0, system16.count)
                    qaMetrics?.micOutputFramesMaximum = maximum
                }
                if system16.count <= pending.capacity - pending.count {
                    pending.append(system16)
                    updatePendingMetrics()
                } else {
                    if channel == "sistema" { qaMetrics?.systemFramesRejectedAtPendingLimit += system16.count }
                    else { qaMetrics?.micFramesRejectedAtPendingLimit += system16.count }
                    let error = IntegrityError.pendingLimitExceeded(
                        system: (systemPending?.count ?? 0) + (channel == "sistema" ? system16.count : 0),
                        mic: (micPending?.count ?? 0) + (channel == "micrófono" ? system16.count : 0),
                        limit: pendingFrameLimit)
                    probe.error = error.localizedDescription
                    recordCaptureFailure(error)
                }
                if status == .endOfStream { return probe }
            }
            let error = IntegrityError.incompleteDrain(channel: channel, calls: Self.drainCallLimit)
            probe.error = error.localizedDescription
            recordCaptureFailure(error)
            return probe
        }

        private func interleaveConvertedOutput(frames: Int) {
            interleaved.removeAll(keepingCapacity: true)
            for index in 0..<frames {
                interleaved.append(system16[index])
                interleaved.append(mic16[index])
            }
        }

        private func submitInterleaved(frames: Int) -> Bool {
            guard frames > 0 else { return true }
            let maximum = max(qaMetrics?.interleavedFramesMaximum ?? 0, frames)
            qaMetrics?.interleavedFramesMaximum = maximum
            do {
                qaMetrics?.pairedFramesSubmittedToWriter += frames
                try writer.write(interleaved)
                qaMetrics?.pairedFramesAcceptedByWriter += frames
                return true
            } catch {
                qaMetrics?.pairedFramesInFailedWrite += frames
                writeError = error
                onWriteFailure?("La captura dejó de guardar audio: \(error.localizedDescription). Detené la grabación.")
                return false
            }
        }

        private func process(_ slot: AudioRingBuffer.Slot) {
            if qaMetrics != nil, slot.frames > 0 {
                qaMetrics?.consumedSlots += 1
                qaMetrics?.systemInputFrames += slot.frames
                qaMetrics?.micInputFrames += slot.frames
                if writeError != nil {
                    qaMetrics?.inputFramesPerChannelSkippedAfterWriteFailure += slot.frames
                }
                if captureError != nil {
                    qaMetrics?.inputFramesPerChannelSkippedAfterCaptureFailure += slot.frames
                }
            }
            guard writeError == nil, captureError == nil else { return }
            let frames = slot.frames
            guard frames > 0 else { return }
            if repairCapture {
                do {
                    try system.resample(mono: UnsafePointer(slot.system), frameCount: frames, into: &system16)
                } catch {
                    recordConversionFailure(error, channel: "sistema")
                }
                do {
                    try mic.resample(mono: UnsafePointer(slot.mic), frameCount: frames, into: &mic16)
                } catch {
                    recordConversionFailure(error, channel: "micrófono")
                }
            } else {
                // Keep baseline's converter-error behavior for the isolated A/B.
                try? system.resample(mono: UnsafePointer(slot.system), frameCount: frames, into: &system16)
                try? mic.resample(mono: UnsafePointer(slot.mic), frameCount: frames, into: &mic16)
            }
            if qaMetrics != nil {
                qaMetrics?.system16FramesProduced += system16.count
                qaMetrics?.mic16FramesProduced += mic16.count
                let systemMaximum = max(qaMetrics?.systemOutputFramesMaximum ?? 0, system16.count)
                let micMaximum = max(qaMetrics?.micOutputFramesMaximum ?? 0, mic16.count)
                qaMetrics?.systemOutputFramesMaximum = systemMaximum
                qaMetrics?.micOutputFramesMaximum = micMaximum
            }
            if repairCapture {
                pairConvertedOutput()
            } else {
                let n = min(system16.count, mic16.count)
                qaMetrics?.systemUnpairedFramesDiscarded += system16.count - n
                qaMetrics?.micUnpairedFramesDiscarded += mic16.count - n
                interleaveConvertedOutput(frames: n)
                _ = submitInterleaved(frames: n)
            }
        }
    }
}

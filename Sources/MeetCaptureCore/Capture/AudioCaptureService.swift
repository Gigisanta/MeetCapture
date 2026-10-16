// AudioCaptureService.swift
// Records the meeting: system audio (Core Audio process tap) + microphone
// → 16 kHz Int16 stereo interleaved raw PCM (L=system, R=mic) plus a
// `.format.json` sidecar.
//
// Threads:
//   real-time IOProc  → mixes each track to mono into a preallocated ring slot
//   consumer Thread   → resample, interleave, live sink, buffered file write
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
    func getLiveSink() -> (@Sendable ([Int16]) -> Void)?
    func setLiveSink(_ sink: (@Sendable ([Int16]) -> Void)?)

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

    /// Consumer of the live 16 kHz mono mix (L+R, clamped). Called on the consumer thread.
    var liveSink: (@Sendable ([Int16]) -> Void)? {
        get { engine.getLiveSink() }
        set { engine.setLiveSink(newValue) }
    }

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

/// Holds the live sink inside the lock. A bare closure in the generic lock
/// state is re-wrapped in a reabstraction thunk on every `withLock { $0 }`
/// and the thunks pile up: after ~18 min of reads per chunk the consumer
/// thread overflowed its stack (SIGBUS on 2026-09-15 and 2026-09-24).
struct LiveSinkBox: Sendable {
    let call: @Sendable ([Int16]) -> Void
}

/// Everything below the main actor: owned by `queue` except the ring
/// (IOProc + consumer) and `liveSink` (any thread).
final class CaptureEngine: CaptureEngineBackend, @unchecked Sendable {
    private struct PendingStartArtifacts: Sendable {
        let audioPath: String
        let sidecarPath: String
    }

    let queue = DispatchQueue(label: AppInfo.bundleID + ".capture", qos: .userInitiated)
    let ring = AudioRingBuffer()
    let liveSink = OSAllocatedUnfairLock<LiveSinkBox?>(initialState: nil)
    var onRebuildFailure: (@Sendable (String) -> Void)?

    var acceptedCallbacks: Int { ring.acceptedCallbacks }
    var droppedCallbacks: Int { ring.droppedCallbacks }

    func getLiveSink() -> (@Sendable ([Int16]) -> Void)? {
        liveSink.withLock { $0 }?.call
    }

    func setLiveSink(_ sink: (@Sendable ([Int16]) -> Void)?) {
        liveSink.withLock { $0 = sink.map(LiveSinkBox.init(call:)) }
    }

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
                                        liveSink: liveSink, onWriteFailure: onRebuildFailure)
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
                    // Mic-only leaves L silent: PCMToWAV and the live sink sum
                    // L+R, so copying the mic to both channels would double it.
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
                                         liveSink: liveSink, onWriteFailure: onRebuildFailure)
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

    // MARK: - Consumer thread

    /// Drains ring slots: resample both tracks, interleave L/R, feed the
    /// live sink and the buffered writer. Owns the resamplers.
    private final class Consumer: @unchecked Sendable {
        let inputRate: Double
        private let ring: AudioRingBuffer
        private let writer: PCMFileWriter
        private let liveSink: OSAllocatedUnfairLock<LiveSinkBox?>
        private let onWriteFailure: (@Sendable (String) -> Void)?
        private let system: AudioResampler
        private let mic: AudioResampler
        private let stopFlag = OSAllocatedUnfairLock(initialState: false)
        private let done = DispatchSemaphore(value: 0)
        private var system16: [Int16] = []
        private var mic16: [Int16] = []
        private var interleaved: [Int16] = []
        private var writeError: Error?
        private var completionError: Error?

        init(ring: AudioRingBuffer, writer: PCMFileWriter, inputRate: Double,
             liveSink: OSAllocatedUnfairLock<LiveSinkBox?>,
             onWriteFailure: (@Sendable (String) -> Void)?) throws {
            guard let system = AudioResampler(inputRate: inputRate, outputRate: AudioCaptureService.targetSampleRate, channels: 1),
                  let mic = AudioResampler(inputRate: inputRate, outputRate: AudioCaptureService.targetSampleRate, channels: 1)
            else { throw CaptureError.resamplerInitFailed }
            self.ring = ring
            self.writer = writer
            self.inputRate = inputRate
            self.liveSink = liveSink
            self.onWriteFailure = onWriteFailure
            self.system = system
            self.mic = mic
            system16.reserveCapacity(AudioRingBuffer.maxFrames)
            mic16.reserveCapacity(AudioRingBuffer.maxFrames)
            interleaved.reserveCapacity(AudioRingBuffer.maxFrames * 2)
        }

        func start() {
            let thread = Thread { [self] in run() }
            thread.name = "meetcapture.capture.consumer"
            thread.qualityOfService = .userInitiated
            // Foundation gives block threads 512 KB; the resampler + live feed
            // path overflowed that on real calls (three SIGBUS on 2026-09-11).
            thread.stackSize = AudioCaptureService.workerStackSize
            thread.start()
        }

        /// Signals the thread, waits until every queued slot is written and flushed.
        func finish() throws {
            stopFlag.withLock { $0 = true }
            ring.available.signal()
            done.wait()
            if let completionError { throw completionError }
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
            do {
                try writer.flush()
            } catch {
                completionError = error
            }
            done.signal()
        }

        private func process(_ slot: AudioRingBuffer.Slot) {
            guard writeError == nil else { return }
            let frames = slot.frames
            guard frames > 0 else { return }
            system.resample(mono: UnsafePointer(slot.system), frameCount: frames, into: &system16)
            mic.resample(mono: UnsafePointer(slot.mic), frameCount: frames, into: &mic16)
            let n = min(system16.count, mic16.count)
            guard n > 0 else { return }
            interleaved.removeAll(keepingCapacity: true)
            for i in 0..<n {
                interleaved.append(system16[i])
                interleaved.append(mic16[i])
            }
            if let sink = liveSink.withLock({ $0 }) {
                var mix = [Int16](repeating: 0, count: n)
                for i in 0..<n { mix[i] = PCMToWAV.mix(system16[i], mic16[i]) }
                sink.call(mix)
            }
            do {
                try writer.write(interleaved)
            } catch {
                writeError = error
                onWriteFailure?("La captura dejó de guardar audio: \(error.localizedDescription). Detené la grabación.")
            }
        }
    }
}

// AudioCapture.swift
// MeetCapture v4 — System audio capture via Core Audio process tap.
//
// NOTE: This replaced the ScreenCaptureKit (SCStream) implementation, which
// regressed on macOS 15+/26: SCStream.startCapture() succeeds but never
// delivers any sample-buffer callbacks (audio OR screen), with no error —
// confirmed reproducible with minimal textbook code signed under the granted
// identity. The Core Audio process-tap API (macOS 14.4+) captures the global
// system-audio mix reliably and does NOT require Screen Recording permission.

import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import AppKit
import os.log

// MARK: - Capture Errors

enum CaptureError: LocalizedError {
    case fileCreationFailed(path: String, reason: String)
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .fileCreationFailed(let path, let reason):
            return "Failed to create output file at '\(path)': \(reason)"
        case .tapCreationFailed(let s):
            return "Could not create system-audio tap (OSStatus \(s)). Grant Audio Recording access in System Settings."
        case .aggregateCreationFailed(let s):
            return "Could not create capture device (OSStatus \(s))."
        case .ioProcCreationFailed(let s):
            return "Could not install audio callback (OSStatus \(s))."
        case .deviceStartFailed(let s):
            return "Could not start audio capture (OSStatus \(s))."
        }
    }
}

// MARK: - Capture State

enum CaptureState: Equatable {
    case idle
    case recording
    case error(String)

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }
}

// MARK: - AudioCaptureService

/// Captures a meeting's full audio — the system-audio mix (remote participants)
/// via a Core Audio process tap PLUS the local microphone (your own voice) —
/// into one raw PCM file. Both sources are summed to **mono Float32** in the
/// IOProc. The aggregate's sample rate depends on the input device (48kHz with
/// the tap alone, 44.1kHz when the built-in mic drives the clock), so we read
/// the ACTUAL rate at setup (`currentSampleRate`) and the transcriber resamples
/// from it to 16kHz — nothing about the rate is hardcoded.
final class AudioCaptureService: NSObject, @unchecked Sendable {
    @Published private(set) var state: CaptureState = .idle
    @Published private(set) var bytesCaptured: Int = 0
    @Published private(set) var lastError: String?

    /// Sample rate of the on-disk PCM. Pinned at the FIRST build of a recording
    /// so that rebuilds after a device change (which may run at a different
    /// rate) stay consistent — the IOProc resamples the live stream to this.
    private var recordingSampleRate: Double = 0
    /// Rate the current aggregate actually runs at (updates on each rebuild).
    private var liveInputRate: Double = 48_000
    /// What the transcriber reads the file as.
    var currentSampleRate: Double { recordingSampleRate > 0 ? recordingSampleRate : 48_000 }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var fileHandle: FileHandle?
    /// Serializes rebuilds (device-change) against teardown so the Core Audio
    /// object IDs are never mutated from two threads at once.
    private let rebuildQueue = DispatchQueue(label: "com.meetcapture.rebuild")
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// Serial queue for disk writes. The IOProc runs on a realtime audio thread
    /// where blocking `write()` calls cause dropped samples (the truncated
    /// captures we saw). We copy each buffer and flush it here instead.
    private let writeQueue = DispatchQueue(label: "com.meetcapture.audiowrite", qos: .utility)
    /// Reused across IOProc callbacks so the realtime audio thread never heap-
    /// allocates the mix/resample buffers (malloc there can block on a lock →
    /// priority inversion → dropped samples). Safe as plain stored buffers:
    /// `AudioDeviceStop` drains any in-flight callback before a rebuild starts a
    /// new IOProc, so exactly one callback ever touches these at a time.
    private var scratchMono: [Float] = []
    private var scratchResample: [Float] = []
    private var outputPath: String?
    private(set) var currentOutputPath: String?
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.meetcapture", category: "AudioCapture")

    override init() {
        super.init()
        logger.info("AudioCaptureService initialized (Core Audio process tap)")
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Permission
    //
    // Core Audio process taps require Microphone (audio input) authorization —
    // NOT Screen Recording. Without it, AudioDeviceStart blocks ~60s waiting
    // for the (unanswered) prompt and then fails. We request it up front so
    // recording is instant, and gate the Record button on the status.

    func checkPermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestPermission(completion: @escaping (Bool) -> Void = { _ in }) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    @discardableResult func ensurePermission() -> Bool {
        if checkPermission() { return true }
        requestPermission()
        return false
    }

    /// Open the Microphone privacy pane (UI's "Open Settings" affordance).
    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Capture Lifecycle

    func startCapture(outputPath: String) async throws {
        guard state != .recording else { return }
        try setupCapture(outputPath: outputPath)
    }

    private func setupCapture(outputPath: String) throws {
        lastError = nil
        bytesCaptured = 0
        recordingSampleRate = 0   // pinned on first buildCoreAudio()

        // Output file
        guard FileManager.default.createFile(atPath: outputPath, contents: nil) else {
            throw CaptureError.fileCreationFailed(path: outputPath, reason: "Could not create file")
        }
        guard let handle = FileHandle(forWritingAtPath: outputPath) else {
            throw CaptureError.fileCreationFailed(path: outputPath, reason: "Could not open file for writing")
        }
        fileHandle = handle
        self.outputPath = outputPath
        currentOutputPath = outputPath

        try buildCoreAudio()
        installDeviceListeners()
        state = .recording
        logger.info("Audio capture started (tap+mic) → \(outputPath)")
    }

    /// Builds the tap + aggregate + IOProc and starts it, writing into the
    /// already-open `fileHandle`. Reusable for the initial setup AND for
    /// rebuilding after a device change (which would otherwise leave the tap
    /// delivering zero buffers — a silent, unrecoverable capture).
    private func buildCoreAudio() throws {
        // 1. Global system-audio tap (excludes nothing — capture the full mix)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { throw CaptureError.tapCreationFailed(err) }
        tapID = tap

        // 2. Private aggregate = system-audio tap + (if available) the mic.
        let aggUID = "meetcapture-tap-\(UUID().uuidString)"
        var subDeviceList: [[String: Any]] = []
        if let micUID = defaultInputUID() {
            subDeviceList = [[kAudioSubDeviceUIDKey as String: micUID]]
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetCaptureTap",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: subDeviceList,
            kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapUIDKey as String: desc.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard err == noErr else { throw CaptureError.aggregateCreationFailed(err) }
        aggregateID = agg

        // Rate this aggregate runs at. First build pins the on-disk rate; later
        // rebuilds resample to it so the file stays single-rate.
        var rate = 0.0
        var rsz = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(agg, &rateAddr, 0, nil, &rsz, &rate) == noErr, rate > 0 {
            liveInputRate = rate
        }
        if recordingSampleRate == 0 { recordingSampleRate = liveInputRate }
        let outRate = recordingSampleRate
        logger.info("Core Audio built: live=\(self.liveInputRate)Hz disk=\(outRate)Hz mic=\(!subDeviceList.isEmpty)")

        // 3. IOProc → sum all sub-streams (mic + system) to mono Float32,
        //    resample to the pinned disk rate if the device changed, then write.
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            var frames = 0
            for b in abl where b.mNumberChannels > 0 {
                frames = max(frames, Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels)))
            }
            guard frames > 0 else { return }
            // Mix every sub-device (mic + system) to mono at full level into the
            // reused scratch buffer; clamp avoids clip. Grow only when a larger
            // callback arrives — steady state allocates nothing.
            if self.scratchMono.count < frames { self.scratchMono = [Float](repeating: 0, count: frames) }
            self.scratchMono.withUnsafeMutableBufferPointer { mono in
                for f in 0..<frames { mono[f] = 0 }
                for b in abl {
                    guard let md = b.mData, b.mNumberChannels > 0 else { continue }
                    let ch = Int(b.mNumberChannels)
                    let fp = md.bindMemory(to: Float.self, capacity: frames * ch)
                    for f in 0..<frames {
                        var acc: Float = 0
                        for c in 0..<ch { acc += fp[f * ch + c] }
                        mono[f] += acc / Float(ch)
                    }
                }
                for f in 0..<frames { mono[f] = max(-1, min(1, mono[f])) }
            }
            // Resample to the pinned disk rate only when the device rate differs
            // (post-rebuild); the common case is a no-op. Per-callback linear
            // interp drops the ~10ms boundary sample — inaudible for STT.
            let live = self.liveInputRate
            let srcBuf: [Float]
            let count: Int
            if abs(live - outRate) > 1, live > 0, Int(Double(frames) / (live / outRate)) > 0 {
                let r = live / outRate
                let outN = Int(Double(frames) / r)
                if self.scratchResample.count < outN { self.scratchResample = [Float](repeating: 0, count: outN) }
                self.scratchMono.withUnsafeBufferPointer { m in
                    self.scratchResample.withUnsafeMutableBufferPointer { rs in
                        for j in 0..<outN {
                            let p = Double(j) * r
                            let i = Int(p), fr = Float(p - Double(i))
                            let a = m[i], b = (i + 1 < frames) ? m[i + 1] : a
                            rs[j] = a + (b - a) * fr
                        }
                    }
                }
                srcBuf = self.scratchResample; count = outN
            } else {
                srcBuf = self.scratchMono; count = frames
            }
            // One owned copy for the off-thread write (handoff is unavoidable;
            // the scratch buffers are reused next callback). Blocking disk I/O
            // stays off the realtime thread via writeQueue (no dropped samples).
            let bytes = srcBuf.withUnsafeBytes { raw in
                Data(bytes: raw.baseAddress!, count: count * MemoryLayout<Float>.size)
            }
            self.writeQueue.async { try? self.fileHandle?.write(contentsOf: bytes) }
        }
        guard err == noErr, let proc else { throw CaptureError.ioProcCreationFailed(err) }
        procID = proc

        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { throw CaptureError.deviceStartFailed(err) }
    }

    // MARK: - Device-change resilience
    //
    // A default input/output device change (AirPods connect/sleep, plugging in
    // headphones, switching output) leaves the existing tap delivering zero
    // buffers with no error. We listen for those changes and rebuild the tap +
    // aggregate into the same output file so capture continues seamlessly.

    private func installDeviceListeners() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceChange()
        }
        deviceListenerBlock = block
        for selector in [kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, rebuildQueue, block)
        }
    }

    private func removeDeviceListeners() {
        guard let block = deviceListenerBlock else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, rebuildQueue, block)
        }
        deviceListenerBlock = nil
    }

    /// Runs on `rebuildQueue` (the listener queue), so it's already serialized
    /// against itself; stopCapture also syncs on this queue before teardown.
    private func handleDeviceChange() {
        guard state.isRecording else { return }
        logger.warning("Default audio device changed — rebuilding tap to avoid silent capture")
        teardownCoreAudio()
        do {
            try buildCoreAudio()
        } catch {
            logger.error("Tap rebuild failed: \(error.localizedDescription)")
            lastError = "Audio device changed and capture could not be restarted."
        }
    }

    /// UID of the current default input device (microphone), or nil if none.
    private func defaultInputUID() -> String? {
        var devID = AudioDeviceID(0)
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &devID) == noErr,
              devID != 0 else { return nil }
        var uid: Unmanaged<CFString>?
        var usz = UInt32(MemoryLayout<CFString?>.size)
        var uaddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(devID, &uaddr, 0, nil, &usz, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private func failCleanup() {
        removeDeviceListeners()
        rebuildQueue.sync { teardownCoreAudio() }
        writeQueue.sync {}
        fileHandle?.closeFile()
        fileHandle = nil
        state = .error("capture setup failed")
    }

    func stopCapture() async {
        guard state == .recording else { return }
        removeDeviceListeners()            // no further rebuilds
        // Serialize teardown against any in-flight device-change rebuild.
        rebuildQueue.sync { teardownCoreAudio() }   // AudioDeviceStop → no more IOProc calls
        writeQueue.sync {}                 // drain any queued writes before closing
        fileHandle?.closeFile()
        fileHandle = nil
        state = .idle
        logger.info("Audio capture stopped. File: \(self.outputPath ?? "unknown")")
    }

    // MARK: - Teardown

    private func teardownCoreAudio() {
        if let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

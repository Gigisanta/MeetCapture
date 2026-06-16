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

    /// Actual sample rate the aggregate device delivered, read at setup time.
    /// On-disk PCM is mono Float32 at this rate.
    private(set) var currentSampleRate: Double = 48_000

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var fileHandle: FileHandle?
    /// Serial queue for disk writes. The IOProc runs on a realtime audio thread
    /// where blocking `write()` calls cause dropped samples (the truncated
    /// captures we saw). We copy each buffer and flush it here instead.
    private let writeQueue = DispatchQueue(label: "com.meetcapture.audiowrite", qos: .utility)
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

        // 1. Global system-audio tap (excludes nothing — capture the full mix)
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(desc, &tap)
        guard err == noErr else { failCleanup(); throw CaptureError.tapCreationFailed(err) }
        tapID = tap

        // 2. Private aggregate = system-audio tap + (if available) the mic.
        //    Adding the mic as a sub-device is what captures YOUR voice — the
        //    tap alone only hears the remote participants coming out of the
        //    speakers. If there's no input device, we fall back to tap-only.
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
        guard err == noErr else { failCleanup(); throw CaptureError.aggregateCreationFailed(err) }
        aggregateID = agg

        // Read the rate the aggregate actually settled on (mic clock may force
        // 44.1k). The transcriber resamples from exactly this.
        var rate = 0.0
        var rsz = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(agg, &rateAddr, 0, nil, &rsz, &rate) == noErr, rate > 0 {
            currentSampleRate = rate
        }
        logger.info("Aggregate rate: \(self.currentSampleRate) Hz, mic=\(!subDeviceList.isEmpty)")

        // 3. IOProc → sum all sub-streams (mic + system) to mono Float32, write.
        var proc: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { [weak self] _, inInputData, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            // All sub-streams share the same frame count per callback.
            var frames = 0
            for b in abl where b.mNumberChannels > 0 {
                frames = max(frames, Int(b.mDataByteSize) / (4 * Int(b.mNumberChannels)))
            }
            guard frames > 0 else { return }
            var mono = [Float](repeating: 0, count: frames)
            // Each sub-device contributes its OWN mono mix, summed at full level
            // (mic + system) so neither source is attenuated; clamp avoids clip.
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
            // ponytail: the array alloc + Data copy on the audio thread is
            // acceptable jitter for a transcription tap; blocking disk I/O stays
            // off the realtime thread via writeQueue (no dropped samples).
            let bytes = mono.withUnsafeBytes { Data($0) }
            self.writeQueue.async { try? self.fileHandle?.write(contentsOf: bytes) }
        }
        guard err == noErr, let proc else { failCleanup(); throw CaptureError.ioProcCreationFailed(err) }
        procID = proc

        err = AudioDeviceStart(agg, proc)
        guard err == noErr else { failCleanup(); throw CaptureError.deviceStartFailed(err) }

        state = .recording
        logger.info("Audio capture started (tap+mic) → \(outputPath)")
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
        teardownCoreAudio()
        writeQueue.sync {}
        fileHandle?.closeFile()
        fileHandle = nil
        state = .error("capture setup failed")
    }

    func stopCapture() async {
        guard state == .recording else { return }
        teardownCoreAudio()               // AudioDeviceStop → no more IOProc calls
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

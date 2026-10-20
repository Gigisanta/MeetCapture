// CoreAudioTap.swift
// One capture graph: process tap (targeted by PID, global fallback, or
// none in mic-only mode) + private aggregate device with the mic as
// sub-device + IOProc. Built and torn down on the caller's queue.

import AudioToolbox
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case ioProcCreationFailed(OSStatus)
    case deviceStartFailed(OSStatus)
    case resamplerInitFailed
    case alreadyRecording
    case startCancelled

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let s):
            return "No se pudo crear el tap de audio del sistema (OSStatus \(s)). Revisá Privacidad › Grabación de audio."
        case .aggregateCreationFailed(let s): return "No se pudo crear el dispositivo de captura (OSStatus \(s))."
        case .ioProcCreationFailed(let s): return "No se pudo instalar el callback de audio (OSStatus \(s))."
        case .deviceStartFailed(let s): return "No se pudo iniciar la captura (OSStatus \(s))."
        case .resamplerInitFailed: return "No se pudo inicializar el resampler."
        case .alreadyRecording: return "Ya hay una grabación en curso."
        case .startCancelled: return "La captura fue cancelada antes de comenzar."
        }
    }
}

struct TapConfiguration: Equatable, Sendable {
    var micOnly: Bool
    var inputDeviceUID: String?
}

final class CoreAudioTap {
    let strategy: String
    let tapInfo: String
    let sampleRate: Double
    let hasMic: Bool
    let micBufferIndex: Int?
    let tapBufferIndex: Int?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let logger = AppInfo.logger("CoreAudioTap")

    init(configuration: TapConfiguration) throws {
        var desc: CATapDescription?
        var strategy = "mic-only"
        if !configuration.micOnly {
            // Always the whole system mix. A tap targeted at the processes
            // using the mic misses calls whose audio plays elsewhere (Safari
            // renders in WebKit helpers, Teams 2 in its own process), which
            // left the call channel silent.
            let global = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            global.isPrivate = true
            var tap = AudioObjectID(kAudioObjectUnknown)
            let err = AudioHardwareCreateProcessTap(global, &tap)
            guard err == noErr else { throw CaptureError.tapCreationFailed(err) }
            tapID = tap
            desc = global
            strategy = "global"
        }
        self.strategy = strategy
        tapInfo = desc.map { "\(strategy) tap, uuid=\($0.uuid)" } ?? strategy

        let micUID = InputDevices.defaultInputUID(preferred: configuration.inputDeviceUID)
        hasMic = micUID != nil
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MeetCaptureTap",
            kAudioAggregateDeviceUIDKey as String: "meetcapture-tap-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: micUID.map { [[kAudioSubDeviceUIDKey as String: $0]] } ?? [],
        ]
        if let desc {
            aggregate[kAudioAggregateDeviceTapListKey as String] = [[kAudioSubTapUIDKey as String: desc.uuid.uuidString]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        let err = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard err == noErr else {
            if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
            throw CaptureError.aggregateCreationFailed(err)
        }
        aggregateID = agg

        // Physical input streams precede the process tap in the aggregate.
        let micInputBuffers = InputDevices.inputBufferCount(forUID: micUID)
        micBufferIndex = micInputBuffers > 0 ? 0 : nil
        tapBufferIndex = desc == nil ? nil : micInputBuffers

        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(agg, &addr, 0, nil, &size, &rate) != noErr || rate <= 0 { rate = 48_000 }
        sampleRate = rate
        logger.info("tap \(strategy, privacy: .public) rate=\(rate) mic=\(micUID != nil)")
    }

    /// Installs the IOProc and starts the device. `block` runs on the real-time thread.
    func start(_ block: @escaping AudioDeviceIOBlock) throws {
        var proc: AudioDeviceIOProcID?
        var err = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, nil, block)
        guard err == noErr, let proc else { throw CaptureError.ioProcCreationFailed(err) }
        procID = proc
        err = AudioDeviceStart(aggregateID, proc)
        guard err == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
            throw CaptureError.deviceStartFailed(err)
        }
    }

    func stop() {
        if let proc = procID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            procID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        destroyTap()
    }

    private func destroyTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { stop() }

}

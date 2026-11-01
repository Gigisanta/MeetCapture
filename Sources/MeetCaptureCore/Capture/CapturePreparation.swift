// Read-only provenance for the existing real-pipeline harness. A device name,
// an idle global mix, or a virtual transport is not proof of fixture routing.
// No audio graph, permission prompt, recorder or recognizer is started here.
import AudioToolbox
import CoreAudio
import CryptoKit
import Darwin
import Foundation

struct CapturePreparation: Encodable {
    struct FileIdentity: Encodable {
        let sha256: String
        let bytes: Int64
    }

    struct StreamFormat: Encodable {
        let id: UInt32
        let sampleRate: Double?
        let formatID: UInt32
        let formatFlags: UInt32
        let bytesPerFrame: UInt32
        let framesPerPacket: UInt32
        let bytesPerPacket: UInt32
        let channels: UInt32
        let bitsPerChannel: UInt32
    }

    struct Gain: Encodable {
        let element: UInt32
        /// not_exposed is distinct from an unreadable control or assumed unity.
        let state: String
        let scalar: Float?
    }

    struct Device: Encodable {
        let id: UInt32
        let uid: String?
        let name: String?
        let modelUID: String?
        let transportType: UInt32?
        let nominalSampleRate: Double?
        let inputStreams: [StreamFormat]?
        let outputStreams: [StreamFormat]?
        let inputGain: [Gain]
        let outputGain: [Gain]
    }

    struct ProcessMember: Encodable {
        let audioObjectID: UInt32
        let pid: Int32?
        let isRunningOutput: Bool?
        let outputDeviceIDs: [UInt32]?
    }

    struct Route: Encodable {
        let requestedInputUID: String?
        let defaultInputUID: String?
        let selectedInput: Device?
        let defaultOutput: Device?
        /// Connected clients, not a fixed/exhaustive membership of a global tap.
        let observedProcesses: [ProcessMember]?
        let readErrors: [String]
    }

    enum Blocker: String, Encodable {
        case unboundedGlobalTap = "unbounded_global_tap"
        case microphoneOnlyDiagnostic = "microphone_only_not_dual_capture"
        case microphoneNotFixtureBound = "microphone_source_not_fixture_bound"
        case inputUnavailable = "input_device_unavailable"
        case requestedInputFallback = "requested_input_fell_back"
        case corpusUnavailable = "corpus_identity_unavailable"
        case referenceUnavailable = "reference_identity_unavailable"
        case metadataIncomplete = "route_metadata_incomplete"
    }

    struct Blocked: LocalizedError {
        let reasons: [Blocker]
        var errorDescription: String? {
            "QA capture blocked: " + reasons.map(\.rawValue).joined(separator: ", ")
        }
    }

    let schema = "meetcapture.capture-preparation.v1"
    let observedAt: String
    let observationKind = "read_only_non_atomic_preflight"
    let corpus: FileIdentity?
    let reference: FileIdentity?
    let route: Route
    let tapStrategy: String
    let tapMembershipScope: String
    let plannedAggregateInputUIDs: [String]
    let plannedCaptureFormat: AudioFormatSidecar
    let micOnly: Bool
    let diarize: Bool
    let language: String
    let identityErrors: [String]
    let blockers: [Blocker]
    let status = "blocked"
    let tapCreated = false
    let captureStarted = false
    let transcriptionStarted = false

    init(source: URL, reference: URL?, configuration: TapConfiguration,
         diarize: Bool, language: String, route: Route) {
        observedAt = ISO8601.string(from: Date())
        self.route = route
        micOnly = configuration.micOnly
        self.diarize = diarize
        self.language = language
        tapStrategy = configuration.strategyName
        tapMembershipScope = configuration.micOnly ? "none" : "all_process_outputs_including_future_clients"
        plannedAggregateInputUIDs = route.selectedInput?.uid.map { [$0] } ?? []
        plannedCaptureFormat = .capture(tapStrategy: configuration.strategyName,
                                       tapInfo: "planned_only_no_tap_created")
        var errors: [String] = []
        corpus = Self.identify(source, maxBytes: 512 * 1_024 * 1_024)
        if corpus == nil { errors.append("corpus_unreadable_nonregular_changed_or_oversize") }
        self.reference = reference.flatMap { Self.identify($0, maxBytes: 4 * 1_024 * 1_024) }
        if self.reference == nil { errors.append("reference_missing_unreadable_nonregular_changed_or_oversize") }
        identityErrors = errors

        // The current capture graph has no fixture-bound microphone source and
        // its global tap admits future clients. Observed UIDs/gains/processes
        // are evidence, never an allowlist or permission to waive those gaps.
        var reasons: [Blocker] = [configuration.micOnly ? .microphoneOnlyDiagnostic : .unboundedGlobalTap,
                                   .microphoneNotFixtureBound]
        if route.selectedInput == nil { reasons.append(.inputUnavailable) }
        if let requested = configuration.inputDeviceUID,
           requested != route.selectedInput?.uid { reasons.append(.requestedInputFallback) }
        if corpus == nil { reasons.append(.corpusUnavailable) }
        if self.reference == nil { reasons.append(.referenceUnavailable) }
        if !route.readErrors.isEmpty { reasons.append(.metadataIncomplete) }
        blockers = reasons
    }

    /// The current topology cannot satisfy this admission contract. There is
    /// deliberately no environment switch, device-name waiver or legacy pass.
    func requireReproducibleInput() throws {
        throw Blocked(reasons: blockers)
    }

    /// Exclusive private publication preserves the first preflight observation.
    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fchmod(fd, mode_t(0o600)) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private static func identify(_ url: URL, maxBytes: Int64) -> FileIdentity? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= maxBytes else { return nil }
        do {
            var hash = SHA256()
            var count: Int64 = 0
            while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
                count += Int64(data.count)
                guard count <= maxBytes else { return nil }
                hash.update(data: data)
            }
            var after = stat()
            guard fstat(fd, &after) == 0, count == before.st_size,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                  before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { return nil }
            return FileIdentity(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes: count)
        } catch {
            return nil
        }
    }
}

/// Bounded Core Audio property reads only; it never creates a tap or changes a
/// default device, gain, routing, preferences or the installed application's state.
enum CaptureRouteReader {
    static func read(configuration: TapConfiguration) -> CapturePreparation.Route {
        var errors: [String] = []
        let system = AudioObjectID(kAudioObjectSystemObject)
        let inputID: UInt32? = scalar(system, kAudioHardwarePropertyDefaultInputDevice,
                                     initial: UInt32(0), label: "default_input", errors: &errors)
        let outputID: UInt32? = scalar(system, kAudioHardwarePropertyDefaultOutputDevice,
                                      initial: UInt32(0), label: "default_output", errors: &errors)
        let ids = objectList(system, kAudioHardwarePropertyDevices, limit: 512, label: "devices", errors: &errors)
        let selectedUID = InputDevices.defaultInputUID(preferred: configuration.inputDeviceUID)
        let selectedID = selectedUID.flatMap { uid in
            ids?.first { InputDevices.stringProperty($0, kAudioDevicePropertyDeviceUID) == uid }
        }
        let input = selectedID.map { device($0, label: "selected_input", errors: &errors) }
        let output = outputID.flatMap { $0 == kAudioObjectUnknown ? nil : device($0, label: "default_output", errors: &errors) }
        let processIDs = objectList(system, kAudioHardwarePropertyProcessObjectList, limit: 1_024,
                                    label: "process_list", errors: &errors)
        let processes = processIDs?.map { id -> CapturePreparation.ProcessMember in
            let pid: Int32? = scalar(id, kAudioProcessPropertyPID, initial: Int32(0), label: "process_pid", errors: &errors)
            let running: UInt32? = scalar(id, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0),
                                          label: "process_output_state", errors: &errors)
            let devices = objectList(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput,
                                     limit: 64, label: "process_output_devices", errors: &errors)
            return .init(audioObjectID: id, pid: pid, isRunningOutput: running.map { $0 != 0 }, outputDeviceIDs: devices)
        }
        if input == nil { errors.append("selected_input_unavailable") }
        if output == nil { errors.append("default_output_unavailable") }
        let defaultUID = inputID.flatMap { InputDevices.stringProperty($0, kAudioDevicePropertyDeviceUID) }
        if defaultUID == nil { errors.append("default_input_uid_unavailable") }
        return .init(requestedInputUID: configuration.inputDeviceUID, defaultInputUID: defaultUID,
                     selectedInput: input, defaultOutput: output, observedProcesses: processes,
                     readErrors: Array(Set(errors)).sorted())
    }

    private static func device(_ id: UInt32, label: String, errors: inout [String]) -> CapturePreparation.Device {
        let uid = InputDevices.stringProperty(id, kAudioDevicePropertyDeviceUID)
        let name = InputDevices.stringProperty(id, kAudioObjectPropertyName)
        let model = InputDevices.stringProperty(id, kAudioDevicePropertyModelUID)
        if uid == nil || name == nil || model == nil { errors.append(label + "_identity_unreadable") }
        let transport: UInt32? = scalar(id, kAudioDevicePropertyTransportType, initial: UInt32(0), label: label + "_transport", errors: &errors)
        let rate: Double? = scalar(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0), label: label + "_rate", errors: &errors)
        let finiteRate = rate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if finiteRate == nil { errors.append(label + "_rate_invalid") }
        let inputs = streams(id, scope: kAudioObjectPropertyScopeInput, label: label + "_input", errors: &errors)
        let outputs = streams(id, scope: kAudioObjectPropertyScopeOutput, label: label + "_output", errors: &errors)
        let inputGain = gains(id, scope: kAudioObjectPropertyScopeInput, streams: inputs, label: label + "_input", errors: &errors)
        let outputGain = gains(id, scope: kAudioObjectPropertyScopeOutput, streams: outputs, label: label + "_output", errors: &errors)
        return .init(id: id, uid: uid, name: name, modelUID: model, transportType: transport,
                     nominalSampleRate: finiteRate, inputStreams: inputs, outputStreams: outputs,
                     inputGain: inputGain, outputGain: outputGain)
    }

    private static func streams(_ id: UInt32, scope: AudioObjectPropertyScope, label: String,
                                errors: inout [String]) -> [CapturePreparation.StreamFormat]? {
        guard let ids = objectList(id, kAudioDevicePropertyStreams, scope: scope, limit: 64, label: label + "_streams", errors: &errors) else { return nil }
        return ids.compactMap { stream in
            guard let format: AudioStreamBasicDescription = scalar(stream, kAudioStreamPropertyVirtualFormat,
                initial: AudioStreamBasicDescription(), label: label + "_format", errors: &errors) else { return nil }
            let rate = format.mSampleRate.isFinite && format.mSampleRate > 0 ? format.mSampleRate : nil
            if rate == nil { errors.append(label + "_format_rate_invalid") }
            return .init(id: stream, sampleRate: rate, formatID: format.mFormatID, formatFlags: format.mFormatFlags,
                         bytesPerFrame: format.mBytesPerFrame, framesPerPacket: format.mFramesPerPacket,
                         bytesPerPacket: format.mBytesPerPacket, channels: format.mChannelsPerFrame,
                         bitsPerChannel: format.mBitsPerChannel)
        }
    }

    private static func gains(_ id: UInt32, scope: AudioObjectPropertyScope,
                              streams: [CapturePreparation.StreamFormat]?, label: String,
                              errors: inout [String]) -> [CapturePreparation.Gain] {
        let channels = streams?.reduce(UInt64(0)) { $0 + UInt64($1.channels) } ?? 0
        guard channels <= 32 else { errors.append(label + "_gain_channel_limit"); return [] }
        let elements = [UInt32(kAudioObjectPropertyElementMain)] + (channels > 0 ? Array(1...UInt32(channels)) : [])
        return elements.map { element in
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            guard AudioObjectHasProperty(id, &address) else { return .init(element: element, state: "not_exposed", scalar: nil) }
            let value: Float? = scalar(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element,
                                        initial: Float(0), label: label + "_gain", errors: &errors)
            guard let value, value.isFinite, (0...1).contains(value) else {
                errors.append(label + "_gain_unreadable_or_invalid")
                return .init(element: element, state: "unreadable", scalar: nil)
            }
            return .init(element: element, state: "observed", scalar: value)
        }
    }

    private static func scalar<T>(_ id: UInt32, _ selector: AudioObjectPropertySelector,
                                  scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                  element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                                  initial: T, label: String, errors: inout [String]) -> T? {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        let status = withUnsafeMutableBytes(of: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr, Int(size) == MemoryLayout<T>.size else { errors.append(label + "_read_failed"); return nil }
        return value
    }

    private static func objectList(_ id: UInt32, _ selector: AudioObjectPropertySelector,
                                   scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                   limit: Int, label: String, errors: inout [String]) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              Int(size) % MemoryLayout<UInt32>.size == 0, Int(size) / MemoryLayout<UInt32>.size <= limit else {
            errors.append(label + "_unreadable_or_limit"); return nil
        }
        if size == 0 { return [] }
        let count = Int(size) / MemoryLayout<UInt32>.size
        var values = [UInt32](repeating: 0, count: count)
        let status = values.withUnsafeMutableBytes { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr, Int(size) == count * MemoryLayout<UInt32>.size else {
            errors.append(label + "_changed_or_read_failed"); return nil
        }
        return values
    }
}

// AudioCapture.swift
// MeetCapture v5 — System + mic audio capture via Core Audio process tap.
//
// On-disk format (v5): Int16 16kHz stereo interleaved raw PCM.
//   L = system audio (remote participants), R = mic / silence.
//   Accompanied by `<path>.format.json` sidecar with full metadata.
//
// NOTE: Replaced ScreenCaptureKit (SCStream), which regressed on macOS
// 15+/26: SCStream.startCapture() succeeds but never delivers any
// sample-buffer callbacks (audio OR screen), with no error — confirmed
// reproducible with minimal textbook code signed under the granted
// identity. The Core Audio process-tap API (macOS 14.4+) captures the
// global system-audio mix reliably and does NOT require Screen Recording
// permission.
//
// Cambios v5 (Jul 2026):
//  - Salida stereo interleaved Int16 a 16kHz (L=system, R=mic/silence).
//    Un solo archivo raw PCM, no más sidecar _mic ignorado por el transcriber.
//  - Sidecar `<audio>.format.json` atómico con schema, sample_rate,
//    sample_format, channels, layout, tap_strategy.
//  - Backpressure real via DispatchSemaphore: máximo `kMaxPendingWrites`
//    chunks en cola; descarta con contador atómico si el consumidor no
//    da abasto. Sin bloqueo del IOProc.
//  - Resampler stateful (AVAudioConverter): fase continua entre buffers,
//    sin discontinuidades por reset por callback. Flush en stop.
//  - IOProc mínimo: copia acotada de buffers Float32, dispatch a cola
//    utility para mezcla → conversión → escritura.
//  - currentSampleRate reporta siempre 16kHz (formato de disco).
//  - Tap metadata indica targeted vs global en formato JSON.

import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import os.log

// MARK: - Constants

private let kTargetSampleRate: Double = 16_000
private let kHeadroom: Float = 0.75
private let kMaxPendingWrites: Int = 100
/// Max frames the IOProc will ever see from the tap (≈170ms @ 48kHz).
private let kMaxBufferFrames: Int = 8192
/// Max channels per buffer (stereo system + stereo mic).
private let kMaxChannels: Int = 2

// MARK: - Stateful Audio Resampler

/// Stateful mono wrapper around AVAudioConverter for Float32→Int16 downsampling.
/// System and microphone use separate instances and are interleaved after conversion.
final class AudioResampler: @unchecked Sendable {
  private final class InputProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var supplied = false
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
      lock.lock()
      defer { lock.unlock() }
      guard !supplied else {
        status.pointee = .noDataNow
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return buffer
    }
  }
  private let converter: AVAudioConverter
  private let inputBuffer: AVAudioPCMBuffer
  private let outputBuffer: AVAudioPCMBuffer

  let inputRate: Double
  let outputRate: Double
  let channels = 1

  init?(inputRate: Double, outputRate: Double, channels: Int) {
    guard channels == 1,
      let inputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: inputRate,
        channels: 1,
        interleaved: false),
      let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: outputRate,
        channels: 1,
        interleaved: false),
      let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
      let inputBuffer = AVAudioPCMBuffer(
        pcmFormat: inputFormat,
        frameCapacity: UInt32(kMaxBufferFrames)),
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: outputFormat,
        frameCapacity: UInt32(kMaxBufferFrames))
    else { return nil }

    self.inputRate = inputRate
    self.outputRate = outputRate
    self.converter = converter
    self.inputBuffer = inputBuffer
    self.outputBuffer = outputBuffer
  }

  func resample(interleaved: UnsafePointer<Float>, frameCount: Int) -> [Int16] {
    guard frameCount > 0, frameCount <= Int(inputBuffer.frameCapacity),
      let destination = inputBuffer.floatChannelData?.pointee
    else { return [] }

    inputBuffer.frameLength = UInt32(frameCount)
    destination.update(from: interleaved, count: frameCount)
    outputBuffer.frameLength = 0

    var error: NSError?
    let provider = InputProvider(buffer: inputBuffer)
    let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
      provider.next(status: inputStatus)
    }

    guard status != .error, outputBuffer.frameLength > 0,
      let source = outputBuffer.int16ChannelData?.pointee
    else { return [] }
    return Array(UnsafeBufferPointer(start: source, count: Int(outputBuffer.frameLength)))
  }

  func flush() -> [Int16] {
    outputBuffer.frameLength = 0
    var error: NSError?
    let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
      inputStatus.pointee = .endOfStream
      return nil
    }
    guard status != .error, outputBuffer.frameLength > 0,
      let source = outputBuffer.int16ChannelData?.pointee
    else { return [] }
    return Array(UnsafeBufferPointer(start: source, count: Int(outputBuffer.frameLength)))
  }

  func reset() {
    converter.reset()
    inputBuffer.frameLength = 0
    outputBuffer.frameLength = 0
  }
}

// MARK: - Capture Errors

enum CaptureError: LocalizedError {
  case fileCreationFailed(path: String, reason: String)
  case tapCreationFailed(OSStatus)
  case aggregateCreationFailed(OSStatus)
  case ioProcCreationFailed(OSStatus)
  case deviceStartFailed(OSStatus)
  case resamplerInitFailed

  var errorDescription: String? {
    switch self {
    case .fileCreationFailed(let path, let reason):
      return "Failed to create output file at '\(path)': \(reason)"
    case .tapCreationFailed(let s):
      return
        "Could not create system-audio tap (OSStatus \(s)). Grant Audio Recording access in System Settings."
    case .aggregateCreationFailed(let s):
      return "Could not create capture device (OSStatus \(s))."
    case .ioProcCreationFailed(let s):
      return "Could not install audio callback (OSStatus \(s))."
    case .deviceStartFailed(let s):
      return "Could not start audio capture (OSStatus \(s))."
    case .resamplerInitFailed:
      return "Could not initialize audio resampler."
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

// MARK: - Audio Format Metadata

/// Schema for the `<path>.format.json` sidecar.
private struct AudioFormatMetadata: Codable {
  let schema: String
  let sampleRate: Int
  let sampleFormat: String
  let channels: Int
  let layout: String
  let tapStrategy: String
  let tapInfo: String

  enum CodingKeys: String, CodingKey {
    case schema
    case sampleRate = "sample_rate"
    case sampleFormat = "sample_format"
    case channels
    case layout
    case tapStrategy = "tap_strategy"
    case tapInfo = "tap_info"
  }
}

// MARK: - Audio Capture Chunk

/// A bounded copy of audio data extracted from the IOProc.
/// Created in the realtime IOProc, consumed on the serial utility queue.
private struct AudioChunk {
  let sysData: [Float]  // interleaved system channels
  let sysFrames: Int
  let sysChannels: Int
  let micData: [Float]  // interleaved mic channels (empty if no mic)
  let micFrames: Int
  let micChannels: Int
}

// MARK: - AudioCaptureService

/// Captures a meeting's full audio — the system-audio mix (remote participants)
/// via a Core Audio process tap PLUS the local microphone (your own voice).
///
/// **Output format (v5):**
///   - Single 16kHz Int16 stereo interleaved raw PCM file.
///     L = system audio, R = mic (or silence if no mic input).
///   - `<path>.format.json` sidecar with full metadata.
///
/// **Tap strategy:** targeted by PID of active conferencing apps
/// (`CallDetector.activeCallProcessIDs()`), with global tap fallback.
///
/// **Resampler:** AVAudioConverter (stateful, anti-alias). Phase-continuous
/// across IOProc callbacks. Flushed on stop to drain residual.
///
/// **Backpressure:** DispatchSemaphore with `kMaxPendingWrites` permits.
/// IOProc acquires non-blocking; writeQueue releases after write. Drops
/// tracked atomically.
final class AudioCaptureService: NSObject, @unchecked Sendable {
  @Published private(set) var state: CaptureState = .idle
  @Published private(set) var lastError: String?

  /// Optional reference to CallDetector for retrieving PIDs of active
  /// conferencing apps when building a targeted process tap.
  weak var callDetector: CallDetector?

  // MARK: - Core Audio objects

  private var tapID = AudioObjectID(kAudioObjectUnknown)
  private var tapDesc: CATapDescription?
  private var aggregateID = AudioObjectID(kAudioObjectUnknown)
  private var procID: AudioDeviceIOProcID?

  // MARK: - File IO

  private var fileHandle: FileHandle?
  private(set) var currentOutputPath: String?
  private var _tapStrategy: String = "unknown"

  // MARK: - Resampler

  private var systemResampler: AudioResampler?
  private var micResampler: AudioResampler?
  private var liveInputRate: Double = 48_000

  // MARK: - Sample rate

  /// Returns the on-disk output sample rate (always 16000).
  var currentSampleRate: Double { kTargetSampleRate }

  // MARK: - Concurrency

  private let rebuildQueue = DispatchQueue(label: "com.meetcapture.rebuild")
  private let writeQueue = DispatchQueue(label: "com.meetcapture.audiowrite", qos: .utility)
  private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

  /// Real backpressure: bounded semaphore for writeQueue.
  private let writeSemaphore = DispatchSemaphore(value: kMaxPendingWrites)

  /// Drop counters (atomic, accessed from IOProc + writeQueue + diagnostics).
  private let countLock = OSAllocatedUnfairLock()
  private var _totalDropped: Int = 0
  private var _totalWritten: Int = 0

  /// Total chunks dropped due to backpressure.
  var totalDroppedChunks: Int { countLock.withLock { _totalDropped } }
  /// Total chunks successfully enqueued for writing.
  var totalWrittenChunks: Int { countLock.withLock { _totalWritten } }

  // MARK: - Logger

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.meetcapture",
    category: "AudioCapture")

  override init() {
    super.init()
    logger.info(
      "AudioCaptureService v5 iniciado (stereo interleaved Int16, resampler stateful, backpressure real)"
    )
  }

  deinit {
    fileHandle?.closeFile()
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

  @discardableResult func ensurePermission() -> Bool {
    if checkPermission() { return true }
    requestPermission()
    return false
  }

  func openPrivacySettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    {
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
    _tapStrategy = "unknown"

    // Ensure directory (0700) and create output file (0600)
    let dir = (outputPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: dir, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])

    guard
      FileManager.default.createFile(
        atPath: outputPath, contents: nil,
        attributes: [.posixPermissions: 0o600])
    else {
      throw CaptureError.fileCreationFailed(
        path: outputPath,
        reason: "Could not create file")
    }
    guard let fh = FileHandle(forWritingAtPath: outputPath) else {
      throw CaptureError.fileCreationFailed(
        path: outputPath,
        reason: "Could not open file for writing")
    }
    fileHandle = fh
    currentOutputPath = outputPath

    // Create the aggregate + tap + IOProc
    do {
      try buildCoreAudio()
    } catch {
      teardownCoreAudio()
      fileHandle?.closeFile()
      fileHandle = nil
      throw error
    }

    // Write format metadata (atomic sidecar)
    writeFormatJSON(outputPath: outputPath)

    installDeviceListeners()
    state = .recording
    logger.info("Capture iniciado: stereo Int16 16kHz → \(outputPath)")
  }

  /// Build the tap + aggregate + IOProc and start.
  /// Targeted PID tap → fallback global; aggregate with mic sub-device.
  /// IOProc copies buffers minimally, dispatches to utility queue.
  private func buildCoreAudio() throws {
    // 1. Tap — targeted by PID (active call apps), fallback to global
    let processIDs: [AudioObjectID] = callDetector?.activeCallProcessIDs() ?? []
    let (tap, desc): (AudioObjectID, CATapDescription)
    if !processIDs.isEmpty {
      let result = try createTap(processIDs: processIDs, fallbackToGlobal: true)
      tap = result.0
      desc = result.1
      _tapStrategy = "targeted"
    } else {
      let result = try createGlobalTapWithDesc()
      tap = result.0
      desc = result.1
      _tapStrategy = "global"
    }
    tapID = tap
    tapDesc = desc

    // 2. Private aggregate = system tap + mic (if available)
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
      kAudioAggregateDeviceTapListKey as String: [
        [kAudioSubTapUIDKey as String: desc.uuid.uuidString]
      ],
    ]
    var agg = AudioObjectID(kAudioObjectUnknown)
    var err = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
    guard err == noErr else { throw CaptureError.aggregateCreationFailed(err) }
    aggregateID = agg

    // Read the aggregate's actual sample rate
    var rate = 0.0
    var rsz = UInt32(MemoryLayout<Double>.size)
    var rateAddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyNominalSampleRate,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    if AudioObjectGetPropertyData(agg, &rateAddr, 0, nil, &rsz, &rate) == noErr, rate > 0 {
      liveInputRate = rate
    }
    logger.info(
      "Core Audio: live=\(self.liveInputRate)Hz target=\(kTargetSampleRate)Hz mic=\(subDeviceList.count>0) strategy=\(self._tapStrategy)"
    )

    // 3. IOProc — minimal copy + semaphore + dispatch to utility queue
    let inputRate = liveInputRate
    let outRate = kTargetSampleRate
    // Create independent mono resamplers on the input's actual rate.
    guard
      let system = AudioResampler(inputRate: inputRate, outputRate: outRate, channels: 1),
      let microphone = AudioResampler(inputRate: inputRate, outputRate: outRate, channels: 1)
    else {
      throw CaptureError.resamplerInitFailed
    }
    systemResampler = system
    micResampler = microphone

    var proc: AudioDeviceIOProcID?
    err = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) {
      [weak self] _, inInputData, _, _, _ in
      guard let self else { return }
      let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
      let nBuf = abl.count
      guard nBuf > 0 else { return }

      // Buffer 0 = tap (system audio), Buffer 1 = mic (if present)
      let sysCh = Int(abl[0].mNumberChannels)
      let sysBytes = Int(abl[0].mDataByteSize)
      let sysFrames = sysBytes / (MemoryLayout<Float>.size * max(sysCh, 1))
      guard sysFrames > 0, sysFrames <= kMaxBufferFrames else { return }

      let hasMic = nBuf > 1 && abl[1].mDataByteSize > 0
      let micCh = hasMic ? Int(abl[1].mNumberChannels) : 0
      let micBytes = hasMic ? Int(abl[1].mDataByteSize) : 0
      let micFrames = hasMic ? micBytes / (MemoryLayout<Float>.size * max(micCh, 1)) : 0

      // --- Bounded copy of raw Float32 data ---
      // We allocate new arrays here (bounded by kMaxBufferFrames * kMaxChannels).
      // This is the ONLY allocation in the IOProc path and is bounded.
      let sysCount = sysFrames * sysCh
      let sysData: [Float] = {
        guard let ptr = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
          return []
        }
        return Array(UnsafeBufferPointer(start: ptr, count: sysCount))
      }()

      let micData: [Float]
      if hasMic, micFrames > 0 {
        let micCount = micFrames * micCh
        if let ptr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
          micData = Array(UnsafeBufferPointer(start: ptr, count: micCount))
        } else {
          micData = []
        }
      } else {
        micData = []
      }

      let chunk = AudioChunk(
        sysData: sysData, sysFrames: sysFrames, sysChannels: sysCh,
        micData: micData, micFrames: micFrames, micChannels: micCh
      )

      // --- Backpressure: non-blocking semaphore ---
      guard self.writeSemaphore.wait(timeout: .now()) == .success else {
        self.countLock.withLock { self._totalDropped += 1 }
        return
      }

      // --- Dispatch processing to utility queue ---
      self.writeQueue.async { [self] in
        defer { self.writeSemaphore.signal() }
        self.processAndWrite(chunk: chunk, inputRate: inputRate)
        self.countLock.withLock { self._totalWritten += 1 }
      }
    }

    guard err == noErr, let proc else { throw CaptureError.ioProcCreationFailed(err) }
    procID = proc

    err = AudioDeviceStart(agg, proc)
    guard err == noErr else { throw CaptureError.deviceStartFailed(err) }
  }

  // MARK: - Process & Write (utility queue)

  /// Called on writeQueue (serial). Mixes, interleaves, resamples, and writes.
  /// This is the only path that touches the resampler and file handle.
  private func processAndWrite(chunk: AudioChunk, inputRate: Double) {
    let sysFrames = chunk.sysFrames
    let sysCh = chunk.sysChannels
    guard sysFrames > 0 else { return }

    // 1. Mix system channels → mono with headroom
    var sysMono = [Float](repeating: 0, count: sysFrames)
    if sysCh > 0, !chunk.sysData.isEmpty {
      for f in 0..<sysFrames {
        var acc: Float = 0
        for c in 0..<min(sysCh, kMaxChannels) {
          acc += chunk.sysData[f * sysCh + c]
        }
        sysMono[f] = (acc / Float(sysCh)) * kHeadroom
      }
    }

    // 2. Mix mic channels → mono with headroom, or silence
    var micMono = [Float](repeating: 0, count: sysFrames)
    let hasMic = !chunk.micData.isEmpty && chunk.micFrames > 0 && chunk.micChannels > 0
    if hasMic {
      let micFrames = min(chunk.micFrames, sysFrames)
      let micCh = chunk.micChannels
      for f in 0..<micFrames {
        var acc: Float = 0
        for c in 0..<min(micCh, kMaxChannels) {
          acc += chunk.micData[f * micCh + c]
        }
        micMono[f] = (acc / Float(micCh)) * kHeadroom
      }
      // Remaining frames (if mic chunk was shorter) stay as silence
    }

    // 3. Resample each logical track independently.
    guard let systemResampler, let micResampler else {
      logger.error("Resampler nil en processAndWrite — dropping chunk")
      return
    }
    let system16 = sysMono.withUnsafeBufferPointer { buffer in
      systemResampler.resample(interleaved: buffer.baseAddress!, frameCount: sysFrames)
    }
    let microphone16 = micMono.withUnsafeBufferPointer { buffer in
      micResampler.resample(interleaved: buffer.baseAddress!, frameCount: sysFrames)
    }
    let outputFrames = min(system16.count, microphone16.count)
    guard outputFrames > 0 else { return }

    // 4. Preserve tracks in one file: L=system, R=mic.
    var out16 = [Int16](repeating: 0, count: outputFrames * 2)
    for frame in 0..<outputFrames {
      out16[frame * 2] = system16[frame]
      out16[frame * 2 + 1] = microphone16[frame]
    }

    // 5. Write to file
    let data = Data(bytes: out16, count: out16.count * MemoryLayout<Int16>.size)
    try? fileHandle?.write(contentsOf: data)
  }

  // MARK: - Format Metadata Sidecar

  /// Write `<path>.format.json` atomically with full audio format description.
  private func writeFormatJSON(outputPath: String) {
    let metadata = AudioFormatMetadata(
      schema: "meetcapture.audio.v1",
      sampleRate: Int(kTargetSampleRate),
      sampleFormat: "s16le",
      channels: 2,
      layout: "L=system,R=mic(silence)",
      tapStrategy: _tapStrategy,
      tapInfo: tapDesc.flatMap { d in
        return "\(_tapStrategy) tap, uuid=\(d.uuid)"
      } ?? _tapStrategy
    )
    let jsonPath = outputPath + ".format.json"
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      let data = try encoder.encode(metadata)
      try data.write(to: URL(fileURLWithPath: jsonPath), options: Data.WritingOptions.atomic)
      logger.info("Metadata escrita: \(jsonPath)")
    } catch {
      logger.warning("No se pudo escribir metadata: \(error.localizedDescription)")
    }
  }

  // MARK: - Targeted / Global Tap Creation

  /// Create a process tap targeted at the given Core Audio process object IDs.
  /// If `fallbackToGlobal` is true and targeted creation fails, falls back
  /// to a global stereo tap (excluding no processes).
  /// Returns both the AudioObjectID and the CATapDescription (needed for the
  /// aggregate's tap list).
  private func createTap(processIDs: [AudioObjectID], fallbackToGlobal: Bool) throws -> (
    AudioObjectID, CATapDescription
  ) {
    let desc = CATapDescription(stereoMixdownOfProcesses: processIDs)
    desc.isPrivate = true
    var tap = AudioObjectID(kAudioObjectUnknown)
    let err = AudioHardwareCreateProcessTap(desc, &tap)
    if err == noErr {
      logger.info("Tap dirigido creado con processIDs: \(processIDs)")
      return (tap, desc)
    }
    logger.warning(
      "Tap dirigido falló (OSStatus \(err)) con processIDs=\(processIDs), \(fallbackToGlobal ? "fallback a global" : "sin fallback")"
    )
    guard fallbackToGlobal else { throw CaptureError.tapCreationFailed(err) }
    return try createGlobalTapWithDesc()
  }

  /// Create a global stereo process tap and return (AudioObjectID, CATapDescription).
  private func createGlobalTapWithDesc() throws -> (AudioObjectID, CATapDescription) {
    let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
    desc.isPrivate = true
    var tap = AudioObjectID(kAudioObjectUnknown)
    let err = AudioHardwareCreateProcessTap(desc, &tap)
    guard err == noErr else { throw CaptureError.tapCreationFailed(err) }
    logger.info("Tap global creado (fallback)")
    return (tap, desc)
  }

  // MARK: - Device-change resilience

  private func installDeviceListeners() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.handleDeviceChange()
    }
    deviceListenerBlock = block
    for selector in [
      kAudioHardwarePropertyDefaultInputDevice,
      kAudioHardwarePropertyDefaultOutputDevice,
    ] {
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
    for selector in [
      kAudioHardwarePropertyDefaultInputDevice,
      kAudioHardwarePropertyDefaultOutputDevice,
    ] {
      var addr = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &addr, rebuildQueue, block)
    }
    deviceListenerBlock = nil
  }

  private func handleDeviceChange() {
    guard state.isRecording else { return }
    logger.warning("Dispositivo de audio cambiado — reconstruyendo tap")
    teardownCoreAudio()
    do {
      try buildCoreAudio()
    } catch {
      logger.error("Rebuild falló: \(error.localizedDescription)")
      lastError = "Audio device changed and capture could not be restarted."
    }
  }

  private func defaultInputUID() -> String? {
    var devID = AudioDeviceID(0)
    var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &devID) == noErr,
      devID != 0
    else { return nil }
    var uid: Unmanaged<CFString>?
    var usz = UInt32(MemoryLayout<CFString?>.size)
    var uaddr = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyDeviceUID,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(devID, &uaddr, 0, nil, &usz, &uid) == noErr else { return nil }
    return uid?.takeRetainedValue() as String?
  }

  // MARK: - Stop

  func stopCapture() async {
    guard state == .recording else { return }
    removeDeviceListeners()
    rebuildQueue.sync { teardownCoreAudio() }
    // Drain queued chunks, then flush both converters on their owning queue.
    writeQueue.sync {
      let systemTail = systemResampler?.flush() ?? []
      let micTail = micResampler?.flush() ?? []
      let frames = min(systemTail.count, micTail.count)
      if frames > 0 {
        var stereo = [Int16](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
          stereo[frame * 2] = systemTail[frame]
          stereo[frame * 2 + 1] = micTail[frame]
        }
        try? fileHandle?.write(
          contentsOf: Data(bytes: stereo, count: stereo.count * MemoryLayout<Int16>.size))
      }
      systemResampler?.reset()
      micResampler?.reset()
    }
    systemResampler = nil
    micResampler = nil
    fileHandle?.closeFile()
    fileHandle = nil
    state = .idle
    logger.info(
      "Capture detenido: \(self.currentOutputPath ?? "nil") (\(self._totalWritten) escritos, \(self._totalDropped) descartados)"
    )
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
    tapDesc = nil
  }
}

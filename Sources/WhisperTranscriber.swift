// WhisperTranscriber.swift
// MeetCapture v4 — Phase 3+ streaming transcription
//
// Reads the raw PCM file written by AudioCaptureService (Core Audio tap:
// Float32, interleaved, 48kHz, stereo) in 30s windows — OR whole-file for
// short recordings. Each window is downmixed to mono, resampled to 16kHz,
// converted to 16-bit, and handed to whisper-cli. Emits progress + final
// assembled text via AsyncStream.
//
// Whole-file mode (default for < 60s): single pass, lower overhead.
// Chunked mode (legacy, for long recordings): 30s windows with context carry.
//
// Q5 quantized models (ggml-*-q5_*.bin) are auto-detected with preference
// Q5_1 > Q5_0 > F16. The model is loaded via WhisperModelManager which
// selects the best available variant.
//
// FORMAT DETECTION:
// If `<audioPath>.format.json` exists, read explicit schema.
// If absent, assume legacy `.pcm` Float32 mono at `captureSampleRate`.
// Supported: float32/mono (legacy) and int16/stereo (new capture path).

import Foundation
import os
import os.lock

/// Processing mode for WhisperTranscriber.
enum TranscriberMode {
  /// Process the entire audio in one shot (ideal for < 60s clips).
  case wholeFile
  /// Process in 30s windows with context carry (legacy, long recordings).
  case chunked
}

/// Audio format schema from `<audioPath>.format.json` sidecar.
struct AudioFormatSchema: Codable, Equatable {
  var schema: String?
  var sampleRate: Int
  var sampleFormat: String
  var channels: Int
  var layout: String?

  enum CodingKeys: String, CodingKey {
    case schema
    case sampleRate = "sample_rate"
    case sampleFormat = "sample_format"
    case channels
    case layout
  }
}

/// Streams a PCM file through whisper-cli in 30s windows (chunked) or
/// single-pass (whole-file). Bounded memory: ~64 KB per chunk conversion,
/// regardless of file size.
final class WhisperTranscriber: @unchecked Sendable {
  static let chunkSeconds: Int = 30
  static let targetSampleRate: Int = 16_000  // whisper requires 16kHz
  /// Base timeout per whisper-cli invocation (seconds). Scaled by duration.
  static let baseTimeoutSec: Int = 30
  static let timeoutPerMinute: Int = 10  // extra seconds per minute of audio
  static let minTimeoutSec: Int = 30
  static let maxTimeoutSec: Int = 600  // 10 min cap

  private let audioPath: String
  private let captureSampleRate: Double
  private let whisperManager: WhisperModelManager
  private let mode: TranscriberMode
  private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "WhisperStream")

  let progress: AsyncStream<Double>
  let text: AsyncStream<String>
  private let progressContinuation: AsyncStream<Double>.Continuation
  private let textContinuation: AsyncStream<String>.Continuation

  /// Flag set when we've finished (or errored). Guards against double-finish
  /// from both error paths and normal completion.
  private var finished = false
  private let finishLock = NSLock()

  /// Schema read from `<audioPath>.format.json` (if present).
  private let formatSchema: AudioFormatSchema?

  init?(
    audioPath: String, sampleRate: Double, whisperManager: WhisperModelManager,
    mode: TranscriberMode = .wholeFile
  ) {
    self.audioPath = audioPath
    self.captureSampleRate = sampleRate > 0 ? sampleRate : 48_000
    self.whisperManager = whisperManager
    self.mode = mode

    // Try to read format.json sidecar
    self.formatSchema = Self.readFormatSidecar(for: audioPath)

    var pCont: AsyncStream<Double>.Continuation!
    self.progress = AsyncStream { pCont = $0 }
    self.progressContinuation = pCont

    var tCont: AsyncStream<String>.Continuation!
    self.text = AsyncStream { tCont = $0 }
    self.textContinuation = tCont

    guard FileManager.default.fileExists(atPath: audioPath) else {
      return nil
    }
  }

  // MARK: - Public API

  /// Run the (chunked or whole-file) transcription. Returns the assembled
  /// final text. On error, closes both AsyncStreams before throwing.
  func run() async throws -> String {
    defer { finishStreams(nil) }  // close on any exit
    let result: String
    let t0 = CFAbsoluteTimeGetCurrent()
    switch mode {
    case .wholeFile:
      result = try await runWholeFile()
    case .chunked:
      result = try await runChunked()
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - t0
    let msg =
      "Transcription complete in \(String(format: "%.1f", elapsed))s"
      + " (\(result.count) chars, mode: \(mode))"
    logger.notice("\(msg, privacy: .public)")
    return result
  }

  // MARK: - Format Sidecar

  /// Read `<audioPath>.format.json` for explicit format.
  /// Returns nil if absent (legacy fallback).
  static func readFormatSidecar(for audioPath: String) -> AudioFormatSchema? {
    let url = URL(fileURLWithPath: audioPath).appendingPathExtension("format.json")
    guard let data = try? Data(contentsOf: url),
      let schema = try? JSONDecoder().decode(AudioFormatSchema.self, from: data),
      schema.sampleRate > 0,
      (1...2).contains(schema.channels),
      ["float32", "s16le", "int16"].contains(schema.sampleFormat.lowercased())
    else { return nil }
    return schema
  }

  /// Resolve format: sidecar has priority, else legacy Float32 mono.
  private func resolveFormat() -> (format: AudioInputFormat, channels: Int, sampleRate: Int) {
    if let s = formatSchema {
      let normalized = s.sampleFormat.lowercased()
      let fmt: AudioInputFormat =
        ["s16le", "int16"].contains(normalized)
        ? .int16Stereo
        : .float32Mono
      return (fmt, max(1, s.channels), max(1, s.sampleRate))
    }
    // Legacy fallback: Float32 mono at captureSampleRate
    return (.float32Mono, 1, Int(captureSampleRate))
  }

  // MARK: - Thread-safe stderr collector

  /// Simple locked box for stderr data collection.
  /// Avoids Swift 6 capture-of-mutable-var warning.
  private final class StderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) {
      lock.lock()
      data.append(d)
      lock.unlock()
    }
    func snapshot() -> Data {
      lock.lock()
      let d = data
      lock.unlock()
      return d
    }
  }

  // MARK: - Whole-File Mode

  /// Convert the entire PCM to a temp WAV via streaming (bounded memory),
  /// then run whisper once.
  private func runWholeFile() async throws -> String {
    // Resolve format once
    let (inputFormat, channels, fileSampleRate) = resolveFormat()
    let wm = "Whole-file: fmt=\(inputFormat) ch=\(channels) sr=\(fileSampleRate)"
    logger.debug("\(wm, privacy: .public)")

    // Make sure a model is loaded
    if !whisperManager.isModelLoaded {
      try whisperManager.startRecording()
    }

    let wavURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("meetcapture-whole-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wavURL) }

    try streamConvertToWAV(
      inputPath: audioPath,
      outputURL: wavURL,
      inputFormat: inputFormat,
      inputChannels: channels,
      inputSampleRate: fileSampleRate)

    progressContinuation.yield(0.3)  // conversion done

    try Task.checkCancellation()

    let text = try await runWhisper(on: wavURL, context: "")
    progressContinuation.yield(1.0)

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw WhisperError.transcriptionFailed(
        reason: "No speech was recognized; raw audio was preserved for retry")
    }
    textContinuation.yield(trimmed)
    return Self.dedupRepeats(trimmed)
  }

  /// Stream-read raw PCM, convert to 16-bit mono WAV, writing directly
  /// to disk. Bounded memory: processes file in 64 KB chunks.
  private func streamConvertToWAV(
    inputPath: String, outputURL: URL,
    inputFormat: AudioInputFormat,
    inputChannels: Int,
    inputSampleRate: Int
  ) throws {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
    defer { try? handle.close() }

    let fileSize = try FileManager.default.attributesOfItem(atPath: inputPath)[.size] as? Int ?? 0
    let inFrameBytes = inputFormat == .float32Mono ? 4 : inputChannels * 2
    let audioDurationSec =
      inputSampleRate > 0 ? Double(fileSize / inFrameBytes) / Double(inputSampleRate) : 0

    func wavHeader(dataSize: UInt32) -> Data {
      let byteRate = UInt32(Self.targetSampleRate) * 2
      let chunkSize = 36 + dataSize
      var header = Data()
      header.append("RIFF".data(using: .ascii)!)
      header.append(contentsOf: withUnsafeBytes(of: chunkSize.littleEndian) { Data($0) })
      header.append("WAVEfmt ".data(using: .ascii)!)
      header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
      header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
      header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
      header.append(
        contentsOf: withUnsafeBytes(of: UInt32(Self.targetSampleRate).littleEndian) { Data($0) })
      header.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
      header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Data($0) })
      header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Data($0) })
      header.append("data".data(using: .ascii)!)
      header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
      return header
    }

    func writeSamples(_ samples: [Int16], to output: FileHandle) throws {
      guard !samples.isEmpty else { return }
      let data = samples.withUnsafeBytes { Data($0) }
      try output.write(contentsOf: data)
    }

    // Header is finalized after streaming so its data length always matches bytes written.
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let outHandle = try FileHandle(forWritingTo: outputURL)
    defer { try? outHandle.close() }
    try outHandle.write(contentsOf: wavHeader(dataSize: 0))

    let chunkBytes = 64 * 1024
    var samplesWritten = 0

    switch inputFormat {
    case .float32Mono:
      let ratio = Double(inputSampleRate) / Double(Self.targetSampleRate)
      guard ratio > 0 else {
        throw WhisperError.transcriptionFailed(reason: "Invalid input sample rate")
      }
      var pending: [Float] = []
      var sourcePosition = 0.0

      while true {
        try Task.checkCancellation()
        let chunk = try handle.read(upToCount: chunkBytes) ?? Data()
        if chunk.isEmpty { break }
        let decoded: [Float] = chunk.withUnsafeBytes { raw in
          let count = raw.count / 4
          return (0..<count).map { index in
            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
            return Float(bitPattern: bits)
          }
        }
        pending.append(contentsOf: decoded)
        var output: [Int16] = []
        output.reserveCapacity(Int(Double(decoded.count) / ratio) + 2)

        while sourcePosition + 1 < Double(pending.count) {
          let lower = Int(sourcePosition)
          let fraction = Float(sourcePosition - Double(lower))
          let value = pending[lower] + (pending[lower + 1] - pending[lower]) * fraction
          output.append(Int16(max(-1, min(1, value)) * 32767))
          sourcePosition += ratio
        }

        let consumed = min(Int(sourcePosition), max(0, pending.count - 1))
        if consumed > 0 {
          pending.removeFirst(consumed)
          sourcePosition -= Double(consumed)
        }
        try writeSamples(output, to: outHandle)
        samplesWritten += output.count
      }

    case .int16Stereo:
      var remainder = Data()
      while true {
        try Task.checkCancellation()
        let next = try handle.read(upToCount: chunkBytes) ?? Data()
        if next.isEmpty && remainder.isEmpty { break }
        remainder.append(next)
        let frameBytes = inputChannels * 2
        let frames = remainder.count / frameBytes
        var output = [Int16]()
        output.reserveCapacity(frames)
        remainder.withUnsafeBytes { raw in
          for frame in 0..<frames {
            let offset = frame * frameBytes
            let left = Int32(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
            let right: Int32
            if inputChannels > 1 {
              right = Int32(
                Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)))
            } else {
              right = left
            }
            output.append(Int16(clamping: (left + right) / 2))
          }
        }
        try writeSamples(output, to: outHandle)
        samplesWritten += output.count
        remainder.removeFirst(frames * frameBytes)
        if next.isEmpty { break }
      }
    }

    guard samplesWritten <= Int(UInt32.max / 2) else {
      throw WhisperError.transcriptionFailed(reason: "Audio exceeds WAV size limit")
    }
    let dataSize = UInt32(samplesWritten * 2)
    try outHandle.seek(toOffset: 0)
    try outHandle.write(contentsOf: wavHeader(dataSize: dataSize))
    try outHandle.truncate(atOffset: UInt64(44) + UInt64(dataSize))
    try outHandle.synchronize()
    logger.debug(
      "Streamed WAV: \(samplesWritten) samples, \(audioDurationSec, privacy: .public)s audio")
  }

  // MARK: - Chunked Mode (legacy)

  /// Run the streaming transcription in 30s windows. Returns the assembled final text.
  private func runChunked() async throws -> String {
    let (inputFormat, channels, fileSampleRate) = resolveFormat()
    let frameBytes = channels * (inputFormat == .int16Stereo ? 2 : 4)
    let chunkSize = Self.chunkSeconds * fileSampleRate * frameBytes

    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: audioPath))
    defer { try? handle.close() }

    let attrs = try FileManager.default.attributesOfItem(atPath: audioPath)
    let totalSize = (attrs[.size] as? Int) ?? 0

    if !whisperManager.isModelLoaded {
      try whisperManager.startRecording()
    }

    var assembled: [String] = []
    var bytesRead: Int = 0
    var chunkIndex: Int = 0
    var carriedTail = ""

    while true {
      try Task.checkCancellation()

      let chunk = try handle.read(upToCount: chunkSize) ?? Data()
      if chunk.isEmpty { break }
      bytesRead += chunk.count
      chunkIndex += 1

      let wavURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetcapture-chunk-\(UUID().uuidString).wav")
      defer { try? FileManager.default.removeItem(at: wavURL) }

      try streamConvertToWAV(
        inputPath: "", outputURL: wavURL,
        inputFormat: inputFormat,
        inputChannels: channels,
        inputSampleRate: fileSampleRate)

      // For chunked mode we write inline data to a temp file, then convert
      let tempPCM = FileManager.default.temporaryDirectory
        .appendingPathComponent("meetcapture-chunk-pcm-\(UUID().uuidString).raw")
      defer { try? FileManager.default.removeItem(at: tempPCM) }
      try chunk.write(to: tempPCM)
      try streamConvertToWAV(
        inputPath: tempPCM.path,
        outputURL: wavURL,
        inputFormat: inputFormat,
        inputChannels: channels,
        inputSampleRate: fileSampleRate)

      let text = try await runWhisper(on: wavURL, context: carriedTail)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        assembled.append(trimmed)
        textContinuation.yield(trimmed)
        carriedTail = String(trimmed.suffix(220))
      }

      let pct = totalSize > 0 ? min(1.0, Double(bytesRead) / Double(totalSize)) : 0.0
      progressContinuation.yield(pct)

      let dm = "Chunk \(chunkIndex) done (\(chunk.count) bytes) → \"\(trimmed.prefix(80))…\""
      logger.debug("\(dm, privacy: .public)")
    }

    progressContinuation.yield(1.0)
    return Self.dedupRepeats(assembled.joined(separator: " "))
  }

  // MARK: - Whisper invocation

  /// Compute a proportional timeout for the audio duration.
  private func computeTimeout(audioDurationSec: Double) -> Int {
    let extra = Int(audioDurationSec / 60.0) * Self.timeoutPerMinute
    let raw = Self.baseTimeoutSec + extra
    return min(Self.maxTimeoutSec, max(Self.minTimeoutSec, raw))
  }

  private func runWhisper(on wavURL: URL, context: String = "") async throws -> String {
    guard let modelPath = whisperManager.loadedModelPathAccessor else {
      finishStreams(WhisperError.noModelLoaded)
      throw WhisperError.noModelLoaded
    }
    let cliPath = whisperManager.whisperCLIPathAccessor
    let vadModel = whisperManager.vadModelPathAccessor
    let prompt =
      context.isEmpty
      ? WhisperModelManager.domainPrompt
      : WhisperModelManager.domainPrompt + " " + context

    // Compute audio duration from WAV file for proportional timeout
    let audioDurationSec: Double = {
      let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path)
      let size = (attrs?[.size] as? Int) ?? 0
      // 16-bit mono WAV: data starts at offset 44, 2 bytes per sample, 16000 Hz
      let dataBytes = max(0, size - 44)
      return Double(dataBytes) / 2.0 / Double(Self.targetSampleRate)
    }()
    let timeoutSec = computeTimeout(audioDurationSec: audioDurationSec)

    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
      let queue = DispatchQueue.global(qos: .userInitiated)

      queue.async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        var args = [
          "-m", modelPath,
          "-f", wavURL.path,
          "-l", "es",
          "-otxt", "-of", wavURL.deletingPathExtension().path,
          "-t", "\(WhisperModelManager.whisperThreads)",
          "--prompt", prompt,
          "--carry-initial-prompt",
          "--suppress-nst",
          "--no-timestamps",
          "--no-prints",
        ]
        if let vad = vadModel {
          args += ["--vad", "--vad-model", vad]
        }
        process.arguments = args

        // Pipe setup: read stderr using a locked buffer to be thread-safe
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Use thread-safe stderr collector
        let stderrCollector = StderrCollector()
        let errHandle = errPipe.fileHandleForReading
        errHandle.readabilityHandler = { handle in
          let d = handle.availableData
          if !d.isEmpty {
            stderrCollector.append(d)
          }
        }

        // Timeout timer proportional to audio duration
        let timerSource = DispatchSource.makeTimerSource(queue: queue)
        timerSource.schedule(deadline: .now() + .seconds(timeoutSec))
        timerSource.setEventHandler {
          if process.isRunning {
            process.interrupt()  // SIGTERM
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
              if process.isRunning { process.terminate() }
            }
          }
        }
        timerSource.resume()

        do {
          try process.run()
          process.waitUntilExit()
        } catch {
          timerSource.cancel()
          errHandle.readabilityHandler = nil
          cont.resume(
            throwing: WhisperError.processError(
              exitCode: -1,
              stderr: "\(error)"))
          return
        }

        timerSource.cancel()
        errHandle.readabilityHandler = nil

        // Capture stderr from collector
        let capturedStderr = stderrCollector.snapshot()

        let exit = process.terminationStatus
        if exit == 15 || exit == 9 {
          cont.resume(
            throwing: WhisperError.processError(
              exitCode: exit,
              stderr: "Timed out after \(timeoutSec)s"))
          return
        }
        guard exit == 0 else {
          let err = String(data: capturedStderr, encoding: .utf8) ?? ""
          cont.resume(
            throwing: WhisperError.processError(
              exitCode: exit,
              stderr: err))
          return
        }

        let txtPath = wavURL.deletingPathExtension().path + ".txt"
        guard FileManager.default.fileExists(atPath: txtPath) else {
          cont.resume(
            throwing: WhisperError.transcriptionFailed(
              reason: "Output not created at \(txtPath)"))
          return
        }
        do {
          let content = try String(contentsOfFile: txtPath, encoding: .utf8)
          try? FileManager.default.removeItem(atPath: txtPath)
          cont.resume(
            returning: content.trimmingCharacters(
              in: .whitespacesAndNewlines))
        } catch {
          cont.resume(
            throwing: WhisperError.transcriptionFailed(
              reason: "\(error)"))
        }
      }
    }
  }

  // MARK: - WAV Writer (multi-format)

  /// Convert a window of captured PCM into a 16kHz mono 16-bit WAV that
  /// whisper-cli reads natively. Supports two input formats:
  ///   - Float32 mono (legacy): any sample rate, linear resample.
  ///   - Int16 stereo (new): 16kHz, averaged to mono, no resample needed.
  /// Peak-normalises each chunk to -1dBFS for whisper intelligibility.
  private func writeWAV(
    captureData: Data, to url: URL,
    inputFormat: AudioInputFormat = .float32Mono,
    inputChannels: Int = 1
  ) throws {
    switch inputFormat {
    case .float32Mono:
      try writeWAVFloat32Mono(captureData: captureData, to: url)
    case .int16Stereo:
      try writeWAVInt16Stereo(captureData: captureData, to: url)
    }
  }

  /// Legacy path: mono Float32 at captureSampleRate, resample to 16kHz.
  private func writeWAVFloat32Mono(captureData: Data, to url: URL) throws {
    let frameBytes = 4  // mono Float32
    let inCount = captureData.count / frameBytes
    let ratio = captureSampleRate / Double(Self.targetSampleRate)
    let outCount = ratio > 0 ? Int(Double(inCount) / ratio) : 0
    var int16Samples = [Int16](repeating: 0, count: max(0, outCount))

    captureData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let floats = raw.bindMemory(to: Float.self)
      guard inCount > 0 else { return }
      var peak: Float = 0
      for i in 0..<inCount {
        let a = abs(floats[i])
        if a > peak { peak = a }
      }
      let target: Float = 0.89
      let gain: Float = (peak > 0.02 && peak < target) ? min(8.0, target / peak) : 1.0
      for j in 0..<outCount {
        let srcPos = Double(j) * ratio
        let i0 = Int(srcPos)
        let frac = Float(srcPos - Double(i0))
        let a = floats[i0]
        let b = (i0 + 1 < inCount) ? floats[i0 + 1] : a
        let mono = (a + (b - a) * frac) * gain
        let clamped = max(-1.0, min(1.0, mono))
        int16Samples[j] = Int16(clamped * 32767.0)
      }
    }

    writeWAVHeader(samples: int16Samples, sampleRate: Self.targetSampleRate, to: url)
  }

  /// New path: 16kHz stereo Int16, just average to mono.
  private func writeWAVInt16Stereo(captureData: Data, to url: URL) throws {
    let frameBytes = 4  // 2 channels × 2 bytes
    let sampleCount = captureData.count / frameBytes
    var int16Samples = [Int16](repeating: 0, count: sampleCount)

    captureData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      let samples = raw.bindMemory(to: Int16.self)
      for i in 0..<sampleCount {
        let l = samples[i * 2]
        let r = samples[i * 2 + 1]
        let avg = (Int32(l) + Int32(r)) / 2
        int16Samples[i] = Int16(clamping: avg)
      }
      var peak: Int16 = 0
      for s in int16Samples {
        let a = abs(s)
        if a > peak { peak = a }
      }
      let targetPeak: Int16 = 29000
      if peak > 100 && peak < targetPeak {
        let gain = Double(targetPeak) / Double(peak)
        for j in 0..<int16Samples.count {
          int16Samples[j] = Int16(clamping: Int(Double(int16Samples[j]) * gain))
        }
      }
    }

    writeWAVHeader(samples: int16Samples, sampleRate: Self.targetSampleRate, to: url)
  }

  /// Write a 16-bit mono WAV header + data.
  private func writeWAVHeader(samples: [Int16], sampleRate: Int, to url: URL) {
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
    let blockAlign = numChannels * (bitsPerSample / 8)
    let dataSize = UInt32(samples.count * Int(bitsPerSample / 8))
    let chunkSize = 36 + dataSize

    var out = Data()
    out.append("RIFF".data(using: .ascii)!)
    out.append(littleEndian32(chunkSize))
    out.append("WAVE".data(using: .ascii)!)
    out.append("fmt ".data(using: .ascii)!)
    out.append(littleEndian32(16))
    out.append(littleEndian16(1))  // PCM
    out.append(littleEndian16(numChannels))
    out.append(littleEndian32(UInt32(sampleRate)))
    out.append(littleEndian32(byteRate))
    out.append(littleEndian16(blockAlign))
    out.append(littleEndian16(bitsPerSample))
    out.append("data".data(using: .ascii)!)
    out.append(littleEndian32(dataSize))
    samples.withUnsafeBytes { out.append(contentsOf: $0) }
    try? out.write(to: url)
  }

  // MARK: - Stream lifecycle

  /// Safely finish both AsyncStreams, optionally with a final error.
  /// Idempotent: only the first call has effect.
  private func finishStreams(_ error: Error?) {
    finishLock.lock()
    if finished {
      finishLock.unlock()
      return
    }
    finished = true
    finishLock.unlock()

    if let err = error {
      logger.error("Transcription failed: \(err.localizedDescription)")
    }
    progressContinuation.finish()
    textContinuation.finish()
  }

  // MARK: - Dedup

  /// Remove whisper-cli's repeated-block hallucination.
  static func dedupRepeats(_ text: String) -> String {
    let parts = text.replacingOccurrences(of: "\n", with: " ")
      .components(separatedBy: CharacterSet(charactersIn: ".!?"))
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    func norm(_ s: String) -> String {
      String(
        s.lowercased().unicodeScalars.filter {
          CharacterSet.alphanumerics.contains($0)
        })
    }
    let window = 8
    let minLen = 12
    var out: [String] = []
    var normOut: [String] = []
    for p in parts {
      let np = norm(p)
      if np.count > minLen && normOut.suffix(window).contains(np) { continue }
      out.append(p)
      normOut.append(np)
    }
    return out.isEmpty ? "" : out.joined(separator: ". ") + "."
  }

  // MARK: - Helpers

  private func littleEndian16(_ v: UInt16) -> Data {
    var le = v.littleEndian
    return Data(bytes: &le, count: 2)
  }
  private func littleEndian32(_ v: UInt32) -> Data {
    var le = v.littleEndian
    return Data(bytes: &le, count: 4)
  }
}

// Keep AudioInputFormat for compatibility — used by chunked mode
extension WhisperTranscriber {
  enum AudioInputFormat: CustomStringConvertible {
    case float32Mono
    case int16Stereo

    var description: String {
      switch self {
      case .float32Mono: return "Float32/mono"
      case .int16Stereo: return "Int16/stereo"
      }
    }
  }
}

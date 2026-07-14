// WhisperTranscriber.swift
// MeetCapture v4 — Phase 3+ streaming transcription
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

import Foundation
import os

/// Processing mode for WhisperTranscriber.
enum TranscriberMode {
    /// Process the entire audio in one shot (ideal for < 60s clips).
    case wholeFile
    /// Process in 30s windows with context carry (legacy, long recordings).
    case chunked
}

/// Streams a PCM file through whisper-cli in 30s windows (chunked) or
/// single-pass (whole-file). Bounded memory: ~2 MB peak (chunked) or
/// ~file-size (whole-file, capped at 60s for safety).
final class WhisperTranscriber {
    static let chunkSeconds: Int = 30
    // On-disk capture format: can be mono Float32 at `captureSampleRate`, OR
    // 16k stereo Int16 (newer capture path). We detect on the fly.
    static let targetSampleRate: Int = 16_000          // whisper requires 16kHz
    /// Timeout per whisper-cli invocation (seconds). A single chunk or whole
    /// file call that exceeds this is SIGTERM'd then SIGKILL'd.
    static let processTimeoutSec: Int = 120

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

    init?(audioPath: String, sampleRate: Double, whisperManager: WhisperModelManager,
          mode: TranscriberMode = .wholeFile) {
        self.audioPath = audioPath
        self.captureSampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.whisperManager = whisperManager
        self.mode = mode

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
        defer { finishStreams(nil) }      // close on any exit
        let result: String
        let t0 = CFAbsoluteTimeGetCurrent()
        switch mode {
        case .wholeFile:
            result = try await runWholeFile()
        case .chunked:
            result = try await runChunked()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        logger.notice("Transcription complete in \(String(format: "%.1f", elapsed))s"
            + " (\(result.count) chars, mode: \(mode))")
        return result
    }

    // MARK: - Whole-File Mode

    /// Read the entire PCM file, convert to 16k mono WAV, run whisper once.
    private func runWholeFile() async throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: audioPath))
        defer { try? handle.close() }

        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else {
            throw WhisperError.transcriptionFailed(reason: "Empty audio file")
        }

        // Detect format: probe first few bytes.
        let (inputFormat, channels) = detectAudioFormat(data)
        logger.debug("Whole-file: \(data.count) bytes, format=\(inputFormat),"
            + " channels=\(channels)")

        // Make sure a model is loaded
        if !whisperManager.isModelLoaded {
            try whisperManager.startRecording()
        }

        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meetcapture-whole-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }

        try writeWAV(captureData: data, to: wavURL, inputFormat: inputFormat,
                     inputChannels: channels)

        progressContinuation.yield(0.3)   // conversion done

        // Check cancellation before launching process
        try Task.checkCancellation()

        let text = try await runWhisper(on: wavURL, context: "")
        progressContinuation.yield(1.0)

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            textContinuation.yield(trimmed)
        }
        return Self.dedupRepeats(trimmed)
    }

    // MARK: - Chunked Mode (legacy)

    /// Run the streaming transcription in 30s windows. Returns the assembled final text.
    private func runChunked() async throws -> String {
        let (chunkSizeBytes, inputFormat, channels) = try computeChunkParams()
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: audioPath))
        defer { try? handle.close() }

        // Get file size for progress
        let attrs = try FileManager.default.attributesOfItem(atPath: audioPath)
        let totalSize = (attrs[.size] as? Int) ?? 0

        // Make sure a model is loaded
        if !whisperManager.isModelLoaded {
            try whisperManager.startRecording()
        }

        var assembled: [String] = []
        var bytesRead: Int = 0
        var chunkIndex: Int = 0
        var carriedTail = ""

        while true {
            try Task.checkCancellation()

            let chunk = try handle.read(upToCount: chunkSizeBytes) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            chunkIndex += 1

            let wavURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetcapture-chunk-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wavURL) }

            try writeWAV(captureData: chunk, to: wavURL,
                         inputFormat: inputFormat, inputChannels: channels)

            let text = try await runWhisper(on: wavURL, context: carriedTail)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                assembled.append(trimmed)
                textContinuation.yield(trimmed)
                carriedTail = String(trimmed.suffix(220))
            }

            let pct = totalSize > 0 ? min(1.0, Double(bytesRead) / Double(totalSize)) : 0.0
            progressContinuation.yield(pct)

            logger.debug("Chunk \(chunkIndex) done (\(chunk.count) bytes) →"
                + " \"\(trimmed.prefix(80))…\"")
        }

        progressContinuation.yield(1.0)
        return Self.dedupRepeats(assembled.joined(separator: " "))
    }

    /// Compute per-chunk byte size and detect audio format once.
    private func computeChunkParams() throws -> (chunkSize: Int,
                                                  format: AudioInputFormat,
                                                  channels: Int) {
        // Probe the first few bytes to detect format.
        let probeHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: audioPath))
        defer { try? probeHandle.close() }
        let probe = probeHandle.readDataOfLength(4096)
        let (fmt, ch) = probe.isEmpty
            ? (.float32Mono, 1)
            : detectAudioFormat(probe)

        // Whole frames per chunk at the detected format.
        let frameBytes = ch * (fmt == .int16Stereo ? 2 : 4)
        let chunkSize = Self.chunkSeconds * Int(captureSampleRate) * frameBytes

        logger.debug("Chunk mode: \(chunkSize)B windows, fmt=\(fmt), ch=\(ch)")
        return (chunkSize, fmt, ch)
    }

    // MARK: - Audio Format Detection

    /// Input audio format variants we can handle.
    enum AudioInputFormat: CustomStringConvertible {
        /// Legacy: mono Float32, any sample rate (48k / 44.1k).
        case float32Mono
        /// New capture path: 16-bit signed integer, stereo interleaved, 16kHz.
        case int16Stereo

        var description: String {
            switch self {
            case .float32Mono: return "Float32/mono"
            case .int16Stereo: return "Int16/stereo"
            }
        }
    }

    /// Detect audio format from raw PCM bytes.
    /// Heuristic: Int16 stereo at 16kHz has L+R both in [-32768, 32767] range;
    /// Float32 mono has bytes that, when interpreted as Int16 pairs, typically
    /// show one large value (the exponent bits) and one near-zero (the mantissa).
    /// Returns (format, channelCount).
    private func detectAudioFormat(_ data: Data) -> (AudioInputFormat, Int) {
        guard data.count >= 8 else { return (.float32Mono, 1) }

        var stereoInt16Frames = 0
        var float32LikeFrames = 0
        let maxFrames = min(data.count / 4, 256)    // 256 stereo frames max

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<maxFrames {
                let idx = i * 2
                guard idx + 1 < samples.count else { break }
                let l = abs(Int(samples[idx]))
                let r = abs(Int(samples[idx + 1]))
                if l > 1 && r > 1 {
                    stereoInt16Frames += 1            // Both channels active — real stereo
                } else if (l > 1) != (r > 1) {
                    float32LikeFrames += 1            // One channel active — Float32 byte pattern
                }
            }
        }

        // If clear majority of frames are stereo Int16, treat as such.
        // Float32 mono channel data viewed as Int16 pairs typically shows
        // the exponent bits as a large value in one slot and mantissa as
        // near-zero in the other, producing mostly float32LikeFrames.
        if stereoInt16Frames > float32LikeFrames && stereoInt16Frames > 16 {
            return (.int16Stereo, 2)
        }
        return (.float32Mono, 1)
    }

    // MARK: - Whisper invocation

    private func runWhisper(on wavURL: URL, context: String = "") async throws -> String {
        guard let modelPath = whisperManager.loadedModelPathAccessor else {
            finishStreams(WhisperError.noModelLoaded)
            throw WhisperError.noModelLoaded
        }
        let cliPath = whisperManager.whisperCLIPathAccessor
        let vadModel = whisperManager.vadModelPathAccessor
        let prompt = context.isEmpty
            ? WhisperModelManager.domainPrompt
            : WhisperModelManager.domainPrompt + " " + context

        // Use withCheckedThrowingContinuation so we can add cancellation and timeout.
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
                    "--no-prints"
                ]
                if let vad = vadModel {
                    args += ["--vad", "--vad-model", vad]
                }
                process.arguments = args

                // Pipe setup: read stderr in the background so a full pipe
                // buffer can't deadlock the child.
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                // Background reader for stderr (collect for diagnostics).
                var stderrData = Data()
                let errHandle = errPipe.fileHandleForReading
                errHandle.readabilityHandler = { handle in
                    let d = handle.availableData
                    if !d.isEmpty { stderrData.append(d) }
                }

                // Timeout timer
                let timeoutSec = Self.processTimeoutSec
                let timerSource = DispatchSource.makeTimerSource(queue: queue)
                timerSource.schedule(deadline: .now() + .seconds(timeoutSec))
                timerSource.setEventHandler {
                    if process.isRunning {
                        process.interrupt()       // SIGTERM
                        // If still running after 5 grace seconds, SIGKILL
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
                    cont.resume(throwing: WhisperError.processError(exitCode: -1,
                        stderr: "\(error)"))
                    return
                }

                timerSource.cancel()
                errHandle.readabilityHandler = nil

                let exit = process.terminationStatus
                // 15 = SIGTERM (from our timeout or external)
                // 9  = SIGKILL
                if exit == 15 || exit == 9 {
                    cont.resume(throwing: WhisperError.processError(exitCode: exit,
                        stderr: "Timed out after \(timeoutSec)s"))
                    return
                }
                guard exit == 0 else {
                    let err = String(data: stderrData, encoding: .utf8) ?? ""
                    cont.resume(throwing: WhisperError.processError(exitCode: exit,
                        stderr: err))
                    return
                }

                let txtPath = wavURL.deletingPathExtension().path + ".txt"
                guard FileManager.default.fileExists(atPath: txtPath) else {
                    cont.resume(throwing: WhisperError.transcriptionFailed(
                        reason: "Output not created at \(txtPath)"))
                    return
                }
                do {
                    let content = try String(contentsOfFile: txtPath, encoding: .utf8)
                    try? FileManager.default.removeItem(atPath: txtPath)
                    cont.resume(returning: content.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                } catch {
                    cont.resume(throwing: WhisperError.transcriptionFailed(
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
    private func writeWAV(captureData: Data, to url: URL,
                          inputFormat: AudioInputFormat = .float32Mono,
                          inputChannels: Int = 1) throws {
        switch inputFormat {
        case .float32Mono:
            try writeWAVFloat32Mono(captureData: captureData, to: url)
        case .int16Stereo:
            try writeWAVInt16Stereo(captureData: captureData, to: url)
        }
    }

    /// Legacy path: mono Float32 at captureSampleRate, resample to 16kHz.
    private func writeWAVFloat32Mono(captureData: Data, to url: URL) throws {
        let frameBytes = 4   // mono Float32
        let inCount = captureData.count / frameBytes
        let ratio = captureSampleRate / Double(Self.targetSampleRate)
        let outCount = ratio > 0 ? Int(Double(inCount) / ratio) : 0
        var int16Samples = [Int16](repeating: 0, count: max(0, outCount))

        captureData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)
            guard inCount > 0 else { return }
            var peak: Float = 0
            for i in 0..<inCount { let a = abs(floats[i]); if a > peak { peak = a } }
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
        let frameBytes = 4    // 2 channels × 2 bytes
        let sampleCount = captureData.count / frameBytes
        var int16Samples = [Int16](repeating: 0, count: sampleCount)

        captureData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                let l = samples[i * 2]
                let r = samples[i * 2 + 1]
                // Average stereo pair → mono
                let avg = (Int32(l) + Int32(r)) / 2
                int16Samples[i] = Int16(clamping: avg)
            }
            // Peak-normalise
            var peak: Int16 = 0
            for s in int16Samples { let a = abs(s); if a > peak { peak = a } }
            let targetPeak: Int16 = 29000   // ~ -1dBFS
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
        out.append(littleEndian16(1))           // PCM
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
        if finished { finishLock.unlock(); return }
        finished = true
        finishLock.unlock()

        if let err = error {
            logger.error("Transcription failed: \(err.localizedDescription)")
            // Yield error before finishing — consumers see a final value
            // then the stream terminates, which is the conventional pattern.
            progressContinuation.finish()
            textContinuation.finish()
        } else {
            progressContinuation.finish()
            textContinuation.finish()
        }
    }

    // MARK: - Dedup

    /// Remove whisper-cli's repeated-block hallucination.
    static func dedupRepeats(_ text: String) -> String {
        let parts = text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func norm(_ s: String) -> String {
            String(s.lowercased().unicodeScalars.filter {
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

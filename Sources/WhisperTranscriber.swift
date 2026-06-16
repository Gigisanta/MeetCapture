// WhisperTranscriber.swift
// MeetCapture v4 — Phase 3 streaming transcription
// Reads the raw PCM file written by AudioCaptureService (Core Audio tap:
// Float32, interleaved, 48kHz, stereo) in 30s windows. Each window is
// downmixed to mono, resampled to 16kHz, converted to 16-bit, and handed to
// whisper-cli. Emits progress + final assembled text via AsyncStream.

import Foundation
import os

/// Streams a PCM file through whisper-cli in 30s windows to bound RAM usage.
/// Bounded memory: ~2 MB peak regardless of total audio length.
final class WhisperTranscriber {
    static let chunkSeconds: Int = 30
    // On-disk capture format: mono Float32 at `captureSampleRate` (set per
    // recording — the aggregate may run at 48k or 44.1k).
    static let bytesPerSample: Int = 4                 // mono Float32
    static let frameBytes: Int = bytesPerSample        // mono → 1 sample/frame
    static let targetSampleRate: Int = 16_000          // whisper requires 16kHz

    private let audioPath: String
    private let captureSampleRate: Double
    private let whisperManager: WhisperModelManager
    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "WhisperStream")

    let progress: AsyncStream<Double>
    let text: AsyncStream<String>
    private let progressContinuation: AsyncStream<Double>.Continuation
    private let textContinuation: AsyncStream<String>.Continuation

    init?(audioPath: String, sampleRate: Double, whisperManager: WhisperModelManager) {
        self.audioPath = audioPath
        self.captureSampleRate = sampleRate > 0 ? sampleRate : 48_000
        self.whisperManager = whisperManager

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

    /// Run the streaming transcription. Returns the assembled final text.
    func run() async throws -> String {
        // Whole frames per chunk (mono Float32 at the capture rate).
        let chunkSizeBytes = Self.chunkSeconds * Int(captureSampleRate) * Self.frameBytes
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
        // Carry the tail of the previous chunk's text as context so whisper keeps
        // continuity across 30s boundaries (names/topics don't reset each chunk).
        var carriedTail = ""

        while true {
            let chunk = try handle.read(upToCount: chunkSizeBytes) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            chunkIndex += 1

            // Downmix 48k stereo Float32 → 16k mono Int16, write temp WAV
            let wavURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetcapture-chunk-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wavURL) }

            try writeWAV(captureData: chunk, to: wavURL)

            // Run whisper-cli on this chunk
            let text = try await runWhisper(on: wavURL, context: carriedTail)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                assembled.append(trimmed)
                textContinuation.yield(trimmed)
                // Keep the last ~220 chars as context for the next chunk.
                carriedTail = String(trimmed.suffix(220))
            }

            // Progress
            let pct = totalSize > 0 ? min(1.0, Double(bytesRead) / Double(totalSize)) : 0.0
            progressContinuation.yield(pct)

            logger.debug("Chunk \(chunkIndex) done (\(chunk.count) bytes) → \"\(trimmed.prefix(80))…\"")
        }

        progressContinuation.yield(1.0)
        progressContinuation.finish()
        textContinuation.finish()
        return Self.dedupRepeats(assembled.joined(separator: " "))
    }

    /// Remove whisper-cli's repeated-block hallucination. On short/silence-padded
    /// clips (notably the final partial chunk) it re-emits whole spans verbatim,
    /// e.g. "A. B. A. B." → we drop a sentence when an identical one (ignoring
    /// case/punctuation) already appeared within the last `window` sentences.
    /// A length gate keeps legitimate short repeats ("Sí. Sí.", "Hola. … Hola.").
    static func dedupRepeats(_ text: String) -> String {
        let parts = text.replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        func norm(_ s: String) -> String { String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        let window = 8       // covers whole-transcript duplication of a few sentences
        let minLen = 12      // only dedup substantial sentences, not short interjections
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

    // MARK: - Whisper invocation

    private func runWhisper(on wavURL: URL, context: String = "") async throws -> String {
        guard let modelPath = whisperManager.loadedModelPathAccessor else {
            throw WhisperError.noModelLoaded
        }
        let cliPath = whisperManager.whisperCLIPathAccessor
        let vadModel = whisperManager.vadModelPathAccessor
        // Domain prompt + carried tail from the previous chunk for continuity.
        let prompt = context.isEmpty
            ? WhisperModelManager.domainPrompt
            : WhisperModelManager.domainPrompt + " " + context

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
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
                    "--suppress-nst",      // drop non-speech tokens ("[MÚSICA]", "(chiming)")
                    "--no-timestamps",
                    "--no-prints"
                ]
                // Voice Activity Detection: skip silence (faster, fewer
                // hallucinations on pauses) when a Silero model is available.
                if let vad = vadModel {
                    args += ["--vad", "--vad-model", vad]
                }
                process.arguments = args
                let stderr = Pipe()
                process.standardError = stderr
                process.standardOutput = Pipe()

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    cont.resume(throwing: WhisperError.processError(exitCode: -1, stderr: "\(error)"))
                    return
                }

                let exit = process.terminationStatus
                if exit != 0 {
                    let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(throwing: WhisperError.processError(exitCode: exit, stderr: err))
                    return
                }

                let txtPath = wavURL.deletingPathExtension().path + ".txt"
                guard FileManager.default.fileExists(atPath: txtPath) else {
                    cont.resume(throwing: WhisperError.transcriptionFailed(reason: "Output not created at \(txtPath)"))
                    return
                }
                do {
                    let content = try String(contentsOfFile: txtPath, encoding: .utf8)
                    try? FileManager.default.removeItem(atPath: txtPath)
                    cont.resume(returning: content.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    cont.resume(throwing: WhisperError.transcriptionFailed(reason: "\(error)"))
                }
            }
        }
    }

    /// Convert a window of captured PCM (mono Float32 at `captureSampleRate`)
    /// into a 16kHz mono 16-bit WAV that whisper-cli reads natively. Resamples
    /// from the actual capture rate (48k or 44.1k) via linear interpolation.
    /// ponytail: linear resample, not a polyphase FIR — speech content sits well
    /// below 8kHz and whisper is robust to the mild aliasing; swap in a low-pass
    /// if sibilance quality ever matters.
    private func writeWAV(captureData: Data, to url: URL) throws {
        let inCount = captureData.count / Self.frameBytes        // mono samples
        let ratio = captureSampleRate / Double(Self.targetSampleRate)  // e.g. 2.756
        let outCount = ratio > 0 ? Int(Double(inCount) / ratio) : 0
        var int16Samples = [Int16](repeating: 0, count: max(0, outCount))

        captureData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let floats = raw.bindMemory(to: Float.self)  // [m0, m1, m2, ...]
            guard inCount > 0 else { return }
            for j in 0..<outCount {
                let srcPos = Double(j) * ratio
                let i0 = Int(srcPos)
                let frac = Float(srcPos - Double(i0))
                let a = floats[i0]
                let b = (i0 + 1 < inCount) ? floats[i0 + 1] : a
                let mono = a + (b - a) * frac
                let clamped = max(-1.0, min(1.0, mono))
                int16Samples[j] = Int16(clamped * 32767.0)
            }
        }

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleRate = Self.targetSampleRate
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(int16Samples.count * Int(bitsPerSample / 8))
        let chunkSize = 36 + dataSize

        var out = Data()
        out.append("RIFF".data(using: .ascii)!)
        out.append(littleEndian32(chunkSize))
        out.append("WAVE".data(using: .ascii)!)
        out.append("fmt ".data(using: .ascii)!)
        out.append(littleEndian32(16))           // PCM header size
        out.append(littleEndian16(1))            // PCM format
        out.append(littleEndian16(numChannels))
        out.append(littleEndian32(UInt32(sampleRate)))
        out.append(littleEndian32(byteRate))
        out.append(littleEndian16(blockAlign))
        out.append(littleEndian16(bitsPerSample))
        out.append("data".data(using: .ascii)!)
        out.append(littleEndian32(dataSize))
        int16Samples.withUnsafeBytes { out.append(contentsOf: $0) }
        try out.write(to: url)
    }

    private func littleEndian16(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }
    private func littleEndian32(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
}

// WhisperTranscriber.swift
// MeetCapture v4 — Phase 3 streaming transcription
// Reads a 16kHz/16-bit/mono PCM file in 30s windows, runs whisper-cli per chunk,
// emits progress + final assembled text via AsyncStream.

import Foundation
import os

/// Streams a PCM file through whisper-cli in 30s windows to bound RAM usage.
/// Bounded memory: ~2 MB peak regardless of total audio length.
final class WhisperTranscriber {
    static let chunkSeconds: Int = 30
    static let sampleRate: Int = 16_000
    static let bytesPerSample: Int = 2  // Int16

    private let audioPath: String
    private let whisperManager: WhisperModelManager
    private let logger = Logger(subsystem: "com.maatwork.meetcapture", category: "WhisperStream")

    let progress: AsyncStream<Double>
    let text: AsyncStream<String>
    private let progressContinuation: AsyncStream<Double>.Continuation
    private let textContinuation: AsyncStream<String>.Continuation

    init?(audioPath: String, whisperManager: WhisperModelManager) {
        self.audioPath = audioPath
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
        let chunkSizeBytes = Self.chunkSeconds * Self.sampleRate * Self.bytesPerSample
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

        while true {
            let chunk = try handle.read(upToCount: chunkSizeBytes) ?? Data()
            if chunk.isEmpty { break }
            bytesRead += chunk.count
            chunkIndex += 1

            // Convert Int16 PCM → Float32 in place, write to temp WAV
            let wavURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("meetcapture-chunk-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wavURL) }

            try writeWAV(pcmData: chunk, sampleRate: Self.sampleRate, to: wavURL)

            // Run whisper-cli on this chunk
            let text = try await runWhisper(on: wavURL)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                assembled.append(trimmed)
                textContinuation.yield(trimmed)
            }

            // Progress
            let pct = totalSize > 0 ? min(1.0, Double(bytesRead) / Double(totalSize)) : 0.0
            progressContinuation.yield(pct)

            logger.debug("Chunk \(chunkIndex) done (\(chunk.count) bytes) → \"\(trimmed.prefix(80))…\"")
        }

        progressContinuation.yield(1.0)
        progressContinuation.finish()
        textContinuation.finish()
        return assembled.joined(separator: " ")
    }

    // MARK: - Whisper invocation

    private func runWhisper(on wavURL: URL) async throws -> String {
        guard let modelPath = whisperManager.loadedModelPathAccessor else {
            throw WhisperError.noModelLoaded
        }
        let cliPath = whisperManager.whisperCLIPathAccessor

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: cliPath)
                process.arguments = [
                    "-m", modelPath,
                    "-f", wavURL.path,
                    "-l", "es",
                    "-otxt", "-of", wavURL.deletingPathExtension().path,
                    "-t", "4",
                    "--no-prints"
                ]
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

    /// Write a minimal WAV header + raw 16-bit PCM samples to disk.
    private func writeWAV(pcmData: Data, sampleRate: Int, to url: URL) throws {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let chunkSize = 36 + dataSize

        var header = Data()
        header.append("RIFF".data(using: .ascii)!)
        header.append(littleEndian32(chunkSize))
        header.append("WAVE".data(using: .ascii)!)
        header.append("fmt ".data(using: .ascii)!)
        header.append(littleEndian32(16))           // PCM header size
        header.append(littleEndian16(1))            // PCM format
        header.append(littleEndian16(numChannels))
        header.append(littleEndian32(UInt32(sampleRate)))
        header.append(littleEndian32(byteRate))
        header.append(littleEndian16(blockAlign))
        header.append(littleEndian16(bitsPerSample))
        header.append("data".data(using: .ascii)!)
        header.append(littleEndian32(dataSize))

        var combined = Data()
        combined.append(header)
        combined.append(pcmData)
        try combined.write(to: url)
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

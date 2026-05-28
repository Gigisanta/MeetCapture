// WhisperBridge.swift
// MeetCapture v4 — Whisper transcription via whisper-cli subprocess
// Uses the installed whisper-cli binary (Homebrew) for transcription.
// Future: can migrate to direct C API when linking libwhisper via Xcode.

import Foundation
import os

// MARK: - Whisper Model Size

enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny    = "tiny"
    case base    = "base"
    case small   = "small"
    case medium  = "medium"
    case large   = "large"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    /// Approximate memory footprint in GB
    var estimatedMemoryGB: Double {
        switch self {
        case .tiny:          return 0.05
        case .base:          return 0.10
        case .small:         return 0.46
        case .medium:        return 1.50
        case .large:         return 2.90
        case .largeV3Turbo:  return 1.50
        }
    }

    /// Filename pattern for the ggml model file
    var filename: String {
        switch self {
        case .largeV3Turbo: return "ggml-large-v3-turbo.bin"
        default:            return "ggml-\(rawValue).bin"
        }
    }
}

// MARK: - WhisperError

enum WhisperError: LocalizedError {
    case noModelLoaded
    case modelLoadFailed(path: String)
    case transcriptionFailed(reason: String)
    case processError(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return "No whisper model loaded"
        case .modelLoadFailed(let path):
            return "Failed to load model at: \(path)"
        case .transcriptionFailed(let reason):
            return "Transcription failed: \(reason)"
        case .processError(let code, let stderr):
            return "whisper-cli exited \(code): \(stderr)"
        }
    }
}

// MARK: - WhisperBridge

/// Transcribes audio using the whisper-cli binary.
/// Thread-safe: all calls go through a serial dispatch queue.
final class WhisperBridge {
    static let shared = WhisperBridge()

    private let logger = Logger(subsystem: "com.meetcapture.whisper", category: "Bridge")
    private let queue = DispatchQueue(label: "com.meetcapture.whisper.bridge", qos: .userInitiated)

    /// Path to whisper-cli binary
    private let whisperCLIPath: String

    /// Path to currently loaded model
    private(set) var loadedModelPath: String?

    /// Whether a model is currently loaded (ready for transcription)
    var isModelLoaded: Bool { loadedModelPath != nil }

    private init() {
        // Find whisper-cli
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ]
        whisperCLIPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"
        logger.info("whisper-cli path: \(self.whisperCLIPath)")
    }

    // MARK: - Model Management

    /// Load a model (stores the path for later use)
    func loadModel(path: String, model: WhisperModelSize) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WhisperError.modelLoadFailed(path: path)
        }

        // Verify whisper-cli exists
        guard FileManager.default.fileExists(atPath: whisperCLIPath) else {
            throw WhisperError.modelLoadFailed(path: "whisper-cli not found at \(whisperCLIPath)")
        }

        loadedModelPath = path
        logger.info("Model loaded: \(model.rawValue) at \(path)")
    }

    /// Unload the current model
    func unloadModel() {
        loadedModelPath = nil
        logger.info("Model unloaded")
    }

    // MARK: - Transcription

    /// Transcribe audio samples by writing to a temp WAV file and calling whisper-cli
    func transcribe(
        samples: [Float],
        language: String = "en",
        translate: Bool = false,
        useGPU: Bool = true
    ) throws -> String {
        guard let modelPath = loadedModelPath else {
            throw WhisperError.noModelLoaded
        }

        return try queue.sync {
            // Write samples to a temporary WAV file
            let tempDir = FileManager.default.temporaryDirectory
            let tempWAV = tempDir.appendingPathComponent("meetcapture-\(UUID().uuidString).wav")

            try writeWAV(samples: samples, sampleRate: 16000, to: tempWAV)

            defer {
                try? FileManager.default.removeItem(at: tempWAV)
            }

            // Build whisper-cli command
            let outputBase = tempDir.appendingPathComponent("meetcapture-out-\(UUID().uuidString)")

            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperCLIPath)
            process.arguments = [
                "-m", modelPath,
                "-f", tempWAV.path,
                "-l", language,
                "-otxt",
                "-of", outputBase.path,
                "-t", "4",  // 4 threads
                "--no-prints"  // suppress stdout
            ]

            if translate {
                process.arguments?.append("--translate")
            }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let exitCode = process.terminationStatus
            let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""

            guard exitCode == 0 else {
                throw WhisperError.processError(exitCode: exitCode, stderr: stderrStr)
            }

            // Read the output .txt file
            let outputTXT = outputBase.path + ".txt"
            guard FileManager.default.fileExists(atPath: outputTXT) else {
                throw WhisperError.transcriptionFailed(reason: "Output file not created: \(outputTXT)")
            }

            let text = try String(contentsOfFile: outputTXT, encoding: .utf8)

            // Cleanup
            try? FileManager.default.removeItem(atPath: outputTXT)

            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - WAV Writing

    /// Write Float32 samples as a 16-bit PCM WAV file (mono, 16kHz)
    private func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let numSamples = samples.count
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(numSamples * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM format
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

        // Convert Float32 to Int16 PCM
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clamped * 32767.0)
            data.append(contentsOf: withUnsafeBytes(of: int16Sample.littleEndian) { Array($0) })
        }

        try data.write(to: url)
    }
}

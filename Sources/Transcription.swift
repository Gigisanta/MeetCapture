// Transcription.swift
// MeetCapture v4 — Whisper transcription service
// Merged: WhisperBridge + WhisperModelManager

import Foundation
import os
import AppKit

// MARK: - Whisper Model Size

enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny    = "tiny"
    case base    = "base"
    case small   = "small"
    case medium  = "medium"
    case large   = "large"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

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

// MARK: - WhisperModelManager

/// Manages whisper model lifecycle: loading, transcription, memory monitoring.
final class WhisperModelManager {
    static let shared = WhisperModelManager()

    private let logger = Logger(subsystem: "com.meetcapture.whisper", category: "ModelManager")
    private let queue = DispatchQueue(label: "com.meetcapture.whisper", qos: .userInitiated)

    private let whisperCLIPath: String
    private let modelsDirectory: URL
    private var loadedModelPath: String?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryCheckTimer: Timer?

    private(set) var activeModel: WhisperModelSize?
    private(set) var isRecording = false
    var preferredModel: WhisperModelSize = .largeV3Turbo
    var memoryThresholdMB: UInt64 = 512

    var isModelLoaded: Bool { loadedModelPath != nil }

    private init() {
        // Find whisper-cli
        let bundleCLI = Bundle.main.resourcePath.map { "\($0)/whisper-cli" }
        let candidates = [
            bundleCLI,
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ].compactMap { $0 }
        whisperCLIPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"

        // Models directory
        let home = FileManager.default.homeDirectoryForCurrentUser
        let whisperModelsDir = home.appendingPathComponent(".whisper/models")
        if FileManager.default.fileExists(atPath: whisperModelsDir.path) {
            self.modelsDirectory = whisperModelsDir
        } else {
            if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
                self.modelsDirectory = appSupport.appendingPathComponent("MeetCapture/Models")
            } else {
                self.modelsDirectory = URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support/MeetCapture/Models")
            }
            try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        }
        self.preferredModel = .base

        setupMemoryPressureMonitoring()
        logger.info("WhisperModelManager initialized. Models dir: \(self.modelsDirectory.path)")
    }

    deinit {
        stopMemoryMonitoring()
    }

    // MARK: - Recording Session

    func startRecording() throws {
        guard !isRecording else { return }
        isRecording = true
        let model = selectBestModel(for: preferredModel)
        try loadModel(model)
        startMemoryMonitoring()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        stopMemoryMonitoring()
        unloadModel()
        activeModel = nil
    }

    // MARK: - Transcription

    func transcribe(samples: [Float], language: String = "es", translate: Bool = false) throws -> String {
        guard isRecording else { throw WhisperError.noModelLoaded }
        guard isModelLoaded else { throw WhisperError.noModelLoaded }

        return try queue.sync {
            let tempDir = FileManager.default.temporaryDirectory
            let tempWAV = tempDir.appendingPathComponent("meetcapture-\(UUID().uuidString).wav")
            try writeWAV(samples: samples, sampleRate: 16000, to: tempWAV)
            defer { try? FileManager.default.removeItem(at: tempWAV) }

            let outputBase = tempDir.appendingPathComponent("meetcapture-out-\(UUID().uuidString)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: whisperCLIPath)
            process.arguments = [
                "-m", loadedModelPath!,
                "-f", tempWAV.path,
                "-l", language,
                "-otxt", "-of", outputBase.path,
                "-t", "4", "--no-prints"
            ]
            if translate { process.arguments?.append("--translate") }

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            try process.run()
            process.waitUntilExit()

            let exitCode = process.terminationStatus
            let stderrStr = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard exitCode == 0 else {
                throw WhisperError.processError(exitCode: exitCode, stderr: stderrStr)
            }

            let outputTXT = outputBase.path + ".txt"
            guard FileManager.default.fileExists(atPath: outputTXT) else {
                throw WhisperError.transcriptionFailed(reason: "Output file not created")
            }
            let text = try String(contentsOfFile: outputTXT, encoding: .utf8)
            try? FileManager.default.removeItem(atPath: outputTXT)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Model Management

    func isModelDownloaded(_ model: WhisperModelSize) -> Bool {
        let path = modelsDirectory.appendingPathComponent(model.filename).path
        return FileManager.default.fileExists(atPath: path)
    }

    func modelURL(for model: WhisperModelSize) -> URL {
        return modelsDirectory.appendingPathComponent(model.filename)
    }

    var downloadedModels: [WhisperModelSize] {
        WhisperModelSize.allCases.filter { isModelDownloaded($0) }
    }

    private func loadModel(_ model: WhisperModelSize) throws {
        let path = modelURL(for: model).path
        guard FileManager.default.fileExists(atPath: path) else {
            throw WhisperError.modelLoadFailed(path: path)
        }
        guard FileManager.default.fileExists(atPath: whisperCLIPath) else {
            throw WhisperError.modelLoadFailed(path: "whisper-cli not found at \(whisperCLIPath)")
        }
        loadedModelPath = path
        activeModel = model
        logger.info("Model loaded: \(model.rawValue)")
    }

    private func unloadModel() {
        loadedModelPath = nil
        logger.info("Model unloaded")
    }

    // MARK: - Model Selection

    private func selectBestModel(for preferred: WhisperModelSize) -> WhisperModelSize {
        let availableMB = availableMemoryMB()
        let requiredMB = UInt64(preferred.estimatedMemoryGB * 1024.0) + memoryThresholdMB
        if availableMB > requiredMB, isModelDownloaded(preferred) {
            return preferred
        }
        let fallbackOrder: [WhisperModelSize] = [.largeV3Turbo, .medium, .small, .base, .tiny]
        for model in fallbackOrder {
            guard isModelDownloaded(model) else { continue }
            let reqMB = UInt64(model.estimatedMemoryGB * 1024.0)
            if availableMB > reqMB + memoryThresholdMB {
                return model
            }
        }
        return isModelDownloaded(.tiny) ? .tiny : .base
    }

    private func smallerModel(than current: WhisperModelSize) -> WhisperModelSize {
        switch current {
        case .largeV3Turbo, .large, .medium: return .small
        case .small: return .base
        case .base: return .tiny
        case .tiny: return .tiny
        }
    }

    // MARK: - Memory Pressure

    private func setupMemoryPressureMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .userInitiated)
        )
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }
            let event = self.memoryPressureSource?.data
            if event?.contains(.critical) == true {
                self.handleMemoryPressure(critical: true)
            } else if event?.contains(.warning) == true {
                self.handleMemoryPressure(critical: false)
            }
        }
        memoryPressureSource?.resume()
    }

    private func stopMemoryMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        memoryCheckTimer?.invalidate()
        memoryCheckTimer = nil
    }

    private func handleMemoryPressure(critical: Bool) {
        guard isRecording, let current = activeModel else { return }
        let smaller = smallerModel(than: current)
        if smaller != current {
            logger.warning("Downgrading model from \(current.rawValue) to \(smaller.rawValue)")
            do { try loadModel(smaller) } catch { logger.error("Failed to downgrade: \(error)") }
        }
    }

    private func startMemoryMonitoring() {
        memoryCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.periodicMemoryCheck()
        }
    }

    private func periodicMemoryCheck() {
        guard isRecording, let current = activeModel else { return }
        let availableMB = availableMemoryMB()
        let requiredMB = UInt64(current.estimatedMemoryGB * 1024.0)
        if availableMB < requiredMB + memoryThresholdMB {
            let smaller = smallerModel(than: current)
            if smaller != current {
                do { try loadModel(smaller) } catch { logger.error("Failed to auto-downgrade: \(error)") }
            }
        }
    }

    private func availableMemoryMB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 4096 }
        let usedMB = UInt64(info.resident_size) / (1024 * 1024)
        let totalMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
        return totalMB > usedMB ? totalMB - usedMB : 0
    }

    // MARK: - WAV Writing

    private func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        let numSamples = samples.count
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(numSamples * Int(bitsPerSample / 8))
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            data.append(contentsOf: withUnsafeBytes(of: Int16(clamped * 32767.0).littleEndian) { Array($0) })
        }
        try data.write(to: url)
    }
}

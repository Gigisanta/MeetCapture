import Foundation
import os
import AppKit

// MARK: - WhisperModelManager

/// Manages whisper model lifecycle based on system memory pressure.
/// Loads models on-demand when recording starts, unloads when done.
/// Monitors memory and auto-downgrades to smaller models under pressure.
final class WhisperModelManager {

    static let shared = WhisperModelManager()

    private let logger = Logger(subsystem: "com.meetcapture.whisper", category: "ModelManager")
    private let whisper = WhisperBridge.shared

    /// Models directory (inside app bundle or ~/Library/Application Support)
    private let modelsDirectory: URL

    /// Currently active model tier
    private(set) var activeModel: WhisperModelSize?

    /// Whether a recording is currently in progress
    private(set) var isRecording = false

    /// Memory pressure source
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    /// Timer for periodic memory checks during recording
    private var memoryCheckTimer: Timer?

    /// Preferred model (user setting)
    var preferredModel: WhisperModelSize = .largeV3Turbo

    /// Available memory threshold in MB - below this, downshift model
    var memoryThresholdMB: UInt64 = 512

    // MARK: - Initialization

    private init() {
        // Determine models directory
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("MeetCapture/Models")
            self.modelsDirectory = appDir
        } else {
            self.modelsDirectory = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/MeetCapture/Models")
        }

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

        setupMemoryPressureMonitoring()

        logger.info("WhisperModelManager initialized. Models dir: \(self.modelsDirectory.path)")
    }

    deinit {
        stopMemoryMonitoring()
    }

    // MARK: - Public API

    /// Start a recording session. Loads the best available model.
    func startRecording() throws {
        guard !isRecording else {
            logger.warning("Recording already in progress")
            return
        }

        isRecording = true
        logger.info("Starting recording session")

        // Determine best model for current memory conditions
        let model = selectBestModel(for: preferredModel)
        try loadModel(model)

        // Start periodic memory checks
        startMemoryMonitoring()
    }

    /// Stop the recording session. Unloads the model.
    func stopRecording() {
        guard isRecording else { return }

        isRecording = false
        logger.info("Stopping recording session")

        stopMemoryMonitoring()

        // Unload model to free memory
        whisper.unloadModel()
        activeModel = nil

        logger.info("Recording session ended, model unloaded")
    }

    /// Transcribe the given audio buffer.
    func transcribe(
        samples: [Float],
        language: String = "en",
        translate: Bool = false
    ) throws -> String {
        guard isRecording else {
            throw WhisperError.noModelLoaded
        }

        guard whisper.isModelLoaded else {
            throw WhisperError.noModelLoaded
        }

        return try whisper.transcribe(
            samples: samples,
            language: language,
            translate: translate,
            useGPU: true
        )
    }

    /// Check if a model file exists locally
    func isModelDownloaded(_ model: WhisperModelSize) -> Bool {
        let path = modelsDirectory.appendingPathComponent(model.filename).path
        return FileManager.default.fileExists(atPath: path)
    }

    /// Get the URL for a model file
    func modelURL(for model: WhisperModelSize) -> URL {
        return modelsDirectory.appendingPathComponent(model.filename)
    }

    /// List all downloaded models
    var downloadedModels: [WhisperModelSize] {
        WhisperModelSize.allCases.filter { isModelDownloaded($0) }
    }

    /// Get file size of a model in bytes
    func modelFileSize(_ model: WhisperModelSize) -> UInt64? {
        let path = modelURL(for: model).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.size] as? UInt64
    }

    // MARK: - Model Selection

    /// Select the best model given available memory.
    /// Tries to load the preferred model, falls back to smaller ones.
    private func selectBestModel(for preferred: WhisperModelSize) -> WhisperModelSize {
        let availableMB = availableMemoryMB()

        // If we have plenty of memory, use preferred
        if availableMB > preferred.estimatedMemoryGB * 1024.0 + Double(memoryThresholdMB) {
            if isModelDownloaded(preferred) {
                return preferred
            }
        }

        // Walk down through smaller models
        let fallbackOrder: [WhisperModelSize] = [.largeV3Turbo, .medium, .small, .base, .tiny]

        for model in fallbackOrder {
            guard isModelDownloaded(model) else { continue }
            let requiredMB = UInt64(model.estimatedMemoryGB * 1024.0)
            if availableMB > requiredMB + memoryThresholdMB {
                logger.info("Selected model: \(model.rawValue) (available: \(availableMB)MB)")
                return model
            }
        }

        // Last resort: tiny or base
        return isModelDownloaded(.tiny) ? .tiny : .base
    }

    /// Load a specific model
    private func loadModel(_ model: WhisperModelSize) throws {
        let path = modelURL(for: model).path

        guard FileManager.default.fileExists(atPath: path) else {
            logger.error("Model file not found: \(path)")
            throw WhisperError.modelLoadFailed(path: path)
        }

        logger.info("Loading model: \(model.rawValue)")
        try whisper.loadModel(path: path, model: model)
        activeModel = model
        logger.info("Model loaded: \(model.rawValue)")
    }

    // MARK: - Memory Pressure Monitoring

    /// Set up system memory pressure notifications
    private func setupMemoryPressureMonitoring() {
        // Listen for memory pressure notifications via DispatchSource
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .userInitiated)
        )

        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self = self, self.isRecording else { return }

            let event = self.memoryPressureSource?.data
            if event?.contains(.critical) == true {
                self.logger.warning("CRITICAL memory pressure - downgrading model")
                self.handleMemoryPressure(critical: true)
            } else if event?.contains(.warning) == true {
                self.logger.warning("Memory pressure WARNING - considering model downgrade")
                self.handleMemoryPressure(critical: false)
            }
        }

        memoryPressureSource?.resume()

        // Also observe NSWorkspace notifications for low memory
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidReceiveMemoryWarning),
            name: NSApplication.didReceiveMemoryWarningNotification,
            object: nil
        )

        logger.info("Memory pressure monitoring started")
    }

    /// Stop all memory monitoring
    private func stopMemoryMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil

        memoryCheckTimer?.invalidate()
        memoryCheckTimer = nil

        NotificationCenter.default.removeObserver(self)

        logger.info("Memory monitoring stopped")
    }

    /// Handle memory pressure events
    private func handleMemoryPressure(critical: Bool) {
        guard isRecording else { return }

        let availableMB = availableMemoryMB()
        logger.info("Available memory: \(availableMB)MB")

        // Downgrade to a smaller model
        if let current = activeModel {
            let smaller = smallerModel(than: current)
            if smaller != current {
                logger.warning("Downgrading model from \(current.rawValue) to \(smaller.rawValue) due to memory pressure")
                do {
                    try loadModel(smaller)
                } catch {
                    logger.error("Failed to downgrade model: \(error)")
                }
            }
        }
    }

    @objc private func handleDidReceiveMemoryWarning() {
        handleMemoryPressure(critical: true)
    }

    /// Start periodic memory checking during recording
    private func startMemoryMonitoring() {
        memoryCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.periodicMemoryCheck()
        }
    }

    /// Check memory periodically and downgrade if needed
    private func periodicMemoryCheck() {
        guard isRecording, let current = activeModel else { return }

        let availableMB = availableMemoryMB()
        let requiredMB = UInt64(current.estimatedMemoryGB * 1024.0)

        // If we're below threshold, downgrade
        if availableMB < requiredMB + memoryThresholdMB {
            logger.warning("Low memory (\(availableMB)MB available). Downgrading from \(current.rawValue)")
            let smaller = smallerModel(than: current)
            if smaller != current {
                do {
                    try loadModel(smaller)
                } catch {
                    logger.error("Failed to auto-downgrade: \(error)")
                }
            }
        }
    }

    // MARK: - Memory Utilities

    /// Get available system memory in MB
    private func availableMemoryMB() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            logger.error("Failed to get memory info")
            return 4096 // Default fallback: assume 4GB available
        }

        let usedMB = UInt64(info.resident_size) / (1024 * 1024)

        // Get total system memory
        let totalMB = ProcessInfo.processInfo.physicalMemory / (1024 * 1024)

        let available = totalMB > usedMB ? totalMB - usedMB : 0
        return available
    }

    /// Get a smaller model for downgrading
    private func smallerModel(than current: WhisperModelSize) -> WhisperModelSize {
        switch current {
        case .largeV3Turbo, .large, .medium:
            return .small
        case .small:
            return .base
        case .base:
            return .tiny
        case .tiny:
            return .tiny // Can't go smaller
        }
    }

    /// Get total system physical memory in MB
    var totalSystemMemoryMB: UInt64 {
        ProcessInfo.processInfo.physicalMemory / (1024 * 1024)
    }

    /// Get used memory for this process in MB
    var processMemoryMB: UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size) / (1024 * 1024)
    }
}

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

    /// Domain-specific initial prompt — primes whisper with participant names,
    /// company/project names and jargon so it spells them correctly instead of
    /// guessing homophones ("MaatWork" not "Matwork", "MeetCapture" not "Met
    /// Capture"). Kept in sync with ~/.hermes/scripts/transcribe.py.
    static let domainPrompt = """
    Transcripción de reunión de trabajo en español argentino. \
    Participantes: Gio, Virginia, Nacho. \
    Empresas y proyectos: MaatWork, Reinnova, Infrannova, Cactus Wealth, MaatQuant, \
    Reinnova Consum, MaatWork Gym, MaatWorkHUB, PlanningMaatWork, MeetCapture, Hermes. \
    Personas: Virginia Folgueiro, Nacho Infante. \
    Términos técnicos: certificación, redeterminación de precios, planificación, \
    etapas, obras, tickets, gestión documental, inventario, presupuesto, partida, \
    parte de obra, orden de compra, proveedor, acopio, baseline, desvío, cash flow, KPI, rubro.
    """

    /// Threads for whisper-cli. Uses available cores (capped) for speed without
    /// starving the UI. Apple Silicon counts efficiency cores too.
    static let whisperThreads: Int = max(4, min(8, ProcessInfo.processInfo.activeProcessorCount))

    private let logger = Logger(subsystem: "com.meetcapture.whisper", category: "ModelManager")
    private let queue = DispatchQueue(label: "com.meetcapture.whisper", qos: .userInitiated)

    private let whisperCLIPath: String
    let whisperCLIPathAccessor: String  // Exposed for WhisperTranscriber
    private let modelsDirectory: URL
    // `loadedModelPath`, `activeModel` and `isRecording` are mutated from several
    // threads — the recording Task, the memory-pressure DispatchSource (global
    // queue), the periodic timer (main) — and read by the transcriber's worker
    // thread. Guard the trio with a lock so a torn `String?` read can't crash and
    // a mid-transcription model swap stays consistent.
    private let stateLock = NSLock()
    private var _loadedModelPath: String?
    private var loadedModelPath: String? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _loadedModelPath }
        set { stateLock.lock(); defer { stateLock.unlock() }; _loadedModelPath = newValue }
    }
    var loadedModelPathAccessor: String? { loadedModelPath }  // Exposed for WhisperTranscriber

    /// Path to a Silero VAD ggml model if one is present (`ggml-silero-*.bin`),
    /// else nil. Used to enable whisper-cli's `--vad` so silence is skipped —
    /// faster, and far fewer hallucinations during meeting pauses.
    var vadModelPathAccessor: String? {
        let candidates = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        let silero = candidates.filter { $0.hasPrefix("ggml-silero") && $0.hasSuffix(".bin") }.sorted().last
        return silero.map { modelsDirectory.appendingPathComponent($0).path }
    }
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var memoryCheckTimer: Timer?

    private var _activeModel: WhisperModelSize?
    private(set) var activeModel: WhisperModelSize? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _activeModel }
        set { stateLock.lock(); defer { stateLock.unlock() }; _activeModel = newValue }
    }
    private var _isRecording = false
    private(set) var isRecording: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _isRecording }
        set { stateLock.lock(); defer { stateLock.unlock() }; _isRecording = newValue }
    }
    var preferredModel: WhisperModelSize = .largeV3Turbo
    var memoryThresholdMB: UInt64 = 512

    var isModelLoaded: Bool { stateLock.lock(); defer { stateLock.unlock() }; return _loadedModelPath != nil }

    private init() {
        // Find whisper-cli. Prefer the Homebrew/system install: the copy bundled
        // into the .app by build.sh is missing its @rpath dylibs (libwhisper,
        // libggml) and fails with "Library not loaded", so it must NOT be first.
        let bundleCLI = Bundle.main.resourcePath.map { "\($0)/whisper-cli" }
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            bundleCLI,
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ].compactMap { $0 }
        whisperCLIPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"
        whisperCLIPathAccessor = whisperCLIPath

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
        self.preferredModel = .medium

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
        // Honor the user's model choice from Settings (@AppStorage "whisperModel").
        // selectBestModel still downgrades if there isn't enough free RAM, so an
        // over-ambitious choice can't freeze the machine. Falls back to the
        // init default (.base) when the setting is unset.
        if let saved = UserDefaults.standard.string(forKey: "whisperModel"),
           let chosen = WhisperModelSize(rawValue: saved) {
            preferredModel = chosen
        }
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
        // whisper-cli runs as a transient subprocess and mmaps the model file,
        // so most of its footprint is file-backed (reclaimable). The old gate
        // ("need full model size + 512MB FREE") was written for an in-process
        // model and wrongly forced everyone down to `base`, wrecking accuracy.
        // Estimate the resident working set as ~60% of the model size and honor
        // the user's choice when it fits; the live memory-pressure source still
        // downgrades if the OS reports genuine pressure.
        let availableMB = availableMemoryMB()
        func workingSetMB(_ m: WhisperModelSize) -> UInt64 { UInt64(m.estimatedMemoryGB * 0.6 * 1024.0) }

        if isModelDownloaded(preferred), availableMB > workingSetMB(preferred) {
            return preferred
        }
        let fallbackOrder: [WhisperModelSize] = [.largeV3Turbo, .medium, .small, .base, .tiny]
        for model in fallbackOrder where isModelDownloaded(model) {
            if availableMB > workingSetMB(model) { return model }
        }
        return isModelDownloaded(.base) ? .base : .tiny
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
        // Only downgrade on GENUINELY critical free memory (absolute floor), not
        // relative to model size. The relative check used to ping-pong the model
        // mid-recording — producing chunks transcribed by different models — even
        // though the mmap'd subprocess was perfectly healthy. 300MB is the floor
        // below which the system is actually in trouble.
        let availableMB = availableMemoryMB()
        if availableMB < 300 {
            let smaller = smallerModel(than: current)
            if smaller != current {
                logger.warning("Critically low memory (\(availableMB)MB) — downgrading \(current.rawValue)→\(smaller.rawValue)")
                do { try loadModel(smaller) } catch { logger.error("Failed to auto-downgrade: \(error)") }
            }
        }
    }

    /// System-wide free memory in MB (free + inactive pages, both reclaimable).
    /// The previous implementation returned physicalMemory minus THIS process's
    /// RSS, which on a 16GB box reports ~15.9GB "available" even when the system
    /// is actually swapping — defeating the whole point of model downgrading.
    private func availableMemoryMB() -> UInt64 {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        // Conservative fallback: assume only the base model is safe.
        guard result == KERN_SUCCESS else { return 512 }
        let pageSize = UInt64(vm_kernel_page_size)
        let reclaimable = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        return reclaimable / (1024 * 1024)
    }

}

import Foundation
import os

// MARK: - Whisper C API Declarations

/// Whisper context pointer (opaque handle)
private typealias WhisperContext = OpaquePointer
/// Whisper state pointer (for partial encoding)
private typealias WhisperState = OpaquePointer

// MARK: - C API Function Signatures (resolved at link time from libwhisper)

@_silgen_name("whisper_init_from_file")
private func whisperInitFromFile(_ path: UnsafePointer<CChar>) -> WhisperContext?

@_silgen_name("whisper_free")
private func whisperFree(_ ctx: WhisperContext?)

@_silgen_name("whisper_full_default_params")
private func whisperFullDefaultParams(_ strategy: CInt) -> whisper_full_params

@_silgen_name("whisper_full")
private func whisperFull(
    _ ctx: WhisperContext?,
    _ params: whisper_full_params,
    _ samples: UnsafePointer<Float>?,
    _ nSamples: CInt,
    _ nThreads: CInt
) -> CInt

@_silgen_name("whisper_full_n_segments")
private func whisperFullNSegments(_ ctx: WhisperContext?) -> CInt

@_silgen_name("whisper_full_get_segment_text")
private func whisperFullGetSegmentText(_ ctx: WhisperContext?, _ iSegment: CInt) -> UnsafePointer<CChar>?

@_silgen_name("whisper_full_n_tokens")
private func whisperFullNTokens(_ ctx: WhisperContext?, _ iSegment: CInt) -> CInt

@_silgen_name("whisper_full_get_token_text")
private func whisperFullGetTokenText(_ ctx: WhisperContext?, _ iSegment: CInt, _ iToken: CInt) -> UnsafePointer<CChar>?

@_silgen_name("whisper_full_lang_id")
private func whisperFullLangId(_ ctx: WhisperContext?, _ iSegment: CInt) -> CInt

// MARK: - Whisper Model Size

enum WhisperModelSize: String, CaseIterable, Identifiable {
    case tiny    = "tiny"
    case base    = "base"
    case small   = "small"
    case medium  = "medium"
    case large   = "large"
    case largeV3Turbo = "large-v3-turbo"

    var id: String { rawValue }

    /// Approximate memory footprint in GB for GPU (Metal) loading
    var estimatedMemoryGB: Double {
        switch self {
        case .tiny:          return 0.05
        case .base:          return 0.10
        case .small:         return 0.46
        case .medium:        return 1.50
        case .large:         return 2.90
        case .largeV3Turbo:  return 1.50  // turbo variant is smaller
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

// MARK: - WhisperBridge

/// Swift wrapper around the whisper.cpp C library.
/// Thread-safe: uses a serial queue for all context operations.
/// Supports Metal acceleration via whisper.cpp's built-in GPU backend.
final class WhisperBridge {

    static let shared = WhisperBridge()

    private let logger = Logger(subsystem: "com.meetcapture.whisper", category: "WhisperBridge")

    /// The underlying whisper context pointer (nil when unloaded)
    private var context: WhisperContext?

    /// Currently loaded model info
    private var loadedModel: WhisperModelSize?
    private var loadedModelPath: String?

    /// Serial queue to protect context access
    private let queue = DispatchQueue(label: "com.meetcapture.whisper.bridge", qos: .userInitiated)

    /// Whether a transcription is currently in progress
    private var isTranscribing = false

    /// Cancellation flag for in-progress transcriptions
    private var cancellationRequested = false

    // MARK: - Initialization

    private init() {
        logger.info("WhisperBridge initialized")
    }

    deinit {
        unloadModelSync()
    }

    // MARK: - Public API

    /// Load a whisper model from disk.
    /// - Parameters:
    ///   - path: Path to the ggml model file (e.g. ggml-base.bin)
    ///   - model: Which model size to load
    /// - Throws: WhisperError if loading fails
    func loadModel(path: String, model: WhisperModelSize) throws {
        try queue.sync {
            // If already loaded with same model, skip
            if loadedModel == model, loadedModelPath == path, context != nil {
                logger.info("Model already loaded: \(model.rawValue)")
                return
            }

            // Unload previous model if switching
            if context != nil {
                logger.info("Switching models: unloading \(self.loadedModel?.rawValue ?? "unknown")")
                unloadModelSync()
            }

            logger.info("Loading whisper model: \(model.rawValue) from \(path)")

            let cPath = path.cString(using: .utf8)!
            guard let ctx = whisperInitFromFile(cPath) else {
                throw WhisperError.modelLoadFailed(path: path)
            }

            self.context = ctx
            self.loadedModel = model
            self.loadedModelPath = path

            logger.info("Model loaded successfully: \(model.rawValue)")
        }
    }

    /// Transcribe audio samples to text.
    /// - Parameters:
    ///   - samples: Array of 16-bit float samples at 16kHz mono
    ///   - language: Language code (e.g. "en", "es"). Default: "en"
    ///   - translate: If true, translate to English
    ///   - useGPU: Whether to use Metal GPU acceleration (default: true)
    /// - Returns: Transcribed text
    /// - Throws: WhisperError if transcription fails
    func transcribe(
        samples: [Float],
        language: String = "en",
        translate: Bool = false,
        useGPU: Bool = true
    ) throws -> String {
        return try queue.sync {
            guard let ctx = context else {
                throw WhisperError.noModelLoaded
            }

            guard !samples.isEmpty else {
                return ""
            }

            guard !cancellationRequested else {
                throw WhisperError.transcriptionCancelled
            }

            isTranscribing = true
            defer { isTranscribing = false }

            // Configure parameters
            var params = whisperFullDefaultParams(0) // 0 = greedy strategy
            params.print_progress = 0
            params.print_special = 0
            params.print_realtime = 0
            params.print_timestamps = 0
            params.print_colors = 0
            params.print_resources = 0
            params.no_timestamps = translate ? 1 : 0
            params.translate = translate ? 1 : 0
            params.single_segment = 0
            params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

            // Set language
            language.withCString { langPtr in
                _ = withUnsafeMutablePointer(to: &params.language.0) { buf in
                    strncpy(buf, langPtr, 3)
                }
            }

            // Use Metal acceleration when available
            if useGPU {
                params.use_gpu = 1
                params.gpu_device = -1 // auto-select
            } else {
                params.use_gpu = 0
            }

            // Run transcription
            let samplesPtr = samples.withUnsafeBufferPointer { $0.baseAddress }
            let result = whisperFull(ctx, params, samplesPtr, Int32(samples.count), params.n_threads)

            guard result == 0 else {
                throw WhisperError.transcriptionFailed(errorCode: result)
            }

            // Extract text from all segments
            let nSegments = whisperFullNSegments(ctx)
            var fullText = ""

            for i in 0..<nSegments {
                guard cancellationRequested == false else {
                    throw WhisperError.transcriptionCancelled
                }

                if let segTextPtr = whisperFullGetSegmentText(ctx, i) {
                    let segText = String(cString: segTextPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !segText.isEmpty {
                        if !fullText.isEmpty {
                            fullText += " "
                        }
                        fullText += segText
                    }
                }
            }

            logger.debug("Transcription complete: \(fullText.prefix(100))...")
            return fullText
        }
    }

    /// Transcribe with partial/streaming support.
    /// Returns results segment by segment via callback.
    func transcribeStreaming(
        samples: [Float],
        language: String = "en",
        onSegment: @escaping (Int, String) -> Void
    ) throws {
        try queue.sync {
            guard let ctx = context else {
                throw WhisperError.noModelLoaded
            }

            guard !samples.isEmpty else { return }

            var params = whisperFullDefaultParams(0)
            params.print_progress = 0
            params.print_special = 0
            params.print_realtime = 0
            params.print_timestamps = 0
            params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)

            language.withCString { langPtr in
                _ = withUnsafeMutablePointer(to: &params.language.0) { buf in
                    strncpy(buf, langPtr, 3)
                }
            }

            params.use_gpu = 1
            params.gpu_device = -1

            let samplesPtr = samples.withUnsafeBufferPointer { $0.baseAddress }
            let result = whisperFull(ctx, params, samplesPtr, Int32(samples.count), params.n_threads)

            guard result == 0 else {
                throw WhisperError.transcriptionFailed(errorCode: result)
            }

            let nSegments = whisperFullNSegments(ctx)
            for i in 0..<nSegments {
                if let segTextPtr = whisperFullGetSegmentText(ctx, i) {
                    let text = String(cString: segTextPtr).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        onSegment(Int(i), text)
                    }
                }
            }
        }
    }

    /// Cancel any in-progress transcription
    func cancelTranscription() {
        queue.sync {
            cancellationRequested = true
            // Reset after a brief delay so next transcription can proceed
        }
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.cancellationRequested = false
        }
    }

    /// Unload the current model to free memory.
    func unloadModel() {
        queue.sync {
            unloadModelSync()
        }
    }

    /// Check if a model is currently loaded
    var isModelLoaded: Bool {
        queue.sync { context != nil }
    }

    /// Currently loaded model size (if any)
    var currentModel: WhisperModelSize? {
        queue.sync { loadedModel }
    }

    // MARK: - Internal

    /// Must be called from within queue.sync or queue.async
    private func unloadModelSync() {
        guard let ctx = context else { return }

        logger.info("Unloading whisper model: \(self.loadedModel?.rawValue ?? "unknown")")
        whisperFree(ctx)

        context = nil
        loadedModel = nil
        loadedModelPath = nil

        logger.info("Model unloaded successfully")
    }
}

// MARK: - WhisperError

enum WhisperError: LocalizedError, CustomStringConvertible {
    case modelLoadFailed(path: String)
    case noModelLoaded
    case transcriptionFailed(errorCode: Int32)
    case transcriptionCancelled
    case insufficientMemory(requiredMB: UInt64, availableMB: UInt64)

    var description: String {
        switch self {
        case .modelLoadFailed(let path):
            return "Failed to load whisper model from: \(path)"
        case .noModelLoaded:
            return "No whisper model loaded. Call loadModel() first."
        case .transcriptionFailed(let code):
            return "Whisper transcription failed with error code: \(code)"
        case .transcriptionCancelled:
            return "Transcription was cancelled"
        case .insufficientMemory(let required, let available):
            return "Insufficient memory: need \(required)MB, have \(available)MB"
        }
    }

    var errorDescription: String? { description }
}

// Research-only, local WhisperKit 1.1.1 adapter. No SDK download path is used.
import AVFoundation
import CryptoKit
import Foundation
import NaturalLanguage
@preconcurrency import WhisperKit

actor WhisperKitEngine: SpeechRecognizer {
    static let shared = WhisperKitEngine()
    static let modelName = "openai_whisper-large-v3_947MB"
    private static let sdkRevision = "1bbc57cb7fe6410248a685b1c5a3c6d56adc2ed4"
    private static let modelRepository = "argmaxinc/whisperkit-coreml"
    private static let modelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    private static let tokenizerRepository = "openai/whisper-large-v3"
    private static let tokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
    private static let contentSHA256 = "d13c4c7e93c175b29a439aa4e0d54811facb80d9ea3d0044ed9f0d74d4d1d9ef"
    // Frozen from the pinned tokenizer, WITHOUT special tokens. Loading verifies
    // this entire list against the SDK's actual tokenizer, including in no-prompt
    // mode. An incompatible tokenizer cannot silently acquire this identity.
    private static let promptTokens = [8524, 409, 2560, 368, 18099, 13, 19835, 259,
                                      29987, 25, 9362, 11, 10223, 33248, 39934, 11,
                                      15576, 14237, 11, 23331, 11, 691, 2869, 338, 13]

    nonisolated let engine: ASREngine = .whisperkit
    nonisolated var modelName: String { Self.modelName }
    nonisolated let identity: QATrace.RecognizerIdentity
    private let artifact: Result<Artifact, Error>
    private let usesPrompt: Bool
    private var loading: (id: UUID, task: Task<Loaded, Error>)?
    private var recognition: (id: UUID, task: Task<[TranscriptionResult], Error>)?
    private var unloading: Task<Void, Never>?

    init(modelDirectory: URL? = QAExperiment.whisperModelDirectory,
         prompt: Bool = QAExperiment.whisperPrompt) {
        let artifact = Result { try Artifact.open(modelDirectory) }
        self.artifact = artifact
        usesPrompt = prompt
        identity = Self.makeIdentity(artifact: artifact, prompt: prompt)
    }

    func prepare() async throws { _ = try await loaded() }

    func words(in samples: [Float], language: String) async throws -> [Segment] {
        var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
        let needsAudioTrace = QATrace.isEnabled && context.inputSHA256 == nil
        if QATrace.isEnabled {
            context.sampleRate = 16_000
            context.invocationID = context.invocationID ?? UUID().uuidString
            if needsAudioTrace { context.inputSHA256 = QATrace.audioSHA256(samples) }
        }
        return try await QATrace.$context.withValue(context) {
            if needsAudioTrace { try QATrace.writeAudio(samples, name: "sdk-input") }
            return try await recognize(.samples(samples), duration: Double(samples.count) / 16_000,
                                       language: language)
        }
    }

    func words(inFile file: URL, language: String) async throws -> [Segment] {
        // Only the header is read here. The SDK's incremental path uses bounded
        // 120-second staging, back-pressure and VAD, NOT loadAudioAsFloatArray.
        let audio = try AVAudioFile(forReading: file)
        guard audio.fileFormat.sampleRate == 16_000, audio.fileFormat.channelCount == 1 else {
            throw AdapterError.contract("file input must be the pipeline's 16 kHz mono channel")
        }
        let duration = Double(audio.length) / audio.fileFormat.sampleRate
        var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
        if QATrace.isEnabled {
            context.sampleRate = 16_000
            context.invocationID = context.invocationID ?? UUID().uuidString
            if context.inputSHA256 == nil { context.inputSHA256 = try Self.fileSHA256(file) }
        }
        return try await QATrace.$context.withValue(context) {
            try await recognize(.file(file), duration: duration, language: language)
        }
    }

    private enum Input: Sendable {
        case samples([Float])
        case file(URL)

        var description: String {
            switch self {
            case .samples: return "16kHz-mono-float32-array"
            case .file: return "16kHz-mono-file-incremental-120s-buffer2"
            }
        }
    }

    private func recognize(_ input: Input, duration: Double, language: String) async throws -> [Segment] {
        guard language == "es" else {
            throw AdapterError.contract("this predeclared WhisperKit arm requires language es")
        }
        try Task.checkCancellation()
        let loaded = try await loaded()
        // WhisperKit owns mutable progress/timings. Concurrent jobs are not part
        // of this pipeline's contract; do not add decoder locks or share a run.
        guard recognition == nil else {
            throw AdapterError.contract("overlapping recognition on one WhisperKit engine")
        }
        try QATrace.write(InvocationTrace(identity: identity, options: loaded.options,
                                          prompt: loaded.prompt, input: input.description,
                                          durationSeconds: duration,
                                          supportsWordTimestamps: loaded.kit.textDecoder.supportsWordTimestamps,
                                          logitsSize: loaded.kit.textDecoder.logitsSize,
                                          encoderEmbedSize: loaded.kit.audioEncoder.embedSize),
                          name: "sdk-invocation")
        let id = UUID()
        let task = Task<[TranscriptionResult], Error> {
            try Task.checkCancellation()
            let results: [TranscriptionResult]
            switch input {
            case .samples(let samples):
                results = try await loaded.kit.transcribe(audioArray: samples, decodeOptions: loaded.options)
            case .file(let file):
                results = try await loaded.kit.transcribe(
                    audioPath: file.path,
                    audioInputOptions: AudioInputOptions(
                        channelMode: .specificChannel(0),
                        audioLoadingMode: .incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)),
                    decodeOptions: loaded.options)
            }
            // The ENTIRE Codable SDK result is retained before any adaptation,
            // including tokens, token log probabilities, segment/word times and timings.
            try QATrace.write(results, name: "sdk-result")
            // The SDK stream may finish normally when its producer is cancelled.
            // A partial result must not become a successful checkpoint in that case.
            try Task.checkCancellation()
            return results
        }
        recognition = (id, task)
        defer { if recognition?.id == id { recognition = nil } }
        let results = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard recognition?.id == id else { throw CancellationError() }
        do {
            let words = try Self.timedWords(from: results, duration: duration)
            try QATrace.write(words, name: "adapter-words")
            return words
        } catch let error as AdapterError {
            try QATrace.write(error.localizedDescription, name: "adapter-contract-failure")
            throw error
        }
    }

    /// Preserves SDK textual order. No timestamp sorting, lexical dedupe, inferred
    /// timestamps, punctuation-only filtering or cross-engine word arbitration.
    static func timedWords(from results: [TranscriptionResult], duration: Double) throws -> [Segment] {
        guard duration.isFinite, duration >= 0 else {
            throw AdapterError.contract("invalid input duration")
        }
        // SDK times are Float. Permit only its one-ULP representation uncertainty
        // at the input endpoint; do not clip a padded window back into the audio.
        let upperBound = Double(Float(duration).nextUp)
        var words: [Segment] = []
        var previousStart = -Double.infinity
        for result in results {
            let countBeforeResult = words.count
            for segment in result.segments {
                let timed = segment.words ?? []
                if !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, timed.isEmpty {
                    throw AdapterError.contract("nonempty SDK segment has no WordTiming alignment; audio is preserved")
                }
                for word in timed {
                    let text = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                    let start = Double(word.start)
                    let end = Double(word.end)
                    guard !text.isEmpty, start.isFinite, end.isFinite,
                          start >= 0, end >= start, end <= upperBound, start >= previousStart else {
                        throw AdapterError.contract("WordTiming has empty text, invalid bounds or nontextual time order; audio is preserved")
                    }
                    words.append(Segment(start: start, end: end, text: text))
                    previousStart = start
                }
            }
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               words.count == countBeforeResult {
                throw AdapterError.contract("nonempty SDK text has no WordTiming alignment; audio is preserved")
            }
        }
        return words
    }

    func unload() async {
        if let unloading { await unloading.value; return }
        let load = loading?.task
        let run = recognition?.task
        loading = nil
        recognition = nil
        run?.cancel()
        load?.cancel()
        let task = Task<Void, Never> {
            _ = try? await run?.value
            if let session = try? await load?.value {
                await session.kit.unloadModels()
                session.kit.tokenizer = nil
                session.kit.clearState()
            }
        }
        unloading = task
        await task.value
        unloading = nil
    }

    private func loaded() async throws -> Loaded {
        if let unloading { await unloading.value }
        try Task.checkCancellation()
        let id: UUID
        let task: Task<Loaded, Error>
        if let loading {
            id = loading.id
            task = loading.task
        } else {
            let artifact = try artifact.get()
            let usesPrompt = usesPrompt
            id = UUID()
            task = Task<Loaded, Error> {
                try artifact.verifyFiles()
                try Task.checkCancellation()
                try QATrace.write(artifact.manifest, name: "whisperkit-model-artifact")
                let tokenizerDirectory = artifact.root.appendingPathComponent("tokenizer", isDirectory: true)
                // Unlike ModelUtilities.loadTokenizer, this public local factory
                // has NO catch-and-download-from-Hub branch in SDK 1.1.1.
                let implementation = try await AutoTokenizerWrapper.from(modelFolder: tokenizerDirectory)
                try Task.checkCancellation()
                let actualPromptTokens = implementation.encode(text: QAExperiment.fixedPrompt, addSpecialTokens: false)
                guard actualPromptTokens == Self.promptTokens, actualPromptTokens.count <= 64 else {
                    throw AdapterError.contract("actual tokenizer does not match the frozen <=64-token fixed prompt")
                }
                let tokenizer = try OfflineWhisperTokenizer(implementation)
                let prompt = PromptTrace(text: usesPrompt ? QAExperiment.fixedPrompt : nil,
                                         sha256: usesPrompt ? Self.sha256(Data(QAExperiment.fixedPrompt.utf8)) : nil,
                                         tokens: usesPrompt ? actualPromptTokens : nil)
                let options = Self.decoderOptions(promptTokens: prompt.tokens)
                let kit = try await StrictLocalWhisperKit(WhisperKitConfig(
                    model: Self.modelName, modelRepo: Self.modelRepository,
                    modelFolder: artifact.root.appendingPathComponent(Self.modelName, isDirectory: true).path,
                    tokenizerFolder: tokenizerDirectory,
                    computeOptions: ModelComputeOptions(melCompute: .cpuOnly,
                                                        audioEncoderCompute: .cpuAndNeuralEngine,
                                                        textDecoderCompute: .cpuAndNeuralEngine),
                    voiceActivityDetector: EnergyVAD(sampleRate: 16_000, frameLength: 0.1,
                                                    frameOverlap: 0, energyThreshold: 0.02),
                    verbose: false, logLevel: .none, prewarm: false, load: false, download: false,
                    useBackgroundDownloadSession: false))
                // The SDK wrapper initializer is internal in 1.1.1. Inject the
                // local protocol wrapper BEFORE loading, bypassing its network
                // fallback entirely. SDK modelVariant's display stays at its
                // unused default; actual model identity is verified below.
                kit.tokenizer = tokenizer
                kit.textDecoder.isModelMultilingual = true
                do {
                    try Task.checkCancellation()
                    try await kit.prewarmModels()
                    try Task.checkCancellation()
                    try await kit.loadModels()
                    try Task.checkCancellation()
                    guard kit.textDecoder.logitsSize == 51_866,
                          kit.audioEncoder.embedSize == 1_280,
                          kit.featureExtractor.windowSamples == 480_000,
                          kit.textDecoder.supportsWordTimestamps else {
                        throw AdapterError.contract("loaded model is not aligned large-v3 (51866 logits, 1280 embeds, 30s window)")
                    }
                    return Loaded(kit: kit, options: options, prompt: prompt)
                } catch {
                    await kit.unloadModels()
                    kit.tokenizer = nil
                    kit.clearState()
                    throw error
                }
            }
            loading = (id, task)
        }
        let result: Loaded
        do {
            result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            if loading?.id == id { loading = nil }
            throw error
        }
        // Cancelling a waiter after a successful load must not discard a shared
        // prepared model. Only a failed loader resets the single-flight state.
        try Task.checkCancellation()
        guard loading?.id == id else { throw CancellationError() }
        return result
    }

    // Ownership transfers from the single-flight loader to this actor. Only one
    // recognition may use the SDK instance; unload cancels and awaits that run.
    private struct Loaded: @unchecked Sendable {
        let kit: WhisperKit
        let options: DecodingOptions
        let prompt: PromptTrace
    }

    private struct PromptTrace: Codable, Sendable {
        var text: String?
        var sha256: String?
        var tokens: [Int]?
    }

    private struct InvocationTrace: Encodable {
        var identity: QATrace.RecognizerIdentity
        var options: DecodingOptions
        var prompt: PromptTrace
        var input: String
        var durationSeconds: Double
        var supportsWordTimestamps: Bool
        var logitsSize: Int?
        var encoderEmbedSize: Int?
    }

    enum AdapterError: LocalizedError {
        case contract(String)
        var errorDescription: String? {
            switch self {
            case .contract(let detail): return "WhisperKit QA adapter contract: \(detail)"
            }
        }
    }

    /// Every initializer value is fixed to the inspected macOS 1.1.1 defaults,
    /// except the predeclared task/language/word timestamps/VAD/prompt controls.
    private nonisolated static func decoderOptions(promptTokens: [Int]?) -> DecodingOptions {
        DecodingOptions(verbose: false, task: .transcribe, language: "es", temperature: 0,
                        temperatureIncrementOnFallback: 0.2, temperatureFallbackCount: 5,
                        sampleLength: 224, topK: 5, usePrefillPrompt: true, detectLanguage: false,
                        skipSpecialTokens: false, withoutTimestamps: false, wordTimestamps: true,
                        maxInitialTimestamp: nil, maxWindowSeek: nil, clipTimestamps: [], windowClipTime: 1,
                        promptTokens: promptTokens, prefixTokens: nil, suppressBlank: false, suppressTokens: [],
                        compressionRatioThreshold: 2.4, logProbThreshold: -1,
                        firstTokenLogProbThreshold: -1.5, noSpeechThreshold: 0.6,
                        concurrentWorkerCount: 16, chunkingStrategy: .vad)
    }

    private nonisolated static func makeIdentity(artifact: Result<Artifact, Error>, prompt: Bool) -> QATrace.RecognizerIdentity {
        let options = decoderOptions(promptTokens: prompt ? promptTokens : nil)
        var configuration: [String: String] = [
            "sdkVersion": "1.1.1", "modelRevision": modelRevision,
            "tokenizerRepository": tokenizerRepository, "tokenizerRevision": tokenizerRevision,
            "artifactContentSHA256": contentSHA256, "decoderLayers": "32", "encoderLayers": "32",
            "precision": "compressed CoreML; weight precision not verified; config torch_dtype is not asset precision",
            "melCompute": "cpuOnly", "audioEncoderCompute": "cpuAndNeuralEngine", "textDecoderCompute": "cpuAndNeuralEngine",
            "sdkBundledTokenizerSource": "swift-transformers 1.1.6 @573e5c9036c2f136b3a8a071da8e8907322403d0 (Argmax modifications)",
            "dependency.swiftArgumentParser": "1.8.2 @6a52f3251125d74daf04fcbd5e6f08a75d074382 (not linked into WhisperKit)",
            "computePlacementStatus": "configured CoreML compute units; physical placement not measured",
            "sampleRate": "16000", "modelWindowSamples": "480000", "prewarm": "true (sequential, then load)",
            "download": "false", "tokenizerLoading": "AutoTokenizerWrapper.from(modelFolder:), no Hub fallback",
            "sdkModelVariantDisplay": "unused default tiny when an offline tokenizer is injected; dimensions and pinned assets identify large-v3",
            "file.channelMode": "specificChannel(0)", "file.audioLoadingMode": "incremental",
            "file.chunkDurationSeconds": "120", "file.maxBufferedChunks": "2",
            "vad": "EnergyVAD", "vad.sampleRate": "16000", "vad.frameLength": "0.1",
            "vad.frameOverlap": "0", "vad.energyThreshold": "0.02",
            "vad.windowPaddingSamples": "16000",
            "arrayChunkFailurePolicy": "trace all SDK chunk outcomes, then throw any failure before SDK offset merging",
            "prompt.text": prompt ? QAExperiment.fixedPrompt : "nil",
            "prompt.sha256": prompt ? sha256(Data(QAExperiment.fixedPrompt.utf8)) : "nil",
            "prompt.tokens": prompt ? json(promptTokens) : "nil", "prompt.addSpecialTokens": "false",
            "prompt.tokenVerification": "actual SDK tokenizer must exactly match frozen tokens at every load",
            "minimumOS": "14.4 remains unverified; experiment host is macOS 26",
            // Codable omits nil optionals. Preserve those explicitly as well as
            // the complete encoded SDK value; no effective nil can disappear.
            "decoderOptions": json(options), "decoder.language": "es",
            "decoder.maxInitialTimestamp": "nil", "decoder.maxWindowSeek": "nil",
            "decoder.promptTokens": prompt ? json(promptTokens) : "nil", "decoder.prefixTokens": "nil",
            "fallback.temperatures": json((0...options.temperatureFallbackCount).map {
                Float(FloatType(options.temperature) + FloatType($0) * FloatType(options.temperatureIncrementOnFallback))
            }),
            "fallback.policy": "SDK 1.1.1 compression/log-prob/first-token/no-speech checks; retain full final hypothesis",
            "wordBounds": "finite 0<=start<=end<=Float(inputDuration).nextUp; SDK order; no clipping/interpolation",
        ]
        switch artifact {
        case .success(let value):
            configuration["artifactManifestSHA256"] = value.manifestSHA256
            configuration["artifactFiles"] = json(value.manifest.files)
        case .failure(let error):
            configuration["artifactManifestError"] = error.localizedDescription
        }
        return QATrace.RecognizerIdentity(adapterType: "MeetCaptureCore.WhisperKitEngine", engine: "whisperkit",
                                          model: modelName, sdk: "WhisperKit", sdkRevision: sdkRevision,
                                          modelRepository: modelRepository,
                                          modelRevisionStatus: "pinned manifest; all artifact bytes must pass SHA-256 before model load",
                                          configuration: configuration)
    }

    private nonisolated static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // All callers supply finite, statically declared options or a decoded
        // string/integer manifest. Encoding failure is a programmer contract.
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func fileSHA256(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct Artifact: Sendable {
        struct Manifest: Codable, Sendable {
            struct File: Codable, Sendable {
                var path: String
                var size: Int64
                var sha256: String
                var sourceURL: String
            }
            var schemaVersion: Int
            var engine: String
            var sdkVersion: String
            var sdkRevision: String
            var modelRepository: String
            var modelRevision: String
            var modelFolder: String
            var decoderLayers: Int
            var encoderLayers: Int
            var tokenizerRepository: String
            var tokenizerRevision: String
            var tokenizerFolder: String
            var contentSHA256: String
            var files: [File]
        }
        let root: URL
        let manifest: Manifest
        let manifestSHA256: String

        static func open(_ directory: URL?) throws -> Artifact {
            guard let directory else {
                throw AdapterError.contract("MEETCAPTURE_QA_WHISPER_MODEL_DIR must name a prepared local artifact directory")
            }
            let root = directory.standardizedFileURL.resolvingSymlinksInPath()
            let file = root.appendingPathComponent("whisperkit-artifact.json")
            let attributes = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                  let size = attributes.fileSize, size > 0, size <= 128 * 1024 else {
                throw AdapterError.contract("invalid or missing local artifact manifest; run qa/asr_whisper_model.py prepare")
            }
            let data = try Data(contentsOf: file)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.schemaVersion == 1, manifest.engine == "whisperkit", manifest.sdkVersion == "1.1.1",
                  manifest.sdkRevision == WhisperKitEngine.sdkRevision,
                  manifest.modelRepository == WhisperKitEngine.modelRepository,
                  manifest.modelRevision == WhisperKitEngine.modelRevision,
                  manifest.modelFolder == WhisperKitEngine.modelName,
                  manifest.decoderLayers == 32, manifest.encoderLayers == 32,
                  manifest.tokenizerRepository == WhisperKitEngine.tokenizerRepository,
                  manifest.tokenizerRevision == WhisperKitEngine.tokenizerRevision,
                  manifest.tokenizerFolder == "tokenizer", manifest.contentSHA256 == WhisperKitEngine.contentSHA256 else {
                throw AdapterError.contract("local manifest does not identify the pinned 1.1.1 / 32-layer large-v3 artifact")
            }
            let canonical = manifest.files.sorted { $0.path < $1.path }.map {
                "\($0.path):\($0.size):\($0.sha256)\n"
            }.joined()
            guard WhisperKitEngine.sha256(Data(canonical.utf8)) == WhisperKitEngine.contentSHA256 else {
                throw AdapterError.contract("artifact file inventory differs from the frozen source hashes")
            }
            return Artifact(root: root, manifest: manifest, manifestSHA256: WhisperKitEngine.sha256(data))
        }

        func verifyFiles() throws {
            for file in manifest.files {
                try Task.checkCancellation()
                let url = root.appendingPathComponent(file.path)
                guard url.standardizedFileURL.resolvingSymlinksInPath().path == url.path,
                      url.path.hasPrefix(root.path + "/") else {
                    throw AdapterError.contract("artifact file path escapes or redirects: \(file.path)")
                }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, values.fileSize.map(Int64.init) == file.size,
                      try WhisperKitEngine.fileSHA256(url) == file.sha256 else {
                    throw AdapterError.contract("local artifact size/SHA-256 mismatch: \(file.path)")
                }
            }
        }
    }
}

/// The stock 1.1.1 array/VAD path logs and drops failed chunks. Keep its actual
/// VAD geometry, batching, ordering and offset merger, but never call the lossy
/// merger with a failure. The incremental file path already propagates errors.
private final class StrictLocalWhisperKit: WhisperKit {
    override func transcribe(
        audioArray: [Float],
        audioArrayOffset: Int,
        decodeOptions: DecodingOptions? = nil,
        callback: TranscriptionCallback? = nil,
        segmentCallback: SegmentDiscoveryCallback? = nil
    ) async throws -> [TranscriptionResult] {
        let windowSamples = featureExtractor.windowSamples ?? 480_000
        guard audioArray.count > windowSamples, decodeOptions?.chunkingStrategy == .vad else {
            return try await super.transcribe(audioArray: audioArray, audioArrayOffset: audioArrayOffset,
                                              decodeOptions: decodeOptions, callback: callback,
                                              segmentCallback: segmentCallback)
        }
        let chunker = VADAudioChunker(windowPadding: 16_000, vad: voiceActivityDetector ?? EnergyVAD())
        let chunks = try await chunker.chunkAll(audioArray: audioArray, maxChunkLength: windowSamples,
                                                decodeOptions: decodeOptions)
        progress.totalUnitCount = max(progress.totalUnitCount, Int64(chunks.count))
        var options = decodeOptions
        options?.clipTimestamps = []
        let results = await transcribeWithOptions(
            audioArrays: chunks.map(\.audioSamples),
            decodeOptionsArray: Array(repeating: options, count: chunks.count),
            seekOffsets: chunks.map { audioArrayOffset + $0.seekOffsetIndex }, callback: callback)
        if QATrace.isEnabled {
            let outcomes = results.enumerated().map { index, result -> ChunkOutcome in
                switch result {
                case .success(let raw):
                    return ChunkOutcome(index: index, results: raw, error: nil)
                case .failure(let error):
                    return ChunkOutcome(index: index, results: nil, error: String(reflecting: error))
                }
            }
            try QATrace.write(outcomes, name: "sdk-vad-chunk-results")
        }
        for result in results {
            if case .failure(let error) = result { throw error }
        }
        try Task.checkCancellation()
        return chunker.updateSeekOffsetsForResults(chunkedResults: results, audioChunks: chunks)
    }

    private struct ChunkOutcome: Encodable {
        var index: Int
        var results: [TranscriptionResult]?
        var error: String?
    }
}

/// Offline equivalent of WhisperTokenizerWrapper, whose initializer is internal
/// in SDK 1.1.1. Word splitting is adapted from its Models.swift (MIT, copyright
/// 2024 Argmax, Inc.; full notice in docs/THIRD_PARTY.md). Only construction and
/// required-token validation differ; BPE/normalization/decoding remain SDK code.
private struct OfflineWhisperTokenizer: WhisperTokenizer, Sendable {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    init(_ tokenizer: TokenizerWrapper) throws {
        func required(_ text: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(text), tokenizer.convertIdToToken(id) == text else {
                throw WhisperKitEngine.AdapterError.contract("pinned tokenizer lacks required token \(text)")
            }
            return id
        }
        let whitespace = tokenizer.encode(text: " ", addSpecialTokens: false)
        guard whitespace.count == 1, tokenizer.decode(tokens: whitespace) == " " else {
            throw WhisperKitEngine.AdapterError.contract("pinned tokenizer lacks the single whitespace token")
        }
        let special = try SpecialTokens(endToken: required("<|endoftext|>"), englishToken: required("<|en|>"),
                                        noSpeechToken: required("<|nospeech|>"), noTimestampsToken: required("<|notimestamps|>"),
                                        specialTokenBegin: required("<|endoftext|>"), startOfPreviousToken: required("<|startofprev|>"),
                                        startOfTranscriptToken: required("<|startoftranscript|>"), timeTokenBegin: required("<|0.00|>"),
                                        transcribeToken: required("<|transcribe|>"), translateToken: required("<|translate|>"),
                                        whitespaceToken: whitespace[0])
        self.tokenizer = tokenizer
        specialTokens = special
        allLanguageTokens = Set(Constants.languages.values.compactMap { tokenizer.convertTokenToId("<|\($0)|>") }
            .filter { $0 > special.specialTokenBegin })
        _ = try required("<|es|>")
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    private func splitTokensOnUnicode(tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decodedFull = tokenizer.decode(tokens: tokens)
        let replacementString = "\u{fffd}"
        var words: [String] = []
        var wordTokens: [[Int]] = []
        var currentTokens: [Int] = []
        for token in tokens {
            currentTokens.append(token)
            let decoded = tokenizer.decode(tokens: currentTokens)
            var hasUnicodeInFullString = false
            if let range = decoded.range(of: replacementString) {
                hasUnicodeInFullString = decodedFull[range] == replacementString
            }
            if !decoded.contains(replacementString) || hasUnicodeInFullString {
                words.append(decoded)
                wordTokens.append(currentTokens)
                currentTokens = []
            }
        }
        return (words, wordTokens)
    }

    private func splitTokensOnSpaces(tokens: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let (subwords, subwordTokensList) = splitTokensOnUnicode(tokens: tokens)
        var words: [String] = []
        var wordTokens: [[Int]] = []
        for (subword, subwordTokens) in zip(subwords, subwordTokensList) {
            let special = subwordTokens.first! >= specialTokens.specialTokenBegin
            let withSpace = subword.hasPrefix(" ")
            var punctuation = false
            if let stripped = UnicodeScalar(subword.trimmingCharacters(in: .whitespaces)) {
                punctuation = CharacterSet.punctuationCharacters.contains(stripped)
            }
            if special || withSpace || punctuation || words.isEmpty {
                words.append(subword)
                wordTokens.append(subwordTokens)
            } else {
                words[words.count - 1] += subword
                wordTokens[words.count - 1].append(contentsOf: subwordTokens)
            }
        }
        return (words, wordTokens)
    }

    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        let decoded = tokenizer.decode(tokens: tokenIds.filter { $0 < specialTokens.specialTokenBegin })
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(decoded)
        let languageCode = recognizer.dominantLanguage.flatMap {
            Locale(identifier: $0.rawValue).language.languageCode?.identifier
        }
        if ["zh", "ja", "th", "lo", "my", "yue"].contains(languageCode) {
            return splitTokensOnUnicode(tokens: tokenIds)
        }
        return splitTokensOnSpaces(tokens: tokenIds)
    }
}

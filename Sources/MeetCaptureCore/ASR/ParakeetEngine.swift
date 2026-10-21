// ParakeetEngine.swift
// Speech engines behind the pipeline, both from FluidAudio (CoreML, on the
// ANE, so they never compete with the local LLM for the GPU):
//   · Parakeet TDT 0.6B "ultra": word-timed transcription of one chunk.
//   · Offline diarizer (pyannote community-1 + VBx): who spoke when.
// Models download once to ~/Library/Application Support/FluidAudio (CC-BY-4.0,
// see docs/THIRD_PARTY.md). Nothing is kept across meetings.

import FluidAudio
import Foundation

protocol SpeechRecognizer: Sendable {
    var engine: ASREngine { get }
    var modelName: String { get }
    var identity: QATrace.RecognizerIdentity { get }
    /// Loads (and on first use downloads) the model; throws when unavailable.
    func prepare() async throws
    /// Words of 16 kHz mono samples in [-1, 1], timed from the start of `samples`.
    func words(in samples: [Float], language: String) async throws -> [Segment]
    /// Disk-backed recognition; must not read an arbitrary meeting into an array.
    func words(inFile file: URL, language: String) async throws -> [Segment]
    func unload() async
}

protocol SpeakerDiarizing: Sendable {
    func spans(in wav: URL) async throws -> [SpeakerSpan]
}

actor ParakeetEngine: SpeechRecognizer {
    static let shared = ParakeetEngine()
    static let modelName = "parakeet-tdt-0.6b-ultra"
    private static let version = AsrModelVersion.ultra
    private static let configuration = ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                                encoderHiddenSize: version.encoderHiddenSize,
                                                seamGapRepairMinGapSeconds: QAExperiment.seamGapSeconds)
    nonisolated var engine: ASREngine { .parakeet }
    nonisolated var modelName: String { Self.modelName }
    nonisolated var identity: QATrace.RecognizerIdentity { Self.recognizerIdentity }
    /// One load shared by every caller; actor reentrancy would otherwise let
    /// the warm-up and a job each download and load the model.
    private var loading: Task<AsrManager, Error>?

    func prepare() async throws { _ = try await loaded() }

    func words(in samples: [Float], language: String) async throws -> [Segment] {
        if QATrace.isEnabled, QATrace.context?.inputSHA256 == nil {
            var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
            context.sampleRate = Self.configuration.sampleRate
            context.inputSHA256 = QATrace.audioSHA256(samples)
            context.invocationID = UUID().uuidString
            return try await QATrace.$context.withValue(context) {
                try QATrace.writeAudio(samples, name: "sdk-input")
                return try await transcribeSamples(samples, language: language)
            }
        }
        return try await transcribeSamples(samples, language: language)
    }

    func words(inFile file: URL, language: String) async throws -> [Segment] {
        try Task.checkCancellation()
        let manager = try await loaded()
        let layers = await manager.decoderLayerCount
        if QATrace.isEnabled {
            try QATrace.write(["path": file.path, "api": "transcribeDiskBacked", "language": language],
                              name: "sdk-file-invocation")
        }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribeDiskBacked(file, decoderState: &state,
                                                            language: Language(rawValue: language))
        try Task.checkCancellation()
        if QATrace.isEnabled { try QATrace.write(result, name: "sdk-result") }
        return try Self.timedWords(from: result, requireTimings: QAExperiment.isEnabled)
    }

    private func transcribeSamples(_ samples: [Float], language: String) async throws -> [Segment] {
        let manager = try await loaded()
        let layers = await manager.decoderLayerCount
        if QATrace.isEnabled {
            try QATrace.write(InvocationTrace(identity: identity, language: language,
                                             sampleCount: samples.count, decoderLayers: layers),
                              name: "sdk-invocation")
        }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state,
                                                  language: Language(rawValue: language))
        if QATrace.isEnabled {
            // Persist the SDK's entire Codable result, not a selected text/timing subset.
            try QATrace.write(result, name: "sdk-result")
        }
        do {
            return try Self.timedWords(from: result, requireTimings: QAExperiment.isEnabled)
        } catch let error as AdapterError {
            if QATrace.isEnabled {
                try QATrace.write(error.localizedDescription, name: "adapter-contract-failure")
            }
            throw error
        }
    }

    enum AdapterError: LocalizedError {
        case missingTimedWords
        case invalidTimedWords

        var errorDescription: String? {
            switch self {
            case .missingTimedWords:
                return "QA adapter contract: SDK returned nonempty text without timed words; audio is preserved"
            case .invalidTimedWords:
                return "QA adapter contract: adapted words contain invalid timestamps; audio is preserved"
            }
        }
    }

    /// The real result adapter; QA rejects a broken timing contract instead of
    /// treating nonempty SDK text as a successfully empty checkpoint.
    static func timedWords(from result: ASRResult, requireTimings: Bool) throws -> [Segment] {
        let adapted = words(from: result.tokenTimings ?? [])
        if QATrace.isEnabled { try QATrace.write(adapted, name: "adapter-words") }
        if requireTimings {
            guard adapted.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else { throw AdapterError.invalidTimedWords }
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, adapted.isEmpty {
                throw AdapterError.missingTimedWords
            }
        }
        return adapted
    }

    private struct InvocationTrace: Encodable {
        var identity: QATrace.RecognizerIdentity
        var language: String
        var sampleCount: Int
        var decoderLayers: Int
    }

    private static let recognizerIdentity: QATrace.RecognizerIdentity = {
        var identity = QATrace.RecognizerIdentity(adapterType: String(reflecting: ParakeetEngine.self))
        let config = configuration
        let tdt = config.tdtConfig
        identity.engine = "parakeet"
        identity.model = modelName
        identity.sdk = "FluidAudio"
        identity.sdkRevision = "bd11ac8da17a944a7291a2c76e9a172eb275f629"
        identity.modelRepository = Repo.parakeetUltra.rawValue
        identity.modelRevisionStatus = "Upstream revision unavailable; local artifact identity in configuration"
        identity.configuration = [
            "modelVersion": String(describing: version),
            "sampleRate": String(config.sampleRate),
            "encoderHiddenSize": String(config.encoderHiddenSize),
            "parallelChunkConcurrency": String(config.parallelChunkConcurrency),
            "streamingEnabled": String(config.streamingEnabled),
            "streamingThreshold": String(config.streamingThreshold),
            "melChunkContextOverride": config.melChunkContextOverride.map { String($0) } ?? "nil",
            "effectiveMelChunkContext": String(config.melChunkContextOverride ?? !version.isV3Family),
            "dualDecodeArbitration": String(config.dualDecodeArbitration),
            "seamGapRepair": String(config.seamGapRepair),
            "seamGapRepairMinGapSeconds": String(config.seamGapRepairMinGapSeconds),
            "seamTimingRealignment": String(config.seamTimingRealignment),
            "tdt.includeTokenDuration": String(tdt.includeTokenDuration),
            "tdt.maxSymbolsPerStep": String(tdt.maxSymbolsPerStep),
            "tdt.durationBins": String(describing: tdt.durationBins),
            "tdt.blankId": String(tdt.blankId),
            "tdt.boundarySearchFrames": String(tdt.boundarySearchFrames),
            "tdt.maxTokensPerChunk": String(tdt.maxTokensPerChunk),
            "tdt.consecutiveBlankLimit": String(tdt.consecutiveBlankLimit),
            "compute.encoder": "cpuAndNeuralEngine",
            "compute.decoder": "cpuAndNeuralEngine",
            "compute.preprocessor": "cpuOnly",
            "modelArtifactFingerprint": (try? QAModelArtifacts.parakeetFingerprint.get()) ?? "unavailable"
        ]
        return identity
    }()

    /// Frees the CoreML models; the next call loads them again. Callers only
    /// unload when no job runs (AppState checks the phase first).
    func unload() async {
        guard let task = loading else { return }
        loading = nil
        await (try? task.value)?.cleanup()
    }

    private func loaded() async throws -> AsrManager {
        try QAExperiment.validate()
        if let loading { return try await loading.value }
        let task = Task<AsrManager, Error> {
            let version = Self.version
            let models = try await AsrModels.downloadAndLoad(version: version)
            _ = try QAModelArtifacts.parakeetFingerprint.get()
            let manager = AsrManager(config: Self.configuration)
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do {
            return try await task.value
        } catch {
            // A failed load (offline, say) must not stick: the next call retries.
            if loading == task { loading = nil }
            throw error
        }
    }

    /// SentencePiece tokens → words: "▁" (or a space) starts a word; word
    /// pieces and punctuation attach to the word before them.
    static func words(from tokens: [TokenTiming]) -> [Segment] {
        var words: [Segment] = []
        var boundaryPending = false
        for token in tokens {
            let boundary = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
            let text = token.token.replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                boundaryPending = boundaryPending || boundary
                continue
            }
            if boundary || boundaryPending || words.isEmpty {
                words.append(Segment(start: token.startTime, end: token.endTime, text: text))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = token.endTime
            }
            boundaryPending = false
        }
        return words
    }
}

enum DiarizationError: LocalizedError {
    case unsupportedOS
    var errorDescription: String? { "La diarización necesita macOS 15 o posterior" }
}

struct FluidDiarizer: SpeakerDiarizing {
    // macOS 14 crashes inside BNNS during Core ML predictions (FluidAudio
    // #661/#878, fixed in 15). A crash cannot be caught, so skip it there.
    static var isSupported: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 }

    /// Downloads and compiles the diarizer models; nothing to do on macOS 14.
    static func prefetch() async throws {
        guard isSupported else { return }
        try await OfflineDiarizerManager(config: OfflineDiarizerConfig()).prepareModels()
    }

    func spans(in wav: URL) async throws -> [SpeakerSpan] {
        guard Self.isSupported else { throw DiarizationError.unsupportedOS }
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        let result = try await manager.process(wav)
        return result.segments.map {
            SpeakerSpan(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
    }
}

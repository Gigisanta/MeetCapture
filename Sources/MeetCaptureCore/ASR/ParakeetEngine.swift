// ParakeetEngine.swift
// Local CoreML ASR and offline diarization through FluidAudio.
// ASR requests CPU/Neural Engine; effective placement is not instrumented.
// Concurrent ASR jobs share one load; the final release clears its model state.
// The offline diarizer has its own job-scoped manager.
// Models download once to ~/Library/Application Support/FluidAudio (CC-BY-4.0;
// see docs/THIRD_PARTY.md); the disk cache survives model release.

import CryptoKit
import FluidAudio
import Foundation

protocol SpeechRecognizer: Sendable {
    /// Loads the model and returns the identity of the artifacts/configuration in use.
    /// The first use may download models; recognition itself is always local.
    func prepare() async throws -> RecognitionIdentity
    /// Balances each successful prepare, including after a failed/cancelled job.
    /// The last user releases the models; concurrent jobs keep their own hold.
    func release() async
    /// Call after prepare: 16 kHz mono words timed from the start of `samples`.
    func words(in samples: [Float], language: String) async throws -> [Segment]
}

protocol SpeakerDiarizing: Sendable {
    func spans(in wav: URL) async throws -> [SpeakerSpan]
}

actor ParakeetEngine: SpeechRecognizer {
    static let shared = ParakeetEngine()
    static let modelName = "parakeet-tdt-0.6b-ultra"
    private static let version = AsrModelVersion.ultra
    private static let configuration = ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                                encoderHiddenSize: version.encoderHiddenSize)

    private struct LoadedModel: Sendable {
        var manager: AsrManager
        var identity: RecognitionIdentity
    }
    /// One load shared by concurrent callers; actor reentrancy must not load
    /// a second copy of the models.
    private var loading: Task<LoadedModel, Error>?
    private var users = 0

    func prepare() async throws -> RecognitionIdentity {
        try Task.checkCancellation()
        // Register before suspension so a finishing job cannot unload a model
        // another job is still preparing to use.
        users += 1
        do {
            let loaded = try await loaded()
            try Task.checkCancellation()
            return loaded.identity
        } catch {
            await release()
            throw error
        }
    }

    func words(in samples: [Float], language: String) async throws -> [Segment] {
        try Task.checkCancellation()
        let manager = try await loaded().manager
        try Task.checkCancellation()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state,
                                                  language: Language(rawValue: language))
        // CoreML may finish an in-flight prediction after cancellation. Never
        // publish that result or let the chunker checkpoint it as completed.
        try Task.checkCancellation()
        return try Self.timedWords(from: result)
    }

    /// Paired with prepare by the job/prefetch owner. Clearing the shared load
    /// before cleanup lets a later job load afresh without touching this manager.
    func release() async {
        precondition(users > 0, "SpeechRecognizer.release requires an active model user")
        users -= 1
        guard users == 0, let task = loading else { return }
        loading = nil
        await (try? task.value)?.manager.cleanup()
    }

    private func loaded() async throws -> LoadedModel {
        if let loading { return try await loading.value }
        // A cancelled waiter must not cancel a load shared with another caller.
        let task = Task<LoadedModel, Error> {
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: Self.configuration)
            do {
                try await manager.loadModels(models)
                let revision = try Self.artifactRevision(in: AsrModels.defaultCacheDirectory(for: Self.version))
                let identity = Self.recognitionIdentity(modelRevision: revision,
                                                        decoderLayers: await manager.decoderLayerCount,
                                                        computeUnits: models.configuration.computeUnits.rawValue)
                return LoadedModel(manager: manager, identity: identity)
            } catch {
                await manager.cleanup()
                throw error
            }
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

    /// The SDK's cache is not pinned to an immutable Hub revision. Identify the
    /// actual loaded Ultra bundles and vocabulary instead of inventing one.
    /// This bounded scan runs once per shared model load, never per chunk.
    static func artifactRevision(in directory: URL) throws -> String {
        let fm = FileManager.default
        var files: [(path: String, url: URL)] = []
        func collect(_ folder: URL, prefix: String) throws {
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) {
                let path = prefix + url.lastPathComponent
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                if values.isDirectory == true {
                    try collect(url, prefix: path + "/")
                } else if values.isRegularFile == true {
                    files.append((path, url))
                }
            }
        }
        for bundle in ModelNames.ASR.requiredModelsV3().sorted() {
            let before = files.count
            try collect(directory.appendingPathComponent(bundle), prefix: bundle + "/")
            guard files.count > before else { throw CocoaError(.fileReadCorruptFile) }
        }
        let vocabulary = ModelNames.ASR.vocabularyFile
        files.append((vocabulary, directory.appendingPathComponent(vocabulary)))
        var hash = SHA256()
        for file in files.sorted(by: { $0.path < $1.path }) {
            let digest = try ContentFingerprint.sha256(file.url)
            hash.update(data: Data("\(file.path)\t\(digest)\n".utf8))
        }
        return "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func recognitionIdentity(modelRevision: String, decoderLayers: Int,
                                             computeUnits: Int) -> RecognitionIdentity {
        let config = configuration, tdt = config.tdtConfig
        return RecognitionIdentity(
            engine: .parakeet, model: modelName, modelRepository: Repo.parakeetUltra.rawValue,
            modelRevision: modelRevision, sdk: "FluidAudio",
            sdkRevision: "bd11ac8da17a944a7291a2c76e9a172eb275f629",
            configuration: [
                "adapter": "validated-token-order-v1",
                "modelVersion": String(describing: version),
                "sampleRate": String(config.sampleRate),
                "encoderHiddenSize": String(config.encoderHiddenSize),
                "decoderLayers": String(decoderLayers),
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
                "tdt.durationBins": tdt.durationBins.map { String($0) }.joined(separator: ","),
                "tdt.blankId": String(tdt.blankId),
                "tdt.boundarySearchFrames": String(tdt.boundarySearchFrames),
                "tdt.maxTokensPerChunk": String(tdt.maxTokensPerChunk),
                "tdt.consecutiveBlankLimit": String(tdt.consecutiveBlankLimit),
                "compute.encoderDecoder": String(computeUnits),
                "compute.preprocessor": "cpuOnly",
            ])
    }

    enum AdapterError: LocalizedError {
        case missingTimedWords
        case invalidTimedWords

        var errorDescription: String? {
            switch self {
            case .missingTimedWords:
                return "El motor devolvió texto sin palabras temporizadas; se conserva el audio para reintentar"
            case .invalidTimedWords:
                return "El motor devolvió tiempos de palabra inválidos; se conserva el audio para reintentar"
            }
        }
    }

    /// Nonempty SDK text without valid real timings is a failed chunk, not
    /// successful silence. Empty SDK output remains valid for noise/silence.
    /// SentencePiece boundaries start words; continuation pieces/punctuation attach
    /// in SDK token order. Validate before aggregation can hide a broken piece.
    static func timedWords(from result: ASRResult) throws -> [Segment] {
        var words: [Segment] = []
        var boundaryPending = false
        for token in result.tokenTimings ?? [] {
            let boundary = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
            let text = token.token.replacingOccurrences(of: "▁", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                boundaryPending = boundaryPending || boundary
                continue
            }
            guard token.startTime.isFinite, token.endTime.isFinite,
                  token.startTime >= 0, token.endTime >= token.startTime
            else { throw AdapterError.invalidTimedWords }
            if boundary || boundaryPending || words.isEmpty {
                words.append(Segment(start: token.startTime, end: token.endTime, text: text,
                                     confidence: token.confidence))
            } else {
                words[words.count - 1].text += text
                words[words.count - 1].end = token.endTime
                // A word is as doubtful as its weakest piece.
                words[words.count - 1].confidence = min(words[words.count - 1].confidence ?? 1, token.confidence)
            }
            boundaryPending = false
        }
        guard words.allSatisfy(\.hasValidTiming) else { throw AdapterError.invalidTimedWords }
        if words.isEmpty, result.text.unicodeScalars.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) {
            throw AdapterError.missingTimedWords
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
        try Task.checkCancellation()
        guard Self.isSupported else { throw DiarizationError.unsupportedOS }
        let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
        try await manager.prepareModels()
        try Task.checkCancellation()
        let result = try await manager.process(wav)
        try Task.checkCancellation()
        return result.segments.map {
            SpeakerSpan(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
        }
    }
}

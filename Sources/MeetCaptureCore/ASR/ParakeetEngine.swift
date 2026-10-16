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
    /// Loads (and on first use downloads) the model; throws when unavailable.
    func prepare() async throws
    /// Words of 16 kHz mono samples in [-1, 1], timed from the start of `samples`.
    func words(in samples: [Float], language: String) async throws -> [Segment]
}

protocol SpeakerDiarizing: Sendable {
    func spans(in wav: URL) async throws -> [SpeakerSpan]
}

actor ParakeetEngine: SpeechRecognizer {
    static let shared = ParakeetEngine()
    static let modelName = "parakeet-tdt-0.6b-ultra"
    private static let version = AsrModelVersion.ultra
    private var manager: AsrManager?

    func prepare() async throws { _ = try await loaded() }

    func words(in samples: [Float], language: String) async throws -> [Segment] {
        let manager = try await loaded()
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state,
                                                  language: Language(rawValue: language))
        return Self.words(from: result.tokenTimings ?? [])
    }

    /// Frees the CoreML models; the next call loads them again.
    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    var isLoaded: Bool { manager != nil }

    private func loaded() async throws -> AsrManager {
        if let manager { return manager }
        let version = Self.version
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId),
                                                   encoderHiddenSize: version.encoderHiddenSize))
        try await manager.loadModels(models)
        self.manager = manager
        return manager
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

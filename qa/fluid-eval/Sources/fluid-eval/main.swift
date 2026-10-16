// fluid-eval — FluidAudio runs for qa/asr_eval.py.
//
//   fluid-eval asr --wav X.wav --out hyp.json [--model v3|ultra] [--vocab terms.txt]
//   fluid-eval diarize --wav X.wav --out dia.json [--threshold 0.6] [--step-ratio 0.2]
//                      [--num-speakers N] [--max-speakers N]
//
// Both write {"engine", "segments": [{start, end, text?, speaker?}], "info"}.
// Models download on first use to FluidAudio's cache. Wall time, RSS and GPU
// are measured by the caller, not here.
import FluidAudio
import Foundation

struct Segment: Encodable {
    var start: Double
    var end: Double
    var text: String?
    var speaker: String?
}

struct Output: Encodable {
    var engine: String
    var segments: [Segment]
    var info: [String: String]
}

struct Usage: Error, CustomStringConvertible {
    let description: String
}

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func required(_ name: String, in args: [String]) throws -> String {
    guard let value = option(name, in: args) else { throw Usage(description: "falta \(name)") }
    return value
}

func write(_ output: Output, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(output).write(to: URL(fileURLWithPath: path), options: .atomic)
}

/// Splits token timings into segments at pauses longer than `gap` seconds or
/// at a word start once a segment passes `maxLength` seconds.
func segmentTokens(_ tokens: [TokenTiming], gap: Double = 0.6, maxLength: Double = 20) -> [[TokenTiming]] {
    var segments: [[TokenTiming]] = []
    var current: [TokenTiming] = []
    for token in tokens {
        if let last = current.last, let first = current.first {
            let wordStart = token.token.hasPrefix("▁") || token.token.hasPrefix(" ")
            let pause = token.startTime - last.endTime > gap
            let long = token.startTime - first.startTime > maxLength
            if wordStart && (pause || long) {
                segments.append(current)
                current = []
            }
        }
        current.append(token)
    }
    if !current.isEmpty { segments.append(current) }
    return segments
}

func text(of tokens: [TokenTiming]) -> String {
    tokens.map(\.token).joined()
        .replacingOccurrences(of: "▁", with: " ")
        .trimmingCharacters(in: .whitespaces)
}

func runASR(_ args: [String]) async throws {
    let wav = try required("--wav", in: args)
    let out = try required("--out", in: args)
    let modelName = option("--model", in: args) ?? "v3"
    let version: AsrModelVersion
    switch modelName {
    case "v3": version = .v3
    case "ultra": version = .ultra
    default: throw Usage(description: "--model debe ser v3 o ultra")
    }
    let language = Language(rawValue: option("--language", in: args) ?? "es")

    let models = try await AsrModels.downloadAndLoad(version: version)
    let config = ASRConfig(
        tdtConfig: TdtConfig(blankId: version.blankId),
        encoderHiddenSize: version.encoderHiddenSize
    )
    let manager = AsrManager(config: config)
    try await manager.loadModels(models)

    let samples = try AudioConverter().resampleAudioFile(path: wav)
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(samples, decoderState: &state, language: language)
    let groups = segmentTokens(result.tokenTimings ?? [])

    var session: VocabularyBoostingSession?
    if let vocabPath = option("--vocab", in: args) {
        let (vocabulary, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabPath)
        session = try await VocabularyBoostingSession(vocabulary: vocabulary, ctcModels: ctcModels)
    }

    let sampleRate = 16_000.0
    let pad = 0.3
    var segments: [Segment] = []
    var rescored = 0
    for group in groups {
        guard let first = group.first, let last = group.last else { continue }
        var segmentText = text(of: group)
        if let session {
            // Rescoring is segment-local: timings shifted to the cut audio.
            let from = max(0, first.startTime - pad)
            let to = min(Double(samples.count) / sampleRate, last.endTime + pad)
            let audio = Array(samples[Int(from * sampleRate)..<Int(to * sampleRate)])
            let local = group.map {
                TokenTiming(
                    token: $0.token, tokenId: $0.tokenId,
                    startTime: $0.startTime - from, endTime: $0.endTime - from,
                    confidence: $0.confidence)
            }
            if let output = await session.rescore(text: segmentText, tokenTimings: local, audioSamples: audio),
               output.text != segmentText {
                segmentText = output.text
                rescored += 1
            }
        }
        segments.append(Segment(start: first.startTime, end: last.endTime, text: segmentText))
    }

    let engine = "parakeet-\(modelName)" + (session == nil ? "" : "-vocab")
    try write(
        Output(
            engine: engine, segments: segments,
            info: [
                "audio_s": String(format: "%.2f", Double(samples.count) / sampleRate),
                "segments_rescored": String(rescored),
            ]),
        to: out)
}

func runDiarize(_ args: [String]) async throws {
    let wav = try required("--wav", in: args)
    let out = try required("--out", in: args)
    var config = OfflineDiarizerConfig()
    if let value = option("--threshold", in: args).flatMap(Double.init) { config.clusteringThreshold = value }
    if let value = option("--step-ratio", in: args).flatMap(Double.init) { config.segmentationStepRatio = value }
    if let value = option("--num-speakers", in: args).flatMap(Int.init) { config.clustering.numSpeakers = value }
    if let value = option("--max-speakers", in: args).flatMap(Int.init) { config.clustering.maxSpeakers = value }

    let manager = OfflineDiarizerManager(config: config)
    try await manager.prepareModels()
    let result = try await manager.process(URL(fileURLWithPath: wav))
    let segments = result.segments.map {
        Segment(start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds), speaker: $0.speakerId)
    }
    try write(
        Output(
            engine: "fluid-offline-diarizer", segments: segments,
            info: [
                "threshold": String(config.clusteringThreshold),
                "step_ratio": String(config.segmentationStepRatio),
                "speakers": String(Set(segments.compactMap(\.speaker)).count),
            ]),
        to: out)
}

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    switch arguments.first {
    case "asr": try await runASR(arguments)
    case "diarize": try await runDiarize(arguments)
    default: throw Usage(description: "uso: fluid-eval asr|diarize --wav X --out Y [opciones]")
    }
} catch {
    FileHandle.standardError.write(Data("fluid-eval: \(error)\n".utf8))
    exit(2)
}

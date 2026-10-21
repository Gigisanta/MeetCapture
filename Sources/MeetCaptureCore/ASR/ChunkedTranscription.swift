// ChunkedTranscription.swift
// Recognition uses 300 s (production), 600 s, or a disk-backed whole-channel
// diagnostic. Mic gating always retains the original 300 s quiet-cut partitions,
// including their filter resets, reference history and untouched fractional tails.
// Checkpoints live next to the capture; original audio is never invalidated.

import Accelerate
import AVFoundation
import CryptoKit
import Foundation

struct ChunkManifest: Codable, Equatable {
    /// v4 binds derived words to audio content and the effective recognizer/pipeline.
    /// Old manifests without these required identities cannot decode or be reused.
    static let currentVersion = 4
    var version = ChunkManifest.currentVersion
    var audioBytes: UInt64
    var sourceSHA256: String
    var language: String
    var recognizer: QATrace.RecognizerIdentity
    var chunking: ChunkingIdentity
    var gate: GateIdentity?
    /// Recognition boundaries, distinct from the fixed baseline gate partitions.
    var boundaries: [Int]

    struct ChunkingIdentity: Codable, Equatable {
        var version = 1
        var options: ChunkedTranscription.Options
        var sampleRate = ChunkedTranscription.sampleRate
        var searchSamples = ChunkedTranscription.searchSamples
        var frameSamples = ChunkedTranscription.frameSamples
        var attempts = ChunkedTranscription.attempts
        var silentPeak = ChunkedTranscription.silentPeak
        var checkpointGranularity: String

        init(options: ChunkedTranscription.Options) {
            self.options = options
            checkpointGranularity = options.chunkSeconds == 0 ? "complete-channel-only" : "recognition-chunk"
        }
    }

    struct GateIdentity: Codable, Equatable {
        var version = 1
        var partitionVersion = 1
        var partitionSeconds = ChunkedTranscription.baselineChunkSeconds
        var partitionPolicy = "baseline300-quiet-cut; reset-filter-per-part; preserve-fractional-tail"
        var partitionSearchSamples = ChunkedTranscription.searchSamples
        var partitionFrameSamples = ChunkedTranscription.frameSamples
        var boundaries: [Int]
        /// SHA-256 of each boundary encoded as a signed little-endian Int64.
        var boundariesSHA256: String
        var referenceSHA256: String
        var referenceHistorySamples = BleedGate.maxLagSamples
        var windowSamples = BleedGate.windowSamples
        var correlation = BleedGate.correlation
        var dominanceDB = BleedGate.dominanceDB
        var silenceDB = BleedGate.silenceDB
        var bandpassVersion = "BleedGate-four-biquads-200-4000Hz-v1"
    }
}

struct ChunkedResult: Sendable {
    var words: [Segment]
    /// One placeholder per chunk the engine failed on twice; the caller keeps the audio.
    var gaps: [Segment]
    var failedChunks: Int { gaps.count }
}

enum ChunkedTranscription {
    static let sampleRate = PCMToWAV.targetSampleRate
    static let baselineChunkSeconds = 300
    static let searchSamples = 10 * sampleRate
    static let frameSamples = sampleRate / 10
    static let attempts = 2
    /// A chunk this quiet (or fully muted by the gate) has no words to find.
    static let silentPeak: Float = 1e-4

    /// Launch-scoped QA controls, explicit here so cache identity and execution
    /// cannot accidentally use different settings. Production resolves to 300 s.
    struct Options: Codable, Equatable, Sendable {
        var chunkSeconds: Int
        var seamGapSeconds: Double
        var lexicalMicDedupe: Bool
        var repairCapture: Bool
        var whisperPrompt: Bool

        static var current: Options {
            Options(chunkSeconds: QAExperiment.chunkSeconds,
                    seamGapSeconds: QAExperiment.seamGapSeconds,
                    lexicalMicDedupe: QAExperiment.lexicalMicDedupe,
                    repairCapture: QAExperiment.repairCapture,
                    whisperPrompt: QAExperiment.whisperPrompt)
        }
    }

    /// A scan never materializes a complete channel, including under QA tracing.
    private static let fileScanSamples = 30 * sampleRate

    static func workDirectory(forAudio path: String) -> String { path + ".work" }

    /// Checkpoints are dropped only once the transcript is durably handed off.
    static func removeWork(forAudio path: String) {
        try? FileManager.default.removeItem(atPath: workDirectory(forAudio: path))
    }

    /// Start of the quietest 100 ms frame in `window` (which begins at `windowStart`).
    static func quietestCut(in window: [Int16], windowStart: Int) -> Int {
        guard window.count >= frameSamples else { return windowStart + window.count / 2 }
        var best = 0
        var bestEnergy = Int64.max
        var frame = 0
        while frame + frameSamples <= window.count {
            var energy: Int64 = 0
            for i in frame..<(frame + frameSamples) {
                let v = Int64(window[i])
                energy += v * v
            }
            if energy < bestEnergy { bestEnergy = energy; best = frame }
            frame += frameSamples
        }
        return windowStart + best
    }

    /// Nominal recognition cuts, moved to the quietest frame within ±10 s.
    /// Zero is one file-backed recognition unit; it does not read the channel.
    /// Gate callers always use the baseline 300 s value, independently of ASR.
    static func boundaries(totalSamples: Int, chunkSeconds: Int = baselineChunkSeconds,
                           read: (Int, Int) throws -> [Int16]) rethrows -> [Int] {
        guard chunkSeconds > 0 else { return [0, totalSamples] }
        let targetChunkSamples = chunkSeconds * sampleRate
        var cuts = [0]
        var nominal = targetChunkSamples
        while nominal + targetChunkSamples / 2 < totalSamples {
            let start = max(cuts[cuts.count - 1] + frameSamples, nominal - searchSamples)
            let end = min(totalSamples, nominal + searchSamples)
            let cut = quietestCut(in: try read(start, end), windowStart: start)
            cuts.append(cut)
            nominal = cut + targetChunkSamples
        }
        cuts.append(totalSamples)
        return cuts
    }

    /// Transcribes a 16 kHz mono channel. A mic/reference pair always uses the
    /// original baseline gate partitions, independently of recognition geometry.
    static func run(wav: URL, workDirectory work: String, audioBytes: UInt64, gateReference: URL? = nil,
                    language: String, recognizer: any SpeechRecognizer, options: Options = .current,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ChunkedResult {
        if QATrace.isEnabled {
            var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
            context.channel = URL(fileURLWithPath: work).lastPathComponent
            context.sampleRate = sampleRate
            return try await QATrace.$context.withValue(context) {
                try await runChannel(wav: wav, workDirectory: work, audioBytes: audioBytes,
                                     gateReference: gateReference, language: language,
                                     recognizer: recognizer, options: options, progress: progress)
            }
        }
        return try await runChannel(wav: wav, workDirectory: work, audioBytes: audioBytes,
                                    gateReference: gateReference, language: language,
                                    recognizer: recognizer, options: options, progress: progress)
    }

    private static func runChannel(wav: URL, workDirectory work: String, audioBytes: UInt64,
                                   gateReference: URL?, language: String, recognizer: any SpeechRecognizer,
                                   options: Options,
                                   progress: @escaping @Sendable (Double) -> Void) async throws -> ChunkedResult {
        let traceEnabled = QATrace.isEnabled
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: false)
        let reference = try gateReference.map {
            try AVAudioFile(forReading: $0, commonFormat: .pcmFormatInt16, interleaved: false)
        }
        let total = Int(file.length)
        guard total > 0 else { throw TranscriptionError.emptyAudio }

        try Task.checkCancellation()
        let cuts = try boundaries(totalSamples: total, chunkSeconds: options.chunkSeconds) {
            try readSamples(file, from: $0, to: $1)
        }
        let gate: ChunkManifest.GateIdentity?
        if let gateReference {
            let gateCuts: [Int]
            if options.chunkSeconds == baselineChunkSeconds {
                gateCuts = cuts
            } else {
                gateCuts = try boundaries(totalSamples: total) { try readSamples(file, from: $0, to: $1) }
            }
            gate = ChunkManifest.GateIdentity(boundaries: gateCuts,
                                             boundariesSHA256: boundariesSHA256(gateCuts),
                                             referenceSHA256: try fileSHA256(gateReference))
        } else {
            gate = nil
        }
        let manifest = ChunkManifest(audioBytes: audioBytes, sourceSHA256: try fileSHA256(wav),
                                     language: language, recognizer: recognizer.identity,
                                     chunking: .init(options: options), gate: gate, boundaries: cuts)
        let manifestURL = URL(fileURLWithPath: work + "/manifest.json")
        let saved = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(ChunkManifest.self, from: $0) }
        let reusedManifest = saved == manifest
        if !reusedManifest {
            try invalidateDerived(in: work, preserving: [wav, gateReference].compactMap { $0 })
            try AppPaths.ensurePrivateDirectory(work)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        }
        let count = cuts.count - 1
        if traceEnabled {
            try QATrace.write(ChannelTrace(sourceWAV: wav.path, gateReferenceWAV: gateReference?.path,
                                            workDirectory: work, manifestReused: reusedManifest,
                                            manifest: manifest, identity: recognizer.identity),
                              name: "channel-manifest")
        }

        if options.chunkSeconds == 0 {
            let result = try await runWholeChannel(file: file, reference: reference, gate: gate,
                                                  work: work, language: language, recognizer: recognizer)
            if traceEnabled {
                try QATrace.write(WordsTrace(words: result.words, gaps: result.gaps), name: "channel-words")
            }
            guard result.gaps.isEmpty else { throw TranscriptionError.emptyOutput }
            progress(1)
            return result
        }

        // The baseline path still gates each original 300 s part directly. Other
        // geometries consume that exact same gated PCM, prepared in bounded parts.
        var prepared: AVAudioFile?
        if options.chunkSeconds != baselineChunkSeconds, let reference, let gate {
            let input = try prepareGatedFile(file: file, reference: reference, gate: gate, work: work)
            prepared = try AVAudioFile(forReading: input.url, commonFormat: .pcmFormatInt16, interleaved: false)
        }
        var words: [Segment] = []
        var gaps: [Segment] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let chunk = try await runChunk(file: file, reference: reference, prepared: prepared,
                                           work: work, index: index, count: count,
                                           start: cuts[index], end: cuts[index + 1], language: language,
                                           recognizer: recognizer)
            words += chunk.words
            gaps += chunk.gaps
            if chunk.gaps.isEmpty { progress(Double(index + 1) / Double(count)) }
        }
        if traceEnabled { try QATrace.write(WordsTrace(words: words, gaps: gaps), name: "channel-words") }
        // Nothing transcribed: fail so the capture stays recoverable.
        guard gaps.count < count else { throw TranscriptionError.emptyOutput }
        return ChunkedResult(words: words, gaps: gaps)
    }

    private struct FileInput {
        var url: URL
        var peak: Float
        /// Hash of the exact normalized Float32 samples, not the WAV container.
        var inputSHA256: String
    }

    private struct FileInputTrace: Encodable {
        var recognitionInputWAV: String
        var inputSHA256: String
        var sampleCount: Int
        var peak: Float
        var gate: ChunkManifest.GateIdentity?
        let checkpointGranularity = "complete-channel-only"
        let cancellationRecovery = "retry-the-complete-channel; no-internal-checkpoints"
        let ungatedScanPartSamples = ChunkedTranscription.fileScanSamples
    }

    private static func runWholeChannel(file: AVAudioFile, reference: AVAudioFile?,
                                        gate: ChunkManifest.GateIdentity?, work: String,
                                        language: String, recognizer: any SpeechRecognizer) async throws -> ChunkedResult {
        try Task.checkCancellation()
        let doneURL = checkpointURL(work: work, index: 0)
        let cached = (try? Data(contentsOf: doneURL))
            .flatMap { try? JSONDecoder().decode([Segment].self, from: $0) }
        if let cached, !QATrace.isEnabled { return ChunkedResult(words: cached, gaps: []) }

        let input: FileInput
        if let reference, let gate {
            input = try prepareGatedFile(file: file, reference: reference, gate: gate, work: work)
        } else {
            input = try scanFileInput(file)
        }
        let total = Int(file.length)
        if QATrace.isEnabled {
            var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
            context.chunkIndex = 0
            context.chunkCount = 1
            context.startSample = 0
            context.endSample = total
            context.offsetSeconds = 0
            context.inputSHA256 = input.inputSHA256
            return try await QATrace.$context.withValue(context) {
                try QATrace.write(FileInputTrace(recognitionInputWAV: input.url.path,
                                                 inputSHA256: input.inputSHA256, sampleCount: total,
                                                 peak: input.peak, gate: gate), name: "file-input")
                return try await decodeChunk(peak: input.peak, cached: cached, doneURL: doneURL,
                                             index: 0, start: 0, end: total) {
                    try await recognizer.words(inFile: input.url, language: language)
                }
            }
        }
        return try await decodeChunk(peak: input.peak, cached: nil, doneURL: doneURL,
                                     index: 0, start: 0, end: total) {
            try await recognizer.words(inFile: input.url, language: language)
        }
    }

    /// Non-gated file-mode inputs are scanned in small pieces to prove silence
    /// and hash/trace the real input without allocating an entire meeting.
    private static func scanFileInput(_ file: AVAudioFile) throws -> FileInput {
        let total = Int(file.length)
        var peak: Float = 0
        var hash = SHA256()
        let count = (total - 1) / fileScanSamples + 1
        for index in 0..<count {
            try Task.checkCancellation()
            let start = index * fileScanSamples
            let end = min(total, start + fileScanSamples)
            let samples = normalized(try readSamples(file, from: start, to: end))
            guard samples.count == end - start else { throw PCMToWAV.ConversionError.invalidData }
            peak = max(peak, vDSP.maximumMagnitude(samples))
            samples.withUnsafeBytes { hash.update(bufferPointer: $0) }
            try traceGatePart(original: samples, gated: samples, reference: nil,
                              index: index, count: count, start: start, end: end)
        }
        return FileInput(url: file.url, peak: peak, inputSHA256: hex(hash.finalize()))
    }

    /// Keep the original gate call boundaries even when recognition uses another
    /// geometry. Each part is the same Int16 -> Float32 -> BleedGate calculation
    /// as production 300 s; only muted samples are changed back to Int16 zero.
    private static func prepareGatedFile(file: AVAudioFile, reference: AVAudioFile,
                                         gate: ChunkManifest.GateIdentity, work: String) throws -> FileInput {
        let total = Int(file.length)
        guard total <= PCMToWAV.maxWAVSamples else { throw PCMToWAV.ConversionError.tooLarge }
        let fm = FileManager.default
        let url = URL(fileURLWithPath: work + "/gated-input.wav")
        let partial = URL(fileURLWithPath: work + "/gated-input.partial.wav")
        for derived in [url, partial] {
            try protectOriginals(from: derived, originals: [file.url, reference.url])
        }
        if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        fm.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: partial)
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? fm.removeItem(at: partial) }
        }
        try handle.write(contentsOf: PCMToWAV.header(dataSize: UInt32(total * 2)))
        var peak: Float = 0
        var hash = SHA256()
        let count = gate.boundaries.count - 1
        for index in 0..<count {
            try Task.checkCancellation()
            let start = gate.boundaries[index], end = gate.boundaries[index + 1]
            var pcm = try readSamples(file, from: start, to: end)
            guard pcm.count == end - start else { throw PCMToWAV.ConversionError.invalidData }
            let original = normalized(pcm)
            let system = try history(reference, from: start, count: pcm.count)
            let gated = BleedGate.apply(mic: original, system: system)
            peak = max(peak, vDSP.maximumMagnitude(gated))
            gated.withUnsafeBytes { hash.update(bufferPointer: $0) }
            try traceGatePart(original: original, gated: gated, reference: system,
                              index: index, count: count, start: start, end: end)
            for sample in pcm.indices where gated[sample] == 0 { pcm[sample] = 0 }
            try pcm.withUnsafeBytes {
                try handle.write(contentsOf: Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: $0.baseAddress!),
                                                   count: $0.count, deallocator: .none))
            }
        }
        try Task.checkCancellation()
        try handle.synchronize()
        try handle.close()
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: partial, to: url)
        finished = true
        return FileInput(url: url, peak: peak, inputSHA256: hex(hash.finalize()))
    }

    private static func traceGatePart(original: [Float], gated: [Float], reference: [Float]?,
                                       index: Int, count: Int, start: Int, end: Int) throws {
        guard QATrace.isEnabled else { return }
        var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
        context.chunkIndex = index
        context.chunkCount = count
        context.startSample = start
        context.endSample = end
        context.offsetSeconds = Double(start) / Double(sampleRate)
        context.inputSHA256 = QATrace.audioSHA256(gated)
        try QATrace.$context.withValue(context) {
            try QATrace.writeAudio(original, name: "gate-input")
            try QATrace.writeAudio(gated, name: "gate-output")
            if let reference { try QATrace.writeAudio(reference, name: "gate-reference-with-history") }
            try QATrace.write(gateTrace(original: original, gated: gated, referenceCount: reference?.count),
                              name: "gate-mask")
        }
    }

    private static func checkpointURL(work: String, index: Int) -> URL {
        URL(fileURLWithPath: String(format: "%@/chunk-%03d.json", work, index))
    }

    private static func protectOriginals(from derived: URL, originals: [URL]) throws {
        let path = derived.resolvingSymlinksInPath().standardizedFileURL.path
        guard !originals.contains(where: {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == path
        }) else {
            throw CocoaError(.fileWriteInvalidFileName,
                             userInfo: [NSLocalizedDescriptionKey: "Derived checkpoint path overlaps original audio"])
        }
    }

    /// Invalidate only files owned by this chunker, never arbitrary work contents
    /// or the source/reference WAVs. Errors are not hidden as a valid fresh cache.
    private static func invalidateDerived(in work: String, preserving originals: [URL]) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: work) else { return }
        for url in try fm.contentsOfDirectory(at: URL(fileURLWithPath: work), includingPropertiesForKeys: nil) {
            let name = url.lastPathComponent
            let isChunk = name.hasPrefix("chunk-") && name.hasSuffix(".json")
                && name.dropFirst(6).dropLast(5).allSatisfy { $0 >= "0" && $0 <= "9" }
            guard isChunk || ["manifest.json", "gated-input.wav", "gated-input.partial.wav"].contains(name) else { continue }
            try protectOriginals(from: url, originals: originals)
            try fm.removeItem(at: url)
        }
    }

    /// FileHandle owns one bounded buffer; neither source hashing nor gate
    /// reference hashing makes a second audio array or maps a complete meeting.
    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hex(hash.finalize())
    }

    private static func boundariesSHA256(_ boundaries: [Int]) -> String {
        var hash = SHA256()
        for boundary in boundaries {
            var value = Int64(boundary).littleEndian
            withUnsafeBytes(of: &value) { hash.update(bufferPointer: $0) }
        }
        return hex(hash.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func runChunk(file: AVAudioFile, reference: AVAudioFile?, prepared: AVAudioFile?,
                                 work: String, index: Int, count: Int, start: Int, end: Int, language: String,
                                 recognizer: any SpeechRecognizer) async throws -> ChunkedResult {
        let traceEnabled = QATrace.isEnabled
        let doneURL = checkpointURL(work: work, index: index)
        let cached = (try? Data(contentsOf: doneURL))
            .flatMap { try? JSONDecoder().decode([Segment].self, from: $0) }
        if let cached, !traceEnabled { return ChunkedResult(words: cached, gaps: []) }

        var samples = normalized(try readSamples(prepared ?? file, from: start, to: end))
        let original = traceEnabled && prepared == nil ? samples : nil
        var tracedReference: [Float]?
        if let reference, prepared == nil {
            let system = try history(reference, from: start, count: samples.count)
            samples = BleedGate.apply(mic: samples, system: system)
            if traceEnabled { tracedReference = system }
        }
        if traceEnabled {
            var context = QATrace.context ?? QATrace.Context(jobID: UUID().uuidString)
            context.chunkIndex = index
            context.chunkCount = count
            context.startSample = start
            context.endSample = end
            context.offsetSeconds = Double(start) / Double(sampleRate)
            context.inputSHA256 = QATrace.audioSHA256(samples)
            return try await QATrace.$context.withValue(context) {
                if let original {
                    try QATrace.writeAudio(original, name: "gate-input")
                    try QATrace.writeAudio(samples, name: "gate-output")
                    if let tracedReference {
                        try QATrace.writeAudio(tracedReference, name: "gate-reference-with-history")
                    }
                    try QATrace.write(gateTrace(original: original, gated: samples,
                                                referenceCount: tracedReference?.count), name: "gate-mask")
                }
                return try await decodeChunk(peak: vDSP.maximumMagnitude(samples), cached: cached, doneURL: doneURL,
                                             index: index, start: start, end: end) {
                    try await recognizer.words(in: samples, language: language)
                }
            }
        }
        return try await decodeChunk(peak: vDSP.maximumMagnitude(samples), cached: nil, doneURL: doneURL,
                                     index: index, start: start, end: end) {
            try await recognizer.words(in: samples, language: language)
        }
    }

    private static func decodeChunk(peak: Float, cached: [Segment]?, doneURL: URL, index: Int,
                                    start: Int, end: Int,
                                    recognize: () async throws -> [Segment]) async throws -> ChunkedResult {
        let traceEnabled = QATrace.isEnabled
        if let cached {
            try QATrace.write(ChunkTrace(outcome: "checkpoint-reused-no-sdk-invocation",
                                         checkpoint: doneURL.path, peak: nil, words: cached, gaps: []),
                              name: "chunk-outcome")
            return ChunkedResult(words: cached, gaps: [])
        }
        let offset = Double(start) / Double(sampleRate)
        let skippedSilent = peak < silentPeak
        var found: [Segment]?
        if skippedSilent { found = [] }
        for attempt in 1...attempts where found == nil {
            try Task.checkCancellation()
            var invocationContext: QATrace.Context?
            if traceEnabled {
                invocationContext = QATrace.context
                invocationContext?.attempt = attempt
                invocationContext?.invocationID = UUID().uuidString
            }
            do {
                if let invocationContext {
                    found = try await QATrace.$context.withValue(invocationContext) {
                        try await recognize()
                    }
                } else {
                    found = try await recognize()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as QATrace.Failure {
                // Missing required evidence is not an ASR failure or a valid gap.
                throw error
            } catch {
                if traceEnabled {
                    try QATrace.$context.withValue(invocationContext) {
                        try QATrace.write(AttemptFailure(errorType: String(reflecting: type(of: error)),
                                                        message: error.localizedDescription),
                                          name: "chunk-attempt-failure")
                    }
                }
                AppInfo.logger("ChunkedTranscription").warning(
                    "chunk \(index) (intento \(attempt)) falló: \(error.localizedDescription, privacy: .public)")
            }
        }
        guard let found else {
            let endSec = Double(end) / Double(sampleRate)
            let gap = Segment(start: offset, end: endSec,
                              text: "[fragmento sin transcribir \(clock(offset))–\(clock(endSec))]")
            if traceEnabled {
                try QATrace.write(ChunkTrace(outcome: "failed-audio-preserved", checkpoint: nil,
                                             peak: peak, words: [], gaps: [gap]), name: "chunk-outcome")
            }
            return ChunkedResult(words: [], gaps: [gap])
        }
        let shifted = found.map {
            Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text, speaker: $0.speaker)
        }
        if traceEnabled {
            try QATrace.write(found, name: "chunk-adapted-words")
            try QATrace.write(ChunkTrace(outcome: skippedSilent ? "silent-peak-skipped" : "decoded",
                                         checkpoint: doneURL.path, peak: peak, words: shifted, gaps: []),
                              name: "chunk-outcome")
        }
        try JSONEncoder().encode(shifted).write(to: doneURL, options: .atomic)
        return ChunkedResult(words: shifted, gaps: [])
    }

    private struct ChannelTrace: Encodable {
        var sourceWAV: String
        var gateReferenceWAV: String?
        var workDirectory: String
        var manifestReused: Bool
        var manifest: ChunkManifest
        var identity: QATrace.RecognizerIdentity
        let sampleRate = ChunkedTranscription.sampleRate
        var targetChunkSamples: Int

        init(sourceWAV: String, gateReferenceWAV: String?, workDirectory: String,
             manifestReused: Bool, manifest: ChunkManifest, identity: QATrace.RecognizerIdentity) {
            self.sourceWAV = sourceWAV
            self.gateReferenceWAV = gateReferenceWAV
            self.workDirectory = workDirectory
            self.manifestReused = manifestReused
            self.manifest = manifest
            self.identity = identity
            targetChunkSamples = manifest.chunking.options.chunkSeconds * ChunkedTranscription.sampleRate
        }
        let searchSamples = ChunkedTranscription.searchSamples
        let frameSamples = ChunkedTranscription.frameSamples
        let attempts = ChunkedTranscription.attempts
        let silentPeak = ChunkedTranscription.silentPeak
    }

    private struct WordsTrace: Encodable {
        var words: [Segment]
        var gaps: [Segment]
    }

    private struct ChunkTrace: Encodable {
        var outcome: String
        var checkpoint: String?
        var peak: Float?
        let wordTimeBasis = "channel-seconds"
        var words: [Segment]
        var gaps: [Segment]
    }

    private struct AttemptFailure: Encodable {
        var errorType: String
        var message: String
    }

    private struct SampleRange: Encodable {
        var start: Int
        var count: Int
    }

    private struct GateTrace: Encodable {
        var applied: Bool
        var sampleCount: Int
        var referenceSampleCount: Int?
        var originalZeroSamples: Int
        var gatedZeroSamples: Int
        var changedSampleCount: Int
        /// This is an exact output-difference mask, not an inferred speech mask
        /// or a claim about decisions in windows that contained only zeros.
        let maskEncoding = "RLE: listed chunk-relative sample ranges changed bits; all other samples unchanged"
        var changedSampleRanges: [SampleRange]
        let referenceHistorySamples = BleedGate.maxLagSamples
        let windowSamples = BleedGate.windowSamples
        let correlation = BleedGate.correlation
        let dominanceDB = BleedGate.dominanceDB
        let silenceDB = BleedGate.silenceDB
    }

    private static func gateTrace(original: [Float], gated: [Float], referenceCount: Int?) -> GateTrace {
        var ranges: [SampleRange] = []
        var rangeStart: Int?
        var originalZeros = 0, gatedZeros = 0, changed = 0
        for index in original.indices {
            if original[index] == 0 { originalZeros += 1 }
            if gated[index] == 0 { gatedZeros += 1 }
            if original[index].bitPattern != gated[index].bitPattern {
                changed += 1
                if rangeStart == nil { rangeStart = index }
            } else if let start = rangeStart {
                ranges.append(SampleRange(start: start, count: index - start))
                rangeStart = nil
            }
        }
        if let start = rangeStart { ranges.append(SampleRange(start: start, count: original.count - start)) }
        return GateTrace(applied: referenceCount != nil, sampleCount: original.count,
                         referenceSampleCount: referenceCount, originalZeroSamples: originalZeros,
                         gatedZeroSamples: gatedZeros, changedSampleCount: changed,
                         changedSampleRanges: ranges)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// `count` reference samples from `start` plus `BleedGate.maxLagSamples`
    /// before them, zero-padded where the file has none.
    private static func history(_ file: AVAudioFile, from start: Int, count: Int) throws -> [Float] {
        let lag = BleedGate.maxLagSamples
        let from = max(0, start - lag)
        let to = min(start + count, Int(file.length))
        var span = [Float](repeating: 0, count: lag - (start - from))
        if to > from { span += normalized(try readSamples(file, from: from, to: to)) }
        let wanted = count + lag
        if span.count < wanted { span += [Float](repeating: 0, count: wanted - span.count) }
        return Array(span.prefix(wanted))
    }

    private static func normalized(_ samples: [Int16]) -> [Float] {
        vDSP.multiply(1 / Float(32_768), vDSP.integerToFloatingPoint(samples, floatingPointType: Float.self))
    }

    /// One read may return fewer frames than asked; loop until `end` or EOF.
    static func readSamples(_ file: AVAudioFile, from start: Int, to end: Int) throws -> [Int16] {
        let wanted = min(end, Int(file.length)) - start
        guard wanted > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                        frameCapacity: AVAudioFrameCount(wanted))
        else { return [] }
        var samples: [Int16] = []
        samples.reserveCapacity(wanted)
        file.framePosition = AVAudioFramePosition(start)
        while samples.count < wanted {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted - samples.count))
            guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { break }
            samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        }
        return samples
    }
}

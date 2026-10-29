// ChunkedTranscription.swift
// One channel is transcribed in ~5 min chunks cut at the quietest point near
// each boundary. Every finished chunk is checkpointed next to the capture
// (<audio>.work/<channel>/), so a crash, quit or engine failure resumes where
// it stopped instead of starting the whole meeting over.

import Accelerate
import AVFoundation
import Foundation

struct ChunkManifest: Codable, Equatable {
    /// v4 binds derived words to source content and the effective recognizer/pipeline.
    /// Older manifests lack required identities and are never reused.
    static let currentVersion = 4
    var version = ChunkManifest.currentVersion
    var audioBytes: UInt64
    var sourceSHA256: String
    var language: String
    var recognizer: RecognitionIdentity
    var chunking = ChunkingIdentity()
    var gate: GateIdentity?
    /// Sample offsets into the channel WAV: first 0, last the total.
    var boundaries: [Int]

    struct ChunkingIdentity: Codable, Equatable {
        var version = 1
        var sampleRate = ChunkedTranscription.sampleRate
        var targetSamples = ChunkedTranscription.targetChunkSamples
        var searchSamples = ChunkedTranscription.searchSamples
        var frameSamples = ChunkedTranscription.frameSamples
        var silentPeak = ChunkedTranscription.silentPeak
    }

    struct GateIdentity: Codable, Equatable {
        var version = 2
        var referenceSHA256: String
        var sampleRate = BleedGate.sampleRate
        var windowSamples = BleedGate.windowSamples
        var maxLagSamples = BleedGate.maxLagSamples
        var maxLeadSamples = BleedGate.maxLeadSamples
        var correlation = BleedGate.correlation
        var dominanceDB = BleedGate.dominanceDB
        var silenceDB = BleedGate.silenceDB
        var bandpass = "four-biquads-200-4000Hz-v1"
    }
}

/// These counts describe the actual samples processed, not word timestamps.
/// Failed chunks are deliberately not checkpointed: the next run still retries.
private struct ChunkMeasurement: Codable {
    enum Kind: String, Codable { case decoded, silence }
    var sampleCount: Int
    var kind: Kind
    var gatedSamples: Int?

    func isValid(for expectedSamples: Int, gated: Bool) -> Bool {
        guard (0...expectedSamples).contains(sampleCount),
              (gatedSamples != nil) == gated else { return false }
        guard let gatedSamples else { return true }
        return gatedSamples >= 0 && gatedSamples <= sampleCount
            && gatedSamples % BleedGate.windowSamples == 0
    }
}

/// New words and measurements commit atomically. Valid old word-array
/// checkpoints stay usable without rereading/gating audio just for metrics.
private struct ChunkCheckpoint: Codable {
    var words: [Segment]
    var quality: ChunkMeasurement?

    init(words: [Segment], quality: ChunkMeasurement) {
        self.words = words
        self.quality = quality
    }

    private enum CodingKeys: String, CodingKey { case words, quality }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([Segment].self) {
            words = legacy
            quality = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        words = try container.decode([Segment].self, forKey: .words)
        // Corrupt/unavailable metrics must not discard valid transcript words.
        quality = try? container.decode(ChunkMeasurement.self, forKey: .quality)
    }
}

struct ChunkedResult: Sendable {
    var words: [Segment]
    /// One placeholder per chunk the engine failed on twice; the caller keeps the audio.
    var gaps: [Segment]
    var sourceSHA256: String
    var quality: TranscriptionQuality.Channel
    var failedChunks: Int { gaps.count }
}

enum ChunkedTranscription {
    static let sampleRate = PCMToWAV.targetSampleRate
    static let targetChunkSamples = 300 * sampleRate
    static let searchSamples = 10 * sampleRate
    static let frameSamples = sampleRate / 10
    static let attempts = 2
    /// A chunk this quiet (or fully muted by the gate) has no words to find.
    static let silentPeak: Float = 1e-4

    private struct Measurements {
        var decodedSamples = 0
        var silenceSkippedSamples = 0
        var gateMeasuredSamples = 0
        var gatedSamples = 0
        var hasGateMeasurements = false
        var unmeasuredIntervals: [TranscriptionQuality.Interval] = []

        mutating func record(_ quality: ChunkMeasurement) {
            switch quality.kind {
            case .decoded: decodedSamples += quality.sampleCount
            case .silence: silenceSkippedSamples += quality.sampleCount
            }
            recordGate(sampleCount: quality.sampleCount, gatedSamples: quality.gatedSamples)
        }

        mutating func recordGate(sampleCount: Int, gatedSamples count: Int?) {
            guard let count else { return }
            hasGateMeasurements = true
            gateMeasuredSamples += sampleCount
            gatedSamples += count
        }

        func report(totalSamples: Int, gaps: [Segment]) -> TranscriptionQuality.Channel {
            let rate = Double(ChunkedTranscription.sampleRate)
            let complete = unmeasuredIntervals.isEmpty
            let gate = hasGateMeasurements
                ? TranscriptionQuality.Gate(measuredSamples: gateMeasuredSamples, gatedSamples: gatedSamples,
                                            gatedDurationSec: Double(gatedSamples) / rate,
                                            complete: gateMeasuredSamples == totalSamples)
                : nil
            return TranscriptionQuality.Channel(
                audioDurationSec: Double(totalSamples) / rate,
                decodingCoverage: complete ? Double(decodedSamples + silenceSkippedSamples) / Double(totalSamples) : nil,
                decodedDurationSec: complete ? Double(decodedSamples) / rate : nil,
                silenceSkippedDurationSec: complete ? Double(silenceSkippedSamples) / rate : nil,
                failedChunks: gaps.map { .init(start: $0.start, end: $0.end) },
                unmeasuredIntervals: unmeasuredIntervals, bleedGate: gate)
        }
    }

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

    /// Nominal cuts every 5 min, each moved to the quietest frame within ±10 s.
    /// A tail shorter than half a chunk joins the previous one.
    static func boundaries(totalSamples: Int, read: (Int, Int) throws -> [Int16]) rethrows -> [Int] {
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

    /// Transcribes `wav` (a 16 kHz mono channel). With `gateReference` (the
    /// system channel) each chunk first goes through `BleedGate`.
    static func run(wav: URL, workDirectory work: String, audioBytes: UInt64, gateReference: URL? = nil,
                    language: String, recognizer: any SpeechRecognizer, recognizerIdentity: RecognitionIdentity,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ChunkedResult {
        let logger = AppInfo.logger("ChunkedTranscription")
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: false)
        let reference = try gateReference.map {
            try AVAudioFile(forReading: $0, commonFormat: .pcmFormatInt16, interleaved: false)
        }
        let total = Int(file.length)
        guard total > 0 else { throw TranscriptionError.emptyAudio }
        try Task.checkCancellation()
        let cuts = try boundaries(totalSamples: total) { try readSamples(file, from: $0, to: $1) }
        let gate = try gateReference.map { ChunkManifest.GateIdentity(referenceSHA256: try ContentFingerprint.sha256($0)) }
        let manifest = ChunkManifest(audioBytes: audioBytes, sourceSHA256: try ContentFingerprint.sha256(wav),
                                     language: language, recognizer: recognizerIdentity, gate: gate, boundaries: cuts)

        let manifestURL = URL(fileURLWithPath: work + "/manifest.json")
        let saved = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(ChunkManifest.self, from: $0) }
        if saved != manifest {
            // Only generated JSON is invalidated. Original/derived WAV inputs
            // and the capture remain available even if recovery is interrupted.
            try invalidateCheckpoints(in: work)
            try AppPaths.ensurePrivateDirectory(work)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        }
        let count = cuts.count - 1

        var words: [Segment] = []
        var gaps: [Segment] = []
        var measurements = Measurements()
        for index in 0..<count {
            try Task.checkCancellation()
            let start = cuts[index], end = cuts[index + 1]
            let offset = Double(start) / Double(sampleRate)
            let doneURL = URL(fileURLWithPath: String(format: "%@/chunk-%03d.json", work, index))
            if let data = try? Data(contentsOf: doneURL),
               let done = try? JSONDecoder().decode(ChunkCheckpoint.self, from: data),
               done.words.allSatisfy({ $0.hasValidTiming && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                words += done.words
                if let quality = done.quality, quality.isValid(for: end - start, gated: reference != nil) {
                    measurements.record(quality)
                } else {
                    measurements.unmeasuredIntervals.append(.init(start: offset, end: Double(end) / Double(sampleRate)))
                }
                progress(Double(index + 1) / Double(count))
                continue
            }
            var samples = normalized(try readSamples(file, from: start, to: end))
            let gatedSamples: Int?
            if let reference {
                let system = try referenceSpan(reference, from: start, count: samples.count)
                gatedSamples = BleedGate.apply(mic: &samples, system: system)
            } else {
                gatedSamples = nil
            }

            var found: [Segment]?
            let silent = vDSP.maximumMagnitude(samples) < silentPeak
            if silent { found = [] }
            for attempt in 1...attempts where found == nil {
                try Task.checkCancellation()
                do {
                    let decoded = try await recognizer.words(in: samples, language: language)
                    try Task.checkCancellation()
                    found = decoded
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    logger.warning("chunk \(index) (intento \(attempt)) falló: \(error.localizedDescription, privacy: .public)")
                }
            }
            try Task.checkCancellation()
            guard let found else {
                measurements.recordGate(sampleCount: samples.count, gatedSamples: gatedSamples)
                let endSec = Double(end) / Double(sampleRate)
                gaps.append(Segment(start: offset, end: endSec,
                                    text: "[fragmento sin transcribir \(clock(offset))–\(clock(endSec))]"))
                continue
            }
            let shifted = found.map {
                Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text, speaker: $0.speaker,
                        confidence: $0.confidence)
            }
            try Task.checkCancellation()
            let quality = ChunkMeasurement(sampleCount: samples.count, kind: silent ? .silence : .decoded,
                                           gatedSamples: gatedSamples)
            try JSONEncoder().encode(ChunkCheckpoint(words: shifted, quality: quality)).write(to: doneURL, options: .atomic)
            measurements.record(quality)
            words += shifted
            progress(Double(index + 1) / Double(count))
        }
        try Task.checkCancellation()
        // Nothing transcribed: fail so the capture stays recoverable.
        guard gaps.count < count else { throw TranscriptionError.emptyOutput }
        return ChunkedResult(words: words, gaps: gaps, sourceSHA256: manifest.sourceSHA256,
                             quality: measurements.report(totalSamples: total, gaps: gaps))
    }

    private static func invalidateCheckpoints(in work: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: work) else { return }
        let manifest = work + "/manifest.json"
        // Remove the identity first: a failed cleanup cannot admit stale chunks
        // under a newly written manifest on the next retry.
        if fm.fileExists(atPath: manifest) { try fm.removeItem(atPath: manifest) }
        for name in try fm.contentsOfDirectory(atPath: work)
            where name.hasPrefix("chunk-") && name.hasSuffix(".json") {
            try fm.removeItem(atPath: work + "/" + name)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// Reference samples aligned with the mic span [start, start + count), plus
    /// `BleedGate.maxLagSamples` before and `BleedGate.maxLeadSamples` after,
    /// zero-padded where the file has none.
    private static func referenceSpan(_ file: AVAudioFile, from start: Int, count: Int) throws -> [Float] {
        let lag = BleedGate.maxLagSamples, lead = BleedGate.maxLeadSamples
        let from = max(0, start - lag)
        let to = min(start + count + lead, Int(file.length))
        var span = [Float](repeating: 0, count: lag - (start - from))
        if to > from { span += normalized(try readSamples(file, from: from, to: to)) }
        let wanted = count + lag + lead
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

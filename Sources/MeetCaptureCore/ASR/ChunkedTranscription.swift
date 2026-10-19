// ChunkedTranscription.swift
// One channel is transcribed in ~5 min chunks cut at the quietest point near
// each boundary. Every finished chunk is checkpointed next to the capture
// (<audio>.work/<channel>/), so a crash, quit or engine failure resumes where
// it stopped instead of starting the whole meeting over.

import Accelerate
import AVFoundation
import Foundation

struct ChunkManifest: Codable, Equatable {
    /// 3: adds the recognition language. 2: Parakeet words per channel (1 was whisper segments of the mono mix).
    static let currentVersion = 3
    var version = ChunkManifest.currentVersion
    /// Size of the source audio; a different size means a different capture.
    var audioBytes: UInt64
    /// Recognition language; chunks transcribed in another language are redone.
    var language: String
    /// Sample offsets into the channel WAV: first 0, last the total.
    var boundaries: [Int]
}

struct ChunkedResult: Sendable {
    var words: [Segment]
    /// One placeholder per chunk the engine failed on twice; the caller keeps the audio.
    var gaps: [Segment]
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
                    language: String, recognizer: any SpeechRecognizer,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ChunkedResult {
        let logger = AppInfo.logger("ChunkedTranscription")
        let fm = FileManager.default
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: false)
        let reference = try gateReference.map {
            try AVAudioFile(forReading: $0, commonFormat: .pcmFormatInt16, interleaved: false)
        }
        let total = Int(file.length)
        guard total > 0 else { throw TranscriptionError.emptyAudio }

        let manifestURL = URL(fileURLWithPath: work + "/manifest.json")
        let saved = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(ChunkManifest.self, from: $0) }
        let cuts: [Int]
        if let saved, saved.version == ChunkManifest.currentVersion, saved.audioBytes == audioBytes,
           saved.language == language,
           saved.boundaries.first == 0, saved.boundaries.last == total {
            cuts = saved.boundaries
        } else {
            try? fm.removeItem(atPath: work)
            try AppPaths.ensurePrivateDirectory(work)
            cuts = try boundaries(totalSamples: total) { try readSamples(file, from: $0, to: $1) }
            try JSONEncoder().encode(ChunkManifest(audioBytes: audioBytes, language: language, boundaries: cuts))
                .write(to: manifestURL, options: .atomic)
        }
        let count = cuts.count - 1

        var words: [Segment] = []
        var gaps: [Segment] = []
        for index in 0..<count {
            try Task.checkCancellation()
            let start = cuts[index], end = cuts[index + 1]
            let offset = Double(start) / Double(sampleRate)
            let doneURL = URL(fileURLWithPath: String(format: "%@/chunk-%03d.json", work, index))
            if let data = try? Data(contentsOf: doneURL),
               let done = try? JSONDecoder().decode([Segment].self, from: data) {
                words += done
                progress(Double(index + 1) / Double(count))
                continue
            }
            var samples = normalized(try readSamples(file, from: start, to: end))
            if let reference {
                samples = BleedGate.apply(mic: samples, system: try history(reference, from: start, count: samples.count))
            }

            var found: [Segment]?
            if vDSP.maximumMagnitude(samples) < silentPeak { found = [] }
            for attempt in 1...attempts where found == nil {
                do {
                    found = try await recognizer.words(in: samples, language: language)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.warning("chunk \(index) (intento \(attempt)) falló: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let found else {
                let endSec = Double(end) / Double(sampleRate)
                gaps.append(Segment(start: offset, end: endSec,
                                    text: "[fragmento sin transcribir \(clock(offset))–\(clock(endSec))]"))
                continue
            }
            let shifted = found.map {
                Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text, speaker: $0.speaker)
            }
            try JSONEncoder().encode(shifted).write(to: doneURL, options: .atomic)
            words += shifted
            progress(Double(index + 1) / Double(count))
        }
        // Nothing transcribed: fail so the capture stays recoverable.
        guard gaps.count < count else { throw TranscriptionError.emptyOutput }
        return ChunkedResult(words: words, gaps: gaps)
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
            try file.read(into: buffer, frameCount: AVAudioFrameCount(wanted - samples.count))
            guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { break }
            samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        }
        return samples
    }
}

// ChunkedTranscription.swift
// Long audio is transcribed in ~5 min chunks cut at the quietest point near
// each boundary. Every finished chunk is checkpointed next to the capture
// (<audio>.work/), so a timeout, crash or quit resumes where it stopped
// instead of starting the whole meeting over.

import AVFoundation
import Foundation

struct ChunkManifest: Codable, Equatable {
    static let currentVersion = 1
    var version = ChunkManifest.currentVersion
    /// Size of the source audio; a different size means a different capture.
    var audioBytes: UInt64
    /// Sample offsets into the 16 kHz mono WAV: first 0, last the total.
    var boundaries: [Int]
}

struct ChunkedResult: Sendable {
    var segments: [Segment]
    /// Chunks that failed on GPU and CPU; their span is marked in the text.
    var failedChunks: Int
}

enum ChunkedTranscription {
    static let sampleRate = PCMToWAV.targetSampleRate
    static let targetChunkSamples = 300 * sampleRate
    static let searchSamples = 10 * sampleRate
    static let frameSamples = sampleRate / 10

    /// One engine call on a chunk WAV; `useGPU == false` is the fallback.
    typealias Engine = @Sendable (_ wav: URL, _ useGPU: Bool) async throws -> [Segment]

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

    static func run(wav: URL, sourceAudio: String, engine: Engine,
                    progress: @escaping @Sendable (Double) -> Void) async throws -> ChunkedResult {
        let logger = AppInfo.logger("ChunkedTranscription")
        let fm = FileManager.default
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatInt16, interleaved: false)
        let total = Int(file.length)
        guard total > 0 else { throw TranscriptionError.emptyAudio }

        let work = workDirectory(forAudio: sourceAudio)
        let manifestURL = URL(fileURLWithPath: work + "/manifest.json")
        let audioBytes = ((try? fm.attributesOfItem(atPath: sourceAudio))?[.size] as? NSNumber)?.uint64Value ?? 0
        let saved = (try? Data(contentsOf: manifestURL))
            .flatMap { try? JSONDecoder().decode(ChunkManifest.self, from: $0) }
        let cuts: [Int]
        if let saved, saved.version == ChunkManifest.currentVersion, saved.audioBytes == audioBytes,
           saved.boundaries.first == 0, saved.boundaries.last == total {
            cuts = saved.boundaries
        } else {
            try? fm.removeItem(atPath: work)
            try AppPaths.ensurePrivateDirectory(work)
            cuts = try boundaries(totalSamples: total) { try readSamples(file, from: $0, to: $1) }
            try JSONEncoder().encode(ChunkManifest(audioBytes: audioBytes, boundaries: cuts))
                .write(to: manifestURL, options: .atomic)
        }
        let count = cuts.count - 1

        var all: [Segment] = []
        var failed = 0
        for index in 0..<count {
            try Task.checkCancellation()
            let start = cuts[index], end = cuts[index + 1]
            let offset = Double(start) / Double(sampleRate)
            let doneURL = URL(fileURLWithPath: String(format: "%@/chunk-%03d.json", work, index))
            if let data = try? Data(contentsOf: doneURL),
               let done = try? JSONDecoder().decode([Segment].self, from: data) {
                all += done
                progress(Double(index + 1) / Double(count))
                continue
            }
            let chunkWAV = URL(fileURLWithPath: String(format: "%@/chunk-%03d.wav", work, index))
            defer { try? fm.removeItem(at: chunkWAV) }
            try writeWAV(try readSamples(file, from: start, to: end), to: chunkWAV)

            var segments: [Segment]?
            for useGPU in [true, false] where segments == nil {
                do {
                    segments = try await engine(chunkWAV, useGPU)
                } catch WhisperError.emptyOutput {
                    segments = []
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    logger.warning("chunk \(index) (gpu=\(useGPU)) falló: \(error.localizedDescription, privacy: .public)")
                }
            }
            guard let segments else {
                failed += 1
                let endSec = Double(end) / Double(sampleRate)
                all.append(Segment(start: offset, end: endSec,
                                   text: "[fragmento sin transcribir \(clock(offset))–\(clock(endSec))]"))
                continue
            }
            let shifted = segments.map {
                Segment(start: $0.start + offset, end: $0.end + offset, text: $0.text, speaker: $0.speaker)
            }
            try JSONEncoder().encode(shifted).write(to: doneURL, options: .atomic)
            all += shifted
            progress(Double(index + 1) / Double(count))
        }
        // Nothing transcribed: fail so the capture stays recoverable.
        guard failed < count else { throw TranscriptionError.emptyOutput }
        return ChunkedResult(segments: all, failedChunks: failed)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static func readSamples(_ file: AVAudioFile, from start: Int, to end: Int) throws -> [Int16] {
        let frames = AVAudioFrameCount(end - start)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return [] }
        file.framePosition = AVAudioFramePosition(start)
        try file.read(into: buffer, frameCount: frames)
        guard let channel = buffer.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func writeWAV(_ samples: [Int16], to url: URL) throws {
        var data = PCMToWAV.header(dataSize: UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url, options: .atomic)
    }
}

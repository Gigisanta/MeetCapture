// ChannelReader.swift
// Splits a capture into the 16 kHz mono WAVs the pipeline reads: L (system,
// the remote side) and R (the local mic). Imports, legacy mono files and a system
// channel that stayed silent the whole meeting (always, in mic-only captures,
// which write the mic to R only) give one channel, diarized as a whole and
// without a forced local-speaker label.

import Foundation

enum ChannelLayout: Equatable, Sendable {
    case dual(system: URL, mic: URL)
    case single(URL)

    /// The channel transcribed and diarized into Participantes.
    var remote: URL {
        switch self {
        case .dual(let system, _): return system
        case .single(let url): return url
        }
    }

    var mic: URL? {
        if case .dual(_, let mic) = self { return mic }
        return nil
    }
}

enum ChannelReader {
    /// Peak under ~−54 dBFS over the whole meeting: the tap captured nothing.
    static let silentPeak = 64

    static func prepare(audioPath: String, captureSampleRate: Double,
                        workDirectory: String) throws -> ChannelLayout {
        if PCMToWAV.is16kMonoWAV(audioPath) { return .single(URL(fileURLWithPath: audioPath)) }
        let format = PCMToWAV.inputFormat(forAudio: audioPath, captureSampleRate: captureSampleRate)
        if case .int16Interleaved(let channels, _) = format, channels >= 2 {
            let system = URL(fileURLWithPath: workDirectory + "/system.wav")
            let mic = URL(fileURLWithPath: workDirectory + "/mic.wav")
            let peaks = try converting([system, mic]) {
                try PCMToWAV.convert(inputPath: audioPath, format: format, outputURLs: [system, mic])
            }
            if peaks[0] >= silentPeak { return .dual(system: system, mic: mic) }
            try? FileManager.default.removeItem(at: system)
            return .single(mic)
        }
        let mono = URL(fileURLWithPath: workDirectory + "/audio.wav")
        _ = try converting([mono]) {
            try PCMToWAV.convert(inputPath: audioPath, format: format, outputURLs: [mono])
        }
        return .single(mono)
    }

    /// Channel WAVs are derived data, removed after every run; the capture stays.
    static func cleanup(_ layout: ChannelLayout, original: String) {
        for url in [layout.remote, layout.mic].compactMap({ $0 }) where url.path != original {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func converting<T>(_ outputs: [URL], _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            for url in outputs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }
}

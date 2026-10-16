// AudioFormatSidecar.swift
// `<audio>.format.json`: describes a raw .pcm capture so it can be decoded
// later (transcription, import, re-transcription). One schema, one writer.

import Foundation

struct AudioFormatSidecar: Codable, Equatable, Sendable {
    static let currentSchema = "meetcapture.audio.v1"

    var schema = AudioFormatSidecar.currentSchema
    var sampleRate: Int
    /// "s16le" for captures; older files may say "int16" or "float32".
    var sampleFormat: String
    var channels: Int
    var layout: String
    var tapStrategy: String
    var tapInfo: String

    enum CodingKeys: String, CodingKey {
        case schema
        case sampleRate = "sample_rate"
        case sampleFormat = "sample_format"
        case channels
        case layout
        case tapStrategy = "tap_strategy"
        case tapInfo = "tap_info"
    }

    /// The format every capture writes: Int16 interleaved stereo at 16 kHz.
    static func capture(tapStrategy: String, tapInfo: String) -> AudioFormatSidecar {
        AudioFormatSidecar(sampleRate: 16_000, sampleFormat: "s16le", channels: 2,
                           layout: tapStrategy == "mic-only" ? "L=mic,R=mic" : "L=system,R=mic",
                           tapStrategy: tapStrategy, tapInfo: tapInfo)
    }

    static func imported() -> AudioFormatSidecar {
        AudioFormatSidecar(sampleRate: 16_000, sampleFormat: "s16le", channels: 2,
                           layout: "interleaved", tapStrategy: "import", tapInfo: "")
    }

    static func path(forAudio audioPath: String) -> String { audioPath + ".format.json" }

    var isInt16: Bool { ["s16le", "int16"].contains(sampleFormat.lowercased()) }

    static func read(forAudio audioPath: String) -> AudioFormatSidecar? {
        guard let data = FileManager.default.contents(atPath: path(forAudio: audioPath)) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(AudioFormatSidecar.self, from: data)
    }

    func write(forAudio audioPath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: URL(fileURLWithPath: Self.path(forAudio: audioPath)), options: .atomic)
    }
}

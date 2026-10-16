// Segment.swift
// One timed transcript segment. `speaker` is filled by diarization
// (nil when diarization is off, unavailable, or the diarizer answered "?").

import Foundation

struct Segment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var speaker: String?

    init(start: Double, end: Double, text: String, speaker: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }
}

enum ASREngine: String, Sendable {
    case whisper
    case sherpa
}

enum TranscriptFormatter {
    /// Final .txt: one line per segment, "[speaker]: text" when labeled.
    static func text(for segments: [Segment]) -> String {
        segments.map { seg -> String in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let speaker = seg.speaker, !speaker.isEmpty else { return text }
            return "[\(speaker)]: \(text)"
        }.joined(separator: "\n")
    }

    /// Trims whitespace and drops empty segments (what every engine returns goes through here).
    static func cleaned(_ segments: [Segment]) -> [Segment] {
        segments.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  seg.start.isFinite, seg.end.isFinite,
                  seg.start >= 0, seg.end >= seg.start else { return nil }
            var speaker = seg.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            if speaker == "?" || speaker?.isEmpty == true { speaker = nil }
            return Segment(start: seg.start, end: seg.end, text: text, speaker: speaker)
        }
    }

    static func speakerCount(_ segments: [Segment]) -> Int {
        Set(segments.compactMap(\.speaker)).count
    }
}

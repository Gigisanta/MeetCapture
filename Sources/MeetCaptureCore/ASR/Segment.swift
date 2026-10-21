// Segment.swift
// One timed transcript segment (a word while transcribing, a speaker turn in
// the transcript). `speaker` is "Yo", "Participante N" or nil.

import Foundation

struct Segment: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var text: String
    var speaker: String?
    /// A word's lowest token confidence. nil for turns, gaps and checkpoints
    /// written before 7.1.0, which are never marked as doubtful.
    var confidence: Float?

    init(start: Double, end: Double, text: String, speaker: String? = nil, confidence: Float? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.confidence = confidence
    }

    var hasValidTiming: Bool {
        start.isFinite && end.isFinite && start >= 0 && end >= start
    }
}

enum ASREngine: String, Codable, Sendable {
    case parakeet
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
            guard !text.isEmpty, seg.hasValidTiming else { return nil }
            var speaker = seg.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
            if speaker == "?" || speaker?.isEmpty == true { speaker = nil }
            return Segment(start: seg.start, end: seg.end, text: text, speaker: speaker, confidence: seg.confidence)
        }
    }

    static func speakerCount(_ segments: [Segment]) -> Int {
        Set(segments.compactMap(\.speaker)).count
    }
}

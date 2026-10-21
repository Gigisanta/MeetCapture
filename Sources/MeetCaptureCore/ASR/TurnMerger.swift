// TurnMerger.swift
// Words from both channels → speaker turns, in time order. Remote words take
// their speaker from diarization ("Participante N", numbered by first
// appearance); mic words are Gio's. Echo removal belongs to the acoustic
// BleedGate: matching text is not evidence that a real reply is bleed.

import Foundation

struct SpeakerSpan: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var speaker: String
}

enum TurnMerger {
    static let micSpeaker = "Gio"
    static let remoteSpeaker = "Participante"
    static let maxGap = 1.5
    /// A turn this long ends at the next sentence end, so lines stay readable.
    static let longTurn = 45.0

    /// Labels each remote word by the span it overlaps most (else the nearest);
    /// without spans every word is the generic "Participante".
    static func labelRemote(_ words: [Segment], spans: [SpeakerSpan]?) -> [Segment] {
        guard let spans, !spans.isEmpty else {
            return words.map { var w = $0; w.speaker = remoteSpeaker; return w }
        }
        var names: [String: String] = [:]
        return words.map { word in
            var w = word
            let best = spans.max { score($0, word) < score($1, word) }!
            if names[best.speaker] == nil { names[best.speaker] = "\(remoteSpeaker) \(names.count + 1)" }
            w.speaker = names[best.speaker]
            return w
        }
    }

    /// Overlap in seconds when positive, else minus the distance.
    private static func score(_ span: SpeakerSpan, _ word: Segment) -> Double {
        min(span.end, word.end) - max(span.start, word.start)
    }

    static func merge(_ words: [Segment]) -> [Segment] {
        let ordered = words.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }

        var turns: [Segment] = []
        for (_, w) in ordered {
            if var last = turns.last, last.speaker == w.speaker, w.start - last.end <= maxGap,
               !(last.end - last.start >= longTurn && endsSentence(last.text)) {
                last.text += " " + w.text
                last.end = max(last.end, w.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(w)
            }
        }
        return turns
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last)
    }
}

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

    /// Words whose weakest token is under this confidence get `doubtMarker`.
    /// Calibrated 2026-10-21 on the 7 dev blocks of the frozen ASR study
    /// (9907 reference words, holdout closed): the max-F1 threshold that flags
    /// <= 5 % of words with precision >= 0.5. It flags 0.9 % of words, 51 % of
    /// them wrong (6 % base rate), and finds only 7.7 % of the errors; a
    /// dropped word is never marked. Read/media speech, not real meetings.
    static let doubtfulBelow: Float = 0.5
    static let doubtMarker = "[?]"

    static func merge(_ words: [Segment]) -> [Segment] {
        let ordered = words.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }

        var turns: [Segment] = []
        for (_, w) in ordered {
            let text = marked(w)
            if var last = turns.last, last.speaker == w.speaker, w.start - last.end <= maxGap,
               !(last.end - last.start >= longTurn && endsSentence(last.text)) {
                last.text += " " + text
                last.end = max(last.end, w.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(Segment(start: w.start, end: w.end, text: text, speaker: w.speaker))
            }
        }
        return turns
    }

    /// "hola," → "hola[?]," : the marker goes before trailing punctuation.
    static func marked(_ word: Segment) -> String {
        guard let confidence = word.confidence, confidence < doubtfulBelow else { return word.text }
        return addingDoubtMarker(to: word.text)
    }

    /// Also used when an alias combines doubtful words into one spelling.
    static func addingDoubtMarker(to text: String) -> String {
        var cut = text.endIndex
        while cut > text.startIndex,
              text[text.index(before: cut)].unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains) {
            cut = text.index(before: cut)
        }
        guard cut > text.startIndex else { return text }
        return text[..<cut] + doubtMarker + text[cut...]
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last)
    }
}

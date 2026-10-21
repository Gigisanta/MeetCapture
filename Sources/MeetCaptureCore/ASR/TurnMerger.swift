// TurnMerger.swift
// Words from both channels → speaker turns, in time order. Remote words take
// their speaker from diarization ("Participante N", numbered by first
// appearance); mic words are Gio's. The legacy lexical echo heuristic can be
// disabled in the QA research arm without changing the acoustic gate.

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
    static let echoWindow = 0.5
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

    static func merge(_ words: [Segment], deduplicateMic: Bool = QAExperiment.lexicalMicDedupe) -> [Segment] {
        var remoteStarts: [String: [Double]] = [:]
        for w in words where deduplicateMic && w.speaker != micSpeaker {
            if let key = normalized(w.text) { remoteStarts[key, default: []].append(w.start) }
        }
        let kept = words.enumerated().filter { _, w in
            guard deduplicateMic, w.speaker == micSpeaker, let key = normalized(w.text),
                  let starts = remoteStarts[key] else { return true }
            return !starts.contains { abs($0 - w.start) <= echoWindow }
        }
        .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        .map(\.element)

        var turns: [Segment] = []
        for w in kept {
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

    private static func normalized(_ text: String) -> String? {
        let key = String(text.lowercased().filter { $0.isLetter || $0.isNumber })
        return key.isEmpty ? nil : key
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".?!…".contains(last)
    }
}

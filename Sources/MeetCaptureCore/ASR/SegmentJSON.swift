// SegmentJSON.swift
// JSON contracts with the external ASR tools.
//
//   whisper-cli -oj   → {"transcription":[{"offsets":{"from":ms,"to":ms},"text":…}]}
//                        (older builds: {"segments":[{start,end,text}]})
//   speaker_diarize   ← {"segments":[{start,end,text}]}   (what it reads via --segments)
//                     → {"speakers":N,"segments":[{start,end,text,"speaker":"A"|"?"}]}

import Foundation

enum SegmentJSON {
    static func parseWhisper(_ data: Data) -> [Segment] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        if let items = root["transcription"] as? [[String: Any]] {
            var segments: [Segment] = []
            for item in items {
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                var start = 0.0, end = 0.0
                if let offsets = item["offsets"] as? [String: Any] {
                    start = number(offsets["from"]) / 1000.0
                    end = number(offsets["to"]) / 1000.0
                }
                segments.append(Segment(start: start, end: end, text: text))
            }
            // whisper.cpp versions can include a legacy `segments` key as
            // well. Prefer the canonical transcription array to avoid
            // duplicating every utterance.
            if !segments.isEmpty { return segments }
        }
        if let items = root["segments"] as? [[String: Any]] {
            return plainSegments(items)
        }
        return []
    }

    /// What speaker_diarize.py expects on --segments: the transcript wrapped in {"segments": [...]}.
    static func encodeForDiarizer(_ segments: [Segment]) throws -> Data {
        let items: [[String: Any]] = segments.map { ["start": $0.start, "end": $0.end, "text": $0.text] }
        return try JSONSerialization.data(withJSONObject: ["segments": items])
    }

    /// speaker_diarize.py output with --segments. "?" and empty labels map to nil.
    static func parseDiarized(_ data: Data) -> [Segment]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["segments"] as? [[String: Any]]
        else { return nil }
        var out: [Segment] = []
        for item in items {
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let start = number(item["start"])
            let end = item["end"] == nil ? start : number(item["end"])
            var speaker = (item["speaker"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if speaker == "?" || speaker?.isEmpty == true { speaker = nil }
            out.append(Segment(start: start, end: end, text: text, speaker: speaker))
        }
        return out.isEmpty ? nil : out
    }

    private static func plainSegments(_ items: [[String: Any]]) -> [Segment] {
        items.compactMap { item in
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let start = number(item["start"])
            let end = item["end"] == nil ? start : number(item["end"])
            let speaker = item["speaker"] as? String
            return Segment(start: start, end: end, text: text, speaker: speaker == "?" ? nil : speaker)
        }
    }

    private static func number(_ value: Any?) -> Double {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let text = value as? String, let d = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return d
        }
        return 0
    }
}

enum DiarizationMerge {
    /// Applies diarizer labels to the transcript. With equal counts the
    /// diarizer echoes the input order (index match); otherwise labels are
    /// matched by segment midpoint with a 0.5 s tolerance.
    static func apply(labels: [Segment], to segments: [Segment]) -> [Segment] {
        guard !labels.isEmpty else { return segments }
        var merged = segments
        if labels.count == segments.count {
            for i in merged.indices { merged[i].speaker = labels[i].speaker }
            return merged
        }
        for i in merged.indices {
            let mid = (merged[i].start + merged[i].end) / 2
            if let match = labels.first(where: { mid >= $0.start - 0.5 && mid <= $0.end + 0.5 }) {
                merged[i].speaker = match.speaker
            }
        }
        return merged
    }
}

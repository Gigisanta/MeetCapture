// Aliases.swift
// Spelling fixes from ~/.meetcapture/config.json "aliases": canonical form →
// what the recognizer writes instead, e.g. {"AppSheet": ["app sheet"]}.
// Whole-word and case-insensitive; the canonical form itself fixes case;
// longer variants are replaced first. Doubt markers do not prevent a match;
// if any matched word was doubtful, the canonical spelling stays marked.

import Foundation

enum Aliases {
    static func apply(_ aliases: [String: [String]], to segments: [Segment]) -> [Segment] {
        let rules = rules(aliases)
        guard !rules.isEmpty else { return segments }
        return segments.map { segment in
            var s = segment
            for (regex, canonical) in rules {
                let matches = regex.matches(in: s.text, range: NSRange(s.text.startIndex..., in: s.text))
                for match in matches.reversed() {
                    guard let range = Range(match.range, in: s.text) else { continue }
                    let doubtful = s.text[range].contains(TurnMerger.doubtMarker)
                    let replacement = doubtful ? TurnMerger.addingDoubtMarker(to: canonical) : canonical
                    s.text.replaceSubrange(range, with: replacement)
                }
            }
            return s
        }
    }

    private static func rules(_ aliases: [String: [String]]) -> [(NSRegularExpression, String)] {
        var pairs: [(variant: String, canonical: String)] = []
        for (canonical, variants) in aliases {
            for variant in variants + [canonical] {
                let v = variant.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { pairs.append((v, canonical)) }
            }
        }
        return pairs.sorted { $0.variant.count > $1.variant.count }.compactMap { pair in
            let escapedMarker = NSRegularExpression.escapedPattern(for: TurnMerger.doubtMarker)
            let optionalMarker = "(?:" + escapedMarker + ")?"
            let words = pair.variant.split(whereSeparator: \.isWhitespace).map { word in
                // Match where the merger inserts a marker, including before
                // a variant's trailing punctuation: EE.UU[?]. → EEUU[?].
                NSRegularExpression.escapedPattern(for: TurnMerger.addingDoubtMarker(to: String(word)))
                    .replacingOccurrences(of: escapedMarker, with: optionalMarker)
            }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, pair.canonical)
        }
    }
}

// Aliases.swift
// Spelling fixes from ~/.meetcapture/config.json "aliases": canonical form →
// what the recognizer writes instead, e.g. {"AppSheet": ["app sheet"]}.
// Whole-word and case-insensitive; the canonical form itself fixes case;
// longer variants are replaced first.

import Foundation

enum Aliases {
    static func apply(_ aliases: [String: [String]], to segments: [Segment]) -> [Segment] {
        let rules = rules(aliases)
        guard !rules.isEmpty else { return segments }
        return segments.map { segment in
            var s = segment
            for (regex, template) in rules {
                s.text = regex.stringByReplacingMatches(
                    in: s.text, range: NSRange(s.text.startIndex..., in: s.text), withTemplate: template)
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
            let words = pair.variant.split(whereSeparator: \.isWhitespace)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
            let pattern = #"(?<![\p{L}\p{N}])"# + words.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}])"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return (regex, NSRegularExpression.escapedTemplate(for: pair.canonical))
        }
    }
}

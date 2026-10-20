// LocalConfig.swift
// Per-machine, per-person configuration that must never be in the repo:
// ~/.meetcapture/config.json (see Resources/config.example.json).
// Every field is optional; a missing or malformed file yields defaults.

import Foundation

struct LocalConfig: Equatable, Sendable {
    /// Emails treated as "internal": calendar events only count as meetings
    /// when at least one attendee is outside this list.
    var whitelistedEmails: [String] = []
    /// Spelling fixes: canonical form → what the recognizer writes instead,
    /// e.g. {"AppSheet": ["app sheet"]}. A single string counts as one variant.
    var aliases: [String: [String]] = [:]

    static let empty = LocalConfig()

    static func load(path: String = AppPaths.current.configFile) -> LocalConfig {
        guard let data = FileManager.default.contents(atPath: path) else { return .empty }
        return parse(data)
    }

    static func parse(_ data: Data) -> LocalConfig {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            AppInfo.logger("LocalConfig").warning("config.json is not a JSON object; ignoring")
            return .empty
        }
        var config = LocalConfig()
        if let emails = root["whitelistedEmails"] as? [String] {
            config.whitelistedEmails = emails
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        }
        if let aliases = root["aliases"] as? [String: Any] {
            for (key, value) in aliases {
                guard let canonical = nonEmpty(key) else { continue }
                let variants = (value as? [Any] ?? [value]).compactMap(nonEmpty)
                config.aliases[canonical] = variants
            }
        }
        return config
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }

}

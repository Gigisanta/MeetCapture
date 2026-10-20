// SummaryDispatcherConfig.swift
// ~/.meetcapture/summary.json is read by tools/summary/meetcapture_summary_dispatcher.py.
// The app edits it from Settings › Resumen. Saving merges into the existing
// file so keys the app does not know about survive.

import Foundation

struct SummaryDispatcherConfig: Equatable, Sendable {
    var endpoint = "http://127.0.0.1:8080/v1"
    var apiKey = "mlx-local"
    var model = "maat/smart"
    var keepAudio = false
    var maxTokens = 2000
    var dryRun = false
    var tagVocabularyDir = ""

    static let `default` = SummaryDispatcherConfig()

    static func load(path: String = AppPaths.current.summaryConfigFile) -> SummaryDispatcherConfig {
        guard let data = FileManager.default.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .default }
        var c = SummaryDispatcherConfig()
        if let v = root["endpoint"] as? String, !v.isEmpty { c.endpoint = v }
        if let v = root["api_key"] as? String { c.apiKey = v }
        if let v = root["model"] as? String { c.model = v }
        if let v = root["keep_audio"] as? Bool { c.keepAudio = v }
        if let v = root["max_tokens"] as? Int, v > 0 { c.maxTokens = v }
        if let v = root["dry_run"] as? Bool { c.dryRun = v }
        if let v = root["tag_vocabulary_dir"] as? String { c.tagVocabularyDir = v }
        return c
    }

    func save(path: String = AppPaths.current.summaryConfigFile) throws {
        let fm = FileManager.default
        try AppPaths.ensurePrivateDirectory((path as NSString).deletingLastPathComponent)
        var root: [String: Any] = [:]
        if let data = fm.contents(atPath: path),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }
        root["endpoint"] = endpoint
        root["api_key"] = apiKey
        root["model"] = model
        root["keep_audio"] = keepAudio
        root["max_tokens"] = maxTokens
        root["dry_run"] = dryRun
        root["tag_vocabulary_dir"] = tagVocabularyDir
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

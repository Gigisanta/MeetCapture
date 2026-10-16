// Settings.swift
// Typed access to UserDefaults. Keys and defaults are defined exactly once;
// SettingsView binds with @AppStorage(Settings.Key.x.rawValue) and the
// Settings.Default.* constants.

import Foundation

enum Settings {
    enum Key: String, CaseIterable {
        case autoRecord
        case notifyHermes
        case retention
        case maxRecordingDuration
        case asrModel
        case asrLanguage
        case diarize
        case sherpaPythonPath
        case scriptsDir
        case micOnlyMode
        case inputDeviceUID
    }

    enum Default {
        static let autoRecord = true
        static let notifyHermes = true
        /// A day to retranscribe (a better engine, a gap) before the audio goes.
        static let retention = RetentionPolicy.keep24h
        static let maxRecordingDuration: Double = 10_800
        static let asrModel = "medium-q5_0"
        static let asrLanguage = "es"
        static let diarize = true
        static let sherpaPythonPath = ""
        static let scriptsDir = ""
        static let micOnlyMode = false
        static let inputDeviceUID = ""
    }

    static var defaults: [String: Any] {
        [
            Key.autoRecord.rawValue: Default.autoRecord,
            Key.notifyHermes.rawValue: Default.notifyHermes,
            Key.retention.rawValue: Default.retention.rawValue,
            Key.maxRecordingDuration.rawValue: Default.maxRecordingDuration,
            Key.asrModel.rawValue: Default.asrModel,
            Key.asrLanguage.rawValue: Default.asrLanguage,
            Key.diarize.rawValue: Default.diarize,
            Key.sherpaPythonPath.rawValue: Default.sherpaPythonPath,
            Key.scriptsDir.rawValue: Default.scriptsDir,
            Key.micOnlyMode.rawValue: Default.micOnlyMode,
            Key.inputDeviceUID.rawValue: Default.inputDeviceUID,
        ]
    }

    static func registerDefaults(_ store: UserDefaults = .standard) {
        store.register(defaults: defaults)
    }

    private static var store: UserDefaults { .standard }

    private static func bool(_ key: Key, default value: Bool) -> Bool {
        store.object(forKey: key.rawValue) as? Bool ?? value
    }

    private static func string(_ key: Key, default value: String) -> String {
        (store.string(forKey: key.rawValue) ?? value).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var autoRecord: Bool { bool(.autoRecord, default: Default.autoRecord) }
    static var notifyHermes: Bool { bool(.notifyHermes, default: Default.notifyHermes) }
    static var diarize: Bool { bool(.diarize, default: Default.diarize) }
    static var micOnlyMode: Bool { bool(.micOnlyMode, default: Default.micOnlyMode) }

    static var retention: RetentionPolicy {
        RetentionPolicy(rawValue: string(.retention, default: Default.retention.rawValue)) ?? Default.retention
    }

    /// Clamped to 30 min … 8 h.
    static var maxRecordingDuration: TimeInterval {
        let configured = store.object(forKey: Key.maxRecordingDuration.rawValue) as? Double ?? 0
        let value = configured > 0 ? configured : Default.maxRecordingDuration
        return min(max(value, 1_800), 28_800)
    }

    /// Model as typed in Settings; empty or a retired sherpa model id
    /// falls back to the default.
    static var asrModel: String {
        let value = string(.asrModel, default: "")
        return value.isEmpty || value.hasPrefix("zipformer-") ? Default.asrModel : value
    }

    static var asrLanguage: String {
        let value = string(.asrLanguage, default: Default.asrLanguage)
        return value.isEmpty ? Default.asrLanguage : value
    }

    static var sherpaPythonPath: String? {
        let value = string(.sherpaPythonPath, default: "")
        return value.isEmpty ? nil : value
    }

    static var scriptsDir: String? {
        let value = string(.scriptsDir, default: "")
        return value.isEmpty ? nil : value
    }

    static var inputDeviceUID: String? {
        let value = string(.inputDeviceUID, default: "")
        return value.isEmpty ? nil : value
    }
}

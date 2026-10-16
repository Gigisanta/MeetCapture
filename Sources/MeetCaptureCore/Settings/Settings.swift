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
        case engine
        case asrModel
        case asrLanguage
        case diarize
        case sherpaPythonPath
        case scriptsDir
        case liveTranscribe
        case liveModel
        case liveIdleUnloadMinutes
        case micOnlyMode
        case inputDeviceUID
    }

    enum Default {
        static let autoRecord = true
        static let notifyHermes = true
        static let retention = RetentionPolicy.deleteAfterHandoff
        static let maxRecordingDuration: Double = 10_800
        static let engine = ASREngine.whisper
        static let asrModel = "medium-q5_0"
        static let asrLanguage = "es"
        static let diarize = true
        static let sherpaPythonPath = ""
        static let scriptsDir = ""
        static let liveTranscribe = true
        static let liveModel = "zipformer-es"
        static let liveIdleUnloadMinutes = 10
        static let micOnlyMode = false
        static let inputDeviceUID = ""
    }

    static var defaults: [String: Any] {
        [
            Key.autoRecord.rawValue: Default.autoRecord,
            Key.notifyHermes.rawValue: Default.notifyHermes,
            Key.retention.rawValue: Default.retention.rawValue,
            Key.maxRecordingDuration.rawValue: Default.maxRecordingDuration,
            Key.engine.rawValue: Default.engine.rawValue,
            Key.asrModel.rawValue: Default.asrModel,
            Key.asrLanguage.rawValue: Default.asrLanguage,
            Key.diarize.rawValue: Default.diarize,
            Key.sherpaPythonPath.rawValue: Default.sherpaPythonPath,
            Key.scriptsDir.rawValue: Default.scriptsDir,
            Key.liveTranscribe.rawValue: Default.liveTranscribe,
            Key.liveModel.rawValue: Default.liveModel,
            Key.liveIdleUnloadMinutes.rawValue: Default.liveIdleUnloadMinutes,
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
    static var liveTranscribe: Bool { bool(.liveTranscribe, default: Default.liveTranscribe) }
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

    static var engine: ASREngine {
        ASREngine(rawValue: string(.engine, default: Default.engine.rawValue)) ?? Default.engine
    }

    /// Model as typed in Settings; empty falls back to the engine's default.
    static var asrModel: String {
        model(for: engine, configured: string(.asrModel, default: ""))
    }

    /// Shared by runtime and Settings UI so a previous engine's standard
    /// model cannot disable transcription before the settings window opens.
    static func model(for engine: ASREngine, configured: String) -> String {
        let value = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        switch engine {
        case .sherpa where value.isEmpty || WhisperModelSize.normalized(from: value) != nil:
            return "zipformer-es"
        case .whisper where value.isEmpty || value == "zipformer-es" || value == "zipformer-en":
            return Default.asrModel
        default:
            return value
        }
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

    static var liveModel: String {
        let value = string(.liveModel, default: Default.liveModel)
        return value.isEmpty ? Default.liveModel : value
    }

    /// Minutes of idle before the live recognizer is unloaded; 0 = never.
    static var liveIdleUnloadMinutes: Int {
        let value = store.object(forKey: Key.liveIdleUnloadMinutes.rawValue) as? Int ?? Default.liveIdleUnloadMinutes
        return max(0, value)
    }

    static var inputDeviceUID: String? {
        let value = string(.inputDeviceUID, default: "")
        return value.isEmpty ? nil : value
    }
}

// Immutable, launch-scoped research controls. Production ignores every QA override.
import Foundation

enum QAExperiment {
    private static let environment: [String: String] = {
        let env = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "com.maatwork.meetcapture.qa",
              ["import", "capture", "ui", "diagnostic", "resampler", "cancel"].contains(env["MEETCAPTURE_REAL_CHECK"] ?? "")
                || env["MEETCAPTURE_PREFETCH_MODELS"] == "1" else { return [:] }
        return env
    }()

    static var isEnabled: Bool { !environment.isEmpty }
    static let engineName = environment["MEETCAPTURE_QA_ENGINE"] ?? "parakeet"
    /// Zero means a disk-backed whole-channel diagnostic, not an unbounded array.
    static let chunkSeconds = Int(environment["MEETCAPTURE_QA_CHUNK_SECONDS"] ?? "300") ?? 300
    static let seamGapSeconds = Double(environment["MEETCAPTURE_QA_SEAM_GAP_SECONDS"] ?? "1.5") ?? 1.5
    static let lexicalMicDedupe = environment["MEETCAPTURE_QA_LEXICAL_MIC_DEDUPE"] != "0"
    static let repairCapture = environment["MEETCAPTURE_QA_REPAIR_CAPTURE"] == "1"
    static let whisperPrompt = environment["MEETCAPTURE_QA_WHISPER_PROMPT"] == "1"
    static var whisperModelDirectory: URL? {
        environment["MEETCAPTURE_QA_WHISPER_MODEL_DIR"].map { URL(fileURLWithPath: $0) }
    }
    static let fixedPrompt = "Reunión de trabajo. Terminología: API, PostgreSQL, TypeScript, GitHub, Vercel."

    enum Invalid: LocalizedError {
        case value(String)
        var errorDescription: String? {
            if case .value(let key) = self { return "Invalid QA experiment option: \(key)" }
            return nil
        }
    }

    /// Run before creating the app or loading a model. Invalid input is never a control arm.
    static func validate() throws {
        let allowed: [String: Set<String>] = [
            "MEETCAPTURE_QA_ENGINE": ["parakeet", "whisperkit"],
            "MEETCAPTURE_QA_CHUNK_SECONDS": ["0", "300", "600"],
            "MEETCAPTURE_QA_SEAM_GAP_SECONDS": ["1.5", "0.5"],
            "MEETCAPTURE_QA_LEXICAL_MIC_DEDUPE": ["0", "1"],
            "MEETCAPTURE_QA_REPAIR_CAPTURE": ["0", "1"],
            "MEETCAPTURE_QA_WHISPER_PROMPT": ["0", "1"]
        ]
        for (key, values) in allowed {
            if let value = environment[key], !values.contains(value) { throw Invalid.value(key) }
        }
        if engineName == "whisperkit", whisperModelDirectory == nil {
            throw Invalid.value("MEETCAPTURE_QA_WHISPER_MODEL_DIR is required")
        }
    }
}

enum SpeechBackend {
    static var selected: any SpeechRecognizer {
        QAExperiment.engineName == "whisperkit" ? WhisperKitEngine.shared : ParakeetEngine.shared
    }
}

// WhisperCLI.swift
// Runs whisper.cpp's whisper-cli on a 16 kHz mono WAV and returns segments.

import Foundation

enum WhisperError: LocalizedError {
    case cliNotFound
    case noModel(directory: String)
    case emptyOutput
    case outputMissing

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "whisper-cli no encontrado (brew install whisper-cpp)"
        case .noModel(let directory):
            return "No hay modelos whisper en \(directory) (scripts/fetch-models.sh --whisper)"
        case .emptyOutput:
            return "whisper-cli no produjo segmentos de transcripción"
        case .outputMissing:
            return "whisper-cli terminó sin crear su archivo JSON de salida"
        }
    }
}

struct WhisperCLI: Sendable {
    let executable: String

    /// Placeholder prompt: names and jargon come from config.json (domainPrompt).
    static let defaultPrompt = """
        Transcripción de reunión de trabajo en español argentino. \
        Participantes: (los nombres de los asistentes). \
        Empresas y proyectos: (los nombres propios que se repiten). \
        Términos técnicos: certificación, redeterminación de precios, planificación, \
        etapas, obras, tickets, gestión documental, inventario, presupuesto, partida, \
        parte de obra, orden de compra, proveedor, acopio, baseline, desvío, cash flow, KPI, rubro.
        """

    /// Prefer the CLI and libraries verified as part of this app's build.
    /// Homebrew remains available when running directly through SwiftPM.
    static func locate(bundleResourcePath: String? = Bundle.main.resourcePath) -> WhisperCLI? {
        let candidates = [
            bundleResourcePath.map { $0 + "/whisper-cli" },
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map(WhisperCLI.init)
    }

    func transcribe(wav: URL, modelPath: String, language: String, prompt: String,
                    vadModelPath: String?, threads: Int = WhisperModels.threads) async throws -> [Segment] {
        let stem = wav.deletingPathExtension().path
        var args = [
            "-m", modelPath,
            "-f", wav.path,
            "-l", language,
            "-oj", "-of", stem,
            "-t", "\(threads)",
            "--prompt", prompt,
            "--suppress-nst",
            "--no-prints",
        ]
        if let vad = vadModelPath { args += ["--vad", "--vad-model", vad] }
        if ProcessInfo.processInfo.environment["MEETCAPTURE_WHISPER_CPU_ONLY"] == "1" {
            args.append("--no-gpu")
        }
        let timeout = ProcessRunner.timeout(forAudioSeconds: PCMToWAV.wavDurationSeconds(wav.path))
        let spec = ProcessSpec(executable: executable, arguments: args, timeout: timeout)
        Signposts.asr.emitEvent("whisper-cli start")
        let jsonURL = URL(fileURLWithPath: stem + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        var lastRetryableError: Error?
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: jsonURL)
            do {
                try await ProcessRunner.runChecked(spec)
            } catch let error as ProcessRunnerError {
                lastRetryableError = error
                switch error {
                case .failed(_, _, _), .timedOut(_, _):
                    if attempt == 0 { continue }
                case .launchFailed(_, _):
                    throw error
                }
                throw error
            }
            guard let data = try? Data(contentsOf: jsonURL) else {
                lastRetryableError = WhisperError.outputMissing
                if attempt == 0 { continue }
                throw WhisperError.outputMissing
            }
            let segments = WhisperHallucinations.filter(SegmentJSON.parseWhisper(data))
            guard !segments.isEmpty else { throw WhisperError.emptyOutput }
            return segments
        }
        throw lastRetryableError ?? WhisperError.outputMissing
    }
}

/// Phrases whisper produces from silence or noise (subtitle credits and
/// stock sign-offs in its training data). A segment that is only one of
/// these carries no speech and is dropped.
enum WhisperHallucinations {
    static let phrases: Set<String> = [
        "la traducción es la misma",
        "subtítulos realizados por la comunidad de amaraorg",
        "subtítulos por la comunidad de amaraorg",
        "subtitulado por la comunidad de amaraorg",
        "gracias por ver el video",
        "gracias por ver",
        "gracias por su atención",
        "suscríbete",
        "suscríbete al canal",
        "thank you for watching",
        "thanks for watching",
        "subtitles by the amaraorg community",
    ]

    static func normalized(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars.filter { CharacterSet.letters.union(.whitespaces).contains($0) }
            .map(String.init).joined()
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func isHallucination(_ text: String) -> Bool {
        let key = normalized(text)
        return key.isEmpty || phrases.contains(key)
    }

    static func filter(_ segments: [Segment]) -> [Segment] {
        segments.filter { !isHallucination($0.text) }
    }
}

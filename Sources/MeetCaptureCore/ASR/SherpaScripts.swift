// SherpaScripts.swift
// Whole-file sherpa-onnx transcription and speaker diarization through the
// python scripts in scripts/. Both are best-effort: nil means "unavailable
// or failed", never an exception, so whisper remains the fallback.

import Foundation
import os

struct SherpaScripts: Sendable {
    let python: String
    let transcribeScript: String?
    let diarizeScript: String?
    private let logger = AppInfo.logger("Sherpa")

    init?(toolchain: Toolchain) {
        guard let python = toolchain.python, toolchain.pythonHasSherpa != false else { return nil }
        self.python = python
        transcribeScript = toolchain.script("transcribe_sherpa.py")
        diarizeScript = toolchain.script("speaker_diarize.py")
    }

    func transcribe(wav: URL, model: String) async -> [Segment]? {
        guard let script = transcribeScript else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("sherpa-out-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        // -B: never write __pycache__ next to scripts inside the signed bundle.
        var args = ["-B", script, "--audio", wav.path, "--out", out.path]
        if !model.isEmpty { args += ["--model", model] }
        let timeout = ProcessRunner.timeout(forAudioSeconds: PCMToWAV.wavDurationSeconds(wav.path))
        let spec = ProcessSpec(executable: python, arguments: args, timeout: timeout)
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: out)
            let result = try? await ProcessRunner.run(spec)
            if let result, result.succeeded, let data = FileManager.default.contents(atPath: out.path) {
                return SegmentJSON.parseSherpa(data)
            }
            logger.warning("transcribe_sherpa falló (intento \(attempt + 1)): \(result?.stderrText ?? "sin salida", privacy: .public)")
        }
        return nil
    }

    func diarize(wav: URL, segments: [Segment]) async -> [Segment]? {
        guard let script = diarizeScript, !segments.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory
        let segmentsURL = tmp.appendingPathComponent("segments-\(UUID().uuidString).json")
        let out = tmp.appendingPathComponent("diar-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: segmentsURL)
            try? FileManager.default.removeItem(at: out)
        }
        guard let payload = try? SegmentJSON.encodeForDiarizer(segments),
              (try? payload.write(to: segmentsURL)) != nil else { return nil }
        let args = ["-B", script, "--audio", wav.path, "--segments", segmentsURL.path, "--out", out.path]
        let timeout = ProcessRunner.timeout(forAudioSeconds: PCMToWAV.wavDurationSeconds(wav.path))
        let spec = ProcessSpec(executable: python, arguments: args, timeout: timeout)
        for attempt in 0..<2 {
            try? FileManager.default.removeItem(at: out)
            let result = try? await ProcessRunner.run(spec)
            if let result, result.succeeded, let data = FileManager.default.contents(atPath: out.path) {
                return SegmentJSON.parseDiarized(data)
            }
            logger.warning("speaker_diarize falló (intento \(attempt + 1)): \(result?.stderrText ?? "sin salida", privacy: .public)")
        }
        return nil
    }
}

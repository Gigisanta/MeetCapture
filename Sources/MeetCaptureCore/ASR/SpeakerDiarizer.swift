// SpeakerDiarizer.swift
// Speaker labels through scripts/speaker_diarize.py (sherpa-onnx). Best
// effort: nil means "unavailable or failed" and the transcript goes out
// without labels.

import Foundation
import os

struct SpeakerDiarizer: Sendable {
    let python: String
    let script: String
    private let logger = AppInfo.logger("Sherpa")

    init?(toolchain: Toolchain) {
        guard let python = toolchain.python, toolchain.pythonHasSherpa != false,
              let script = toolchain.script(ToolchainResolver.sentinelScript) else { return nil }
        self.python = python
        self.script = script
    }

    func diarize(wav: URL, segments: [Segment]) async -> [Segment]? {
        guard !segments.isEmpty else { return nil }
        let tmp = FileManager.default.temporaryDirectory
        let segmentsURL = tmp.appendingPathComponent("segments-\(UUID().uuidString).json")
        let out = tmp.appendingPathComponent("diar-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: segmentsURL)
            try? FileManager.default.removeItem(at: out)
        }
        guard let payload = try? SegmentJSON.encodeForDiarizer(segments),
              (try? payload.write(to: segmentsURL)) != nil else { return nil }
        // -B: never write __pycache__ next to scripts inside the signed bundle.
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

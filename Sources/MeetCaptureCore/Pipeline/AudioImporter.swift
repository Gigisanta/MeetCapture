// AudioImporter.swift
// Turns a user-picked file into something the transcription job can read,
// off the main actor. wav/m4a/aiff/caf go through afconvert; raw .pcm is
// assumed to be a MeetCapture capture (Int16 stereo 16 kHz).

import Foundation

struct PreparedImport: Sendable {
    /// File the transcription job reads (WAV or PCM+sidecar).
    let workPath: String
    /// File kept next to the transcript for re-transcription.
    let durableAudioPath: String
    let transcriptPath: String
    let title: String
}

enum AudioImporter {
    static func prepare(
        url: URL,
        importsDir: String,
        now: Date = Date(),
        converter: @Sendable (ProcessSpec) async throws -> Void = { spec in
            _ = try await ProcessRunner.runChecked(spec)
        }
    ) async throws -> PreparedImport {
        let fm = FileManager.default
        try AppPaths.ensurePrivateDirectory(importsDir)
        let base = importsDir + "/" + stamp(for: url, now: now)
        let title = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        if ext == "pcm" {
            let durable = uniquePath(base + ".pcm")
            let jobBase = URL(fileURLWithPath: durable).deletingPathExtension().path
            try fm.copyItem(at: url, to: URL(fileURLWithPath: durable))
            try AudioFormatSidecar.imported().write(forAudio: durable)
            return PreparedImport(workPath: durable, durableAudioPath: durable,
                                  transcriptPath: jobBase + ".txt", title: title)
        }

        if PCMToWAV.is16kMonoWAV(url.path) {
            let durable = uniquePath(base + ".wav")
            let jobBase = URL(fileURLWithPath: durable).deletingPathExtension().path
            try fm.copyItem(at: url, to: URL(fileURLWithPath: durable))
            return PreparedImport(workPath: durable, durableAudioPath: durable,
                                  transcriptPath: jobBase + ".txt", title: title)
        }

        // afconvert may leave a partial output when cancelled or killed. Keep it
        // out of the durable namespace until the process completes successfully.
        let staging = importsDir + "/.meetcapture-import-\(UUID().uuidString).wav"
        defer { try? fm.removeItem(atPath: staging) }
        let spec = ProcessSpec(
            executable: "/usr/bin/afconvert",
            arguments: ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", url.path, staging],
            timeout: 600)
        try await converter(spec)
        try Task.checkCancellation()
        let durable = uniquePath(base + ".wav")
        try fm.moveItem(atPath: staging, toPath: durable)
        let jobBase = URL(fileURLWithPath: durable).deletingPathExtension().path
        return PreparedImport(workPath: durable, durableAudioPath: durable,
                              transcriptPath: jobBase + ".txt", title: title)
    }

    private static func uniquePath(_ preferred: String) -> String {
        guard !isReserved(preferred) else {
            let url = URL(fileURLWithPath: preferred)
            let stem = url.deletingPathExtension().path
            let ext = url.pathExtension
            var suffix = 2
            while true {
                let candidate = "\(stem)-\(suffix).\(ext)"
                if !isReserved(candidate) { return candidate }
                suffix += 1
            }
        }
        return preferred
    }

    private static func isReserved(_ audioPath: String) -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: audioPath) else { return true }
        guard !fm.fileExists(atPath: AudioFormatSidecar.path(forAudio: audioPath)) else { return true }

        let url = URL(fileURLWithPath: audioPath)
        let transcriptPath = url.deletingPathExtension().path + ".txt"
        return fm.fileExists(atPath: transcriptPath) ||
            fm.fileExists(atPath: ProcessedMarker.path(forTranscript: transcriptPath))
    }

    /// yyyyMMdd-HHmm-<name with unsafe characters replaced>.
    static func stamp(for url: URL, now: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmm"
        // File URLs come back decomposed (NFD); fold accents to ASCII before sanitising.
        let name = url.deletingPathExtension().lastPathComponent
            .folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
        return "\(df.string(from: now))-\(name)"
    }
}

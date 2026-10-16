// RecordingRecovery.swift
// Captures that never reached a transcript: the app quit or crashed while
// recording, or the transcription failed. The raw PCM and its sidecar are
// enough to run the normal pipeline again.

import Foundation

struct RecoverableRecording: Equatable, Sendable {
    var audioPath: String
    var transcriptPath: String
    /// When the capture started (the sidecar is written at start).
    var startedAt: Date
    /// Last write to the PCM, i.e. when the audio ended.
    var endedAt: Date
    var attempts: Int
}

enum RecordingRecovery {
    /// Recent orphans are recovered on launch without asking; older ones
    /// wait for an explicit "Transcribir" so old audio never produces
    /// surprise summaries.
    static let automaticWindow: TimeInterval = 48 * 3600
    static let maxAutomaticAttempts = 3
    /// Under 3 s of 16 kHz stereo s16le there is nothing to transcribe.
    static let minimumBytes = 16_000 * 4 * 3

    static func transcriptPath(forAudio audioPath: String) -> String {
        String(audioPath.dropLast(".pcm".count)) + ".txt"
    }

    static func attemptsPath(forAudio audioPath: String) -> String { audioPath + ".recovery.json" }

    /// Recordings with a valid sidecar and no processed marker, oldest
    /// first. `excluding` holds captures still in use.
    static func find(in directory: String, excluding: Set<String> = [], now: Date = Date()) -> [RecoverableRecording] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name -> RecoverableRecording? in
            guard name.hasPrefix("recording-"), name.hasSuffix(".pcm") else { return nil }
            let audioPath = directory + "/" + name
            guard !excluding.contains(audioPath) else { return nil }
            let transcript = transcriptPath(forAudio: audioPath)
            let sidecarPath = AudioFormatSidecar.path(forAudio: audioPath)
            guard !fm.fileExists(atPath: ProcessedMarker.path(forTranscript: transcript)),
                  !isSettledTranscript(transcript, now: now),
                  let sidecar = AudioFormatSidecar.read(forAudio: audioPath),
                  sidecar.tapStrategy != "import",
                  let audio = try? fm.attributesOfItem(atPath: audioPath),
                  (audio[.size] as? NSNumber)?.intValue ?? 0 >= minimumBytes,
                  let endedAt = audio[.modificationDate] as? Date
            else { return nil }
            let startedAt = (try? fm.attributesOfItem(atPath: sidecarPath))?[.modificationDate] as? Date
            return RecoverableRecording(audioPath: audioPath, transcriptPath: transcript,
                                        startedAt: min(startedAt ?? endedAt, endedAt), endedAt: endedAt,
                                        attempts: attempts(forAudio: audioPath))
        }
        .sorted { $0.endedAt < $1.endedAt }
    }

    /// The pipeline writes the transcript before the marker, so a recent
    /// transcript without a marker is a handoff that failed midway and is
    /// retried. An old one predates the marker and is left alone.
    private static func isSettledTranscript(_ path: String, now: Date) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) > automaticWindow
    }

    static func automatic(_ recordings: [RecoverableRecording], now: Date = Date()) -> [RecoverableRecording] {
        recordings.filter {
            now.timeIntervalSince($0.endedAt) <= automaticWindow && $0.attempts < maxAutomaticAttempts
        }
    }

    static func attempts(forAudio audioPath: String) -> Int {
        guard let data = FileManager.default.contents(atPath: attemptsPath(forAudio: audioPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return json["attempts"] as? Int ?? 0
    }

    /// Counts a failed attempt next to the audio so automatic recovery stops
    /// retrying a recording that cannot be transcribed.
    static func recordFailure(audioPath: String, reason: String, countsAsAttempt: Bool = true,
                              now: Date = Date()) {
        let record: [String: Any] = [
            "attempts": attempts(forAudio: audioPath) + (countsAsAttempt ? 1 : 0),
            "last_error": reason,
            "updated_at": ISO8601DateFormatter().string(from: now),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: attemptsPath(forAudio: audioPath)), options: .atomic)
    }
}

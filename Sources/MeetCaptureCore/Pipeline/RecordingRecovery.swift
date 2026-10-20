// RecordingRecovery.swift
// Captures that never reached a complete transcript: the app quit or crashed
// while recording, the transcription failed, or it left gaps. The raw PCM and
// its sidecar are enough to run the normal pipeline again; a gapped capture
// also keeps its chunk checkpoints, so a retry redoes only the gaps.

import Foundation

struct RecoverableRecording: Equatable, Sendable {
    var audioPath: String
    var transcriptPath: String
    /// When the capture started (the sidecar is written at start).
    var startedAt: Date
    /// Last write to the PCM, i.e. when the audio ended.
    var endedAt: Date
    var attempts: Int
    /// When automatic recovery may try it again; nil means it is due now.
    var nextAttemptAt: Date? = nil

    /// Used up its automatic attempts; only a manual run transcribes it.
    var exhausted: Bool { attempts >= RecordingRecovery.maxAutomaticAttempts }
}

enum RecordingRecovery {
    /// Recent orphans are recovered on launch without asking; older ones
    /// wait for an explicit "Transcribir" so old audio never produces
    /// surprise summaries.
    static let automaticWindow: TimeInterval = 48 * 3600
    static let maxAutomaticAttempts = 3
    /// Wait before the next automatic attempt after the first and second
    /// failures; the third is the last one `automatic` allows.
    static let retryDelays: [TimeInterval] = [300, 1_200]
    /// Under 10 s of 16 kHz stereo s16le there is no meeting to transcribe.
    static let minimumBytes = 16_000 * 4 * 10

    static func transcriptPath(forAudio audioPath: String) -> String {
        String(audioPath.dropLast(".pcm".count)) + ".txt"
    }

    static func attemptsPath(forAudio audioPath: String) -> String { audioPath + ".recovery.json" }

    /// The meeting id a capture was recorded under (`recording-<id>.pcm`).
    static func sessionId(forAudio audioPath: String) -> String? {
        let name = (audioPath as NSString).lastPathComponent
        guard name.hasPrefix("recording-"), name.hasSuffix(".pcm") else { return nil }
        let id = String(name.dropFirst("recording-".count).dropLast(".pcm".count))
        return id.isEmpty ? nil : id
    }

    /// Lives with the chunk checkpoints, so the run that fills every gap
    /// removes it along with them.
    static func gapsPath(forAudio audioPath: String) -> String {
        ChunkedTranscription.workDirectory(forAudio: audioPath) + "/gaps.json"
    }

    /// Written before a gapped transcript is handed off: a crash between the
    /// two leaves an unmarked capture, which is retried as well.
    static func markGaps(audioPath: String, chunks: Int) throws {
        try AppPaths.ensurePrivateDirectory(ChunkedTranscription.workDirectory(forAudio: audioPath))
        try JSONSerialization.data(withJSONObject: ["chunks": chunks])
            .write(to: URL(fileURLWithPath: gapsPath(forAudio: audioPath)), options: .atomic)
    }

    /// Handed off with gaps. Checkpoints alone do not count: a re-run of a
    /// complete capture that failed or was cancelled also leaves them.
    static func hasGaps(audioPath: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: ProcessedMarker.path(forTranscript: transcriptPath(forAudio: audioPath)))
            && fm.fileExists(atPath: gapsPath(forAudio: audioPath))
    }

    /// No complete transcript yet: never handed off, or handed off with gaps.
    static func needsTranscript(audioPath: String) -> Bool {
        hasGaps(audioPath: audioPath)
            || !FileManager.default.fileExists(
                atPath: ProcessedMarker.path(forTranscript: transcriptPath(forAudio: audioPath)))
    }

    /// Recordings with a valid sidecar that were never handed off or were
    /// handed off with gaps, newest first: today's meeting never waits behind
    /// an old orphan. `excluding` holds captures still in use.
    static func find(in directory: String, excluding: Set<String> = [], now: Date = Date()) -> [RecoverableRecording] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return names.compactMap { name -> RecoverableRecording? in
            guard name.hasPrefix("recording-"), name.hasSuffix(".pcm") else { return nil }
            let audioPath = directory + "/" + name
            guard !excluding.contains(audioPath) else { return nil }
            let transcript = transcriptPath(forAudio: audioPath)
            let sidecarPath = AudioFormatSidecar.path(forAudio: audioPath)
            let handedOff = fm.fileExists(atPath: ProcessedMarker.path(forTranscript: transcript))
            guard handedOff ? hasGaps(audioPath: audioPath) : !isSettledTranscript(transcript, now: now),
                  let sidecar = AudioFormatSidecar.read(forAudio: audioPath),
                  sidecar.tapStrategy != "import",
                  let audio = try? fm.attributesOfItem(atPath: audioPath),
                  (audio[.size] as? NSNumber)?.intValue ?? 0 >= minimumBytes,
                  let endedAt = audio[.modificationDate] as? Date
            else { return nil }
            let startedAt = (try? fm.attributesOfItem(atPath: sidecarPath))?[.modificationDate] as? Date
            return RecoverableRecording(audioPath: audioPath, transcriptPath: transcript,
                                        startedAt: min(startedAt ?? endedAt, endedAt), endedAt: endedAt,
                                        attempts: attempts(forAudio: audioPath),
                                        nextAttemptAt: nextAttemptAt(forAudio: audioPath))
        }
        .sorted { $0.endedAt > $1.endedAt }
    }

    /// The pipeline writes the transcript before the marker, so a recent
    /// transcript without a marker is a handoff that failed midway and is
    /// retried. An old one predates the marker and is left alone.
    private static func isSettledTranscript(_ path: String, now: Date) -> Bool {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return false }
        return now.timeIntervalSince(modified) > automaticWindow
    }

    /// Within the automatic window and under the attempt cap, due or not.
    static func retryable(_ recordings: [RecoverableRecording], now: Date = Date()) -> [RecoverableRecording] {
        recordings.filter {
            now.timeIntervalSince($0.endedAt) <= automaticWindow && $0.attempts < maxAutomaticAttempts
        }
    }

    /// Retryable and due. A record without `next_attempt_at` (never failed,
    /// or written before 7.0.0) is due now.
    static func automatic(_ recordings: [RecoverableRecording], now: Date = Date()) -> [RecoverableRecording] {
        retryable(recordings, now: now).filter { ($0.nextAttemptAt ?? .distantPast) <= now }
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private static func record(forAudio audioPath: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: attemptsPath(forAudio: audioPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }

    /// Milliseconds matter: retry delays under a second must not round into the past.
    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func attempts(forAudio audioPath: String) -> Int {
        record(forAudio: audioPath)["attempts"] as? Int ?? 0
    }

    static func nextAttemptAt(forAudio audioPath: String) -> Date? {
        guard let value = record(forAudio: audioPath)["next_attempt_at"] as? String else { return nil }
        return dateFormatter().date(from: value)
    }

    /// Counts a failed attempt next to the audio so automatic recovery stops
    /// retrying a recording that cannot be transcribed, and saves when the
    /// next automatic attempt is due so the backoff survives a relaunch.
    /// Called when an attempt starts too, so a crash midway does not retry
    /// on the next launch before its time.
    static func recordFailure(audioPath: String, reason: String, countsAsAttempt: Bool = true,
                              retryDelays: [TimeInterval] = RecordingRecovery.retryDelays,
                              now: Date = Date()) {
        let formatter = dateFormatter()
        let attempts = attempts(forAudio: audioPath) + (countsAsAttempt ? 1 : 0)
        var record: [String: Any] = [
            "attempts": attempts,
            "last_error": reason,
            "updated_at": formatter.string(from: now),
        ]
        if attempts >= 1, attempts <= retryDelays.count, attempts < maxAutomaticAttempts {
            record["next_attempt_at"] = formatter.string(from: now.addingTimeInterval(retryDelays[attempts - 1]))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: URL(fileURLWithPath: attemptsPath(forAudio: audioPath)), options: .atomic)
    }
}

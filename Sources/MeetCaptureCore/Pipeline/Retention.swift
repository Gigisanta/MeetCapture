// Retention.swift
// What happens to the raw capture after the transcript is handed off.

import Foundation

enum RetentionPolicy: String, CaseIterable, Identifiable, Sendable {
    case deleteAfterHandoff
    case keep24h = "24h"
    case keep

    var id: String { rawValue }
}

enum Retention {
    private static let logger = AppInfo.logger("Retention")

    /// Deletes the exact raw capture (and its sidecar) when the policy says so.
    /// A missing file is already in the requested state. Failures are returned
    /// so the pipeline can report them instead of claiming a complete handoff.
    @discardableResult
    static func apply(policy: RetentionPolicy, audioPath: String) -> Bool {
        guard policy == .deleteAfterHandoff else { return true }
        ChunkedTranscription.removeWork(forAudio: audioPath)
        let sidecar = AudioFormatSidecar.path(forAudio: audioPath)
        if FileManager.default.fileExists(atPath: audioPath) {
            do {
                try FileManager.default.removeItem(atPath: audioPath)
            } catch {
                logger.warning("no se pudo borrar \(audioPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        guard FileManager.default.fileExists(atPath: sidecar) else { return true }
        do {
            try FileManager.default.removeItem(atPath: sidecar)
            return true
        } catch {
            logger.warning("no se pudo borrar \(sidecar, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Launch-time sweep for the 24 h policy: recording-*.pcm (+ sidecar and
    /// recovery record) older than 24 h in the transcripts dir. Exact names,
    /// no globs. A capture without its processed marker was never
    /// transcribed, and one handed off with gaps has them to redo; both stay.
    static func cleanupOldRecordings(in directory: String, policy: RetentionPolicy, now: Date = Date()) {
        guard policy == .keep24h else { return }
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-86_400)
        guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for name in names where name.hasPrefix("recording-") && name.hasSuffix(".pcm") {
            let audioPath = directory + "/" + name
            let transcript = RecordingRecovery.transcriptPath(forAudio: audioPath)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: audioPath, isDirectory: &isDir), !isDir.boolValue,
                  fm.fileExists(atPath: ProcessedMarker.path(forTranscript: transcript)),
                  !RecordingRecovery.hasGaps(audioPath: audioPath),
                  let modified = (try? fm.attributesOfItem(atPath: audioPath))?[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            for path in [audioPath, AudioFormatSidecar.path(forAudio: audioPath),
                         ChunkedTranscription.workDirectory(forAudio: audioPath),
                         RecordingRecovery.attemptsPath(forAudio: audioPath)] {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}

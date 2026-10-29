// PostProcessor.swift
// Everything that happens after the engine returns segments, off the main
// actor: .txt → frozen meeting evidence → SQLite → local marker → .pending v3 → retention.

import Foundation

struct PostProcessInput: Sendable {
    var session: MeetingSession
    var segments: [Segment]
    var transcriptPath: String
    /// File the retention policy may delete (the raw capture).
    var capturePath: String
    /// File the contract points at (the raw capture or the durable import copy).
    var durableAudioPath: String
    var engine: ASREngine
    var model: String
    var language: String
    var applyRetention: Bool
    var retention: RetentionPolicy
    var meetingsDir: String
    var audioDurationSec: Double? = nil
    var audioEndedAt: Date? = nil
    /// The transcript has gaps. The app keeps the audio to redo them, so
    /// retention is skipped and the handoff leaves `audioPath` null: the
    /// summary dispatcher must not delete audio a retry still needs.
    var partial = false
    var quality: TranscriptionQuality? = nil
}

struct PostProcessResult: Sendable {
    var transcriptText: String
    var speakerCount: Int
    var record: MeetingRecord
    var pendingPath: String
}

enum PostProcessError: LocalizedError {
    case emptyTranscript
    case invalidDuration
    case markerWriteFailed(String)
    case storeWriteFailed
    case retentionFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "La transcripción no produjo texto; se conserva el audio para reintentar"
        case .invalidDuration:
            return "La duración de la reunión es inválida; se conserva el audio"
        case .markerWriteFailed(let reason):
            return "No se pudo guardar el marker de procesamiento: \(reason)"
        case .storeWriteFailed:
            return "No se pudo guardar la reunión en el historial; se conserva el audio para reintentar"
        case .retentionFailed(let reason):
            return "La transcripción quedó guardada, pero no se pudo aplicar la retención: \(reason)"
        }
    }
}

actor PostProcessor {
    private let store: MeetingStore
    private let logger = AppInfo.logger("PostProcessor")

    init(store: MeetingStore) {
        self.store = store
    }

    func run(_ input: PostProcessInput, now: Date = Date()) throws -> PostProcessResult {
        let segments = TranscriptFormatter.cleaned(input.segments)
        let text = TranscriptFormatter.text(for: segments)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PostProcessError.emptyTranscript
        }
        let observedEnd = input.session.sourceAudioEndedAt ?? input.audioEndedAt ?? now
        let duration = input.audioDurationSec ?? observedEnd.timeIntervalSince(input.session.startedAt)
        guard duration.isFinite, duration >= 0 else { throw PostProcessError.invalidDuration }
        var session = input.session
        // A sidecar written before the driver starts is not start evidence.
        // Only history or an explicitly accredited source clock preserves it.
        let sourceStart: Date?
        if input.audioDurationSec != nil {
            sourceStart = store.summary(id: session.id)?.startedAt
                ?? (session.startedAtIsAuthoritative == true ? session.startedAt : nil)
        } else {
            sourceStart = nil
        }
        let endedAt = sourceStart?.addingTimeInterval(duration) ?? observedEnd
        session.startedAt = sourceStart ?? endedAt.addingTimeInterval(-duration)
        if input.audioDurationSec != nil {
            session.sourceAudioEndedAt = nil
            session.startedAtIsAuthoritative = true
        }
        let speakerCount = TranscriptFormatter.speakerCount(segments)

        let transcriptURL = URL(fileURLWithPath: input.transcriptPath)
        try AppPaths.ensurePrivateDirectory(transcriptURL.deletingLastPathComponent().path)
        try text.write(to: URL(fileURLWithPath: input.transcriptPath), atomically: true, encoding: .utf8)
        if FileManager.default.fileExists(atPath: input.durableAudioPath) {
            try session.write(forAudio: input.durableAudioPath)
        }

        let record = MeetingRecord(
            id: session.id, title: session.displayTitle,
            startedAt: session.startedAt, endedAt: endedAt,
            durationSec: duration,
            engine: input.engine.rawValue, model: input.model, language: input.language,
            transcriptPath: input.transcriptPath, summaryPath: nil,
            speakerCount: speakerCount, transcriptText: text)
        // SQLite is durable before the irreversible retention step. A failed
        // history write therefore never deletes the only raw copy.
        guard store.insert(record) else { throw PostProcessError.storeWriteFailed }

        do {
            try ProcessedMarker.write(transcriptPath: input.transcriptPath, title: session.displayTitle, now: now)
        } catch {
            let reason = error.localizedDescription
            logger.error("marker: \(reason, privacy: .public)")
            throw PostProcessError.markerWriteFailed(reason)
        }

        // This is the publication point observed by the summary dispatcher.
        // It must be last among local durable writes so a failed store/marker
        // can never expose a handoff that invites external cleanup.
        let contract = PendingContract(
            session: session, endedAt: endedAt, transcriptPath: input.transcriptPath,
            transcriptText: text, audioPath: input.partial ? nil : input.durableAudioPath, engine: input.engine,
            model: input.model, language: input.language, segments: segments, quality: input.quality)
        let pendingPath = input.session.pendingPath(in: input.meetingsDir)
        try contract.write(to: pendingPath)

        if input.applyRetention, !input.partial, !Retention.apply(policy: input.retention, audioPath: input.capturePath) {
            throw PostProcessError.retentionFailed("no se pudo borrar el audio o su sidecar")
        }

        return PostProcessResult(transcriptText: text, speakerCount: contract.speakerCount,
                                 record: record, pendingPath: pendingPath)
    }
}

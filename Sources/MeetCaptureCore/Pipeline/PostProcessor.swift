// PostProcessor.swift
// Everything that happens after the engine returns segments, off the main
// actor: generation snapshot → display .txt → SQLite → marker → .pending → retention.

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
    case handoffTranscriptChanged
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
        case .handoffTranscriptChanged:
            return "La copia de entrega de esta transcripción fue modificada; se conserva el audio y no se republica"
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
        let endedAt = input.audioEndedAt ?? now
        let duration = input.audioDurationSec ?? endedAt.timeIntervalSince(input.session.startedAt)
        guard duration.isFinite, duration >= 0 else { throw PostProcessError.invalidDuration }
        var session = input.session
        session.startedAt = endedAt.addingTimeInterval(-duration)
        let speakerCount = TranscriptFormatter.speakerCount(segments)

        let transcriptData = Data(text.utf8)
        let checksum = PendingContractV2.sha256Hex(transcriptData)
        // A handoff must never reference the editable display file. A retry can
        // fail after replacing that file, and a reader may still hold the prior
        // handoff even after a new one is published.
        let handoffURL = URL(fileURLWithPath: input.meetingsDir)
            .appendingPathComponent("handoff-transcripts", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
            .appendingPathComponent(checksum + ".txt")
        try publishTranscript(transcriptData, to: handoffURL)

        let transcriptURL = URL(fileURLWithPath: input.transcriptPath)
        try AppPaths.ensurePrivateDirectory(transcriptURL.deletingLastPathComponent().path)
        try transcriptData.write(to: transcriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.transcriptPath)

        let record = MeetingRecord(
            id: input.session.id, title: input.session.displayTitle,
            startedAt: session.startedAt, endedAt: endedAt,
            durationSec: duration,
            engine: input.engine.rawValue, model: input.model, language: input.language,
            transcriptPath: input.transcriptPath, summaryPath: nil,
            speakerCount: speakerCount, transcriptText: text)
        // SQLite is durable before the irreversible retention step. A failed
        // history write therefore never deletes the only raw copy.
        guard store.insert(record) else { throw PostProcessError.storeWriteFailed }

        do {
            try ProcessedMarker.write(transcriptPath: input.transcriptPath, title: input.session.displayTitle, now: now)
        } catch {
            let reason = error.localizedDescription
            logger.error("marker: \(reason, privacy: .public)")
            throw PostProcessError.markerWriteFailed(reason)
        }

        // This is the publication point observed by the summary dispatcher.
        // It must be last among local durable writes so a failed store/marker
        // can never expose a handoff that invites external cleanup.
        let contract = PendingContractV2(
            session: session, endedAt: endedAt, transcriptPath: handoffURL.path,
            checksum: checksum, audioPath: input.partial ? nil : input.durableAudioPath, engine: input.engine,
            model: input.model, language: input.language, segments: segments)
        let pendingPath = input.session.pendingPath(in: input.meetingsDir)
        try contract.write(to: pendingPath)

        if input.applyRetention, !input.partial, !Retention.apply(policy: input.retention, audioPath: input.capturePath) {
            throw PostProcessError.retentionFailed("no se pudo borrar el audio o su sidecar")
        }

        return PostProcessResult(transcriptText: text, speakerCount: contract.speakerCount,
                                 record: record, pendingPath: pendingPath)
    }

    /// Publish complete private bytes without replacing an existing generation.
    /// A corrupt generation is evidence, not permission to silently repair it.
    private func publishTranscript(_ data: Data, to destination: URL) throws {
        let fm = FileManager.default
        try AppPaths.ensurePrivateDirectory(destination.deletingLastPathComponent().path)
        if fm.fileExists(atPath: destination.path) {
            try validateTranscript(data, at: destination)
            return
        }
        let temporary = destination.appendingPathExtension("tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do {
            // link is exclusive and atomic: an existing snapshot is never
            // overwritten, even if another producer publishes the same bytes.
            try fm.linkItem(at: temporary, to: destination)
        } catch {
            guard fm.fileExists(atPath: destination.path) else { throw error }
            try validateTranscript(data, at: destination)
        }
    }

    private func validateTranscript(_ data: Data, at destination: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: destination) == data else {
            throw PostProcessError.handoffTranscriptChanged
        }
    }
}

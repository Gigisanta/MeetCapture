// TranscriptionJob.swift
// Transcription of one capture: split L (remote) and R (Gio's mic) into
// 16 kHz WAVs, gate the remote voice out of the mic, transcribe each channel
// in checkpointed chunks with Parakeet, diarize the remote channel and merge
// both into speaker turns. Runs off the main actor; reports coarse progress.

import Foundation

enum TranscriptionError: LocalizedError {
    case emptyAudio
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "El archivo de audio está vacío; no se generó ninguna transcripción"
        case .emptyOutput:
            return "El motor de transcripción no produjo texto; se conserva el audio para reintentar"
        }
    }
}

/// Diarization of the remote channel, cached so a resumed run does not redo it.
struct DiarizationCache: Codable {
    var audioBytes: UInt64
    var sourceSHA256: String
    var spans: [SpeakerSpan]
}

struct TranscriptionJob: Sendable {
    var audioPath: String
    var captureSampleRate: Double
    var language: String
    var diarize: Bool
    var aliases: [String: [String]] = [:]
    var recognizer: any SpeechRecognizer = ParakeetEngine.shared
    var diarizer: any SpeakerDiarizing = FluidDiarizer()

    struct Outcome: Sendable {
        var segments: [Segment]
        var engineUsed: ASREngine
        var modelUsed: String
        var audioDurationSec: Double? = nil
        /// Chunks no attempt could transcribe; the caller keeps the audio.
        var failedChunks = 0
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
        try Task.checkCancellation()
        let state = Signposts.pipeline.beginInterval("transcription")
        defer { Signposts.pipeline.endInterval("transcription", state) }
        let fm = FileManager.default

        let work = ChunkedTranscription.workDirectory(forAudio: audioPath)
        // Version 1 (whisper on the mono mix) kept its chunks at the top level.
        if fm.fileExists(atPath: work + "/manifest.json") { ChunkedTranscription.removeWork(forAudio: audioPath) }
        try AppPaths.ensurePrivateDirectory(work)
        let layout = try ChannelReader.prepare(audioPath: audioPath, captureSampleRate: captureSampleRate,
                                               workDirectory: work)
        defer { ChannelReader.cleanup(layout, original: audioPath) }
        let duration = PCMToWAV.wavDurationSeconds(layout.remote.path)
        guard duration > 0 else { throw TranscriptionError.emptyAudio }
        let identity = try await recognizer.prepare()
        let outcome: Outcome
        do {
            outcome = try await transcribePrepared(layout: layout, work: work, duration: duration,
                                                   identity: identity, progress: progress)
        } catch {
            await recognizer.release()
            throw error
        }
        await recognizer.release()
        try Task.checkCancellation()
        return outcome
    }

    private func transcribePrepared(layout: ChannelLayout, work: String, duration: TimeInterval,
                                    identity: RecognitionIdentity,
                                    progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
        progress(0.1)
        try Task.checkCancellation()

        let audioBytes = ((try? FileManager.default.attributesOfItem(atPath: audioPath))?[.size] as? NSNumber)?.uint64Value ?? 0
        let micShare = layout.mic == nil ? 0.0 : 0.3
        let remote = try await ChunkedTranscription.run(
            wav: layout.remote, workDirectory: work + "/remote", audioBytes: audioBytes,
            language: language, recognizer: recognizer, recognizerIdentity: identity,
            progress: { progress(0.1 + (0.7 - micShare) * $0) })
        var mic: ChunkedResult?
        if let micURL = layout.mic {
            mic = try await ChunkedTranscription.run(
                wav: micURL, workDirectory: work + "/mic", audioBytes: audioBytes,
                gateReference: layout.remote, language: language, recognizer: recognizer, recognizerIdentity: identity,
                progress: { progress(0.5 + 0.3 * $0) })
        }
        progress(0.8)
        try Task.checkCancellation()

        var words = remote.words
        if diarize || mic != nil {
            let spans = diarize ? try await speakerSpans(layout.remote, work: work, audioBytes: audioBytes,
                                                         sourceSHA256: remote.sourceSHA256) : nil
            words = TurnMerger.labelRemote(words, spans: spans)
            try Task.checkCancellation()
        }
        words += (mic?.words ?? []).map { var w = $0; w.speaker = TurnMerger.micSpeaker; return w }
        let gaps = remote.gaps + (mic?.gaps ?? [])
        let turns = Aliases.apply(aliases, to: TurnMerger.merge(words))
        let result = TranscriptFormatter.cleaned((turns + gaps).sorted { $0.start < $1.start })
        guard !result.isEmpty else { throw TranscriptionError.emptyOutput }
        try Task.checkCancellation()
        progress(1.0)
        return Outcome(segments: result, engineUsed: identity.engine, modelUsed: identity.model,
                       audioDurationSec: duration, failedChunks: gaps.count)
    }

    /// nil when diarization fails: the remote side becomes one "Participante".
    private func speakerSpans(_ wav: URL, work: String, audioBytes: UInt64,
                              sourceSHA256: String) async throws -> [SpeakerSpan]? {
        try Task.checkCancellation()
        let cacheURL = URL(fileURLWithPath: work + "/diarization.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(DiarizationCache.self, from: data),
           cache.audioBytes == audioBytes, cache.sourceSHA256 == sourceSHA256 {
            return cache.spans
        }
        do {
            let spans = try await diarizer.spans(in: wav)
            try Task.checkCancellation()
            try? JSONEncoder().encode(DiarizationCache(audioBytes: audioBytes, sourceSHA256: sourceSHA256, spans: spans))
                .write(to: cacheURL, options: .atomic)
            return spans
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            AppInfo.logger("TranscriptionJob").warning(
                "diarización no disponible: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

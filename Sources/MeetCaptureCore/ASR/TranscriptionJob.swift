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
    var spans: [SpeakerSpan]
}

struct TranscriptionJob: Sendable {
    var audioPath: String
    var captureSampleRate: Double
    var language: String
    var diarize: Bool
    var aliases: [String: [String]] = [:]
    var recognizer: any SpeechRecognizer = SpeechBackend.selected
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
        if QATrace.isEnabled {
            let context = QATrace.Context(jobID: UUID().uuidString)
            return try await QATrace.$context.withValue(context) {
                do {
                    return try await transcribe(progress: progress)
                } catch let error as QATrace.Failure {
                    throw error
                } catch {
                    try QATrace.write(error.localizedDescription, name: "job-failure")
                    throw error
                }
            }
        }
        return try await transcribe(progress: progress)
    }

    private func transcribe(progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
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
        try await recognizer.prepare()
        if QATrace.isEnabled {
            try QATrace.write(JobTrace(audioPath: audioPath, captureSampleRate: captureSampleRate,
                                       language: language, diarize: diarize, aliases: aliases,
                                       identity: recognizer.identity),
                              name: "job-input")
        }
        progress(0.1)
        try Task.checkCancellation()

        let audioBytes = ((try? fm.attributesOfItem(atPath: audioPath))?[.size] as? NSNumber)?.uint64Value ?? 0
        let micShare = layout.mic == nil ? 0.0 : 0.3
        let remote = try await ChunkedTranscription.run(
            wav: layout.remote, workDirectory: work + "/remote", audioBytes: audioBytes,
            language: language, recognizer: recognizer,
            progress: { progress(0.1 + (0.7 - micShare) * $0) })
        var mic: ChunkedResult?
        if let micURL = layout.mic {
            mic = try await ChunkedTranscription.run(
                wav: micURL, workDirectory: work + "/mic", audioBytes: audioBytes,
                gateReference: layout.remote, language: language, recognizer: recognizer,
                progress: { progress(0.5 + 0.3 * $0) })
        }
        progress(0.8)
        try Task.checkCancellation()

        var words = remote.words
        var spans: [SpeakerSpan]?
        if diarize || mic != nil {
            spans = diarize ? await speakerSpans(layout.remote, work: work, audioBytes: audioBytes) : nil
            words = TurnMerger.labelRemote(words, spans: spans)
        }
        words += (mic?.words ?? []).map { var w = $0; w.speaker = TurnMerger.micSpeaker; return w }
        let gaps = remote.gaps + (mic?.gaps ?? [])
        if QATrace.isEnabled {
            try QATrace.write(LabeledWordsTrace(words: words, remoteWordCount: remote.words.count,
                                                micWordCount: mic?.words.count ?? 0, spans: spans,
                                                remoteGaps: remote.gaps, micGaps: mic?.gaps ?? []),
                              name: "labeled-words-before-merger")
        }
        let merged = TurnMerger.merge(words)
        if QATrace.isEnabled { try QATrace.write(merged, name: "turns-after-merger") }
        let turns = Aliases.apply(aliases, to: merged)
        if QATrace.isEnabled { try QATrace.write(turns, name: "turns-after-aliases") }
        let beforeCleaning = (turns + gaps).sorted { $0.start < $1.start }
        if QATrace.isEnabled { try QATrace.write(beforeCleaning, name: "turns-before-cleaning") }
        let result = TranscriptFormatter.cleaned(beforeCleaning)
        if QATrace.isEnabled { try QATrace.write(result, name: "turns-cleaned") }
        guard !result.isEmpty else { throw TranscriptionError.emptyOutput }
        progress(1.0)
        return Outcome(segments: result, engineUsed: recognizer.engine, modelUsed: recognizer.modelName,
                       audioDurationSec: duration, failedChunks: gaps.count)
    }

    private struct JobTrace: Encodable {
        var audioPath: String
        var captureSampleRate: Double
        var language: String
        var diarize: Bool
        var aliases: [String: [String]]
        var identity: QATrace.RecognizerIdentity
        let chunkManifestVersion = ChunkManifest.currentVersion
        let mergerMaxGap = TurnMerger.maxGap
        let mergerEchoWindow = TurnMerger.echoWindow
        let mergerLongTurn = TurnMerger.longTurn
    }

    private struct LabeledWordsTrace: Encodable {
        /// Exactly the merger input, in textual emission order: remote, then mic.
        var words: [Segment]
        var remoteWordCount: Int
        var micWordCount: Int
        var spans: [SpeakerSpan]?
        var remoteGaps: [Segment]
        var micGaps: [Segment]
    }

    /// nil when diarization fails: the remote side becomes one "Participante".
    private func speakerSpans(_ wav: URL, work: String, audioBytes: UInt64) async -> [SpeakerSpan]? {
        let cacheURL = URL(fileURLWithPath: work + "/diarization.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cache = try? JSONDecoder().decode(DiarizationCache.self, from: data), cache.audioBytes == audioBytes {
            return cache.spans
        }
        do {
            let spans = try await diarizer.spans(in: wav)
            try? JSONEncoder().encode(DiarizationCache(audioBytes: audioBytes, spans: spans))
                .write(to: cacheURL, options: .atomic)
            return spans
        } catch {
            AppInfo.logger("TranscriptionJob").warning(
                "diarización no disponible: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

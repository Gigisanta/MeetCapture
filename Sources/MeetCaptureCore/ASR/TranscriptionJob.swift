// TranscriptionJob.swift
// Transcription of one audio file with the configured engine:
// PCM/WAV → 16 kHz mono WAV → sherpa or chunked whisper → diarization.
// Runs entirely off the main actor; reports coarse progress.

import Foundation

enum TranscriptionError: LocalizedError {
    case emptyAudio
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .emptyAudio:
            return "El archivo de audio está vacío; no se generó ninguna transcripción"
        case .emptyOutput:
            return "El motor de transcripción no produjo segmentos; se conserva el audio para reintentar"
        }
    }
}

struct TranscriptionJob: Sendable {
    var audioPath: String
    var captureSampleRate: Double
    var engine: ASREngine
    var model: String
    var language: String
    var diarize: Bool
    var prompt: String
    var toolchain: Toolchain
    var whisperModels: WhisperModels = .default

    /// Whisper model actually used (after memory fallback) or the sherpa model id.
    struct Outcome: Sendable {
        var segments: [Segment]
        var engineUsed: ASREngine
        var modelUsed: String
        var audioDurationSec: Double? = nil
        /// Chunks no engine could transcribe; the caller keeps the audio.
        var failedChunks = 0
    }

    func run(progress: @escaping @Sendable (Double) -> Void) async throws -> Outcome {
        let logger = AppInfo.logger("TranscriptionJob")
        let state = Signposts.pipeline.beginInterval("transcription")
        defer { Signposts.pipeline.endInterval("transcription", state) }

        let wav = try PCMToWAV.prepare(audioPath: audioPath, captureSampleRate: captureSampleRate)
        defer { PCMToWAV.cleanup(wav, original: audioPath) }
        let audioDuration = PCMToWAV.wavDurationSeconds(wav.path)
        guard audioDuration > 0 else { throw TranscriptionError.emptyAudio }
        progress(0.3)
        try Task.checkCancellation()

        let sherpa = SherpaScripts(toolchain: toolchain)
        var segments: [Segment]? = nil
        var engineUsed = engine
        var modelUsed = model
        var failedChunks = 0

        if engine == .sherpa {
            segments = await sherpa?.transcribe(wav: wav, model: model)
            if segments == nil {
                logger.warning("sherpa no disponible; usando whisper")
                engineUsed = .whisper
            }
        }
        if segments == nil {
            guard let cli = WhisperCLI.locate() else { throw WhisperError.cliNotFound }
            guard let selected = whisperModels.select(setting: engine == .whisper ? model : Settings.Default.asrModel) else {
                throw WhisperError.noModel(directory: whisperModels.directory)
            }
            modelUsed = URL(fileURLWithPath: selected.path).deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "ggml-", with: "")
            let modelPath = selected.path, vad = whisperModels.vadModelPath
            let language = language, prompt = prompt
            let chunked = try await ChunkedTranscription.run(
                wav: wav, sourceAudio: audioPath,
                engine: { chunk, useGPU in
                    try await cli.transcribe(wav: chunk, modelPath: modelPath, language: language,
                                             prompt: prompt, vadModelPath: vad, useGPU: useGPU)
                },
                progress: { progress(0.3 + 0.5 * $0) })
            segments = chunked.segments
            failedChunks = chunked.failedChunks
        }
        progress(0.8)
        try Task.checkCancellation()

        var result = TranscriptFormatter.cleaned(segments ?? [])
        guard !result.isEmpty else { throw TranscriptionError.emptyOutput }
        if diarize, let labels = await sherpa?.diarize(wav: wav, segments: result) {
            result = DiarizationMerge.apply(labels: labels, to: result)
        }
        progress(1.0)
        return Outcome(segments: result, engineUsed: engineUsed, modelUsed: modelUsed,
                       audioDurationSec: audioDuration, failedChunks: failedChunks)
    }
}

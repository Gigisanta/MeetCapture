// TranscriptionQuality.swift
// Audio-processing evidence, not a speech-coverage or word-error estimate.

import Foundation

struct TranscriptionQuality: Codable, Equatable, Sendable {
    var audioDurationSec: Double
    /// A separate remote channel requires both a non-silent system channel
    /// and an explicit system/mic layout in the source capture's format sidecar.
    var channels: Channels
    /// Only successful diarization of a separate remote channel can supply this.
    /// Never inferred from the fallback "Participante" label or a mono mix.
    var remoteSpeakerCount: Int? = nil

    struct Channels: Codable, Equatable, Sendable {
        var remote: Channel? = nil
        var microphone: Channel? = nil
        var single: Channel? = nil
        /// Unknown imported stereo is still processed as before, but channel
        /// positions alone cannot prove remote/local identities.
        var left: Channel? = nil
        var right: Channel? = nil
    }

    struct Interval: Codable, Equatable, Sendable {
        var start: Double
        var end: Double
    }

    struct Channel: Codable, Equatable, Sendable {
        var audioDurationSec: Double
        /// Fraction of source samples successfully decoded OR verified silent
        /// after gating. Empty ASR output still counts as decoded, not as speech.
        /// nil when a valid legacy checkpoint has no measured sample counts.
        var decodingCoverage: Double?
        /// Samples actually sent to a successful recognizer invocation.
        var decodedDurationSec: Double?
        /// Samples skipped by the existing silence check, including gated silence.
        var silenceSkippedDurationSec: Double?
        /// One interval for each chunk that exhausted the existing ASR attempts.
        var failedChunks: [Interval]
        /// Valid transcript checkpoints whose measured counts are unavailable.
        var unmeasuredIntervals: [Interval]
        /// nil when gating was not used or no cached/new measurements are known.
        var bleedGate: Gate?
    }

    struct Gate: Codable, Equatable, Sendable {
        /// Mic samples passed through the gate in chunks with recorded counts.
        /// Includes trailing partial windows, which the gate deliberately keeps.
        var measuredSamples: Int
        /// Whole-window samples zeroed by the acoustic decision, counted once
        /// even if ASR retried that chunk. Not a count of originally nonzero PCM.
        var gatedSamples: Int
        var gatedDurationSec: Double
        /// false means these are only the measured subset, not a meeting total.
        var complete: Bool
    }
}

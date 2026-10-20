// ChannelLevels.swift
// Peak level of each channel over the most recent seconds of a capture that
// is still being written (16 kHz s16le stereo, L = system, R = mic).
// Used to notice a denied System Audio Recording permission or a dead mic:
// both deliver digital silence instead of an error.

import Foundation

struct ChannelLevels: Equatable, Sendable {
    var systemPeak: Int
    var micPeak: Int

    /// Anything above a couple of LSB is signal or at least analog noise;
    /// a denied tap or a muted device produces exact zeros.
    static let silenceThreshold = 2

    var systemSilent: Bool { systemPeak <= Self.silenceThreshold }
    var micSilent: Bool { micPeak <= Self.silenceThreshold }

    /// Reads at most the last `seconds` of `path`. Returns nil when the file
    /// holds less than one second of audio.
    static func measureTail(path: String, seconds: Double, sampleRate: Int = 16_000) -> ChannelLevels? {
        let frameBytes = 4
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let available = Int(size) / frameBytes * frameBytes
        guard available >= sampleRate * frameBytes else { return nil }
        let window = min(available, Int(seconds * Double(sampleRate)) * frameBytes)
        do {
            try handle.seek(toOffset: UInt64(available - window))
            guard let data = try handle.read(upToCount: window), data.count >= frameBytes else { return nil }
            return peaks(data)
        } catch {
            return nil
        }
    }

    static func peaks(_ data: Data) -> ChannelLevels {
        var left = 0, right = 0
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count - 3, by: 4) {
                let l = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
                let r = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)))
                left = max(left, abs(l))
                right = max(right, abs(r))
            }
        }
        return ChannelLevels(systemPeak: left, micPeak: right)
    }
}

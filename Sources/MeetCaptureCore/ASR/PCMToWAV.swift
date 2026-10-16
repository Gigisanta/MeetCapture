// PCMToWAV.swift
// Converts a raw capture (.pcm + sidecar) or any PCM stream to the
// 16 kHz mono int16 WAV every engine consumes. Streaming, 64 KB chunks,
// header patched after the data so the length is always right.

import AVFoundation
import Foundation

enum PCMToWAV {
    static let targetSampleRate = 16_000
    static let headerSize = 44
    /// RIFF's 32-bit chunk size includes 36 bytes beyond the PCM data.
    private static let maxWAVSamples = Int((UInt32.max - 36) / 2)

    enum InputFormat: Equatable, Sendable {
        case float32Mono(sampleRate: Int)
        case int16Interleaved(channels: Int, sampleRate: Int)
        case unsupported(sampleFormat: String)
    }

    enum ConversionError: LocalizedError {
        case invalidSampleRate
        case invalidChannels
        case invalidData
        case unsupportedFormat(String)
        case tooLarge
        var errorDescription: String? {
            switch self {
            case .invalidSampleRate: return "Frecuencia de muestreo inválida"
            case .invalidChannels: return "Cantidad de canales inválida"
            case .invalidData: return "Datos PCM truncados o inválidos"
            case .unsupportedFormat(let format): return "Formato PCM no soportado: \(format)"
            case .tooLarge: return "El audio supera el tamaño máximo de un WAV"
            }
        }
    }

    static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meetcapture-whole-\(UUID().uuidString).wav")
    }

    /// Mixes the system (L) and mic (R) channels by summing with a clamp.
    /// Averaging halved each voice (−6 dB), which is all whisper gets when
    /// the other channel is silent — the usual case in a call.
    static func mix(_ left: Int16, _ right: Int16) -> Int16 {
        Int16(clamping: Int32(left) + Int32(right))
    }

    /// Format of a capture file: sidecar when present, else the legacy float32 mono at `captureSampleRate`.
    static func inputFormat(forAudio path: String, captureSampleRate: Double) -> InputFormat {
        if let sidecar = AudioFormatSidecar.read(forAudio: path) {
            let rate = sidecar.sampleRate
            let format = sidecar.sampleFormat.lowercased()
            if sidecar.isInt16 {
                return .int16Interleaved(channels: sidecar.channels, sampleRate: rate)
            }
            if ["float32", "f32", "float"].contains(format) {
                return .float32Mono(sampleRate: rate)
            }
            return .unsupported(sampleFormat: sidecar.sampleFormat)
        }
        return .float32Mono(sampleRate: Int(captureSampleRate))
    }

    /// Core Audio parses RIFF chunks (including JUNK/FLLR/LIST); audio need
    /// not begin at byte 44. afconvert routinely emits a padded header.
    static func is16kMonoWAV(_ path: String) -> Bool {
        guard let audio = wavFile(path) else { return false }
        let format = audio.fileFormat
        return format.commonFormat == .pcmFormatInt16 && format.channelCount == 1
            && format.sampleRate == Double(targetSampleRate)
    }

    static func wavDurationSeconds(_ path: String) -> Double {
        guard let audio = wavFile(path), audio.fileFormat.sampleRate > 0 else { return 0 }
        return Double(audio.length) / audio.fileFormat.sampleRate
    }

    private static func wavFile(_ path: String) -> AVAudioFile? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 12), head.count == 12,
              String(decoding: head.prefix(4), as: UTF8.self) == "RIFF",
              String(decoding: head.suffix(4), as: UTF8.self) == "WAVE" else { return nil }
        return try? AVAudioFile(forReading: url)
    }

    /// Returns the input itself when it is already a 16k mono WAV, otherwise
    /// a fresh temp WAV (caller removes it with `cleanup`).
    static func prepare(audioPath: String, captureSampleRate: Double) throws -> URL {
        if is16kMonoWAV(audioPath) { return URL(fileURLWithPath: audioPath) }
        let out = makeTempURL()
        do {
            try convert(inputPath: audioPath,
                        format: inputFormat(forAudio: audioPath, captureSampleRate: captureSampleRate),
                        outputURL: out)
        } catch {
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }

    static func cleanup(_ wavURL: URL, original: String) {
        guard wavURL.path != original else { return }
        try? FileManager.default.removeItem(at: wavURL)
    }

    static func convert(inputPath: String, format: InputFormat, outputURL: URL) throws {
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
        defer { try? input.close() }

        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        try output.write(contentsOf: header(dataSize: 0))

        let chunkBytes = 64 * 1024
        var samplesWritten = 0
        func emit(_ samples: [Int16]) throws {
            guard !samples.isEmpty else { return }
            guard samples.count <= maxWAVSamples - samplesWritten else {
                throw ConversionError.tooLarge
            }
            try output.write(contentsOf: samples.withUnsafeBytes { Data($0) })
            samplesWritten += samples.count
        }

        switch format {
        case .float32Mono(let sampleRate):
            var resampler = try StreamingLinearResampler(sourceRate: sampleRate)
            var remainder = Data()
            while true {
                try Task.checkCancellation()
                let chunk = try input.read(upToCount: chunkBytes) ?? Data()
                if chunk.isEmpty { break }
                remainder.append(chunk)
                let count = remainder.count / MemoryLayout<Float>.size
                guard count > 0 else { continue }
                var values = [Float](); values.reserveCapacity(count)
                try remainder.withUnsafeBytes { raw in
                    for i in 0..<count {
                        let bits = UInt32(littleEndian: raw.loadUnaligned(
                            fromByteOffset: i * MemoryLayout<Float>.size, as: UInt32.self))
                        let value = Float(bitPattern: bits) * 32767
                        guard value.isFinite else { throw ConversionError.invalidData }
                        values.append(value)
                    }
                }
                remainder.removeFirst(count * MemoryLayout<Float>.size)
                try emit(resampler.append(values))
            }
            guard remainder.isEmpty else { throw ConversionError.invalidData }
            try emit(resampler.finish())

        case .int16Interleaved(let channels, let sampleRate):
            guard channels > 0 else { throw ConversionError.invalidChannels }
            var resampler = try StreamingLinearResampler(sourceRate: sampleRate)
            let frameBytes = channels * MemoryLayout<Int16>.size
            var remainder = Data()
            while true {
                try Task.checkCancellation()
                let next = try input.read(upToCount: chunkBytes) ?? Data()
                if next.isEmpty && remainder.isEmpty { break }
                remainder.append(next)
                let frames = remainder.count / frameBytes
                if frames > 0 {
                    var values = [Float](); values.reserveCapacity(frames)
                    remainder.withUnsafeBytes { raw in
                        for frame in 0..<frames {
                            let offset = frame * frameBytes
                            let left = Int32(Int16(littleEndian: raw.loadUnaligned(
                                fromByteOffset: offset, as: Int16.self)))
                            let right = channels > 1
                                ? Int32(Int16(littleEndian: raw.loadUnaligned(
                                    fromByteOffset: offset + 2, as: Int16.self)))
                                : left
                            values.append(Float(channels > 1 ? Int32(mix(Int16(left), Int16(right))) : left))
                        }
                    }
                    remainder.removeFirst(frames * frameBytes)
                    try emit(resampler.append(values))
                }
                if next.isEmpty { break }
            }
            guard remainder.isEmpty else { throw ConversionError.invalidData }
            try emit(resampler.finish())

        case .unsupported(let sampleFormat):
            throw ConversionError.unsupportedFormat(sampleFormat)
        }

        guard samplesWritten <= maxWAVSamples else { throw ConversionError.tooLarge }
        let dataSize = UInt32(samplesWritten * 2)
        try output.seek(toOffset: 0)
        try output.write(contentsOf: header(dataSize: dataSize))
        try output.truncate(atOffset: UInt64(headerSize) + UInt64(dataSize))
        try output.synchronize()
    }

    private struct StreamingLinearResampler {
        private static let pendingCompactionThreshold = 4_096

        let ratio: Double
        let sourceRate: Int
        var pending: [Float] = []
        var pendingStart = 0
        var sourceBase = 0
        var nextOutput = 0
        var totalSamples = 0

        init(sourceRate: Int) throws {
            guard sourceRate > 0 else { throw ConversionError.invalidSampleRate }
            self.sourceRate = sourceRate
            ratio = Double(sourceRate) / Double(targetSampleRate)
        }

        mutating func append(_ values: [Float]) throws -> [Int16] {
            guard !values.isEmpty else { return [] }
            pending.append(contentsOf: values)
            totalSamples += values.count
            return try drain(final: false)
        }

        mutating func finish() throws -> [Int16] { try drain(final: true) }

        private mutating func drain(final: Bool) throws -> [Int16] {
            let targetCount = Int((Double(totalSamples) * Double(targetSampleRate)
                                   / Double(sourceRate)).rounded(.down))
            var output: [Int16] = []
            while nextOutput < targetCount {
                let position = Double(nextOutput) * ratio
                if !final && position + 1 >= Double(totalSamples) { break }
                let local = position - Double(sourceBase)
                let availableCount = pending.count - pendingStart
                guard local >= 0, local < Double(availableCount) else { break }
                let lower = Int(local)
                let value: Float
                if lower + 1 < availableCount {
                    let fraction = Float(local - Double(lower))
                    value = pending[pendingStart + lower]
                        + (pending[pendingStart + lower + 1] - pending[pendingStart + lower]) * fraction
                } else if final {
                    value = pending[pendingStart + lower]
                } else {
                    break
                }
                guard value.isFinite else { throw ConversionError.invalidData }
                let clamped = max(-32768, min(32767, value))
                output.append(Int16(clamping: Int(clamped.rounded())))
                nextOutput += 1

                let safeIndex = Int(floor(Double(nextOutput) * ratio))
                let removable = min(max(0, safeIndex - sourceBase), max(0, availableCount - 1))
                if removable > 0 {
                    pendingStart += removable
                    sourceBase += removable
                }
            }

            // Keep indexed reads cheap and bound stale samples to one small window.
            if pendingStart == pending.count {
                pending.removeAll(keepingCapacity: true)
                pendingStart = 0
            } else if pendingStart >= Self.pendingCompactionThreshold {
                pending.removeFirst(pendingStart)
                pendingStart = 0
            }
            return output
        }
    }

    static func header(dataSize: UInt32) -> Data {
        var h = Data(capacity: headerSize)
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { h.append(contentsOf: $0) } }
        h.append(contentsOf: Array("RIFF".utf8)); le32(36 + dataSize)
        h.append(contentsOf: Array("WAVEfmt ".utf8)); le32(16); le16(1); le16(1)
        le32(UInt32(targetSampleRate)); le32(UInt32(targetSampleRate) * 2); le16(2); le16(16)
        h.append(contentsOf: Array("data".utf8)); le32(dataSize)
        return h
    }
}

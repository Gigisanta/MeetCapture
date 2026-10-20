// PCMToWAV.swift
// Converts a raw capture (.pcm + sidecar) into one 16 kHz mono int16 WAV per
// channel. Streaming, 64 KB chunks, header patched after the data so the
// length is always right.

import AVFoundation
import Foundation

enum PCMToWAV {
    static let targetSampleRate = 16_000
    static let headerSize = 44
    /// RIFF's 32-bit chunk size includes 36 bytes beyond the PCM data.
    static let maxWAVSamples = Int((UInt32.max - 36) / 2)

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

    /// First channel only; see `convert(inputPath:format:outputURLs:)`.
    @discardableResult
    static func convert(inputPath: String, format: InputFormat, outputURL: URL) throws -> [Int] {
        try convert(inputPath: inputPath, format: format, outputURLs: [outputURL])
    }

    /// Streams channel i of the input into `outputURLs[i]` as a 16 kHz mono
    /// int16 WAV (mono input fills only the first) and returns each output's
    /// peak |sample|. Channels are never mixed: L and R carry different people.
    @discardableResult
    static func convert(inputPath: String, format: InputFormat, outputURLs: [URL]) throws -> [Int] {
        let channels: Int, sampleRate: Int, isFloat: Bool
        switch format {
        case .float32Mono(let rate): channels = 1; sampleRate = rate; isFloat = true
        case .int16Interleaved(let count, let rate):
            guard count > 0 else { throw ConversionError.invalidChannels }
            channels = count; sampleRate = rate; isFloat = false
        case .unsupported(let sampleFormat): throw ConversionError.unsupportedFormat(sampleFormat)
        }
        let outputs = Array(outputURLs.prefix(channels))
        guard !outputs.isEmpty else { throw ConversionError.invalidChannels }

        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: inputPath))
        defer { try? input.close() }
        var resamplers = try outputs.map { _ in try StreamingLinearResampler(sourceRate: sampleRate) }
        var writers = try outputs.map { try WAVWriter(url: $0) }
        defer { for writer in writers { try? writer.handle.close() } }

        let sampleBytes = isFloat ? MemoryLayout<Float>.size : MemoryLayout<Int16>.size
        let frameBytes = channels * sampleBytes
        var remainder = Data()
        while true {
            try Task.checkCancellation()
            let next = try input.read(upToCount: 64 * 1024) ?? Data()
            if next.isEmpty { break }
            remainder.append(next)
            let frames = remainder.count / frameBytes
            guard frames > 0 else { continue }
            var values = outputs.map { _ in [Float]() }
            for c in values.indices { values[c].reserveCapacity(frames) }
            try remainder.withUnsafeBytes { raw in
                for frame in 0..<frames {
                    for c in outputs.indices {
                        let offset = frame * frameBytes + c * sampleBytes
                        if isFloat {
                            let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                            let value = Float(bitPattern: bits) * 32767
                            guard value.isFinite else { throw ConversionError.invalidData }
                            values[c].append(value)
                        } else {
                            values[c].append(Float(Int16(littleEndian: raw.loadUnaligned(
                                fromByteOffset: offset, as: Int16.self))))
                        }
                    }
                }
            }
            remainder.removeFirst(frames * frameBytes)
            for c in outputs.indices { try writers[c].write(resamplers[c].append(values[c])) }
        }
        guard remainder.isEmpty else { throw ConversionError.invalidData }
        for c in outputs.indices {
            try writers[c].write(resamplers[c].finish())
            try writers[c].finish()
        }
        return writers.map(\.peak)
    }

    /// Streaming 16 kHz mono WAV: header patched once the length is known.
    private struct WAVWriter {
        let handle: FileHandle
        var samplesWritten = 0
        var peak = 0

        init(url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: PCMToWAV.header(dataSize: 0))
        }

        mutating func write(_ samples: [Int16]) throws {
            guard !samples.isEmpty else { return }
            guard samples.count <= PCMToWAV.maxWAVSamples - samplesWritten else { throw ConversionError.tooLarge }
            for sample in samples { peak = max(peak, abs(Int(sample))) }
            try handle.write(contentsOf: samples.withUnsafeBytes { Data($0) })
            samplesWritten += samples.count
        }

        func finish() throws {
            let dataSize = UInt32(samplesWritten * 2)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: PCMToWAV.header(dataSize: dataSize))
            try handle.truncate(atOffset: UInt64(PCMToWAV.headerSize) + UInt64(dataSize))
            try handle.synchronize()
        }
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

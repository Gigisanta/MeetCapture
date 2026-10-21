// AudioResampler.swift
// Stateful mono Float32 → Int16 resampler (AVAudioConverter keeps phase
// across calls). One instance per logical track; nothing allocated per call.

import AVFoundation
import Foundation

final class AudioResampler: @unchecked Sendable {
    enum ConversionError: LocalizedError {
        case invalidFrameCount(Int, capacity: Int)
        case missingSampleBuffer

        var errorDescription: String? {
            switch self {
            case .invalidFrameCount(let frames, let capacity):
                return "El conversor recibió \(frames) frames; la capacidad de entrada es \(capacity)."
            case .missingSampleBuffer:
                return "AVAudioConverter no proporcionó el buffer de muestras esperado."
            }
        }
    }

    private final class InputProvider: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let provider: InputProvider
    let inputRate: Double
    let outputRate: Double

    var outputFrameCapacity: Int { Int(outputBuffer.frameCapacity) }

    init?(inputRate: Double, outputRate: Double, channels: Int, frameCapacity: Int = AudioRingBuffer.maxFrames) {
        guard channels == 1, inputRate > 0, outputRate > 0, frameCapacity > 0 else { return nil }
        let outputCapacity = max(frameCapacity,
                                 Int(ceil(Double(frameCapacity) * outputRate / inputRate)) + 1)
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outputRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: UInt32(frameCapacity)),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                                   frameCapacity: UInt32(outputCapacity))
        else { return nil }
        self.inputRate = inputRate
        self.outputRate = outputRate
        self.converter = converter
        self.inputBuffer = inputBuffer
        self.outputBuffer = outputBuffer
        provider = InputProvider(buffer: inputBuffer)
    }

    /// Resamples `frameCount` mono floats into `out` (reused, cleared first).
    func resample(mono: UnsafePointer<Float>, frameCount: Int, into out: inout [Int16]) throws {
        out.removeAll(keepingCapacity: true)
        guard frameCount >= 0, frameCount <= Int(inputBuffer.frameCapacity) else {
            throw ConversionError.invalidFrameCount(frameCount, capacity: Int(inputBuffer.frameCapacity))
        }
        guard frameCount > 0 else { return }
        guard let destination = inputBuffer.floatChannelData?.pointee else {
            throw ConversionError.missingSampleBuffer
        }
        inputBuffer.frameLength = UInt32(frameCount)
        destination.update(from: mono, count: frameCount)
        outputBuffer.frameLength = 0
        provider.supplied = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { [provider] _, inputStatus in
            provider.next(inputStatus)
        }
        if status == .error { throw conversionFailure(error) }
        try copyOutput(into: &out)
    }

    /// One end-of-stream pass. Only `.endOfStream`, not an empty output buffer,
    /// confirms that the converter has finished draining.
    func flush(into out: inout [Int16]) throws -> AVAudioConverterOutputStatus {
        out.removeAll(keepingCapacity: true)
        outputBuffer.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        if status == .error { throw conversionFailure(error) }
        try copyOutput(into: &out)
        return status
    }

    private func copyOutput(into out: inout [Int16]) throws {
        guard outputBuffer.frameLength > 0 else { return }
        guard let source = outputBuffer.int16ChannelData?.pointee else {
            throw ConversionError.missingSampleBuffer
        }
        out.append(contentsOf: UnsafeBufferPointer(start: source, count: Int(outputBuffer.frameLength)))
    }

    private func conversionFailure(_ error: NSError?) -> NSError {
        error ?? NSError(
            domain: "MeetCapture.AudioResampler", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter falló sin proporcionar un NSError."])
    }

    func reset() {
        converter.reset()
        inputBuffer.frameLength = 0
        outputBuffer.frameLength = 0
    }
}

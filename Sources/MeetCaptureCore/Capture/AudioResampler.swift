// AudioResampler.swift
// Stateful mono Float32 → Int16 resampler (AVAudioConverter keeps phase
// across calls). One instance per logical track; nothing allocated per call.

import AVFoundation
import Foundation

final class AudioResampler: @unchecked Sendable {
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
    func resample(mono: UnsafePointer<Float>, frameCount: Int, into out: inout [Int16]) {
        out.removeAll(keepingCapacity: true)
        guard frameCount > 0, frameCount <= Int(inputBuffer.frameCapacity),
              let destination = inputBuffer.floatChannelData?.pointee else { return }
        inputBuffer.frameLength = UInt32(frameCount)
        destination.update(from: mono, count: frameCount)
        outputBuffer.frameLength = 0
        provider.supplied = false
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { [provider] _, inputStatus in
            provider.next(inputStatus)
        }
        guard status != .error, outputBuffer.frameLength > 0,
              let source = outputBuffer.int16ChannelData?.pointee else { return }
        out.append(contentsOf: UnsafeBufferPointer(start: source, count: Int(outputBuffer.frameLength)))
    }

    func resample(interleaved: UnsafePointer<Float>, frameCount: Int) -> [Int16] {
        var out: [Int16] = []
        resample(mono: interleaved, frameCount: frameCount, into: &out)
        return out
    }

    /// Drains the converter (end of stream).
    func flush() -> [Int16] {
        outputBuffer.frameLength = 0
        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
        guard status != .error, outputBuffer.frameLength > 0,
              let source = outputBuffer.int16ChannelData?.pointee else { return [] }
        return Array(UnsafeBufferPointer(start: source, count: Int(outputBuffer.frameLength)))
    }

    func reset() {
        converter.reset()
        inputBuffer.frameLength = 0
        outputBuffer.frameLength = 0
    }
}

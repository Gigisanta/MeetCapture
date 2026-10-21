import AVFoundation
import XCTest
@testable import MeetCaptureCore

final class AudioResamplerTests: XCTestCase {
    /// Feeds one second of a 440 Hz sine in 100 ms chunks and returns the
    /// resampled Int16 output (including the final flush).
    private func resampleOneSecond(inputRate: Double) throws -> [Int16] {
        let resampler = try XCTUnwrap(
            AudioResampler(inputRate: inputRate, outputRate: 16_000, channels: 1))
        let chunkFrames = Int(inputRate / 10)
        var result: [Int16] = []
        for chunk in 0..<10 {
            let start = chunk * chunkFrames
            let samples = (0..<chunkFrames).map { index -> Float in
                let t = Double(start + index) / inputRate
                return Float(sin(2 * .pi * 440 * t) * 0.5)
            }
            try samples.withUnsafeBufferPointer { buffer in
                result += try resampler.resample(interleaved: buffer.baseAddress!, frameCount: samples.count)
            }
        }
        result += try resampler.flush()
        return result
    }

    func test48kToleratesLessThan200SamplesDrift() throws {
        let out = try resampleOneSecond(inputRate: 48_000)
        XCTAssertLessThan(abs(out.count - 16_000), 200, "48k drift: \(out.count)")
        XCTAssertGreaterThan(out.map { abs(Int($0)) }.max() ?? 0, 10_000, "48k output is silent")
    }

    func test44_1kToleratesLessThan200SamplesDrift() throws {
        let out = try resampleOneSecond(inputRate: 44_100)
        XCTAssertLessThan(abs(out.count - 16_000), 200, "44.1k drift: \(out.count)")
        XCTAssertGreaterThan(out.map { abs(Int($0)) }.max() ?? 0, 10_000, "44.1k output is silent")
    }

    func testStereoLagIgnoresAmplitudeThresholdBiasButDetectsOneFrameDelay() throws {
        let system: [Int16] = Array(repeating: 0, count: 16)
            + [33, 100, -317, 8192, -1100, 440, -57, 0]
            + Array(repeating: 0, count: 16)
        let mic = system.map { $0 / 2 }
        XCTAssertNotEqual(system.firstIndex { abs(Int($0)) > 32 },
                          mic.firstIndex { abs(Int($0)) > 32 })
        let aligned = try XCTUnwrap(CaptureEngine.diagnosticWaveformLag(system: system, mic: mic))
        XCTAssertEqual(aligned.frames, 0)
        let delayed = [Int16(0)] + Array(mic.dropLast())
        let shifted = try XCTUnwrap(CaptureEngine.diagnosticWaveformLag(system: system, mic: delayed))
        XCTAssertEqual(shifted.frames, 1)
    }


    func testStereoConverterIsRejected() {
        XCTAssertNil(
            AudioResampler(inputRate: 48_000, outputRate: 16_000, channels: 2),
            "tracks are converted independently; a stereo converter must be rejected")
    }
}

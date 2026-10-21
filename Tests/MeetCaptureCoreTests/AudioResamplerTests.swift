import AVFoundation
import XCTest
@testable import MeetCaptureCore

final class AudioResamplerTests: XCTestCase {
    /// Feeds one second of a 440 Hz sine in 100 ms chunks and drains until
    /// the converter confirms end of stream, as the capture consumer must.
    private func resampleOneSecond(inputRate: Double) throws -> [Int16] {
        let resampler = try XCTUnwrap(
            AudioResampler(inputRate: inputRate, outputRate: 16_000, channels: 1))
        let chunkFrames = Int(inputRate / 10)
        var result: [Int16] = []
        var converted: [Int16] = []
        converted.reserveCapacity(resampler.outputFrameCapacity)
        for chunk in 0..<10 {
            let start = chunk * chunkFrames
            let samples = (0..<chunkFrames).map { index -> Float in
                let t = Double(start + index) / inputRate
                return Float(sin(2 * .pi * 440 * t) * 0.5)
            }
            try samples.withUnsafeBufferPointer { buffer in
                try resampler.resample(mono: buffer.baseAddress!, frameCount: samples.count, into: &converted)
            }
            result.append(contentsOf: converted)
        }
        var drained = false
        for _ in 0..<8 {
            let status = try resampler.flush(into: &converted)
            result.append(contentsOf: converted)
            if status == .endOfStream {
                drained = true
                break
            }
        }
        XCTAssertTrue(drained, "\(inputRate) Hz converter did not finish draining")
        return result
    }

    func testCaptureRatesPreserveDurationAndFinalWaveformAfterDrain() throws {
        for inputRate: Double in [16_000, 44_100, 48_000] {
            let out = try resampleOneSecond(inputRate: inputRate)
            XCTAssertLessThanOrEqual(abs(out.count - 16_000), 1, "\(inputRate) Hz drift: \(out.count)")
            XCTAssertGreaterThan(out.suffix(64).map { abs(Int($0)) }.max() ?? 0, 10_000,
                                 "\(inputRate) Hz final waveform is absent")
        }
    }

    func testOversizedAndNegativeInputFailWithoutLeavingStaleOutput() throws {
        let capacity = 8
        let resampler = try XCTUnwrap(
            AudioResampler(inputRate: 16_000, outputRate: 16_000, channels: 1, frameCapacity: capacity))
        let samples = [Float](repeating: 0.25, count: capacity + 1)
        for frameCount in [-1, capacity + 1] {
            var output: [Int16] = [1234]
            XCTAssertThrowsError(try samples.withUnsafeBufferPointer { buffer in
                try resampler.resample(mono: buffer.baseAddress!, frameCount: frameCount, into: &output)
            }) { error in
                guard let conversionError = error as? AudioResampler.ConversionError,
                      case .invalidFrameCount(let actual, let limit) = conversionError else {
                    return XCTFail("unexpected conversion error: \(error)")
                }
                XCTAssertEqual(actual, frameCount)
                XCTAssertEqual(limit, capacity)
            }
            XCTAssertTrue(output.isEmpty, "a rejected batch must not reuse the previous channel output")
        }
    }

    func testStereoConverterIsRejected() {
        XCTAssertNil(
            AudioResampler(inputRate: 48_000, outputRate: 16_000, channels: 2),
            "tracks are converted independently; a stereo converter must be rejected")
    }
}

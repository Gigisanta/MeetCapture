import AVFoundation
import Foundation

@main
struct AudioResamplerIntegrationTests {
  static func main() {
    var failures: [String] = []

    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
      if !condition() { failures.append(message) }
    }

    func run(inputRate: Double, seconds: Int) -> [Int16] {
      guard
        let resampler = AudioResampler(
          inputRate: inputRate,
          outputRate: 16_000,
          channels: 1
        )
      else {
        failures.append("resampler init failed for \(inputRate)")
        return []
      }

      let chunkFrames = Int(inputRate / 10)
      var result: [Int16] = []
      for chunk in 0..<(seconds * 10) {
        let start = chunk * chunkFrames
        let samples = (0..<chunkFrames).map { index -> Float in
          let t = Double(start + index) / inputRate
          return Float(sin(2 * .pi * 440 * t) * 0.5)
        }
        samples.withUnsafeBufferPointer { buffer in
          result += resampler.resample(
            interleaved: buffer.baseAddress!,
            frameCount: samples.count
          )
        }
      }
      result += resampler.flush()
      return result
    }

    let output48 = run(inputRate: 48_000, seconds: 1)
    check(abs(output48.count - 16_000) < 200, "48k drift: \(output48.count)")
    check(output48.map { abs(Int($0)) }.max() ?? 0 > 10_000, "48k output is silent")

    let output441 = run(inputRate: 44_100, seconds: 1)
    check(abs(output441.count - 16_000) < 200, "44.1k drift: \(output441.count)")
    check(output441.map { abs(Int($0)) }.max() ?? 0 > 10_000, "44.1k output is silent")

    let invalid = AudioResampler(inputRate: 48_000, outputRate: 16_000, channels: 2)
    check(invalid == nil, "stereo converter must be rejected; tracks are converted independently")

    if failures.isEmpty {
      print("AudioResamplerIntegrationTests: 5/5 PASS")
    } else {
      failures.forEach { print("FAIL: \($0)") }
      exit(1)
    }
  }
}

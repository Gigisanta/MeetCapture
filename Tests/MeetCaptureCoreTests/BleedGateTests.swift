import XCTest
@testable import MeetCaptureCore

final class BleedGateTests: XCTestCase {
    private let rate = BleedGate.sampleRate
    private let lag = BleedGate.maxLagSamples

    /// Deterministic speech-band noise in [-amp, amp].
    private func noise(_ count: Int, seed: UInt64, amp: Float) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return amp * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    /// `system` with the lag history the gate expects (zeros before the span).
    private func withHistory(_ system: [Float]) -> [Float] { [Float](repeating: 0, count: lag) + system }

    private func muted(_ out: [Float]) -> [Bool] {
        stride(from: 0, to: out.count - BleedGate.windowSamples + 1, by: BleedGate.windowSamples).map { start in
            out[start..<(start + BleedGate.windowSamples)].allSatisfy { $0 == 0 }
        }
    }

    func testDelayedEchoOfTheSystemChannelIsMuted() {
        let system = noise(3 * rate, seed: 1, amp: 0.3)
        let delay = 30 * rate / 1_000
        let mic = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.4 }
        let out = BleedGate.apply(mic: mic, system: withHistory(system))
        XCTAssertEqual(muted(out), [true, true, true, true, true, true])
    }

    func testGioAloneIsKeptAndTheRemoteSideSilentIsKept() {
        let gio = noise(2 * rate, seed: 2, amp: 0.3)
        let silence = [Float](repeating: 0, count: 2 * rate)
        XCTAssertEqual(BleedGate.apply(mic: gio, system: withHistory(silence)), gio)
        let unrelated = noise(2 * rate, seed: 3, amp: 0.3)
        XCTAssertEqual(BleedGate.apply(mic: gio, system: withHistory(unrelated)), gio,
                       "uncorrelated remote audio is not bleed")
    }

    func testDoubleTalkWhereGioDominatesIsKept() {
        let system = noise(2 * rate, seed: 4, amp: 0.05)
        let gio = noise(2 * rate, seed: 5, amp: 0.6)
        let delay = 20 * rate / 1_000
        let bleed = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay)
        let mic = zip(gio, bleed).map { $0 + $1 }
        XCTAssertEqual(BleedGate.apply(mic: mic, system: withHistory(system)), mic)
    }

    func testEchoBeyondTheLagRangeIsNotMuted() {
        let system = noise(2 * rate, seed: 6, amp: 0.3)
        let delay = 300 * rate / 1_000
        let mic = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.4 }
        let out = BleedGate.apply(mic: mic, system: withHistory(system))
        XCTAssertEqual(muted(out).dropFirst(), [false, false, false])
    }

    func testTrailingPartialWindowIsLeftAlone() {
        let system = noise(rate / 4, seed: 7, amp: 0.3)
        XCTAssertEqual(BleedGate.apply(mic: system, system: withHistory(system)), system)
    }
}

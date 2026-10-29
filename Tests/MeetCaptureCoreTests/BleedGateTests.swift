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

    /// `system` with lag history before and lead samples after (zeros outside the span).
    private func withHistory(_ system: [Float]) -> [Float] {
        [Float](repeating: 0, count: lag) + system + [Float](repeating: 0, count: BleedGate.maxLeadSamples)
    }

    private func muted(_ out: [Float]) -> [Bool] {
        stride(from: 0, to: out.count - BleedGate.windowSamples + 1, by: BleedGate.windowSamples).map { start in
            out[start..<(start + BleedGate.windowSamples)].allSatisfy { $0 == 0 }
        }
    }

    func testDelayedEchoOfTheSystemChannelIsMuted() {
        let system = noise(3 * rate, seed: 1, amp: 0.3)
        let delay = 30 * rate / 1_000
        var mic = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.4 }
        let gatedSamples = BleedGate.apply(mic: &mic, system: withHistory(system))
        XCTAssertEqual(muted(mic), [true, true, true, true, true, true])
        XCTAssertEqual(gatedSamples, 3 * rate)
    }

    func testMicCopyAheadOfTheTapIsMuted() {
        let system = noise(3 * rate, seed: 8, amp: 0.3)
        let lead = 5 * rate / 1_000
        var mic = system.dropFirst(lead).map { $0 * 0.4 } + [Float](repeating: 0, count: lead)
        let gatedSamples = BleedGate.apply(mic: &mic, system: withHistory(system))
        XCTAssertEqual(muted(mic), [true, true, true, true, true, true])
        XCTAssertEqual(gatedSamples, 3 * rate)
    }

    func testGioAloneIsKeptAndTheRemoteSideSilentIsKept() {
        let gio = noise(2 * rate, seed: 2, amp: 0.3)
        let silence = [Float](repeating: 0, count: 2 * rate)
        let unrelated = noise(2 * rate, seed: 3, amp: 0.3)
        for system in [silence, unrelated] {
            var mic = gio
            XCTAssertEqual(BleedGate.apply(mic: &mic, system: withHistory(system)), 0)
            XCTAssertEqual(mic, gio, "silence and uncorrelated remote audio are not bleed")
        }
    }

    func testDoubleTalkWhereGioDominatesIsKept() {
        let system = noise(2 * rate, seed: 4, amp: 0.05)
        let gio = noise(2 * rate, seed: 5, amp: 0.6)
        let delay = 20 * rate / 1_000
        let bleed = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay)
        let original = zip(gio, bleed).map { $0 + $1 }
        var mic = original
        XCTAssertEqual(BleedGate.apply(mic: &mic, system: withHistory(system)), 0)
        XCTAssertEqual(mic, original)
    }

    func testEchoBeyondTheLagRangeIsNotMuted() {
        let system = noise(2 * rate, seed: 6, amp: 0.3)
        let delay = 300 * rate / 1_000
        var mic = [Float](repeating: 0, count: delay) + system.prefix(system.count - delay).map { $0 * 0.4 }
        _ = BleedGate.apply(mic: &mic, system: withHistory(system))
        XCTAssertEqual(muted(mic).dropFirst(), [false, false, false])
    }

    func testLocalVoiceEchoedBackByTheRemoteSideIsKept() {
        let gio = noise(2 * rate, seed: 9, amp: 0.3)
        let delay = 300 * rate / 1_000
        let system = [Float](repeating: 0, count: delay) + gio.prefix(gio.count - delay).map { $0 * 0.4 }
        var mic = gio
        _ = BleedGate.apply(mic: &mic, system: withHistory(system))
        XCTAssertEqual(muted(mic).dropFirst(), [false, false, false])
    }

    func testTrailingPartialWindowIsLeftAlone() {
        for (count, expectedGated) in [(rate / 4, 0), (5 * rate / 4, rate)] {
            let system = noise(count, seed: 7, amp: 0.3)
            var mic = system
            XCTAssertEqual(BleedGate.apply(mic: &mic, system: withHistory(system)), expectedGated)
            XCTAssertTrue(mic.prefix(expectedGated).allSatisfy { $0 == 0 })
            XCTAssertEqual(mic.suffix(rate / 4), system.suffix(rate / 4),
                           "the partial window is neither changed nor counted")
        }
    }
}

// BleedGate.swift
// With Mac speakers the mic (R) also hears the remote side (L). A 0.5 s
// window of R is muted when that copy lands from 100 ms behind to 50 ms
// ahead of L (normalized cross-correlation above 0.4) and is not clearly
// louder than L: that is the remote voice coming back through the mic, not the local speaker. Calibrated
// on real calls with the eval harness: 0.4 mutes the bleed and keeps >95 % of
// local words; without the gate local WER was 100–220 %.

import Accelerate

enum BleedGate {
    static let sampleRate = 16_000
    static let windowSamples = sampleRate / 2
    /// Maximum delay of the speaker copy reaching the mic: 100 ms.
    static let maxLagSamples = sampleRate / 10
    /// The aggregate device does not align the tap and the mic sub-device: the mic
    /// copy can also land slightly before the tap copy (−2…−7 ms on the
    /// 2026-10-26/28/29 captures). Bound the lead to 50 ms so longer remote
    /// echoes of the local voice stay outside the search range.
    static let maxLeadSamples = sampleRate / 20
    static let correlation: Float = 0.4
    static let dominanceDB: Float = 10
    static let silenceDB: Float = -55

    /// `mic` is R for a span in [-1, 1]; `system` is L for the same span
    /// preceded by `maxLagSamples` of history and followed by `maxLeadSamples`
    /// (zeros outside the file).
    /// Zeros the bleed windows in place and returns their sample count.
    /// A trailing partial window is kept and never counted as gated.
    static func apply(mic: inout [Float], system: [Float]) -> Int {
        precondition(system.count == mic.count + maxLagSamples + maxLeadSamples,
                     "system needs lag history and lead samples")
        let windows = mic.count / windowSamples
        guard windows > 0 else { return 0 }
        var gatedSamples = 0
        let r = bandpass(mic), l = bandpass(system)
        for window in 0..<windows {
            let start = window * windowSamples
            let range = start..<(start + windowSamples)
            let lDB = dbfs(system[(start + maxLagSamples)..<(start + maxLagSamples + windowSamples)])
            let rDB = dbfs(mic[range])
            guard lDB > silenceDB, rDB - lDB < dominanceDB else { continue }
            if peakCorrelation(mic: r, system: l, start: start) > correlation {
                mic.replaceSubrange(range, with: repeatElement(0, count: windowSamples))
                gatedSamples += windowSamples
            }
        }
        return gatedSamples
    }

    /// Peak |NCC| of the R window at `start` against L delayed −maxLead…maxLag.
    /// `system` index `start` is `maxLag` samples before the window.
    static func peakCorrelation(mic: [Float], system: [Float], start: Int) -> Float {
        let lags = maxLagSamples + maxLeadSamples + 1
        var corr = [Float](repeating: 0, count: lags)
        mic.withUnsafeBufferPointer { r in
            system.withUnsafeBufferPointer { l in
                // corr[k] = Σn l[start+k+n]·r[start+n]; delay = maxLag − k,
                // from +maxLag (k = 0) to −maxLead.
                vDSP_conv(l.baseAddress! + start, 1, r.baseAddress! + start, 1,
                          &corr, 1, vDSP_Length(lags), vDSP_Length(windowSamples))
            }
        }
        let rNorm = sqrt(Double(vDSP.sumOfSquares(mic[start..<(start + windowSamples)])))
        // Sliding energy of the L window for each lag.
        var energy = Double(vDSP.sumOfSquares(system[start..<(start + windowSamples)]))
        var best: Float = 0
        for k in 0..<lags {
            if k > 0 {
                let out = Double(system[start + k - 1]), into = Double(system[start + k - 1 + windowSamples])
                energy = max(0, energy - out * out + into * into)
            }
            let denom = sqrt(energy) * rNorm
            if denom > 1e-12 { best = max(best, Float(Double(abs(corr[k])) / denom)) }
        }
        return best
    }

    static func dbfs(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return -180 }
        let rms = sqrt(vDSP.sumOfSquares(samples) / Float(samples.count))
        return 20 * log10(rms + 1e-9)
    }

    /// 200–4000 Hz, where speech carries and room rumble and hiss do not:
    /// 4th-order Butterworth high-pass and low-pass (two biquads each).
    static func bandpass(_ signal: [Float]) -> [Float] {
        let qs = [0.541_196_1, 1.306_563]
        var coefficients: [Double] = []
        for q in qs { coefficients += section(highPass: true, frequency: 200, q: q) }
        for q in qs { coefficients += section(highPass: false, frequency: 4_000, q: q) }
        guard var filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1,
                                       sectionCount: vDSP_Length(qs.count * 2), ofType: Float.self)
        else { return signal }
        return filter.apply(input: signal)
    }

    /// RBJ cookbook biquad, normalized: b0, b1, b2, a1, a2.
    private static func section(highPass: Bool, frequency: Double, q: Double) -> [Double] {
        let w0 = 2 * Double.pi * frequency / Double(sampleRate)
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = (highPass ? 1 + cosw : 1 - cosw) / 2
        let b1 = highPass ? -(1 + cosw) : 1 - cosw
        return [b0 / a0, b1 / a0, b0 / a0, -2 * cosw / a0, (1 - alpha) / a0]
    }
}

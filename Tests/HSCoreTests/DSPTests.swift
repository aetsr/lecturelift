import Foundation
import HSCore
import XCTest

// MARK: - helpers

/// Magnitude response (dB) of a normalised biquad {b0,b1,b2,a1,a2} at frequency f.
func responseDb(_ c: [Double], _ f: Double, _ fs: Double) -> Double {
    let w = 2 * Double.pi * f / fs
    func z(_ k: Double) -> (Double, Double) { (cos(-k * w), sin(-k * w)) }
    let (c1, s1) = z(1), (c2, s2) = z(2)
    let nr = c[0] + c[1] * c1 + c[2] * c2, ni = c[1] * s1 + c[2] * s2
    let dr = 1 + c[3] * c1 + c[4] * c2, di = c[3] * s1 + c[4] * s2
    return 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
}

func design(_ type: Int32, _ fs: Double, _ f0: Double, _ q: Double, _ g: Double) -> [Double] {
    var o = [Double](repeating: 0, count: 5)
    hs_design_biquad(type, fs, f0, q, g, &o)
    return o
}

/// Independent BS.1770-4 integrated loudness (48 kHz published K-filter coefficients, 400 ms
/// blocks with 75 % overlap, absolute −70 and relative −10 LU gates).
func integratedLUFS(_ L: [Float], _ R: [Float]) -> Double {
    let sb = [1.53512485958697, -2.69169618940638, 1.19839281085285], sa = [-1.69065929318241, 0.73248077421585]
    let rb = [1.0, -2.0, 1.0], ra = [-1.99004745483398, 0.99007225036621]
    func filt(_ x: [Float]) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var s1 = 0.0, s2 = 0.0, t1 = 0.0, t2 = 0.0
        for i in 0..<x.count {
            let a = Double(x[i]); let o = sb[0] * a + s1; s1 = sb[1] * a - sa[0] * o + s2; s2 = sb[2] * a - sa[1] * o
            let p = rb[0] * o + t1; t1 = rb[1] * o - ra[0] * p + t2; t2 = rb[2] * o - ra[1] * p
            y[i] = p
        }
        return y
    }
    let kl = filt(L), kr = filt(R)
    let block = 19200, hop = 4800
    var energies: [Double] = []
    var i = 0
    while i + block <= kl.count {
        var e = 0.0
        for k in i..<(i + block) { e += kl[k] * kl[k] + kr[k] * kr[k] }
        energies.append(e / Double(block)); i += hop
    }
    func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(max(e, 1e-30)) }
    let abs = energies.filter { lufs($0) > -70 }
    guard !abs.isEmpty else { return -.infinity }
    let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
    let gated = abs.filter { lufs($0) > rel }
    return lufs(gated.reduce(0, +) / Double(gated.count))
}

final class Chain {
    let e: OpaquePointer
    let fs: Double
    init(_ preset: String? = nil, fs: Double = 48000) {
        self.fs = fs
        e = hs_engine_create()!
        hs_engine_prepare(e, fs, 4096)
        if let preset { XCTAssertEqual(hs_engine_apply_preset(e, preset), 0) }
    }
    deinit { hs_engine_destroy(e) }
    func set(_ p: Int32, _ v: Float) { hs_engine_set_param(e, p, v) }
    /// Processes in 512-sample blocks, returns output (copy).
    func run(_ L: [Float], _ R: [Float], block: Int = 512) -> ([Float], [Float]) {
        var l = L, r = R
        var i = 0
        while i < l.count {
            let n = min(block, l.count - i)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                hs_engine_process_planar(e, lp.baseAddress! + i, rp.baseAddress! + i, Int32(n))
            } }
            i += n
        }
        return (l, r)
    }
}

struct Noise { var s: UInt64 = 0x9E3779B97F4A7C15
    mutating func next() -> Float { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Float(Double(s % 2_000_001) / 1_000_000 - 1) } }

func pinkNoise(_ n: Int, seed: UInt64 = 1) -> [Float] {
    var g = Noise(s: seed); var b0: Float = 0, b1: Float = 0, b2: Float = 0
    return (0..<n).map { _ in
        let w = g.next()
        b0 = 0.99765 * b0 + w * 0.0990460; b1 = 0.96300 * b1 + w * 0.2965164; b2 = 0.57000 * b2 + w * 1.0526913
        return (b0 + b1 + b2 + w * 0.1848) * 0.11
    }
}

func scaled(_ x: [Float], toLUFS target: Double) -> [Float] {
    let l = integratedLUFS(x, x)
    let g = Float(pow(10, (target - l) / 20))
    return x.map { $0 * g }
}

func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1))) }

// MARK: - tests

final class BiquadTests: XCTestCase {
    func testKWeightingMatchesBS1770At48k() {
        var s = [Double](repeating: 0, count: 5), r = s
        hs_design_kweighting(48000, &s, &r)
        let ps = [1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585]
        let pr = [1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621]
        for i in 0..<5 { XCTAssertEqual(s[i], ps[i], accuracy: 1e-9); XCTAssertEqual(r[i], pr[i], accuracy: 1e-9) }
    }

    func testKWeightingIsRateIndependent() {
        // The 44.1 kHz design must have the same response as the 48 kHz one at speech frequencies.
        var s48 = [Double](repeating: 0, count: 5), r48 = s48, s44 = s48, r44 = s48
        hs_design_kweighting(48000, &s48, &r48); hs_design_kweighting(44100, &s44, &r44)
        for f in [100.0, 1000, 4000, 10000] {
            XCTAssertEqual(responseDb(s48, f, 48000) + responseDb(r48, f, 48000), responseDb(s44, f, 44100) + responseDb(r44, f, 44100), accuracy: 0.05)
        }
    }

    func testHighPassIsMinus3dBAt80Hz() {
        let c = design(1, 48000, 80, 1 / 2.0.squareRoot(), 0)
        XCTAssertEqual(responseDb(c, 80, 48000), -3.01, accuracy: 0.02)
        XCTAssertEqual(responseDb(c, 40, 48000), -12.3, accuracy: 0.3)   // 12 dB/oct
        XCTAssertEqual(responseDb(c, 1000, 48000), 0, accuracy: 0.01)
    }

    func testPeakAndShelfGains() {
        XCTAssertEqual(responseDb(design(3, 48000, 300, 1, -3), 300, 48000), -3, accuracy: 1e-6)
        XCTAssertEqual(responseDb(design(3, 48000, 3000, 1, 2.5), 3000, 48000), 2.5, accuracy: 1e-6)
        let sh = design(5, 48000, 8000, 1, 1.5)
        XCTAssertEqual(responseDb(sh, 8000, 48000), 0.75, accuracy: 0.01)   // shelf mid-point = half gain
        XCTAssertEqual(responseDb(sh, 20000, 48000), 1.5, accuracy: 0.1)
        XCTAssertEqual(responseDb(sh, 500, 48000), 0, accuracy: 0.02)
    }

    func testCookbookAgainstIndependentFormula() {
        // Peaking EQ written out independently (RBJ cookbook), compared coefficient by coefficient.
        let fs = 44100.0, f0 = 1234.0, q = 0.8, g = -4.2
        let A = pow(10, g / 40), w0 = 2 * Double.pi * f0 / fs, al = sin(w0) / (2 * q)
        let a0 = 1 + al / A
        let ref = [(1 + al * A) / a0, -2 * cos(w0) / a0, (1 - al * A) / a0, -2 * cos(w0) / a0, (1 - al / A) / a0]
        let c = design(3, fs, f0, q, g)
        for i in 0..<5 { XCTAssertEqual(c[i], ref[i], accuracy: 1e-12) }
    }
}

final class ChainTests: XCTestCase {
    func testPresetAusIsBitIdentical() {
        var g = Noise()
        let L = (0..<20000).map { _ in g.next() }, R = (0..<20000).map { _ in g.next() }
        let (l, r) = Chain("off").run(L, R, block: 333)
        XCTAssertEqual(l.map(\.bitPattern), L.map(\.bitPattern))
        XCTAssertEqual(r.map(\.bitPattern), R.map(\.bitPattern))
    }

    func testUnknownPresetIsRejected() {
        let e = hs_engine_create()!; defer { hs_engine_destroy(e) }
        XCTAssertEqual(hs_engine_apply_preset(e, "nope"), -1)
    }

    func testLimiterCeilingIsNeverExceeded() {
        let c = Chain("off"); c.set(Int32(HS_P_LIMIT_ON), 1)
        var g = Noise(s: 7)
        // loud noise with +12 dBFS spikes
        let L = (0..<96000).map { i -> Float in g.next() * (i % 1000 == 0 ? 4 : 1.5) }
        let (l, r) = c.run(L, L)
        let ceiling: Float = 0.8912509
        // The first 10 ms are the bypass→on crossfade from the (unlimited) original (D-012).
        XCTAssertLessThanOrEqual(l[480...].map(abs).max()!, ceiling)
        XCTAssertLessThanOrEqual(r[480...].map(abs).max()!, ceiling)
        XCTAssertEqual(hs_engine_latency_samples(c.e), 72)
    }

    /// Low-frequency overs (the case that broke the deque) and a transient: the gain must reach the
    /// requirement by itself, so the final safety clamp never has to act.
    func testLimiterNeedsNoClampForLowFrequencyOversAndSpikes() {
        for f in [60.0, 100.0, 3000.0] {
            let c = Chain("off"); c.set(Int32(HS_P_LIMIT_ON), 1)
            let x = (0..<48000).map { Float(2.0 * sin(2 * Double.pi * f * Double($0) / 48000)) }
            let (l, _) = c.run(x, x)
            var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
            XCTAssertEqual(t.limiterClips, 0, "clamp acted at \(f) Hz")
            XCTAssertLessThanOrEqual(l[480...].map(abs).max()!, 0.8912509)
            XCTAssertGreaterThan(l[24000...].map(abs).max()!, 0.88, "limiter over-attenuates at \(f) Hz")
        }
        let c = Chain("off"); c.set(Int32(HS_P_LIMIT_ON), 1)
        var x = (0..<48000).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        x[30000] = 4   // +12 dBFS single-sample spike
        _ = c.run(x, x)
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        XCTAssertEqual(t.limiterClips, 0)
    }

    func testLimiterToggleIsClickFree() {
        let c = Chain("off"); c.set(Int32(HS_P_HPF_ON), 1)
        let x = (0..<48000).map { Float(1.2 * sin(2 * Double.pi * 200 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<100 {
            if k == 30 { c.set(Int32(HS_P_LIMIT_ON), 1) }
            if k == 60 { c.set(Int32(HS_P_LIMIT_ON), 0) }
            out += c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)])).0
        }
        // 200 Hz at 1.2 changes by ≤ 2π·200/48000·1.2 ≈ 0.031 per sample
        XCTAssertLessThan(zip(out.dropFirst(), out).map { abs($0 - $1) }.max()!, 0.045)
    }

    func testLevelerGainSettlesOnStationaryInput() {
        let c = Chain("off"); c.set(Int32(HS_P_LEVEL_ON), 1)
        let x = scaled(pinkNoise(48000 * 40, seed: 4), toLUFS: -26)
        _ = c.run(Array(x[..<(48000 * 15)]), Array(x[..<(48000 * 15)]))
        var gains: [Float] = []
        for k in 0..<50 {   // 25 s, sample the gain every 0.5 s
            let seg = Array(x[(48000 * 15 + k * 24000)..<(48000 * 15 + (k + 1) * 24000)])
            _ = c.run(seg, seg)
            var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t); gains.append(t.levelerGainDb)
        }
        XCTAssertLessThan(gains.max()! - gains.min()!, 1.0, "AGC gain not settled: \(gains.min()!)…\(gains.max()!)")
    }

    func testLevelerFollowsALastingLevelDrop() {
        let c = Chain("off"); c.set(Int32(HS_P_LEVEL_ON), 1)
        let loud = scaled(pinkNoise(48000 * 15, seed: 6), toLUFS: -15)
        let quiet = scaled(pinkNoise(48000 * 40, seed: 8), toLUFS: -28)   // −13 LU drop
        _ = c.run(loud, loud)
        let (l, r) = c.run(quiet, quiet)
        XCTAssertEqual(integratedLUFS(Array(l[(48000 * 30)...]), Array(r[(48000 * 30)...])), -18, accuracy: 1.5)
    }

    func testNonFiniteInputDoesNotPoisonTheChain() {
        let c = Chain("clarity")
        var x = scaled(pinkNoise(72000, seed: 12), toLUFS: -20)
        x[1000] = .nan; x[1001] = .infinity
        let (l, r) = c.run(x, x)
        XCTAssertTrue(l.allSatisfy(\.isFinite) && r.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rms(l[48000...]), 0.01, "chain went silent after a NaN")
    }

    func testBlockSizeDoesNotChangeTheResult() {
        let x = scaled(pinkNoise(24000, seed: 13), toLUFS: -20)
        let ref = Chain("clarity").run(x, x, block: 512).0
        for b in [1, 4096] {
            let out = Chain("clarity").run(x, x, block: b).0
            XCTAssertEqual(zip(ref, out).map { abs($0 - $1) }.max()!, 0, accuracy: 1e-6, "block \(b)")
        }
    }

    func testChainAt44k1() {
        let x = scaled(pinkNoise(44100 * 20, seed: 14), toLUFS: -26)
        let (l, _) = Chain("clarity", fs: 44100).run(x, x)
        XCTAssertTrue(l.allSatisfy { $0.isFinite && abs($0) <= 0.8912509 })
    }

    func testDeEsserLR4SumIsFlatWithoutReduction() {
        for f in [1000.0, 5000.0, 9000.0] {
            let c = Chain("off"); c.set(Int32(HS_P_DEESS_ON), 1); c.set(Int32(HS_P_DEESS_MAX_DB), 0)
            let x = (0..<48000).map { Float(0.3 * sin(2 * Double.pi * f * Double($0) / 48000)) }
            let (l, _) = c.run(x, x)
            XCTAssertEqual(20 * log10(rms(l[24000...]) / rms(x[24000...])), 0, accuracy: 0.05, "\(f) Hz")
        }
    }

    func testLimiterIsTransparentBelowCeiling() {
        let c = Chain("off"); c.set(Int32(HS_P_LIMIT_ON), 1)
        let x = (0..<48000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        let (l, _) = c.run(x, x)
        // after warm-up the output is the input delayed by the look-ahead, unchanged
        for i in 4800..<48000 { XCTAssertEqual(l[i], x[i - 72], accuracy: 1e-6) }
    }

    func testLevelerReachesTargetFromQuiet() {
        let c = Chain("off"); c.set(Int32(HS_P_LEVEL_ON), 1)
        let x = scaled(pinkNoise(48000 * 30), toLUFS: -30)
        let (l, r) = c.run(x, x)
        let tail = Array(l[(48000 * 20)...]), tailR = Array(r[(48000 * 20)...])
        XCTAssertEqual(integratedLUFS(tail, tailR), -18, accuracy: 1.0)
    }

    func testLevelerReachesTargetFromLoud() {
        let c = Chain("off"); c.set(Int32(HS_P_LEVEL_ON), 1)
        let x = scaled(pinkNoise(48000 * 20, seed: 3), toLUFS: -10)
        let (l, r) = c.run(x, x)
        XCTAssertEqual(integratedLUFS(Array(l[(48000 * 10)...]), Array(r[(48000 * 10)...])), -18, accuracy: 1.0)
    }

    func testLevelerFreezesGainInPauses() {
        // 8 s "speech" at −28 LUFS, then 6 s pause with room noise at −60 dBFS RMS: the AGC gain
        // must stay frozen during the pause (no pumping of the noise floor).
        let c = Chain("off"); c.set(Int32(HS_P_LEVEL_ON), 1)
        let speech = scaled(pinkNoise(48000 * 8, seed: 5), toLUFS: -28)
        var noise = pinkNoise(48000 * 6, seed: 9)
        let nr = rms(noise[...]); noise = noise.map { $0 * Float(0.001 / nr) }
        _ = c.run(speech, speech)
        _ = c.run(Array(noise[..<48000]), Array(noise[..<48000]))      // first second of the pause
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        let early = t.levelerGainDb
        _ = c.run(Array(noise[48000...]), Array(noise[48000...]))       // remaining 5 s
        hs_engine_read_telemetry(c.e, &t)
        XCTAssertGreaterThan(early, 3, "AGC should have raised the quiet speech")
        XCTAssertEqual(t.levelerGainDb, early, accuracy: 0.5, "AGC gain moved during the pause")
    }

    func testDeEsserReducesSibilanceButNotVoice() {
        // Vowel-like 500 Hz tone: no reduction. Same tone plus a strong 6.5 kHz component: reduction
        // of the high band between 1 and 3 dB, low band untouched.
        let n = 48000
        let voice = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 500 * Double($0) / 48000)) }
        let sib = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 6500 * Double($0) / 48000)) }
        let c1 = Chain("off"); c1.set(Int32(HS_P_DEESS_ON), 1)
        let (v, _) = c1.run(voice, voice)
        XCTAssertEqual(20 * log10(rms(v[24000...]) / rms(voice[24000...])), 0, accuracy: 0.1)
        let mixed = zip(voice, sib).map { $0 + $1 }
        let c2 = Chain("off"); c2.set(Int32(HS_P_DEESS_ON), 1)
        let (m, _) = c2.run(mixed, mixed)
        var t = hs_telemetry(); hs_engine_read_telemetry(c2.e, &t)
        XCTAssertLessThanOrEqual(t.deessDb, -1.0)
        XCTAssertGreaterThanOrEqual(t.deessDb, -3.01)
        // Measured on the signal: the 6.5 kHz component drops 1–3 dB, the 500 Hz component stays.
        func amp(_ x: ArraySlice<Float>, _ f: Double) -> Double {
            var re = 0.0, im = 0.0
            for (k, v) in x.enumerated() { let ph = 2 * Double.pi * f * Double(k) / 48000; re += Double(v) * cos(ph); im += Double(v) * sin(ph) }
            return 2 * sqrt(re * re + im * im) / Double(x.count)
        }
        let hi = 20 * log10(amp(m[24000..<48000], 6500) / amp(mixed[24000..<48000], 6500))
        let lo = 20 * log10(amp(m[24000..<48000], 500) / amp(mixed[24000..<48000], 500))
        XCTAssertLessThanOrEqual(hi, -1.0); XCTAssertGreaterThanOrEqual(hi, -3.1)
        XCTAssertEqual(lo, 0, accuracy: 0.1)
    }

    func testDeEsserIgnoresQuietHiss() {
        var g = Noise(s: 11)
        let hiss = (0..<48000).map { _ in g.next() * 0.0003 }   // ≈ −75 dBFS
        let c = Chain("off"); c.set(Int32(HS_P_DEESS_ON), 1)
        _ = c.run(hiss, hiss)
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        XCTAssertEqual(t.deessDb, 0, accuracy: 0.05)
    }

    func testBypassToggleIsClickFree() {
        let c = Chain("off")
        let x = (0..<48000).map { Float(0.5 * sin(2 * Double.pi * 1000 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<(x.count / 480) {
            if k == 40 { c.set(Int32(HS_P_EQ_ON), 1); c.set(Int32(HS_P_PRESENCE_DB), 5) }
            if k == 70 { c.set(Int32(HS_P_EQ_ON), 0) }
            let (l, _) = c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)]))
            out += l
        }
        // A 1 kHz sine at 0.5 changes by at most 2π·1000/48000·0.5·gain ≈ 0.066·gain per sample.
        let maxStep = zip(out.dropFirst(), out).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(maxStep, 0.09)
    }

    func testRateGuardDisablesHighFiltersAt16k() {
        // At 16 kHz (Bluetooth HFP) the 8 kHz shelf is disabled and the de-esser band moves down: must stay sane.
        let c = Chain("clarity", fs: 16000)
        var g = Noise(s: 2)
        let x = (0..<32000).map { _ in g.next() * 0.2 }
        let (l, _) = c.run(x, x)
        XCTAssertTrue(l.allSatisfy { $0.isFinite && abs($0) <= 0.8912509 })
    }

    func testPresetValuesReportWhatAPresetSets() {
        var v = [Float](repeating: 0, count: Int(HS_P_COUNT)), m = [UInt8](repeating: 0, count: Int(HS_P_COUNT))
        XCTAssertEqual(hs_preset_values("auditorium", &v, &m), 0)
        XCTAssertEqual(m[Int(HS_P_REVERB_ON)], 1); XCTAssertEqual(v[Int(HS_P_REVERB_ON)], 1)
        XCTAssertEqual(v[Int(HS_P_ROOM)], 2); XCTAssertEqual(v[Int(HS_P_WET)], 0.18, accuracy: 1e-6)
        XCTAssertEqual(m[Int(HS_P_DENOISE_ON)], 0, "presets never touch the denoiser switch")
        XCTAssertEqual(m[Int(HS_P_AB_ORIGINAL)], 0)
        XCTAssertEqual(hs_preset_values("nope", &v, &m), -1)
    }

    func testLevelerStrengthChangeIsContinuous() {
        let c = Chain("clarity")
        let x = (0..<96000).map { Float(0.2 * sin(2 * Double.pi * 200 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<200 {
            if k == 100 { c.set(Int32(HS_P_LEVEL_STRENGTH), 1) }
            out += c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)])).0
        }
        // 200 Hz at ≤ 0.89 changes ≤ 0.024/sample; a make-up jump of ~5 dB would show as a step
        XCTAssertLessThan(zip(out[4800...].dropFirst(), out[4800...]).map { abs($0 - $1) }.max()!, 0.04)
    }
}

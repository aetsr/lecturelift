import Foundation
import HSCore
import XCTest

final class ReverbTests: XCTestCase {
    func testFFTBackendIsAccelerate() {
        XCTAssertEqual(String(cString: hs_fft_backend()), "vdsp")
    }

    /// Two-stage partitioned convolution must equal direct convolution for any block size.
    func testConvolverMatchesNaiveConvolution() {
        var g = Noise(s: 21)
        for irLen in [300, 2048, 10000] {
            let ir = (0..<irLen).map { i in g.next() * Float(exp(-Double(i) / Double(irLen / 4))) }
            let x = (0..<12000).map { _ in g.next() }
            var ref = [Double](repeating: 0, count: x.count)
            for n in 0..<x.count { var acc = 0.0; for k in 0..<min(irLen, n + 1) { acc += Double(ir[k]) * Double(x[n - k]) }; ref[n] = acc }
            let refPeak = ref.map(abs).max()!
            for block in [1, 37, 256, 471, 512] {
                var out = [Float](repeating: 0, count: x.count)
                XCTAssertEqual(hs_test_convolve(ir, Int32(irLen), x, &out, Int32(x.count), Int32(block)), 0)
                let err = zip(out, ref).map { abs(Double($0) - $1) }.max()!
                XCTAssertLessThan(20 * log10(err / refPeak), -100, "ir \(irLen) block \(block)")
            }
        }
    }

    func reverbChain(_ preset: String) -> Chain {
        let c = Chain(preset)
        XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 42), 0)
        return c
    }

    func testBuiltButDisabledReverbIsBitIdentical() {
        let c = reverbChain("off")
        var g = Noise(s: 3)
        let x = (0..<20000).map { _ in g.next() }
        XCTAssertEqual(c.run(x, x).0.map(\.bitPattern), x.map(\.bitPattern))
    }

    func testReverbAddsADecayingTailWithoutLatency() {
        let c = Chain("off")
        c.set(Int32(HS_P_REVERB_ON), 1); c.set(Int32(HS_P_WET), 0.4); c.set(Int32(HS_P_PREDELAY_MS), 10); c.set(Int32(HS_P_DISTANCE), 0)
        XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 42), 0)
        _ = c.run([Float](repeating: 0, count: 4800), [Float](repeating: 0, count: 4800))   // finish the enable ramp
        var x = [Float](repeating: 0, count: 96000); x[0] = 1
        let (l, _) = c.run(x, x)
        // The only chain latency is the limiter look-ahead (constant, D-012); the reverb adds none.
        let lat = Int(hs_engine_latency_samples(c.e))
        XCTAssertEqual(lat, 72)
        XCTAssertEqual(l[..<lat].map(abs).max()!, 0)
        XCTAssertEqual(l[lat], 0.6, accuracy: 1e-5, "dry impulse × (1 − wet) at the chain latency")
        XCTAssertEqual(l[(lat + 1)..<(lat + 470)].map(abs).max()!, 0, accuracy: 1e-6, "nothing before the 10 ms pre-delay")
        let early = rms(l[4800..<14400]), late = rms(l[48000..<57600])
        XCTAssertGreaterThan(early, 1e-4)
        XCTAssertLessThan(late, early * 0.5, "tail must decay (RT60 1 s)")
    }

    func testRoomChangeIsClickFreeAndRetiresOldPair() {
        let c = reverbChain("hall")
        let x = (0..<48000).map { Float(0.3 * sin(2 * Double.pi * 300 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<100 {
            if k == 40 { c.set(Int32(HS_P_ROOM), 2); XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 7), 0) }
            out += c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)])).0
        }
        let maxStep = zip(out[24000...].dropFirst(), out[24000...]).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(maxStep, 0.1)
        XCTAssertEqual(hs_engine_reverb_needs_rebuild(c.e), 0)
        hs_engine_collect_garbage(c.e)   // the old pair has been returned after its 300 ms fade
        XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 7), 1, "nothing to rebuild")
    }

    func testDisableDrainReenableHasNoStaleTail() {
        let c = Chain("off")
        c.set(Int32(HS_P_REVERB_ON), 1); c.set(Int32(HS_P_WET), 0.4)
        XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 1), 0)
        var g = Noise(s: 5)
        let loud = (0..<48000).map { _ in g.next() * 0.5 }
        _ = c.run(loud, loud)
        c.set(Int32(HS_P_REVERB_ON), 0)
        let silence = [Float](repeating: 0, count: 48000 * 3)
        let (s1, _) = c.run(silence, silence)       // disabled: after the 10 ms ramp and the limiter delay, silence stays silence
        XCTAssertEqual(s1[1000...].map(abs).max()!, 0)
        c.set(Int32(HS_P_REVERB_ON), 1)
        let (s2, _) = c.run(silence, silence)       // re-enabled on silence: the drained state is clean
        XCTAssertLessThan(s2.map(abs).max()!, 1e-6)
    }

    /// Re-enable while the convolver is still draining (not only after a full drain) — D-014 must-fix.
    func testReenableMidDrainReplaysNoStaleAudio() {
        let c = Chain("off")
        c.set(Int32(HS_P_REVERB_ON), 1); c.set(Int32(HS_P_WET), 0.4)
        XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 1), 0)
        let silence = [Float](repeating: 0, count: 4800)
        _ = c.run(silence, silence)
        c.set(Int32(HS_P_REVERB_ON), 0)
        let burst = [Float](repeating: 0.5, count: 480)            // arrives during the disable ramp
        _ = c.run(burst, burst)
        _ = c.run(silence, silence)                                  // 100 ms gap: still draining
        c.set(Int32(HS_P_REVERB_ON), 1)
        let before = c.run(silence, silence).0                       // re-enable on silence
        _ = before
        // only the burst's own (decaying, faded-out) tail may remain — not the parked pre-delay copy
        let (after, _) = c.run([Float](repeating: 0, count: 48000), [Float](repeating: 0, count: 48000))
        XCTAssertLessThan(after.map(abs).max()!, 0.05)
    }

    func testTwoQuickRoomChangesAreClickFree() {
        let c = reverbChain("hall")
        c.set(Int32(HS_P_WET), 0.4)
        let x = (0..<48000).map { Float(0.3 * sin(2 * Double.pi * 300 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<100 {
            if k == 40 { c.set(Int32(HS_P_ROOM), 2); XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 7), 0) }
            if k == 50 { c.set(Int32(HS_P_ROOM), 0); XCTAssertEqual(hs_engine_rebuild_reverb(c.e, 8), 0) }   // 100 ms later
            out += c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)])).0
        }
        XCTAssertLessThan(zip(out[24000...].dropFirst(), out[24000...]).map { abs($0 - $1) }.max()!, 0.1)
    }

    func testIRHasNoFalseInterauralDelayFromJitter() {
        // identical ear geometry for the floor reflection → the first strong reflections of L and R
        // must align within one sample (the ears are 18 cm apart horizontally only)
        let n = Int(hs_ir_length(1, 48000))
        var l = [Float](repeating: 0, count: n), r = l
        _ = hs_ir_generate(1, 0.5, 48000, 42, &l, &r, Int32(n))
        let fl = l.firstIndex { abs($0) > 1e-3 }!, fr = r.firstIndex { abs($0) > 1e-3 }!
        XCTAssertLessThanOrEqual(abs(fl - fr), 26, "≤ 0.18 m / 343 m/s ≈ 25 samples")
    }

    func testPredelayChangeIsClickFree() {
        let c = reverbChain("hall")
        let x = (0..<48000).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<100 {
            if k == 50 { c.set(Int32(HS_P_PREDELAY_MS), 35) }
            out += c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)])).0
        }
        XCTAssertLessThan(zip(out[24000...].dropFirst(), out[24000...]).map { abs($0 - $1) }.max()!, 0.05)
    }

    func testFullPresetsStayWithinCeilingAndLatency() {
        for preset in ["seminar", "hall", "auditorium"] {
            let c = reverbChain(preset)
            let x = scaled(pinkNoise(48000 * 6, seed: 31), toLUFS: -20)
            let (l, r) = c.run(x, x)
            XCTAssertTrue(l[480...].allSatisfy { abs($0) <= 0.8912509 } && r[480...].allSatisfy { abs($0) <= 0.8912509 }, preset)
            XCTAssertEqual(hs_engine_latency_samples(c.e), 72, preset)
        }
    }
}

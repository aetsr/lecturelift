import Foundation
import HSCore
import XCTest

/// Needs scripts/build_libdf.sh (vendor/libdf). Skipped otherwise.
final class DenoiserTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let lib = root.appendingPathComponent("vendor/libdf/lib/libdf.dylib").path
    let model = root.appendingPathComponent("vendor/libdf/models/DeepFilterNet3_onnx.tar.gz").path

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: lib), "libDF not built")
        XCTAssertEqual(hs_denoiser_library_load(lib), 0)
    }

    func engine(sync: Bool, atten: Float = 8) -> Chain {
        let c = Chain("off")
        c.set(Int32(HS_P_DENOISE_DB), atten)
        XCTAssertEqual(hs_engine_denoiser_load(c.e, model, sync ? 1 : 0, 256), 0)
        c.set(Int32(HS_P_DENOISE_ON), 1)
        return c
    }

    func testLatencyIsFixedAndReported() {
        let c = engine(sync: true)
        XCTAssertEqual(hs_engine_denoiser_latency(c.e), 480 + 256 + 720 + 1440)
        // the chain latency includes the denoiser only once it is actually mixed in (after one full
        // latency of real input + the 20 ms ramp; D-026), so the A/B original stays aligned
        XCTAssertEqual(hs_engine_latency_samples(c.e), 72)
        let z = [Float](repeating: 0.01, count: 9600)
        _ = c.run(z, z, block: 256)
        XCTAssertEqual(hs_engine_latency_samples(c.e), 2896 + 72)   // + limiter look-ahead (chain active)
        XCTAssertEqual(hs_engine_denoiser_load(c.e, model, 1, 256), -4, "only one denoiser")
        hs_engine_denoiser_unload(c.e, 1)
    }

    /// With a 1 dB attenuation limit the output is mostly the (aligned) noisy input: it must be the
    /// input delayed by exactly the reported latency. (0 dB is clamped to 1: libDF's 0 dB shortcut
    /// returns the undelayed frame, D-016.)
    func testOutputIsAlignedWithReportedLatency() {
        let c = engine(sync: true, atten: 0)   // clamped to 1 dB
        XCTAssertEqual(hs_engine_get_param(c.e, Int32(HS_P_DENOISE_DB)), 1)
        let n = 48000 * 3
        var g = Noise(s: 5)
        let x = (0..<n).map { _ in g.next() * 0.2 }   // broadband: unambiguous cross-correlation
        let (l, _) = c.run(x, x, block: 256)
        let lat = Int(hs_engine_latency_samples(c.e))
        var best = 0, bestC = -1.0
        for lag in 0...6000 {
            var acc = 0.0, ex = 0.0, ey = 0.0
            for i in stride(from: 48000, to: n - lag, by: 3) { acc += Double(x[i]) * Double(l[i + lag]); ex += Double(x[i] * x[i]); ey += Double(l[i + lag] * l[i + lag]) }
            let cc = acc / (ex * ey).squareRoot()
            if cc > bestC { bestC = cc; best = lag }
        }
        XCTAssertEqual(best, lat, accuracy: 2, "corr \(bestC)")
        XCTAssertGreaterThan(bestC, 0.95)
        hs_engine_denoiser_unload(c.e, 1)
    }

    func testDenoisingReducesStationaryNoise() {
        let c = engine(sync: true, atten: 24)
        var g = Noise(s: 77)
        let noise = (0..<48000 * 3).map { _ in g.next() * 0.05 }
        let (l, _) = c.run(noise, noise, block: 256)
        let reduction = 20 * log10(rms(l[48000...]) / rms(noise[48000...]))
        XCTAssertLessThan(reduction, -10, "DFN3 should remove stationary noise (got \(reduction) dB)")
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        XCTAssertEqual(t.dnUnderflows, 0)
        XCTAssertEqual(t.dnNaN, 0)
        XCTAssertEqual(t.dnHops, UInt64(48000 * 3 / 480))
        hs_engine_denoiser_unload(c.e, 1)
    }

    /// Live worker paused → the I/O side must fall back to the equally delayed input (never silence,
    /// no time jump), and return to denoised output once the worker catches up.
    func testUnderflowFallsBackToDelayedInputAndRecovers() {
        let c = engine(sync: false, atten: 1)
        let x = (0..<480000).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / 48000)) }
        hs_engine_denoiser_test_pause(c.e, 1)
        var out: [Float] = []
        for k in 0..<100 { out += c.run(Array(x[(k * 256)..<((k + 1) * 256)]), Array(x[(k * 256)..<((k + 1) * 256)])).0 }
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        XCTAssertGreaterThan(t.dnUnderflows, 0)
        let lat = Int(hs_engine_latency_samples(c.e))
        // after the prefill is used up the output is the delayed input (fallback), not silence
        for i in 20000..<25600 { XCTAssertEqual(out[i], x[i - lat], accuracy: 1e-4) }
        hs_engine_denoiser_test_pause(c.e, 0)
        for k in 100..<300 {
            out += c.run(Array(x[(k * 256)..<((k + 1) * 256)]), Array(x[(k * 256)..<((k + 1) * 256)])).0
            usleep(5333)   // real time for the worker
        }
        let max = zip(out.dropFirst(), out).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(max, 0.1, "no click when falling back / recovering")
        hs_engine_denoiser_unload(c.e, 0)
    }

    func testNonFiniteInputAndUnloadWhileRunning() {
        let c = engine(sync: false)
        var x = (0..<48000).map { Float(0.1 * sin(Double($0) * 0.05)) }
        x[5000] = .nan; x[5001] = .infinity
        var out: [Float] = []
        for k in 0..<(48000 / 256) {
            out += c.run(Array(x[(k * 256)..<((k + 1) * 256)]), Array(x[(k * 256)..<((k + 1) * 256)])).0
            usleep(1000)
        }
        XCTAssertTrue(out.allSatisfy(\.isFinite))
        hs_engine_denoiser_unload(c.e, 0)   // joins the worker
        XCTAssertEqual(hs_engine_denoiser_latency(c.e), 0)
    }

    // ---- D-017 regression tests ----

    /// A worker stall longer than the input ring (> ~340 ms) must not disable denoising for good:
    /// after the stall the fallback ends and noise reduction returns.
    func testLongStallRecovers() {
        let c = engine(sync: false, atten: 24)
        var g = Noise(s: 81)
        let block = { (0..<256).map { _ in g.next() * 0.05 } }
        for _ in 0..<40 { let b = block(); _ = c.run(b, b); usleep(5333) }   // warm up
        hs_engine_denoiser_test_pause(c.e, 1)
        for _ in 0..<200 { let b = block(); _ = c.run(b, b) }                  // ~1 s stall, ring overflows
        hs_engine_denoiser_test_pause(c.e, 0)
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        let underAfterStall = t.dnUnderflows
        var tail: [Float] = [], inp: [Float] = []
        for k in 0..<300 {
            let b = block(); let o = c.run(b, b).0
            if k >= 200 { tail += o; inp += b }
            usleep(5333)
        }
        hs_engine_read_telemetry(c.e, &t)
        XCTAssertLessThan(t.dnUnderflows - underAfterStall, 60, "underflows must stop after the stall")
        XCTAssertLessThan(20 * log10(rms(tail[...]) / rms(inp[...])), -10, "noise reduction must come back")
        hs_engine_denoiser_unload(c.e, 0)
    }

    /// Enabling must not ramp onto the zero prefill (no gap, no hard start).
    func testEnableHasNoGapOrHardStart() {
        let c = Chain("off")
        c.set(Int32(HS_P_DENOISE_DB), 1)
        XCTAssertEqual(hs_engine_denoiser_load(c.e, model, 1, 256), 0)
        let x = (0..<48000).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<(48000 / 256) {
            if k == 20 { c.set(Int32(HS_P_DENOISE_ON), 1) }
            out += c.run(Array(x[(k * 256)..<((k + 1) * 256)]), Array(x[(k * 256)..<((k + 1) * 256)])).0
        }
        let steps = zip(out.dropFirst(), out).map { abs($0 - $1) }
        XCTAssertLessThan(steps.max()!, 0.06, "hard start / discontinuity")
        // no window of ≥ 10 ms silence after enabling
        for i in stride(from: 6000, to: out.count - 480, by: 240) {
            XCTAssertGreaterThan(rms(out[i..<(i + 480)]), 0.05, "gap at \(i)")
        }
        hs_engine_denoiser_unload(c.e, 1)
    }

    /// A libDF error latches onto the delayed fallback (no time jump, no silence) and is reported.
    func testLibDFFailureLatchesToDelayedFallback() {
        let c = engine(sync: true, atten: 1)
        let x = (0..<48000).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<(48000 / 256) {
            if k == 60 { hs_engine_denoiser_test_fail(c.e) }
            out += c.run(Array(x[(k * 256)..<((k + 1) * 256)]), Array(x[(k * 256)..<((k + 1) * 256)])).0
        }
        var t = hs_telemetry(); hs_engine_read_telemetry(c.e, &t)
        XCTAssertEqual(t.dnFailed, 1)
        XCTAssertGreaterThanOrEqual(t.dnNaN, 1)
        let lat = Int(hs_engine_latency_samples(c.e))
        for i in 40000..<out.count { XCTAssertEqual(out[i], x[i - lat], accuracy: 1e-4) }   // delayed fallback, aligned
        XCTAssertLessThan(zip(out.dropFirst(), out).map { abs($0 - $1) }.max()!, 0.06)
        hs_engine_denoiser_unload(c.e, 1)
    }

    /// A/B "Original" with the denoiser mixed in: aligned to the full latency (≈ 2968 samples).
    func testABOriginalAlignedWithDenoiser() {
        let c = engine(sync: true, atten: 12)
        let x = (0..<96000).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<(96000 / 256) {
            if k == 200 { c.set(Int32(HS_P_AB_ORIGINAL), 1) }
            out += c.run(Array(x[(k * 256)..<((k + 1) * 256)]), Array(x[(k * 256)..<((k + 1) * 256)])).0
        }
        let lat = Int(hs_engine_latency_samples(c.e))
        XCTAssertEqual(lat, 2968)
        for i in (out.count - 4800)..<out.count { XCTAssertEqual(out[i], x[i - lat], accuracy: 1e-5) }
        XCTAssertLessThan(zip(out[2000...].dropFirst(), out[2000...]).map { abs($0 - $1) }.max()!, 0.06)
        hs_engine_denoiser_unload(c.e, 1)
    }
}

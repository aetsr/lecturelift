import Foundation
import HSCore
import XCTest

final class IRGeneratorTests: XCTestCase {
    func ir(_ room: Int32, damping: Float = 0.5, fs: Double = 48000, seed: UInt64 = 42) -> ([Float], [Float]) {
        let n = Int(hs_ir_length(room, fs))
        var l = [Float](repeating: 0, count: n), r = l
        XCTAssertEqual(Int(hs_ir_generate(room, damping, fs, seed, &l, &r, Int32(n))), n)
        return (l, r)
    }

    /// Octave-band filter (two HP + two LP Butterworth sections) for the T30 measurement.
    func octave(_ x: [Float], fc: Double, fs: Double) -> [Double] {
        var y = x.map(Double.init)
        func run(_ type: Int32, _ f: Double) {
            let c = design(type, fs, f, 1 / 2.0.squareRoot(), 0)
            var z1 = 0.0, z2 = 0.0
            for i in 0..<y.count { let a = y[i]; let o = c[0] * a + z1; z1 = c[1] * a - c[3] * o + z2; z2 = c[2] * a - c[4] * o; y[i] = o }
        }
        run(1, fc / 2.0.squareRoot()); run(1, fc / 2.0.squareRoot()); run(0, fc * 2.0.squareRoot()); run(0, fc * 2.0.squareRoot())
        return y
    }

    /// Schroeder backward integration, T30 from a linear fit between −5 and −35 dB.
    func t30(_ h: [Double], fs: Double) -> Double {
        var edc = [Double](repeating: 0, count: h.count)
        var acc = 0.0
        for i in stride(from: h.count - 1, through: 0, by: -1) { acc += h[i] * h[i]; edc[i] = acc }
        let db = edc.map { 10 * log10(max($0, 1e-300) / edc[0]) }
        guard let i5 = db.firstIndex(where: { $0 <= -5 }), let i35 = db.firstIndex(where: { $0 <= -35 }), i35 > i5 + 10 else { return .nan }
        var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
        let m = Double(i35 - i5)
        for i in i5..<i35 { let x = Double(i) / fs; sx += x; sy += db[i]; sxx += x * x; sxy += x * db[i] }
        let slope = (m * sxy - sx * sy) / (m * sxx - sx * sx)   // dB/s
        return -60 / slope
    }

    func testRT60WithinTenPercentPerPresetAndRate() {
        for fs in [48000.0, 44100.0] {
            for room in Int32(0)...2 {
                let target = Double(hs_ir_target_rt60(room))
                let (l, r) = ir(room, fs: fs)
                for (name, ch) in [("L", l), ("R", r)] {
                    // mid-frequency reverberation time (500 Hz and 1 kHz octaves), as in ISO 3382
                    let t = (t30(octave(ch, fc: 500, fs: fs), fs: fs) + t30(octave(ch, fc: 1000, fs: fs), fs: fs)) / 2
                    XCTAssertEqual(t, target, accuracy: 0.10 * target, "room \(room) \(name) @\(Int(fs)): T30 \(t)")
                }
            }
        }
    }

    func testDampingShortensHighFrequencies() {
        let (l, _) = ir(1, damping: 1.0)
        let mid = t30(octave(l, fc: 1000, fs: 48000), fs: 48000)
        let high = t30(octave(l, fc: 8000, fs: 48000), fs: 48000)
        XCTAssertLessThan(high, 0.6 * mid)
        let (l0, _) = ir(1, damping: 0)
        XCTAssertEqual(t30(octave(l0, fc: 8000, fs: 48000), fs: 48000), t30(octave(l0, fc: 1000, fs: 48000), fs: 48000), accuracy: 0.15)
    }

    func testDeterministicUnitEnergyDecorrelated() {
        let (a, b) = ir(1), (c, _) = ir(1)
        XCTAssertEqual(a, c, "same seed must give the same IR")
        let energy = (a.reduce(0) { $0 + Double($1 * $1) } + b.reduce(0) { $0 + Double($1 * $1) }) / 2
        XCTAssertEqual(energy, 1, accuracy: 1e-3)
        // late-tail L/R correlation (after 100 ms) must be low → width
        let s = 4800
        var xy = 0.0, xx = 0.0, yy = 0.0
        for i in s..<a.count { xy += Double(a[i] * b[i]); xx += Double(a[i] * a[i]); yy += Double(b[i] * b[i]) }
        XCTAssertLessThan(abs(xy / (xx * yy).squareRoot()), 0.2)
    }

    func testNoDirectSoundAndEarlyReflectionsFirst() {
        let (l, _) = ir(1)
        XCTAssertEqual(l[0], 0)                       // time zero = direct arrival, direct excluded
        let firstIdx = l.firstIndex { abs($0) > 1e-4 }!
        XCTAssertGreaterThan(firstIdx, 24)           // first reflection arrives after the direct path
        XCTAssertLessThan(firstIdx, 48000 / 20)      // …within 50 ms in a 20 m hall
    }
}

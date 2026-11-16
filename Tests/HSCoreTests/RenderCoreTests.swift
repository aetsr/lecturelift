import CoreAudio
import HSCore
import XCTest

/// Drives hs_ioproc with synthetic AudioBufferLists, exactly as the HAL would.
final class RenderCoreTests: XCTestCase {
    final class Harness {
        let engine: OpaquePointer
        let inData: UnsafeMutablePointer<Float>
        let outData: [UnsafeMutablePointer<Float>]
        let inList: UnsafeMutableAudioBufferListPointer
        let outList: UnsafeMutableAudioBufferListPointer
        let frames: Int
        var sampleTime: Double = 0

        init(frames: Int, inChannels: Int = 2, outChannels: [Int] = [2], map: [Int8], startOpen: Bool = true) {
            self.frames = frames
            engine = hs_engine_create()!
            hs_engine_prepare(engine, 48000, 4096)
            hs_engine_set_input(engine, 0, Int32(inChannels), 1)
            hs_engine_set_output_map(engine, Int32(outChannels.count), outChannels.map { Int32($0) },
                                     outChannels.map { _ in Int32(1) }, map)
            hs_engine_reset_fade(engine, startOpen ? 1 : 0)
            inData = .allocate(capacity: frames * inChannels)
            inList = AudioBufferList.allocate(maximumBuffers: 1)
            inList[0] = AudioBuffer(mNumberChannels: UInt32(inChannels), mDataByteSize: UInt32(frames * inChannels * 4), mData: inData)
            outList = AudioBufferList.allocate(maximumBuffers: outChannels.count)
            outData = outChannels.map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames * 8) }
            for (i, ch) in outChannels.enumerated() {
                outList[i] = AudioBuffer(mNumberChannels: UInt32(ch), mDataByteSize: UInt32(frames * ch * 4), mData: outData[i])
            }
        }

        func run(advance: Double? = nil) {
            var ts = AudioTimeStamp()
            ts.mSampleTime = sampleTime
            ts.mFlags = .sampleTimeValid
            var zero = AudioTimeStamp()
            _ = hs_ioproc(0, &zero, inList.unsafePointer, &zero, outList.unsafeMutablePointer, &ts, UnsafeMutableRawPointer(engine))
            sampleTime += advance ?? Double(frames)
        }

        deinit { hs_engine_destroy(engine) }
    }

    func testPassthroughIsBitIdentical() {
        let h = Harness(frames: 256, map: [Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        var rng = SystemRandomNumberGenerator()
        for block in 0..<20 {
            for i in 0..<512 { h.inData[i] = Float.random(in: -1...1, using: &rng) }
            h.run()
            for i in 0..<512 { XCTAssertEqual(h.outData[0][i].bitPattern, h.inData[i].bitPattern, "block \(block) sample \(i)") }
        }
    }

    func testMonoOutputGetsSum() {
        let h = Harness(frames: 64, outChannels: [1], map: [Int8(HS_SRC_MONO)])
        for i in 0..<64 { h.inData[2 * i] = 0.5; h.inData[2 * i + 1] = 0.25 }
        h.run()
        for i in 0..<64 { XCTAssertEqual(h.outData[0][i], 0.375, accuracy: 1e-7) }
    }

    func testUnmappedChannelsAreSilent() {
        // 4-channel interface, preferred stereo pair = channels 3/4.
        let h = Harness(frames: 32, outChannels: [4], map: [Int8(HS_SRC_ZERO), Int8(HS_SRC_ZERO), Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        for i in 0..<64 { h.inData[i] = 0.7 }
        for i in 0..<128 { h.outData[0][i] = 9 }
        h.run()
        for f in 0..<32 {
            XCTAssertEqual(h.outData[0][f * 4 + 0], 0); XCTAssertEqual(h.outData[0][f * 4 + 1], 0)
            XCTAssertEqual(h.outData[0][f * 4 + 2], 0.7); XCTAssertEqual(h.outData[0][f * 4 + 3], 0.7)
        }
    }

    func testFadeInStartsSilentAndReachesUnity() {
        let h = Harness(frames: 256, map: [Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)], startOpen: false)
        for i in 0..<512 { h.inData[i] = 1 }
        h.run()
        XCTAssertLessThan(h.outData[0][0], 0.01)
        for _ in 0..<5 { h.run() }   // 6 × 256 = 1536 samples > 960 (20 ms)
        XCTAssertEqual(h.outData[0][510], 1, accuracy: 1e-6)
        var t = hs_telemetry(); hs_engine_read_telemetry(h.engine, &t)
        XCTAssertEqual(t.fadeState, Int32(HS_FADE_OPEN))
    }

    func testFadeOutReachesSilence() {
        let h = Harness(frames: 256, map: [Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        for i in 0..<512 { h.inData[i] = 1 }
        hs_engine_set_fade_target(h.engine, 0)
        for _ in 0..<5 { h.run() }
        XCTAssertEqual(h.outData[0][510], 0)
        var t = hs_telemetry(); hs_engine_read_telemetry(h.engine, &t)
        XCTAssertEqual(t.fadeState, Int32(HS_FADE_SILENT))
    }

    func testXrunCountsSampleTimeDiscontinuity() {
        let h = Harness(frames: 128, map: [Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        h.run(); h.run()
        h.run(advance: 384)   // next block skips 256 frames
        h.run()
        var t = hs_telemetry(); hs_engine_read_telemetry(h.engine, &t)
        XCTAssertEqual(t.xruns, 1)
        XCTAssertEqual(t.callbacks, 4)
    }

    func testZeroInputDoesNotCountAsNonzero() {
        let h = Harness(frames: 64, map: [Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        for i in 0..<128 { h.inData[i] = 0 }
        h.run(); h.run()
        var t = hs_telemetry(); hs_engine_read_telemetry(h.engine, &t)
        XCTAssertEqual(t.nonzeroBlocks, 0)
        h.inData[5] = 1e-6
        h.run()
        hs_engine_read_telemetry(h.engine, &t)
        XCTAssertEqual(t.nonzeroBlocks, 1)
    }
}

final class RenderCoreBufferTests: XCTestCase {
    /// A NULL output buffer must not shift the channel map of the buffers after it.
    func testNullBufferKeepsChannelOffsets() {
        let engine = hs_engine_create()!
        defer { hs_engine_destroy(engine) }
        hs_engine_prepare(engine, 48000, 1024)
        hs_engine_set_input(engine, 0, 2, 1)
        hs_engine_set_output_map(engine, 2, [2, 2], [1, 1], [Int8(HS_SRC_ZERO), Int8(HS_SRC_ZERO), Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        hs_engine_reset_fade(engine, 1)
        let n = 16
        let inData = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n); defer { inData.deallocate() }
        for i in 0..<n { inData[2 * i] = 0.25; inData[2 * i + 1] = -0.5 }
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        inList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(8 * n), mData: inData)
        let out1 = UnsafeMutablePointer<Float>.allocate(capacity: 2 * n); defer { out1.deallocate() }
        let outList = AudioBufferList.allocate(maximumBuffers: 2)
        outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(8 * n), mData: nil)   // NULL buffer
        outList[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(8 * n), mData: out1)
        var ts = AudioTimeStamp()
        // Frame count comes from buffer 0's byte size even if its data is NULL.
        _ = hs_ioproc(0, &ts, inList.unsafePointer, &ts, outList.unsafeMutablePointer, &ts, UnsafeMutableRawPointer(engine))
        XCTAssertEqual(out1[0], 0.25); XCTAssertEqual(out1[1], -0.5)
    }
}

final class CaptureTests: XCTestCase {
    func testCaptureRecordsRawInputAndReleasesSafely() {
        let h = RenderCoreTests.Harness(frames: 256, map: [Int8(HS_SRC_LEFT), Int8(HS_SRC_RIGHT)])
        hs_engine_apply_preset(h.engine, "clarity")          // chain active: capture must still be RAW input
        XCTAssertEqual(hs_engine_capture_start(h.engine, 0.01), 0)   // 480 frames
        XCTAssertEqual(hs_engine_capture_start(h.engine, 0.01), -1, "only one capture at a time")
        var expected: [Float] = []
        var g = Noise(s: 99)
        for _ in 0..<3 {
            for i in 0..<512 { h.inData[i] = g.next() * 0.5 }
            expected += (0..<512).map { h.inData[$0] }
            h.run()
        }
        var cap: Int64 = 0
        XCTAssertEqual(hs_engine_capture_progress(h.engine, &cap), 480)
        XCTAssertEqual(cap, 480)
        XCTAssertEqual(hs_engine_capture_detach(h.engine), 480)
        var dst = [Float](repeating: 0, count: 960)
        XCTAssertEqual(hs_engine_capture_copy(h.engine, &dst, 480), 480)
        XCTAssertEqual(dst.map(\.bitPattern), Array(expected[0..<960]).map(\.bitPattern))
        XCTAssertEqual(hs_engine_capture_release(h.engine, 0), 0, "IOProc may still hold the pointer")
        h.run(); h.run()
        XCTAssertEqual(hs_engine_capture_release(h.engine, 0), 1)
        XCTAssertEqual(hs_engine_capture_start(h.engine, 0.01), 0, "a new capture can start after release")
    }
}

final class ABTests: XCTestCase {
    /// "Original" must be the chain input delayed by the reported latency (time-aligned), and the
    /// switch must be click-free.
    func testOriginalIsTimeAlignedAndSwitchIsClickFree() {
        let c = Chain("clarity")
        let n = 48000
        let x = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 48000)) }
        var out: [Float] = []
        for k in 0..<(n / 480) {
            if k == 40 { c.set(Int32(HS_P_AB_ORIGINAL), 1) }
            out += c.run(Array(x[(k * 480)..<((k + 1) * 480)]), Array(x[(k * 480)..<((k + 1) * 480)])).0
        }
        let lat = Int(hs_engine_latency_samples(c.e))
        for i in (n - 4800)..<n { XCTAssertEqual(out[i], x[i - lat], accuracy: 1e-5) }
        let maxStep = zip(out[1000...].dropFirst(), out[1000...]).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(maxStep, 0.05)   // 220 Hz at 0.3 changes ≤ 0.009/sample; leveler gain may differ
    }

    func testABOffIsBitIdenticalForAus() {
        var g = Noise(s: 4)
        let x = (0..<10000).map { _ in g.next() }
        XCTAssertEqual(Chain("off").run(x, x).0.map(\.bitPattern), x.map(\.bitPattern))
    }
}

import AVFoundation
import HSCore

/// BS.1770-4 integrated loudness (K-weighting designed for the file's rate, 400 ms blocks with
/// 75 % overlap, absolute −70 / relative −10 LU gates) and loudness normalisation.
enum Measure {
    struct Result { let lufs: Double; let peakDb: Double; let seconds: Double }

    static func read(_ url: URL) throws -> (chans: [[Float]], rate: Double) {
        let f = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        let chans = (0..<Int(f.processingFormat.channelCount)).map {
            Array(UnsafeBufferPointer(start: buf.floatChannelData![$0], count: Int(buf.frameLength)))
        }
        return (chans, f.processingFormat.sampleRate)
    }

    static func peak(_ chans: [[Float]]) -> Float { chans.map { $0.map(abs).max() ?? 0 }.max() ?? 0 }

    static func file(_ url: URL) throws -> Result {
        let (chans, rate) = try read(url)
        return Result(lufs: integrated(chans, rate: rate), peakDb: 20 * log10(max(Double(peak(chans)), 1e-12)),
                      seconds: Double(chans.first?.count ?? 0) / rate)
    }

    /// Scales `input` to `targetLufs` integrated and writes a 32-bit float stereo WAV.
    /// Returns (gain dB, resulting peak dBFS). No limiting: listening files must stay unaltered in sound.
    static func normalize(_ input: URL, to output: URL, targetLufs: Double) throws -> (gainDb: Double, peakDb: Double) {
        let (chans, rate) = try read(input)
        let stereo = chans.count >= 2 ? Array(chans[0..<2]) : [chans[0], chans[0]]
        let gainDb = targetLufs - integrated(stereo, rate: rate)
        let g = Float(pow(10, gainDb / 20))
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let n = stereo[0].count
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<2 { for i in 0..<n { buf.floatChannelData![c][i] = stereo[c][i] * g } }
        var out: AVAudioFile? = try AVAudioFile(forWriting: output, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
        try out?.write(from: buf)
        out = nil   // finalise the header
        return (gainDb, 20 * log10(max(Double(peak(stereo)) * Double(g), 1e-12)))
    }

    static func integrated(_ chans: [[Float]], rate: Double) -> Double {
        var s = [Double](repeating: 0, count: 5), r = s
        hs_design_kweighting(rate, &s, &r)
        let k: [[Double]] = chans.map { x in
            var y = [Double](repeating: 0, count: x.count)
            var s1 = 0.0, s2 = 0.0, t1 = 0.0, t2 = 0.0
            for i in 0..<x.count {
                let a = Double(x[i]); let o = s[0] * a + s1; s1 = s[1] * a - s[3] * o + s2; s2 = s[2] * a - s[4] * o
                let p = r[0] * o + t1; t1 = r[1] * o - r[3] * p + t2; t2 = r[2] * o - r[4] * p
                y[i] = p
            }
            return y
        }
        let len = k.first?.count ?? 0, block = Int(0.4 * rate), hop = block / 4
        var energies: [Double] = []
        var i = 0
        while i + block <= len {
            var e = 0.0
            for c in k { for j in i..<(i + block) { e += c[j] * c[j] } }
            energies.append(e / Double(block)); i += hop
        }
        func lufs(_ e: Double) -> Double { -0.691 + 10 * log10(max(e, 1e-30)) }
        let abs = energies.filter { lufs($0) > -70 }
        guard !abs.isEmpty else { return -.infinity }
        let rel = lufs(abs.reduce(0, +) / Double(abs.count)) - 10
        let gated = abs.filter { lufs($0) > rel }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

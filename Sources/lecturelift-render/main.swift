// lecturelift-render — runs the exact HSCore chain offline on a file.
// Usage: lecturelift-render in.wav out.wav [--preset NAME] [--block N] [--bench]
//        lecturelift-render --measure a.wav [b.wav …]           (BS.1770 integrated loudness + peak)
//        lecturelift-render --normalize LUFS in.wav out.wav     (loudness-match, no limiting)
//        lecturelift-render --impulse [--preset NAME]      (prints algorithmic latency, measured)
import AVFoundation
import Foundation
import HSCore

func fail(_ msg: String) -> Never { FileHandle.standardError.write((msg + "\n").data(using: .utf8)!); exit(1) }

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
let preset = option("--preset") ?? "hall"
let block = Int(option("--block") ?? "512") ?? 512
let impulse = args.contains("--impulse"); args.removeAll { $0 == "--impulse" }
let bench = args.contains("--bench"); args.removeAll { $0 == "--bench" }
let denoiseDb = option("--denoise").flatMap(Float.init)
let wetOverride = option("--wet").flatMap(Float.init)            // reverb mix 0…0.4 (after the preset)
let predelayOverride = option("--predelay").flatMap(Float.init)  // ms
// --set NAME=VALUE (repeatable), applied after the preset: experiments without touching the chain code
let paramNames: [String: Int32] = [
    "mono": Int32(HS_P_MONO), "hpf": Int32(HS_P_HPF_ON), "eq": Int32(HS_P_EQ_ON), "deess": Int32(HS_P_DEESS_ON),
    "level": Int32(HS_P_LEVEL_ON), "limit": Int32(HS_P_LIMIT_ON), "reverb": Int32(HS_P_REVERB_ON),
    "debox": Int32(HS_P_DEBOX_DB), "presence": Int32(HS_P_PRESENCE_DB), "deessmax": Int32(HS_P_DEESS_MAX_DB),
    "target": Int32(HS_P_TARGET_LUFS), "room": Int32(HS_P_ROOM), "wet": Int32(HS_P_WET), "predelay": Int32(HS_P_PREDELAY_MS),
    "damping": Int32(HS_P_DAMPING), "distance": Int32(HS_P_DISTANCE),
    "levelstrength": Int32(HS_P_LEVEL_STRENGTH), "denoisedb": Int32(HS_P_DENOISE_DB),
]
var paramSets: [(Int32, Float)] = []
while let kv = option("--set") {
    let parts = kv.split(separator: "=").map(String.init)
    guard parts.count == 2, let id = paramNames[parts[0]], let v = Float(parts[1]) else { fail("bad --set \(kv); names: \(paramNames.keys.sorted())") }
    paramSets.append((id, v))
}   // Qualität: DeepFilterNet3 with this attenuation limit
let stageNames = ["mono", "denoise", "hpf", "eq", "deesser", "leveler", "reverb", "limiter"]

if args.first == "--measure" {
    for path in args.dropFirst() {
        do {
            let r = try Measure.file(URL(fileURLWithPath: path))
            print(String(format: "%@: %.2f LUFS, peak %.2f dBFS, %.1f s", (path as NSString).lastPathComponent, r.lufs, r.peakDb, r.seconds))
        } catch { fail("\(path): \(error)") }
    }
    exit(0)
}

if args.first == "--normalize" {
    guard args.count == 4, let target = Double(args[1]) else { fail("usage: lecturelift-render --normalize LUFS in.wav out.wav") }
    do {
        let r = try Measure.normalize(URL(fileURLWithPath: args[2]), to: URL(fileURLWithPath: args[3]), targetLufs: target)
        print(String(format: "%@ → %@: gain %+.2f dB, peak %.2f dBFS%@", (args[2] as NSString).lastPathComponent,
                     (args[3] as NSString).lastPathComponent, r.gainDb, r.peakDb, r.peakDb > -0.1 ? "  WARNING: clips" : ""))
    } catch { fail("normalize: \(error)") }
    exit(0)
}

guard let engine = hs_engine_create() else { fail("engine") }
defer { hs_engine_destroy(engine) }
func applyPreset() {
    if hs_engine_apply_preset(engine, preset) != 0 { fail("unknown preset \(preset)") }
    if let w = wetOverride { hs_engine_set_param(engine, Int32(HS_P_WET), w) }
    if let p = predelayOverride { hs_engine_set_param(engine, Int32(HS_P_PREDELAY_MS), p) }
    for (id, v) in paramSets { hs_engine_set_param(engine, id, v) }
    if hs_engine_rebuild_reverb(engine, 42) < 0 { fail("reverb build failed") }
    if let db = denoiseDb {
        let env = ProcessInfo.processInfo.environment
        let lib = env["LECTURELIFT_LIBDF"] ?? "vendor/libdf/lib/libdf.dylib"
        let model = env["LECTURELIFT_DFN_MODEL"] ?? "vendor/libdf/models/DeepFilterNet3_onnx.tar.gz"
        if hs_denoiser_library_load(lib) != 0 { fail("cannot load \(lib) (run scripts/build_libdf.sh)") }
        hs_engine_set_param(engine, Int32(HS_P_DENOISE_DB), db)
        // synchronous (deterministic) with the latency structure of a live 256-frame session
        let r = hs_engine_denoiser_load(engine, model, 1, 256)
        if r != 0 { fail("denoiser load failed: \(r)") }
        hs_engine_set_param(engine, Int32(HS_P_DENOISE_ON), 1)
    }
}

if impulse {
    let sr = 48000.0, n = 48000
    hs_engine_prepare(engine, sr, Int32(n))
    applyPreset()
    // Bring every enabled stage to fully-on before the impulse (bypass crossfades start at 0).
    var warm = [Float](repeating: 0, count: n), warmR = warm
    hs_engine_process_planar(engine, &warm, &warmR, Int32(n))
    var l = [Float](repeating: 0, count: n), r = l
    l[0] = 1; r[0] = 1
    hs_engine_process_planar(engine, &l, &r, Int32(n))
    let peak = l.indices.max { abs(l[$0]) < abs(l[$1]) } ?? 0
    print("preset=\(preset) reported_latency=\(hs_engine_latency_samples(engine)) measured_peak_at=\(peak) samples (\(Double(peak) / sr * 1000) ms)")
    exit(0)
}

guard args.count == 2 else { fail("usage: lecturelift-render in.wav out.wav [--preset NAME] [--block N] | --impulse") }
let inURL = URL(fileURLWithPath: args[0]), outURL = URL(fileURLWithPath: args[1])
let inFile: AVAudioFile
do { inFile = try AVAudioFile(forReading: inURL, commonFormat: .pcmFormatFloat32, interleaved: false) } catch { fail("read: \(error)") }
let fmt = inFile.processingFormat
guard let stereo = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 2) else { fail("format") }
var outFile: AVAudioFile!
do { outFile = try AVAudioFile(forWriting: outURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                                              AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true],
                                commonFormat: .pcmFormatFloat32, interleaved: false) } catch { fail("write: \(error)") }

hs_engine_prepare(engine, fmt.sampleRate, Int32(block))
applyPreset()
let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(block))!
let outBuf = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: AVAudioFrameCount(block))!
var total = 0
let t0 = Date()
var renderNs: UInt64 = 0
while inFile.framePosition < inFile.length {
    let want = AVAudioFrameCount(min(Int64(block), inFile.length - inFile.framePosition))
    do { try inFile.read(into: inBuf, frameCount: want) } catch { fail("read at \(inFile.framePosition): \(error)") }
    let n = Int(inBuf.frameLength)
    if n == 0 { break }
    let l = outBuf.floatChannelData![0], r = outBuf.floatChannelData![1]
    let src = inBuf.floatChannelData!
    for i in 0..<n { l[i] = src[0][i]; r[i] = fmt.channelCount > 1 ? src[1][i] : src[0][i] }
    let a = DispatchTime.now().uptimeNanoseconds
    hs_engine_process_planar(engine, l, r, Int32(n))
    renderNs += DispatchTime.now().uptimeNanoseconds - a
    outBuf.frameLength = AVAudioFrameCount(n)
    do { try outFile.write(from: outBuf) } catch { fail("write: \(error)") }
    total += n
}
outFile = nil   // releases the file → header sizes are finalised
let audioSec = Double(total) / fmt.sampleRate
if bench {
    func pad(_ x: String) -> String { x.padding(toLength: 9, withPad: " ", startingAt: 0) }
    print("\(pad("stage"))        RTF      CPU%")
    var sum = 0.0
    for (i, name) in stageNames.enumerated() {
        let rtf = Double(hs_engine_stage_ns(engine, Int32(i))) / 1e9 / max(audioSec, 1e-9)
        sum += rtf
        print(pad(name) + String(format: " %10.6f %8.3f%%", rtf, rtf * 100))
    }
    print(pad("total") + String(format: " %10.6f %8.3f%%  (chain total, single core)", sum, sum * 100))
}
print(String(format: "rendered %.2f s (%@ → %@), preset=%@, RTF=%.5f, wall %.2f s",
             audioSec, inURL.lastPathComponent, outURL.lastPathComponent, preset, Double(renderNs) / 1e9 / max(audioSec, 1e-9),
             Date().timeIntervalSince(t0)))

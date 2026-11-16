// M1 verification tool: does macOS release a mutedWhenTapped tap when the owning process is SIGKILLed?
// Modes:
//   play   <freq> <seconds>        tone to the built-in speakers (separate process = the tap target)
//   tap    <pid> <private:0|1>    mute-tap <pid> into an aggregate on the built-in speakers, output zeros, run forever
//   listen <freq> <seconds>        built-in mic, Goertzel level of <freq> every 0.5 s (dBFS)
//   list                           taps + aggregate devices visible to THIS process
//   sweep                          try to destroy every visible tap/aggregate whose name/UID starts with "lecturelift-killtest"
import AudioToolbox
import CoreAudio
import Foundation

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = def; var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
    return st == noErr ? v : def
}
func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
    var out = [AudioObjectID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out)
    return out
}
func str(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &s) == noErr, let v = s else { return "?" }
    return v.takeRetainedValue() as String
}
func streams(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size)
    return Int(size) / 4
}
func builtin(_ scope: AudioObjectPropertyScope) -> AudioObjectID {
    for d in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
        let t: UInt32 = prop(d, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, 0)
        if t == kAudioDeviceTransportTypeBuiltIn && streams(d, scope) > 0 { return d }
    }
    fatalError("no built-in device for scope")
}
func check(_ st: OSStatus, _ what: String) { if st != noErr { print("FAIL \(what): \(st)"); exit(2) } }
let args = CommandLine.arguments
setvbuf(stdout, nil, _IOLBF, 0)

switch args.count > 1 ? args[1] : "" {
case "play":
    let freq = Double(args[2])!, secs = Double(args[3])!
    let useDefault = args.count > 4 && args[4] == "default"
    let dev = useDefault ? prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) : builtin(kAudioObjectPropertyScopeOutput)
    let sr: Double = prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 48000)
    var phase = 0.0
    // (Re)starts playback on the current device; re-run after a coreaudiod restart so the same
    // process (same PID) keeps playing — needed by the coreaudiod live test.
    func startPlayback() {
        let d = useDefault ? prop(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) : builtin(kAudioObjectPropertyScopeOutput)
        var proc: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&proc, d, nil) { _, _, _, out, _ in
            let abl = UnsafeMutableAudioBufferListPointer(out)
            let ch = Int(abl[0].mNumberChannels), n = Int(abl[0].mDataByteSize) / 4 / max(ch, 1)
            let p = abl[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<n { let v = Float(0.05 * sin(phase)); phase += 2 * .pi * freq / sr; for c in 0..<ch { p[i * ch + c] = v } }
            for b in 1..<abl.count { memset(abl[b].mData, 0, Int(abl[b].mDataByteSize)) }
        }
        print("PLAY pid=\(getpid()) dev=\(d) sr=\(sr) ioproc=\(st) start=\(st == noErr ? AudioDeviceStart(d, proc) : -1)")
    }
    _ = dev
    startPlayback()
    var restartAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyServiceRestarted, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &restartAddr, DispatchQueue.main) { _, _ in
        print("coreaudiod restarted: restarting playback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { startPlayback() }
    }
    RunLoop.main.run(until: Date().addingTimeInterval(secs))
case "tap":
    let pid = pid_t(args[2])!, priv = args[3] == "1"
    var p = pid; var obj: AudioObjectID = 0; var size = UInt32(4)
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &p, &size, &obj), "pid->obj")
    let desc = CATapDescription(stereoMixdownOfProcesses: [obj])
    desc.name = "lecturelift-killtest-tap"; desc.isPrivate = priv; desc.muteBehavior = .mutedWhenTapped
    var tap: AudioObjectID = 0
    check(AudioHardwareCreateProcessTap(desc, &tap), "create tap")
    let out = builtin(kAudioObjectPropertyScopeOutput)
    let outUID = str(out, kAudioDevicePropertyDeviceUID)
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceNameKey: "lecturelift-killtest-agg", kAudioAggregateDeviceUIDKey: "lecturelift-killtest-agg-\(UUID().uuidString)",
        kAudioAggregateDeviceMainSubDeviceKey: outUID, kAudioAggregateDeviceIsPrivateKey: priv, kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
    ]
    var agg: AudioObjectID = 0
    check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg), "create agg")
    var proc: AudioDeviceIOProcID?
    var nonzero = 0
    check(AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inp, _, outp, _ in
        let i = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
        if let d = i.first?.mData { let f = d.assumingMemoryBound(to: Float.self); if f[0] != 0 || f[7] != 0 { nonzero += 1 } }
        for b in UnsafeMutableAudioBufferListPointer(outp) { memset(b.mData, 0, Int(b.mDataByteSize)) }
    }, "ioproc")
    check(AudioDeviceStart(agg, proc), "start")
    print("TAP pid=\(getpid()) private=\(priv) tap=\(tap) agg=\(agg)")
    while true { Thread.sleep(forTimeInterval: 1); print("tap alive, nonzero input blocks so far: \(nonzero)") }
case "listen":
    let freq = Double(args[2])!, secs = Double(args[3])!
    let dev = builtin(kAudioObjectPropertyScopeInput)
    let sr: Double = prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, 48000)
    let w = 2 * cos(2 * .pi * freq / sr)
    var s1 = 0.0, s2 = 0.0, n = 0
    let lock = NSLock()
    var proc: AudioDeviceIOProcID?
    check(AudioDeviceCreateIOProcIDWithBlock(&proc, dev, nil) { _, inp, _, _, _ in
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
        guard let d = abl.first?.mData else { return }
        let ch = Int(abl[0].mNumberChannels), cnt = Int(abl[0].mDataByteSize) / 4 / max(ch, 1)
        let f = d.assumingMemoryBound(to: Float.self)
        lock.lock(); for k in 0..<cnt { let s0 = Double(f[k * ch]) + w * s1 - s2; s2 = s1; s1 = s0 }; n += cnt; lock.unlock()
    }, "ioproc")
    check(AudioDeviceStart(dev, proc), "start")
    let t0 = Date()
    while Date().timeIntervalSince(t0) < secs {
        Thread.sleep(forTimeInterval: 0.5)
        lock.lock(); let p = s1 * s1 + s2 * s2 - w * s1 * s2; let m = n; s1 = 0; s2 = 0; n = 0; lock.unlock()
        let amp = m > 0 ? 2 * sqrt(max(p, 0)) / Double(m) : 0
        print(String(format: "t=%5.1f  %4.0f Hz level %6.1f dBFS", Date().timeIntervalSince(t0), freq, 20 * log10(amp + 1e-12)))
    }
case "list", "sweep":
    let sys = AudioObjectID(kAudioObjectSystemObject)
    for t in ids(sys, kAudioHardwarePropertyTapList) {
        let uid = str(t, kAudioTapPropertyUID)
        print("TAP id=\(t) uid=\(uid)")
        if args[1] == "sweep" { print("  destroy ->", AudioHardwareDestroyProcessTap(t)) }
    }
    for d in ids(sys, kAudioHardwarePropertyDevices) {
        let name = str(d, kAudioObjectPropertyName), uid = str(d, kAudioDevicePropertyDeviceUID)
        let isAgg = prop(d, kAudioObjectPropertyClass, kAudioObjectPropertyScopeGlobal, AudioClassID(0)) == kAudioAggregateDeviceClassID
        if isAgg || name.hasPrefix("hall") { print("AGG id=\(d) name=\(name) uid=\(uid)")
            if args[1] == "sweep" && name.hasPrefix("lecturelift-killtest") { print("  destroy ->", AudioHardwareDestroyAggregateDevice(d)) } }
    }
case "procs":
    typealias RespFn = @convention(c) (pid_t) -> pid_t
    let resp: RespFn? = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid").map { unsafeBitCast($0, to: RespFn.self) }
    for o in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
        let pid: pid_t = prop(o, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, -1)
        let run: UInt32 = prop(o, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, 0)
        let r = resp?(pid) ?? -1
        var rname = ""
        if r > 0 { var buf = [CChar](repeating: 0, count: 1024); proc_pidpath(r, &buf, 1024); rname = String(cString: buf).components(separatedBy: "/").last ?? "" }
        print("obj=\(o) pid=\(pid) out=\(run) bid=\(str(o, kAudioProcessPropertyBundleID)) resp=\(r) \(rname)")
    }
case "bundletap":
    if #available(macOS 26.0, *) {
        let desc = CATapDescription(stereoMixdownOfProcesses: [])
        desc.bundleIDs = [args[2]]; desc.isProcessRestoreEnabled = true
        desc.name = "lecturelift-killtest-btap"; desc.isPrivate = true; desc.muteBehavior = .unmuted
        var tap: AudioObjectID = 0
        check(AudioHardwareCreateProcessTap(desc, &tap), "create bundle tap")
        let aggDesc: [String: Any] = [kAudioAggregateDeviceNameKey: "lecturelift-killtest-agg", kAudioAggregateDeviceUIDKey: "lecturelift-killtest-agg-\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: str(builtin(kAudioObjectPropertyScopeOutput), kAudioDevicePropertyDeviceUID),
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: str(builtin(kAudioObjectPropertyScopeOutput), kAudioDevicePropertyDeviceUID)]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]]
        var agg: AudioObjectID = 0
        check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg), "agg")
        var nz = 0, total = 0
        var proc: AudioDeviceIOProcID?
        check(AudioDeviceCreateIOProcIDWithBlock(&proc, agg, nil) { _, inp, _, _, _ in
            let i = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inp))
            total += 1
            if let b = i.last, let d = b.mData { let f = d.assumingMemoryBound(to: Float.self); let n = Int(b.mDataByteSize) / 4
                for k in 0..<n where f[k] != 0 { nz += 1; break } }
        }, "io")
        check(AudioDeviceStart(agg, proc), "start")
        Thread.sleep(forTimeInterval: Double(args[3])!)
        print("bundleTap \(args[2]): blocks=\(total) nonzero=\(nz)")
    } else { print("needs macOS 26") }
case "setdefault":
    for d in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) where str(d, kAudioObjectPropertyName).contains(args[2]) && streams(d, kAudioObjectPropertyScopeOutput) > 0 {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v = d
        print("set default output -> \(str(d, kAudioObjectPropertyName)):", AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &v))
        break
    }
default:
    print("usage: killtest play|tap|listen|list|sweep ...")
}

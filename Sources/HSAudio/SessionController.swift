import AppKit
import AVFoundation
import CoreAudio
import Foundation
import HSCore
import os

/// Raw engine pointer wrapper; access is serialised by the lifecycle queue.
struct EngineRef: @unchecked Sendable { let ptr: OpaquePointer; init(_ p: OpaquePointer) { ptr = p } }

/// User-visible state of the audio session.
public enum SessionState: Equatable, Sendable {
    case off
    case waiting(WaitReason)
    case active
    case needsPermission
    case reconnecting(String)
    case failed(String)
}

public struct SessionStatus: Equatable, Sendable {
    public var state: SessionState = .off
    public var outputName: String = ""
    public var targetApps: [String] = []
    public var latencyMs: Double = 0
    public var cpuPercent: Double = 0
    public var peakIn: Float = 0
    public var peakOut: Float = 0
    public var xruns: UInt64 = 0
    public var bufferFrames: Int = 0
    public var sampleRate: Double = 0
    public var muted: Bool = false
    public var dnUnderflows: UInt64 = 0
    public var qualitaetActive: Bool = false
    /// 0…1 while a raw-input capture is running, nil otherwise.
    public var captureProgress: Double?
    /// Path of the last saved capture (or an error text prefixed with "!").
    public var lastCapture: String?
    public init() {}
}

/// Owns the session lifecycle. All HAL calls happen on `lifecycle`; events only mark the world
/// dirty and trigger one debounced reconcile (DESIGN §4.4).
public final class SessionController: @unchecked Sendable {
    public static let shared = SessionController()

    let log = Logger(subsystem: "io.github.aetsr.lecturelift", category: "Session")
    let lifecycle = DispatchQueue(label: "io.github.aetsr.lecturelift.lifecycle", qos: .userInitiated)
    let watchdogQueue = DispatchQueue(label: "io.github.aetsr.lecturelift.watchdog", qos: .userInitiated)

    // ---- lifecycle-queue state ----
    private var session: TapSession?
    private var generation: UInt64 = 0
    private var enabled = false
    private var sleeping = false
    private var selectedApps: [String] = ProcessResolver.defaultBrowsers
    private var preset = "clarity"   // owner decision D-018 (real-clip listening review)
    private var qualitaet = false
    private var overrides: [Int32: Float] = [:]
    private var abOriginal = false
    private var qualitaetToken = 0
    private var dnReloadPending = false
    private var denoiseDb: Float = 12   // owner decision D-023: optional mode at a moderate setting
    private var lastTargetActivity = Date.distantPast
    private var debounce: DispatchWorkItem?
    private var firstDirty: DispatchTime?
    private var systemListeners: [PropertyListener] = []
    private var outputListeners: [PropertyListener] = []
    private var listenedOutput: AudioObjectID = 0
    private var tick: DispatchSourceTimer?
    private var zeroSince: Date?
    private var retryCount = 0
    private var retryAt: Date?
    private var waitReason: WaitReason = .disabled
    private var lastError: String?
    private var needsPermission = false
    private var pendingFree: [(engine: EngineRef, since: Date)] = []
    // capture of the unprocessed tap input (owner request, D-015)
    private var captureActive = false
    private var captureReleasePending = false
    private var lastCapture: String?
    private var activity: NSObjectProtocol?

    // ---- shared with watchdog / UI (lock-protected, never touched by the audio thread) ----
    private let lock = OSAllocatedUnfairLock()
    private var liveEngine: EngineRef?
    private var liveGeneration: UInt64 = 0
    private var liveStart = DispatchTime.now()
    private var status = SessionStatus()
    private var lifecyclePing = DispatchTime.now()

    public var idleTimeout: TimeInterval = 15
    public var onStatus: (@Sendable (SessionStatus) -> Void)?

    private let defaults = UserDefaults.standard
    /// TCC state (private preflight). `.unavailable` → fall back to the persisted non-zero heuristic.
    private var tccState: CapturePermission = .unavailable
    /// Mute only when the grant is confirmed: by TCC if readable, otherwise by the first non-zero
    /// sample. A pending prompt (`.undetermined`) never mutes (D-010).
    private var permissionConfirmed: Bool {
        tccState == .unavailable ? defaults.bool(forKey: "permissionConfirmed") : tccState == .granted
    }
    private func setHeuristicConfirmed(_ v: Bool) { defaults.set(v, forKey: "permissionConfirmed") }

    private init() {}

    // MARK: public API (any thread)

    public func start(selectedApps: [String]) {
        lifecycle.async { [self] in
            self.selectedApps = selectedApps
            TapManager.sweepLeftovers()
            tccState = CapturePermission.current()
            log.info("TCC preflight: \(String(describing: self.tccState), privacy: .public)")
            installSystemListeners()
            installTimers()
            observeWorkspace()
            markDirty(immediate: true)
        }
    }

    public func setEnabled(_ on: Bool) {
        lifecycle.async { [self] in
            enabled = on
            retryCount = 0; retryAt = nil
            if on { lastTargetActivity = Date() }
            markDirty(immediate: true)
        }
    }

    /// Chain preset (HSCore names: off, clarity, seminar, hall, auditorium). Applied lock-free
    /// to the live engine; parameters are atomics and every stage crossfades its bypass.
    public func setPreset(_ name: String) {
        lifecycle.async { [self] in
            preset = name
            if let s = session { applyPresetAndOverrides(s) }
        }
    }

    /// "Qualität" mode: DeepFilterNet3 on its own worker thread (opt-in; ≤ 12 % CPU, ≤ 80 ms).
    public func setQualitaet(_ on: Bool, attenuationDb: Float? = nil) {
        lifecycle.async { [self] in
            qualitaet = on
            qualitaetToken += 1
            if let a = attenuationDb { denoiseDb = a }
            guard let s = session else { return }
            hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_DB), denoiseDb)
            if on { if hs_engine_denoiser_latency(s.engine) == 0 { startDenoiser(s) } else { hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_ON), 1) } }
            else { stopDenoiser(s) }
        }
    }

    public static func denoiserResources() -> (lib: String, model: String)? {
        let fm = FileManager.default
        var lib = Bundle.main.privateFrameworksURL?.appendingPathComponent("libdf.dylib").path
        var model = Bundle.main.url(forResource: "DeepFilterNet3_onnx.tar", withExtension: "gz", subdirectory: "Models")?.path
        #if DEBUG   // developer override only; a release build loads code from its own bundle only
        let env = ProcessInfo.processInfo.environment
        lib = env["LECTURELIFT_LIBDF"] ?? lib
        model = env["LECTURELIFT_DFN_MODEL"] ?? model
        #endif
        guard let lib, let model, fm.fileExists(atPath: lib), fm.fileExists(atPath: model) else { return nil }
        return (lib, model)
    }

    private func startDenoiser(_ s: TapSession) {
        guard let res = Self.denoiserResources() else { log.error("Qualität: libDF/model not bundled"); return }
        if hs_denoiser_library_load(res.lib) != 0 { log.error("Qualität: cannot load libDF"); return }
        let r = hs_engine_denoiser_load(s.engine, res.model, 0, Int32(s.bufferFrames))
        guard r == 0 || r == -4 else { log.error("Qualität: denoiser load \(r)"); return }
        hs_engine_denoiser_set_workgroup(s.engine, TapManager.ioWorkgroup(s))
        hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_ON), 1)
        log.info("Qualität on: latency +\(hs_engine_denoiser_latency(s.engine)) samples")
    }

    private func stopDenoiser(_ s: TapSession) {
        hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_ON), 0)
        unloadWhenRampedOut(generation: s.generation, token: qualitaetToken, attempt: 0)
    }

    private func reloadWhenRampedOut(generation gen: UInt64, attempt: Int) {
        lifecycle.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            guard let cur = self.session, cur.generation == gen else { self.dnReloadPending = false; return }
            var t = hs_telemetry(); hs_engine_read_telemetry(cur.engine, &t)
            if t.dnMix > 0, attempt < 50 { self.reloadWhenRampedOut(generation: gen, attempt: attempt + 1); return }
            hs_engine_denoiser_unload(cur.engine, 0)
            if self.qualitaet { self.startDenoiser(cur) }
            self.dnReloadPending = false
        }
    }

    /// Unload only once the stage mix has reached 0 and no newer on/off request came in (token).
    private func unloadWhenRampedOut(generation gen: UInt64, token: Int, attempt: Int) {
        lifecycle.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, let cur = self.session, cur.generation == gen, !self.qualitaet, self.qualitaetToken == token else { return }
            var t = hs_telemetry(); hs_engine_read_telemetry(cur.engine, &t)
            if t.dnMix > 0, attempt < 50 { self.unloadWhenRampedOut(generation: gen, token: token, attempt: attempt + 1); return }
            hs_engine_denoiser_unload(cur.engine, 0)
        }
    }

    /// Parameter overrides on top of the preset ("Custom"). Applied lock-free to the live engine and
    /// re-applied after the preset on every new session.
    public func setOverrides(_ o: [Int32: Float]) {
        lifecycle.async { [self] in
            overrides = o
            if let s = session { applyPresetAndOverrides(s) }
        }
    }

    /// A/B: true = play the original (time-aligned). Not persisted.
    public func setABOriginal(_ on: Bool) {
        lifecycle.async { [self] in
            abOriginal = on
            if let s = session { hs_engine_set_param(s.engine, Int32(HS_P_AB_ORIGINAL), on ? 1 : 0) }
        }
    }

    private func applyPresetAndOverrides(_ s: TapSession) {
        // Merge preset values and overrides first and write each parameter once: the audio thread
        // never sees a preset value for a parameter that is overridden (Fable M5 #2).
        var vals = [Float](repeating: 0, count: Int(HS_P_COUNT))
        var mask = [UInt8](repeating: 0, count: Int(HS_P_COUNT))
        if hs_preset_values(preset, &vals, &mask) == 0 {
            for (k, v) in overrides { vals[Int(k)] = v; mask[Int(k)] = 1 }
            for i in 0..<Int(HS_P_COUNT) where mask[i] != 0 { hs_engine_set_param(s.engine, Int32(i), vals[i]) }
        }
        hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_DB), denoiseDb)
        hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_ON), qualitaet && hs_engine_denoiser_latency(s.engine) > 0 ? 1 : 0)
        hs_engine_set_param(s.engine, Int32(HS_P_AB_ORIGINAL), abOriginal ? 1 : 0)
        maintainReverb(s)
    }

    /// Apps that currently have an audio connection (for the app picker), grouped by app.
    public func availableAudioApps() -> [(bundleID: String, name: String)] {
        let procs = ProcessResolver.allProcesses()
        var seen = Set<String>()
        var out: [(String, String)] = []
        for p in procs where !p.appBundleID.isEmpty && !seen.contains(p.appBundleID) {
            seen.insert(p.appBundleID)
            out.append((p.appBundleID, appName(p.appBundleID)))
        }
        return out.sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    public func setSelectedApps(_ apps: [String]) {
        lifecycle.async { [self] in selectedApps = apps; markDirty() }
    }

    /// Synchronous teardown (app quit, willSleep).
    public func shutdown() {
        lifecycle.sync { [self] in enabled = false; teardown(fade: false) }
    }

    /// Status (published every 0.5 s) with live meters/CPU read from the engine telemetry (lock-protected:
    /// lifecycle clears liveEngine under the same lock before freeing).
    public func currentStatus() -> SessionStatus {
        lock.withLock {
            var st = status
            if let e = liveEngine {
                var t = hs_telemetry(); hs_engine_read_telemetry(e.ptr, &t)
                st.peakIn = t.peakIn; st.peakOut = t.peakOut; st.cpuPercent = Double(t.cpuLoad) * 100; st.xruns = t.xruns
            }
            return st
        }
    }

    // MARK: events → reconcile

    private func markDirty(immediate: Bool = false) {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        debounce?.cancel()
        let now = DispatchTime.now()
        if firstDirty == nil { firstDirty = now }
        // Trailing 150 ms debounce, but never postpone a reconcile by more than 500 ms in total.
        let waited = Double(now.uptimeNanoseconds - firstDirty!.uptimeNanoseconds) / 1e9
        let delay = immediate ? 0 : max(0, min(0.15, 0.5 - waited))
        let work = DispatchWorkItem { [weak self] in self?.firstDirty = nil; self?.reconcile() }
        debounce = work
        lifecycle.asyncAfter(deadline: now + delay, execute: work)
    }

    private func snapshot(processes: [AudioProcessInfo]) -> WorldSnapshot {
        let out = CA.defaultOutputDevice()
        let targets = resolveTargets(processes)
        if targets.contains(where: { $0.isRunningOutput }) { lastTargetActivity = Date() }
        let idle = Date().timeIntervalSince(lastTargetActivity) > idleTimeout
        return WorldSnapshot(enabled: enabled, sleeping: sleeping, permissionConfirmed: permissionConfirmed,
                             outputUID: out == kAudioObjectUnknown ? nil : CA.deviceUID(out),
                             outputAlive: out != kAudioObjectUnknown && CA.isAlive(out),
                             outputRate: out == kAudioObjectUnknown ? 0 : CA.nominalRate(out),
                             targets: targets.map(\.objectID), idle: idle)
    }

    private func reconcile() {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        let processes = ProcessResolver.allProcesses()
        let world = snapshot(processes: processes)
        if let at = retryAt, Date() < at { publish(processes: processes); return }

        let action = Reconciler.plan(current: session?.spec, world: world)
        switch action {
        case .none:
            if session == nil, case .failure(let r) = Reconciler.desired(world) { waitReason = r }
        case .stop(let reason):
            waitReason = reason
            teardown(fade: reason != .sleeping)
        case .updateTargets(let t):
            if let s = session, !TapManager.updateTargets(s, targets: t) {
                rebuild(Reconciler.desired(world))
            } else if let s = session {
                s.spec.targets = t   // keep the spec in sync after a successful live update
            }
        case .start, .restart:
            rebuild(Reconciler.desired(world))
        }
        watchOutput(CA.defaultOutputDevice())
        publish(processes: processes)
    }

    /// Builds the IR for the current room/damping when needed (allocates: lifecycle queue only)
    /// and frees convolver pairs the audio thread has retired.
    private func maintainReverb(_ s: TapSession) {
        let r = hs_engine_rebuild_reverb(s.engine, 42)
        if r < 0 { log.error("reverb rebuild: \(r)") }   // -1 = queue full → retried on the next tick
    }

    private func rebuild(_ desired: Result<SessionSpec, WaitReason>) {
        teardown(fade: true)
        guard case .success(let spec) = desired else { return }
        generation += 1
        let gen = generation
        do {
            let s = try TapManager.create(spec: spec, generation: gen, onOverload: { [weak self] in
                // Runs on lifecycle; the engine is only touched if this generation is still live.
                guard let self, let cur = self.session, cur.generation == gen else { return }
                hs_engine_note_overload(cur.engine)
            }, queue: lifecycle)
            session = s
            applyPresetAndOverrides(s)
            if qualitaet { startDenoiser(s) }
            // While permission is unconfirmed the tap does not mute the original, so our output stays
            // silent too (otherwise original + copy 11–17 ms later = comb filter).
            hs_engine_set_fade_target(s.engine, spec.muted ? 1 : 0)
            lock.withLock { liveEngine = EngineRef(s.engine); liveGeneration = gen; liveStart = DispatchTime.now() }
            lastError = nil
            retryCount = 0; retryAt = nil
            zeroSince = nil
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "LectureLift audio session")
            }
        } catch {
            log.error("create failed: \(String(describing: error), privacy: .public)")
            lastError = String(describing: error)
            scheduleRetry()
        }
    }

    private func teardown(fade: Bool) {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        guard let s = session else { return }
        if fade {
            hs_engine_set_fade_target(s.engine, 0)
            // Wait (max 60 ms) for the 20 ms fade-out to reach silence.
            let deadline = Date().addingTimeInterval(0.06)
            var t = hs_telemetry()
            repeat { usleep(5_000); hs_engine_read_telemetry(s.engine, &t) } while t.fadeState != Int32(HS_FADE_SILENT) && Date() < deadline
        }
        lock.withLock { liveEngine = nil }
        TapManager.destroy(s)
        hs_engine_denoiser_unload(s.engine, 1)   // IOProc gone: stop + join the worker now (D-014 M4 note)
        // The IOProc is stopped: a running capture is saved as far as it got.
        if captureActive { finishCapture(engine: s.engine, rate: s.spec.sampleRate, ioprocStopped: true) }
        captureReleasePending = false   // engine destroy frees any detached capture
        session = nil
        // Destroy calls may fail (dead device, hung HAL), so the I/O thread is not proven gone:
        // free only after its heartbeat has been silent for ≥ 1 s (drainPendingFree).
        pendingFree.append((EngineRef(s.engine), Date()))
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    private func scheduleRetry() {
        let delays: [TimeInterval] = [1, 5, 30]
        let d = delays[min(retryCount, delays.count - 1)]
        retryCount += 1
        retryAt = Date().addingTimeInterval(d)
        lifecycle.asyncAfter(deadline: .now() + d) { [weak self] in self?.retryAt = nil; self?.markDirty(immediate: true) }
    }

    // MARK: service restart

    private func handleServiceRestart() {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        log.error("coreaudiod restarted")
        systemListeners.forEach { $0.abandon() }; systemListeners = []
        outputListeners.forEach { $0.abandon() }; outputListeners = []
        listenedOutput = 0
        if let s = session {
            lock.withLock { liveEngine = nil }
            TapManager.destroyAfterServiceRestart(s)
            if captureActive { finishCapture(engine: s.engine, rate: s.spec.sampleRate, ioprocStopped: true) }
            captureReleasePending = false
            session = nil
            // The HAL I/O thread lives in our process and may still be inside hs_render:
            // free only after the heartbeat has been silent for ≥ 1 s (checked in tick()).
            pendingFree.append((EngineRef(s.engine), Date()))
        }
        generation += 1
        installSystemListeners()
        markDirty()
    }

    private func drainPendingFree() {
        let now = mach_absolute_time()
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        pendingFree.removeAll { entry in
            var t = hs_telemetry(); hs_engine_read_telemetry(entry.engine.ptr, &t)
            let silentNs = Double(now &- t.heartbeatHostTime) * Double(tb.numer) / Double(tb.denom)
            if silentNs > 1e9, Date().timeIntervalSince(entry.since) > 1 { hs_engine_destroy(entry.engine.ptr); return true }
            return false
        }
    }

    // MARK: listeners

    private func installSystemListeners() {
        guard systemListeners.isEmpty else { return }
        let q = lifecycle
        systemListeners = [
            PropertyListener(CA.system, kAudioHardwarePropertyDefaultOutputDevice, queue: q) { [weak self] in self?.markDirty() },
            PropertyListener(CA.system, kAudioHardwarePropertyDevices, queue: q) { [weak self] in self?.markDirty() },
            PropertyListener(CA.system, kAudioHardwarePropertyProcessObjectList, queue: q) { [weak self] in self?.markDirty() },
            PropertyListener(CA.system, kAudioHardwarePropertyServiceRestarted, queue: q) { [weak self] in self?.handleServiceRestart() },
        ]
    }

    private func watchOutput(_ dev: AudioObjectID) {
        guard dev != listenedOutput else { return }
        outputListeners.forEach { $0.remove() }
        listenedOutput = dev
        guard dev != kAudioObjectUnknown else { outputListeners = []; return }
        let q = lifecycle
        outputListeners = [
            PropertyListener(dev, kAudioDevicePropertyDeviceIsAlive, queue: q) { [weak self] in
                guard let self else { return }
                if !CA.isAlive(dev) { self.teardown(fade: false) }   // device gone: no fade possible
                self.markDirty()
            },
            PropertyListener(dev, kAudioDevicePropertyNominalSampleRate, queue: q) { [weak self] in self?.markDirty() },
        ]
    }

    private func observeWorkspace() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.log.info("willSleep: tearing down")
            self.lifecycle.sync { self.sleeping = true; self.teardown(fade: false) }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.log.info("didWake: reconnecting in 1 s")
            self.lifecycle.asyncAfter(deadline: .now() + 1) {
                self.sleeping = false
                self.lastTargetActivity = Date()
                self.markDirty(immediate: true)
            }
        }
    }

    // MARK: timers: idle/permission (lifecycle, 0.5 s) and watchdog (own queue, 0.25 s)

    private func installTimers() {
        guard tick == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: lifecycle)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.onTick() }
        t.resume()
        tick = t

        let w = DispatchSource.makeTimerSource(queue: watchdogQueue)
        w.schedule(deadline: .now() + 0.25, repeating: 0.25)
        w.setEventHandler { [weak self] in self?.watchdog() }
        w.resume()
        watchdogTimer = w
    }
    private var watchdogTimer: DispatchSourceTimer?
    private var tickCount = 0
    /// Test hook: LECTURELIFT_DEBUG_STALL_AT=<s> simulates an IOProc stall once, s seconds after session start.
    #if DEBUG
    private let debugStallAt: TimeInterval? = ProcessInfo.processInfo.environment["LECTURELIFT_DEBUG_STALL_AT"].flatMap(Double.init)
    #else
    private let debugStallAt: TimeInterval? = nil
    #endif
    private var debugStallFired = false

    // MARK: capture of the unprocessed tap input

    /// Records `seconds` of the raw tap input (before any processing) to a local WAV file.
    /// The file never leaves the machine. Directory: LECTURELIFT_CAPTURE_DIR, defaults "captureDirectory",
    /// else ~/Music/LectureLift Clips.
    public func startCapture(seconds: Double = 60) {
        lifecycle.async { [self] in
            guard let s = session, !captureActive, !captureReleasePending else { return }
            if hs_engine_capture_start(s.engine, seconds) == 0 {
                captureActive = true
                lastCapture = nil
                log.info("capture armed: \(seconds) s")
            }
        }
    }

    static func captureDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["LECTURELIFT_CAPTURE_DIR"] { return URL(fileURLWithPath: env) }
        if let d = UserDefaults.standard.string(forKey: "captureDirectory") { return URL(fileURLWithPath: d) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/LectureLift Clips")
    }

    private func finishCapture(engine: OpaquePointer, rate: Double, ioprocStopped: Bool) {
        dispatchPrecondition(condition: .onQueue(lifecycle))
        captureActive = false
        let frames = hs_engine_capture_detach(engine)
        guard frames > 0 else { _ = hs_engine_capture_release(engine, 1); return }
        var data = [Float](repeating: 0, count: Int(frames) * 2)
        _ = hs_engine_capture_copy(engine, &data, frames)
        if hs_engine_capture_release(engine, ioprocStopped ? 1 : 0) == 0 { captureReleasePending = true }
        do {
            let dir = Self.captureDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let fmtr = DateFormatter(); fmtr.dateFormat = "yyyyMMdd-HHmmss"
            let url = dir.appendingPathComponent("clip-\(fmtr.string(from: Date())).wav")
            let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
            buf.frameLength = AVAudioFrameCount(frames)
            for i in 0..<Int(frames) { buf.floatChannelData![0][i] = data[2 * i]; buf.floatChannelData![1][i] = data[2 * i + 1] }
            var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file?.write(from: buf)
            file = nil
            lastCapture = url.path
            log.info("capture saved: \(Int(frames)) frames → \(url.path, privacy: .private)")
        } catch {
            lastCapture = "!\(error.localizedDescription)"
            log.error("capture write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func onTick() {
        lock.withLock { lifecyclePing = DispatchTime.now() }
        drainPendingFree()
        let processes = ProcessResolver.allProcesses()
        let targets = resolveTargets(processes)
        let running = targets.contains { $0.isRunningOutput }
        if running { lastTargetActivity = Date() }

        tickCount += 1
        if tickCount % 4 == 0 {   // every 2 s
            let now = CapturePermission.current()
            if now != tccState {
                log.info("TCC state \(String(describing: self.tccState), privacy: .public) → \(String(describing: now), privacy: .public)")
                tccState = now
                markDirty(immediate: true)   // muted ↔ unmuted follows the grant
            }
        }
        if let s = session {
            if captureActive {
                var cap: Int64 = 0
                let w = hs_engine_capture_progress(s.engine, &cap)
                if cap > 0, w >= cap { finishCapture(engine: s.engine, rate: s.spec.sampleRate, ioprocStopped: false) }
            } else if captureReleasePending, hs_engine_capture_release(s.engine, 0) == 1 {
                captureReleasePending = false
            }
            if let at = debugStallAt, Date().timeIntervalSince(s.startedAt) > at, !debugStallFired {
                debugStallFired = true
                log.error("TEST HOOK: simulating IOProc stall in g\(s.generation)")
                hs_engine_debug_stall(s.engine, 1)
            }
            maintainReverb(s)
            var t = hs_telemetry(); hs_engine_read_telemetry(s.engine, &t)
            if qualitaet, t.dnFailed != 0, !dnReloadPending, Self.denoiserResources() != nil {
                // libDF error latched (D-017): ramp out (no jump from the delayed fallback to undelayed
                // input), unload, then load a fresh state (Fable M5 #1).
                log.error("denoiser failed (\(t.dnNaN) errors): reloading")
                dnReloadPending = true
                hs_engine_set_param(s.engine, Int32(HS_P_DENOISE_ON), 0)
                reloadWhenRampedOut(generation: s.generation, attempt: 0)
            }
            if tickCount % 10 == 0 {
                // swiftlint:disable:next line_length
                log.info("telemetry g\(s.generation) cb=\(t.callbacks) frames=\(t.lastFrames) xruns=\(t.xruns) cpu=\(String(format: "%.2f", t.cpuLoad * 100), privacy: .public)% peakIn=\(String(format: "%.3f", t.peakIn), privacy: .public) peakOut=\(String(format: "%.3f", t.peakOut), privacy: .public) nonzero=\(t.nonzeroBlocks) muted=\(s.spec.muted) fade=\(t.fadeState) lat=\(String(format: "%.1f", s.ioLatency * 1000), privacy: .public)ms ioDelta=\(String(format: "%.1f", t.ioDeltaSec * 1000), privacy: .public)ms")
            }
            // Permission: first non-zero sample confirms it; until then zeros mean "maybe denied".
            let heuristic = tccState == .unavailable
            if t.nonzeroBlocks > 0 {
                zeroSince = nil
                needsPermission = tccState == .denied
                if heuristic, !permissionConfirmed { setHeuristicConfirmed(true); markDirty(immediate: true) }   // → recreate muted
            } else if running {
                zeroSince = zeroSince ?? Date()
                let zeroFor = zeroSince.map { Date().timeIntervalSince($0) } ?? 0
                needsPermission = tccState == .denied || (!permissionConfirmed && zeroFor > 5)
                if permissionConfirmed, zeroFor > 10 {
                    // Grant may have been revoked: a muted tap + zeros = silence. Fall back to the
                    // unmuted probe; the next non-zero sample confirms again.
                    log.error("10 s of digital zeros while targets play: re-checking permission (unmuted)")
                    if heuristic { setHeuristicConfirmed(false) } else { tccState = CapturePermission.current() }
                    markDirty(immediate: true)
                }
            }
            let idle = Date().timeIntervalSince(lastTargetActivity) > idleTimeout
            if idle || Set(targets.map(\.objectID)) != Set(s.spec.targets) { markDirty() }
        } else if enabled, running, waitReason == .idle || waitReason == .noTargets {
            markDirty(immediate: true)
        }
        publish(processes: processes)
    }

    private func watchdog() {
        // Read telemetry under the lock: lifecycle clears liveEngine under the same lock before freeing.
        let (t, hasEngine, gen, started, ping) = lock.withLock { () -> (hs_telemetry, Bool, UInt64, DispatchTime, DispatchTime) in
            var tel = hs_telemetry()
            if let e = liveEngine { hs_engine_read_telemetry(e.ptr, &tel) }
            return (tel, liveEngine != nil, liveGeneration, liveStart, lifecyclePing)
        }
        let now = DispatchTime.now()
        if hasEngine, Double(now.uptimeNanoseconds &- ping.uptimeNanoseconds) / 1e9 > 3 {
            // lifecycle is hung inside a HAL call. Process death releases the mute (D-007).
            log.fault("lifecycle queue unresponsive for >3 s with an active session: exiting")
            exit(3)
        }
        guard hasEngine else { return }
        let armed = t.generation == gen && t.callbacks > 0
        let age = Double(now.uptimeNanoseconds &- started.uptimeNanoseconds) / 1e9
        guard armed || age > 2 else { return }
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        let silentMs = Double(mach_absolute_time() &- t.heartbeatHostTime) * Double(tb.numer) / Double(tb.denom) / 1e6
        if !armed || silentMs > 500 {
            log.error("watchdog: no IOProc heartbeat for \(Int(silentMs)) ms (g\(gen)): tearing down")
            lifecycle.async { [weak self] in
                guard let self, self.session?.generation == gen else { return }
                self.lastError = "Audio-Gerät reagiert nicht"
                self.teardown(fade: false)
                self.scheduleRetry()
                self.publish(processes: ProcessResolver.allProcesses())
            }
        }
    }

    // MARK: status

    private func publish(processes: [AudioProcessInfo]) {
        var st = SessionStatus()
        let out = CA.defaultOutputDevice()
        st.outputName = out == kAudioObjectUnknown ? "" : CA.name(out)
        let targets = resolveTargets(processes)
        st.targetApps = Array(Set(targets.map { appName($0.appBundleID) })).sorted()
        if let s = session {
            var t = hs_telemetry(); hs_engine_read_telemetry(s.engine, &t)
            st.state = needsPermission ? .needsPermission : .active
            // Added latency = measured tap→output gap (device latency is common to both paths) + algorithmic.
            let io = t.ioDeltaSec > 0 ? t.ioDeltaSec : s.ioLatency
            st.latencyMs = (io + Double(hs_engine_latency_samples(s.engine)) / s.spec.sampleRate) * 1000
            st.cpuPercent = Double(t.cpuLoad) * 100
            st.peakIn = t.peakIn; st.peakOut = t.peakOut; st.xruns = t.xruns
            st.bufferFrames = s.bufferFrames; st.sampleRate = s.spec.sampleRate; st.muted = s.spec.muted
            st.dnUnderflows = t.dnUnderflows; st.qualitaetActive = t.dnMix > 0
            if captureActive {
                var cap: Int64 = 0
                let w = hs_engine_capture_progress(s.engine, &cap)
                st.captureProgress = cap > 0 ? min(1, Double(max(w, 0)) / Double(cap)) : 0
            }
        } else if !enabled {
            st.state = .off
        } else if let e = lastError {
            st.state = retryAt != nil ? .reconnecting(e) : .failed(e)
        } else {
            st.state = .waiting(waitReason)
        }
        st.lastCapture = lastCapture
        let snap = st
        let changed = lock.withLock { () -> Bool in
            let c = status.state != snap.state || status.targetApps != snap.targetApps || status.outputName != snap.outputName
            status = snap; return c
        }
        if changed { log.info("state=\(String(describing: snap.state), privacy: .public) out=\(snap.outputName, privacy: .public) apps=\(snap.targetApps, privacy: .public)") }
        if changed { onStatus?(snap) }
    }

    /// Test hook: LECTURELIFT_PIDS="123,456" taps exactly these PIDs (our own tone process), never browsers.
    #if DEBUG
    private let pidOverride: Set<pid_t>? = ProcessInfo.processInfo.environment["LECTURELIFT_PIDS"]
        .map { Set($0.split(separator: ",").compactMap { pid_t($0) }) }
    #else
    private let pidOverride: Set<pid_t>? = nil
    #endif

    private func resolveTargets(_ processes: [AudioProcessInfo]) -> [AudioProcessInfo] {
        if let pids = pidOverride { return processes.filter { pids.contains($0.pid) } }
        return ProcessResolver.resolve(selected: selectedApps, in: processes)
    }

    private func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}

import CoreAudio
import Foundation
import HSCore
import os

/// What a session should look like. Two equal specs mean "nothing to do".
public struct SessionSpec: Equatable, Sendable {
    public var outputUID: String
    public var sampleRate: Double
    public var muted: Bool
    public var targets: [AudioObjectID]

    public init(outputUID: String, sampleRate: Double, muted: Bool, targets: [AudioObjectID]) {
        self.outputUID = outputUID; self.sampleRate = sampleRate; self.muted = muted; self.targets = targets
    }
}

/// A running tap → private aggregate → IOProc chain. Created and destroyed on the lifecycle queue only.
final class TapSession {
    var spec: SessionSpec
    let generation: UInt64
    let tapID: AudioObjectID
    let tapUUID: UUID
    let aggregateID: AudioObjectID
    let outputDevice: AudioObjectID
    var procID: AudioDeviceIOProcID?
    let engine: OpaquePointer
    let bufferFrames: Int
    /// Estimated added latency in seconds (I/O path only; algorithmic latency is added by the caller).
    let ioLatency: Double
    var listeners: [PropertyListener] = []
    let startedAt = Date()

    init(spec: SessionSpec, generation: UInt64, tapID: AudioObjectID, tapUUID: UUID, aggregateID: AudioObjectID,
         outputDevice: AudioObjectID, procID: AudioDeviceIOProcID?, engine: OpaquePointer, bufferFrames: Int, ioLatency: Double) {
        self.spec = spec; self.generation = generation; self.tapID = tapID; self.tapUUID = tapUUID
        self.aggregateID = aggregateID; self.outputDevice = outputDevice; self.procID = procID
        self.engine = engine; self.bufferFrames = bufferFrames; self.ioLatency = ioLatency
    }
}

/// Creates and tears down sessions. Implementation follows Apple's "Capturing system audio with
/// Core Audio taps" and AudioCap (BSD-2-Clause, Guilherme Rambo) for the tap/aggregate pattern.
enum TapManager {
    static let log = Logger(subsystem: "io.github.aetsr.lecturelift", category: "TapManager")
    static let uidPrefix = "io.github.aetsr.lecturelift."
    static let preferredBufferFrames: UInt32 = 256

    static func makeTapDescription(targets: [AudioObjectID], muted: Bool, uuid: UUID) -> CATapDescription {
        let d = CATapDescription(stereoMixdownOfProcesses: targets)
        d.name = "LectureLift"
        d.uuid = uuid
        d.isPrivate = true
        d.muteBehavior = muted ? .mutedWhenTapped : .unmuted
        return d
    }

    /// Builds the whole chain. On any failure everything created so far is destroyed again.
    static func create(spec: SessionSpec, generation: UInt64, onOverload: @escaping () -> Void,
                       queue: DispatchQueue) throws -> TapSession {
        let output = CA.ids(CA.system, kAudioHardwarePropertyDevices).first { CA.deviceUID($0) == spec.outputUID }
        guard let output else { throw CAError(what: "find output device \(spec.outputUID)", status: OSStatus(kAudioHardwareBadDeviceError)) }

        // 1. Tap
        let tapUUID = UUID()
        let desc = makeTapDescription(targets: spec.targets, muted: spec.muted, uuid: tapUUID)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "AudioHardwareCreateProcessTap")
        var cleanup: [() -> Void] = [{ AudioHardwareDestroyProcessTap(tapID) }]
        func fail(_ e: Error) -> Error { cleanup.reversed().forEach { $0() }; return e }

        // 2. Private aggregate: output device = main + clock; tap in the tap list.
        let aggUID = "\(uidPrefix)agg.\(tapUUID.uuidString)"
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LectureLift",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: spec.outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // false: AudioDeviceStart must not wait for the first tapped audio (DESIGN §4.2; a silent
            // target would otherwise block start and trip the watchdog).
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: spec.outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUUID.uuidString,
                                              kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        do { try check(AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg), "AudioHardwareCreateAggregateDevice") }
        catch { throw fail(error) }
        cleanup.append { AudioHardwareDestroyAggregateDevice(agg) }

        // 3. Buffer size (best effort) and real layouts.
        CA.set(agg, kAudioDevicePropertyBufferFrameSize, preferredBufferFrames)
        let bufferFrames = Int(CA.get(agg, kAudioDevicePropertyBufferFrameSize, default: UInt32(512)))
        let range: AudioValueRange = CA.get(agg, kAudioDevicePropertyBufferFrameSizeRange, default: AudioValueRange(mMinimum: 0, mMaximum: 4096))
        let maxFrames = max(4096, Int(range.mMaximum), bufferFrames)
        let rate = CA.nominalRate(agg) > 0 ? CA.nominalRate(agg) : spec.sampleRate

        let inLayout = CA.bufferLayout(agg, kAudioObjectPropertyScopeInput)
        let outLayout = CA.bufferLayout(agg, kAudioObjectPropertyScopeOutput)
        guard let tapChannels = inLayout.last, !outLayout.isEmpty else {
            throw fail(CAError(what: "aggregate layout in=\(inLayout) out=\(outLayout)", status: OSStatus(kAudioHardwareUnspecifiedError)))
        }
        // Hardware input streams of the output device come first, the tap stream last.
        let tapBufferIndex = inLayout.count - 1

        // 4. Engine
        guard let engine = hs_engine_create() else { throw fail(CAError(what: "hs_engine_create", status: -1)) }
        cleanup.append { hs_engine_destroy(engine) }
        hs_engine_prepare(engine, rate, Int32(maxFrames))
        hs_engine_set_input(engine, Int32(tapBufferIndex), Int32(tapChannels), 1)
        let sources = outputChannelMap(outputDevice: output, layout: outLayout)
        let chans = outLayout.map { Int32($0) }
        let inter = outLayout.map { _ in Int32(1) }
        hs_engine_set_output_map(engine, Int32(outLayout.count), chans, inter, sources)
        hs_engine_reset_fade(engine, 0)
        hs_engine_set_generation(engine, generation)

        // 5. IOProc (plain C function pointer, raw context)
        var procID: AudioDeviceIOProcID?
        do { try check(AudioDeviceCreateIOProcID(agg, hs_ioproc, UnsafeMutableRawPointer(engine), &procID), "AudioDeviceCreateIOProcID") }
        catch { throw fail(error) }
        cleanup.append { if let p = procID { AudioDeviceDestroyIOProcID(agg, p) } }
        do { try disableHardwareInputs(aggregate: agg, procID: procID, streamCount: inLayout.count) }
        catch { throw fail(error) }

        let latency = estimateIOLatency(aggregate: agg, bufferFrames: bufferFrames, rate: rate)
        let session = TapSession(spec: spec, generation: generation, tapID: tapID, tapUUID: tapUUID, aggregateID: agg,
                                 outputDevice: output, procID: procID, engine: engine, bufferFrames: bufferFrames, ioLatency: latency)
        session.listeners.append(PropertyListener(agg, kAudioDeviceProcessorOverload, queue: queue, handler: onOverload))

        // 6. Start
        do { try check(AudioDeviceStart(agg, procID), "AudioDeviceStart") }
        catch { session.listeners.forEach { $0.remove() }; throw fail(error) }

        // swiftlint:disable:next line_length
        log.info("session g\(generation) up: out=\(spec.outputUID, privacy: .public) rate=\(rate) buf=\(bufferFrames) in=\(inLayout, privacy: .public) out=\(outLayout, privacy: .public) muted=\(spec.muted) targets=\(spec.targets.count)")
        return session
    }

    /// Fixed teardown order: stop → destroy IOProc → destroy aggregate → destroy tap.
    /// The engine is NOT freed here; the caller frees it once the heartbeat is provably silent.
    static func destroy(_ s: TapSession) {
        s.listeners.forEach { $0.remove() }
        s.listeners.removeAll()
        if let p = s.procID {
            AudioDeviceStop(s.aggregateID, p)
            AudioDeviceDestroyIOProcID(s.aggregateID, p)
            s.procID = nil
        }
        AudioHardwareDestroyAggregateDevice(s.aggregateID)
        AudioHardwareDestroyProcessTap(s.tapID)
        log.info("session g\(s.generation) torn down")
    }

    /// After a coreaudiod restart: listener registrations are gone server-side, the destroy calls
    /// are still made but their errors ignored.
    static func destroyAfterServiceRestart(_ s: TapSession) {
        s.listeners.forEach { $0.abandon() }
        s.listeners.removeAll()
        if let p = s.procID {
            _ = AudioDeviceStop(s.aggregateID, p)
            _ = AudioDeviceDestroyIOProcID(s.aggregateID, p)
            s.procID = nil
        }
        _ = AudioHardwareDestroyAggregateDevice(s.aggregateID)
        _ = AudioHardwareDestroyProcessTap(s.tapID)
    }

    /// Live update of the tapped process list (kAudioTapPropertyDescription is settable).
    static func updateTargets(_ s: TapSession, targets: [AudioObjectID]) -> Bool {
        let desc = makeTapDescription(targets: targets, muted: s.spec.muted, uuid: s.tapUUID)
        var addr = CA.address(kAudioTapPropertyDescription)
        var ref: CATapDescription = desc
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectSetPropertyData(s.tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        if status != noErr { log.error("live tap update failed: \(CA.fourCC(status), privacy: .public)") }
        return status == noErr
    }

    /// Channel map for the aggregate output: stereo to the device's preferred pair, mono sum to a
    /// single-channel device, silence everywhere else.
    static func outputChannelMap(outputDevice: AudioObjectID, layout: [Int]) -> [Int8] {
        let total = layout.reduce(0, +)
        var map = [Int8](repeating: Int8(HS_SRC_ZERO), count: max(total, 1))
        if total == 0 { return map }
        if total == 1 { map[0] = Int8(HS_SRC_MONO); return map }
        var pair: (UInt32, UInt32) = (1, 2)
        pair = CA.get(outputDevice, kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeOutput, default: pair)
        var l = Int(pair.0) - 1, r = Int(pair.1) - 1
        if !(0..<total).contains(l) || !(0..<total).contains(r) || l == r { l = 0; r = 1 }   // invalid pair → first two
        map[l] = Int8(HS_SRC_LEFT)
        map[r] = Int8(HS_SRC_RIGHT)
        return map
    }

    /// Only the tap stream is needed; switching the output device's own inputs (e.g. the AirPods
    /// microphone) off avoids waking them and forcing Bluetooth into the low-quality headset profile.
    static func disableHardwareInputs(aggregate: AudioObjectID, procID: AudioDeviceIOProcID?, streamCount: Int) throws {
        guard let procID, streamCount > 1 else { return }
        let size = MemoryLayout<AudioHardwareIOProcStreamUsage>.size + (streamCount - 1) * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streamCount)
        let flags = raw.advanced(by: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!)
            .bindMemory(to: UInt32.self, capacity: streamCount)
        for i in 0..<streamCount { flags[i] = i == streamCount - 1 ? 1 : 0 }
        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        let st = AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(size), raw)
        // Fatal: otherwise e.g. the AirPods microphone would wake up and force the headset profile.
        try check(st, "kAudioDevicePropertyIOProcStreamUsage")
    }

    /// Added latency of the tap path: one buffer + input safety offset + input latency of the
    /// aggregate (tap stream). Validated against a measurement in M1 (DESIGN §9.1).
    static func estimateIOLatency(aggregate: AudioObjectID, bufferFrames: Int, rate: Double) -> Double {
        let inLat = Int(CA.get(aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeInput, default: UInt32(0)))
        let inSafety = Int(CA.get(aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeInput, default: UInt32(0)))
        let outLat = Int(CA.get(aggregate, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, default: UInt32(0)))
        let outSafety = Int(CA.get(aggregate, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, default: UInt32(0)))
        let inStreams = CA.ids(aggregate, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput)
        let streamLat = inStreams.map { Int(CA.get($0, kAudioStreamPropertyLatency, default: UInt32(0))) }
        log.info("latency props: in=\(inLat) inSafety=\(inSafety) out=\(outLat) outSafety=\(outSafety) inStreamLat=\(streamLat, privacy: .public) buf=\(bufferFrames) rate=\(rate)")
        // Fallback until the first IOProc reports the measured gap: two I/O buffers (measured on M1, D-008).
        return Double(2 * bufferFrames) / max(rate, 1)
    }

    /// The aggregate's IOThread workgroup (raw HAL object), for the denoiser worker to join.
    static func ioWorkgroup(_ s: TapSession) -> UnsafeMutableRawPointer? {
        var addr = CA.address(kAudioDevicePropertyIOThreadOSWorkgroup)
        var raw: UnsafeMutableRawPointer?
        var size = UInt32(MemoryLayout<UnsafeMutableRawPointer?>.size)
        let st = AudioObjectGetPropertyData(s.aggregateID, &addr, 0, nil, &size, &raw)
        return st == noErr ? raw : nil
    }

    /// Defensive clean-up of public leftovers with our prefix (private objects die with their process).
    static func sweepLeftovers() {
        for d in CA.ids(CA.system, kAudioHardwarePropertyDevices) where (CA.deviceUID(d) ?? "").hasPrefix(uidPrefix) {
            AudioHardwareDestroyAggregateDevice(d)
        }
    }
}

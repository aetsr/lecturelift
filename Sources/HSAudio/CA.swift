import CoreAudio
import Foundation

/// Thin, typed helpers around the Core Audio property API. Control threads only.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ sel: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: element)
    }

    static func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, default def: T) -> T {
        var a = address(sel, scope)
        var value = def
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &a, 0, nil, &size, $0)
        }
        return status == noErr ? value : def
    }

    @discardableResult
    static func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: T,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> OSStatus {
        var a = address(sel, scope)
        var v = value
        return withUnsafeMutablePointer(to: &v) {
            AudioObjectSetPropertyData(obj, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    static func ids(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
        var a = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &out) == noErr else { return [] }
        return out
    }

    static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector,
                       _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var a = address(sel, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Stream configuration (one AudioBuffer per stream) of a device in the given scope.
    static func bufferLayout(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> [Int] {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return [] }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return abl.map { Int($0.mNumberChannels) }
    }

    static func defaultOutputDevice() -> AudioObjectID {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    static func deviceUID(_ dev: AudioObjectID) -> String? { string(dev, kAudioDevicePropertyDeviceUID) }
    static func name(_ obj: AudioObjectID) -> String { string(obj, kAudioObjectPropertyName) ?? "?" }

    static func isAlive(_ dev: AudioObjectID) -> Bool {
        get(dev, kAudioDevicePropertyDeviceIsAlive, default: UInt32(0)) != 0
    }

    static func nominalRate(_ dev: AudioObjectID) -> Double {
        get(dev, kAudioDevicePropertyNominalSampleRate, default: Float64(0))
    }

    static func fourCC(_ status: OSStatus) -> String {
        let n = UInt32(bitPattern: status)
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((n >> $0) & 0xFF))) }
        return chars.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " " || $0 == "!") }
            ? "'\(String(chars))' (\(status))" : "\(status)"
    }
}

struct CAError: Error, CustomStringConvertible {
    let what: String
    let status: OSStatus
    var description: String { "\(what) failed: \(CA.fourCC(status))" }
}

@inline(__always)
func check(_ status: OSStatus, _ what: String) throws {
    if status != noErr { throw CAError(what: what, status: status) }
}

/// RAII registration of a HAL property listener (block-based, delivered on `queue`).
final class PropertyListener {
    private let object: AudioObjectID
    private var addr: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private(set) var active = false

    init(_ object: AudioObjectID, _ sel: AudioObjectPropertySelector,
         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
         queue: DispatchQueue, handler: @escaping () -> Void) {
        self.object = object
        self.addr = CA.address(sel, scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        active = AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr
    }

    func remove() {
        guard active else { return }
        AudioObjectRemovePropertyListenerBlock(object, &addr, queue, block)
        active = false
    }

    /// After a coreaudiod restart the registration is gone server-side; forget it without calling remove.
    func abandon() { active = false }

    deinit { remove() }
}

import AppKit
import CoreAudio
import Darwin

/// One Core Audio process object (a process that has an audio connection).
public struct AudioProcessInfo: Hashable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
    /// Bundle ID of the app this process belongs to (itself, or its responsible app).
    public let appBundleID: String
}

/// Maps the user's selected apps (bundle IDs) to the Core Audio process objects that actually
/// render their audio. Browsers render audio in helper processes, so the main PID is not enough.
public enum ProcessResolver {
    /// Browsers offered by default. Prefix match catches their helper processes.
    public static let defaultBrowsers = [
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox",
    ]

    /// Extra bundle-ID prefixes whose processes belong to an app although they don't share its prefix.
    static let extraPrefixes: [String: [String]] = [
        "org.mozilla.firefox": ["org.mozilla.plugincontainer"],
    ]

    // Private API (optional): responsible PID for XPC services such as com.apple.WebKit.GPU.
    private typealias RespFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: RespFn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: RespFn.self)
    }()
    public static var hasResponsibilityAPI: Bool { responsibleFn != nil }

    public static func allProcesses() -> [AudioProcessInfo] {
        CA.ids(CA.system, kAudioHardwarePropertyProcessObjectList).compactMap { obj in
            let pid: pid_t = CA.get(obj, kAudioProcessPropertyPID, default: pid_t(-1))
            guard pid > 0, pid != getpid() else { return nil }
            let bid = CA.string(obj, kAudioProcessPropertyBundleID) ?? ""
            let running = CA.get(obj, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            var app = bid
            if let fn = responsibleFn {
                let rpid = fn(pid)
                if rpid > 0, rpid != pid, let rb = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier {
                    app = rb
                }
            }
            return AudioProcessInfo(objectID: obj, pid: pid, bundleID: bid, isRunningOutput: running, appBundleID: app)
        }
    }

    /// Whether `process` belongs to the app `selected` (bundle-ID prefix, extra prefixes, responsible app).
    public static func belongs(_ process: AudioProcessInfo, to selected: String) -> Bool {
        if process.bundleID == selected || process.bundleID.hasPrefix(selected + ".") { return true }
        if process.appBundleID == selected || process.appBundleID.hasPrefix(selected + ".") { return true }
        for extra in extraPrefixes[selected] ?? [] where process.bundleID.hasPrefix(extra) { return true }
        return false
    }

    public static func resolve(selected: [String], in processes: [AudioProcessInfo]) -> [AudioProcessInfo] {
        processes.filter { p in selected.contains { belongs(p, to: $0) } }
            .sorted { $0.objectID < $1.objectID }
    }
}

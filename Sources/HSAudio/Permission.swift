import Foundation

/// System-audio-capture permission state, read via the private TCC preflight call when available.
/// Pattern after AudioCap (BSD-2-Clause, Guilherme Rambo): `TCCAccessPreflight("kTCCServiceAudioCapture")`.
/// Observed on macOS 27.2 (D-010): while the system prompt is still pending the tap already
/// delivers audio, so non-zero samples alone do NOT prove the grant.
public enum CapturePermission: Equatable, Sendable {
    case granted, denied, undetermined
    /// The private API is missing: callers fall back to the non-zero-sample heuristic.
    case unavailable

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private static let preflightFn: PreflightFn? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        return unsafeBitCast(sym, to: PreflightFn.self)
    }()

    /// Cheap XPC round trip to tccd; call from control threads only, at most every few hundred ms.
    public static func current() -> CapturePermission {
        guard let fn = preflightFn else { return .unavailable }
        switch fn("kTCCServiceAudioCapture" as CFString, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }
}

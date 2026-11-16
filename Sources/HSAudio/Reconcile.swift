import CoreAudio

/// Snapshot of everything that decides what the session should be (read fresh on every reconcile).
public struct WorldSnapshot: Equatable, Sendable {
    public var enabled: Bool
    public var sleeping: Bool
    public var permissionConfirmed: Bool
    public var outputUID: String?
    public var outputAlive: Bool
    public var outputRate: Double
    public var targets: [AudioObjectID]
    public var idle: Bool

    public init(enabled: Bool, sleeping: Bool, permissionConfirmed: Bool, outputUID: String?, outputAlive: Bool,
                outputRate: Double, targets: [AudioObjectID], idle: Bool) {
        self.enabled = enabled; self.sleeping = sleeping; self.permissionConfirmed = permissionConfirmed
        self.outputUID = outputUID; self.outputAlive = outputAlive; self.outputRate = outputRate
        self.targets = targets; self.idle = idle
    }
}

public enum WaitReason: Error, Equatable, Sendable { case disabled, sleeping, noOutput, noTargets, idle }

public enum ReconcileAction: Equatable, Sendable {
    case none
    case stop(WaitReason)
    case start(SessionSpec)
    case restart(SessionSpec)
    case updateTargets([AudioObjectID])
}

/// Pure decision logic, unit-tested without Core Audio.
public enum Reconciler {
    public static func desired(_ w: WorldSnapshot) -> Result<SessionSpec, WaitReason> {
        if !w.enabled { return .failure(.disabled) }
        if w.sleeping { return .failure(.sleeping) }
        guard let uid = w.outputUID, w.outputAlive, w.outputRate > 0 else { return .failure(.noOutput) }
        if w.targets.isEmpty { return .failure(.noTargets) }
        if w.idle { return .failure(.idle) }
        // Until permission is confirmed the tap does not mute: no silence if capture is denied.
        return .success(SessionSpec(outputUID: uid, sampleRate: w.outputRate, muted: w.permissionConfirmed, targets: w.targets))
    }

    public static func plan(current: SessionSpec?, world: WorldSnapshot) -> ReconcileAction {
        switch desired(world) {
        case .failure(let reason):
            return current == nil ? .none : .stop(reason)
        case .success(let want):
            guard let cur = current else { return .start(want) }
            if cur == want { return .none }
            if cur.outputUID == want.outputUID, cur.sampleRate == want.sampleRate, cur.muted == want.muted {
                return .updateTargets(want.targets)
            }
            return .restart(want)
        }
    }
}

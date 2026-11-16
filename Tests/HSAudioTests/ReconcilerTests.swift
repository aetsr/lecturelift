import CoreAudio
@testable import HSAudio
import XCTest

final class ReconcilerTests: XCTestCase {
    func world(enabled: Bool = true, sleeping: Bool = false, perm: Bool = true, uid: String? = "AirPods",
               alive: Bool = true, rate: Double = 48000, targets: [AudioObjectID] = [10, 11], idle: Bool = false) -> WorldSnapshot {
        WorldSnapshot(enabled: enabled, sleeping: sleeping, permissionConfirmed: perm, outputUID: uid, outputAlive: alive,
                      outputRate: rate, targets: targets, idle: idle)
    }

    func testStartsWhenEverythingIsReady() {
        XCTAssertEqual(Reconciler.plan(current: nil, world: world()),
                       .start(SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: true, targets: [10, 11])))
    }

    func testUnconfirmedPermissionRunsUnmuted() {
        guard case .start(let s) = Reconciler.plan(current: nil, world: world(perm: false)) else { return XCTFail() }
        XCTAssertFalse(s.muted)
    }

    func testPermissionConfirmationRestartsMuted() {
        let cur = SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: false, targets: [10, 11])
        XCTAssertEqual(Reconciler.plan(current: cur, world: world()),
                       .restart(SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: true, targets: [10, 11])))
    }

    func testNoChangeIsNoAction() {
        let cur = SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: true, targets: [10, 11])
        XCTAssertEqual(Reconciler.plan(current: cur, world: world()), ReconcileAction.none)
    }

    func testOutputChangeRestarts() {
        let cur = SessionSpec(outputUID: "Speakers", sampleRate: 48000, muted: true, targets: [10, 11])
        guard case .restart(let s) = Reconciler.plan(current: cur, world: world()) else { return XCTFail() }
        XCTAssertEqual(s.outputUID, "AirPods")
    }

    func testRateChangeRestarts() {
        let cur = SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: true, targets: [10, 11])
        guard case .restart = Reconciler.plan(current: cur, world: world(rate: 24000)) else { return XCTFail() }
    }

    func testHelperProcessChangeIsLiveUpdate() {
        let cur = SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: true, targets: [10])
        XCTAssertEqual(Reconciler.plan(current: cur, world: world(targets: [10, 12])), .updateTargets([10, 12]))
    }

    func testStopReasons() {
        let cur = SessionSpec(outputUID: "AirPods", sampleRate: 48000, muted: true, targets: [10, 11])
        XCTAssertEqual(Reconciler.plan(current: cur, world: world(enabled: false)), .stop(.disabled))
        XCTAssertEqual(Reconciler.plan(current: cur, world: world(sleeping: true)), .stop(.sleeping))
        XCTAssertEqual(Reconciler.plan(current: cur, world: world(alive: false)), .stop(.noOutput))
        XCTAssertEqual(Reconciler.plan(current: cur, world: world(targets: [])), .stop(.noTargets))
        XCTAssertEqual(Reconciler.plan(current: cur, world: world(idle: true)), .stop(.idle))
    }

    func testNothingRunningAndNotWantedIsNoAction() {
        XCTAssertEqual(Reconciler.plan(current: nil, world: world(enabled: false)), ReconcileAction.none)
    }

    func testProcessMatching() {
        func p(_ bid: String, app: String? = nil) -> AudioProcessInfo {
            AudioProcessInfo(objectID: 1, pid: 1, bundleID: bid, isRunningOutput: true, appBundleID: app ?? bid)
        }
        XCTAssertTrue(ProcessResolver.belongs(p("com.google.Chrome.helper"), to: "com.google.Chrome"))
        XCTAssertTrue(ProcessResolver.belongs(p("com.google.Chrome"), to: "com.google.Chrome"))
        XCTAssertFalse(ProcessResolver.belongs(p("com.google.ChromeCanary"), to: "com.google.Chrome"))
        XCTAssertTrue(ProcessResolver.belongs(p("com.apple.WebKit.GPU", app: "com.apple.Safari"), to: "com.apple.Safari"))
        XCTAssertFalse(ProcessResolver.belongs(p("com.apple.WebKit.GPU", app: "com.apple.mail"), to: "com.apple.Safari"))
        XCTAssertTrue(ProcessResolver.belongs(p("org.mozilla.plugincontainer"), to: "org.mozilla.firefox"))
        XCTAssertFalse(ProcessResolver.belongs(p("com.spotify.client"), to: "com.google.Chrome"))
    }
}

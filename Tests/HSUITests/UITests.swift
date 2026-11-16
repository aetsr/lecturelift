import AppKit
import HSAudio
import HSCore
@testable import HSUI
import SwiftUI
import XCTest

final class FakeController: SessionControlling {
    var calls: [String] = []
    var status = SessionStatus()
    var overrides: [Int32: Float] = [:]
    func setEnabled(_ on: Bool) { calls.append("enabled=\(on)") }
    func setPreset(_ name: String) { calls.append("preset=\(name)") }
    func setOverrides(_ o: [Int32: Float]) { overrides = o; calls.append("overrides=\(o.count)") }
    func setQualitaet(_ on: Bool, attenuationDb: Float?) { calls.append("qualitaet=\(on)") }
    func setSelectedApps(_ apps: [String]) { calls.append("apps=\(apps.count)") }
    func setABOriginal(_ on: Bool) { calls.append("ab=\(on)") }
    func startCapture(seconds: Double) { calls.append("capture") }
    func currentStatus() -> SessionStatus { status }
    func availableAudioApps() -> [(bundleID: String, name: String)] { [("com.spotify.client", "Spotify")] }
}

@MainActor
final class AppModelTests: XCTestCase {
    func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "hs.test.\(UUID().uuidString)")!
        return d
    }

    func testDefaultsAreClarityAndOff() {
        let f = FakeController()
        let m = AppModel(controller: f, defaults: freshDefaults(), qualitaetAvailable: true, startPolling: false, reconcileLoginItem: false)
        XCTAssertEqual(m.settings.basePreset, .clarity)
        XCTAssertFalse(m.settings.enabled)
        XCTAssertFalse(m.settings.qualitaet)
        XCTAssertTrue(f.calls.contains("preset=clarity"))
    }

    func testSliderMakesCustomAndPresetClearsIt() {
        let f = FakeController()
        let m = AppModel(controller: f, defaults: freshDefaults(), qualitaetAvailable: true, startPolling: false, reconcileLoginItem: false)
        m.set("wet", 0.05)
        XCTAssertTrue(m.settings.isCustom)
        XCTAssertEqual(f.overrides[Int32(HS_P_WET)], 0.05)
        XCTAssertEqual(f.overrides[Int32(HS_P_REVERB_ON)], 1, "a room share > 0 switches the reverb on")
        m.set("wet", 0)
        XCTAssertEqual(f.overrides[Int32(HS_P_REVERB_ON)], 0)
        m.choosePreset(.hall)
        XCTAssertFalse(m.settings.isCustom)
        XCTAssertTrue(f.overrides.isEmpty)
        XCTAssertEqual(m.value("wet"), 0.15, accuracy: 1e-6, "slider shows the preset value")
        m.choosePreset(.clarity)
        XCTAssertEqual(m.value("wet"), 0, "no room in Klarheit → 0 %")
    }

    func testSettingsPersistAcrossLaunches() {
        let d = freshDefaults()
        let m = AppModel(controller: FakeController(), defaults: d, qualitaetAvailable: true, startPolling: false, reconcileLoginItem: false)
        m.choosePreset(.seminar)
        m.set("presence", 4)
        m.update { $0.qualitaet = true; $0.denoiseDb = 18; $0.enabled = true }
        m.setApp("com.spotify.client", selected: true)
        let m2 = AppModel(controller: FakeController(), defaults: d, qualitaetAvailable: true, startPolling: false, reconcileLoginItem: false)
        XCTAssertEqual(m2.settings, m.settings)
    }

    func testQualitaetIsNotRequestedWithoutLibDF() {
        let f = FakeController()
        let m = AppModel(controller: f, defaults: freshDefaults(), qualitaetAvailable: false, startPolling: false, reconcileLoginItem: false)
        m.update { $0.qualitaet = true }
        XCTAssertEqual(f.calls.last, "qualitaet=false")
    }

    func testSettingsDecodeIsForwardCompatible() throws {
        // JSON written by an older version (fields missing) must keep what it has, default the rest
        let old = #"{"enabled":true,"basePreset":"auditorium","overrides":{"wet":0.03}}"#
        let s = try JSONDecoder().decode(ChainSettings.self, from: Data(old.utf8))
        XCTAssertTrue(s.enabled); XCTAssertEqual(s.basePreset, .auditorium); XCTAssertEqual(s.overrides["wet"], 0.03)
        XCTAssertEqual(s.denoiseDb, 12); XCTAssertTrue(s.hotkeyEnabled)
        let unknownPreset = #"{"basePreset":"kathedrale"}"#
        XCTAssertEqual(try JSONDecoder().decode(ChainSettings.self, from: Data(unknownPreset.utf8)).basePreset, .clarity)
    }

    func testLegacyFlagsAreRemovedAfterMigration() {
        let d = freshDefaults()
        d.set(true, forKey: "enabled")
        var s = ChainSettings.load(from: d); XCTAssertTrue(s.enabled)
        s.enabled = false; s.save(to: d)
        XCTAssertNil(d.object(forKey: "enabled"), "legacy flag must not survive (could re-enable tapping)")
        XCTAssertFalse(ChainSettings.load(from: d).enabled)
    }

    func testAppsOverrideIsNotPersisted() {
        let d = freshDefaults(); let f = FakeController()
        let m = AppModel(controller: f, defaults: d, qualitaetAvailable: true, startPolling: false, appsOverride: ["x.test"], reconcileLoginItem: false)
        XCTAssertTrue(f.calls.contains("apps=1"))
        m.setApp("com.spotify.client", selected: true)
        XCTAssertFalse(f.calls.contains("apps=6"), "override wins for this run")
        XCTAssertTrue(ChainSettings.load(from: d).selectedApps.contains("com.spotify.client"))
    }

    func testMigratesOldFlags() {
        let d = freshDefaults()
        d.set(true, forKey: "enabled"); d.set(true, forKey: "qualitaet")
        XCTAssertTrue(ChainSettings.load(from: d).enabled)
        XCTAssertTrue(ChainSettings.load(from: d).qualitaet)
    }
}

/// Every user-visible German string in HSUI/HSApp must exist in the catalog with de + en (DESIGN §11.5).
final class LocalizationTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testAllUIStringsHaveGermanAndEnglish() throws {
        let catURL = Self.root.appendingPathComponent("Sources/HSApp/Resources/Localizable.xcstrings")
        let cat = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catURL)) as? [String: Any])
        let strings = try XCTUnwrap(cat["strings"] as? [String: [String: Any]])
        for (k, v) in strings {
            let loc = v["localizations"] as? [String: Any] ?? [:]
            XCTAssertNotNil(loc["de"], "missing de: \(k)"); XCTAssertNotNil(loc["en"], "missing en: \(k)")
        }
        // literal UI strings in the sources (Text("…"), Button("…"), Toggle("…"), title:/help:, LocalizedStringKey cases)
        var missing: [String] = []
        let pattern = try NSRegularExpression(pattern: #"(?:Text|Button|Label|ProgressView|Toggle)\(\s*"([^"\\]*(?:\\.[^"\\]*)*)"|(?:title|help): "([^"]+)"|case [^:]+: "([^"]+)"|String\(localized: "([^"]+)"\)"#)
        for dir in ["Sources/HSUI", "Sources/HSApp"] {
            let urls = try FileManager.default.contentsOfDirectory(at: Self.root.appendingPathComponent(dir), includingPropertiesForKeys: nil)
            for u in urls where u.pathExtension == "swift" {
                let src = try String(contentsOf: u, encoding: .utf8)
                for m in pattern.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                    for g in 1...4 {
                        guard let r = Range(m.range(at: g), in: src) else { continue }
                        var key = String(src[r])
                        if key.isEmpty || key.contains("%") && !key.contains("%@") && !key.contains("%%") { continue }
                        // interpolations (also with nested parentheses) become a format specifier in the catalog;
                        // compare with all specifiers normalised to one token
                        key = key.replacingOccurrences(of: #"\\\((?:[^()]|\([^()]*\))*\)"#, with: "%@", options: .regularExpression)
                        let norm = { (k: String) in k.replacingOccurrences(of: #"%(?:@|ll[du]|l?[duf]|\.\d+f)"#, with: "§", options: .regularExpression) }
                        let catalog = Set(strings.keys.map(norm))
                        if !["", "⌃⌥H: ein/aus"].contains(key), key.rangeOfCharacter(from: .letters) != nil, !catalog.contains(norm(key)) {
                            missing.append("\(u.lastPathComponent): \(key)")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(missing.isEmpty, "not in Localizable.xcstrings:\n" + missing.sorted().joined(separator: "\n"))
    }
}

/// Renders the menu offscreen (AppKit controls need a real window) to PNGs for visual review.
@MainActor
final class SnapshotTests: XCTestCase {
    func render(_ m: AppModel, dark: Bool, name: String) throws {
        let view = MenuView(model: m)
            .background(Color(nsColor: .windowBackgroundColor))   // the real menu has the system material behind it
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 640)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.backgroundColor = .windowBackgroundColor   // the real menu has the system material behind it
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        host.frame.size = fit; win.setContentSize(fit)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let dir = LocalizationTests.root.appendingPathComponent("build/snapshots")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(fit.height, 300)
    }

    func testRenderMenuStates() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["CI"] == "true", "needs a window-server session")
        let f = FakeController()
        let d = UserDefaults(suiteName: "hs.snap.\(UUID().uuidString)")!
        let m = AppModel(controller: f, defaults: d, qualitaetAvailable: true, startPolling: false, reconcileLoginItem: false)
        m.status.outputName = "AirPods Pro"
        try render(m, dark: false, name: "menu_off_light")
        m.update { $0.enabled = true }
        m.status.state = .active; m.status.muted = true; m.status.latencyMs = 12; m.status.cpuPercent = 1.8
        m.status.peakIn = 0.3; m.status.peakOut = 0.25
        try render(m, dark: false, name: "menu_active_light")
        m.set("wet", 0.05); m.update { $0.qualitaet = true }
        try render(m, dark: true, name: "menu_custom_qualitaet_dark")
        m.status.state = .needsPermission
        try render(m, dark: true, name: "menu_permission_dark")
    }
}

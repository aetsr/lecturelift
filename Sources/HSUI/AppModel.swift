import AppKit
import Foundation
import HSAudio
import ServiceManagement

/// What the UI needs from the audio side (SessionController in the app, a fake in tests).
public protocol SessionControlling: AnyObject {
    func setEnabled(_ on: Bool)
    func setPreset(_ name: String)
    func setOverrides(_ o: [Int32: Float])
    func setQualitaet(_ on: Bool, attenuationDb: Float?)
    func setSelectedApps(_ apps: [String])
    func setABOriginal(_ on: Bool)
    func startCapture(seconds: Double)
    func currentStatus() -> SessionStatus
    func availableAudioApps() -> [(bundleID: String, name: String)]
}

extension SessionController: SessionControlling {}

@MainActor @Observable
public final class AppModel {
    public private(set) var settings: ChainSettings
    public var status = SessionStatus()
    public var abOriginal = false { didSet { controller.setABOriginal(abOriginal) } }
    public var audioApps: [(bundleID: String, name: String)] = []
    public var loginItemError: String?
    public var qualitaetAvailable: Bool
    private let controller: SessionControlling
    private let defaults: UserDefaults
    private var timer: Timer?

    /// DEBUG test hook: tap only these apps for this run (not persisted).
    private let appsOverride: [String]?
    /// Called when the hot-key setting changes (the app delegate registers/unregisters the key).
    public var onHotkeyEnabledChange: ((Bool) -> Void)?

    public init(controller: SessionControlling, defaults: UserDefaults = .standard, qualitaetAvailable: Bool,
                startPolling: Bool = true, appsOverride: [String]? = nil, reconcileLoginItem: Bool = true) {
        self.controller = controller
        self.defaults = defaults
        self.qualitaetAvailable = qualitaetAvailable
        self.appsOverride = appsOverride
        settings = ChainSettings.load(from: defaults)
        if reconcileLoginItem {   // the system is the source of truth for the login item
            let on = SMAppService.mainApp.status == .enabled
            if on != settings.launchAtLogin { settings.launchAtLogin = on; settings.save(to: defaults) }
        }
        applyAll()
        if startPolling {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let st = self.controller.currentStatus()
                    if st != self.status { self.status = st }   // no redraw when nothing changed
                }
            }
        }
    }

    // MARK: - intents

    public func update(_ change: (inout ChainSettings) -> Void) {
        var s = settings
        change(&s)
        guard s != settings else { return }
        let old = settings
        settings = s
        s.save(to: defaults)
        apply(from: old, to: s)
    }

    public func choosePreset(_ p: PresetChoice) {
        update { $0.basePreset = p; $0.overrides = [:] }
    }

    /// Current value of a slider parameter: override, else the base preset's value.
    public func value(_ name: String) -> Float {
        if name == "wet", value("reverb") < 0.5 { return 0 }   // no room active → show 0 %, not the preset's idle value
        return settings.overrides[name] ?? PresetValues.of(settings.basePreset)[name] ?? 0
    }

    /// Moving a slider makes the setting "Custom". Room-related sliders switch the reverb on.
    public func set(_ name: String, _ v: Float) {
        update { s in
            s.overrides[name] = v
            if name == "wet" { s.overrides["reverb"] = v > 0.0005 ? 1 : 0 }
            if name == "room" { s.overrides["reverb"] = 1; if (s.overrides["wet"] ?? PresetValues.of(s.basePreset)["wet"] ?? 0) <= 0 { s.overrides["wet"] = 0.05 } }
            if name == "distance", (s.overrides["reverb"] ?? PresetValues.of(s.basePreset)["reverb"] ?? 0) == 0 { s.overrides["reverb"] = 1; s.overrides["wet"] = s.overrides["wet"] ?? 0.05 }
        }
    }

    public func toggleEnabled() { update { $0.enabled.toggle() } }
    public func refreshApps() { audioApps = controller.availableAudioApps() }
    public func capture() { controller.startCapture(seconds: 60) }

    public func setApp(_ bundleID: String, selected: Bool) {
        update { s in
            if selected { if !s.selectedApps.contains(bundleID) { s.selectedApps.append(bundleID) } }
            else { s.selectedApps.removeAll { $0 == bundleID } }
        }
    }

    // MARK: - applying

    private func applyAll() {
        controller.setPreset(settings.basePreset.rawValue)
        controller.setOverrides(ParamName.engineOverrides(settings.overrides))
        controller.setQualitaet(settings.qualitaet && qualitaetAvailable, attenuationDb: settings.denoiseDb)
        controller.setSelectedApps(appsOverride ?? settings.selectedApps)
        controller.setEnabled(settings.enabled)
    }

    private func apply(from old: ChainSettings, to s: ChainSettings) {
        if s.basePreset != old.basePreset { controller.setPreset(s.basePreset.rawValue) }
        if s.overrides != old.overrides || s.basePreset != old.basePreset { controller.setOverrides(ParamName.engineOverrides(s.overrides)) }
        if s.qualitaet != old.qualitaet || s.denoiseDb != old.denoiseDb {
            controller.setQualitaet(s.qualitaet && qualitaetAvailable, attenuationDb: s.denoiseDb)
        }
        if s.selectedApps != old.selectedApps, appsOverride == nil { controller.setSelectedApps(s.selectedApps) }
        if s.hotkeyEnabled != old.hotkeyEnabled { onHotkeyEnabledChange?(s.hotkeyEnabled) }
        if s.enabled != old.enabled { controller.setEnabled(s.enabled) }
        if s.launchAtLogin != old.launchAtLogin { applyLoginItem(s.launchAtLogin) }
    }

    private func applyLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
            // reflect the real state: the toggle must not stay on (and be persisted) after a failure
            let real = SMAppService.mainApp.status == .enabled
            if real != settings.launchAtLogin { settings.launchAtLogin = real; settings.save(to: defaults) }
        }
    }

    /// Opens the licence notices shipped in the app bundle.
    public func openLicences() {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") { NSWorkspace.shared.open(url) }
    }
}

import AppKit
import Carbon.HIToolbox
import HSAudio
import HSUI
import SwiftUI

@main
struct LectureLiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.status.state == .active ? "building.columns.fill" : "building.columns")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var hotKey: HotKey?
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        let c = SessionController.shared
        #if DEBUG   // developer overrides (test hooks); never in release builds
        let env = ProcessInfo.processInfo.environment
        if env["LECTURELIFT_ENABLE"] == "1" {
            var s = ChainSettings.load(); s.enabled = true; s.save()
        }
        if let p = env["LECTURELIFT_PRESET"], let choice = PresetChoice(rawValue: p) {
            var s = ChainSettings.load(); s.basePreset = choice; s.overrides = [:]; s.save()
        }
        let appsOverride = env["LECTURELIFT_APPS"]?.split(separator: ",").map(String.init)
        c.start(selectedApps: appsOverride ?? ChainSettings.load().selectedApps)
        #else
        let appsOverride: [String]? = nil
        c.start(selectedApps: ChainSettings.load().selectedApps)
        #endif
        model = AppModel(controller: c, qualitaetAvailable: SessionController.denoiserResources() != nil, appsOverride: appsOverride)
        super.init()
        model.onHotkeyEnabledChange = { [weak self] on in self?.setHotKey(on) }
        setHotKey(model.settings.hotkeyEnabled)
        // SIGTERM/SIGINT via DispatchSource: tear down cleanly, then exit (no HAL IPC in a raw handler)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { SessionController.shared.shutdown(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
    }

    /// ⌃⌥H toggles LectureLift (Carbon hot key: no Accessibility permission needed). Unregistered when
    /// disabled, so the key combination is free for other apps (Fable M5 #7).
    private func setHotKey(_ on: Bool) {
        if on, hotKey == nil {
            hotKey = HotKey(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
                self?.model.toggleEnabled()
            }
        } else if !on {
            hotKey = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SessionController.shared.shutdown()
    }
}

/// Minimal Carbon global hot key.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let st = InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
            guard let ctx else { return noErr }
            let hk = Unmanaged<HotKey>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { hk.action() }
            return noErr
        }, 1, &spec, me, &handler)
        guard st == noErr else { return nil }
        let id = EventHotKeyID(signature: OSType(0x4853_4C48), id: 1)   // 'HSLH'
        guard RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else { return nil }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}

import AppKit
import HSAudio
import SwiftUI

/// The menu-bar popover (DESIGN §10). German source strings; English via the app's string catalog.
public struct MenuView: View {
    @Bindable var model: AppModel
    @State private var showApps = false
    @State private var showSettings = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.status.state == .needsPermission { PermissionCard() }
            if model.settings.enabled { abSwitch }
            presetPicker
            sliders
            Divider()
            meters
            DisclosureGroup(isExpanded: $showApps) { appList } label: { Text("Apps").font(.subheadline.weight(.medium)) }
                .onChange(of: showApps) { _, open in if open { model.refreshApps() } }
            DisclosureGroup(isExpanded: $showSettings) { settingsList } label: { Text("Einstellungen").font(.subheadline.weight(.medium)) }
            Divider()
            HStack {
                Text("⌃⌥H: ein/aus").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onDisappear { model.abOriginal = false }   // never leave A/B on "Original" unnoticed
    }

    // MARK: header / status

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "building.columns.fill").foregroundStyle(model.settings.enabled ? Color.accentColor : .secondary)
                Text("LectureLift").font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { model.settings.enabled }, set: { v in model.update { $0.enabled = v } }))
                    .toggleStyle(.switch).labelsHidden()
                    .help(Text("LectureLift ein- oder ausschalten"))
            }
            Text(stateText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stateText: LocalizedStringKey {
        switch model.status.state {
        case .off: "Aus – Originalton"
        case .active: model.abOriginal ? "Vergleich: Originalton" : (model.status.muted ? "Aktiv" : "Aktiv (Berechtigung wird geprüft)")
        case .needsPermission: "Keine Berechtigung"
        case .reconnecting: "Neu verbinden …"
        case .failed(let e): "Fehler: \(e)"
        case .waiting(let r):
            switch r {
            case .idle, .noTargets: "Wartet auf Audio"
            case .noOutput: "Kein Ausgabegerät"
            case .sleeping: "Ruhezustand"
            case .disabled: "Aus – Originalton"
            }
        }
    }

    private var abSwitch: some View {
        Picker("", selection: $model.abOriginal) {
            Text("Original").tag(true)
            Text("LectureLift").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden()
        .help(Text("Sofortiger Vergleich mit dem unbearbeiteten Ton (zeitgleich, ohne Klicken)"))
    }

    // MARK: presets / sliders

    private var presetPicker: some View {
        HStack {
            Text("Voreinstellung").font(.subheadline)
            Spacer()
            Menu {
                ForEach(PresetChoice.allCases) { p in
                    Button { model.choosePreset(p) } label: { Text(presetName(p)) }
                }
            } label: {
                Text(model.settings.isCustom ? LocalizedStringKey("Eigene (\(presetNameString(model.settings.basePreset)))") : presetName(model.settings.basePreset))
            }
            .fixedSize()
        }
    }

    private func presetName(_ p: PresetChoice) -> LocalizedStringKey {
        switch p {
        case .off: "Aus"
        case .clarity: "Nur Klarheit"
        case .seminar: "Seminarraum"
        case .hall: "Hörsaal (Raum)"
        case .auditorium: "Audimax"
        }
    }

    private func presetNameString(_ p: PresetChoice) -> String {
        switch p {
        case .off: String(localized: "Aus")
        case .clarity: String(localized: "Nur Klarheit")
        case .seminar: String(localized: "Seminarraum")
        case .hall: String(localized: "Hörsaal (Raum)")
        case .auditorium: String(localized: "Audimax")
        }
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: 8) {
            ParamSlider(title: "Präsenz", help: "Hebt die Sprachverständlichkeit (2–4 kHz) an",
                        value: model.value("presence"), range: 0...6, format: "%.1f dB") { model.set("presence", $0) }
            ParamSlider(title: "Raumanteil", help: "Wie viel Raumklang hinzugefügt wird (0 = kein Raum)",
                        value: model.value("wet") * 100, range: 0...40, format: "%.0f %%") { model.set("wet", $0 / 100) }
            VStack(alignment: .leading, spacing: 3) {
                Text("Raumgröße").font(.caption)
                Picker("", selection: Binding(get: { Int(model.value("room")) }, set: { model.set("room", Float($0)) })) {
                    Text("Seminarraum").tag(0); Text("Hörsaal (Raum)").tag(1); Text("Audimax").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help(Text("Nachhallzeit 0,5 / 1,0 / 1,6 s"))
            }
            ParamSlider(title: "Distanz", help: "Sprecher klingt weiter entfernt (etwas dumpfer, mehr Raum)",
                        value: model.value("distance") * 100, range: 0...100, format: "%.0f %%") { model.set("distance", $0 / 100) }
            Toggle(isOn: Binding(get: { model.settings.qualitaet }, set: { v in model.update { $0.qualitaet = v } })) {
                Text("Entrauschen (Qualität)").font(.caption)
            }
            .disabled(!model.qualitaetAvailable)
            .help(Text("DeepFilterNet3 entfernt Rauschen und etwas Nachhall. Mehr Rechenlast (bis 12 %) und ca. 60 ms zusätzliche Verzögerung."))
            if model.settings.qualitaet, model.status.state == .active, model.status.sampleRate > 0, model.status.sampleRate != 48000 {
                Text("Entrauschen ist nur bei 48 kHz aktiv (Ausgabegerät läuft mit \(Int(model.status.sampleRate)) Hz).")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if model.settings.qualitaet {
                ParamSlider(title: "Stärke", help: "Maximale Absenkung von Rauschen (höher = stärker, kann die Stimme angreifen)",
                            value: model.settings.denoiseDb, range: 6...30, format: "%.0f dB") { v in model.update { $0.denoiseDb = v.rounded() } }
            }
        }
    }

    // MARK: meters

    private var meters: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
            GridRow { Text("Ausgabe"); Text(model.status.outputName.isEmpty ? "–" : model.status.outputName).lineLimit(1) }
            GridRow { Text("Pegel"); HStack(spacing: 4) { LevelBar(value: model.status.peakIn); LevelBar(value: model.status.peakOut) } }
            GridRow { Text("Latenz"); Text(model.status.state == .active ? String(format: "≈ %.0f ms", model.status.latencyMs) : "–") }
            GridRow { Text("CPU"); Text(model.status.state == .active ? String(format: "%.1f %%", model.status.cpuPercent) : "–") }
            GridRow {
                Text("Aussetzer")
                if model.status.dnUnderflows > 0 {
                    Text("\(model.status.xruns) · Entrauschen \(model.status.dnUnderflows)")
                } else {
                    Text(verbatim: "\(model.status.xruns)")
                }
            }
        }
        .font(.caption)
        .help(Text("Latenz = zusätzliche Verzögerung durch LectureLift; Aussetzer = Audio-Unterbrechungen"))
    }

    // MARK: apps / settings

    private var appList: some View {
        VStack(alignment: .leading, spacing: 4) {
            let known: [(String, String)] = [("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari"),
                                             ("company.thebrowser.Browser", "Arc"), ("org.mozilla.firefox", "Firefox")]
            let extra = model.audioApps.filter { a in !known.contains { $0.0 == a.bundleID } }.map { ($0.bundleID, $0.name) }
            // selected apps stay visible (deselectable) even when they have no audio connection right now
            let selectedOnly = model.settings.selectedApps
                .filter { b in !known.contains { $0.0 == b } && !extra.contains { $0.0 == b } }
                .map { b in (b, NSWorkspace.shared.urlForApplication(withBundleIdentifier: b).map { FileManager.default.displayName(atPath: $0.path) } ?? b) }
            ForEach(known + extra + selectedOnly, id: \.0) { app in
                Toggle(app.1, isOn: Binding(get: { model.settings.selectedApps.contains(app.0) },
                                            set: { model.setApp(app.0, selected: $0) }))
                    .font(.caption)
            }
            Text("Nur die gewählten Apps werden bearbeitet; alle anderen bleiben unverändert.").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var settingsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.settings.launchAtLogin }, set: { v in model.update { $0.launchAtLogin = v } })) {
                Text("Bei Anmeldung starten").font(.caption)
            }
            if let e = model.loginItemError { Text(verbatim: e).font(.caption2).foregroundStyle(.red) }
            Toggle(isOn: Binding(get: { model.settings.hotkeyEnabled }, set: { v in model.update { $0.hotkeyEnabled = v } })) {
                Text("Tastenkürzel ⌃⌥H").font(.caption)
            }
            if let p = model.status.captureProgress {
                ProgressView(value: p) { Text("Nehme Originalton auf …") }.font(.caption)
            } else {
                Button("60 s Originalton aufnehmen") { model.capture() }
                    .disabled(model.status.state != .active)
                    .help(Text("Speichert 60 s des unbearbeiteten Browser-Tons lokal (Musik/LectureLift Clips), z. B. für den Hörvergleich. Wird nie hochgeladen."))
                    .font(.caption)
            }
            Button("Lizenzen und Danksagungen") { model.openLicences() }.font(.caption)
            if let c = model.status.lastCapture {
                Text(c.hasPrefix("!") ? "Aufnahme fehlgeschlagen: \(String(c.dropFirst()))" : "Gespeichert: \((c as NSString).lastPathComponent)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

/// Onboarding when the system-audio permission is missing (D-010: never mutes while undetermined).
struct PermissionCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label { Text("Berechtigung nötig").font(.subheadline.weight(.semibold)) } icon: { Image(systemName: "lock.shield") }
            Text("LectureLift braucht die Berechtigung „Bildschirm- & Systemaudioaufnahme“. Bis dahin hörst du den Originalton.")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Systemeinstellungen öffnen") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.orange.opacity(0.12)))
    }
}

struct ParamSlider: View {
    let title: LocalizedStringKey
    let help: LocalizedStringKey
    let value: Float
    let range: ClosedRange<Float>
    let format: String
    let onChange: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .controlSize(.small)
        }
        .help(Text(help))
    }
}

struct LevelBar: View {
    let value: Float
    var body: some View {
        let db = 20 * log10(max(Double(value), 1e-5))
        let frac = max(0, min(1, (db + 60) / 60))
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(db > -3 ? Color.red : Color.green).frame(width: g.size.width * frac)
            }
        }
        .frame(width: 90, height: 6)
    }
}

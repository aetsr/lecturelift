import Foundation
import HSCore

/// Named presets of the chain (HSCore names). "Custom" = a named base preset plus overrides.
public enum PresetChoice: String, CaseIterable, Codable, Sendable, Identifiable {
    case off, clarity, seminar, hall, auditorium
    public var id: String { rawValue }
}

/// Everything the user can set; persisted as JSON in UserDefaults ("settings.v1").
public struct ChainSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var basePreset: PresetChoice = .clarity          // D-018/D-023: Klarheit is the default
    public var overrides: [String: Float] = [:]                // parameter name → value ("Custom")
    public var qualitaet = false                               // DeepFilterNet3 (optional, D-023)
    public var denoiseDb: Float = 12
    public var selectedApps: [String] = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "org.mozilla.firefox"]
    public var hotkeyEnabled = true
    public var launchAtLogin = false

    public init() {}
    public var isCustom: Bool { !overrides.isEmpty }

    // Forward-compatible decoding: a field added later must not reset all settings (Fable M5 #3).
    enum CodingKeys: String, CodingKey { case enabled, basePreset, overrides, qualitaet, denoiseDb, selectedApps, hotkeyEnabled, launchAtLogin }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ChainSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        basePreset = (try? c.decodeIfPresent(PresetChoice.self, forKey: .basePreset)) ?? d.basePreset
        overrides = try c.decodeIfPresent([String: Float].self, forKey: .overrides) ?? d.overrides
        qualitaet = try c.decodeIfPresent(Bool.self, forKey: .qualitaet) ?? d.qualitaet
        denoiseDb = try c.decodeIfPresent(Float.self, forKey: .denoiseDb) ?? d.denoiseDb
        selectedApps = try c.decodeIfPresent([String].self, forKey: .selectedApps) ?? d.selectedApps
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
    }

    static let key = "settings.v1"

    public static func load(from d: UserDefaults = .standard) -> ChainSettings {
        guard let data = d.data(forKey: key), let s = try? JSONDecoder().decode(ChainSettings.self, from: data) else {
            var s = ChainSettings()
            s.enabled = d.bool(forKey: "enabled")          // migrate the M1–M4 flags
            s.qualitaet = d.bool(forKey: "qualitaet")
            return s
        }
        return s
    }

    public func save(to d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
        // migrated: the legacy flags must never be read again (they could re-enable tapping)
        d.removeObject(forKey: "enabled"); d.removeObject(forKey: "qualitaet")
    }
}

/// Engine parameter ids for the names used in `ChainSettings.overrides`.
public enum ParamName {
    public static let ids: [String: Int32] = [
        "presence": Int32(HS_P_PRESENCE_DB), "wet": Int32(HS_P_WET), "room": Int32(HS_P_ROOM),
        "distance": Int32(HS_P_DISTANCE), "reverb": Int32(HS_P_REVERB_ON), "predelay": Int32(HS_P_PREDELAY_MS),
        "deessmax": Int32(HS_P_DEESS_MAX_DB), "levelstrength": Int32(HS_P_LEVEL_STRENGTH),
    ]

    public static func engineOverrides(_ o: [String: Float]) -> [Int32: Float] {
        var out: [Int32: Float] = [:]
        for (k, v) in o { if let id = ids[k] { out[id] = v } }
        return out
    }
}

/// Parameter values of a named preset, read from a scratch engine (control thread, allocates).
public enum PresetValues {
    private static var cache: [PresetChoice: [String: Float]] = [:]

    public static func of(_ p: PresetChoice) -> [String: Float] {
        if let c = cache[p] { return c }
        guard let e = hs_engine_create() else { return [:] }
        defer { hs_engine_destroy(e) }
        hs_engine_apply_preset(e, p.rawValue)
        var v: [String: Float] = [:]
        for (name, id) in ParamName.ids { v[name] = hs_engine_get_param(e, id) }
        cache[p] = v
        return v
    }
}

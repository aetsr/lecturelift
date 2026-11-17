import AppKit
import HSAudio
@testable import HSUI
import ObjectiveC
import SwiftUI
import XCTest

/// Regenerates the README images in docs/images (menu screenshots in English, social preview).
/// Only runs on request:  LECTURELIFT_DOC_IMAGES=1 swift test --filter DocImages
/// Uses a fake controller: no audio device, no tap, no sound.
@MainActor
final class DocImages: XCTestCase {
    static var outDir: URL { LocalizationTests.root.appendingPathComponent("docs/images") }

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LECTURELIFT_DOC_IMAGES"] == "1", "doc images only on request")
        EnglishStrings.install()
    }

    /// Renders `view` offscreen at `scale` × its fitting size (or `size`) into a PNG.
    @discardableResult
    func png(_ view: some View, dark: Bool, name: String, scale: CGFloat = 2, size: NSSize? = nil) throws -> NSImage {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.locale, Locale(identifier: "en")).environment(\.controlActiveState, .key))
        let win = KeyLookingWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        win.isOpaque = false; win.backgroundColor = .clear
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        let fit = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fit); win.setContentSize(fit)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(fit.width * scale), pixelsHigh: Int(fit.height * scale),
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = fit
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: Self.outDir.appendingPathComponent("\(name).png"))
        let img = NSImage(size: fit); img.addRepresentation(rep)
        return img
    }

    /// The menu as it appears in the menu-bar popover: rounded panel, window material colour.
    func panel(_ m: AppModel) -> some View {
        MenuView(model: m)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            .padding(1)
    }

    func model(active: Bool) -> AppModel {
        let m = AppModel(controller: FakeController(), defaults: UserDefaults(suiteName: "hs.doc.\(UUID().uuidString)")!,
                         qualitaetAvailable: true, startPolling: false, reconcileLoginItem: false)
        m.update { $0.enabled = true }
        m.status.outputName = "MacBook Pro Speakers"
        if active {
            m.status.state = .active; m.status.muted = true
            m.status.latencyMs = 7; m.status.cpuPercent = 1.6
            m.status.peakIn = 0.22; m.status.peakOut = 0.35
        } else {
            m.status.state = .needsPermission
        }
        return m
    }

    func testRenderDocImages() throws {
        var mainDark: NSImage?
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let img = try png(panel(model(active: true)), dark: dark, name: "menu-\(suffix)")
            if dark { mainDark = img }
            try png(panel(model(active: false)), dark: dark, name: "permission-\(suffix)")
        }
        try png(SocialCard(screenshot: try XCTUnwrap(mainDark)), dark: true, name: "social-preview",
                scale: 1, size: NSSize(width: 1280, height: 640))
    }
}

/// Draws controls in their active (key-window) look without ever becoming key or taking focus.
final class KeyLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// 1280 × 640 social preview: name, pitch, screenshot.
struct SocialCard: View {
    let screenshot: NSImage
    var body: some View {
        HStack(spacing: 56) {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 18) {
                    Image(systemName: "building.columns.fill").font(.system(size: 54, weight: .semibold)).foregroundStyle(.tint)
                    Text(verbatim: "LectureLift").font(.system(size: 76, weight: .bold))
                }
                Text(verbatim: "Clearer, steadier lecture audio on your Mac — live and per app, with no virtual audio driver.")
                    .font(.system(size: 32, weight: .regular)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "macOS 14.4+ · Apple Silicon · Core Audio process taps · MIT")
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(nsImage: screenshot).resizable().interpolation(.high).scaledToFit()
                .frame(height: 560).shadow(color: .black.opacity(0.5), radius: 24, y: 8)
        }
        .padding(.horizontal, 72)
        .frame(width: 1280, height: 640)
        .background(LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.15), Color(red: 0.05, green: 0.06, blue: 0.09)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .foregroundStyle(.white)
    }
}

/// Test-only: answer Bundle string lookups from the catalog's English column, so the views
/// render in English inside the test runner (which has no app bundle with .lproj tables).
enum EnglishStrings {
    nonisolated(unsafe) static var table: [String: String] = [:]
    nonisolated(unsafe) static var installed = false

    static func install() {
        guard !installed else { return }
        let url = LocalizationTests.root.appendingPathComponent("Sources/HSApp/Resources/Localizable.xcstrings")
        if let data = try? Data(contentsOf: url),
           let cat = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let strings = cat["strings"] as? [String: [String: Any]] {
            for (k, v) in strings {
                if let en = ((v["localizations"] as? [String: Any])?["en"] as? [String: Any])?["stringUnit"] as? [String: Any],
                   let value = en["value"] as? String { table[k] = value }
            }
        }
        hook3("localizedStringForKey:value:table:")
        hook4("localizedStringForKey:value:table:localization:")
        hook4("localizedStringForKey:value:table:localizations:")
        hook4("_localizedStringForKey:value:table:localizations:")
        hook6("_localizedStringForKey:value:table:bundleLocalizations:localization:preventMarkdownParsing:")
        hookAttr3("localizedAttributedStringForKey:value:table:")
        hookAttr4("localizedAttributedStringForKey:value:table:localization:")
        installed = true
    }

    private static func method(_ name: String) -> Method? { class_getInstanceMethod(Bundle.self, NSSelectorFromString(name)) }

    private static func hook3(_ name: String) {
        guard let m = method(name) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSString
        let orig = unsafeBitCast(method_getImplementation(m), to: Original.self); let sel = method_getName(m)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSString = { b, k, v, t in
            table[k as String].map { $0 as NSString } ?? orig(b, sel, k, v, t)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hook4(_ name: String) {
        guard let m = method(name) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSString
        let orig = unsafeBitCast(method_getImplementation(m), to: Original.self); let sel = method_getName(m)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> NSString = { b, k, v, t, l in
            table[k as String].map { $0 as NSString } ?? orig(b, sel, k, v, t, l)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hook6(_ name: String) {
        guard let m = method(name) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?, AnyObject?, Bool) -> NSString
        let orig = unsafeBitCast(method_getImplementation(m), to: Original.self); let sel = method_getName(m)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?, AnyObject?, Bool) -> NSString = { b, k, v, t, bl, l, p in
            table[k as String].map { $0 as NSString } ?? orig(b, sel, k, v, t, bl, l, p)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hookAttr3(_ name: String) {
        guard let m = method(name) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?) -> NSAttributedString
        let orig = unsafeBitCast(method_getImplementation(m), to: Original.self); let sel = method_getName(m)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?) -> NSAttributedString = { b, k, v, t in
            table[k as String].map { NSAttributedString(string: $0) } ?? orig(b, sel, k, v, t)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    private static func hookAttr4(_ name: String) {
        guard let m = method(name) else { return }
        typealias Original = @convention(c) (AnyObject, Selector, NSString, NSString?, NSString?, AnyObject?) -> NSAttributedString
        let orig = unsafeBitCast(method_getImplementation(m), to: Original.self); let sel = method_getName(m)
        let block: @convention(block) (AnyObject, NSString, NSString?, NSString?, AnyObject?) -> NSAttributedString = { b, k, v, t, l in
            table[k as String].map { NSAttributedString(string: $0) } ?? orig(b, sel, k, v, t, l)
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
}

import AppKit
import Observation
import SwiftUI

// Appearance personalization: theme colors (light + dark), shape and type scale, and the per-surface
// Liquid Glass breakdown. Everything is stored as plain UserDefaults preferences and registered in
// `CustomizationRegistry`, so people (Settings → Appearance) and agents (preview/undo) change the same values.
// Views read it through `AxolotlSurface` / `ThemeStore.shared`, which SwiftUI observes.

/// A themable color. Each has a light and a dark variant.
enum ThemeColorToken: String, CaseIterable, Identifiable {
    case accent, window, sidebar, toolbar, activeTab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accent: return "Accent"
        case .window: return "Window background"
        case .sidebar: return "Sidebar background"
        case .toolbar: return "Tab strip and toolbar"
        case .activeTab: return "Active tab"
        }
    }

    var summary: String {
        switch self {
        case .accent: return "Highlights, switches, focus rings and selected items."
        case .window: return "The window backdrop behind tabs and pages."
        case .sidebar: return "The sidebar when it floats over the page."
        case .toolbar: return "The tab strip / title bar behind the tabs (top layouts)."
        case .activeTab: return "The selected tab, and the toolbar under it in the Chrome layout."
        }
    }

    func defaultsKey(dark: Bool) -> String { "axolotl_theme_\(rawValue)_\(dark ? "dark" : "light")" }
    func registryKey(dark: Bool) -> String { "theme.\(rawValue).\(dark ? "dark" : "light")" }
}

struct ThemeColorPair: Equatable {
    var light: UInt32
    var dark: UInt32

    func hex(dark isDark: Bool) -> UInt32 { isDark ? dark : light }
    var color: Color { Color(light: .axolotlHex(light), dark: .axolotlHex(dark)) }
}

/// Ready-made color sets. "Custom" is any set that matches none of them.
enum ThemePreset: String, CaseIterable, Identifiable {
    case axolotl, chrome, graphite, ocean, sand, rose

    static let customValue = "custom"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .axolotl: return "Axolotl"
        case .chrome: return "Chrome"
        case .graphite: return "Graphite"
        case .ocean: return "Ocean"
        case .sand: return "Sand"
        case .rose: return "Rose"
        }
    }

    func color(_ token: ThemeColorToken) -> ThemeColorPair {
        let p: (UInt32, UInt32)
        switch (self, token) {
        case (.axolotl, .accent): p = (0x0A84FF, 0x0A84FF)
        case (.axolotl, .window): p = (0xECECEE, 0x1C1C1E)
        case (.axolotl, .sidebar): p = (0xF5F5F7, 0x242426)
        case (.axolotl, .toolbar): p = (0xECECEE, 0x1C1C1E)
        case (.axolotl, .activeTab): p = (0xFFFFFF, 0x3A3A3D)
        // Chrome 155's default theme (see ChromePalette): frame, toolbar/active tab, star blue.
        case (.chrome, .accent): p = (0x3265CB, 0x729CEF)
        case (.chrome, .window): p = (0xD6E2FB, 0x1F2020)
        case (.chrome, .sidebar): p = (0xFFFFFF, 0x3C3C3C)
        case (.chrome, .toolbar): p = (0xD6E2FB, 0x1F2020)
        case (.chrome, .activeTab): p = (0xFFFFFF, 0x3C3C3C)
        case (.graphite, .accent): p = (0x5E5E66, 0xB4B4BE)
        case (.graphite, .window): p = (0xE3E3E6, 0x161618)
        case (.graphite, .sidebar): p = (0xEDEDF0, 0x1E1E21)
        case (.graphite, .toolbar): p = (0xDCDCE0, 0x131315)
        case (.graphite, .activeTab): p = (0xFAFAFB, 0x2E2E32)
        case (.ocean, .accent): p = (0x0E7C86, 0x3CC6CF)
        case (.ocean, .window): p = (0xE4EEF1, 0x0F1C21)
        case (.ocean, .sidebar): p = (0xEEF5F7, 0x142328)
        case (.ocean, .toolbar): p = (0xD9E8EC, 0x0B171B)
        case (.ocean, .activeTab): p = (0xFFFFFF, 0x1F343B)
        case (.sand, .accent): p = (0xB5651D, 0xE39A55)
        case (.sand, .window): p = (0xF1ECE4, 0x1E1A16)
        case (.sand, .sidebar): p = (0xF7F3EC, 0x26211C)
        case (.sand, .toolbar): p = (0xEAE3D8, 0x1A1612)
        case (.sand, .activeTab): p = (0xFFFDF9, 0x362F28)
        case (.rose, .accent): p = (0xC2185B, 0xF48FB1)
        case (.rose, .window): p = (0xF4E9EC, 0x1F171A)
        case (.rose, .sidebar): p = (0xF9F0F2, 0x281D21)
        case (.rose, .toolbar): p = (0xEFDFE4, 0x1A1316)
        case (.rose, .activeTab): p = (0xFFFFFF, 0x3A2A30)
        }
        return ThemeColorPair(light: p.0, dark: p.1)
    }
}

/// Swatches offered for each color (pickers, never typed IDs; the hex field is optional).
enum ThemeSwatches {
    static let accents: [ThemeColorPair] = [
        .init(light: 0x0A84FF, dark: 0x0A84FF), .init(light: 0x5E5CE6, dark: 0x7D7AFF), .init(light: 0xBF5AF2, dark: 0xDA8FFF),
        .init(light: 0xC2185B, dark: 0xF48FB1), .init(light: 0xFF453A, dark: 0xFF6961), .init(light: 0xB5651D, dark: 0xE39A55),
        .init(light: 0x30A46C, dark: 0x4CC38A), .init(light: 0x0E7C86, dark: 0x3CC6CF), .init(light: 0x5E5E66, dark: 0xB4B4BE),
    ]

    /// Background swatches for a surface: every preset's value, without repeats.
    static func backgrounds(_ token: ThemeColorToken) -> [ThemeColorPair] {
        var out: [ThemeColorPair] = []
        for p in ThemePreset.allCases where !out.contains(p.color(token)) { out.append(p.color(token)) }
        return out
    }
}

nonisolated enum ThemeHex {
    /// "#RRGGBB" or "RRGGBB" (six hex digits) → value.
    static func parse(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(s, radix: 16)
    }

    static func format(_ v: UInt32) -> String { String(format: "#%06X", v & 0xFFFFFF) }
}

/// Everything the theme controls, resolved from preferences.
struct Theme: Equatable {
    var colors: [ThemeColorToken: ThemeColorPair]
    var highContrast = false
    /// Corner radius scale, percent.
    var radiusScale = 100
    var compact = false
    /// Interface text scale, percent.
    var fontScale = 100

    static let contrastKey = "axolotl_theme_contrast"
    static let radiusKey = "axolotl_theme_radius"
    static let densityKey = "axolotl_theme_density"
    static let fontScaleKey = "axolotl_theme_font_scale"
    static var defaultsKeys: [String] {
        ThemeColorToken.allCases.flatMap { [$0.defaultsKey(dark: false), $0.defaultsKey(dark: true)] }
            + [contrastKey, radiusKey, densityKey, fontScaleKey]
    }

    static let axolotl = Theme(colors: Dictionary(uniqueKeysWithValues: ThemeColorToken.allCases.map { ($0, ThemePreset.axolotl.color($0)) }))

    static func load(_ d: UserDefaults) -> Theme {
        var t = Theme.axolotl
        for token in ThemeColorToken.allCases {
            var pair = ThemePreset.axolotl.color(token)
            if let v = d.string(forKey: token.defaultsKey(dark: false)).flatMap(ThemeHex.parse) { pair.light = v }
            if let v = d.string(forKey: token.defaultsKey(dark: true)).flatMap(ThemeHex.parse) { pair.dark = v }
            t.colors[token] = pair
        }
        t.highContrast = d.string(forKey: contrastKey) == "high"
        t.compact = d.string(forKey: densityKey) == "compact"
        if d.object(forKey: radiusKey) != nil { t.radiusScale = d.integer(forKey: radiusKey) }
        if d.object(forKey: fontScaleKey) != nil { t.fontScale = d.integer(forKey: fontScaleKey) }
        return t
    }

    func pair(_ token: ThemeColorToken) -> ThemeColorPair { colors[token] ?? ThemePreset.axolotl.color(token) }
    func color(_ token: ThemeColorToken) -> Color { pair(token).color }

    /// The preset whose colors these are, or nil (Custom).
    var preset: ThemePreset? {
        ThemePreset.allCases.first { p in ThemeColorToken.allCases.allSatisfy { pair($0) == p.color($0) } }
    }

    func radius(_ base: CGFloat) -> CGFloat { (base * CGFloat(radiusScale) / 100).rounded() }
    func font(_ base: CGFloat) -> CGFloat { base * CGFloat(fontScale) / 100 }
}

// MARK: - Liquid Glass breakdown

/// Parts of the window that can use Liquid Glass on their own. The master switch (`LiquidGlass`) gates them all.
enum GlassSurface: String, CaseIterable, Identifiable {
    case sidebar, toolbar, menus, popovers, aiPanel, settings, startPage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .toolbar: return "Tab strip and toolbar"
        case .menus: return "Menus and dropdowns"
        case .popovers: return "Popovers and floating panels"
        case .aiPanel: return "AI panel"
        case .settings: return "Settings sidebar"
        case .startPage: return "Start page"
        }
    }

    var summary: String {
        switch self {
        case .sidebar: return "The tab sidebar's backdrop."
        case .toolbar: return "The window backdrop in top-tab layouts and dragged tabs."
        case .menus: return "Pop-up menus in Settings and panels (off: Axolotl's own solid menus)."
        case .popovers: return "Popovers, link previews, Ask on Page, password bars, split view labels, address suggestions, profile badge."
        case .aiPanel: return "The AI panel, its cards and the command bar."
        case .settings: return "The Settings page's sidebar."
        case .startPage: return "The start page backdrop, search box and tiles."
        }
    }

    var defaultsKey: String { "axolotl_glass_\(rawValue)" }
    var registryKey: String { "glass.\(rawValue)" }
}

struct GlassSettings: Equatable {
    var master = LiquidGlass.defaultValue
    var off: Set<GlassSurface> = []
    /// Frosted (blurred) glass; off = clear glass.
    var blur = true
    /// How much of the theme color shows through glass, percent.
    var tint = 0

    static let blurKey = "axolotl_glass_blur"
    static let tintKey = "axolotl_glass_tint"
    static var defaultsKeys: [String] {
        [LiquidGlass.defaultsKey, blurKey, tintKey] + GlassSurface.allCases.map(\.defaultsKey)
    }

    static func load(_ d: UserDefaults) -> GlassSettings {
        var g = GlassSettings()
        if d.object(forKey: LiquidGlass.defaultsKey) != nil { g.master = d.bool(forKey: LiquidGlass.defaultsKey) }
        g.off = Set(GlassSurface.allCases.filter { d.object(forKey: $0.defaultsKey) != nil && !d.bool(forKey: $0.defaultsKey) })
        if d.object(forKey: blurKey) != nil { g.blur = d.bool(forKey: blurKey) }
        g.tint = d.integer(forKey: tintKey)
        return g
    }

    /// Master off = every surface off; master on = the surface's own choice. nil = master only.
    func isOn(_ surface: GlassSurface?) -> Bool { master && !(surface.map(off.contains) ?? false) }
}

// MARK: - Store

/// The live theme and glass settings, re-read when preferences change. SwiftUI views that read it re-render.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var theme: Theme
    private(set) var glass: GlassSettings
    /// Offscreen renders set a theme directly and stop following preferences.
    @ObservationIgnored private var pinned = false
    @ObservationIgnored private var observer: DefaultsObserver?

    private init() {
        theme = .load(.standard)
        glass = .load(.standard)
        // Only theme and glass keys: other preference writes don't re-read them.
        observer = DefaultsObserver(keys: Theme.defaultsKeys + GlassSettings.defaultsKeys) { ThemeStore.shared.reload() }
    }

    func reload() {
        guard !pinned else { return }
        let t = Theme.load(.standard), g = GlassSettings.load(.standard)
        // Assign only on change: views re-render only for a real difference.
        if t != theme { theme = t }
        if g != glass { glass = g }
    }

    /// Offscreen snapshots only: show `theme` / `glass` without touching preferences.
    func pin(theme: Theme? = nil, glass: GlassSettings? = nil) {
        pinned = true
        if let theme { self.theme = theme }
        if let glass { self.glass = glass }
    }
}

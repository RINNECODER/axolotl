// Axolotl — start page wallpapers: presets, palettes and the settings that drive them.
// The shaders themselves live in Wallpaper/WallpaperWeb (WebGPU, bundled, offline).
import Foundation
import Combine

enum WallpaperPrefs {
    static let preset = "axolotl_wallpaper_preset"
    static let styles = "axolotl_wallpaper_styles"
    static let frameRate = "axolotl_wallpaper_fps"
    static let showMoon = "axolotl_wallpaper_show_moon"
    static let logo = "axolotl_logo_style"
}

/// The start page ASCII axolotl's look. The defaults are the original logo.
struct LogoStyle: Codable, Equatable {
    enum Glyphs: String, Codable, CaseIterable { case classic, blocks, dots, binary, letters }
    enum Tint: String, Codable, CaseIterable { case classic, accent, mono, pink, gold }
    enum Size: String, Codable, CaseIterable { case small, medium, large }
    enum Motion: String, Codable, CaseIterable { case wave, still }

    var glyphs = Glyphs.blocks
    var tint = Tint.accent
    var size = Size.medium
    var motion = Motion.wave
    var show = true
}

/// A dark base plus two mid tones. The accent is chosen separately.
struct WallpaperPalette: Identifiable, Equatable {
    let id: String
    let name: String
    let base: String
    let mid: String
    let high: String

    static let all: [WallpaperPalette] = [
        .init(id: "midnight", name: "Midnight", base: "#070912", mid: "#1b2a6b", high: "#3f6fd8"),
        .init(id: "lagoon", name: "Lagoon", base: "#04100f", mid: "#0c4a4a", high: "#1fa39a"),
        .init(id: "orchid", name: "Orchid", base: "#0d0614", mid: "#3b1460", high: "#8a3ec2"),
        .init(id: "ember", name: "Ember", base: "#0f0605", mid: "#5a1a10", high: "#c2532a"),
        .init(id: "moss", name: "Moss", base: "#060c07", mid: "#1d3b22", high: "#5e8f4e"),
        .init(id: "graphite", name: "Graphite", base: "#0a0a0c", mid: "#26272d", high: "#5d6070"),
    ]

    static func named(_ id: String) -> WallpaperPalette? { all.first { $0.id == id } }
}

struct WallpaperAccent: Identifiable, Equatable {
    let id: String
    let name: String
    let hex: String

    static let all: [WallpaperAccent] = [
        .init(id: "moonlight", name: "Moonlight", hex: "#e8e6ff"),
        .init(id: "lavender", name: "Lavender", hex: "#b49cff"),
        .init(id: "cyan", name: "Cyan", hex: "#6fe3ff"),
        .init(id: "mint", name: "Mint", hex: "#7cf0b4"),
        .init(id: "amber", name: "Amber", hex: "#ffc46b"),
        .init(id: "rose", name: "Rose", hex: "#ff7aa8"),
    ]

    static func named(_ id: String) -> WallpaperAccent? { all.first { $0.id == id } }
}

enum WallpaperPreset: String, CaseIterable, Identifiable {
    case none
    case polarVeil, inkBloom, velvetMesh, nightDrift, moonlitHaze
    case tidalDither, emberPlasma, halftoneDusk, marbleSmoke, lunarRays

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .polarVeil: return "Polar Veil"
        case .inkBloom: return "Ink Bloom"
        case .velvetMesh: return "Velvet Mesh"
        case .nightDrift: return "Night Drift"
        case .moonlitHaze: return "Moonlit Haze"
        case .tidalDither: return "Tidal Dither"
        case .emberPlasma: return "Ember Plasma"
        case .halftoneDusk: return "Halftone Dusk"
        case .marbleSmoke: return "Marble Smoke"
        case .lunarRays: return "Lunar Rays"
        }
    }

    /// The look each preset is tuned for; the user can change both.
    var defaultStyle: WallpaperStyle {
        switch self {
        case .none, .nightDrift: return WallpaperStyle(palette: "midnight", accent: "moonlight")
        case .polarVeil: return WallpaperStyle(palette: "midnight", accent: "mint", grain: 0.4)
        case .inkBloom: return WallpaperStyle(palette: "orchid", accent: "rose", grain: 0.4)
        case .velvetMesh: return WallpaperStyle(palette: "orchid", accent: "amber", grain: 0.55)
        case .moonlitHaze: return WallpaperStyle(palette: "graphite", accent: "moonlight", grain: 0.35)
        case .tidalDither: return WallpaperStyle(palette: "lagoon", accent: "cyan")
        case .emberPlasma: return WallpaperStyle(palette: "ember", accent: "amber", grain: 0.4)
        case .halftoneDusk: return WallpaperStyle(palette: "midnight", accent: "rose")
        case .marbleSmoke: return WallpaperStyle(palette: "graphite", accent: "lavender", grain: 0.5)
        case .lunarRays: return WallpaperStyle(palette: "midnight", accent: "lavender", grain: 0.4)
        }
    }
}

/// Per-preset look. Decoding never fails on bad stored values: unknown swatches and
/// effects fall back to the preset's defaults and numbers are clamped into range.
struct WallpaperStyle: Codable, Equatable {
    /// What the start page's pointer does to the wallpaper.
    enum Pointer: String, Codable, CaseIterable { case off, glow, ripple, parallax }
    enum Click: String, Codable, CaseIterable { case off, burst }

    static let speedRange: ClosedRange<Double> = 0...2
    static let intensityRange: ClosedRange<Double> = 0.3...1
    static let dimRange: ClosedRange<Double> = 0...0.7
    static let grainRange: ClosedRange<Double> = 0...1
    static let zoomRange: ClosedRange<Double> = 1...2

    var palette: String
    var accent: String
    var speed: Double = 1
    var intensity: Double = 1
    var dim: Double = 0.25
    var grain: Double = 0
    var zoom: Double = 1
    var pointer = Pointer.off
    var click = Click.off

    init(palette: String, accent: String, speed: Double = 1, intensity: Double = 1, dim: Double = 0.25,
         grain: Double = 0, zoom: Double = 1, pointer: Pointer = .off, click: Click = .off) {
        self.palette = palette
        self.accent = accent
        self.speed = speed
        self.intensity = intensity
        self.dim = dim
        self.grain = grain
        self.zoom = zoom
        self.pointer = pointer
        self.click = click
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette = (try? c.decode(String.self, forKey: .palette)) ?? ""
        accent = (try? c.decode(String.self, forKey: .accent)) ?? ""
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1
        intensity = (try? c.decode(Double.self, forKey: .intensity)) ?? 1
        dim = (try? c.decode(Double.self, forKey: .dim)) ?? 0.25
        // Grain's default differs per preset; NaN makes `validated(for:)` fill it in.
        grain = (try? c.decode(Double.self, forKey: .grain)) ?? .nan
        zoom = (try? c.decode(Double.self, forKey: .zoom)) ?? 1
        pointer = (try? c.decode(Pointer.self, forKey: .pointer)) ?? .off
        click = (try? c.decode(Click.self, forKey: .click)) ?? .off
    }

    /// The same style with every field valid for `preset`.
    func validated(for preset: WallpaperPreset) -> WallpaperStyle {
        let fallback = preset.defaultStyle
        func clamp(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double {
            v.isFinite ? min(max(v, r.lowerBound), r.upperBound) : d
        }
        return WallpaperStyle(
            palette: WallpaperPalette.named(palette) != nil ? palette : fallback.palette,
            accent: WallpaperAccent.named(accent) != nil ? accent : fallback.accent,
            speed: clamp(speed, Self.speedRange, 1),
            intensity: clamp(intensity, Self.intensityRange, 1),
            dim: clamp(dim, Self.dimRange, 0.25),
            grain: clamp(grain, Self.grainRange, fallback.grain),
            zoom: clamp(zoom, Self.zoomRange, 1),
            pointer: pointer, click: click)
    }

    /// A random, good-looking style for `preset`: any swatches, knobs kept near the defaults.
    /// Pointer and click effects stay as they are.
    func surprise(for preset: WallpaperPreset, using rng: inout some RandomNumberGenerator) -> WallpaperStyle {
        let d = preset.defaultStyle
        return WallpaperStyle(
            palette: WallpaperPalette.all.randomElement(using: &rng)!.id,
            accent: WallpaperAccent.all.randomElement(using: &rng)!.id,
            speed: .random(in: 0.6...1.4, using: &rng),
            intensity: .random(in: 0.75...1, using: &rng),
            dim: dim,
            grain: min(1, d.grain + .random(in: 0...0.3, using: &rng)),
            zoom: .random(in: 1...1.5, using: &rng),
            pointer: pointer, click: click)
    }
}

/// What the web view is told to draw. Encoded as JSON for `axolotlWallpaper.apply`.
struct WallpaperRenderConfig: Codable, Equatable {
    struct Colors: Codable, Equatable {
        let bg: String
        let a: String
        let b: String
        let accent: String
    }

    static let allowedFrameRates = [30, 60]

    let preset: String
    let colors: Colors
    let speed: Double
    let intensity: Double
    let grain: Double
    let zoom: Double
    /// `WallpaperStyle.Pointer` / `.Click` raw values.
    let pointer: String
    let click: String
    let fps: Int
    /// Fraction of the device pixel ratio the canvas renders at.
    let scale: Double
    /// Draw one frame and hold it (Reduce Motion, Low Power Mode, thumbnails).
    var still: Bool

    init(preset: WallpaperPreset, style: WallpaperStyle, fps: Int, still: Bool, scale: Double = 0.5) {
        let s = style.validated(for: preset)
        let p = WallpaperPalette.named(s.palette) ?? WallpaperPalette.all[0]
        let accent = WallpaperAccent.named(s.accent) ?? WallpaperAccent.all[0]
        self.preset = preset.rawValue
        colors = Colors(bg: p.base, a: p.mid, b: p.high, accent: accent.hex)
        speed = s.speed
        intensity = s.intensity
        grain = s.grain
        zoom = s.zoom
        pointer = s.pointer.rawValue
        click = s.click.rawValue
        self.fps = Self.allowedFrameRates.contains(fps) ? fps : 30
        self.scale = min(max(scale, 0.25), 1)
        self.still = still
    }

    func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Whether the wallpaper should animate, hold a still frame or stop drawing.
struct WallpaperActivity: Equatable {
    enum Mode: Equatable { case running, still, paused }

    var isOnScreen = false          // start page shown and its window visible
    var reduceMotion = false
    var lowPower = false

    var mode: Mode {
        guard isOnScreen else { return .paused }
        return reduceMotion || lowPower ? .still : .running
    }
}

/// The user's wallpaper settings, shared by every start page and the settings pane.
final class WallpaperStore: ObservableObject {
    static let shared = WallpaperStore()

    private let defaults: UserDefaults

    @Published var preset: WallpaperPreset { didSet { defaults.set(preset.rawValue, forKey: WallpaperPrefs.preset) } }
    @Published private(set) var styles: [String: WallpaperStyle]
    @Published var frameRate: Int { didSet { defaults.set(frameRate, forKey: WallpaperPrefs.frameRate) } }
    @Published var showMoon: Bool { didSet { defaults.set(showMoon, forKey: WallpaperPrefs.showMoon) } }
    @Published var logo: LogoStyle { didSet { defaults.set(try? JSONEncoder().encode(logo), forKey: WallpaperPrefs.logo) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preset = WallpaperPreset(rawValue: defaults.string(forKey: WallpaperPrefs.preset) ?? "") ?? .none
        styles = Self.decodeStyles(defaults.data(forKey: WallpaperPrefs.styles))
        let fps = defaults.integer(forKey: WallpaperPrefs.frameRate)
        frameRate = WallpaperRenderConfig.allowedFrameRates.contains(fps) ? fps : 30
        showMoon = defaults.object(forKey: WallpaperPrefs.showMoon) == nil ? true : defaults.bool(forKey: WallpaperPrefs.showMoon)
        // Unreadable or unknown values (e.g. from a newer build) fall back to the original logo.
        logo = defaults.data(forKey: WallpaperPrefs.logo).flatMap { try? JSONDecoder().decode(LogoStyle.self, from: $0) } ?? LogoStyle()
    }

    static func decodeStyles(_ data: Data?) -> [String: WallpaperStyle] {
        guard let data, let raw = try? JSONDecoder().decode([String: WallpaperStyle].self, from: data) else { return [:] }
        return raw.reduce(into: [:]) { out, entry in
            if let p = WallpaperPreset(rawValue: entry.key), p != .none { out[entry.key] = entry.value.validated(for: p) }
        }
    }

    func style(for preset: WallpaperPreset) -> WallpaperStyle {
        styles[preset.rawValue]?.validated(for: preset) ?? preset.defaultStyle
    }

    /// Picks another wallpaper and gives it a random look.
    func surpriseMe() {
        var rng = SystemRandomNumberGenerator()
        let next = WallpaperPreset.allCases.filter { $0 != .none && $0 != preset }.randomElement(using: &rng)!
        setStyle(style(for: preset == .none ? next : preset).surprise(for: next, using: &rng), for: next)
        preset = next
    }

    func setStyle(_ style: WallpaperStyle, for preset: WallpaperPreset) {
        guard preset != .none else { return }
        styles[preset.rawValue] = style.validated(for: preset)
        if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: WallpaperPrefs.styles) }
    }

    func resetStyle(for preset: WallpaperPreset) {
        styles[preset.rawValue] = nil
        if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: WallpaperPrefs.styles) }
    }

    func renderConfig(for preset: WallpaperPreset? = nil, still: Bool) -> WallpaperRenderConfig {
        let p = preset ?? self.preset
        return WallpaperRenderConfig(preset: p, style: style(for: p), fps: frameRate, still: still)
    }
}

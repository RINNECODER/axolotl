// Luna — start page wallpapers: presets, palettes and the settings that drive them.
// The shaders themselves live in Wallpaper/WallpaperWeb (WebGPU, bundled, offline).
import Foundation
import Combine

enum WallpaperPrefs {
    static let preset = "luna_wallpaper_preset"
    static let styles = "luna_wallpaper_styles"
    static let frameRate = "luna_wallpaper_fps"
    static let showMoon = "luna_wallpaper_show_moon"
    static let moonStyle = "luna_moon_style"
}

enum MoonStyle: String, CaseIterable, Identifiable {
    case ascii, shader
    var id: String { rawValue }
    var title: String { self == .ascii ? "ASCII" : "Shader" }
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
        case .polarVeil: return WallpaperStyle(palette: "midnight", accent: "mint")
        case .inkBloom: return WallpaperStyle(palette: "orchid", accent: "rose")
        case .velvetMesh: return WallpaperStyle(palette: "orchid", accent: "amber")
        case .moonlitHaze: return WallpaperStyle(palette: "graphite", accent: "moonlight")
        case .tidalDither: return WallpaperStyle(palette: "lagoon", accent: "cyan")
        case .emberPlasma: return WallpaperStyle(palette: "ember", accent: "amber")
        case .halftoneDusk: return WallpaperStyle(palette: "midnight", accent: "rose")
        case .marbleSmoke: return WallpaperStyle(palette: "graphite", accent: "lavender")
        case .lunarRays: return WallpaperStyle(palette: "midnight", accent: "lavender")
        }
    }
}

/// Per-preset look. Decoding never fails on bad stored values: unknown swatches fall
/// back to the preset's defaults and numbers are clamped into range.
struct WallpaperStyle: Codable, Equatable {
    static let speedRange: ClosedRange<Double> = 0.25...2
    static let intensityRange: ClosedRange<Double> = 0.3...1
    static let dimRange: ClosedRange<Double> = 0...0.7

    var palette: String
    var accent: String
    var speed: Double = 1
    var intensity: Double = 1
    var dim: Double = 0.25

    init(palette: String, accent: String, speed: Double = 1, intensity: Double = 1, dim: Double = 0.25) {
        self.palette = palette
        self.accent = accent
        self.speed = speed
        self.intensity = intensity
        self.dim = dim
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        palette = (try? c.decode(String.self, forKey: .palette)) ?? ""
        accent = (try? c.decode(String.self, forKey: .accent)) ?? ""
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1
        intensity = (try? c.decode(Double.self, forKey: .intensity)) ?? 1
        dim = (try? c.decode(Double.self, forKey: .dim)) ?? 0.25
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
            dim: clamp(dim, Self.dimRange, 0.25))
    }
}

/// What the web view is told to draw. Encoded as JSON for `lunaWallpaper.apply`.
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
    let fps: Int
    /// Fraction of the device pixel ratio the canvas renders at.
    let scale: Double
    /// Draw one frame and hold it (Reduce Motion, Low Power Mode, thumbnails).
    var still: Bool
    /// The shader moon turns faster while the AI is working.
    var busy = false

    init(preset: WallpaperPreset, style: WallpaperStyle, fps: Int, still: Bool, scale: Double = 0.5) {
        let s = style.validated(for: preset)
        let p = WallpaperPalette.named(s.palette) ?? WallpaperPalette.all[0]
        let accent = WallpaperAccent.named(s.accent) ?? WallpaperAccent.all[0]
        self.preset = preset.rawValue
        colors = Colors(bg: p.base, a: p.mid, b: p.high, accent: accent.hex)
        speed = s.speed
        intensity = s.intensity
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
    @Published var moonStyle: MoonStyle { didSet { defaults.set(moonStyle.rawValue, forKey: WallpaperPrefs.moonStyle) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preset = WallpaperPreset(rawValue: defaults.string(forKey: WallpaperPrefs.preset) ?? "") ?? .none
        styles = Self.decodeStyles(defaults.data(forKey: WallpaperPrefs.styles))
        let fps = defaults.integer(forKey: WallpaperPrefs.frameRate)
        frameRate = WallpaperRenderConfig.allowedFrameRates.contains(fps) ? fps : 30
        showMoon = defaults.object(forKey: WallpaperPrefs.showMoon) == nil ? true : defaults.bool(forKey: WallpaperPrefs.showMoon)
        moonStyle = MoonStyle(rawValue: defaults.string(forKey: WallpaperPrefs.moonStyle) ?? "") ?? .ascii
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

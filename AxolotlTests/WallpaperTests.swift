import XCTest
import SwiftUI
@testable import Axolotl

final class WallpaperTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let name = "WallpaperTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testStoredStylesAreClampedAndUnknownSwatchesFallBackToPresetDefaults() throws {
        let json = #"""
        {"inkBloom": {"palette": "neon", "accent": "amber", "speed": 9, "intensity": -1, "dim": 0.4,
                      "grain": 3, "zoom": 0.1, "pointer": "laser", "click": "burst"},
         "nightDrift": {"speed": "fast"},
         "notAPreset": {"palette": "moss", "accent": "mint"},
         "none": {"palette": "moss", "accent": "mint"}}
        """#
        let styles = WallpaperStore.decodeStyles(Data(json.utf8))

        XCTAssertEqual(Set(styles.keys), ["inkBloom", "nightDrift"])
        XCTAssertEqual(styles["inkBloom"], WallpaperStyle(palette: "orchid", accent: "amber", speed: 2, intensity: 0.3, dim: 0.4,
                                                          grain: 1, zoom: 1, pointer: .off, click: .burst))
        XCTAssertEqual(styles["nightDrift"], WallpaperStyle(palette: "midnight", accent: "moonlight"))
        XCTAssertEqual(WallpaperStore.decodeStyles(Data("not json".utf8)), [:])
    }

    func testStylesSavedBeforeEffectsDecodeWithThePresetDefaults() {
        let old = #"{"velvetMesh": {"palette": "moss", "accent": "mint", "speed": 0.5, "intensity": 0.9, "dim": 0.3}}"#
        let style = WallpaperStore.decodeStyles(Data(old.utf8))["velvetMesh"]
        XCTAssertEqual(style, WallpaperStyle(palette: "moss", accent: "mint", speed: 0.5, intensity: 0.9, dim: 0.3,
                                             grain: WallpaperPreset.velvetMesh.defaultStyle.grain))
        XCTAssertEqual(style?.pointer, .off, "pointer effects are opt-in")
        XCTAssertEqual(style?.click, .off)
        XCTAssertEqual(style?.zoom, 1)
    }

    func testSurpriseKeepsKnobsInRangeAndLeavesPointerEffectsAlone() {
        var rng = SystemRandomNumberGenerator()
        let mine = WallpaperStyle(palette: "moss", accent: "mint", dim: 0.5, pointer: .ripple, click: .burst)
        for preset in WallpaperPreset.allCases where preset != .none {
            let s = mine.surprise(for: preset, using: &rng)
            XCTAssertEqual(s, s.validated(for: preset), "\(preset) out of range")
            XCTAssertGreaterThan(s.speed, 0, "never frozen")
            XCTAssertEqual([s.pointer.rawValue, s.click.rawValue, "\(s.dim)"], ["ripple", "burst", "0.5"])
        }
    }

    func testRenderConfigResolvesSwatchesToColorsAndRejectsUnsupportedFrameRates() throws {
        let style = WallpaperStyle(palette: "ember", accent: "cyan", speed: 0, intensity: 0.8, grain: 0.3, zoom: 1.5,
                                   pointer: .parallax, click: .burst)
        let config = WallpaperRenderConfig(preset: .emberPlasma, style: style, fps: 45, still: true, scale: 3)

        let decoded = try JSONSerialization.jsonObject(with: Data(config.json().utf8)) as! [String: Any]
        XCTAssertEqual(decoded["preset"] as? String, "emberPlasma")
        XCTAssertEqual(decoded["colors"] as? [String: String],
                       ["bg": "#0f0605", "a": "#5a1a10", "b": "#c2532a", "accent": "#6fe3ff"])
        XCTAssertEqual(decoded["speed"] as? Double, 0)
        XCTAssertEqual(decoded["grain"] as? Double, 0.3)
        XCTAssertEqual(decoded["zoom"] as? Double, 1.5)
        XCTAssertEqual(decoded["pointer"] as? String, "parallax")
        XCTAssertEqual(decoded["click"] as? String, "burst")
        XCTAssertEqual(decoded["fps"] as? Int, 30)
        XCTAssertEqual(decoded["scale"] as? Double, 1)
        XCTAssertEqual(decoded["still"] as? Bool, true)
    }

    func testStorePersistsPerPresetStylesAndDefaultsToNoWallpaper() {
        let defaults = freshDefaults()
        let store = WallpaperStore(defaults: defaults)
        XCTAssertEqual(store.preset, .none)
        XCTAssertTrue(store.showMoon)
        XCTAssertEqual(store.frameRate, 30)

        store.preset = .tidalDither
        let custom = WallpaperStyle(palette: "moss", accent: "rose", speed: 0.5, grain: 0.7, zoom: 1.25, pointer: .glow, click: .burst)
        store.setStyle(custom, for: .tidalDither)
        store.showMoon = false
        store.frameRate = 60

        let reloaded = WallpaperStore(defaults: defaults)
        XCTAssertEqual(reloaded.preset, .tidalDither)
        XCTAssertEqual(reloaded.style(for: .tidalDither), custom)
        XCTAssertEqual(reloaded.style(for: .polarVeil), WallpaperPreset.polarVeil.defaultStyle)
        XCTAssertFalse(reloaded.showMoon)
        XCTAssertEqual(reloaded.frameRate, 60)

        reloaded.resetStyle(for: .tidalDither)
        XCTAssertEqual(WallpaperStore(defaults: defaults).style(for: .tidalDither), WallpaperPreset.tidalDither.defaultStyle)
    }

    func testLogoStyleDefaultsToBlueBlocksAndPersists() {
        let defaults = freshDefaults()
        XCTAssertEqual(WallpaperStore(defaults: defaults).logo,
                       LogoStyle(glyphs: .blocks, tint: .accent, size: .medium, motion: .wave, show: true))

        let custom = LogoStyle(glyphs: .letters, tint: .gold, size: .large, motion: .still, show: false)
        WallpaperStore(defaults: defaults).logo = custom
        XCTAssertEqual(WallpaperStore(defaults: defaults).logo, custom)

        defaults.set(Data(#"{"glyphs":"emoji"}"#.utf8), forKey: WallpaperPrefs.logo)
        XCTAssertEqual(WallpaperStore(defaults: defaults).logo, LogoStyle(), "unknown values fall back to the original")
    }

    func testWallpaperOnlyAnimatesWhileOnScreenAndHoldsStillForReduceMotionOrLowPower() {
        var activity = WallpaperActivity()
        XCTAssertEqual(activity.mode, .paused)

        activity.isOnScreen = true
        XCTAssertEqual(activity.mode, .running)

        activity.reduceMotion = true
        XCTAssertEqual(activity.mode, .still)
        activity.reduceMotion = false
        activity.lowPower = true
        XCTAssertEqual(activity.mode, .still)

        activity.isOnScreen = false
        XCTAssertEqual(activity.mode, .paused)
    }

    func testSchemeHandlerServesOnlyAllowlistedFiles() {
        func url(_ s: String) -> URL { URL(string: s)! }
        XCTAssertNotNil(WallpaperSchemeHandler.fileURL(for: url("axolotl-wallpaper://app/index.html")))
        XCTAssertNotNil(WallpaperSchemeHandler.fileURL(for: url("axolotl-wallpaper://app/shaders.js")))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(for: url("axolotl-wallpaper://app/..%2FInfo.plist")))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(for: url("axolotl-wallpaper://app/%2Fetc%2Fpasswd")))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(for: url("axolotl-wallpaper://app/LICENSE-shaders.txt")))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(for: url("axolotl-wallpaper://other/index.html")))
        XCTAssertNil(WallpaperSchemeHandler.fileURL(for: url("https://app/index.html")))
    }

    func testNavigationPolicyAllowsOnlyBundledSchemePagesInMainFrame() {
        let page = URL(string: "axolotl-wallpaper://app/index.html")
        XCTAssertTrue(WallpaperBridge.allowsNavigation(to: page, isMainFrame: true))
        XCTAssertFalse(WallpaperBridge.allowsNavigation(to: page, isMainFrame: nil), "new windows have no target frame")
        XCTAssertFalse(WallpaperBridge.allowsNavigation(to: URL(string: "https://example.com"), isMainFrame: true))
        XCTAssertFalse(WallpaperBridge.allowsNavigation(to: URL(string: "axolotl-wallpaper://app/secret.txt"), isMainFrame: true))
        XCTAssertFalse(WallpaperBridge.allowsNavigation(to: nil, isMainFrame: true))
    }

    func testReloadBackoffGrowsThenGivesUp() {
        XCTAssertEqual(WallpaperBridge.reloadDelay(attempt: 1), 0.5)
        XCTAssertEqual(WallpaperBridge.reloadDelay(attempt: 2), 1)
        XCTAssertNil(WallpaperBridge.reloadDelay(attempt: WallpaperBridge.maxReloads + 1))
    }

    @MainActor
    func testAsciiAxolotlSamplesTheMarkIntoTheGrid() throws {
        // Start page size: 170pt → 50 × 24 cells.
        let g = AxolotlRenderer.grid(cols: 50, rows: 24, cellAspect: 1.12 / 0.62)
        let lit = g.cells.filter { $0 > 0.04 }.count
        XCTAssertTrue((g.cells.count / 5...g.cells.count * 4 / 5).contains(lit), "lit \(lit) of \(g.cells.count)")
        XCTAssertEqual(g.cells.prefix(50).max(), 0, "top row stays empty (art is centered)")
        // Optional: AXOLOTL_LOGO_SHOT=<folder name> renders the start page logo to a PNG under the temp dir.
        if let name = ProcessInfo.processInfo.environment["AXOLOTL_LOGO_SHOT"], !name.isEmpty {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            print("Logo shot: \(dir.path)")
            var styles = LogoStyle.Glyphs.allCases.map { ("glyphs-\($0.rawValue)", LogoStyle(glyphs: $0)) }
            styles += LogoStyle.Tint.allCases.map { ("tint-\($0.rawValue)", LogoStyle(tint: $0)) }
            for (file, style) in styles {
                let renderer = ImageRenderer(content: Canvas { ctx, size in
                    AxolotlRenderer.draw(&ctx, size: size, diameter: 170, t: 40, style: style)
                }.frame(width: 170 * 1.3, height: 170 * 1.15).background(Color.black))
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage?.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try image.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(file).png"))
            }
        }
    }
}

import XCTest
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
        {"inkBloom": {"palette": "neon", "accent": "amber", "speed": 9, "intensity": -1, "dim": 0.4},
         "nightDrift": {"speed": "fast"},
         "notAPreset": {"palette": "moss", "accent": "mint"},
         "none": {"palette": "moss", "accent": "mint"}}
        """#
        let styles = WallpaperStore.decodeStyles(Data(json.utf8))

        XCTAssertEqual(Set(styles.keys), ["inkBloom", "nightDrift"])
        XCTAssertEqual(styles["inkBloom"], WallpaperStyle(palette: "orchid", accent: "amber", speed: 2, intensity: 0.3, dim: 0.4))
        XCTAssertEqual(styles["nightDrift"], WallpaperStyle(palette: "midnight", accent: "moonlight"))
        XCTAssertEqual(WallpaperStore.decodeStyles(Data("not json".utf8)), [:])
    }

    func testRenderConfigResolvesSwatchesToColorsAndRejectsUnsupportedFrameRates() throws {
        let style = WallpaperStyle(palette: "ember", accent: "cyan", speed: 1.5, intensity: 0.8)
        let config = WallpaperRenderConfig(preset: .emberPlasma, style: style, fps: 45, still: true, scale: 3)

        let decoded = try JSONSerialization.jsonObject(with: Data(config.json().utf8)) as! [String: Any]
        XCTAssertEqual(decoded["preset"] as? String, "emberPlasma")
        XCTAssertEqual(decoded["colors"] as? [String: String],
                       ["bg": "#0f0605", "a": "#5a1a10", "b": "#c2532a", "accent": "#6fe3ff"])
        XCTAssertEqual(decoded["speed"] as? Double, 1.5)
        XCTAssertEqual(decoded["fps"] as? Int, 30)
        XCTAssertEqual(decoded["scale"] as? Double, 1)
        XCTAssertEqual(decoded["still"] as? Bool, true)
    }

    func testStorePersistsPerPresetStylesAndDefaultsToNoWallpaperWithAsciiMoon() {
        let defaults = freshDefaults()
        let store = WallpaperStore(defaults: defaults)
        XCTAssertEqual(store.preset, .none)
        XCTAssertEqual(store.moonStyle, .ascii)
        XCTAssertTrue(store.showMoon)
        XCTAssertEqual(store.frameRate, 30)

        store.preset = .tidalDither
        store.setStyle(WallpaperStyle(palette: "moss", accent: "rose", speed: 0.5), for: .tidalDither)
        store.moonStyle = .shader
        store.showMoon = false
        store.frameRate = 60

        let reloaded = WallpaperStore(defaults: defaults)
        XCTAssertEqual(reloaded.preset, .tidalDither)
        XCTAssertEqual(reloaded.style(for: .tidalDither), WallpaperStyle(palette: "moss", accent: "rose", speed: 0.5))
        XCTAssertEqual(reloaded.style(for: .polarVeil), WallpaperPreset.polarVeil.defaultStyle)
        XCTAssertEqual(reloaded.moonStyle, .shader)
        XCTAssertFalse(reloaded.showMoon)
        XCTAssertEqual(reloaded.frameRate, 60)

        reloaded.resetStyle(for: .tidalDither)
        XCTAssertEqual(WallpaperStore(defaults: defaults).style(for: .tidalDither), WallpaperPreset.tidalDither.defaultStyle)
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
        let page = URL(string: "axolotl-wallpaper://app/moon.html")
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
}

import XCTest
@testable import Axolotl

@MainActor
final class ThemeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var customizer: Customizer!

    override func setUp() async throws {
        suiteName = "ThemeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        customizer = Customizer(env: CustomizationEnvironment(defaults: defaults, shortcuts: ShortcutStore(defaults: defaults)),
                                log: AIChangeLog(defaults: defaults))
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func set(_ key: String, _ value: JSONValue) throws -> AIChange {
        try customizer.apply(CustomizationPlan(settings: [SettingChange(key: key, value: value)]), context: nil, source: "test")
    }

    func testColorsRejectBadHexAndAreStoredNormalized() throws {
        let accent = try XCTUnwrap(CustomizationRegistry.setting("theme.accent.light"))
        for bad: JSONValue in [.string("#12345"), .string("zzzzzz"), .string("#GGGGGG"), .string("#1234567"), .number(0x3265CB), .bool(true)] {
            XCTAssertThrowsError(try accent.validate(bad), "\(bad) must be rejected")
        }
        XCTAssertThrowsError(try set("theme.window.dark", .string("blue")))
        XCTAssertNil(defaults.object(forKey: ThemeColorToken.window.defaultsKey(dark: true)), "rejected plans write nothing")

        _ = try set("theme.accent.light", .string("3265cb"))
        XCTAssertEqual(defaults.string(forKey: ThemeColorToken.accent.defaultsKey(dark: false)), "#3265CB")
        XCTAssertEqual(Theme.load(defaults).pair(.accent).light, 0x3265CB)
    }

    func testRangesAreEnforced() throws {
        XCTAssertThrowsError(try set("appearance.cornerRadius", .number(60)))
        XCTAssertThrowsError(try set("appearance.fontScale", .number(300)))
        XCTAssertThrowsError(try set("glass.tint", .number(40)))
        XCTAssertThrowsError(try set("appearance.density", .string("tiny")))
        XCTAssertThrowsError(try set("appearance.themePreset", .string("neon")))
        _ = try set("appearance.cornerRadius", .number(125))
        _ = try set("glass.tint", .number(30))
        let theme = Theme.load(defaults)
        XCTAssertEqual(theme.radius(8), 10)
        XCTAssertEqual(GlassSettings.load(defaults).tint, 30)
    }

    func testPresetThenTokenEditShowsCustomAndUndoRestores() throws {
        XCTAssertEqual(Theme.load(defaults).preset, .axolotl)
        let preset = try set("appearance.themePreset", .string("ocean"))
        XCTAssertEqual(Theme.load(defaults).preset, .ocean)
        XCTAssertEqual(Theme.load(defaults).pair(.sidebar), ThemePreset.ocean.color(.sidebar))

        let edit = try set("theme.accent.dark", .string("#FF0000"))
        XCTAssertNil(Theme.load(defaults).preset)
        XCTAssertEqual(CustomizationRegistry.setting("appearance.themePreset")?.read(customizer.env).stringValue, "custom")

        _ = try customizer.undo(edit.id)
        XCTAssertEqual(Theme.load(defaults).preset, .ocean)
        _ = try customizer.undo(preset.id)
        XCTAssertEqual(Theme.load(defaults).preset, .axolotl)
        for key in CustomizationRegistry.themeColorKeys { XCTAssertNil(defaults.object(forKey: key), "\(key) must be unset again") }
    }

    func testChromeTemplateSetsChromeThemeAndAxolotlRestoresIt() throws {
        _ = try set("theme.accent.light", .string("#00AA00"))
        _ = try set("layout.template", .string("chrome"))
        XCTAssertEqual(Theme.load(defaults).preset, .chrome)
        _ = try set("layout.template", .string("axolotl"))
        XCTAssertEqual(defaults.string(forKey: ThemeColorToken.accent.defaultsKey(dark: false)), "#00AA00")
        XCTAssertNil(defaults.object(forKey: ThemeColorToken.window.defaultsKey(dark: false)))
    }

    func testMasterOffDisablesEverySurface() throws {
        for surface in GlassSurface.allCases { defaults.set(true, forKey: surface.defaultsKey) }
        defaults.set(false, forKey: LiquidGlass.defaultsKey)
        let off = GlassSettings.load(defaults)
        XCTAssertFalse(off.isOn(nil))
        for surface in GlassSurface.allCases { XCTAssertFalse(off.isOn(surface), "\(surface) must follow the master switch") }

        _ = try set("appearance.liquidGlass", .bool(true))
        _ = try set("glass.sidebar", .bool(false))
        let on = GlassSettings.load(defaults)
        XCTAssertFalse(on.isOn(.sidebar))
        for surface in GlassSurface.allCases where surface != .sidebar { XCTAssertTrue(on.isOn(surface)) }
    }
}

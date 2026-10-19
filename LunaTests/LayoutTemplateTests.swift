import XCTest
@testable import Luna

@MainActor
final class LayoutTemplateTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var customizer: Customizer!

    override func setUp() async throws {
        suiteName = "LayoutTemplateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        customizer = Customizer(env: CustomizationEnvironment(defaults: defaults, shortcuts: ShortcutStore(defaults: defaults)),
                                log: AIChangeLog(defaults: defaults))
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func setTemplate(_ value: String) throws -> AIChange {
        try customizer.apply(CustomizationPlan(settings: [SettingChange(key: "layout.template", value: .string(value))]),
                             context: nil, source: "test")
    }

    /// The user's own setup: some keys set, the rest never touched.
    private func seedLunaSetup() {
        defaults.set(BrowserLayout.sidebar.rawValue, forKey: BrowserLayout.defaultsKey)
        defaults.set(true, forKey: ChromePrefs.roundedFrame)
        defaults.set(false, forKey: ChromePrefs.minimalURL)
    }

    private func assertLunaSetup(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(defaults.string(forKey: BrowserLayout.defaultsKey), "sidebar", file: file, line: line)
        XCTAssertEqual(defaults.object(forKey: ChromePrefs.roundedFrame) as? Bool, true, file: file, line: line)
        XCTAssertEqual(defaults.object(forKey: ChromePrefs.minimalURL) as? Bool, false, file: file, line: line)
        for key in [ChromePrefs.showBookmarksBar, ChromePrefs.showHomeButton, ChromePrefs.showToolbar, "luna_sidebar_visible",
                    LiquidGlass.defaultsKey] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) was never set and must be unset again", file: file, line: line)
        }
        XCTAssertNil(defaults.object(forKey: LayoutTemplate.defaultsKey), file: file, line: line)
        XCTAssertNil(defaults.object(forKey: LayoutTemplate.savedKey), file: file, line: line)
    }

    func testChromeThenLunaRestoresExactPriorValues() throws {
        seedLunaSetup()
        _ = try setTemplate("chrome")
        XCTAssertEqual(defaults.string(forKey: BrowserLayout.defaultsKey), "classic")
        XCTAssertEqual(defaults.object(forKey: ChromePrefs.showBookmarksBar) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: ChromePrefs.roundedFrame) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: LiquidGlass.defaultsKey) as? Bool, false, "Chrome draws solid surfaces")
        XCTAssertEqual(customizer.currentValue("layout.template"), "chrome")

        // Changes made while on Chrome don't leak into the restored Luna setup.
        defaults.set(false, forKey: ChromePrefs.showBookmarksBar)
        _ = try setTemplate("luna")
        assertLunaSetup()
    }

    func testUndoingTheTemplateChangeRestoresEverything() throws {
        seedLunaSetup()
        let change = try setTemplate("chrome")
        XCTAssertEqual(change.lines, [ChangeLine(title: "Layout template", from: "Custom", to: "Chrome")])
        _ = try customizer.undo(change.id)
        assertLunaSetup()

        // Undoing a switch back to Luna returns to Chrome, with the saved Luna setup intact for next time.
        _ = try setTemplate("chrome")
        let back = try setTemplate("luna")
        _ = try customizer.undo(back.id)
        XCTAssertEqual(customizer.currentValue("layout.template"), "chrome")
        XCTAssertEqual(defaults.string(forKey: BrowserLayout.defaultsKey), "classic")
        _ = try setTemplate("luna")
        assertLunaSetup()
    }

    func testLiquidGlassIsAToggleableSettingThatDefaultsOn() throws {
        XCTAssertEqual(customizer.currentValue("appearance.liquidGlass"), .bool(true))
        _ = try customizer.apply(CustomizationPlan(settings: [SettingChange(key: "appearance.liquidGlass", value: .bool(false))]),
                                 context: nil, source: "test")
        XCTAssertEqual(defaults.object(forKey: LiquidGlass.defaultsKey) as? Bool, false)
        XCTAssertThrowsError(try customizer.apply(
            CustomizationPlan(settings: [SettingChange(key: "appearance.liquidGlass", value: .string("off"))]),
            context: nil, source: "test"))
    }

    func testRegistryValidatesLayoutTemplate() {
        XCTAssertNoThrow(try customizer.validate([SettingChange(key: "layout.template", value: "chrome")]))
        XCTAssertNoThrow(try customizer.validate([SettingChange(key: "layout.template", value: "luna")]))
        for (value, message) in [(JSONValue.string("safari"), "not allowed"), (.bool(true), "expected one of")] {
            XCTAssertThrowsError(try customizer.validate([SettingChange(key: "layout.template", value: value)])) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), error.localizedDescription)
            }
        }
        XCTAssertEqual(customizer.currentValue("layout.template"), "luna", "unset reads as Luna")
    }

    func testChromeTabPitchShrinksEvenlyBetweenChromesBounds() {
        XCTAssertEqual(ChromeMetrics.tabPitch(available: 1100, count: 3), 238, "tabs stop growing at Chrome's max")
        XCTAssertEqual(ChromeMetrics.tabPitch(available: 1100, count: 10), 110)
        XCTAssertEqual(ChromeMetrics.tabPitch(available: 1100, count: 25), 44)
        XCTAssertEqual(ChromeMetrics.tabPitch(available: 1100, count: 100), ChromeMetrics.minTabPitch, "below the minimum the strip scrolls")
        XCTAssertEqual(ChromeMetrics.tabPitch(available: 1100, count: 0), 0)
        XCTAssertTrue(ChromeMetrics.isNarrow(pitch: 44))
        XCTAssertFalse(ChromeMetrics.showsClose(pitch: 70, isActive: false))
        XCTAssertTrue(ChromeMetrics.showsClose(pitch: 44, isActive: true))
    }

    @MainActor
    func testTrafficLightsAreRestoredSynchronouslyWhenTheViewLeavesTheWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let before = close.frame.origin
        let view = TrafficLightPositioner.PositionerView()
        window.contentView?.addSubview(view)
        view.enabled = true
        let moved = expectation(description: "moved")
        DispatchQueue.main.async { moved.fulfill() }
        wait(for: [moved], timeout: 2)
        XCTAssertNotEqual(close.frame.origin, before)

        view.removeFromSuperview()
        TrafficLightPositioner.dismantleNSView(view, coordinator: ())
        XCTAssertEqual(close.frame.origin, before)
    }

    func testCustomizingUnderATemplateSwitchesToCustomAndKeepsTheChange() throws {
        seedLunaSetup()
        _ = try setTemplate("chrome")
        let env = CustomizationEnvironment(defaults: defaults, shortcuts: ShortcutStore(defaults: defaults))

        RegistrySettings.willChange("bookmarksBar.visible", env: env)
        defaults.set(false, forKey: ChromePrefs.showBookmarksBar)

        XCTAssertEqual(LayoutTemplate.current(defaults), .luna)
        XCTAssertNil(defaults.object(forKey: LayoutTemplate.savedKey))
        // Chrome's other settings stay: the window looks the same apart from the change.
        XCTAssertEqual(defaults.object(forKey: ChromePrefs.showToolbar) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: ChromePrefs.showBookmarksBar) as? Bool, false)
    }

    func testSettingsOutsideTheTemplateLeaveItAlone() throws {
        _ = try setTemplate("chrome")
        let env = CustomizationEnvironment(defaults: defaults, shortcuts: ShortcutStore(defaults: defaults))
        RegistrySettings.willChange("search.engine", env: env)
        XCTAssertEqual(LayoutTemplate.current(defaults), .chrome)
    }
}

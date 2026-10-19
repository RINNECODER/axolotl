import XCTest
@testable import Axolotl

@MainActor
final class SettingsPaneLinkTests: XCTestCase {
    override func tearDown() async throws {
        SettingsRouter.shared.requestedPane = nil
        SettingsRouter.shared.passwordsTab = .passwords
    }

    func testOldPaneNamesOpenThePaneThatHoldsThoseSettingsNow() {
        let expected: [String: SettingsPane] = [
            "profiles": .general, "search": .general, "import": .passwords, "importData": .passwords,
            "axolotlMax": .ai, "personalization": .privacy, "dev": .agents, "developer": .agents,
            // Names that survived keep working as they are.
            "appearance": .appearance, "tabs": .tabs, "ai": .ai, "passwords": .passwords,
            "extensions": .extensions, "about": .about,
        ]
        for (name, pane) in expected { XCTAssertEqual(SettingsPane.resolve(name), pane, name) }
        for pane in SettingsPane.allCases { XCTAssertEqual(SettingsPane.resolve(pane.rawValue), pane) }
        XCTAssertNil(SettingsPane.resolve("nope"))
    }

    func testImportLinkOpensTheImportTab() {
        XCTAssertTrue(SettingsRouter.shared.request("import"))
        XCTAssertEqual(SettingsRouter.shared.requestedPane, .passwords)
        XCTAssertEqual(SettingsRouter.shared.passwordsTab, .importData)

        XCTAssertTrue(SettingsRouter.shared.request("passwords"))
        XCTAssertEqual(SettingsRouter.shared.passwordsTab, .passwords)

        SettingsRouter.shared.requestedPane = nil
        XCTAssertFalse(SettingsRouter.shared.request("nope"))
        XCTAssertNil(SettingsRouter.shared.requestedPane)
    }

    func testSettingsTabURLsOpenTheirPane() {
        for pane in SettingsPane.allCases {
            let url = InternalPage.settingsURL(pane)
            XCTAssertEqual(url.absoluteString, "axolotl://settings/\(pane.rawValue)")
            XCTAssertEqual(InternalPage.settingsPane(url), pane)
        }
        // Old pane names deep-link too; the bare URL keeps the default pane.
        XCTAssertEqual(InternalPage.settingsPane(URL(string: "axolotl://settings/developer")), .agents)
        XCTAssertNil(InternalPage.settingsPane(URL(string: "axolotl://settings")))
        XCTAssertTrue(InternalPage.isSettings(URL(string: "axolotl://settings")))
        XCTAssertFalse(InternalPage.isSettings(URL(string: "https://settings")))
        XCTAssertFalse(InternalPage.isSettings(URL(string: "axolotl://history")))
    }

    func testTypingASettingsURLOpensItInsteadOfSearching() {
        XCTAssertEqual(AddressInput.url(for: "axolotl://settings/agents")?.absoluteString, "axolotl://settings/agents")
    }

    func testAppIconOptionsLoadFromTheAssetCatalogAndDefaultToAxolotl() throws {
        let setting = try XCTUnwrap(CustomizationRegistry.setting("appearance.appIcon"))
        let defaults = UserDefaults(suiteName: "AppIconTests-\(UUID().uuidString)")!
        XCTAssertEqual(setting.read(CustomizationEnvironment(defaults: defaults, shortcuts: .shared)).stringValue, "Axolotl")
        XCTAssertThrowsError(try setting.validate("AppIcon"))
        for (name, _) in AppIcon.options { XCTAssertNotNil(AppIcon.image(name), name) }
    }

    func testEachRegistrySettingAppearsInOnePaneAndExists() {
        var seen: [String: SettingsPane] = [:]
        for pane in SettingsPane.allCases {
            for key in pane.registryKeys {
                XCTAssertNotNil(CustomizationRegistry.setting(key), "\(key) is not in the registry")
                XCTAssertNil(seen[key], "\(key) is in both \(seen[key].map { $0.rawValue } ?? "") and \(pane.rawValue)")
                seen[key] = pane
            }
        }
    }

    func testSearchFindsAPaneBySettingLabel() {
        XCTAssertTrue(SettingsPane.ai.matches("tidy downloads"))
        XCTAssertTrue(SettingsPane.appearance.matches("bookmarks bar"))
        XCTAssertFalse(SettingsPane.about.matches("bookmarks bar"))
    }
}

@MainActor
final class DefaultBrowserSettingTests: XCTestCase {
    private final class FakeAPI: DefaultBrowserAPI {
        var handlers: [String: URL] = [:]
        var setCalls: [(URL, String)] = []
        func handlerURL(forScheme scheme: String) -> URL? { handlers[scheme] }
        func setHandler(_ appURL: URL, forScheme scheme: String) async throws {
            setCalls.append((appURL, scheme))
            handlers[scheme] = appURL
        }
    }

    private let axolotl = URL(fileURLWithPath: "/Applications/Axolotl.app")
    private let safari = URL(fileURLWithPath: "/Applications/Safari.app")

    func testMakeDefaultSetsAxolotlForHTTPAndHTTPS() async throws {
        let api = FakeAPI()
        api.handlers = ["http": safari, "https": safari]
        let setting = SystemDefaultBrowser(api: api, appURL: axolotl)
        XCTAssertFalse(setting.isDefault)

        try await setting.makeDefault()

        XCTAssertEqual(api.setCalls.map(\.1), ["http", "https"])
        XCTAssertEqual(api.setCalls.map(\.0), [axolotl, axolotl])
        XCTAssertTrue(setting.isDefault)
    }

    func testIsDefaultNeedsBothSchemes() {
        let api = FakeAPI()
        api.handlers = ["http": axolotl, "https": safari]
        XCTAssertFalse(SystemDefaultBrowser(api: api, appURL: axolotl).isDefault)
        api.handlers["https"] = axolotl
        XCTAssertTrue(SystemDefaultBrowser(api: api, appURL: axolotl).isDefault)
    }

    func testStubIsChosenByEnvironmentOrLaunchArgument() {
        let suite = "DefaultBrowserSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        XCTAssertFalse(DefaultBrowser.isStubbed(environment: [:], defaults: defaults))
        XCTAssertTrue(DefaultBrowser.isStubbed(environment: [DefaultBrowser.stubKey: "1"], defaults: defaults))
        XCTAssertFalse(DefaultBrowser.isStubbed(environment: [DefaultBrowser.stubKey: "0"], defaults: defaults))
        defaults.set(true, forKey: DefaultBrowser.stubKey)  // what `-AXOLOTL_STUB_DEFAULT_BROWSER 1` sets
        XCTAssertTrue(DefaultBrowser.isStubbed(environment: [:], defaults: defaults))
    }
}

final class OnboardingStateTests: XCTestCase {
    func testShowAgainClearsTheSeenFlagAndAsksOnboardingToShow() {
        let suite = "OnboardingStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        OnboardingState.markSeen(defaults)
        let posted = expectation(forNotification: .axolotlShowOnboarding, object: nil, notificationCenter: center)

        OnboardingState.showAgain(defaults: defaults, center: center)

        wait(for: [posted], timeout: 1)
        XCTAssertFalse(OnboardingState.hasSeen(defaults))
    }
}

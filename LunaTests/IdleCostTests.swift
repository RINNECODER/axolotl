import XCTest
@testable import Luna

/// Optional features and background work cost nothing while idle or off.
@MainActor
final class IdleCostTests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testDefaultsObserverIgnoresOtherKeysAndCoalescesBursts() throws {
        let suite = "luna-idle-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var calls = 0
        let observer = DefaultsObserver(keys: ["luna_theme_contrast"], defaults: d) { calls += 1 }
        d.set("x", forKey: "unrelated_key")
        spin()
        XCTAssertEqual(calls, 0, "a write to another key must not reload the theme")
        for v in ["high", "normal", "high"] { d.set(v, forKey: "luna_theme_contrast") }
        spin()
        XCTAssertEqual(calls, 1, "a burst of writes is one reload")
        withExtendedLifetime(observer) {}
    }

    func testOptionalFeatureScriptsOnlyWhenOn() {
        let key = LunaMaxPrefs.linkPreviews
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key); WebViewWrapper.samplesPageTheme = false }
        func sources(_ setup: () -> Void) -> [String] {
            setup()
            let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
            return web.ensureWebView(for: UUID()).configuration.userContentController.userScripts.map(\.source)
        }
        let off = sources { UserDefaults.standard.set(false, forKey: key); WebViewWrapper.samplesPageTheme = false }
        XCTAssertFalse(off.contains { $0.contains("lunaLinkPreview") }, "link previews off: no script")
        XCTAssertFalse(off.contains { $0.contains("lumaPageTheme") }, "page theme off: no script")
        XCTAssertTrue(off.contains { $0.contains("lunaMedia") }, "audio detection stays")
        XCTAssertTrue(off.contains { $0.contains("lunaPasswords") })
        let on = sources { UserDefaults.standard.set(true, forKey: key); WebViewWrapper.samplesPageTheme = true }
        XCTAssertTrue(on.contains { $0.contains("lunaLinkPreview") })
        XCTAssertTrue(on.contains { $0.contains("lumaPageTheme") })
    }
}

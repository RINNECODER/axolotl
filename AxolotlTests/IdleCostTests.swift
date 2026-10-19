import XCTest
@testable import Axolotl

/// Optional features and background work cost nothing while idle or off.
@MainActor
final class IdleCostTests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testDefaultsObserverIgnoresOtherKeysAndCoalescesBursts() throws {
        let suite = "axolotl-idle-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var calls = 0
        let observer = DefaultsObserver(keys: ["axolotl_theme_contrast"], defaults: d) { calls += 1 }
        d.set("x", forKey: "unrelated_key")
        spin()
        XCTAssertEqual(calls, 0, "a write to another key must not reload the theme")
        for v in ["high", "normal", "high"] { d.set(v, forKey: "axolotl_theme_contrast") }
        spin()
        XCTAssertEqual(calls, 1, "a burst of writes is one reload")
        withExtendedLifetime(observer) {}
    }

    func testOptionalFeatureScriptsOnlyWhenOn() {
        let key = AxolotlMaxPrefs.linkPreviews
        let keys = [key, AutofillPrefs.addresses, AutofillPrefs.cards]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (k, v) in zip(keys, saved) { UserDefaults.standard.set(v, forKey: k) }
            WebViewWrapper.samplesPageTheme = false
        }
        func setAll(_ on: Bool) { keys.forEach { UserDefaults.standard.set(on, forKey: $0) } }
        func sources(_ setup: () -> Void) -> [String] {
            setup()
            let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
            return web.ensureWebView(for: UUID()).configuration.userContentController.userScripts.map(\.source)
        }
        let off = sources { setAll(false); WebViewWrapper.samplesPageTheme = false }
        XCTAssertFalse(off.contains { $0.contains("axolotlLinkPreview") }, "link previews off: no script")
        XCTAssertFalse(off.contains { $0.contains("axolotlPageTheme") }, "page theme off: no script")
        XCTAssertFalse(off.contains { $0.contains("axolotlAutofill") }, "autofill off: no script")
        XCTAssertTrue(off.contains { $0.contains("axolotlMedia") }, "audio detection stays")
        XCTAssertTrue(off.contains { $0.contains("axolotlPasswords") })
        let on = sources { setAll(true); WebViewWrapper.samplesPageTheme = true }
        XCTAssertTrue(on.contains { $0.contains("axolotlLinkPreview") })
        XCTAssertTrue(on.contains { $0.contains("axolotlPageTheme") })
        XCTAssertTrue(on.contains { $0.contains("axolotlAutofill") })
    }

    func testHibernatorKeepsOneOneShotTimerForTheNextDueTab() throws {
        let session = ProfileSession(profileId: UUID(), dataStore: .nonPersistent(), workspace: WorkspaceStore(persistence: nil))
        let store = session.workspace, hib = session.hibernator
        let a = try XCTUnwrap(store.activeTabId)
        _ = session.webViewWrapper.ensureWebView(for: a)
        // Only the visible tab is loaded: nothing to unload, no timer.
        hib.start()
        XCTAssertNil(hib.nextSweepDate(timeout: 60))
        XCTAssertNil(hib.timer)

        let b = store.newTab(url: nil)
        store.activate(b)
        spin(0.3)
        let due = try XCTUnwrap(store.tab(a)).lastActiveAt.addingTimeInterval(hib.timeout)
        XCTAssertEqual(hib.nextSweepDate(now: due.addingTimeInterval(-1))?.timeIntervalSince(due) ?? 99, 0, accuracy: 0.01)
        let timer = try XCTUnwrap(hib.timer, "background loaded tab schedules a sweep")
        XCTAssertEqual(timer.timeInterval, 0, "one-shot, not repeating")
        XCTAssertEqual(timer.fireDate.timeIntervalSince(due), 0, accuracy: 1)

        // Past due but kept (busy): retry later instead of spinning.
        let late = due.addingTimeInterval(10)
        XCTAssertEqual(hib.nextSweepDate(now: late)?.timeIntervalSince(late) ?? 0, TabHibernator.busyRecheck, accuracy: 0.01)
        XCTAssertNil(hib.nextSweepDate(timeout: 0), "hibernation off: no timer")
        hib.stop()
        XCTAssertNil(hib.timer)
    }
}

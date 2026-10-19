import XCTest
import WebKit
@testable import Luna

/// Exercises real WKWebViews: per-tab page state for side-by-side panes,
/// hibernation, and restoring back/forward history on reactivation.
@MainActor
final class WebPaneTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("luna-pane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        WebViewWrapper.samplesPageTheme = true
    }

    override func tearDownWithError() throws {
        WebViewWrapper.samplesPageTheme = false
        try? FileManager.default.removeItem(at: dir)
    }

    private func page(_ name: String, background: String) throws -> URL {
        let url = dir.appendingPathComponent("\(name).html")
        try "<html><head><title>\(name)</title></head><body style=\"background:\(background)\">\(name)</body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeSession() -> ProfileSession {
        ProfileSession(profileId: UUID(), dataStore: .nonPersistent(), workspace: WorkspaceStore(persistence: nil))
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), "timed out: \(message)")
    }

    /// Opens a tab the way the shell does (create, then load).
    private func open(_ url: URL, in session: ProfileSession) -> UUID {
        let id = session.tabManager.newTab(url: url)
        session.webViewWrapper.setActiveTab(id)
        session.webViewWrapper.load(url: url, in: id)
        return id
    }

    private func loaded(_ session: ProfileSession, _ id: UUID, _ url: URL) -> Bool {
        guard let wv = session.webViewWrapper.webViewIfLoaded(for: id) else { return false }
        return wv.url?.standardizedFileURL == url.standardizedFileURL && !wv.isLoading
    }

    func testSideBySidePanesKeepIndependentThemeAndHistory() throws {
        let session = makeSession()
        let web = session.webViewWrapper
        let dark1 = try page("dark1", background: "#111111")
        let dark2 = try page("dark2", background: "#202020")
        let light = try page("light", background: "#fafafa")

        let a = open(dark1, in: session)
        waitUntil("dark1") { loaded(session, a, dark1) }
        web.load(url: dark2, in: a)
        waitUntil("dark2") { loaded(session, a, dark2) }
        let b = open(light, in: session)
        waitUntil("light") { loaded(session, b, light) }

        XCTAssertNotNil(session.workspace.split([a, b]))
        XCTAssertEqual(Set(session.workspace.visibleTabIds), [a, b])

        waitUntil("themes") { web.pageTheme(for: a) != nil && web.pageTheme(for: b) != nil }
        XCTAssertEqual(web.pageTheme(for: a)?.isDark, true)
        XCTAssertEqual(web.pageTheme(for: b)?.isDark, false)
        XCTAssertEqual(web.canGoBackByTab[a], true)
        XCTAssertNotEqual(web.canGoBackByTab[b], true)

        // Chrome mirrors whichever pane is focused.
        web.setActiveTab(a)
        XCTAssertTrue(web.canGoBackForActiveTab)
        XCTAssertEqual(web.pageThemeForActiveTab?.isDark, true)
        web.setActiveTab(b)
        XCTAssertFalse(web.canGoBackForActiveTab)
        XCTAssertEqual(web.pageThemeForActiveTab?.isDark, false)
    }

    func testHibernatedTabRestoresHistoryOnActivation() throws {
        let session = makeSession()
        let web = session.webViewWrapper
        let first = try page("first", background: "#111111")
        let second = try page("second", background: "#111111")

        let a = open(first, in: session)
        waitUntil("first") { loaded(session, a, first) }
        web.load(url: second, in: a)
        waitUntil("second") { loaded(session, a, second) }
        waitUntil("theme") { web.pageTheme(for: a) != nil }
        let b = open(try page("other", background: "#fff"), in: session)
        XCTAssertEqual(session.workspace.activeTabId, b)

        var unloaded: [UUID]?
        session.hibernator.sweep(now: Date().addingTimeInterval(3600), timeout: 60) { unloaded = $0 }
        waitUntil("sweep") { unloaded != nil }
        XCTAssertEqual(unloaded, [a], "only the idle background tab unloads; the visible one stays")
        XCTAssertFalse(web.loadedTabIds.contains(a))
        XCTAssertNotNil(session.workspace.tab(a)?.interactionState)
        XCTAssertNotNil(web.pageTheme(for: a), "metadata survives hibernation")

        session.tabManager.switchToTab(a)
        waitUntil("restore") { loaded(session, a, second) }
        waitUntil("history") { web.canGoBackByTab[a] == true }
        XCTAssertNil(session.workspace.tab(a)?.interactionState, "state is consumed once restored")
    }

    func testVisibleSplitPanesAreNeverHibernated() throws {
        let session = makeSession()
        let one = try page("one", background: "#000")
        let two = try page("two", background: "#fff")
        let a = open(one, in: session)
        let b = open(two, in: session)
        waitUntil("both") { loaded(session, a, one) && loaded(session, b, two) }
        _ = session.workspace.split([a, b])

        XCTAssertEqual(session.hibernator.candidates(now: Date().addingTimeInterval(3600), timeout: 60), [])
    }

    func testHibernationDisabledWithZeroTimeout() throws {
        let session = makeSession()
        let a = open(try page("x", background: "#000"), in: session)
        _ = open(try page("y", background: "#fff"), in: session)
        waitUntil("x") { session.webViewWrapper.webViewIfLoaded(for: a)?.isLoading == false }
        XCTAssertEqual(session.hibernator.candidates(now: Date().addingTimeInterval(3600), timeout: 0), [])
    }
}

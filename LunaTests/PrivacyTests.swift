import WebKit
import XCTest
@testable import Luna

@MainActor
final class PrivacyTests: XCTestCase {
    private func profileDir(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Luna/Profiles/\(id.uuidString)", isDirectory: true)
    }

    // MARK: Private window

    func testPrivateSessionWritesNothingToDisk() {
        let profile = UUID()
        let session = ProfileSession(profileId: profile, dataStore: .nonPersistent(), isPrivate: true)
        XCTAssertTrue(session.webViewWrapper.isPrivate, "password-save offers key off this")
        let tab = session.workspace.newTab(url: URL(string: "https://example.com/secret")!)
        session.historyManager.recordPageVisit(url: URL(string: "https://example.com/secret")!, title: "Secret")
        session.historyManager.addConversationSummary(
            tabId: tab, summary: ConversationSummary(tabId: tab, summary: "s", messageRange: 0...0))
        session.chatStore.setMessages([ChatMessage(role: .user, text: "hi")], for: tab)
        session.workspace.flush()
        session.historyManager.flush()
        session.chatStore.flush()

        XCTAssertTrue(session.historyManager.historyEvents.isEmpty, "private visits aren't recorded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: profileDir(profile).path),
                       "no history, chats, summaries or workspace file for the profile")
    }

    func testNormalSessionDoesWriteTheProfile() {
        // Control for the test above: the same steps on a persistent history do reach disk.
        let profile = UUID()
        defer { try? FileManager.default.removeItem(at: profileDir(profile)) }
        let history = HistoryManager(profileId: profile)
        history.recordPageVisit(url: URL(string: "https://example.com/")!, title: "E")
        history.flush()
        XCTAssertEqual(history.historyEvents.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profileDir(profile).appendingPathComponent("history.sqlite").path))
    }

    func testPrivateWindowsShareOneNonPersistentStoreUntilTheLastCloses() {
        let first = PrivateBrowsing.dataStore()
        XCTAssertFalse(first.isPersistent)
        XCTAssertTrue(PrivateBrowsing.dataStore() === first)
        PrivateBrowsing.windowClosed()  // no windows tracked: the store is dropped
        XCTAssertFalse(PrivateBrowsing.dataStore() === first)
    }

    func testPrivateSessionIgnoresProfileSwitches() {
        let store = BrowserSessionStore(isPrivate: true)
        let before = store.activeSession
        store.switchTo(profileId: UUID())
        XCTAssertTrue(store.activeSession === before)
        XCTAssertTrue(store.activeSession.isPrivate)
    }

    // MARK: HTTPS-first

    func testUpgradesPlainHTTPToHTTPS() {
        XCTAssertEqual(HTTPSUpgrade.upgrade(URL(string: "http://example.com/a?b=1#c")!)?.absoluteString, "https://example.com/a?b=1#c")
        XCTAssertEqual(HTTPSUpgrade.upgrade(URL(string: "http://example.com:80/")!)?.absoluteString, "https://example.com/")
    }

    func testLeavesNonUpgradableURLsAlone() {
        for raw in ["https://example.com/", "http://localhost:3000/", "http://localhost/", "http://192.168.1.1/",
                    "http://[::1]/", "http://printer.local/", "http://intranet/", "http://example.com:8080/", "file:///tmp/x"] {
            XCTAssertNil(HTTPSUpgrade.upgrade(URL(string: raw)!), raw)
        }
    }

    func testContinueToHTTPExemptsTheHost() {
        XCTAssertNil(HTTPSUpgrade.upgrade(URL(string: "http://Example.com/")!, exempt: ["example.com"]))
        XCTAssertNotNil(HTTPSUpgrade.upgrade(URL(string: "http://other.com/")!, exempt: ["example.com"]))
    }

    func testFailedUpgradeOffersHTTPOnTheErrorPageAndContinueLoadsIt() {
        UserDefaults.standard.removeObject(forKey: PrivacyPrefs.httpsFirst)  // default: on
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let tab = UUID()
        let http = URL(string: "http://nonexistent.invalid/page")!
        web.load(url: http, in: tab)
        let wv = web.ensureWebView(for: tab)
        XCTAssertEqual(wv.url?.scheme ?? "https", "https", "the https try goes first")
        let deadline = Date().addingTimeInterval(15)
        while web.pageErrorByTab[tab] == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertEqual(web.pageErrorByTab[tab]?.httpFallback, http)

        web.continueToHTTP(in: tab)
        XCTAssertNil(web.pageErrorByTab[tab]?.httpFallback)
        XCTAssertNil(HTTPSUpgrade.upgrade(http, exempt: ["nonexistent.invalid"]))
    }

    // MARK: Global Privacy Control

    func testGPCScriptIsRegisteredInEveryFrameAtDocumentStart() {
        UserDefaults.standard.removeObject(forKey: PrivacyPrefs.globalPrivacyControl)  // default: on
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let scripts = web.ensureWebView(for: UUID()).configuration.userContentController.userScripts
        let gpc = scripts.first { $0.source.contains("globalPrivacyControl") }
        XCTAssertNotNil(gpc)
        XCTAssertEqual(gpc?.injectionTime, .atDocumentStart)
        XCTAssertEqual(gpc?.isForMainFrameOnly, false)
    }

    func testGPCOffRegistersNoScript() {
        UserDefaults.standard.set(false, forKey: PrivacyPrefs.globalPrivacyControl)
        defer { UserDefaults.standard.removeObject(forKey: PrivacyPrefs.globalPrivacyControl) }
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let scripts = web.ensureWebView(for: UUID()).configuration.userContentController.userScripts
        XCTAssertFalse(scripts.contains { $0.source.contains("globalPrivacyControl") })
    }

    func testPrivacySettingsAreInTheRegistry() {
        for key in ["privacy.globalPrivacyControl", "privacy.httpsFirst"] {
            XCTAssertEqual(CustomizationRegistry.setting(key)?.kind, .bool, key)
        }
    }
}

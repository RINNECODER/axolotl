import XCTest
import WebKit
@testable import Axolotl

@MainActor
final class PasswordTests: XCTestCase {
    private var profile: UUID!

    override func setUp() {
        profile = UUID()
        // These hit the real Keychain: keep test logins out of iCloud.
        UserDefaults.standard.set(false, forKey: PasswordVault.syncKey(profile.uuidString))
    }

    override func tearDown() {
        for cred in PasswordVault.shared.credentials(profile: profile) {
            try? PasswordVault.shared.delete(cred, profile: profile)
        }
        UserDefaults.standard.removeObject(forKey: PasswordVault.syncKey(profile.uuidString))
    }

    func testCSVParsingHandlesQuotesCommasAndNewlines() {
        let csv = "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\n" +
            "Example,https://www.example.com/login,me@x.com,\"p,a\"\"ss\",\"line1\nline2\",\r\n" +
            "Bare,github.com,octo,hunter2,,\n"
        let rows = PasswordVault.parseCSV(csv)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1][3], "p,a\"ss")
        XCTAssertEqual(rows[1][4], "line1\nline2")
        XCTAssertEqual(rows[2][1], "github.com")
    }

    func testSaveUpdateListAndDeleteAreScopedToProfile() throws {
        let vault = PasswordVault.shared
        try vault.save(host: "www.Example.com", username: "me", password: "one", profile: profile)
        try vault.save(host: "example.com", username: "me", password: "two", profile: profile) // update, not duplicate
        XCTAssertEqual(vault.credentials(profile: profile).map(\.host), ["example.com"])
        XCTAssertTrue(vault.isSaved(host: "example.com", username: "me", password: "two", profile: profile))
        XCTAssertFalse(vault.isSaved(host: "example.com", username: "me", password: "one", profile: profile))
        XCTAssertTrue(vault.credentials(profile: UUID()).isEmpty, "other profiles can't see it")

        vault.lock()
        XCTAssertThrowsError(try vault.password(for: vault.credentials(profile: profile)[0], profile: profile),
                             "reading a password requires unlocking")

        try vault.delete(vault.credentials(profile: profile)[0], profile: profile)
        XCTAssertTrue(vault.credentials(profile: profile).isEmpty)
    }

    func testImportFromApplePasswordsCSV() throws {
        let csv = "Title,URL,Username,Password,Notes,OTPAuth\nA,https://a.example,alice,pw1,,\nNo URL,,bob,pw2,,\nB,b.example,bob,pw3,,\n"
        let result = try PasswordVault.shared.importCSV(csv, profile: profile)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(PasswordVault.shared.credentials(profile: profile).map(\.host), ["a.example", "b.example"])
    }

    // MARK: Page integration

    private let html = """
        <form id="f" onsubmit="event.preventDefault()">
          <input id="u" type="email" autocomplete="username">
          <input id="p" type="password">
          <button id="go" type="submit">Sign in</button>
        </form>
        """

    private func waitUntil(_ what: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    private func loginPage() -> (WebViewWrapper, UUID, WKWebView) {
        let web = WebViewWrapper(profileId: profile, dataStore: .nonPersistent())
        let tab = UUID()
        let wv = web.ensureWebView(for: tab)
        wv.loadHTMLString(html, baseURL: URL(string: "https://login.example.test/")!)
        waitUntil("page load") { wv.url != nil && !wv.isLoading }
        return (web, tab, wv)
    }

    /// Async tests must not spin the run loop; poll with sleeps instead.
    private func asyncWait(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    private func asyncLoginPage() async throws -> (WebViewWrapper, UUID, WKWebView) {
        let web = WebViewWrapper(profileId: profile, dataStore: .nonPersistent())
        let tab = UUID()
        let wv = web.ensureWebView(for: tab)
        wv.loadHTMLString(html, baseURL: URL(string: "https://login.example.test/")!)
        try await asyncWait("page load") { wv.url != nil && !wv.isLoading }
        return (web, tab, wv)
    }

    func testFillHelperIsHiddenFromPageAndFillsFields() async throws {
        let (_, _, wv) = try await asyncLoginPage()
        let pageSees = try await wv.evaluateJavaScript("typeof window.__axolotlFill") as? String
        XCTAssertEqual(pageSees, "undefined", "page scripts must not reach the fill function")

        let wrongHost = try await wv.callAsyncJavaScript("return window.__axolotlFill('a', 'b', 'evil.test');",
                                                        arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(wrongHost, false)

        let filled = try await wv.callAsyncJavaScript("return window.__axolotlFill(u, p, h);",
                                                     arguments: ["u": "me@x.com", "p": "s3cret", "h": "login.example.test"],
                                                     in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(filled, true)
        let values = try await wv.evaluateJavaScript("document.getElementById('u').value + '|' + document.getElementById('p').value") as? String
        XCTAssertEqual(values, "me@x.com|s3cret")
    }

    func testPrivateWindowNeverOffersToSave() async throws {
        let (web, _, wv) = try await asyncLoginPage()
        web.isPrivate = true
        _ = try await wv.evaluateJavaScript("""
            document.getElementById('u').value = 'new@x.com';
            document.getElementById('p').value = 'pw-123';
            document.getElementById('go').click();
            """)
        try await Task.sleep(for: .seconds(1))  // the normal-window test below sees its offer well within this
        XCTAssertNil(web.passwordSaveOffer)
    }

    func testSubmittingANewLoginOffersToSaveIt() async throws {
        let (web, tab, wv) = try await asyncLoginPage()
        _ = try await wv.evaluateJavaScript("""
            document.getElementById('u').value = 'new@x.com';
            document.getElementById('p').value = 'pw-123';
            document.getElementById('go').click();
            """)
        try await asyncWait("save offer") { web.passwordSaveOffer != nil }
        XCTAssertEqual(web.passwordSaveOffer?.tabId, tab)
        XCTAssertEqual(web.passwordSaveOffer?.host, "login.example.test")
        XCTAssertEqual(web.passwordSaveOffer?.username, "new@x.com")
        XCTAssertEqual(web.passwordSaveOffer?.password, "pw-123")
    }

    func testSavedLoginProducesFillOffer() throws {
        try PasswordVault.shared.save(host: "login.example.test", username: "me", password: "x", profile: profile)
        let (web, tab, _) = loginPage()
        waitUntil("fill offer") { web.passwordFillOffer != nil }
        XCTAssertEqual(web.passwordFillOffer?.tabId, tab)
        XCTAssertEqual(web.passwordFillOffer?.credentials.map(\.username), ["me"])
    }
}

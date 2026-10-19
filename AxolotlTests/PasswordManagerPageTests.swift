import XCTest
@testable import Axolotl

/// axolotl://passwords view model against `FakeKeychain` (never the real Keychain).
@MainActor
final class PasswordManagerPageTests: XCTestCase {
    private var suite: String!
    private var model: PasswordManagerModel!
    private var vault: PasswordVault!
    private let profile = UUID()

    override func setUp() {
        suite = "PasswordManagerPageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: PasswordVault.syncKey(profile.uuidString))
        vault = PasswordVault(store: KeychainStore(backend: FakeKeychain(), accessGroup: "TEAMID.com.axolotl.browser"),
                              defaults: defaults, profileNames: { [] })
        try! vault.save(host: "www.github.com", username: "octo", password: "pw1", profile: profile)
        try! vault.save(host: "github.com", username: "work", password: "pw2", profile: profile)
        try! vault.save(host: "example.com", username: "me@x.com", password: "pw3", profile: profile)
        model = PasswordManagerModel(vault: vault, profileId: profile, authenticate: { _ in false })
    }

    override func tearDown() { UserDefaults().removePersistentDomain(forName: suite) }

    func testListsBySiteAndSearchesHostAndUsername() {
        XCTAssertEqual(model.sites.map(\.host), ["example.com", "github.com"])
        XCTAssertEqual(model.sites[1].logins.map(\.username), ["octo", "work"])
        model.query = "WORK"
        XCTAssertEqual(model.sites.flatMap(\.logins).map(\.username), ["work"])
        model.query = "exam"
        XCTAssertEqual(model.sites.map(\.host), ["example.com"])
        model.query = "nothing"
        XCTAssertTrue(model.sites.isEmpty)
    }

    func testRevealNeedsDeviceAuthentication() async {
        model.select(model.credentials[0])
        let shown = await model.revealedPassword()
        XCTAssertNil(shown, "declined authentication shows nothing")
        XCTAssertNil(model.revealed)
    }

    func testAddEditAndDelete() throws {
        XCTAssertEqual(model.save(site: "", username: "a", password: "x"), "Enter a site, like example.com.")
        XCTAssertEqual(model.save(site: "new.com", username: "a", password: ""), "Enter a password.")
        XCTAssertNotNil(model.save(site: "https://github.com/login", username: "octo", password: "dup"), "already saved")

        XCTAssertNil(model.save(site: "https://www.News.com/login", username: " me ", password: "secret"))
        XCTAssertEqual(model.selection?.host, "news.com")
        XCTAssertEqual(model.selection?.username, "me")
        XCTAssertTrue(vault.isSaved(host: "news.com", username: "me", password: "secret", profile: profile))

        // Editing the username moves the login: the new one is saved, the old one is gone.
        let old = try XCTUnwrap(model.selection)
        XCTAssertNil(model.save(site: "news.com", username: "me2", password: "secret2", replacing: old))
        XCTAssertFalse(model.credentials.contains(old))
        XCTAssertTrue(vault.isSaved(host: "news.com", username: "me2", password: "secret2", profile: profile))
        // Editing only the password keeps one entry.
        XCTAssertNil(model.save(site: "news.com", username: "me2", password: "secret3", replacing: model.selection))
        XCTAssertEqual(model.credentials.filter { $0.host == "news.com" }.count, 1)

        let doomed = try XCTUnwrap(model.selection)
        model.delete(doomed)
        XCTAssertNil(model.selection)
        XCTAssertFalse(model.credentials.contains { $0.host == "news.com" })
        XCTAssertEqual(vault.credentials(profile: profile).count, 3)
    }

    func testHostParsing() {
        XCTAssertEqual(PasswordManagerModel.host(from: "https://www.example.com/a?b"), "example.com")
        XCTAssertEqual(PasswordManagerModel.host(from: " Example.com "), "example.com")
        XCTAssertNil(PasswordManagerModel.host(from: "   "))
    }
}

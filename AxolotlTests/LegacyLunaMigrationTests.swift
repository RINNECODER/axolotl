import SQLite3
import XCTest
@testable import Axolotl

/// The Luna → Axolotl copy, against temp folders, a throwaway defaults suite and
/// `FakeKeychain` (never the real ~/Library, defaults or Keychain).
final class LegacyLunaMigrationTests: XCTestCase {
    private var root: URL!
    private var oldLib: URL!
    private var newLib: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let fake = FakeKeychain()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-migration-\(UUID().uuidString)")
        oldLib = root.appendingPathComponent("old/Library")
        newLib = root.appendingPathComponent("new/Library")
        try FileManager.default.createDirectory(at: oldLib, withIntermediateDirectories: true)
        suite = "axolotl.migration.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func migration(groups: (String, String)? = nil) -> LegacyLunaMigration {
        LegacyLunaMigration(oldID: "com.luna.browser", newID: "com.axolotl.browser", oldLibrary: oldLib,
                            newLibrary: newLib, defaults: defaults, keychain: fake, keychainGroups: groups)
    }

    private func write(_ text: String, _ path: String, in lib: URL) throws {
        let url = lib.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in lib: URL) -> String? {
        try? String(contentsOf: lib.appendingPathComponent(path), encoding: .utf8)
    }

    private func writeOldDefaults(_ values: [String: Any]) throws {
        let url = oldLib.appendingPathComponent("Preferences/com.luna.browser.plist")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue((values as NSDictionary).write(to: url, atomically: true))
    }

    func testRenamesKeysValuesAndNestedSettings() {
        XCTAssertEqual(LegacyLunaMigration.renameKey("luna_theme_density"), "axolotl_theme_density")
        XCTAssertEqual(LegacyLunaMigration.renameKey("luma_ai_provider"), "axolotl_ai_provider")
        XCTAssertEqual(LegacyLunaMigration.renameKey("lunaMax.tidyTitles"), "axolotlMax.tidyTitles")
        XCTAssertEqual(LegacyLunaMigration.renameKey("browserImport.sources"), "browserImport.sources")
        XCTAssertEqual(LegacyLunaMigration.renameValue("luna") as? String, "axolotl")
        XCTAssertEqual(LegacyLunaMigration.renameValue("lunarRays") as? String, "lunarRays", "not the brand")
        let nested = LegacyLunaMigration.renameValue(["luna_frameless": true, "home": "luna://settings"]) as? [String: Any]
        XCTAssertEqual(nested?["axolotl_frameless"] as? Bool, true)
        XCTAssertEqual(nested?["home"] as? String, "axolotl://settings")
        let json = Data(#"[{"lunaProfileId":"A","url":"luma://history"}]"#.utf8)
        XCTAssertEqual((LegacyLunaMigration.renameValue(json) as? Data).flatMap { String(data: $0, encoding: .utf8) },
                       #"[{"axolotlProfileId":"A","url":"axolotl://history"}]"#)
    }

    func testCopiesOldSettingsWithoutOverwritingNewOnes() throws {
        defaults.set("kept", forKey: "axolotl_search_engine")
        try writeOldDefaults(["luna_search_engine": "old", "luma_ai_provider": "ollama", "luna_theme_preset": "luna"])
        migration().migrateDefaults()
        XCTAssertEqual(defaults.string(forKey: "axolotl_search_engine"), "kept")
        XCTAssertEqual(defaults.string(forKey: "axolotl_ai_provider"), "ollama")
        XCTAssertEqual(defaults.string(forKey: "axolotl_theme_preset"), "axolotl")
        XCTAssertNil(defaults.object(forKey: "luna_search_engine"), "old keys come over renamed")
    }

    func testCopiesDataFolderOnlyWhenAbsentAndRewritesInternalURLs() throws {
        let old = #"{"url":"luna://bookmarks","other":"https://lunar.example/luna"}"#
        try write(old, "Application Support/Luna/Profiles/P/bookmarks.json", in: oldLib)
        try write("cookies", "WebKit/com.luna.browser/WebsiteData/Default/X/c", in: oldLib)
        try write("mine", "HTTPStorages/com.axolotl.browser/x", in: newLib)
        try write("theirs", "HTTPStorages/com.luna.browser/x", in: oldLib)

        migration().run()

        XCTAssertEqual(read("Application Support/Axolotl/Profiles/P/bookmarks.json", in: newLib),
                       #"{"url":"axolotl://bookmarks","other":"https://lunar.example/luna"}"#)
        XCTAssertEqual(read("Application Support/Luna/Profiles/P/bookmarks.json", in: oldLib), old, "Luna's copy untouched")
        XCTAssertEqual(read("WebKit/com.axolotl.browser/WebsiteData/Default/X/c", in: newLib), "cookies")
        XCTAssertEqual(read("HTTPStorages/com.axolotl.browser/x", in: newLib), "mine", "never overwrites")
    }

    func testRewritesInternalURLsInHistory() throws {
        let dir = root.appendingPathComponent("hist")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("history.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
            CREATE TABLE visits(id INTEGER PRIMARY KEY, uid TEXT NOT NULL, ts REAL NOT NULL, sec INTEGER NOT NULL,
                url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '');
            INSERT INTO visits(uid, ts, sec, url) VALUES ('a', 1, 1, 'luna://settings'), ('b', 2, 2, 'luma://history'),
                ('c', 3, 3, 'https://lunar.example/');
            """, nil, nil, nil)
        sqlite3_close(db)

        LegacyLunaMigration.rewriteHistory(at: url)

        var urls: [String] = []
        sqlite3_open(url.path, &db)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "SELECT url FROM visits ORDER BY id", -1, &stmt, nil)
        while sqlite3_step(stmt) == SQLITE_ROW { urls.append(String(cString: sqlite3_column_text(stmt, 0))) }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        XCTAssertEqual(urls, ["axolotl://settings", "axolotl://history", "https://lunar.example/"])
    }

    func testRunsOnlyOnce() throws {
        try writeOldDefaults(["luna_frameless": true])
        migration().run()
        XCTAssertTrue(defaults.bool(forKey: LegacyLunaMigration.doneKey))

        try write("{}", "Application Support/Luna/later.json", in: oldLib)
        defaults.removeObject(forKey: "axolotl_frameless")
        migration().run()
        XCTAssertNil(defaults.object(forKey: "axolotl_frameless"), "second launch copies nothing")
        XCTAssertNil(read("Application Support/Axolotl/later.json", in: newLib))
    }

    func testCopiesKeychainItemsToNewGroupAndKeepsOldOnes() {
        let old = "TEAM.com.luna.browser", new = "TEAM.com.axolotl.browser"
        func item(_ extra: [String: Any]) -> [String: Any] {
            [kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: old,
             kSecAttrSynchronizable as String: false].merging(extra) { $1 }
        }
        _ = fake.add(item([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.luna.browser",
                           kSecAttrAccount as String: "luna-mcp-token", kSecValueData as String: Data("tok".utf8)]))
        _ = fake.add(item([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.luna.autofill.key",
                           kSecAttrAccount as String: "P", kSecValueData as String: Data("old-key".utf8)]))
        _ = fake.add(item([kSecClass as String: kSecClassInternetPassword, kSecAttrServer as String: "example.com",
                           kSecAttrAccount as String: "me", kSecAttrCreator as String: LegacyLunaMigration.legacyCreator,
                           kSecAttrLabel as String: "example.com (Luna)", kSecValueData as String: Data("pw".utf8)]))
        // Axolotl already has its own autofill key for P: keep it.
        _ = fake.add(item([kSecClass as String: kSecClassGenericPassword, kSecAttrAccessGroup as String: new,
                           kSecAttrService as String: AutofillStore.keyService, kSecAttrAccount as String: "P",
                           kSecValueData as String: Data("new-key".utf8)]))

        migration().migrateKeychain(from: old, to: new)

        func secret(_ query: [String: Any]) -> String? {
            let q = query.merging([kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: new,
                                   kSecReturnData as String: true]) { $1 }
            return (fake.copyMatching(q).1 as? Data).flatMap { String(data: $0, encoding: .utf8) }
        }
        XCTAssertEqual(secret([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainManager.serviceName,
                               kSecAttrAccount as String: KeychainManager.Account.axolotlMCPToken.rawValue]), "tok")
        XCTAssertEqual(secret([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AutofillStore.keyService,
                               kSecAttrAccount as String: "P"]), "new-key", "never overwrites")
        let login = fake.items.first { ($0[kSecAttrAccessGroup as String] as? String) == new && ($0[kSecAttrServer as String] as? String) == "example.com" }
        XCTAssertEqual((login?[kSecAttrCreator as String] as? NSNumber)?.uint32Value, PasswordVault.creator)
        XCTAssertEqual(login?[kSecAttrLabel as String] as? String, "example.com (Axolotl)")
        XCTAssertEqual(String(data: login?[kSecValueData as String] as? Data ?? Data(), encoding: .utf8), "pw")
        XCTAssertEqual(fake.items.filter { ($0[kSecAttrAccessGroup as String] as? String) == old }.count, 3, "Luna's items stay")
        XCTAssertFalse(fake.calls.contains { $0.op == "delete" || $0.op == "update" })
    }
}

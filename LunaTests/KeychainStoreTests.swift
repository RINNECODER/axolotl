import Security
import XCTest
@testable import Luna

/// In-memory stand-in for SecItem*: keeps legacy and data protection items
/// apart, honours kSecAttrSynchronizable(Any), and records every call.
nonisolated final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private(set) var items: [[String: Any]] = []
    private(set) var calls: [(op: String, query: [String: Any])] = []
    /// Adds whose attributes match this are refused (simulates a failed write).
    var failAdd: (([String: Any]) -> Bool)?

    private static let controlKeys: Set<String> = [
        kSecReturnData as String, kSecReturnAttributes as String, kSecMatchLimit as String,
        kSecValueData as String, kSecUseDataProtectionKeychain as String, kSecAttrSynchronizable as String,
    ]

    private static let primaryKeys: Set<String> = [
        kSecClass as String, kSecAttrService as String, kSecAttrAccount as String, kSecAttrServer as String,
        kSecAttrSecurityDomain as String, kSecAttrProtocol as String, kSecAttrAccessGroup as String,
        kSecUseDataProtectionKeychain as String, kSecAttrSynchronizable as String,
    ]

    private func isDataProtection(_ d: [String: Any]) -> Bool { d[kSecUseDataProtectionKeychain as String] as? Bool ?? false }

    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        guard isDataProtection(item) == isDataProtection(query) else { return false }
        let itemSync = item[kSecAttrSynchronizable as String] as? Bool ?? false
        switch query[kSecAttrSynchronizable as String] {
        case let flag as Bool where flag != itemSync: return false
        case nil where itemSync: return false
        default: break
        }
        for (key, value) in query where !Self.controlKeys.contains(key) {
            guard let have = item[key], (have as AnyObject).isEqual(value) else { return false }
        }
        return true
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        calls.append(("add", attributes))
        if failAdd?(attributes) == true { return errSecIO }
        // Duplicates are judged on the primary key only, like the real Keychain.
        let probe = attributes.filter { Self.primaryKeys.contains($0.key) }
        if items.contains(where: { matches($0, probe) }) { return errSecDuplicateItem }
        items.append(attributes)
        return errSecSuccess
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        calls.append(("copy", query))
        let found = items.filter { matches($0, query) }
        guard !found.isEmpty else { return (errSecItemNotFound, nil) }
        if query[kSecReturnData as String] as? Bool == true { return (errSecSuccess, found[0][kSecValueData as String] as AnyObject) }
        let attrs = found.map { $0.filter { $0.key != kSecValueData as String } }
        let all = (query[kSecMatchLimit as String] as AnyObject).isEqual(kSecMatchLimitAll)
        return (errSecSuccess, all ? attrs as NSArray : attrs[0] as NSDictionary)
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        calls.append(("update", query))
        var hit = false
        for i in items.indices where matches(items[i], query) {
            items[i].merge(attributes) { $1 }
            hit = true
        }
        return hit ? errSecSuccess : errSecItemNotFound
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        calls.append(("delete", query))
        let before = items.count
        items.removeAll { matches($0, query) }
        return items.count < before ? errSecSuccess : errSecItemNotFound
    }

    func dataProtectionItems() -> [[String: Any]] { items.filter(isDataProtection) }
    func legacyItems() -> [[String: Any]] { items.filter { !isDataProtection($0) } }
}

@MainActor
final class KeychainStoreTests: XCTestCase {
    private let group = "TEAMID.com.luna.browser"
    private var fake: FakeKeychain!
    private var store: KeychainStore!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        fake = FakeKeychain()
        store = KeychainStore(backend: fake, accessGroup: group)
        suite = "KeychainStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func assertScoped(_ query: [String: Any], _ op: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true, "\(op) not in data protection keychain", file: file, line: line)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, group, "\(op) missing access group", file: file, line: line)
        XCTAssertNotNil(query[kSecAttrSynchronizable as String], "\(op) missing synchronizable", file: file, line: line)
    }

    func testEveryOperationUsesDataProtectionKeychainAndAccessGroup() throws {
        let keys = KeychainManager(store: store)
        try keys.store("sk-test", for: .openAIKey)
        XCTAssertEqual(keys.string(for: .openAIKey), "sk-test")
        try keys.delete(.openAIKey)

        let vault = PasswordVault(store: store, defaults: defaults)
        let profile = UUID()
        try vault.save(host: "example.com", username: "me", password: "pw", profile: profile)
        try vault.save(host: "example.com", username: "me", password: "pw2", profile: profile)
        _ = vault.isSaved(host: "example.com", username: "me", password: "pw2", profile: profile)
        let creds = vault.credentials(profile: profile)
        try vault.delete(creds[0], profile: profile)

        XCTAssertEqual(Set(fake.calls.map(\.op)), ["add", "copy", "update", "delete"])
        for call in fake.calls { assertScoped(call.query, call.op) }
    }

    func testReplacingAKeyUpdatesInPlaceAndNeverDeletesFirst() throws {
        let keys = KeychainManager(store: store)
        try keys.store("sk-old", for: .openAIKey)
        fake.failAdd = { _ in true }
        try keys.store("sk-new", for: .openAIKey)
        XCTAssertEqual(keys.string(for: .openAIKey), "sk-new")
        XCTAssertFalse(fake.calls.contains { $0.op == "delete" }, "old value never removed before the new one is written")
        XCTAssertThrowsError(try keys.store("x", for: .anthropicKey), "a failed first write still reports")
    }

    func testAPIKeysStayOnDeviceAndLoginsSync() throws {
        try KeychainManager(store: store).store("sk-test", for: .anthropicKey)
        try PasswordVault(store: store, defaults: defaults).save(host: "example.com", username: "me", password: "pw", profile: UUID())

        let key = try XCTUnwrap(fake.items.first { ($0[kSecClass as String] as AnyObject).isEqual(kSecClassGenericPassword) })
        XCTAssertEqual(key[kSecAttrService as String] as? String, "com.luna.browser")
        XCTAssertEqual(key[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertTrue((key[kSecAttrAccessible as String] as AnyObject).isEqual(kSecAttrAccessibleWhenUnlockedThisDeviceOnly))

        let login = try XCTUnwrap(fake.items.first { ($0[kSecClass as String] as AnyObject).isEqual(kSecClassInternetPassword) })
        XCTAssertEqual(login[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertTrue((login[kSecAttrAccessible as String] as AnyObject).isEqual(kSecAttrAccessibleWhenUnlocked),
                      "synced items can't be ThisDeviceOnly")
    }

    func testICloudToggleMovesExistingLogins() throws {
        let vault = PasswordVault(store: store, defaults: defaults)
        let profile = UUID()
        XCTAssertTrue(vault.isICloudSyncEnabled(profile: profile), "on by default")
        try vault.save(host: "example.com", username: "me", password: "pw", profile: profile)

        try vault.setICloudSync(false, profile: profile)
        XCTAssertFalse(vault.isICloudSyncEnabled(profile: profile))
        XCTAssertEqual(fake.items.map { $0[kSecAttrSynchronizable as String] as? Bool }, [false])
        XCTAssertTrue(vault.isSaved(host: "example.com", username: "me", password: "pw", profile: profile))

        try vault.save(host: "other.com", username: "me", password: "pw", profile: profile)
        try vault.setICloudSync(true, profile: profile)
        XCTAssertEqual(fake.items.map { $0[kSecAttrSynchronizable as String] as? Bool }, [true, true])
        XCTAssertEqual(vault.credentials(profile: profile).map(\.host), ["example.com", "other.com"])
    }

    // MARK: Migration

    private func seedLegacy(profile: UUID) {
        _ = fake.add(store.legacyScoped([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.luma.browser",
                             kSecAttrAccount as String: "openai-api-key", kSecValueData as String: Data("sk-old".utf8)]))
        _ = fake.add(store.legacyScoped([kSecClass as String: kSecClassInternetPassword, kSecAttrCreator as String: PasswordVault.creator,
                             kSecAttrSecurityDomain as String: profile.uuidString, kSecAttrServer as String: "example.com",
                             kSecAttrAccount as String: "me", kSecValueData as String: Data("pw".utf8)]))
    }

    private func migrator() -> KeychainMigrator {
        var m = KeychainMigrator(store: store, defaults: defaults)
        let defaults = defaults!
        m.vaultSync = { defaults.object(forKey: PasswordVault.syncKey($0)) as? Bool ?? true }
        return m
    }

    func testMigrationMovesLegacyItemsAndRenamesService() throws {
        let profile = UUID()
        seedLegacy(profile: profile)
        let m = migrator()
        XCTAssertTrue(m.legacyItemsExist())

        XCTAssertEqual(m.run(), .init(migrated: 2, failed: 0))
        XCTAssertTrue(m.isDone)
        XCTAssertTrue(fake.legacyItems().isEmpty, "legacy copies deleted")
        XCTAssertFalse(m.legacyItemsExist())
        XCTAssertEqual(KeychainManager(store: store).string(for: .openAIKey), "sk-old", "moved to com.luna.browser")
        let vault = PasswordVault(store: store, defaults: defaults)
        XCTAssertTrue(vault.isSaved(host: "example.com", username: "me", password: "pw", profile: profile))
        XCTAssertEqual(fake.dataProtectionItems().count, 2)
    }

    func testMigrationKeepsLegacyItemWhenWriteFailsAndRetries() {
        let profile = UUID()
        seedLegacy(profile: profile)
        fake.failAdd = { ($0[kSecClass as String] as AnyObject).isEqual(kSecClassInternetPassword) }
        let m = migrator()

        XCTAssertEqual(m.run(), .init(migrated: 1, failed: 1))
        XCTAssertFalse(m.isDone, "retry next launch")
        XCTAssertEqual(fake.legacyItems().count, 1, "failed item kept in the legacy keychain")
        XCTAssertTrue(m.legacyItemsExist())

        fake.failAdd = nil
        XCTAssertEqual(m.run(), .init(migrated: 1, failed: 0))
        XCTAssertTrue(m.isDone)
        XCTAssertTrue(fake.legacyItems().isEmpty)
    }

    func testMigrationRespectsProfileSyncSetting() {
        let profile = UUID()
        defaults.set(false, forKey: PasswordVault.syncKey(profile.uuidString))
        seedLegacy(profile: profile)
        migrator().run()
        let login = fake.dataProtectionItems().first { ($0[kSecClass as String] as AnyObject).isEqual(kSecClassInternetPassword) }
        XCTAssertEqual(login?[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testNothingToMigrateWhenLegacyKeychainIsEmpty() {
        XCTAssertFalse(migrator().legacyItemsExist())
        XCTAssertEqual(migrator().run(), .init())
    }
}

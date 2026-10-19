import Security
import XCTest
@testable import Luna

/// Synced logins are keyed by profile name so they line up across Macs;
/// device-only logins keep the profile UUID. Runs against `FakeKeychain`.
@MainActor
final class PasswordSyncKeyTests: XCTestCase {
    private var fake: FakeKeychain!
    private var store: KeychainStore!
    private var defaults: UserDefaults!
    private var suite: String!
    private var names: [(id: UUID, name: String)] = []

    override func setUp() {
        fake = FakeKeychain()
        store = KeychainStore(backend: fake, accessGroup: "TEAMID.com.luna.browser")
        suite = "PasswordSyncKeyTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        names = []
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    private func vault() -> PasswordVault {
        PasswordVault(store: store, defaults: defaults, profileNames: { [unowned self] in self.names })
    }

    private func profile(_ name: String) -> UUID {
        let id = UUID()
        names.append((id, name))
        return id
    }

    private func logins() -> [[String: Any]] {
        fake.dataProtectionItems().filter { ($0[kSecClass as String] as AnyObject).isEqual(kSecClassInternetPassword) }
    }

    private func domains() -> [String] { logins().compactMap { $0[kSecAttrSecurityDomain as String] as? String }.sorted() }

    private func seedSynced(domain: String, host: String, user: String = "me", secret: String, modified: Date? = nil) {
        var item = PasswordVault.baseQuery(domain: domain)
        item[kSecAttrServer as String] = host
        item[kSecAttrAccount as String] = user
        item[kSecValueData as String] = Data(secret.utf8)
        if let modified { item[kSecAttrModificationDate as String] = modified }
        XCTAssertEqual(store.add(item, sync: .synchronizable), errSecSuccess)
    }

    // MARK: Normalization

    func testNameKeyTrimsFoldsCaseAndNormalizesUnicode() {
        XCTAssertEqual(PasswordVault.nameKey("  Work "), "name:work")
        XCTAssertEqual(PasswordVault.nameKey("WORK"), PasswordVault.nameKey("work"))
        XCTAssertEqual(PasswordVault.nameKey("Caf\u{E9}"), PasswordVault.nameKey("Cafe\u{301}"), "precomposed == decomposed")
        XCTAssertEqual(PasswordVault.nameKey("\u{FF37}ork"), "name:work", "compatibility forms fold")
        XCTAssertNotEqual(PasswordVault.nameKey("Work"), PasswordVault.nameKey("Home"))
        XCTAssertNil(PasswordVault.nameKey("   "))
    }

    func testSyncedLoginsAreKeyedByNameAndAreVisibleToAnotherMacsProfile() throws {
        let mac1 = profile("Work")
        try vault().save(host: "example.com", username: "me", password: "pw", profile: mac1)
        XCTAssertEqual(domains(), ["name:work"])

        // Same synced item, different Mac: profile has a different UUID but the same name.
        names = []
        let mac2 = profile(" work")
        XCTAssertTrue(vault().isSaved(host: "example.com", username: "me", password: "pw", profile: mac2))
        XCTAssertEqual(vault().credentials(profile: mac2).map(\.host), ["example.com"])
    }

    // MARK: Sync off

    func testSyncOffKeepsUUIDKeyAndIgnoresRenames() throws {
        let id = profile("Work")
        let v = vault()
        try v.setICloudSync(false, profile: id)
        try v.save(host: "example.com", username: "me", password: "pw", profile: id)
        XCTAssertEqual(domains(), [id.uuidString])
        XCTAssertEqual(logins().first?[kSecAttrSynchronizable as String] as? Bool, false)

        try v.rekeyForRename(profile: id, from: "Work", to: "Job")
        names = [(id, "Job")]
        XCTAssertEqual(domains(), [id.uuidString])
        XCTAssertTrue(v.isSaved(host: "example.com", username: "me", password: "pw", profile: id))
    }

    func testTogglingSyncMovesBetweenUUIDAndNameKeys() throws {
        let id = profile("Work")
        let v = vault()
        try v.setICloudSync(false, profile: id)
        try v.save(host: "example.com", username: "me", password: "pw", profile: id)
        try v.setICloudSync(true, profile: id)
        XCTAssertEqual(domains(), ["name:work"])
        try v.setICloudSync(false, profile: id)
        XCTAssertEqual(domains(), [id.uuidString])
    }

    // MARK: Rename

    func testRenameRekeysSyncedLogins() throws {
        let id = profile("Work")
        let v = vault()
        try v.save(host: "example.com", username: "me", password: "pw", profile: id)
        try v.rekeyForRename(profile: id, from: "Work", to: "Job")
        names = [(id, "Job")]
        XCTAssertEqual(domains(), ["name:job"])
        XCTAssertTrue(v.isSaved(host: "example.com", username: "me", password: "pw", profile: id))
    }

    func testRenameCollisionMergesKeepingNewestPerHostAndUser() throws {
        let id = profile("Work")
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        seedSynced(domain: "name:work", host: "a.com", secret: "work-newer", modified: new)
        seedSynced(domain: "name:job", host: "a.com", secret: "job-older", modified: old)
        seedSynced(domain: "name:work", host: "b.com", secret: "work-older", modified: old)
        seedSynced(domain: "name:job", host: "b.com", secret: "job-newer", modified: new)
        seedSynced(domain: "name:work", host: "only-work.com", secret: "w")
        seedSynced(domain: "name:job", host: "only-job.com", secret: "j")

        let v = vault()
        try v.rekeyForRename(profile: id, from: "Work", to: "Job")
        names = [(id, "Job")]

        XCTAssertEqual(domains(), Array(repeating: "name:job", count: 4), "no duplicates, nothing left under the old key")
        XCTAssertTrue(v.isSaved(host: "a.com", username: "me", password: "work-newer", profile: id))
        XCTAssertTrue(v.isSaved(host: "b.com", username: "me", password: "job-newer", profile: id))
        XCTAssertEqual(v.credentials(profile: id).map(\.host), ["a.com", "b.com", "only-job.com", "only-work.com"])
    }

    func testRenameToCaseVariantIsNoOp() throws {
        let id = profile("Work")
        try vault().save(host: "example.com", username: "me", password: "pw", profile: id)
        let before = fake.calls.count
        try vault().rekeyForRename(profile: id, from: "Work", to: "WORK ")
        XCTAssertEqual(domains(), ["name:work"])
        XCTAssertEqual(fake.calls.count, before, "same key, no keychain traffic")
    }

    // MARK: Duplicate names

    func testDuplicateNamesFallBackToUUIDSoProfilesStaySeparate() throws {
        let a = profile("Work"), b = profile("work")
        let v = vault()
        XCTAssertTrue(v.hasDuplicateName(profile: a))
        try v.save(host: "example.com", username: "me", password: "pw", profile: a)
        XCTAssertEqual(domains(), [a.uuidString])
        XCTAssertEqual(v.credentials(profile: b).count, 0)
    }

    // MARK: Migration

    func testMigrationMovesUUIDKeyedSyncedLoginsToNameKeyOnce() throws {
        let synced = profile("Work"), off = profile("Home")
        defaults.set(false, forKey: PasswordVault.syncKey(off.uuidString))
        seedSynced(domain: synced.uuidString, host: "example.com", secret: "pw")
        var local = PasswordVault.baseQuery(domain: off.uuidString)
        local[kSecAttrServer as String] = "home.com"; local[kSecAttrAccount as String] = "me"
        local[kSecValueData as String] = Data("x".utf8)
        XCTAssertEqual(store.add(local, sync: .deviceOnly), errSecSuccess)

        let v = vault()
        XCTAssertTrue(v.migrateToNameKeys())
        XCTAssertEqual(domains(), ["name:work", off.uuidString].sorted())
        XCTAssertTrue(v.isSaved(host: "example.com", username: "me", password: "pw", profile: synced))

        let calls = fake.calls.count
        XCTAssertTrue(v.migrateToNameKeys())
        XCTAssertEqual(fake.calls.count, calls, "runs once")
    }

    func testLegacyMigratorWritesSyncedLoginsUnderNameKey() {
        let id = profile("Work")
        _ = store.legacyAdd([kSecClass as String: kSecClassInternetPassword, kSecAttrCreator as String: PasswordVault.creator,
                             kSecAttrSecurityDomain as String: id.uuidString, kSecAttrServer as String: "example.com",
                             kSecAttrAccount as String: "me", kSecValueData as String: Data("pw".utf8)])
        var m = KeychainMigrator(store: store, defaults: defaults)
        m.vaultSync = { _ in true }
        let domains = vault().syncDomainSnapshot()
        m.vaultDomain = { domains[$0] ?? $0 }
        XCTAssertEqual(m.run().failed, 0)
        XCTAssertEqual(self.domains(), ["name:work"])
        XCTAssertTrue(vault().isSaved(host: "example.com", username: "me", password: "pw", profile: id))
    }
}

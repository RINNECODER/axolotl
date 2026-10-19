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
        item[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
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

    // MARK: Sync toggle safety

    private func secret(_ host: String, in domain: String) -> String? {
        logins().first { $0[kSecAttrServer as String] as? String == host && $0[kSecAttrSecurityDomain as String] as? String == domain }
            .flatMap { $0[kSecValueData as String] as? Data }.map { String(decoding: $0, as: UTF8.self) }
    }

    func testTurningSyncOnKeepsTheNewerCopyOnConflict() throws {
        let id = profile("Work")
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        for (host, secret, modified) in [("a.com", "device-new", new), ("b.com", "device-old", old)] {
            var item = PasswordVault.baseQuery(domain: id.uuidString)
            item[kSecAttrServer as String] = host
            item[kSecAttrAccount as String] = "me"
            item[kSecValueData as String] = Data(secret.utf8)
            item[kSecAttrModificationDate as String] = modified
            item[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            XCTAssertEqual(store.add(item, sync: .deviceOnly), errSecSuccess)
        }
        seedSynced(domain: "name:work", host: "a.com", secret: "synced-old", modified: old)
        seedSynced(domain: "name:work", host: "b.com", secret: "synced-new", modified: new)
        defaults.set(false, forKey: PasswordVault.syncKey(id.uuidString))

        try vault().setICloudSync(true, profile: id)
        XCTAssertEqual(domains(), ["name:work", "name:work"])
        XCTAssertEqual(secret("a.com", in: "name:work"), "device-new", "newer device copy replaces the older synced one")
        XCTAssertEqual(secret("b.com", in: "name:work"), "synced-new", "newer synced copy kept")
        XCTAssertTrue(vault().isICloudSyncEnabled(profile: id))
    }

    func testFailedMoveKeepsEveryLoginAndTheOldSetting() throws {
        let id = profile("Work")
        let v = vault()
        try v.setICloudSync(false, profile: id)
        try v.save(host: "a.com", username: "me", password: "pa", profile: id)
        try v.save(host: "b.com", username: "me", password: "pb", profile: id)
        fake.failAdd = { $0[kSecAttrServer as String] as? String == "b.com" }

        XCTAssertThrowsError(try v.setICloudSync(true, profile: id))
        XCTAssertFalse(v.isICloudSyncEnabled(profile: id), "setting only flips once every login moved")
        XCTAssertTrue(v.isSaved(host: "a.com", username: "me", password: "pa", profile: id))
        XCTAssertTrue(v.isSaved(host: "b.com", username: "me", password: "pb", profile: id))

        fake.failAdd = nil
        try v.setICloudSync(true, profile: id)
        XCTAssertEqual(domains(), ["name:work", "name:work"])
        XCTAssertTrue(v.isSaved(host: "a.com", username: "me", password: "pa", profile: id))
    }

    // MARK: CSV import

    func testCSVImportNeverOverwritesASavedPasswordAndDropsRepeatedRows() throws {
        let id = profile("Work")
        let v = vault()
        try v.save(host: "a.example", username: "alice", password: "newer", profile: id)
        let csv = """
            Title,URL,Username,Password
            A,https://a.example,alice,older
            B,b.example,bob,pw
            B,https://b.example,bob,pw
            B2,b.example,bob,other
            C,,carol,pw
            """
        let r = try v.importCSV(csv, profile: id)
        XCTAssertEqual([r.imported, r.skipped, r.conflicts], [1, 2, 2])
        XCTAssertTrue(v.isSaved(host: "a.example", username: "alice", password: "newer", profile: id))
        XCTAssertTrue(v.isSaved(host: "b.example", username: "bob", password: "pw", profile: id))
        XCTAssertEqual(logins().count, 2)
        XCTAssertEqual(r.summary, "Imported 1 login, skipped 2, kept 2 existing logins with a different password.")
    }

    // MARK: Profile delete

    func testDeletingAProfileRemovesItsLoginsAndSetting() throws {
        let work = profile("Work"), local = profile("Local")
        let v = vault()
        try v.save(host: "synced.com", username: "me", password: "pw", profile: work)
        try v.setICloudSync(false, profile: local)
        try v.save(host: "device.com", username: "me", password: "pw", profile: local)
        let keep = profile("Keep")
        try v.save(host: "keep.com", username: "me", password: "pw", profile: keep)

        v.deleteAll(profile: work, includingSynced: true)
        v.deleteAll(profile: local, includingSynced: true)
        XCTAssertEqual(domains(), ["name:keep"])
        XCTAssertNil(defaults.object(forKey: PasswordVault.syncKey(local.uuidString)))
    }

    func testDeletingAProfileByDefaultKeepsItsSyncedLoginsForOtherMacs() throws {
        let work = profile("Work")
        let v = vault()
        try v.setICloudSync(false, profile: work)
        try v.save(host: "device.com", username: "me", password: "pw", profile: work)
        seedSynced(domain: "name:work", host: "synced.com", secret: "pw")

        v.deleteAll(profile: work)
        XCTAssertEqual(domains(), ["name:work"], "device-only login gone, synced login kept")
        XCTAssertNil(defaults.object(forKey: PasswordVault.syncKey(work.uuidString)))
    }

    func testDeletingAProfileKeepsSyncedLoginsOfAnotherProfileWithTheSameName() throws {
        let a = profile("Work")
        try vault().save(host: "example.com", username: "me", password: "pw", profile: a)
        let b = profile("work")
        vault().deleteAll(profile: b, includingSynced: true)
        names.removeAll { $0.id == b }
        XCTAssertTrue(vault().isSaved(host: "example.com", username: "me", password: "pw", profile: a))
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
        _ = fake.add(store.legacyScoped([kSecClass as String: kSecClassInternetPassword, kSecAttrCreator as String: PasswordVault.creator,
                             kSecAttrSecurityDomain as String: id.uuidString, kSecAttrServer as String: "example.com",
                             kSecAttrAccount as String: "me", kSecValueData as String: Data("pw".utf8)]))
        var m = KeychainMigrator(store: store, defaults: defaults)
        m.vaultSync = { _ in true }
        let domains = vault().syncDomainSnapshot()
        m.vaultDomain = { domains[$0] ?? $0 }
        XCTAssertEqual(m.run().failed, 0)
        XCTAssertEqual(self.domains(), ["name:work"])
        XCTAssertTrue(vault().isSaved(host: "example.com", username: "me", password: "pw", profile: id))
    }
}

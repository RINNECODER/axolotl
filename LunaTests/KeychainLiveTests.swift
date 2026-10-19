import Security
import XCTest
@testable import Luna

/// Manual check against the real Keychain, using test-only items. Skipped
/// unless LUNA_KEYCHAIN_LIVE is set (pass TEST_RUNNER_LUNA_KEYCHAIN_LIVE to
/// xcodebuild test):
///   migrate  - write a legacy test item, migrate it, read it back
///   read     - after rebuilding Luna (new signature), read it with
///              Keychain UI disabled: success means no prompt
///   cleanup  - delete every test item
@MainActor
final class KeychainLiveTests: XCTestCase {
    private let legacyService = "com.luna.browser.test"
    private let migratedService = "com.luna.browser.test.migrated"
    private let controlService = "com.luna.browser.test.control"
    private let account = "probe"
    private let doneKey = "keychainMigratedV2.test"
    private let store = KeychainStore.shared

    private var phase: String? { ProcessInfo.processInfo.environment["LUNA_KEYCHAIN_LIVE"] }

    private func generic(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ query: [String: Any], legacy: Bool) -> OSStatus {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return (legacy ? store.legacyCopyMatching(q) : store.copyMatching(q, sync: .deviceOnly)).0
    }

    func testMigratePhase() throws {
        guard phase == "migrate" else { throw XCTSkip("set LUNA_KEYCHAIN_LIVE=migrate") }
        print("LIVE access group: \(store.accessGroup ?? "nil")")
        for service in [legacyService, controlService] {
            var add = generic(service)
            add[kSecValueData as String] = Data("test-only".utf8)
            XCTAssertEqual(store.legacyAdd(add), errSecSuccess)
        }
        UserDefaults.standard.removeObject(forKey: doneKey)
        var m = KeychainMigrator(store: store, defaults: .standard)
        m.genericServices = [(legacyService, migratedService)]
        m.vaultCreator = nil
        m.doneKey = doneKey
        XCTAssertTrue(m.legacyItemsExist())
        let result = m.run()
        print("LIVE migrate result: \(result)")
        XCTAssertEqual(result, .init(migrated: 1, failed: 0))
        XCTAssertEqual(read(generic(migratedService), legacy: false), errSecSuccess, "readable in data protection keychain")
        XCTAssertEqual(read(generic(legacyService), legacy: true), errSecItemNotFound, "legacy copy gone")
        UserDefaults.standard.removeObject(forKey: doneKey)
    }

    func testReadPhase() throws {
        guard phase == "read" else { throw XCTSkip("set LUNA_KEYCHAIN_LIVE=read") }
        // Any read that would need a prompt now fails with errSecInteractionNotAllowed instead.
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        let migrated = read(generic(migratedService), legacy: false)
        let control = read(generic(controlService), legacy: true)
        print("LIVE read after rebuild: migrated=\(migrated) legacyControl=\(control)")
        XCTAssertEqual(migrated, errSecSuccess)
    }

    func testCleanupPhase() throws {
        guard phase == "cleanup" else { throw XCTSkip("set LUNA_KEYCHAIN_LIVE=cleanup") }
        _ = store.delete(generic(migratedService), sync: .deviceOnly)
        _ = store.legacyDelete(generic(legacyService))
        _ = store.legacyDelete(generic(controlService))
        UserDefaults.standard.removeObject(forKey: doneKey)
        XCTAssertEqual(read(generic(migratedService), legacy: false), errSecItemNotFound)
        XCTAssertEqual(read(generic(controlService), legacy: true), errSecItemNotFound)
    }
}

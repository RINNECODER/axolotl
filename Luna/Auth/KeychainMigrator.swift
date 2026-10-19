import Foundation
import Security

/// One-time move of Luna's Keychain items from the legacy login keychain
/// (per-item ACLs tied to the code signature, hence the prompts after every
/// update) to the data protection keychain (`KeychainStore`).
///
/// A legacy item is deleted only after its copy is safely in the new store.
/// Anything that fails stays where it is and is retried on the next launch;
/// the done flag is set only when nothing is left behind.
nonisolated struct KeychainMigrator {
    static let doneKey = "keychainMigratedV2"

    struct Result: Equatable {
        var migrated = 0
        var failed = 0
    }

    let store: KeychainStore
    let defaults: UserDefaults
    /// Generic-password services to move: legacy name → new name.
    var genericServices: [(from: String, to: String)] = [
        (KeychainManager.legacyServiceName, KeychainManager.serviceName),
        // Same name: only the keychain changes (login keychain → data protection keychain).
        (SecretVault.defaultService, SecretVault.defaultService),
    ]
    /// Creator code of password-vault internet passwords (nil skips them).
    var vaultCreator: UInt32? = PasswordVault.creator
    /// Whether a profile's logins should sync through iCloud Keychain.
    var vaultSync: (String) -> Bool = { profile in
        UserDefaults.standard.object(forKey: PasswordVault.syncKey(profile)) as? Bool ?? true
    }
    /// Security domain a migrated login gets: profile UUID string → domain
    /// for synced logins (the profile's name key). Unknown profiles keep their UUID.
    var vaultDomain: (String) -> String = { $0 }
    var doneKey = KeychainMigrator.doneKey

    var isDone: Bool { defaults.bool(forKey: doneKey) }

    /// Whether anything is left in the legacy keychain. Reads attributes
    /// only (no secrets), so it never brings up a prompt.
    func legacyItemsExist() -> Bool {
        genericServices.contains { !legacyItems(genericQuery(service: $0.from)).isEmpty }
            || (vaultQuery().map { !legacyItems($0).isEmpty } ?? false)
    }

    /// Moves every legacy item. macOS may ask once per item for access to
    /// the old copy; that's the last time.
    @discardableResult
    func run() -> Result {
        var result = Result()
        for (from, to) in genericServices {
            for attrs in legacyItems(genericQuery(service: from)) {
                let account = attrs[kSecAttrAccount as String] as? String ?? ""
                var match = genericQuery(service: from)
                match[kSecAttrAccount as String] = account
                var add = genericQuery(service: to)
                add[kSecAttrAccount as String] = account
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                move(match: match, add: add, sync: .deviceOnly, into: &result)
            }
        }
        if let base = vaultQuery() {
            for attrs in legacyItems(base) {
                guard let server = attrs[kSecAttrServer as String] as? String,
                      let profile = attrs[kSecAttrSecurityDomain as String] as? String else { continue }
                var match = base
                match[kSecAttrServer as String] = server
                match[kSecAttrAccount as String] = attrs[kSecAttrAccount as String] as? String ?? ""
                match[kSecAttrSecurityDomain as String] = profile
                let sync = vaultSync(profile)
                var add = match
                if sync { add[kSecAttrSecurityDomain as String] = vaultDomain(profile) }
                add[kSecAttrProtocol as String] = attrs[kSecAttrProtocol as String] ?? kSecAttrProtocolHTTPS
                add[kSecAttrLabel as String] = attrs[kSecAttrLabel as String] as? String ?? "\(server) (Luna)"
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                move(match: match, add: add, sync: sync ? .synchronizable : .deviceOnly, into: &result)
            }
        }
        if result.failed == 0 { defaults.set(true, forKey: doneKey) }
        return result
    }

    // MARK: Private

    private func genericQuery(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func vaultQuery() -> [String: Any]? {
        vaultCreator.map { [kSecClass as String: kSecClassInternetPassword, kSecAttrCreator as String: $0] }
    }

    private func legacyItems(_ query: [String: Any]) -> [[String: Any]] {
        var q = query
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = store.legacyCopyMatching(q)
        guard status == errSecSuccess else { return [] }
        return result as? [[String: Any]] ?? []
    }

    private func move(match: [String: Any], add: [String: Any], sync: KeychainStore.Sync, into result: inout Result) {
        var read = match
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = store.legacyCopyMatching(read)
        guard status == errSecSuccess, let secret = data as? Data else { result.failed += 1; return }
        var item = add
        item[kSecValueData as String] = secret
        let added = store.add(item, sync: sync)
        // A duplicate means the new store already has a (newer) copy.
        guard added == errSecSuccess || added == errSecDuplicateItem else { result.failed += 1; return }
        let deleted = store.legacyDelete(match)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { result.failed += 1; return }
        result.migrated += 1
    }
}

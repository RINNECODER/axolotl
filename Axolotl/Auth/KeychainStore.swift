import Foundation
import Security

/// The raw SecItem calls, behind a protocol so tests can record queries
/// without touching the real Keychain.
nonisolated protocol KeychainBackend: Sendable {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?)
    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

nonisolated struct SystemKeychainBackend: KeychainBackend {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Every Keychain read and write in Axolotl goes through here.
///
/// Items live in the data protection keychain under Axolotl's access group.
/// Access there is granted by the app's entitlements, not by a per-item ACL
/// tied to the code signature, so rebuilding or updating Axolotl never brings up
/// "Axolotl wants to use your confidential information" prompts.
///
/// `legacy*` methods reach the old file-based login keychain and exist only
/// for the one-time migration (`KeychainMigrator`).
nonisolated final class KeychainStore: @unchecked Sendable {
    /// iCloud Keychain behaviour of an item or query.
    enum Sync {
        /// Stays on this Mac.
        case deviceOnly
        /// Syncs through iCloud Keychain.
        case synchronizable
        /// Queries only: match both kinds.
        case any
    }

    static let shared = KeychainStore()

    let backend: KeychainBackend
    /// nil lets the system pick the app's default group (first entitled one).
    let accessGroup: String?

    init(backend: KeychainBackend = SystemKeychainBackend(),
         accessGroup: String? = KeychainStore.entitledAccessGroup()) {
        self.backend = backend
        self.accessGroup = accessGroup
    }

    // MARK: Data protection keychain

    /// Adds the flags every Axolotl query carries.
    func scoped(_ query: [String: Any], sync: Sync) -> [String: Any] {
        var q = query
        q[kSecUseDataProtectionKeychain as String] = true
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        switch sync {
        case .deviceOnly: q[kSecAttrSynchronizable as String] = kCFBooleanFalse
        case .synchronizable: q[kSecAttrSynchronizable as String] = kCFBooleanTrue
        case .any: q[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }
        return q
    }

    func add(_ attributes: [String: Any], sync: Sync) -> OSStatus {
        precondition(sync != .any, "an item is either synchronizable or not")
        return backend.add(scoped(attributes, sync: sync))
    }

    func copyMatching(_ query: [String: Any], sync: Sync) -> (OSStatus, AnyObject?) {
        backend.copyMatching(scoped(query, sync: sync))
    }

    func update(_ query: [String: Any], sync: Sync, set attributes: [String: Any]) -> OSStatus {
        backend.update(scoped(query, sync: sync), attributes)
    }

    func delete(_ query: [String: Any], sync: Sync) -> OSStatus {
        backend.delete(scoped(query, sync: sync))
    }

    // MARK: Legacy login keychain (migration only)

    func legacyScoped(_ query: [String: Any]) -> [String: Any] {
        var q = query
        q[kSecUseDataProtectionKeychain as String] = false
        return q
    }

    func legacyCopyMatching(_ query: [String: Any]) -> (OSStatus, AnyObject?) {
        backend.copyMatching(legacyScoped(query))
    }

    func legacyDelete(_ query: [String: Any]) -> OSStatus {
        backend.delete(legacyScoped(query))
    }

    // MARK: Access group

    /// The first `keychain-access-groups` entry from Axolotl's own signature
    /// ("TEAMID.com.axolotl.browser"), falling back to the application identifier.
    /// Read at runtime so the team prefix is never hardcoded.
    static func entitledAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil) else { return nil }
        if let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String],
           let first = groups.first {
            return first
        }
        for key in ["com.apple.application-identifier", "application-identifier"] {
            if let id = SecTaskCopyValueForEntitlement(task, key as CFString, nil) as? String { return id }
        }
        return nil
    }
}

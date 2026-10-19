import Foundation
import LocalAuthentication
import Security

/// Saved website logins in the Keychain (internet-password items), scoped
/// per Luna profile. Reading a password requires Touch ID or the Mac
/// password, remembered for a few minutes. Logins sync through iCloud
/// Keychain unless the profile turns that off.
final class PasswordVault {
    static let shared = PasswordVault()

    struct Credential: Identifiable, Hashable {
        var id: String { "\(host)\u{1F}\(username)" }
        let host: String
        let username: String
        let modified: Date?
    }

    enum VaultError: LocalizedError {
        case locked
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .locked: return "Passwords are locked."
            case .keychain(let status): return "Keychain error \(status)."
            }
        }
    }

    /// Four-char creator code marking items Luna created ("Luna").
    nonisolated static let creator: UInt32 = 0x4C75_6E61
    private static let unlockDuration: TimeInterval = 5 * 60

    private var unlockedUntil: Date = .distantPast
    private let neverSaveKey = "luna_passwords_never_save"
    private let keychain: KeychainStore
    private let defaults: UserDefaults

    /// The local profiles (id and name); synced logins are keyed by name.
    private let profileNames: () -> [(id: UUID, name: String)]

    init(store: KeychainStore = .shared, defaults: UserDefaults = .standard,
         profileNames: @escaping () -> [(id: UUID, name: String)] = {
             ProfileManager.shared.profiles.map { ($0.id, $0.name) }
         }) {
        keychain = store
        self.defaults = defaults
        self.profileNames = profileNames
    }

    nonisolated deinit {}

    // MARK: Hosts

    /// Normalizes a host so www.example.com and example.com share logins.
    static func normalize(_ host: String) -> String {
        let h = host.lowercased()
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    // MARK: Unlock

    var isUnlocked: Bool { Date() < unlockedUntil }

    /// Asks for Touch ID / the Mac password unless recently unlocked.
    func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 60
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if ok { unlockedUntil = Date().addingTimeInterval(Self.unlockDuration) }
            return ok
        } catch {
            return false
        }
    }

    func lock() { unlockedUntil = .distantPast }

    // MARK: Profile keys

    /// Stable, Mac-independent key for a profile name: trimmed, Unicode
    /// (NFKC) normalized and case-folded. nil for a blank name.
    nonisolated static func nameKey(_ name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive], locale: nil)
        return key.isEmpty ? nil : "name:" + key
    }

    /// Where a login lives: its iCloud mode and `kSecAttrSecurityDomain`.
    /// Synced logins are keyed by profile name (the profile UUID is random per
    /// Mac); device-only logins keep the profile UUID.
    struct Scope: Equatable {
        let sync: KeychainStore.Sync
        let domain: String
    }

    /// The domain synced logins of `profile` use: its name key, or its UUID
    /// when the name is blank or shared with another local profile (so two
    /// profiles never read each other's logins).
    func syncDomain(profile: UUID) -> String {
        let profiles = profileNames()
        guard let me = profiles.first(where: { $0.id == profile }), let key = Self.nameKey(me.name),
              profiles.filter({ Self.nameKey($0.name) == key }).count == 1 else { return profile.uuidString }
        return key
    }

    /// Whether `profile` shares its name with another profile, which keeps its logins from syncing.
    func hasDuplicateName(profile: UUID) -> Bool {
        let profiles = profileNames()
        guard let me = profiles.first(where: { $0.id == profile }), let key = Self.nameKey(me.name) else { return false }
        return profiles.filter { Self.nameKey($0.name) == key }.count > 1
    }

    /// UUID string → synced domain for every profile (for the legacy migrator).
    func syncDomainSnapshot() -> [String: String] {
        Dictionary(uniqueKeysWithValues: profileNames().map { ($0.id.uuidString, syncDomain(profile: $0.id)) })
    }

    private func deviceScope(_ profile: UUID) -> Scope { Scope(sync: .deviceOnly, domain: profile.uuidString) }
    private func syncedScope(_ profile: UUID) -> Scope { Scope(sync: .synchronizable, domain: syncDomain(profile: profile)) }

    /// Where `profile`'s logins are read from: its own device-only items, plus
    /// the synced ones while iCloud sync is on.
    private func scopes(_ profile: UUID) -> [Scope] {
        isICloudSyncEnabled(profile: profile) ? [syncedScope(profile), deviceScope(profile)] : [deviceScope(profile)]
    }

    // MARK: Queries (no secrets)

    static func baseQuery(domain: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrCreator as String: Self.creator,
            kSecAttrSecurityDomain as String: domain,
        ]
    }

    // MARK: iCloud Keychain

    nonisolated static func syncKey(_ profile: String) -> String { "luna_passwords_icloud_sync.\(profile)" }
    private func syncKey(_ profile: UUID) -> String { Self.syncKey(profile.uuidString) }

    /// Whether new and existing logins of `profile` sync through iCloud Keychain (default on).
    func isICloudSyncEnabled(profile: UUID) -> Bool {
        defaults.object(forKey: syncKey(profile)) as? Bool ?? true
    }

    /// Turns iCloud sync on or off for `profile` and moves its existing logins to match.
    func setICloudSync(_ enabled: Bool, profile: UUID) throws {
        defaults.set(enabled, forKey: syncKey(profile))
        let from = enabled ? deviceScope(profile) : syncedScope(profile)
        let to = enabled ? syncedScope(profile) : deviceScope(profile)
        var query = Self.baseQuery(domain: from.domain)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = keychain.copyMatching(query, sync: from.sync)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw VaultError.keychain(status) }
        for attrs in items {
            guard let server = attrs[kSecAttrServer as String] as? String else { continue }
            var match = Self.baseQuery(domain: from.domain)
            match[kSecAttrServer as String] = server
            match[kSecAttrAccount as String] = attrs[kSecAttrAccount as String] as? String ?? ""
            var read = match
            read[kSecReturnData as String] = true
            read[kSecMatchLimit as String] = kSecMatchLimitOne
            let (readStatus, data) = keychain.copyMatching(read, sync: from.sync)
            guard readStatus == errSecSuccess, let secret = data as? Data else { throw VaultError.keychain(readStatus) }
            var add = match
            add[kSecAttrSecurityDomain as String] = to.domain
            add[kSecValueData as String] = secret
            add[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
            add[kSecAttrLabel as String] = attrs[kSecAttrLabel as String] as? String ?? "\(server) (Luna)"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = keychain.add(add, sync: to.sync)
            guard added == errSecSuccess || added == errSecDuplicateItem else { throw VaultError.keychain(added) }
            _ = keychain.delete(match, sync: from.sync)
        }
    }

    // MARK: Name keys (renames and migration)

    /// Moves every synced login from domain `from` to domain `to` in place.
    /// When `to` already has the same host and username, the newest copy wins.
    func moveSynced(from: String, to: String) throws {
        guard from != to else { return }
        var query = Self.baseQuery(domain: from)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = keychain.copyMatching(query, sync: .synchronizable)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { throw VaultError.keychain(status) }
        for attrs in items {
            guard let server = attrs[kSecAttrServer as String] as? String else { continue }
            var source = Self.baseQuery(domain: from)
            source[kSecAttrServer as String] = server
            source[kSecAttrAccount as String] = attrs[kSecAttrAccount as String] as? String ?? ""
            var target = source
            target[kSecAttrSecurityDomain as String] = to

            var probe = target
            probe[kSecReturnAttributes as String] = true
            probe[kSecMatchLimit as String] = kSecMatchLimitOne
            let (probeStatus, existing) = keychain.copyMatching(probe, sync: .synchronizable)
            if probeStatus == errSecItemNotFound {
                let moved = keychain.update(source, sync: .synchronizable, set: [kSecAttrSecurityDomain as String: to])
                guard moved == errSecSuccess else { throw VaultError.keychain(moved) }
                continue
            }
            guard probeStatus == errSecSuccess else { throw VaultError.keychain(probeStatus) }
            let theirs = (existing as? [String: Any])?[kSecAttrModificationDate as String] as? Date ?? .distantPast
            let ours = attrs[kSecAttrModificationDate as String] as? Date ?? .distantPast
            if ours > theirs {
                var read = source
                read[kSecReturnData as String] = true
                read[kSecMatchLimit as String] = kSecMatchLimitOne
                let (readStatus, data) = keychain.copyMatching(read, sync: .synchronizable)
                guard readStatus == errSecSuccess, let secret = data as? Data else { throw VaultError.keychain(readStatus) }
                let written = keychain.update(target, sync: .synchronizable, set: [kSecValueData as String: secret])
                guard written == errSecSuccess else { throw VaultError.keychain(written) }
            }
            let removed = keychain.delete(source, sync: .synchronizable)
            guard removed == errSecSuccess || removed == errSecItemNotFound else { throw VaultError.keychain(removed) }
        }
    }

    /// Re-keys `profile`'s synced logins after it is renamed from `oldName` to `newName`.
    /// Call before the new name is stored; throws (changing nothing further) on a Keychain error.
    func rekeyForRename(profile: UUID, from oldName: String, to newName: String) throws {
        guard isICloudSyncEnabled(profile: profile),
              let old = Self.nameKey(oldName), let new = Self.nameKey(newName) else { return }
        let others = profileNames().filter { $0.id != profile }
        // The old key was this profile's only if no other profile shared that name.
        let oldDomain = others.contains(where: { Self.nameKey($0.name) == old }) ? profile.uuidString : old
        try moveSynced(from: oldDomain, to: new)
    }

    private static let nameKeysMigratedKey = "luna_passwords_name_keys_v1"

    /// One-time move of synced logins from UUID keys to name keys.
    @discardableResult
    func migrateToNameKeys() -> Bool {
        guard !defaults.bool(forKey: Self.nameKeysMigratedKey) else { return true }
        var ok = true
        for p in profileNames() where isICloudSyncEnabled(profile: p.id) {
            let domain = syncDomain(profile: p.id)
            if domain != p.id.uuidString, (try? moveSynced(from: p.id.uuidString, to: domain)) == nil { ok = false }
        }
        if ok { defaults.set(true, forKey: Self.nameKeysMigratedKey) }
        return ok
    }

    func credentials(profile: UUID, host: String? = nil) -> [Credential] {
        var items: [[String: Any]] = []
        for scope in scopes(profile) {
            var query = Self.baseQuery(domain: scope.domain)
            if let host { query[kSecAttrServer as String] = Self.normalize(host) }
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            let (status, result) = keychain.copyMatching(query, sync: scope.sync)
            if status == errSecSuccess, let found = result as? [[String: Any]] { items += found }
        }
        var seen = Set<String>()
        return items.compactMap { attrs in
            guard let server = attrs[kSecAttrServer as String] as? String else { return nil }
            let cred = Credential(host: server, username: attrs[kSecAttrAccount as String] as? String ?? "",
                                  modified: attrs[kSecAttrModificationDate as String] as? Date)
            return seen.insert(cred.id).inserted ? cred : nil
        }
        .sorted { ($0.host, $0.username) < ($1.host, $1.username) }
    }

    // MARK: Secrets

    private func secret(host: String, username: String, profile: UUID) -> (OSStatus, Data?) {
        var last: OSStatus = errSecItemNotFound
        for scope in scopes(profile) {
            var query = Self.baseQuery(domain: scope.domain)
            query[kSecAttrServer as String] = host
            query[kSecAttrAccount as String] = username
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, result) = keychain.copyMatching(query, sync: scope.sync)
            if status == errSecSuccess { return (status, result as? Data) }
            if status != errSecItemNotFound { last = status }
        }
        return (last, nil)
    }

    /// Returns the password only while unlocked.
    func password(for credential: Credential, profile: UUID) throws -> String? {
        guard isUnlocked else { throw VaultError.locked }
        let (status, data) = secret(host: credential.host, username: credential.username, profile: profile)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw VaultError.keychain(status) }
        return String(data: data, encoding: .utf8)
    }

    /// Whether `password` is already what's stored (no unlock needed: compares in Keychain).
    func isSaved(host: String, username: String, password: String, profile: UUID) -> Bool {
        let (status, data) = secret(host: Self.normalize(host), username: username, profile: profile)
        guard status == errSecSuccess, let data else { return false }
        return String(data: data, encoding: .utf8) == password
    }

    func save(host: String, username: String, password: String, profile: UUID) throws {
        let server = Self.normalize(host)
        let data = Data(password.utf8)
        for scope in scopes(profile) {
            var match = Self.baseQuery(domain: scope.domain)
            match[kSecAttrServer as String] = server
            match[kSecAttrAccount as String] = username
            let update = keychain.update(match, sync: scope.sync, set: [kSecValueData as String: data])
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw VaultError.keychain(update) }
        }
        let target = isICloudSyncEnabled(profile: profile) ? syncedScope(profile) : deviceScope(profile)
        var add = Self.baseQuery(domain: target.domain)
        add[kSecAttrServer as String] = server
        add[kSecAttrAccount as String] = username
        add[kSecValueData as String] = data
        add[kSecAttrProtocol as String] = kSecAttrProtocolHTTPS
        add[kSecAttrLabel as String] = "\(server) (Luna)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = keychain.add(add, sync: target.sync)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    func delete(_ credential: Credential, profile: UUID) throws {
        for scope in scopes(profile) {
            var query = Self.baseQuery(domain: scope.domain)
            query[kSecAttrServer as String] = credential.host
            query[kSecAttrAccount as String] = credential.username
            let status = keychain.delete(query, sync: scope.sync)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError.keychain(status) }
        }
    }

    // MARK: Never save

    func isNeverSave(_ host: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: neverSaveKey) ?? []).contains(Self.normalize(host))
    }

    func setNeverSave(_ host: String, _ never: Bool) {
        var list = Set(UserDefaults.standard.stringArray(forKey: neverSaveKey) ?? [])
        if never { list.insert(Self.normalize(host)) } else { list.remove(Self.normalize(host)) }
        UserDefaults.standard.set(Array(list).sorted(), forKey: neverSaveKey)
    }

    // MARK: Import

    struct ImportResult {
        var imported = 0
        var skipped = 0
    }

    /// Imports Apple Passwords' CSV export (Title,URL,Username,Password,Notes,OTPAuth),
    /// which uses the same columns as Chrome's (name,url,username,password).
    func importCSV(_ text: String, profile: UUID) throws -> ImportResult {
        var result = ImportResult()
        let rows = Self.parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased() }),
              let urlCol = header.firstIndex(of: "url"),
              let userCol = header.firstIndex(of: "username"),
              let passCol = header.firstIndex(of: "password") else {
            throw VaultError.keychain(errSecParam)
        }
        for row in rows.dropFirst() {
            guard row.count > max(urlCol, userCol, passCol) else { result.skipped += 1; continue }
            let rawURL = row[urlCol].trimmingCharacters(in: .whitespaces)
            let url = URL(string: rawURL.contains("://") ? rawURL : "https://\(rawURL)")
            guard let host = url?.host, !host.isEmpty, !row[passCol].isEmpty else { result.skipped += 1; continue }
            try save(host: host, username: row[userCol], password: row[passCol], profile: profile)
            result.imported += 1
        }
        return result
    }

    /// RFC 4180 CSV (quoted fields, escaped quotes, newlines inside quotes).
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

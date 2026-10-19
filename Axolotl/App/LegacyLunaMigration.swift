import Foundation
import Security
import SQLite3

/// One-time copy of a Luna install (the app's former name) into Axolotl.
///
/// It only ever reads Luna's data: settings, files, website data and Keychain items are
/// copied, never moved, changed or deleted, so Luna keeps working and nothing is lost if a
/// step fails. Runs at the very start of launch, before any store or WebKit data store
/// opens, and only once (`doneKey`). Anything Axolotl already has is never overwritten.
nonisolated struct LegacyLunaMigration {
    static let doneKey = "axolotl_legacy_luna_migrated"

    // MARK: Renames (keep in sync with the Luna → Axolotl rename)

    /// Substrings rewritten in settings keys (at any depth): the same case-preserving
    /// rename the code went through. "lunar" was never renamed and isn't a key.
    static let keyRenames: [(old: String, new: String)] = [
        ("LUNA", "AXOLOTL"), ("LUMA", "AXOLOTL"),
        ("Luna", "Axolotl"), ("Luma", "Axolotl"),
        ("luna", "axolotl"), ("luma", "axolotl"),
    ]

    /// Whole string values that were renamed (ThemePreset / LayoutTemplate raw values).
    static let valueRenames: [String: String] = ["luna": "axolotl"]

    /// Tokens rewritten inside stored text: internal URLs and renamed Codable keys.
    static let textRenames: [(old: String, new: String)] = [
        ("luna-wallpaper://", "axolotl-wallpaper://"),
        ("luna://", "axolotl://"), ("luma://", "axolotl://"),
        ("\"lunaProfileId\"", "\"axolotlProfileId\""),
        ("\"originatedInLuna\"", "\"originatedInAxolotl\""),
        ("\"startedInLuna\"", "\"startedInAxolotl\""),
    ]

    /// Keychain renames: generic-password services, accounts, and the vault's creator code.
    static let serviceRenames: [String: String] = [
        "com.luna.browser": KeychainManager.serviceName,
        "Luna API Keys": SecretVault.defaultService,
        "com.luna.autofill.key": AutofillStore.keyService,
        "com.luna.autofill.card": AutofillStore.cardService,
    ]
    static let accountRenames: [String: String] = ["luna-mcp-token": KeychainManager.Account.axolotlMCPToken.rawValue]
    static let legacyCreator: UInt32 = 0x4C75_6E61 // "Luna"

    /// Data folders and files under `Library`, old → new (Caches are rebuilt, so skipped).
    /// WebKit keeps its data (per-profile `WKWebsiteDataStore(forIdentifier:)` stores under
    /// WebsiteData/Default) in `WebKit/<bundle id>`, or straight in `WebKit` inside a sandbox container.
    static func libraryItems(oldID: String, newID: String, sandboxed: Bool) -> [(old: String, new: String)] {
        [("Application Support/Luna", "Application Support/Axolotl"),
         sandboxed ? ("WebKit", "WebKit") : ("WebKit/\(oldID)", "WebKit/\(newID)"),
         ("HTTPStorages/\(oldID)", "HTTPStorages/\(newID)"),
         ("HTTPStorages/\(oldID).binarycookies", "HTTPStorages/\(newID).binarycookies")]
    }

    // MARK: Setup

    let oldID: String
    let newID: String
    /// Luna's `~/Library` (inside its container for the sandboxed app).
    let oldLibrary: URL
    /// Axolotl's `~/Library` (inside its container for the sandboxed app).
    let newLibrary: URL
    let defaults: UserDefaults
    let keychain: KeychainBackend
    /// Keychain access groups ("TEAMID.com.luna.browser" → "TEAMID.com.axolotl.browser"); nil skips the Keychain.
    let keychainGroups: (old: String, new: String)?
    var sandboxed = false
    let fileManager = FileManager.default

    /// The live app's locations. The sandboxed app reads Luna's container through a
    /// read-only temporary-exception entitlement; the Dev app is unsandboxed.
    static func live() -> LegacyLunaMigration? {
        guard let newID = Bundle.main.bundleIdentifier, newID.hasPrefix("com.axolotl.") else { return nil }
        let oldID = newID.replacingOccurrences(of: "com.axolotl.", with: "com.luna.")
        let newLibrary = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        var oldLibrary = newLibrary
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        if sandboxed, let home = getpwuid(getuid())?.pointee.pw_dir {
            oldLibrary = URL(fileURLWithPath: String(cString: home))
                .appendingPathComponent("Library/Containers/\(oldID)/Data/Library", isDirectory: true)
        }
        let groups = KeychainStore.entitledAccessGroup().flatMap { group -> (String, String)? in
            guard group.hasSuffix(newID) else { return nil }
            return (String(group.dropLast(newID.count)) + oldID, group)
        }
        return LegacyLunaMigration(oldID: oldID, newID: newID, oldLibrary: oldLibrary, newLibrary: newLibrary,
                                   defaults: .standard, keychain: SystemKeychainBackend(), keychainGroups: groups,
                                   sandboxed: sandboxed)
    }

    /// Call first thing at launch. Never in unit tests (they run inside the app).
    static func runAtLaunch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        live()?.run()
    }

    // MARK: Run

    func run() {
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        migrateDefaults()
        for item in Self.libraryItems(oldID: oldID, newID: newID, sandboxed: sandboxed) {
            let copied = copyMissing(oldLibrary.appendingPathComponent(item.old), to: newLibrary.appendingPathComponent(item.new))
            if item.new.hasPrefix("Application Support/") { copied.forEach(rewriteStoredURLs) }
        }
        if let keychainGroups { migrateKeychain(from: keychainGroups.old, to: keychainGroups.new) }
        defaults.set(true, forKey: Self.doneKey)
    }

    // MARK: Settings

    func migrateDefaults() {
        let plist = oldLibrary.appendingPathComponent("Preferences/\(oldID).plist")
        guard let old = NSDictionary(contentsOf: plist) as? [String: Any] else { return }
        for (key, value) in old {
            let newKey = Self.renameKey(key)
            guard newKey != Self.doneKey, defaults.object(forKey: newKey) == nil else { continue }
            defaults.set(Self.renameValue(value), forKey: newKey)
        }
    }

    static func renameKey(_ key: String) -> String {
        keyRenames.reduce(key) { $0.replacingOccurrences(of: $1.old, with: $1.new) }
    }

    static func renameText(_ text: String) -> String {
        textRenames.reduce(text) { $0.replacingOccurrences(of: $1.old, with: $1.new) }
    }

    /// Strings, JSON-in-Data and nested settings, with renamed keys inside dictionaries too.
    static func renameValue(_ value: Any) -> Any {
        switch value {
        case let s as String:
            return valueRenames[s] ?? renameText(s)
        case let d as Data:
            guard let text = String(data: d, encoding: .utf8) else { return d }
            return Data(renameText(text).utf8)
        case let a as [Any]:
            return a.map(renameValue)
        case let dict as [String: Any]:
            return Dictionary(dict.map { (renameKey($0.key), renameValue($0.value)) }) { a, _ in a }
        default:
            return value
        }
    }

    // MARK: Files

    /// Copies whatever of `from` is missing at `to`: the whole item when `to` doesn't exist,
    /// else folder by folder. Existing files are never overwritten, and neither are the
    /// SQLite sidecars (-wal/-shm/-journal) of an existing database. Returns the copied items.
    @discardableResult
    func copyMissing(_ from: URL, to: URL) -> [URL] {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: from.path, isDirectory: &isDir) else { return [] }
        guard fileManager.fileExists(atPath: to.path) else {
            do {
                try fileManager.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: from, to: to)
                return [to]
            } catch {
                try? fileManager.removeItem(at: to) // only ever our own half copy: `to` didn't exist
                return []
            }
        }
        guard isDir.boolValue, let children = try? fileManager.contentsOfDirectory(atPath: from.path) else { return [] }
        let existing = Set(children.filter { fileManager.fileExists(atPath: to.appendingPathComponent($0).path) })
        return children.flatMap { name -> [URL] in
            let db = ["-wal", "-shm", "-journal"].first(where: name.hasSuffix).map { String(name.dropLast($0.count)) }
            if let db, existing.contains(db) { return [] }
            return copyMissing(from.appendingPathComponent(name), to: to.appendingPathComponent(name))
        }
    }

    /// Rewrites luna:// URLs and renamed keys in Axolotl's fresh copy (JSON stores and history).
    func rewriteStoredURLs(in item: URL) {
        let files = fileManager.enumerator(at: item, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        for url in files + [item] {
            switch url.pathExtension {
            case "json":
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let renamed = Self.renameText(text)
                if renamed != text { try? Data(renamed.utf8).write(to: url, options: .atomic) }
            case "sqlite" where url.lastPathComponent == "history.sqlite":
                Self.rewriteHistory(at: url)
            default:
                continue
            }
        }
    }

    static func rewriteHistory(at url: URL) {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { return }
        sqlite3_exec(db, """
            UPDATE OR IGNORE visits SET url = 'axolotl://' || substr(url, 8)
            WHERE url LIKE 'luna://%' OR url LIKE 'luma://%';
            """, nil, nil, nil)
    }

    // MARK: Keychain

    private static let copiedAttributes: [String] = [
        kSecAttrService, kSecAttrAccount, kSecAttrServer, kSecAttrProtocol, kSecAttrPort, kSecAttrPath,
        kSecAttrAuthenticationType, kSecAttrSecurityDomain, kSecAttrLabel, kSecAttrDescription,
        kSecAttrComment, kSecAttrGeneric, kSecAttrCreator, kSecAttrAccessible, kSecAttrSynchronizable,
    ].map { $0 as String }

    private static let lookupAttributes: Set<String> = Set([
        kSecAttrService, kSecAttrAccount, kSecAttrServer, kSecAttrProtocol, kSecAttrPort, kSecAttrPath,
        kSecAttrAuthenticationType, kSecAttrSecurityDomain, kSecAttrSynchronizable,
    ].map { $0 as String })

    /// Copies every item in Luna's access group into Axolotl's (read old, add new; never
    /// deletes). Items Axolotl already has stay as they are (errSecDuplicateItem).
    func migrateKeychain(from oldGroup: String, to newGroup: String) {
        for itemClass in [kSecClassGenericPassword, kSecClassInternetPassword] {
            let base: [String: Any] = [kSecClass as String: itemClass, kSecUseDataProtectionKeychain as String: true,
                                       kSecAttrAccessGroup as String: oldGroup]
            var list = base
            list[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
            list[kSecReturnAttributes as String] = true
            list[kSecMatchLimit as String] = kSecMatchLimitAll
            let (status, found) = keychain.copyMatching(list)
            guard status == errSecSuccess, let items = found as? [[String: Any]] else { continue }
            for attrs in items {
                var lookup = base.merging(attrs.filter { Self.lookupAttributes.contains($0.key) }) { a, _ in a }
                lookup[kSecReturnData as String] = true
                guard let secret = keychain.copyMatching(lookup).1 as? Data else { continue }
                var add = attrs.filter { Self.copiedAttributes.contains($0.key) }
                add[kSecClass as String] = itemClass
                add[kSecUseDataProtectionKeychain as String] = true
                add[kSecAttrAccessGroup as String] = newGroup
                add[kSecValueData as String] = secret
                for (key, map) in [(kSecAttrService as String, Self.serviceRenames), (kSecAttrAccount as String, Self.accountRenames)] {
                    if let old = add[key] as? String, let new = map[old] { add[key] = new }
                }
                if (add[kSecAttrCreator as String] as? NSNumber)?.uint32Value == Self.legacyCreator {
                    add[kSecAttrCreator as String] = PasswordVault.creator
                }
                for key in [kSecAttrLabel as String, kSecAttrDescription as String] {
                    if let text = add[key] as? String { add[key] = text.replacingOccurrences(of: "Luna", with: "Axolotl") }
                }
                _ = keychain.add(add)
            }
        }
    }
}

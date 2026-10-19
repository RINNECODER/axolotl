import AppKit
import Foundation
import Security

/// Where keys grabbed by Luna go: a Keychain generic password (service "Luna API Keys",
/// account "<service>/<key name>") plus the clipboard. Items live in the data protection keychain
/// through `KeychainStore`, stay on this Mac and are never synced to iCloud.
/// Values only ever arrive from `SecretCapture` and leave through `copy`; callers outside get
/// only the Keychain item name. Nothing here logs or returns a value to a model.
final class SecretVault {
    static let shared = SecretVault()
    static let defaultService = "Luna API Keys"
    static let autoClearKey = "luna_grab_clipboard_autoclear"
    static let autoClearSeconds: TimeInterval = 90

    struct Item: Equatable, Identifiable {
        let account: String
        let created: Date?
        var id: String { account }
    }

    struct Saved: Equatable {
        /// "Luna API Keys / <account>", as Keychain Access shows it.
        let keychainItem: String
        let account: String
    }

    enum VaultError: LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            if case .keychain(let s) = self { return "Keychain error \(s)." }
            return nil
        }
    }

    let service: String
    let pasteboard: NSPasteboard
    private let keychain: KeychainStore

    init(service: String = SecretVault.defaultService, pasteboard: NSPasteboard = .general,
         keychain: KeychainStore = .shared) {
        self.service = service
        self.pasteboard = pasteboard
        self.keychain = keychain
    }

    /// Saves the value under a new account, copies it, and returns where it went. An existing account is
    /// never overwritten: the name gets `-2`, `-3`… instead. The value is not kept in memory.
    func store(_ value: String, account requested: String) throws -> Saved {
        let data = Data(value.utf8)
        var account = requested
        var suffix = 1
        while true {
            var add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service, kSecAttrAccount as String: account]
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "\(service): \(account)"
            add[kSecAttrDescription as String] = "API key saved by Luna"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = keychain.add(add, sync: .deviceOnly)
            if status == errSecSuccess { break }
            guard status == errSecDuplicateItem, suffix < 1000 else { throw VaultError.keychain(status) }
            suffix += 1
            account = "\(requested)-\(suffix)"
        }
        Self.putOnPasteboard(value, pasteboard: pasteboard)
        return Saved(keychainItem: "\(service) / \(account)", account: account)
    }

    /// Saved keys without their values, newest first.
    func items() -> [Item] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        let (status, result) = keychain.copyMatching(query, sync: .deviceOnly)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { attrs in
            (attrs[kSecAttrAccount as String] as? String).map {
                Item(account: $0, created: attrs[kSecAttrCreationDate as String] as? Date)
            }
        }
        .sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
    }

    /// Copies a saved key to the clipboard (Settings → Copy).
    @discardableResult
    func copy(account: String) -> Bool {
        guard let value = value(account: account) else { return false }
        Self.putOnPasteboard(value, pasteboard: pasteboard)
        return true
    }

    func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        _ = keychain.delete(query, sync: .deviceOnly)
    }

    /// The stored value; only for `copy` and tests that compare it. Never return it to a model.
    func value(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        let (status, result) = keychain.copyMatching(query, sync: .deviceOnly)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Optional (Settings, default on): clears the clipboard after 90 s unless something else was copied.
    static func putOnPasteboard(_ value: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Clipboard managers skip items carrying these markers (nspasteboard.org).
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard UserDefaults.standard.object(forKey: Self.autoClearKey) as? Bool ?? true else { return }
        let count = pasteboard.changeCount
        let board = pasteboard
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoClearSeconds) {
            if board.changeCount == count { board.clearContents() }
        }
    }
}

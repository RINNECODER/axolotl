import CommonCrypto
import Foundation

/// Decrypts the "v10" values Chromium browsers write for cookies and logins on macOS.
/// The AES key is derived from a password kept in the login Keychain
/// ("<Name> Safe Storage"); reading it triggers macOS's own access prompt. Axolotl
/// holds the key in memory for one import only and never stores or logs it.
nonisolated enum ChromiumCrypto {
    enum CryptoError: Error { case noKey, badValue }

    /// Keychain generic-password item that holds a browser's Safe Storage password.
    static func safeStorageService(_ kind: BrowserKind) -> (service: String, account: String)? {
        switch kind {
        case .chrome: return ("Chrome Safe Storage", "Chrome")
        case .brave: return ("Brave Safe Storage", "Brave")
        case .edge: return ("Microsoft Edge Safe Storage", "Microsoft Edge")
        case .vivaldi: return ("Vivaldi Safe Storage", "Vivaldi")
        case .arc: return ("Arc Safe Storage", "Arc")
        case .firefox, .safari: return nil
        }
    }

    /// The Safe Storage password from the login Keychain (prompts the user once).
    static func safeStoragePassword(_ kind: BrowserKind) -> String? {
        guard let item = safeStorageService(kind) else { return nil }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: item.service,
            kSecAttrAccount as String: item.account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else {
            // Some builds store the item without an account; retry without it.
            query.removeValue(forKey: kSecAttrAccount as String)
            out = nil
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    /// PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16 bytes) — Chromium's macOS key.
    static func deriveKey(password: String) -> Data {
        var key = Data(count: 16)
        let salt = Array("saltysalt".utf8)
        let pw = Array(password.utf8)
        _ = key.withUnsafeMutableBytes { keyPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 keyPtr.bindMemory(to: UInt8.self).baseAddress, 16)
        }
        return key
    }

    /// Decrypts one "v10" value: AES-128-CBC, IV of 16 spaces, PKCS#7 padding.
    /// Plaintext is returned without interpreting it; `stripHostHash` removes the
    /// 32-byte SHA256(host) prefix newer cookie DBs prepend (meta version >= 24).
    static func decrypt(_ value: Data, key: Data, stripHostHash: Bool = false) throws -> Data {
        guard value.count > 3, value.prefix(3) == Data("v10".utf8) else { throw CryptoError.badValue }
        let body = value.dropFirst(3)
        let iv = Array(repeating: UInt8(0x20), count: 16) // 16 spaces
        let capacity = body.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            body.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, 16, iv,
                            inPtr.baseAddress, body.count,
                            outPtr.baseAddress, capacity, &moved)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { throw CryptoError.badValue }
        out = out.prefix(moved)
        if stripHostHash { out = out.count >= 32 ? out.dropFirst(32) : Data() }
        return Data(out)
    }

    /// Inverse of `decrypt`, used only to build synthetic fixtures (tests never touch real data).
    static func encrypt(_ plaintext: Data, key: Data, hostHashPrefix: Data? = nil) -> Data {
        var body = Data()
        if let hostHashPrefix { body.append(hostHashPrefix) }
        body.append(plaintext)
        let iv = Array(repeating: UInt8(0x20), count: 16)
        let capacity = body.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        _ = out.withUnsafeMutableBytes { outPtr in
            body.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, 16, iv, inPtr.baseAddress, body.count, outPtr.baseAddress, capacity, &moved)
                }
            }
        }
        return Data("v10".utf8) + out.prefix(moved)
    }
}

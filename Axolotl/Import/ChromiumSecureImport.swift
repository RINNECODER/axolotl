import Foundation

// Values parsed off the main actor; applied to the profile later.

nonisolated struct ImportedCookie: Equatable, Sendable {
    var host: String        // host_key, may have a leading dot
    var name: String
    var value: String
    var path: String
    var expires: Date
    var isSecure: Bool
    var isHTTPOnly: Bool
    var sameSite: Int       // Chromium: -1 unspecified, 0 none, 1 lax, 2 strict
}

nonisolated struct ImportedLogin: Equatable, Sendable {
    var origin: String
    var username: String
    var password: String
}

nonisolated struct ImportedAutofillAddress: Equatable, Sendable {
    var name = "", organization = "", street = "", city = "", state = "", postalCode = "", country = ""
    var phone = "", email = ""
}

/// Reads the encrypted Chromium stores (cookies, logins) and the plaintext
/// autofill store. Decryption needs the browser's Safe Storage key, injected so
/// tests can drive the same code path with a synthetic password.
nonisolated enum ChromiumSecureImport {
    typealias KeyProvider = (BrowserKind) -> Data?

    /// Default provider: derive the key from the login Keychain password (prompts once).
    static func keychainKeyProvider(_ kind: BrowserKind) -> Data? {
        ChromiumCrypto.safeStoragePassword(kind).map(ChromiumCrypto.deriveKey)
    }

    // MARK: Cookies

    static func cookies(profileFolder: URL, key: Data) throws -> [ImportedCookie] {
        // Newer Chromium keeps cookies under Network/; fall back to the old location.
        let network = profileFolder.appendingPathComponent("Network/Cookies")
        let flat = profileFolder.appendingPathComponent("Cookies")
        let file = FileManager.default.fileExists(atPath: network.path) ? network : flat
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let db = try SQLiteSnapshot(copying: file)
        let stripHostHash = metaVersion(db) >= 24
        let rows = try db.rows("""
            SELECT host_key, name, encrypted_value, path, expires_utc, is_secure, is_httponly, samesite
            FROM cookies
            """)
        let now = Date()
        return rows.compactMap { r -> ImportedCookie? in
            guard r.count == 8, let host = r[0].text, let name = r[1].text,
                  let encrypted = r[2].data, let path = r[3].text, let expires = r[4].int else { return nil }
            guard let plain = try? ChromiumCrypto.decrypt(encrypted, key: key, stripHostHash: stripHostHash),
                  let value = String(data: plain, encoding: .utf8) else { return nil }
            let expiry = ChromiumImporter.date(fromChromium: expires)
            guard expires != 0, expiry > now else { return nil } // skip session and expired cookies
            return ImportedCookie(host: host, name: name, value: value, path: path.isEmpty ? "/" : path,
                                  expires: expiry, isSecure: (r[5].int ?? 0) != 0, isHTTPOnly: (r[6].int ?? 0) != 0,
                                  sameSite: Int(r[7].int ?? -1))
        }
    }

    private static func metaVersion(_ db: SQLiteSnapshot) -> Int64 {
        (try? db.rows("SELECT value FROM meta WHERE key = 'version'"))?.first?.first?.int.flatMap { $0 }
            ?? (try? db.rows("SELECT value FROM meta WHERE key = 'version'"))?.first?.first?.text.flatMap { Int64($0) }
            ?? 0
    }

    // MARK: Logins

    static func logins(profileFolder: URL, key: Data) throws -> [ImportedLogin] {
        let file = profileFolder.appendingPathComponent("Login Data")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let db = try SQLiteSnapshot(copying: file)
        let rows = try db.rows("SELECT origin_url, username_value, password_value FROM logins")
        return rows.compactMap { r -> ImportedLogin? in
            guard r.count == 3, let origin = r[0].text, let username = r[1].text,
                  let encrypted = r[2].data, !origin.isEmpty else { return nil }
            guard let plain = try? ChromiumCrypto.decrypt(encrypted, key: key),
                  let password = String(data: plain, encoding: .utf8), !password.isEmpty else { return nil }
            return ImportedLogin(origin: origin, username: username, password: password)
        }
    }

    // MARK: Autofill addresses

    static func addresses(profileFolder: URL) throws -> [ImportedAutofillAddress] {
        let file = profileFolder.appendingPathComponent("Web Data")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let db = try SQLiteSnapshot(copying: file)
        // Two schema eras: the old `autofill_profiles`(+phones/emails) and the newer `addresses`+`contact_info`.
        if db.hasTable("autofill_profiles") {
            return legacyAddresses(db)
        } else if db.hasTable("local_addresses") || db.hasTable("addresses") {
            return modernAddresses(db)
        }
        return [] // unknown schema: skip
    }

    private static func legacyAddresses(_ db: SQLiteSnapshot) -> [ImportedAutofillAddress] {
        let rows = (try? db.rows("""
            SELECT guid, company_name, street_address, city, state, zipcode, country_code
            FROM autofill_profiles
            """)) ?? []
        return rows.compactMap { r in
            guard r.count == 7, let guid = r[0].text else { return nil }
            var a = ImportedAutofillAddress(organization: r[1].text ?? "", street: r[2].text ?? "",
                                            city: r[3].text ?? "", state: r[4].text ?? "",
                                            postalCode: r[5].text ?? "", country: r[6].text ?? "")
            a.name = firstValue(db, "SELECT first_name || ' ' || last_name FROM autofill_profile_names WHERE guid = ?", guid) ?? ""
            a.email = firstValue(db, "SELECT email FROM autofill_profile_emails WHERE guid = ?", guid) ?? ""
            a.phone = firstValue(db, "SELECT number FROM autofill_profile_phones WHERE guid = ?", guid) ?? ""
            return a.isEmpty ? nil : a
        }
    }

    private static func modernAddresses(_ db: SQLiteSnapshot) -> [ImportedAutofillAddress] {
        let table = db.hasTable("local_addresses") ? "local_addresses" : "addresses"
        let typeTable = db.hasTable("local_addresses_type_tokens") ? "local_addresses_type_tokens" : "contact_info_type_tokens"
        let rows = (try? db.rows("SELECT guid FROM \(table)")) ?? []
        return rows.compactMap { r in
            guard let guid = r[0].text else { return nil }
            // Field values are keyed by numeric server type in a side table.
            func field(_ type: Int) -> String {
                firstValue(db, "SELECT value FROM \(typeTable) WHERE guid = ? AND type = \(type)", guid) ?? ""
            }
            var a = ImportedAutofillAddress()
            a.name = field(7)           // NAME_FULL
            a.organization = field(60)  // COMPANY_NAME
            a.street = field(77)        // ADDRESS_HOME_STREET_ADDRESS
            a.city = field(33)          // ADDRESS_HOME_CITY
            a.state = field(34)         // ADDRESS_HOME_STATE
            a.postalCode = field(35)    // ADDRESS_HOME_ZIP
            a.country = field(36)       // ADDRESS_HOME_COUNTRY
            a.email = field(9)          // EMAIL_ADDRESS
            a.phone = field(14)         // PHONE_HOME_WHOLE_NUMBER
            return a.isEmpty ? nil : a
        }
    }

    private static func firstValue(_ db: SQLiteSnapshot, _ sql: String, _ guid: String) -> String? {
        // SQLiteSnapshot binds only Int64; inline the guid safely (it's a browser-generated UUID).
        let safe = guid.replacingOccurrences(of: "'", with: "''")
        let value = (try? db.rows(sql.replacingOccurrences(of: "?", with: "'\(safe)'")))?.first?.first?.text
        return value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }
}

nonisolated extension ImportedAutofillAddress {
    var isEmpty: Bool {
        [name, organization, street, city, state, postalCode, country, phone, email].allSatisfy(\.isEmpty)
    }
}

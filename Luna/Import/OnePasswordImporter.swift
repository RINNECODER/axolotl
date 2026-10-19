import Compression
import Foundation

/// Reads logins from a 1Password export: `.1pux` (a zip holding `export.data`
/// JSON) or 1Password's CSV. Luna's password store keeps site, username and
/// password, so notes, one-time codes and non-login items are counted, not stored.
enum OnePasswordImporter {
    struct Login: Equatable {
        var title: String
        var url: String
        var username: String
        var password: String
        var notes: String = ""
        var totp: String?
    }

    struct Result: Equatable {
        var logins: [Login] = []
        /// Items that aren't logins (cards, notes, identities, password-only items…).
        var skippedOtherItems = 0
        /// Logins without a website or password, which Luna can't fill.
        var skippedIncomplete = 0
        /// Logins whose notes or one-time code weren't kept.
        var droppedExtras = 0
    }

    static let loginCategory = "001"

    // MARK: 1PUX

    static func parse1PUX(at url: URL) throws -> Result {
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable(url.lastPathComponent) }
        guard let json = try ZipReader.entry(named: "export.data", in: data) else {
            throw ImportError.missingFile("export.data")
        }
        return try parseExportData(json)
    }

    static func parseExportData(_ data: Data) throws -> Result {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.unreadable("export.data")
        }
        var result = Result()
        for account in root["accounts"] as? [[String: Any]] ?? [] {
            for vault in account["vaults"] as? [[String: Any]] ?? [] {
                for item in vault["items"] as? [[String: Any]] ?? [] {
                    if let state = item["state"] as? String, state != "active" { continue } // archived/trashed
                    guard item["categoryUuid"] as? String == loginCategory else { result.skippedOtherItems += 1; continue }
                    let overview = item["overview"] as? [String: Any] ?? [:]
                    let details = item["details"] as? [String: Any] ?? [:]
                    let fields = details["loginFields"] as? [[String: Any]] ?? []
                    func field(_ designation: String) -> String? {
                        fields.first { $0["designation"] as? String == designation }?["value"] as? String
                    }
                    let urls = (overview["urls"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
                    let site = (overview["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? urls.first ?? ""
                    var login = Login(title: overview["title"] as? String ?? "", url: site,
                                      username: field("username") ?? "",
                                      password: field("password") ?? (details["password"] as? String) ?? "",
                                      notes: details["notesPlain"] as? String ?? "")
                    login.totp = totp(in: details)
                    guard !login.url.isEmpty, !login.password.isEmpty else { result.skippedIncomplete += 1; continue }
                    if !login.notes.isEmpty || login.totp != nil { result.droppedExtras += 1 }
                    result.logins.append(login)
                }
            }
        }
        return result
    }

    private static func totp(in details: [String: Any]) -> String? {
        for section in details["sections"] as? [[String: Any]] ?? [] {
            for field in section["fields"] as? [[String: Any]] ?? [] {
                if let value = field["value"] as? [String: Any], let code = value["totp"] as? String, !code.isEmpty { return code }
            }
        }
        return nil
    }

    // MARK: CSV

    /// 1Password's CSV export (Title, Url, Username, Password, OTPAuth, Favorite, Archived, Tags, Notes).
    static func parseCSV(_ text: String) -> Result {
        let rows = PasswordVault.parseCSV(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }) else { return Result() }
        func col(_ names: String...) -> Int? { names.lazy.compactMap { header.firstIndex(of: $0) }.first }
        guard let u = col("url", "website", "login_url"), let p = col("password", "login_password") else { return Result() }
        let user = col("username", "login_username"), title = col("title", "name")
        let otp = col("otpauth", "one-time password"), notes = col("notes", "notesplain"), archived = col("archived")
        var result = Result()
        for row in rows.dropFirst() where !row.allSatisfy(\.isEmpty) {
            func v(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
            if v(archived).lowercased() == "true" { continue }
            var login = Login(title: v(title), url: v(u), username: v(user), password: v(p), notes: v(notes))
            login.totp = v(otp).isEmpty ? nil : v(otp)
            guard !login.url.isEmpty, !login.password.isEmpty else { result.skippedIncomplete += 1; continue }
            if !login.notes.isEmpty || login.totp != nil { result.droppedExtras += 1 }
            result.logins.append(login)
        }
        return result
    }

    /// The CSV Luna's password import reads (url, username, password).
    static func vaultCSV(_ logins: [Login]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["url,username,password"] + logins.map { [q($0.url), q($0.username), q($0.password)].joined(separator: ",") })
            .joined(separator: "\n")
    }
}

/// Minimal zip reader: finds one entry via the central directory and inflates
/// it (stored or deflate), enough for 1Password's `.1pux`.
nonisolated enum ZipReader {
    static func entry(named name: String, in zip: Data) throws -> Data? {
        let bytes = [UInt8](zip)
        func u16(_ o: Int) -> Int { o + 1 < bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // End of central directory: signature 0x06054b50 within the last 64 KB + 22 bytes.
        guard bytes.count >= 22 else { throw ImportError.unreadable("1PUX") }
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 65_557) {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ImportError.unreadable("1PUX") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        for _ in 0..<count {
            guard u32(p) == 0x0201_4b50 else { throw ImportError.unreadable("1PUX") }
            let method = u16(p + 10), compSize = u32(p + 20), size = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32), local = u32(p + 42)
            guard p + 46 + nameLen <= bytes.count else { throw ImportError.unreadable("1PUX") }
            let entryName = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard entryName == name else { continue }
            guard u32(local) == 0x0403_4b50 else { throw ImportError.unreadable("1PUX") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compSize <= bytes.count else { throw ImportError.unreadable("1PUX") }
            let body = Data(bytes[start..<(start + compSize)])
            switch method {
            case 0: return body
            case 8: return try inflate(body, size: size)
            default: throw ImportError.unreadable("1PUX")
            }
        }
        return nil
    }

    private static func inflate(_ data: Data, size: Int) throws -> Data {
        var out = Data(count: max(size, 1))
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw ImportError.unreadable("1PUX") }
        return out.prefix(written)
    }
}

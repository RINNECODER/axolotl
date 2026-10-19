import AppKit
import Foundation
import WebKit

/// Imports the secure, Chromium-only data types (cookies, saved passwords,
/// extensions, autofill addresses) into an Axolotl profile. Reading runs off the
/// main actor; applying touches main-actor stores, so it stays here.
extension BrowserImporter {
    struct SecureSummary: Equatable {
        var cookies: Int?
        var passwords: Int?
        /// (imported, not supported) extension counts.
        var extensionsImported: Int?
        var extensionsFailed = 0
        var addresses: Int?
        /// True when cookies/passwords were requested but the Safe Storage key wasn't readable.
        var keychainUnavailable = false
        var vaultLocked = false
        var extensionsDeclined = false
        var errors: [String] = []

        var parts: [String] {
            var p: [String] = []
            if let c = cookies { p.append("\(c) cookie\(c == 1 ? "" : "s")") }
            if let pw = passwords { p.append("\(pw) password\(pw == 1 ? "" : "s")") }
            if let e = extensionsImported { p.append("\(e) extension\(e == 1 ? "" : "s")" + (extensionsFailed > 0 ? " (\(extensionsFailed) not supported)" : "")) }
            if let a = addresses { p.append("\(a) address\(a == 1 ? "" : "es")") }
            return p
        }
    }

    nonisolated struct SecureRead: Sendable {
        var cookies: [ImportedCookie]?
        var logins: [ImportedLogin]?
        var addresses: [ImportedAutofillAddress]?
        var extensionCandidates: [ChromiumExtensionImport.Candidate]?
        var keychainUnavailable = false
        var errors: [String] = []
    }

    /// Reads the requested secure types from one profile folder. `keyProvider`
    /// yields the Safe Storage key (prompting via the Keychain by default); it's
    /// injected in tests so the same decrypt path runs on synthetic fixtures.
    nonisolated static func readSecure(kind: BrowserKind, dataFolder: URL, profile: SourceProfile,
                                       types: Set<ImportDataType>,
                                       keyProvider: ChromiumSecureImport.KeyProvider = ChromiumSecureImport.keychainKeyProvider) -> SecureRead {
        var result = SecureRead()
        guard kind.engine == .chromium else { return result }
        let folder = profile.id.isEmpty ? dataFolder : dataFolder.appendingPathComponent(profile.id, isDirectory: true)
        let needsKey = types.contains(.cookies) || types.contains(.passwords)
        let key = needsKey ? keyProvider(kind) : nil
        if needsKey, key == nil { result.keychainUnavailable = true }

        if types.contains(.cookies), let key {
            do { result.cookies = try ChromiumSecureImport.cookies(profileFolder: folder, key: key) }
            catch { result.errors.append("Cookies: \(error.localizedDescription)") }
        }
        if types.contains(.passwords), let key {
            do { result.logins = try ChromiumSecureImport.logins(profileFolder: folder, key: key) }
            catch { result.errors.append("Passwords: \(error.localizedDescription)") }
        }
        if types.contains(.autofill) {
            do { result.addresses = try ChromiumSecureImport.addresses(profileFolder: folder) }
            catch { result.errors.append("Autofill: \(error.localizedDescription)") }
        }
        if types.contains(.extensions) {
            result.extensionCandidates = ChromiumExtensionImport.candidates(profileFolder: folder)
        }
        return result
    }

    // MARK: Apply (main actor)

    @MainActor
    static func applySecure(_ read: SecureRead, into axolotlProfileId: UUID) async -> SecureSummary {
        var summary = SecureSummary(keychainUnavailable: read.keychainUnavailable, errors: read.errors)

        if let cookies = read.cookies {
            let store = ProfileManager.shared.dataStore(for: axolotlProfileId).httpCookieStore
            var added = 0
            for c in cookies {
                guard let cookie = httpCookie(c) else { continue }
                await store.setCookie(cookie)
                added += 1
            }
            summary.cookies = added
        }

        if let logins = read.logins, !logins.isEmpty {
            if await PasswordVault.shared.unlock(reason: "import passwords") {
                let csv = loginsCSV(logins)
                summary.passwords = (try? PasswordVault.shared.importCSV(csv, profile: axolotlProfileId).imported) ?? 0
            } else {
                summary.vaultLocked = true
            }
        } else if read.logins != nil {
            summary.passwords = 0
        }

        if let addresses = read.addresses {
            let store = AutofillStore.forProfile(axolotlProfileId)
            var added = 0
            for a in addresses {
                let addr = AutofillAddress(name: a.name, organization: a.organization, street: a.street, city: a.city,
                                           state: a.state, postalCode: a.postalCode, country: a.country, phone: a.phone, email: a.email)
                if store.hasAddress(like: addr) { continue }
                store.save(addr)
                added += 1
            }
            summary.addresses = added
        }

        if let candidates = read.extensionCandidates {
            var imported = 0, failed = 0
            if !candidates.isEmpty, confirmExtensionBatch(candidates.map(\.name)) {
                // One alert above covers the whole batch, so skip the per-extension one.
                let library = ExtensionLibrary.shared
                let perExtension = library.confirmInstall
                library.confirmInstall = { _ in true }
                defer { library.confirmInstall = perExtension }
                for c in candidates {
                    do { _ = try await library.install(from: c.folder); imported += 1 }
                    catch { failed += 1 }
                }
            } else if !candidates.isEmpty {
                summary.extensionsDeclined = true
            }
            summary.extensionsImported = summary.extensionsDeclined ? nil : imported
            summary.extensionsFailed = failed
        }
        return summary
    }

    /// One confirmation for every extension an import would add.
    @MainActor
    static var confirmExtensionBatch: ([String]) -> Bool = { names in
        let alert = NSAlert()
        alert.messageText = "Add \(names.count == 1 ? "this extension" : "these \(names.count) extensions")?"
        alert.informativeText = names.sorted().joined(separator: "\n")
            + "\n\nThey keep the website access they had in your other browser."
        alert.addButton(withTitle: names.count == 1 ? "Add Extension" : "Add All")
        alert.addButton(withTitle: "Not Now")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Chromium's leading-dot host means "and subdomains"; HTTPCookie wants the domain and `.domainMatch`.
    static func httpCookie(_ c: ImportedCookie) -> HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [
            .name: c.name, .value: c.value, .path: c.path,
            .domain: c.host, .expires: c.expires,
        ]
        if c.isSecure { props[.secure] = "TRUE" }
        if #available(macOS 10.15, *) {
            switch c.sameSite {
            case 2: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            case 1: props[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            default: break
            }
        }
        var cookie = HTTPCookie(properties: props)
        // HTTPOnly isn't a public property key; set it through the private dictionary if accepted.
        if cookie != nil, c.isHTTPOnly {
            props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            cookie = HTTPCookie(properties: props) ?? cookie
        }
        return cookie
    }

    static func loginsCSV(_ logins: [ImportedLogin]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return (["url,username,password"] + logins.map { [q($0.origin), q($0.username), q($0.password)].joined(separator: ",") })
            .joined(separator: "\n")
    }
}

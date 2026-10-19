// Axolotl — built-in passkeys (WebAuthn, ES256 only). Keys are made in the Secure Enclave when the Mac has
// one (else a software P-256 key), stored in the Keychain on this device only, and never synced or exported.
// Keys, challenges and signatures are never logged.
import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The DOMException names a WebAuthn call rejects with.
enum WebAuthnError: String, Error {
    case notAllowed = "NotAllowedError", invalidState = "InvalidStateError"
    case security = "SecurityError", notSupported = "NotSupportedError"
}

/// Settings → Passwords → Passkeys: on by default, with sites the user turned off.
enum PasskeyPrefs {
    static let enabledKey = "axolotl_passkeys_enabled"
    static let offSitesKey = "axolotl_passkeys_off_sites"

    static func isOn(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    static func offSites(_ defaults: UserDefaults = .standard) -> [String] { defaults.stringArray(forKey: offSitesKey) ?? [] }

    static func isOn(host: String, _ defaults: UserDefaults = .standard) -> Bool {
        let h = PasswordVault.normalize(host)
        return isOn(defaults) && !offSites(defaults).contains { h == $0 || h.hasSuffix("." + $0) }
    }

    static func set(_ on: Bool, host: String, _ defaults: UserDefaults = .standard) {
        let h = PasswordVault.normalize(host)
        var sites = offSites(defaults).filter { $0 != h }
        if !on && !h.isEmpty { sites.append(h) }
        defaults.set(sites.sorted(), forKey: offSitesKey)
    }
}

/// One stored passkey. The private key is kept apart (`PasskeyStoring.key(for:)`) so listing never loads it.
struct PasskeyRecord: Codable, Identifiable, Equatable {
    var id: String { credentialId }
    let credentialId: String // base64url
    let rpId: String
    let userHandle: String // base64url
    let userName: String
    let displayName: String
    let profile: UUID
    let created: Date
    /// Secure Enclave key blob (only this Mac's enclave can use it), else a raw software key.
    let enclave: Bool
}

protocol PasskeyStoring: AnyObject {
    func all() -> [PasskeyRecord]
    func save(_ record: PasskeyRecord, key: Data) throws
    func key(for credentialId: String) -> Data?
    func delete(_ credentialId: String)
}

/// Generic-password items: account = credential id, attributes = the record, data = the key. This device only.
final class KeychainPasskeyStore: PasskeyStoring {
    static let shared = KeychainPasskeyStore()
    private static let service = "com.axolotl.passkeys"
    let store: KeychainStore

    init(store: KeychainStore = .shared) { self.store = store }

    private func query(_ id: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        if let id { q[kSecAttrAccount as String] = id }
        return q
    }

    func all() -> [PasskeyRecord] {
        var q = query()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        let (status, result) = store.copyMatching(q, sync: .deviceOnly)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { ($0[kSecAttrGeneric as String] as? Data).flatMap { try? JSONDecoder().decode(PasskeyRecord.self, from: $0) } }
    }

    func save(_ record: PasskeyRecord, key: Data) throws {
        var item = query(record.credentialId)
        item[kSecAttrGeneric as String] = try JSONEncoder().encode(record)
        item[kSecAttrLabel as String] = "Axolotl passkey (\(record.rpId))"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = key
        let status = store.add(item, sync: .deviceOnly)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    func key(for credentialId: String) -> Data? {
        var q = query(credentialId)
        q[kSecReturnData as String] = true
        let (status, result) = store.copyMatching(q, sync: .deviceOnly)
        return status == errSecSuccess ? result as? Data : nil
    }

    func delete(_ credentialId: String) { _ = store.delete(query(credentialId), sync: .deviceOnly) }
}

/// Just enough CTAP2-canonical CBOR for authData's COSE key and a "none" attestation object.
enum CBOR {
    indirect enum Value { case int(Int), bytes(Data), text(String), map([(Value, Value)]) }

    static func encode(_ value: Value) -> Data {
        switch value {
        case .int(let n): return n >= 0 ? head(0, UInt64(n)) : head(1, UInt64(-1 - n))
        case .bytes(let d): return head(2, UInt64(d.count)) + d
        case .text(let s): let d = Data(s.utf8); return head(3, UInt64(d.count)) + d
        case .map(let pairs): return pairs.reduce(head(5, UInt64(pairs.count))) { $0 + encode($1.0) + encode($1.1) }
        }
    }

    private static func head(_ major: UInt8, _ n: UInt64) -> Data {
        let m = major << 5
        switch n {
        case ..<24: return Data([m | UInt8(n)])
        case ..<0x100: return Data([m | 24, UInt8(n)])
        case ..<0x10000: return Data([m | 25, UInt8(n >> 8), UInt8(n & 0xff)])
        default: return Data([m | 26] + (0..<4).reversed().map { UInt8((n >> (8 * UInt64($0))) & 0xff) })
        }
    }
}

/// A frame's origin as WebKit reports it (never as the page claims it).
struct WebOrigin: Equatable {
    let scheme: String, host: String, port: Int

    var serialized: String {
        let isDefault = port == 0 || (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)\(isDefault ? "" : ":\(port)")"
    }

    /// WebAuthn needs a secure context: https, or http on localhost.
    var isSecure: Bool { scheme == "https" || (scheme == "http" && (host == "localhost" || host.hasSuffix(".localhost"))) }
}

enum WebAuthn {
    static let es256 = -7
    /// UP | UV; AT is added when attested credential data follows. BE/BS stay 0: these passkeys never sync.
    static let flagsUPUV: UInt8 = 0x05, flagAT: UInt8 = 0x40

    // shortcut: a short built-in list of multi-label public suffixes, not the full Public Suffix List; adopt the
    // real list if a site on an unlisted shared suffix (e.g. a hosting platform) needs isolation.
    static let publicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk", "ltd.uk", "plc.uk", "com.au", "net.au", "org.au", "edu.au", "gov.au",
        "co.nz", "org.nz", "co.jp", "ne.jp", "or.jp", "ac.jp", "co.kr", "or.kr", "co.in", "net.in", "org.in", "com.br", "net.br",
        "com.cn", "net.cn", "org.cn", "com.mx", "com.tr", "com.tw", "com.hk", "com.sg", "co.za", "com.ar", "co.il", "com.es",
        "github.io", "gitlab.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "herokuapp.com", "web.app",
        "firebaseapp.com", "appspot.com", "blogspot.com", "azurewebsites.net", "cloudfront.net", "fly.dev", "onrender.com",
    ]

    static func isPublicSuffix(_ domain: String) -> Bool { !domain.contains(".") || publicSuffixes.contains(domain) }

    /// The request's rpId (default: the origin's host) if the origin may use it.
    static func relyingParty(_ requested: String?, for origin: WebOrigin) throws -> String {
        guard origin.isSecure else { throw WebAuthnError.security }
        let host = origin.host.lowercased()
        let rpId = (requested?.isEmpty == false ? requested! : host).lowercased()
        let isIP = host.contains(":") || host.split(separator: ".").allSatisfy { Int($0) != nil }
        if rpId == host { return rpId } // a host (even an IP or localhost) may always be its own rpId
        guard !isIP, host.hasSuffix("." + rpId), !isPublicSuffix(rpId) else { throw WebAuthnError.security }
        return rpId
    }

    /// clientDataJSON in the spec's serialization order (type, challenge, origin, crossOrigin).
    static func clientDataJSON(type: String, challenge: Data, origin: WebOrigin, crossOrigin: Bool = false) -> Data {
        let o = (try? JSONSerialization.data(withJSONObject: origin.serialized, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let json = "{\"type\":\"\(type)\",\"challenge\":\"\(JWTVerifier.base64URLEncode(challenge))\",\"origin\":\(o),\"crossOrigin\":\(crossOrigin)}"
        return Data(json.utf8)
    }

    static func coseKey(_ key: P256.Signing.PublicKey) -> Data {
        let xy = key.rawRepresentation // x || y, 32 bytes each
        return CBOR.encode(.map([(.int(1), .int(2)), (.int(3), .int(es256)), (.int(-1), .int(1)),
                                 (.int(-2), .bytes(xy.prefix(32))), (.int(-3), .bytes(xy.suffix(32)))]))
    }

    /// The SubjectPublicKeyInfo DER `getPublicKey()` returns.
    static func spki(_ key: P256.Signing.PublicKey) -> Data { key.derRepresentation }

    static func authenticatorData(rpId: String, credentialId: Data? = nil, publicKey: P256.Signing.PublicKey? = nil) -> Data {
        var d = Data(SHA256.hash(data: Data(rpId.utf8)))
        let attested = credentialId != nil && publicKey != nil
        d.append(flagsUPUV | (attested ? flagAT : 0))
        d.append(contentsOf: [0, 0, 0, 0]) // signCount 0: no counter, as with synced platform passkeys
        if let credentialId, let publicKey {
            d.append(Data(count: 16)) // AAGUID: none
            d.append(contentsOf: [UInt8(credentialId.count >> 8), UInt8(credentialId.count & 0xff)])
            d.append(credentialId)
            d.append(coseKey(publicKey))
        }
        return d
    }

    static func attestationObject(authData: Data) -> Data {
        CBOR.encode(.map([(.text("fmt"), .text("none")), (.text("attStmt"), .map([])), (.text("authData"), .bytes(authData))]))
    }
}

/// What the page's JS bridge sends; every field is page-controlled and checked here.
struct PasskeyRequest: Decodable {
    struct User: Decodable { let id: String; var name: String?; var displayName: String? }
    let challenge: String
    var rpId: String?
    var user: User?
    var algs: [Int]?
    var exclude: [String]?
    var allow: [String]?
    var attachment: String?
}

/// The authenticator: makes and uses credentials. The UI (consent, Touch ID) runs in the bridge before these calls.
final class PasskeyAuthenticator {
    let store: PasskeyStoring
    let profile: UUID
    var useEnclave = SecureEnclave.isAvailable

    init(store: PasskeyStoring = KeychainPasskeyStore.shared, profile: UUID) {
        self.store = store
        self.profile = profile
    }

    func passkeys(rpId: String) -> [PasskeyRecord] { store.all().filter { $0.profile == profile && $0.rpId == rpId } }

    /// Saved passkeys the request may use: allowCredentials when given, else all of the site's.
    func candidates(_ request: PasskeyRequest, rpId: String) -> [PasskeyRecord] {
        let mine = passkeys(rpId: rpId)
        guard let allow = request.allow, !allow.isEmpty else { return mine }
        return mine.filter { allow.contains($0.credentialId) }
    }

    func validateCreate(_ request: PasskeyRequest) throws {
        guard let user = request.user, let id = JWTVerifier.base64URLDecode(user.id), (1...64).contains(id.count),
              JWTVerifier.base64URLDecode(request.challenge) != nil else { throw WebAuthnError.notAllowed }
        if let algs = request.algs, !algs.isEmpty, !algs.contains(WebAuthn.es256) { throw WebAuthnError.notSupported }
        if request.attachment == "cross-platform" { throw WebAuthnError.notSupported } // a security key is asked for
    }

    /// Makes a passkey and returns the page-facing credential. Call after the user consented and verified.
    func create(_ request: PasskeyRequest, origin: WebOrigin, rpId: String) throws -> [String: Any] {
        try validateCreate(request)
        guard let user = request.user, let challenge = JWTVerifier.base64URLDecode(request.challenge) else { throw WebAuthnError.notAllowed }
        let mine = passkeys(rpId: rpId)
        if let exclude = request.exclude, mine.contains(where: { exclude.contains($0.credentialId) }) { throw WebAuthnError.invalidState }

        let (blob, publicKey) = try makeKey()
        let credentialId = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let cid = JWTVerifier.base64URLEncode(credentialId)
        let record = PasskeyRecord(credentialId: cid, rpId: rpId, userHandle: user.id, userName: user.name ?? "",
                                   displayName: user.displayName ?? user.name ?? "", profile: profile, created: Date(), enclave: useEnclave)
        try store.save(record, key: blob)
        mine.filter { $0.userHandle == user.id }.forEach { store.delete($0.credentialId) } // one passkey per account

        let authData = WebAuthn.authenticatorData(rpId: rpId, credentialId: credentialId, publicKey: publicKey)
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin)
        return credential(cid, response: [
            "clientDataJSON": b64(clientData), "attestationObject": b64(WebAuthn.attestationObject(authData: authData)),
            "authenticatorData": b64(authData), "publicKey": b64(WebAuthn.spki(publicKey)),
            "publicKeyAlgorithm": WebAuthn.es256, "transports": ["internal"],
        ])
    }

    /// Signs in with `record`. Call after the user chose it and verified.
    func assert(_ request: PasskeyRequest, origin: WebOrigin, rpId: String, with record: PasskeyRecord) throws -> [String: Any] {
        guard record.rpId == rpId, record.profile == profile, let challenge = JWTVerifier.base64URLDecode(request.challenge),
              let blob = store.key(for: record.credentialId) else { throw WebAuthnError.notAllowed }
        let authData = WebAuthn.authenticatorData(rpId: rpId)
        let clientData = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin)
        let message = authData + Data(SHA256.hash(data: clientData))
        let signature = record.enclave
            ? try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).signature(for: message).derRepresentation
            : try P256.Signing.PrivateKey(rawRepresentation: blob).signature(for: message).derRepresentation
        return credential(record.credentialId, response: [
            "clientDataJSON": b64(clientData), "authenticatorData": b64(authData),
            "signature": b64(signature), "userHandle": record.userHandle,
        ])
    }

    private func makeKey() throws -> (Data, P256.Signing.PublicKey) {
        if useEnclave, let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .privateKeyUsage, nil) {
            let key = try SecureEnclave.P256.Signing.PrivateKey(accessControl: access)
            return (key.dataRepresentation, key.publicKey)
        }
        useEnclave = false
        let key = P256.Signing.PrivateKey()
        return (key.rawRepresentation, key.publicKey)
    }

    private func b64(_ d: Data) -> String { JWTVerifier.base64URLEncode(d) }

    private func credential(_ id: String, response: [String: Any]) -> [String: Any] {
        ["id": id, "type": "public-key", "authenticatorAttachment": "platform", "response": response]
    }

    /// Touch ID or the Mac password, asked fresh on every create and get.
    static func verifyUser(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }
}

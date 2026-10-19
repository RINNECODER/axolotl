import AppKit
import CryptoKit
import SwiftUI
import XCTest
@testable import Axolotl

/// Built-in passkeys against an in-memory store with software keys (never the real Keychain or Secure Enclave).
@MainActor
final class PasskeyTests: XCTestCase {
    private final class MemoryStore: PasskeyStoring {
        var items: [String: (PasskeyRecord, Data)] = [:]
        func all() -> [PasskeyRecord] { items.values.map(\.0) }
        func save(_ record: PasskeyRecord, key: Data) throws { items[record.credentialId] = (record, key) }
        func key(for credentialId: String) -> Data? { items[credentialId]?.1 }
        func delete(_ credentialId: String) { items[credentialId] = nil }
    }

    private let origin = WebOrigin(scheme: "https", host: "login.example.com", port: 443)
    private let profile = UUID()
    private var store: MemoryStore!
    private var auth: PasskeyAuthenticator!

    override func setUp() {
        store = MemoryStore()
        auth = PasskeyAuthenticator(store: store, profile: profile)
        auth.useEnclave = false
    }

    private func b64(_ d: Data) -> String { JWTVerifier.base64URLEncode(d) }
    private func data(_ s: Any?) -> Data { JWTVerifier.base64URLDecode(s as! String)! }
    private func createRequest(user: String = "u1", exclude: [String]? = nil, algs: [Int]? = [-7, -257]) -> PasskeyRequest {
        PasskeyRequest(challenge: b64(Data("create-challenge".utf8)), rpId: "example.com",
                       user: .init(id: b64(Data(user.utf8)), name: "\(user)@example.com", displayName: "User \(user)"),
                       algs: algs, exclude: exclude)
    }

    // MARK: CBOR, COSE, authData, attestation

    func testCBORMatchesRFC8949Vectors() {
        XCTAssertEqual(CBOR.encode(.int(0)), Data([0x00]))
        XCTAssertEqual(CBOR.encode(.int(23)), Data([0x17]))
        XCTAssertEqual(CBOR.encode(.int(24)), Data([0x18, 0x18]))
        XCTAssertEqual(CBOR.encode(.int(1000)), Data([0x19, 0x03, 0xe8]))
        XCTAssertEqual(CBOR.encode(.int(1_000_000)), Data([0x1a, 0x00, 0x0f, 0x42, 0x40]))
        XCTAssertEqual(CBOR.encode(.int(-1)), Data([0x20]))
        XCTAssertEqual(CBOR.encode(.int(-7)), Data([0x26]))
        XCTAssertEqual(CBOR.encode(.int(-100)), Data([0x38, 0x63]))
        XCTAssertEqual(CBOR.encode(.text("a")), Data([0x61, 0x61]))
        XCTAssertEqual(CBOR.encode(.bytes(Data([1, 2, 3, 4]))), Data([0x44, 1, 2, 3, 4]))
        XCTAssertEqual(CBOR.encode(.map([(.int(1), .int(2)), (.int(3), .int(4))])), Data([0xa2, 0x01, 0x02, 0x03, 0x04]))
    }

    func testCOSEKeyIsCanonicalEC2P256() {
        let key = P256.Signing.PrivateKey().publicKey
        let cose = WebAuthn.coseKey(key)
        let xy = key.rawRepresentation
        // {1: 2 (EC2), 3: -7 (ES256), -1: 1 (P-256), -2: x, -3: y}
        let expected = Data([0xa5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01, 0x21, 0x58, 0x20]) + xy.prefix(32)
            + Data([0x22, 0x58, 0x20]) + xy.suffix(32)
        XCTAssertEqual(cose, expected)
        XCTAssertEqual(cose.count, 77)
    }

    func testAuthenticatorDataLayout() {
        let key = P256.Signing.PrivateKey().publicKey
        let credId = Data(repeating: 0xab, count: 32)
        let d = WebAuthn.authenticatorData(rpId: "example.com", credentialId: credId, publicKey: key)
        XCTAssertEqual(d.prefix(32), Data(SHA256.hash(data: Data("example.com".utf8))))
        XCTAssertEqual(d[32], 0x45) // UP | UV | AT, BE/BS clear
        XCTAssertEqual(d[33..<37], Data([0, 0, 0, 0]))
        XCTAssertEqual(d[37..<53], Data(count: 16))
        XCTAssertEqual(d[53..<55], Data([0x00, 0x20]))
        XCTAssertEqual(d[55..<87], credId)
        XCTAssertEqual(d[87...], WebAuthn.coseKey(key))

        let assertion = WebAuthn.authenticatorData(rpId: "example.com")
        XCTAssertEqual(assertion.count, 37)
        XCTAssertEqual(assertion[32], 0x05)
    }

    func testNoneAttestationObjectStructure() {
        let authData = Data([1, 2, 3])
        // {"fmt": "none", "attStmt": {}, "authData": h'010203'}
        var expected = Data([0xa3, 0x63] + Array("fmt".utf8) + [0x64] + Array("none".utf8))
        expected += Data([0x67] + Array("attStmt".utf8) + [0xa0])
        expected += Data([0x68] + Array("authData".utf8) + [0x43, 1, 2, 3])
        XCTAssertEqual(WebAuthn.attestationObject(authData: authData), expected)
    }

    // MARK: Client data and rpId

    func testClientDataJSONFieldsAndOrder() {
        let json = WebAuthn.clientDataJSON(type: "webauthn.get", challenge: Data([0xfb, 0xff]), origin: origin)
        XCTAssertEqual(String(data: json, encoding: .utf8),
                       #"{"type":"webauthn.get","challenge":"-_8","origin":"https://login.example.com","crossOrigin":false}"#)
        let port = WebOrigin(scheme: "https", host: "example.com", port: 8443)
        XCTAssertTrue(String(data: WebAuthn.clientDataJSON(type: "webauthn.create", challenge: Data(), origin: port), encoding: .utf8)!
            .contains(#""origin":"https://example.com:8443""#))
    }

    func testRelyingPartyValidation() throws {
        XCTAssertEqual(try WebAuthn.relyingParty("example.com", for: origin), "example.com")
        XCTAssertEqual(try WebAuthn.relyingParty(nil, for: origin), "login.example.com")
        XCTAssertEqual(try WebAuthn.relyingParty("Login.Example.com", for: origin), "login.example.com")
        for bad in ["evil.com", "ample.com", "com", "other.example.com"] {
            XCTAssertThrowsError(try WebAuthn.relyingParty(bad, for: origin), bad)
        }
        XCTAssertThrowsError(try WebAuthn.relyingParty("co.uk", for: WebOrigin(scheme: "https", host: "shop.co.uk", port: 0)))
        XCTAssertEqual(try WebAuthn.relyingParty("shop.co.uk", for: WebOrigin(scheme: "https", host: "www.shop.co.uk", port: 0)), "shop.co.uk")
        XCTAssertThrowsError(try WebAuthn.relyingParty(nil, for: WebOrigin(scheme: "http", host: "example.com", port: 80)))
        XCTAssertEqual(try WebAuthn.relyingParty(nil, for: WebOrigin(scheme: "http", host: "localhost", port: 3000)), "localhost")
        XCTAssertThrowsError(try WebAuthn.relyingParty("0.1", for: WebOrigin(scheme: "https", host: "10.0.0.1", port: 0)))
    }

    // MARK: Authenticator

    func testCreateThenAssertionVerifiesWithReturnedPublicKey() throws {
        let created = try auth.create(createRequest(), origin: origin, rpId: "example.com")
        let id = created["id"] as! String
        let response = created["response"] as! [String: Any]
        XCTAssertEqual(response["publicKeyAlgorithm"] as? Int, -7)
        let publicKey = try P256.Signing.PublicKey(derRepresentation: data(response["publicKey"]))
        let cdj = try JSONSerialization.jsonObject(with: data(response["clientDataJSON"])) as! [String: Any]
        XCTAssertEqual(cdj["type"] as? String, "webauthn.create")
        XCTAssertEqual(cdj["origin"] as? String, "https://login.example.com")
        XCTAssertEqual(data(response["authenticatorData"]).suffix(77), WebAuthn.coseKey(publicKey))
        XCTAssertEqual(store.all().first?.userName, "u1@example.com")

        let record = try XCTUnwrap(auth.candidates(PasskeyRequest(challenge: "", allow: [id]), rpId: "example.com").first)
        let challenge = Data("get-challenge".utf8)
        let got = try auth.assert(PasskeyRequest(challenge: b64(challenge)), origin: origin, rpId: "example.com", with: record)
        let r = got["response"] as! [String: Any]
        let authData = data(r["authenticatorData"]), clientData = data(r["clientDataJSON"])
        let signature = try P256.Signing.ECDSASignature(derRepresentation: data(r["signature"]))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: authData + Data(SHA256.hash(data: clientData))))
        XCTAssertEqual(data(r["userHandle"]), Data("u1".utf8))
        XCTAssertFalse(publicKey.isValidSignature(signature, for: Data("tampered".utf8)))
    }

    func testExcludeCredentialsIsInvalidState() throws {
        let id = try auth.create(createRequest(), origin: origin, rpId: "example.com")["id"] as! String
        XCTAssertThrowsError(try auth.create(createRequest(user: "u2", exclude: [id]), origin: origin, rpId: "example.com")) {
            XCTAssertEqual($0 as? WebAuthnError, .invalidState)
        }
        XCTAssertNoThrow(try auth.create(createRequest(user: "u2", exclude: ["unknown"]), origin: origin, rpId: "example.com"))
    }

    func testAllowCredentialsFilteringAndSiteScoping() throws {
        let a = try auth.create(createRequest(user: "a"), origin: origin, rpId: "example.com")["id"] as! String
        _ = try auth.create(createRequest(user: "b"), origin: origin, rpId: "example.com")
        XCTAssertEqual(auth.candidates(PasskeyRequest(challenge: ""), rpId: "example.com").count, 2)
        XCTAssertEqual(auth.candidates(PasskeyRequest(challenge: "", allow: [a]), rpId: "example.com").map(\.credentialId), [a])
        XCTAssertTrue(auth.candidates(PasskeyRequest(challenge: "", allow: ["apple-passwords-only"]), rpId: "example.com").isEmpty)
        XCTAssertTrue(auth.candidates(PasskeyRequest(challenge: ""), rpId: "evil.com").isEmpty)
        let other = PasskeyAuthenticator(store: store, profile: UUID())
        XCTAssertTrue(other.candidates(PasskeyRequest(challenge: ""), rpId: "example.com").isEmpty)
        // A record can't sign for another site.
        let record = store.all().first!
        XCTAssertThrowsError(try auth.assert(PasskeyRequest(challenge: "AA"), origin: origin, rpId: "evil.com", with: record))
    }

    func testRecreatingForSameUserReplacesAndUnsupportedAlgRejected() throws {
        _ = try auth.create(createRequest(), origin: origin, rpId: "example.com")
        _ = try auth.create(createRequest(), origin: origin, rpId: "example.com")
        XCTAssertEqual(store.all().count, 1)
        XCTAssertThrowsError(try auth.create(createRequest(algs: [-257]), origin: origin, rpId: "example.com")) {
            XCTAssertEqual($0 as? WebAuthnError, .notSupported)
        }
    }

    func testPerSitePrefs() {
        let defaults = UserDefaults(suiteName: "PasskeyTests.\(UUID())")!
        XCTAssertTrue(PasskeyPrefs.isOn(host: "www.example.com", defaults))
        PasskeyPrefs.set(false, host: "www.example.com", defaults)
        XCTAssertFalse(PasskeyPrefs.isOn(host: "login.example.com", defaults))
        XCTAssertTrue(PasskeyPrefs.isOn(host: "notexample.com", defaults))
        PasskeyPrefs.set(true, host: "example.com", defaults)
        XCTAssertTrue(PasskeyPrefs.isOn(host: "example.com", defaults))
        defaults.set(false, forKey: PasskeyPrefs.enabledKey)
        XCTAssertFalse(PasskeyPrefs.isOn(host: "example.com", defaults))
    }

    /// Renders the passkey sheets and the Passwords page's passkey list offscreen when AXOLOTL_PASSKEY_SHOT is a PNG path.
    func testRenderPasskeyUI() throws {
        guard let path = ProcessInfo.processInfo.environment["AXOLOTL_PASSKEY_SHOT"], !path.isEmpty else {
            throw XCTSkip("Set AXOLOTL_PASSKEY_SHOT to a PNG path to render.")
        }
        _ = try auth.create(createRequest(user: "octo"), origin: origin, rpId: "github.com")
        _ = try auth.create(createRequest(user: "me"), origin: origin, rpId: "example.com")
        let model = PasswordManagerModel(vault: PasswordVault(store: KeychainStore(backend: FakeKeychain(), accessGroup: "T.com.axolotl.browser"),
                                                              defaults: UserDefaults(suiteName: "PasskeyShot.\(UUID())")!, profileNames: { [] }),
                                         profileId: profile, passkeyStore: store, authenticate: { _ in false })
        let page = NSHostingView(rootView: PasswordManagerPageView(model: model).frame(width: 760, height: 300))
        page.frame = NSRect(x: 0, y: 0, width: 760, height: 300)

        func alert(_ title: String, _ info: String, _ buttons: [String], accessory: NSView? = nil) -> NSView {
            let a = NSAlert()
            a.messageText = title
            a.informativeText = info
            buttons.forEach { a.addButton(withTitle: $0) }
            a.accessoryView = accessory
            a.layout()
            return a.window.contentView!
        }
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        popup.addItems(withTitles: ["User octo (octo@example.com)", "Work (work@example.com)"])
        let sheets = [
            alert("Create a passkey for github.com?", "You'll sign in to github.com as octo@example.com with Touch ID or your Mac password. The passkey is saved in Axolotl on this Mac.", ["Continue", "Cancel"]),
            alert("Sign in to github.com with a passkey?", "", ["Sign In", "Cancel"], accessory: popup),
            alert("This passkey is in Apple Passwords.", "Axolotl can't reach it yet. Use the site's other sign-in options, or open this page in Brave.", ["Open in Brave", "Cancel"]),
        ]
        let width = 760 + sheets.reduce(0) { $0 + $1.bounds.width + 20 }
        let height = max(300, sheets.map(\.bounds.height).max()!)
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        page.frame.origin = NSPoint(x: 0, y: height - 300)
        canvas.addSubview(page)
        var x: CGFloat = 780
        for s in sheets {
            s.frame.origin = NSPoint(x: x, y: height - s.bounds.height)
            canvas.addSubview(s)
            x += s.bounds.width + 20
        }
        canvas.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let rep = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

import XCTest
import Security
@testable import Axolotl

@MainActor
final class CloudModelTests: XCTestCase {

    // MARK: Request shaping

    func testTurnsAlternateStartWithUserAndCarryContext() {
        var req = LLMRequest(prompt: "What's on this page?", context: "Page text")
        req.conversationSummary = "We talked about Swift."
        req.recentMessages = [
            ChatMessage(role: .assistant, text: "Earlier reply"),
            ChatMessage(role: .assistant, text: "Second reply"),
            ChatMessage(role: .user, text: "  "),
            ChatMessage(role: .user, text: "Follow-up"),
        ]
        let turns = req.turns
        XCTAssertEqual(turns.map(\.role), [.user, .assistant, .user])
        XCTAssertTrue(turns[1].text.contains("Understood.") && turns[1].text.contains("Second reply"))
        XCTAssertTrue(turns[2].text.hasPrefix("Follow-up"))
        XCTAssertTrue(turns[2].text.hasSuffix("What's on this page?\n\n---\nContext:\nPage text"))
    }

    func testLeadingAssistantTurnsAreDropped() {
        var req = LLMRequest(prompt: "Hi")
        req.recentMessages = [ChatMessage(role: .assistant, text: "Welcome")]
        XCTAssertEqual(req.turns.map(\.role), [.user])
    }

    func testErrorMessageParsesProviderShapes() {
        XCTAssertEqual(errorMessage(fromBody: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)), "invalid x-api-key")
        XCTAssertEqual(errorMessage(fromBody: Data(#"{"error":"invalid_grant","error_description":"expired"}"#.utf8)), "expired")
    }

    // MARK: ID token verification

    private func makeKeyPair() throws -> (SecKey, Data, Data) {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        guard let priv = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(pub, &error) as Data? else {
            throw error!.takeRetainedValue()
        }
        // PKCS#1 RSAPublicKey: SEQUENCE { INTEGER n, INTEGER e }
        var i = der.startIndex
        func readLength() -> Int {
            let first = Int(der[i]); i += 1
            guard first & 0x80 != 0 else { return first }
            var len = 0
            for _ in 0..<(first & 0x7f) { len = (len << 8) | Int(der[i]); i += 1 }
            return len
        }
        i += 1; _ = readLength()                // SEQUENCE
        i += 1; let nLen = readLength()        // INTEGER n
        let n = der[i..<(i + nLen)]; i += nLen
        i += 1; let eLen = readLength()        // INTEGER e
        let e = der[i..<(i + eLen)]
        return (priv, Data(n), Data(e))
    }

    private func sign(_ claims: [String: Any], kid: String, key: SecKey) throws -> String {
        let header = JWTVerifier.base64URLEncode(try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": kid]))
        let payload = JWTVerifier.base64URLEncode(try JSONSerialization.data(withJSONObject: claims))
        let signed = Data("\(header).\(payload)".utf8)
        let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, signed as CFData, nil)! as Data
        return "\(header).\(payload).\(JWTVerifier.base64URLEncode(sig))"
    }

    func testVerifiesSignatureAndClaims() throws {
        let (priv, n, e) = try makeKeyPair()
        let jwks: [[String: Any]] = [["kty": "RSA", "kid": "k1", "n": JWTVerifier.base64URLEncode(n), "e": JWTVerifier.base64URLEncode(e)]]
        let claims: [String: Any] = ["iss": "https://auth.openai.com", "aud": "oaiapp_123", "sub": "user-1",
                                     "email": "a@b.c", "nonce": "N", "exp": Date().addingTimeInterval(600).timeIntervalSince1970]
        let token = try sign(claims, kid: "k1", key: priv)

        let verified = try JWTVerifier.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "oaiapp_123", nonce: "N")
        XCTAssertEqual(verified["email"] as? String, "a@b.c")

        XCTAssertThrowsError(try JWTVerifier.verify(token, jwks: jwks, issuer: "https://evil", audience: "oaiapp_123", nonce: "N"))
        XCTAssertThrowsError(try JWTVerifier.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "other", nonce: "N"))
        XCTAssertThrowsError(try JWTVerifier.verify(token, jwks: jwks, issuer: "https://auth.openai.com", audience: "oaiapp_123", nonce: "X"))

        // Tampered payload fails the signature check.
        var parts = token.split(separator: ".").map(String.init)
        var forged = claims
        forged["email"] = "attacker@example.com"
        parts[1] = JWTVerifier.base64URLEncode(try JSONSerialization.data(withJSONObject: forged))
        XCTAssertThrowsError(try JWTVerifier.verify(parts.joined(separator: "."), jwks: jwks, issuer: "https://auth.openai.com",
                                                    audience: "oaiapp_123", nonce: "N")) { error in
            XCTAssertEqual(error.localizedDescription, JWTVerifier.VerifyError.badSignature.localizedDescription)
        }

        // A key the provider didn't publish is rejected.
        let other = try sign(claims, kid: "unknown", key: priv)
        XCTAssertThrowsError(try JWTVerifier.verify(other, jwks: jwks, issuer: "https://auth.openai.com", audience: "oaiapp_123", nonce: "N"))
    }

    func testExpiredTokenIsRejected() throws {
        let (priv, n, e) = try makeKeyPair()
        let jwks: [[String: Any]] = [["kty": "RSA", "kid": "k", "n": JWTVerifier.base64URLEncode(n), "e": JWTVerifier.base64URLEncode(e)]]
        let token = try sign(["iss": "i", "aud": "a", "exp": Date().addingTimeInterval(-3600).timeIntervalSince1970], kid: "k", key: priv)
        XCTAssertThrowsError(try JWTVerifier.verify(token, jwks: jwks, issuer: "i", audience: "a", nonce: nil))
        let noExpiry = try sign(["iss": "i", "aud": "a"], kid: "k", key: priv)
        XCTAssertThrowsError(try JWTVerifier.verify(noExpiry, jwks: jwks, issuer: "i", audience: "a", nonce: nil), "tokens without exp are rejected")
    }

    // MARK: Loopback redirect

    func testLoopbackServerReturnsCallbackParameters() async throws {
        let server = try LoopbackServer(port: 0)
        let port = try await server.start()
        XCTAssertGreaterThan(port, 0)

        async let params = server.waitForCallback(timeout: 10)
        // A stray request (favicon) must not complete the flow.
        _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/favicon.ico")!)
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth/callback?code=abc&state=xyz&client_id=oaiapp_1")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("signed in"))

        let result = try await params
        XCTAssertEqual(result["code"], "abc")
        XCTAssertEqual(result["state"], "xyz")
        XCTAssertEqual(result["client_id"], "oaiapp_1")
        server.stop()
    }
}

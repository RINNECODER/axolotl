import Foundation
import Security

/// Verifies RS256-signed ID tokens against an OpenID provider's JWKS.
enum JWTVerifier {
    enum VerifyError: LocalizedError {
        case malformed
        case unsupportedAlgorithm(String)
        case unknownKey
        case badSignature
        case claim(String)

        var errorDescription: String? {
            switch self {
            case .malformed: return "The sign-in token was malformed."
            case .unsupportedAlgorithm(let alg): return "Unsupported token algorithm \(alg)."
            case .unknownKey: return "The sign-in token was signed with an unknown key."
            case .badSignature: return "The sign-in token's signature didn't verify."
            case .claim(let msg): return "The sign-in token was rejected: \(msg)."
            }
        }
    }

    struct Token {
        let header: [String: Any]
        let claims: [String: Any]
        let signedPart: Data
        let signature: Data
    }

    static func decode(_ jwt: String) throws -> Token {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = base64URLDecode(parts[0]), let claimsData = base64URLDecode(parts[1]),
              let signature = base64URLDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any],
              let claims = try? JSONSerialization.jsonObject(with: claimsData) as? [String: Any] else {
            throw VerifyError.malformed
        }
        return Token(header: header, claims: claims, signedPart: Data("\(parts[0]).\(parts[1])".utf8), signature: signature)
    }

    /// Checks signature, issuer, audience, expiry and nonce. Returns the claims.
    static func verify(_ jwt: String, jwks: [[String: Any]], issuer: String, audience: String, nonce: String?,
                       now: Date = Date()) throws -> [String: Any] {
        let token = try decode(jwt)
        let alg = token.header["alg"] as? String ?? ""
        guard alg == "RS256" else { throw VerifyError.unsupportedAlgorithm(alg) }
        let kid = token.header["kid"] as? String
        guard let jwk = jwks.first(where: { ($0["kid"] as? String) == kid && ($0["kty"] as? String) == "RSA" })
                ?? (kid == nil ? jwks.first(where: { ($0["kty"] as? String) == "RSA" }) : nil),
              let n = (jwk["n"] as? String).flatMap(base64URLDecode),
              let e = (jwk["e"] as? String).flatMap(base64URLDecode),
              let key = rsaPublicKey(modulus: n, exponent: e) else {
            throw VerifyError.unknownKey
        }
        guard SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256,
                                    token.signedPart as CFData, token.signature as CFData, nil) else {
            throw VerifyError.badSignature
        }
        let claims = token.claims
        guard claims["iss"] as? String == issuer else { throw VerifyError.claim("wrong issuer") }
        let aud = claims["aud"]
        let audiences = (aud as? [String]) ?? [(aud as? String) ?? ""]
        guard audiences.contains(audience) else { throw VerifyError.claim("wrong audience") }
        guard let exp = claims["exp"] as? Double else { throw VerifyError.claim("no expiry") }
        if Date(timeIntervalSince1970: exp) < now.addingTimeInterval(-60) { throw VerifyError.claim("expired") }
        if let nonce, claims["nonce"] as? String != nonce { throw VerifyError.claim("nonce mismatch") }
        return claims
    }

    // MARK: - Helpers

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        return Data(base64Encoded: b64)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Builds a SecKey from a JWK's modulus/exponent (PKCS#1 RSAPublicKey DER).
    static func rsaPublicKey(modulus: Data, exponent: Data) -> SecKey? {
        func derLength(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []
            var n = count
            while n > 0 { bytes.insert(UInt8(n & 0xff), at: 0); n >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func derInteger(_ value: Data) -> Data {
            var v = Data(value.drop { $0 == 0 })
            if v.isEmpty { v = Data([0]) }
            if v[v.startIndex] & 0x80 != 0 { v.insert(0, at: 0) }
            return Data([0x02]) + derLength(v.count) + v
        }
        let sequence = derInteger(modulus) + derInteger(exponent)
        let der = Data([0x30]) + derLength(sequence.count) + sequence
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        return SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil)
    }
}

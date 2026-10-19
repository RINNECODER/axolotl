import AppKit
import Combine
import CryptoKit
import Foundation

/// "Sign in with ChatGPT" using OpenAI's open-source/local-app flow: OAuth 2.0
/// authorization code + PKCE in the system browser, a loopback redirect, and
/// plan usage via the `chatgpt.tokens.use.direct` scope.
/// https://developers.openai.com/siwc/token-sharing-open-source/sign-in
final class ChatGPTAuth: ObservableObject {
    static let shared = ChatGPTAuth()

    static let authorizeURL = URL(string: "https://auth.openai.com/api/accounts/authorize")!
    static let tokenURL = URL(string: "https://auth.openai.com/api/accounts/oauth/token")!
    static let discoveryURL = URL(string: "https://auth.openai.com/.well-known/openid-configuration")!
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke \(planScope)"
    static let registrationClientID = "dynamic_agent_client"
    static let appName = "Luna"
    static let preferredPort: UInt16 = 1455
    private static let hostIDKey = "luna_chatgpt_host_id"
    private static let clientIDKey = "luna_chatgpt_client_id"

    /// Saved per account (Keychain). Replaced together on refresh.
    struct Credentials: Codable {
        var email: String
        var name: String?
        var issuer: String
        var subject: String
        var clientID: String
        var hostID: String
        var idToken: String
        var accessToken: String
        var refreshToken: String
        var tokenType: String
        var expiresAt: Date
        var scopes: [String]
        var savedAt: Date
    }

    enum AuthError: LocalizedError {
        case notSignedIn
        case denied
        case stateMismatch
        case registrationIncomplete
        case clientMismatch
        case planNotGranted
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notSignedIn: return "Sign in with ChatGPT in Settings → AI & Models."
            case .denied: return "Sign-in was cancelled in the browser."
            case .stateMismatch: return "Sign-in response didn't match this request. Try again."
            case .registrationIncomplete: return "OpenAI didn't finish registering Luna. Try signing in again."
            case .clientMismatch: return "The sign-in response came from a different app registration and was rejected."
            case .planNotGranted: return "Plan usage wasn't granted. Allow Luna to use your ChatGPT plan when signing in."
            case .server(let msg): return msg
            }
        }
    }

    @Published private(set) var credentials: Credentials?
    @Published private(set) var isSigningIn = false

    private var refreshTask: Task<Credentials, Error>?
    private var activeServer: LoopbackServer?
    private var discovery: [String: Any]?

    nonisolated deinit {}

    private init() {
        reloadFromKeychain()
    }

    /// Re-reads saved credentials (e.g. after the Keychain migration moved them).
    func reloadFromKeychain() {
        if let data = KeychainManager.shared.data(for: .chatGPTCredentials) {
            credentials = try? JSONDecoder().decode(Credentials.self, from: data)
        }
    }

    var isSignedIn: Bool { credentials != nil }

    /// Stable per-install host identifier, sent as `ext_agent_host_id`.
    private var hostID: String {
        if let existing = UserDefaults.standard.string(forKey: Self.hostIDKey) { return existing }
        let id = "urn:uuid:\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(id, forKey: Self.hostIDKey)
        return id
    }

    /// Issued client ID from the first registration; kept across sign-outs.
    private var issuedClientID: String? {
        get { UserDefaults.standard.string(forKey: Self.clientIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.clientIDKey) }
    }

    // MARK: - Sign in

    func signIn() async throws {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer {
            isSigningIn = false
            activeServer?.stop()
            activeServer = nil
        }

        let registering = issuedClientID == nil
        // Registration must use the same port for the whole flow; later sign-ins may use any free port.
        var server = try LoopbackServer(port: Self.preferredPort)
        var port: UInt16
        do {
            port = try await server.start()
        } catch where !registering {
            server.stop()
            server = try LoopbackServer(port: 0)
            port = try await server.start()
        }
        activeServer = server
        let redirectURI = "http://127.0.0.1:\(port)/auth/callback"

        let verifier = JWTVerifier.base64URLEncode(Data((0..<32).map { _ in UInt8.random(in: 0...255) }))
        let challenge = JWTVerifier.base64URLEncode(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = JWTVerifier.base64URLEncode(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let nonce = JWTVerifier.base64URLEncode(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))

        var query: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: issuedClientID ?? Self.registrationClientID),
            URLQueryItem(name: "ext_agent_host_id", value: hostID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "resource", value: Self.resource),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "nonce", value: nonce),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]
        if registering {
            query.append(URLQueryItem(name: "agent_name_hint", value: Self.appName))
        } else if let previous = credentials {
            query.append(URLQueryItem(name: "login_hint", value: previous.email))
        }
        var components = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = query
        NSWorkspace.shared.open(components.url!)

        let params = try await server.waitForCallback()
        if let error = params["error"] {
            throw error == "access_denied" ? AuthError.denied : AuthError.server(params["error_description"] ?? error)
        }
        guard params["state"] == state, let code = params["code"] else { throw AuthError.stateMismatch }

        let clientID: String
        if registering {
            guard let issued = params["client_id"], !issued.isEmpty, issued != Self.registrationClientID else {
                throw AuthError.registrationIncomplete
            }
            issuedClientID = issued
            clientID = issued
        } else {
            let saved = issuedClientID!
            if let returned = params["client_id"], !returned.isEmpty, returned != saved { throw AuthError.clientMismatch }
            clientID = saved
        }

        let token = try await postForm(Self.tokenURL, [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "resource": Self.resource,
        ])
        guard let idToken = token["id_token"] as? String else { throw AuthError.server("Sign-in returned no ID token.") }

        let config = try await openIDConfiguration()
        let claims = try JWTVerifier.verify(idToken, jwks: try await jwks(config), issuer: config["issuer"] as? String ?? "",
                                            audience: clientID, nonce: nonce)
        let granted = (token["scope"] as? String ?? params["scope"] ?? "").split(separator: " ").map(String.init)
        guard granted.contains(Self.planScope) else { throw AuthError.planNotGranted }
        guard let access = token["access_token"] as? String, let refresh = token["refresh_token"] as? String else {
            throw AuthError.server("Sign-in returned no access token.")
        }

        let creds = Credentials(
            email: claims["email"] as? String ?? "",
            name: claims["name"] as? String,
            issuer: claims["iss"] as? String ?? "",
            subject: claims["sub"] as? String ?? "",
            clientID: clientID,
            hostID: hostID,
            idToken: idToken,
            accessToken: access,
            refreshToken: refresh,
            tokenType: token["token_type"] as? String ?? "Bearer",
            expiresAt: Date().addingTimeInterval(token["expires_in"] as? Double ?? 3600),
            scopes: granted,
            savedAt: Date()
        )
        try save(creds)
    }

    func cancelSignIn() {
        activeServer?.stop()
    }

    // MARK: - Tokens

    /// A non-expired access token, refreshing (serialized) when needed.
    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let creds = credentials else { throw AuthError.notSignedIn }
        if !forceRefresh, creds.expiresAt > Date().addingTimeInterval(60) { return creds.accessToken }
        if let refreshTask { return try await refreshTask.value.accessToken }
        let task = Task { try await self.refresh(creds) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func refresh(_ creds: Credentials) async throws -> Credentials {
        let token: [String: Any]
        do {
            token = try await postForm(Self.tokenURL, [
                "grant_type": "refresh_token",
                "client_id": creds.clientID,
                "refresh_token": creds.refreshToken,
                "resource": Self.resource,
            ])
        } catch AuthError.server(let msg) where msg.contains("invalid_grant") {
            clearLocal()
            throw AuthError.notSignedIn
        }
        var next = creds
        next.accessToken = token["access_token"] as? String ?? creds.accessToken
        next.refreshToken = token["refresh_token"] as? String ?? creds.refreshToken
        next.idToken = token["id_token"] as? String ?? creds.idToken
        next.expiresAt = Date().addingTimeInterval(token["expires_in"] as? Double ?? 3600)
        if let scope = token["scope"] as? String { next.scopes = scope.split(separator: " ").map(String.init) }
        next.savedAt = Date()
        try save(next)
        return next
    }

    // MARK: - Sign out

    /// Revokes the refresh token, then clears local tokens. Returns false if
    /// remote revocation couldn't be confirmed (tokens are cleared anyway).
    @discardableResult
    func signOut() async -> Bool {
        guard let creds = credentials else { return true }
        var revoked = false
        if let config = try? await openIDConfiguration(),
           let endpoint = (config["revocation_endpoint"] as? String).flatMap(URL.init(string:)) {
            for attempt in 0..<3 where !revoked {
                if attempt > 0 { try? await Task.sleep(for: .seconds(Double(attempt))) }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody(["token": creds.refreshToken, "token_type_hint": "refresh_token",
                                                  "client_id": creds.clientID])
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let status = (response as? HTTPURLResponse)?.statusCode {
                    if status == 200 { revoked = true } else if status < 500 { break }
                }
            }
        }
        clearLocal()
        return revoked
    }

    // MARK: - Helpers

    private func save(_ creds: Credentials) throws {
        try KeychainManager.shared.store(try JSONEncoder().encode(creds), for: .chatGPTCredentials)
        credentials = creds
    }

    private func clearLocal() {
        try? KeychainManager.shared.delete(.chatGPTCredentials)
        credentials = nil
    }

    private func openIDConfiguration() async throws -> [String: Any] {
        if let discovery { return discovery }
        let (data, _) = try await URLSession.shared.data(from: Self.discoveryURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.server("Couldn't read OpenAI's sign-in configuration.")
        }
        discovery = json
        return json
    }

    private func jwks(_ config: [String: Any]) async throws -> [[String: Any]] {
        guard let uri = (config["jwks_uri"] as? String).flatMap(URL.init(string:)) else {
            throw AuthError.server("OpenAI's sign-in configuration has no signing keys.")
        }
        let (data, _) = try await URLSession.shared.data(from: uri)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["keys"] as? [[String: Any]] ?? []
    }

    private func postForm(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard status == 200 else {
            let code = json["error"] as? String ?? ""
            let desc = json["error_description"] as? String ?? errorMessage(fromBody: data)
            throw AuthError.server(code.isEmpty ? desc : "\(code): \(desc)")
        }
        return json
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        .joined(separator: "&")
        .data(using: .utf8)!
    }
}

import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that receives an OAuth redirect.
/// Requires the sandbox's incoming-network (server) entitlement.
final class LoopbackServer {
    enum ServerError: LocalizedError {
        case couldNotStart(String)
        case timedOut
        case cancelled

        var errorDescription: String? {
            switch self {
            case .couldNotStart(let msg): return "Couldn't start the sign-in listener: \(msg)"
            case .timedOut: return "Sign-in timed out. Try again."
            case .cancelled: return "Sign-in was cancelled."
            }
        }
    }

    private let listener: NWListener
    private let path: String
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var connections: [NWConnection] = []

    nonisolated deinit {}

    /// - Parameter port: 0 picks any free port.
    init(port: UInt16, path: String = "/auth/callback") throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: params)
        self.path = path
    }

    /// Starts listening and returns the bound port.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { cont in
            startContinuation = cont
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerStateChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
        }
    }

    /// Waits for the redirect and returns its query parameters.
    func waitForCallback(timeout: TimeInterval = 300) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(ServerError.timedOut))
            }
        }
    }

    func stop() {
        finish(.failure(ServerError.cancelled))
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            startContinuation?.resume(returning: listener.port?.rawValue ?? 0)
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: ServerError.couldNotStart(error.localizedDescription))
            startContinuation = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            MainActor.assumeIsolated { self?.handle(data ?? Data(), on: connection) }
        }
    }

    private func handle(_ data: Data, on connection: NWConnection) {
        let request = String(data: data, encoding: .utf8) ?? ""
        let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard let components = URLComponents(string: "http://127.0.0.1\(target)"), components.path == path else {
            respond(connection, status: "404 Not Found", body: "Not found")
            return
        }
        var params: [String: String] = [:]
        for item in components.queryItems ?? [] { params[item.name] = item.value ?? "" }
        let ok = params["error"] == nil
        respond(connection, status: "200 OK", body: ok
            ? "<h2>You're signed in to Axolotl.</h2><p>You can close this tab and return to Axolotl.</p>"
            : "<h2>Sign-in didn't complete.</h2><p>You can close this tab and try again in Axolotl.</p>")
        finish(.success(params))
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let html = "<!doctype html><html><head><meta charset=utf-8><title>Axolotl</title><style>body{font:15px -apple-system,sans-serif;margin:15vh auto;max-width:28em;text-align:center;color:#333}@media(prefers-color-scheme:dark){body{background:#1e1e1e;color:#ddd}}</style></head><body>\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

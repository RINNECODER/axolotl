import Foundation
import Network

/// Minimal HTTP/1.1 listener on 127.0.0.1 for `MCPEndpoint`. One request per connection
/// (`Connection: close`); bodies by Content-Length or chunked; bounded sizes and read time.
/// Requires the sandbox's incoming-network (server) entitlement.
final class MCPServer {
    enum ServerError: LocalizedError {
        case couldNotStart(String)
        var errorDescription: String? {
            switch self {
            case .couldNotStart(let m): return m
            }
        }
    }

    static let maxHeaderBytes = 32 * 1024
    static let maxBodyBytes = 4 * 1024 * 1024
    static let readTimeout: TimeInterval = 30

    let endpoint: MCPEndpoint
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<UInt16, Error>?

    nonisolated deinit {}

    init(endpoint: MCPEndpoint) {
        self.endpoint = endpoint
    }

    /// Starts listening on 127.0.0.1 and returns the bound port (`0` picks a free one).
    func start(port: UInt16) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch {
            throw ServerError.couldNotStart(error.localizedDescription)
        }
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
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

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        if let startContinuation {
            self.startContinuation = nil
            startContinuation.resume(throwing: ServerError.couldNotStart("Stopped."))
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            startContinuation?.resume(returning: listener?.port?.rawValue ?? 0)
            startContinuation = nil
        case .failed(let error):
            startContinuation?.resume(throwing: ServerError.couldNotStart(error.localizedDescription))
            startContinuation = nil
            listener?.cancel()
        default:
            break
        }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .cancelled, .failed: self?.connections.removeValue(forKey: key)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        let loopback = Self.isLoopback(connection.endpoint)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.readTimeout) { [weak self, weak connection] in
            // Still reading a request after the timeout: drop it. (Handled requests disarm this.)
            guard let self, let connection, self.connections[key] != nil, !self.handling.contains(key) else { return }
            connection.cancel()
        }
        receive(on: connection, buffer: Data(), loopback: loopback)
    }

    private var handling: Set<ObjectIdentifier> = []

    private func receive(on connection: NWConnection, buffer: Data, loopback: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch Self.parse(buffer, loopback: loopback) {
                case .complete(let request):
                    self.handling.insert(ObjectIdentifier(connection))
                    Task { @MainActor in
                        let response = await self.endpoint.handle(request)
                        self.send(response, on: connection)
                    }
                case .invalid(let status, let message):
                    self.send(.text(status, message), on: connection)
                case .incomplete:
                    if error != nil || isComplete { connection.cancel(); return }
                    self.receive(on: connection, buffer: buffer, loopback: loopback)
                }
            }
        }
    }

    private func send(_ response: MCPHTTPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        let key = ObjectIdentifier(connection)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handling.remove(key)
                connection.cancel()
            }
        })
    }

    // MARK: Parsing

    enum ParseResult {
        case incomplete
        case complete(MCPHTTPRequest)
        case invalid(Int, String)
    }

    /// Parses one request from `buffer`, or says more bytes are needed.
    static func parse(_ buffer: Data, loopback: Bool) -> ParseResult {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > maxHeaderBytes ? .invalid(431, "Headers too large") : .incomplete
        }
        guard headerEnd.lowerBound <= maxHeaderBytes,
              let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid(400, "Bad request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(400, "Bad request") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400, "Bad header") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            // A repeated Host/Authorization is ambiguous; refuse rather than pick one.
            if headers[name] != nil, ["host", "authorization", "origin", "content-length", "mcp-session-id"].contains(name) {
                return .invalid(400, "Duplicate \(name) header")
            }
            headers[name] = value
        }
        let rest = buffer[headerEnd.upperBound...]
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(Data(rest)) {
            // A chunked body that never ends must not grow the buffer (and its rescans) forever.
            case .none: return buffer.count > maxHeaderBytes + maxBodyBytes + 1024 ? .invalid(413, "Body too large") : .incomplete
            case .some(.failure): return .invalid(400, "Bad chunked body")
            case .some(.success(let decoded)): body = decoded
            }
        } else {
            let length = headers["content-length"].flatMap { Int($0) } ?? 0
            guard length >= 0, length <= maxBodyBytes else { return .invalid(413, "Body too large") }
            guard rest.count >= length else { return .incomplete }
            body = Data(rest.prefix(length))
        }
        return .complete(MCPHTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]),
                                        headers: headers, body: body, remoteIsLoopback: loopback))
    }

    private struct ChunkError: Error {}

    /// Nil while incomplete.
    private static func decodeChunked(_ data: Data) -> Result<Data, ChunkError>? {
        var out = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return nil }
            let sizeText = String(data: data[index..<lineEnd.lowerBound], encoding: .ascii)?
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else { return .failure(ChunkError()) }
            if size == 0 { return .success(out) }
            guard out.count + size <= maxBodyBytes else { return .failure(ChunkError()) }
            let start = lineEnd.upperBound
            guard data.distance(from: start, to: data.endIndex) >= size + 2 else { return nil }
            let end = data.index(start, offsetBy: size)
            out.append(data[start..<end])
            index = data.index(end, offsetBy: 2)
        }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address): return address.isLoopback || address == IPv6Address("::ffff:127.0.0.1")
        case .name(let name, _): return name == "127.0.0.1" || name == "localhost" || name == "::1"
        @unknown default: return false
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 431: return "Request Header Fields Too Large"
        default: return "Error"
        }
    }
}

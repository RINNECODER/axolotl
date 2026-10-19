import Foundation

/// Claude via the Anthropic Messages API (raw HTTP; no Swift SDK exists).
/// Authenticates with a Claude Console API key stored in the Keychain.
struct AnthropicClient {
    static let baseURL = URL(string: "https://api.anthropic.com/v1")!
    static let apiVersion = "2023-06-01"
    /// Models that accept the server-side refusal fallback (`fallbacks: "default"`).
    private static let fallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    var apiKey: () -> String? = { KeychainManager.shared.string(for: .anthropicKey) }

    struct Model: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    private func authorizedRequest(_ url: URL) throws -> URLRequest {
        guard let key = apiKey(), !key.isEmpty else {
            throw LLMError.notConfigured("Add an Anthropic API key in Settings → AI & Models.")
        }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        return request
    }

    func listModels() async throws -> [Model] {
        var components = URLComponents(url: Self.baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "100")]
        let request = try authorizedRequest(components.url!)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status: status, message: errorMessage(fromBody: data)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = json?["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            return Model(id: id, displayName: item["display_name"] as? String ?? id)
        }
    }

    /// Streams the assistant's text. Retries 429/5xx/529 up to twice before
    /// any output arrives.
    func stream(model: String, request req: LLMRequest, onToken: @escaping (String) -> Void) async throws {
        var request = try authorizedRequest(Self.baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 64_000,
            "stream": true,
            "system": req.systemPrompt,
            "messages": req.turns.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] },
        ]
        if Self.fallbackModels.contains(model) {
            // On a safety decline, the API re-runs the request on a suitable model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var attempt = 0
        while true {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                try await Self.consume(lines: bytes.lines, onToken: onToken)
                return
            }
            let message = errorMessage(fromBody: await bytes.collect())
            let retryable = status == 429 || status == 529 || status >= 500
            guard retryable, attempt < 2 else {
                switch status {
                case 401: throw LLMError.http(status: status, message: "Anthropic rejected the API key. Check it in Settings → AI & Models.")
                case 404: throw LLMError.http(status: status, message: "Model “\(model)” isn't available to this API key. Pick another model in Settings.")
                default: throw LLMError.http(status: status, message: message)
                }
            }
            attempt += 1
            let retryAfter = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? Double(attempt * 2)
            try await Task.sleep(for: .seconds(min(retryAfter, 10)))
        }
    }

    static func consume<Lines: AsyncSequence>(lines: Lines, onToken: @escaping (String) -> Void) async throws where Lines.Element == String {
        var stopReason: String?
        var stopped = false
        try await SSE.read(lines: lines) { event in
            guard let json = SSE.json(event.data), let type = json["type"] as? String else { return true }
            switch type {
            case "content_block_delta":
                // Thinking deltas are ignored; only visible text is shown.
                if let delta = json["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    onToken(text)
                }
            case "message_delta":
                if let delta = json["delta"] as? [String: Any] { stopReason = delta["stop_reason"] as? String ?? stopReason }
            case "message_stop":
                stopped = true
                return false
            case "error":
                let err = json["error"] as? [String: Any]
                throw LLMError.stream(err?["message"] as? String ?? "Claude returned an error.")
            default:
                break
            }
            return true
        }
        if stopReason == "refusal" {
            throw LLMError.refused("Claude declined to answer this request.")
        }
        // A dropped connection ends the byte stream without message_stop; don't report it as done.
        if !stopped && !Task.isCancelled {
            throw LLMError.incomplete("The response ended unexpectedly.")
        }
        if stopReason == "max_tokens" {
            throw LLMError.incomplete("The reply was cut off at the output length limit.")
        }
    }
}

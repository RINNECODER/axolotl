import Foundation

/// OpenRouter: one API key for every model, through its OpenAI-compatible chat completions API.
/// The model list is public (no key) and cached for the session.
struct OpenRouterClient {
    static let baseURL = URL(string: "https://openrouter.ai/api/v1")!
    /// TypeSafe's Jev router on OpenRouter; computer use falls back to it (see `ComputerUseAgent`).
    static let jevModel = "typesafe/jev-router"

    var apiKey: () -> String? = { KeychainManager.shared.string(for: .openRouterKey) }

    @MainActor private static var cachedModels: [ModelCatalog.Model]?

    @MainActor
    func listModels() async throws -> [ModelCatalog.Model] {
        if let cached = Self.cachedModels { return cached }
        let (data, response) = try await URLSession.shared.data(from: Self.baseURL.appendingPathComponent("models"))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status: status, message: errorMessage(fromBody: data)) }
        let models = Self.parseModels(data)
        if !models.isEmpty { Self.cachedModels = models }
        return models
    }

    /// `GET /models` → text-output models, sorted by name.
    static func parseModels(_ data: Data) -> [ModelCatalog.Model] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let items = json?["data"] as? [[String: Any]] ?? []
        return items.compactMap { m -> ModelCatalog.Model? in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let outputs = (m["architecture"] as? [String: Any])?["output_modalities"] as? [String]
            if let outputs, !outputs.contains("text") { return nil }
            return (id, m["name"] as? String ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func chatRequest(model: String, request req: LLMRequest, apiKey: String) throws -> URLRequest {
        let messages = [["role": "system", "content": req.systemPrompt]]
            + req.turns.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("Axolotl", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "stream": true])
        return request
    }

    @MainActor
    func stream(model: String, request req: LLMRequest, onToken: @escaping (String) -> Void) async throws {
        guard let key = apiKey(), !key.isEmpty else {
            throw LLMError.notConfigured("Add an OpenRouter API key in Settings → AI & Models.")
        }
        guard !model.isEmpty else { throw LLMError.notConfigured("Choose a model in Settings → AI & Models.") }
        let (bytes, response) = try await URLSession.shared.bytes(for: Self.chatRequest(model: model, request: req, apiKey: key))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let message = errorMessage(fromBody: await bytes.collect())
            throw LLMError.http(status: status, message: status == 401 ? "OpenRouter rejected the API key. Check it in Settings → AI & Models." : message)
        }
        try await Self.consume(lines: bytes.lines, onToken: onToken)
    }

    /// Chat-completions SSE: `choices[0].delta.content` chunks until `[DONE]`.
    static func consume<Lines: AsyncSequence>(lines: Lines, onToken: (String) -> Void) async throws where Lines.Element == String {
        var done = false
        try await SSE.read(lines: lines) { event in
            if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" { done = true; return false }
            guard let json = SSE.json(event.data) else { return true }
            if let error = json["error"] as? [String: Any] {
                throw LLMError.stream(error["message"] as? String ?? "OpenRouter returned an error.")
            }
            let choice = (json["choices"] as? [[String: Any]])?.first
            if let text = (choice?["delta"] as? [String: Any])?["content"] as? String, !text.isEmpty { onToken(text) }
            if let reason = choice?["finish_reason"] as? String, reason == "length" {
                throw LLMError.incomplete("The response stopped early (length).")
            }
            return true
        }
        if !done && !Task.isCancelled { throw LLMError.incomplete("The response ended unexpectedly.") }
    }
}

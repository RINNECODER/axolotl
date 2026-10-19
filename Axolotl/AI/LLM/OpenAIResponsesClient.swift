import Foundation

/// OpenAI's Responses API, used both with a ChatGPT sign-in (plan usage) and
/// with an OpenAI API key. Requests are streamed and not stored.
struct OpenAIResponsesClient {
    static let baseURL = URL(string: "https://api.openai.com/v1")!

    enum Credential {
        case chatGPT
        case apiKey
    }

    let credential: Credential

    struct Model: Identifiable, Hashable {
        let id: String
        let displayName: String
    }

    @MainActor
    private func bearerToken(forceRefresh: Bool = false) async throws -> String {
        switch credential {
        case .chatGPT:
            return try await ChatGPTAuth.shared.validAccessToken(forceRefresh: forceRefresh)
        case .apiKey:
            guard let key = KeychainManager.shared.string(for: .openAIKey), !key.isEmpty else {
                throw LLMError.notConfigured("Add an OpenAI API key in Settings → AI & Models.")
            }
            return key
        }
    }

    @MainActor
    func listModels() async throws -> [Model] {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("models"))
        request.setValue("Bearer \(try await bearerToken())", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status: status, message: errorMessage(fromBody: data)) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        // ChatGPT plan connections return `models` (slug/display_name/visibility);
        // API keys return the standard `data` list.
        if let models = json?["models"] as? [[String: Any]] {
            return models.compactMap { m in
                guard (m["visibility"] as? String ?? "list") == "list", let slug = m["slug"] as? String else { return nil }
                return Model(id: slug, displayName: m["display_name"] as? String ?? slug)
            }
        }
        let items = json?["data"] as? [[String: Any]] ?? []
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "o5", "chatgpt"]
        return items.compactMap { $0["id"] as? String }
            .filter { id in chatPrefixes.contains { id.hasPrefix($0) } && !id.contains("audio") && !id.contains("realtime")
                && !id.contains("transcribe") && !id.contains("tts") && !id.contains("image") && !id.contains("embedding") }
            .sorted()
            .map { Model(id: $0, displayName: $0) }
    }

    @MainActor
    func stream(model: String, request req: LLMRequest, onToken: @escaping (String) -> Void) async throws {
        guard !model.isEmpty else {
            throw LLMError.notConfigured("Choose a model in Settings → AI & Models.")
        }
        let body: [String: Any] = [
            "model": model,
            "instructions": req.systemPrompt,
            "input": req.turns.map { ["role": $0.role == .user ? "user" : "assistant", "content": $0.text] },
            "store": false,
            "stream": true,
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        for attempt in 0..<2 {
            var request = URLRequest(url: Self.baseURL.appendingPathComponent("responses"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(try await bearerToken(forceRefresh: attempt > 0))", forHTTPHeaderField: "Authorization")
            request.httpBody = bodyData

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                try await consume(bytes, onToken: onToken)
                return
            }
            let message = errorMessage(fromBody: await bytes.collect())
            // A ChatGPT access token can expire between refresh checks; refresh once.
            if status == 401, credential == .chatGPT, attempt == 0 { continue }
            switch (status, credential) {
            case (401, .chatGPT):
                throw LLMError.http(status: status, message: "Your ChatGPT sign-in expired. Sign in again in Settings → AI & Models.")
            case (403, .chatGPT):
                // Don't retry or loop through sign-in: the account isn't eligible.
                throw LLMError.http(status: status, message: "This ChatGPT account can't be used here. Plan usage needs ChatGPT Plus or Pro.")
            case (401, .apiKey):
                throw LLMError.http(status: status, message: "OpenAI rejected the API key. Check it in Settings → AI & Models.")
            default:
                throw LLMError.http(status: status, message: message)
            }
        }
    }

    private func consume(_ bytes: URLSession.AsyncBytes, onToken: @escaping (String) -> Void) async throws {
        var completed = false
        try await SSE.read(bytes) { event in
            guard let json = SSE.json(event.data) else { return true }
            let type = json["type"] as? String ?? event.name ?? ""
            switch type {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String {
                    onToken(delta)
                }
            case "response.completed":
                completed = true
                return false
            case "response.failed":
                let error = (json["response"] as? [String: Any])?["error"] as? [String: Any]
                let code = error?["code"] as? String ?? ""
                switch code {
                case "subscription_sharing_usage_limit_exceeded":
                    throw LLMError.stream("You've reached Axolotl's usage limit on your ChatGPT plan. Raise it in ChatGPT settings or try again later.")
                case "subscription_sharing_usage_unavailable":
                    throw LLMError.stream("Your ChatGPT plan has no usage available right now. Try again later.")
                default:
                    throw LLMError.stream(error?["message"] as? String ?? "The response failed (\(code)).")
                }
            case "response.incomplete":
                let reason = ((json["response"] as? [String: Any])?["incomplete_details"] as? [String: Any])?["reason"] as? String
                throw LLMError.incomplete("The response stopped early\(reason.map { " (\($0))" } ?? "").")
            case "error":
                throw LLMError.stream(json["message"] as? String ?? "OpenAI returned an error.")
            default:
                break
            }
            return true
        }
        if !completed && !Task.isCancelled {
            throw LLMError.incomplete("The response ended unexpectedly.")
        }
    }
}

// Luna — Gemini Client (SSE streaming via streamGenerateContent)
import Foundation

// MARK: - Errors

enum GeminiError: LocalizedError {
    case missingAPIKey
    case unauthorized
    case endpointNotFound
    case networkFailure(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Add a Gemini API key, or choose another provider, in Settings → AI & Models."
        case .unauthorized:
            return "Gemini rejected the API key. Check it in Settings → AI & Models."
        case .endpointNotFound:
            return "Gemini API returned 404. Check your API version."
        case .networkFailure(let msg):
            return "Network error: \(msg)"
        }
    }
}

private enum GeminiAPIError: Error {
    case invalidURL
    case noData
    case badStatus(Int)
}

// MARK: - GeminiClient

final class GeminiClient {

    private let apiKeyProvider: () -> String?

    init(apiKeyProvider: @escaping () -> String?) {
        self.apiKeyProvider = apiKeyProvider
    }

    // MARK: - Streaming generate

    @discardableResult
    func generateStreaming(
        prompt: String,
        context: String?,
        recentMessages: [ChatMessage] = [],
        conversationSummary: String? = nil,
        onToken: @escaping (String) -> Void,
        onCompletion: @escaping (Result<Void, Error>) -> Void
    ) -> Task<Void, Never> {
        Task {
            guard let apiKey = apiKeyProvider() else {
                await MainActor.run { onCompletion(.failure(GeminiError.missingAPIKey)) }
                return
            }

            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse") else {
                await MainActor.run { onCompletion(.failure(GeminiAPIError.invalidURL)) }
                return
            }

            let body = buildRequestBody(prompt: prompt, context: context,
                                        recentMessages: recentMessages, conversationSummary: conversationSummary)
            guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                await MainActor.run { onCompletion(.failure(GeminiAPIError.noData)) }
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            request.httpBody = bodyData

            do {
                let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse {
                    switch http.statusCode {
                    case 401:
                        await MainActor.run { onCompletion(.failure(GeminiError.unauthorized)) }
                        return
                    case 404:
                        await MainActor.run { onCompletion(.failure(GeminiError.endpointNotFound)) }
                        return
                    case 200: break
                    default:
                        await MainActor.run { onCompletion(.failure(GeminiAPIError.badStatus(http.statusCode))) }
                        return
                    }
                }

                for try await line in asyncBytes.lines {
                    if Task.isCancelled { break }
                    if line.hasPrefix("data: ") {
                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr == "[DONE]" { break }
                        if let token = Self.extractToken(from: jsonStr) {
                            await MainActor.run { onToken(token) }
                        }
                    }
                }
                // Cancelled streams never report (LLMService.stream contract).
                if Task.isCancelled { return }
                await MainActor.run { onCompletion(.success(())) }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                await MainActor.run { onCompletion(.failure(GeminiError.networkFailure(error.localizedDescription))) }
            }
        }
    }

    // MARK: - Non-streaming generate (title gen / summarization)

    func generate(
        prompt: String,
        context: String?,
        recentMessages: [ChatMessage] = [],
        conversationSummary: String? = nil,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let apiKey = apiKeyProvider() else {
            DispatchQueue.main.async { completion(.failure(GeminiError.missingAPIKey)) }
            return
        }
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent") else {
            DispatchQueue.main.async { completion(.failure(GeminiAPIError.invalidURL)) }
            return
        }
        let body = buildRequestBody(prompt: prompt, context: context,
                                    recentMessages: recentMessages, conversationSummary: conversationSummary)
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            DispatchQueue.main.async { completion(.failure(GeminiAPIError.noData)) }
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = bodyData
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(GeminiError.networkFailure(error.localizedDescription))) }
                return
            }
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                switch http.statusCode {
                case 401, 403:
                    DispatchQueue.main.async { completion(.failure(GeminiError.unauthorized)) }
                case 404:
                    DispatchQueue.main.async { completion(.failure(GeminiError.endpointNotFound)) }
                default:
                    DispatchQueue.main.async { completion(.failure(GeminiError.networkFailure("HTTP \(http.statusCode)"))) }
                }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { completion(.failure(GeminiAPIError.noData)) }
                return
            }
            if let parsed = Self.parseSingleResponse(data: data) {
                DispatchQueue.main.async { completion(.success(parsed)) }
            } else {
                DispatchQueue.main.async { completion(.failure(GeminiError.networkFailure("Failed to parse Gemini response"))) }
            }
        }.resume()
    }

    // MARK: - Summarization

    func summarizeConversation(messages: [ChatMessage], completion: @escaping (Result<String, Error>) -> Void) {
        let transcript = messages.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
        let prompt = "Summarize this conversation in 2-3 sentences:\n\(transcript)\n\nReply with ONLY the summary."
        generate(prompt: prompt, context: nil) { result in
            switch result {
            case .success(let data):
                if let response = try? JSONDecoder().decode(LLMResponse.self, from: data) {
                    completion(.success(response.text))
                } else {
                    completion(.failure(GeminiError.networkFailure("Parse failed")))
                }
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    // MARK: - Helpers

    private func buildRequestBody(prompt: String, context: String?,
                                   recentMessages: [ChatMessage], conversationSummary: String?) -> [String: Any] {
        var contents: [[String: Any]] = []
        if let summary = conversationSummary {
            contents.append(["role": "user", "parts": [["text": "Previous conversation summary: \(summary)"]]])
            contents.append(["role": "model", "parts": [["text": "Understood."]]])
        }
        for msg in recentMessages {
            contents.append(["role": msg.role == .user ? "user" : "model", "parts": [["text": msg.text]]])
        }
        let userMessage: String
        if let ctx = context, !ctx.isEmpty {
            userMessage = "\(prompt)\n\n---\nContext:\n\(ctx)"
        } else {
            userMessage = prompt
        }
        contents.append(["role": "user", "parts": [["text": userMessage]]])
        let systemPrompt = "You are Luna, an intelligent browser assistant. Be concise and accurate. Use Markdown when it improves clarity. \(LLMClock.contextLine())"
        return [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            "generationConfig": ["temperature": 0.7, "maxOutputTokens": 8192]
        ]
    }

    private static func extractToken(from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else { return nil }
        return text
    }

    private static func parseSingleResponse(data: Data) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else { return nil }
        return try? JSONEncoder().encode(LLMResponse(text: text, action: nil))
    }
}

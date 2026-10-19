import Foundation

/// One chat turn sent to any provider.
struct LLMRequest {
    var prompt: String
    var context: String? = nil
    var recentMessages: [ChatMessage] = []
    var conversationSummary: String? = nil
    var systemPrompt: String = LLMRequest.defaultSystemPrompt

    static var defaultSystemPrompt: String {
        "You are Luna, an intelligent browser assistant. Be concise and accurate. Use Markdown when it improves clarity. " +
            "If the user wants to change how Luna looks or works (toolbar, bookmarks bar, layout, theme, tabs), point them to Personalize " +
            "in the composer's mode menu; Luna is customized only through its settings, never by writing code or building it. " +
            "\(LLMClock.contextLine())"
    }

    /// The final user message: the prompt plus any page/document context.
    var userMessage: String {
        guard let context, !context.isEmpty else { return prompt }
        return "\(prompt)\n\n---\nContext:\n\(context)"
    }

    /// Conversation as alternating user/assistant turns ending with the user
    /// message. Consecutive same-role turns are merged and empty ones dropped,
    /// which both OpenAI and Anthropic require.
    var turns: [(role: ChatMessage.Role, text: String)] {
        var raw: [(ChatMessage.Role, String)] = []
        if let summary = conversationSummary, !summary.isEmpty {
            raw.append((.user, "Summary of our earlier conversation: \(summary)"))
            raw.append((.assistant, "Understood."))
        }
        raw += recentMessages.map { ($0.role, $0.text) }
        raw.append((.user, userMessage))
        var merged: [(role: ChatMessage.Role, text: String)] = []
        for (role, text) in raw {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let last = merged.last, last.role == role {
                merged[merged.count - 1].text += "\n\n" + trimmed
            } else {
                merged.append((role, trimmed))
            }
        }
        // Must start with a user turn.
        while merged.first?.role == .assistant { merged.removeFirst() }
        return merged
    }
}

/// Errors shared by the cloud clients, phrased for the chat UI.
enum LLMError: LocalizedError {
    case notConfigured(String)
    case http(status: Int, message: String)
    case refused(String)
    case incomplete(String)
    case stream(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let msg): return msg
        case .http(let status, let message): return message.isEmpty ? "Request failed (HTTP \(status))." : message
        case .refused(let msg): return msg
        case .incomplete(let msg): return msg
        case .stream(let msg): return msg
        }
    }
}

/// Minimal Server-Sent Events reader over URLSession byte streams.
enum SSE {
    struct Event {
        var name: String?
        var data: String
    }

    /// Calls `handle` for each `data:` line (every provider here sends one
    /// JSON object per event). Return false to stop reading.
    static func read(_ bytes: URLSession.AsyncBytes, handle: (Event) throws -> Bool) async throws {
        try await read(lines: bytes.lines, handle: handle)
    }

    static func read<Lines: AsyncSequence>(lines: Lines, handle: (Event) throws -> Bool) async throws where Lines.Element == String {
        var name: String?
        for try await line in lines {
            if Task.isCancelled { return }
            if line.hasPrefix("event:") {
                name = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if try !handle(Event(name: name, data: value)) { return }
                name = nil
            }
        }
    }

    static func json(_ text: String) -> [String: Any]? {
        guard let d = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

/// Reads an error message out of a non-2xx response body.
func errorMessage(fromBody data: Data) -> String {
    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let err = json["error"] as? [String: Any], let msg = err["message"] as? String { return msg }
        if let msg = json["message"] as? String { return msg }
        if let msg = json["error_description"] as? String { return msg }
    }
    return String(data: data.prefix(300), encoding: .utf8) ?? ""
}

extension URLSession.AsyncBytes {
    /// Collects the remaining body (for error responses).
    func collect(limit: Int = 64_000) async -> Data {
        var data = Data()
        do {
            for try await byte in self {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {}
        return data
    }
}

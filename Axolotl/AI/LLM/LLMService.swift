import Foundation

/// Routes chat requests to the provider chosen in Settings → AI & Models.
/// Every AI surface (start page, side panel, Axolotl Max) goes through here.
final class LLMService {
    static let shared = LLMService()

    private let gemini = GeminiClient(apiKeyProvider: { KeychainManager.shared.fetchGeminiKey() })
    private let ollama = OllamaClient()

    nonisolated deinit {}

    var provider: AIProvider { AIProvider.current }

    /// The model the current provider will use, for display.
    var modelName: String {
        switch provider {
        case .chatgpt: return ModelPrefs.string(ModelPrefs.chatgptModel)
        case .openai: return ModelPrefs.string(ModelPrefs.openaiModel)
        case .anthropic: return ModelPrefs.string(ModelPrefs.anthropicModel, default: ModelPrefs.defaultAnthropicModel)
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return ModelPrefs.string(ModelPrefs.ollamaModel)
        }
    }

    /// Streams a reply. Cancel the returned task to stop it; `onCompletion`
    /// is not called after cancellation.
    @discardableResult
    func stream(_ request: LLMRequest,
                onToken: @escaping (String) -> Void,
                onCompletion: @escaping (Result<Void, Error>) -> Void) -> Task<Void, Never> {
        switch provider {
        case .gemini:
            return gemini.generateStreaming(
                prompt: request.prompt, context: request.context,
                recentMessages: request.recentMessages, conversationSummary: request.conversationSummary,
                onToken: onToken, onCompletion: onCompletion)
        case .ollama:
            return ollama.generateStreaming(
                baseURLString: ModelPrefs.string(ModelPrefs.ollamaBaseURL, default: "http://127.0.0.1:11434"),
                model: ModelPrefs.string(ModelPrefs.ollamaModel),
                prompt: request.prompt, context: request.context,
                recentMessages: request.recentMessages, conversationSummary: request.conversationSummary,
                onToken: onToken, onCompletion: onCompletion)
        case .chatgpt, .openai, .anthropic:
            let provider = self.provider
            let model = modelName
            return Task {
                do {
                    switch provider {
                    case .chatgpt:
                        try await OpenAIResponsesClient(credential: .chatGPT).stream(model: model, request: request, onToken: onToken)
                    case .openai:
                        try await OpenAIResponsesClient(credential: .apiKey).stream(model: model, request: request, onToken: onToken)
                    default:
                        try await AnthropicClient().stream(model: model, request: request, onToken: onToken)
                    }
                    if !Task.isCancelled { onCompletion(.success(())) }
                } catch {
                    if !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled {
                        onCompletion(.failure(error))
                    }
                }
            }
        }
    }

    /// Collects a full reply (titles, summaries, Axolotl Max).
    func complete(_ request: LLMRequest) async throws -> String {
        try await Self.collect { stream(request, onToken: $0, onCompletion: $1) }
    }

    /// Runs a `stream`-shaped call to completion. Cancelling the caller cancels the stream and
    /// throws CancellationError; cancelled streams never call onCompletion, so this resumes itself.
    static func collect(_ start: (@escaping (String) -> Void, @escaping (Result<Void, Error>) -> Void) -> Task<Void, Never>) async throws -> String {
        let state = CollectState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                guard state.begin(cont) else { return }
                state.setTask(start({ state.append($0) }, { state.finish($0) }))
            }
        } onCancel: {
            state.cancel()
        }
    }

    func complete(_ request: LLMRequest, completion: @escaping (Result<String, Error>) -> Void) {
        Task {
            do { completion(.success(try await complete(request))) } catch { completion(.failure(error)) }
        }
    }

    static let maxSummaryChars = 1_500

    /// Folds the previous summary and the new messages into one summary, so it stays bounded.
    static func summaryRequest(previous: String?, messages: [ChatMessage]) -> LLMRequest {
        let transcript = messages.map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }.joined(separator: "\n")
        let prior = previous.flatMap { $0.isEmpty ? nil : "Earlier summary:\n\($0)\n\nNew messages:\n" } ?? ""
        return LLMRequest(prompt: "Summarize this conversation in 2-4 sentences, merging any earlier summary into one:\n\(prior)\(transcript)\n\nReply with ONLY the summary.")
    }

    /// Summary used to keep long conversations within context, capped at `maxSummaryChars`.
    func summarize(_ messages: [ChatMessage], previous: String? = nil, completion: @escaping (Result<String, Error>) -> Void) {
        complete(Self.summaryRequest(previous: previous, messages: messages)) { result in
            completion(result.map { String($0.prefix(Self.maxSummaryChars)) })
        }
    }
}

/// Shared by `collect`'s callbacks (any thread) and its cancel handler; resumes the continuation once.
private nonisolated final class CollectState: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<String, Error>?
    private var task: Task<Void, Never>?
    private var text = ""
    private var cancelled = false

    /// False if already cancelled (the continuation is resumed with CancellationError).
    func begin(_ c: CheckedContinuation<String, Error>) -> Bool {
        lock.lock()
        if cancelled { lock.unlock(); c.resume(throwing: CancellationError()); return false }
        cont = c
        lock.unlock()
        return true
    }

    func setTask(_ t: Task<Void, Never>) {
        lock.lock()
        let late = cancelled
        if !late { task = t }
        lock.unlock()
        if late { t.cancel() }
    }

    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = cont; cont = nil
        let out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        switch result {
        case .success: c?.resume(returning: out)
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let c = cont, t = task
        cont = nil; task = nil
        lock.unlock()
        t?.cancel()
        c?.resume(throwing: CancellationError())
    }
}

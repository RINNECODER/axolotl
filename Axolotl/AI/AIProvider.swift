import Foundation

/// AI backends. Subscriptions (a ChatGPT sign-in, or a coding CLI already signed in on this Mac)
/// come first; API-key providers are the alternative, with OpenRouter recommended.
enum AIProvider: String, CaseIterable, Identifiable {
    case chatgpt = "chatgpt"
    case codexCLI = "codex-cli"
    case claudeCLI = "claude-cli"
    case openrouter = "openrouter"
    case anthropic = "anthropic"
    case openai = "openai"
    case gemini = "gemini"
    case ollama = "ollama"

    static let defaultsKey = "axolotl_ai_provider"

    /// "Use an API key instead", in display order.
    static let apiProviders: [AIProvider] = [.openrouter, .anthropic, .openai, .gemini, .ollama]

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .codexCLI: return "Codex CLI"
        case .claudeCLI: return "Claude Code"
        case .openrouter: return "OpenRouter"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI API"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama (local)"
        }
    }

    var detail: String {
        switch self {
        case .chatgpt: return "Uses your ChatGPT Plus or Pro plan. Sign in with your ChatGPT account."
        case .codexCLI: return "Uses the Codex CLI already signed in on this Mac, and its plan."
        case .claudeCLI: return "Uses Claude Code already signed in on this Mac, and its plan."
        case .openrouter: return "One key, every model. Recommended."
        case .anthropic: return "Claude models with an API key from the Claude Console."
        case .openai: return "OpenAI models with an API key from the OpenAI platform."
        case .gemini: return "Google Gemini with an API key from Google AI Studio."
        case .ollama: return "Models running on this Mac. Nothing leaves your computer."
        }
    }

    /// The signed-in CLI behind a subscription provider.
    var harness: HarnessID? {
        switch self {
        case .codexCLI: return .codex
        case .claudeCLI: return .claudeCode
        default: return nil
        }
    }

    var isAPIKey: Bool { Self.apiProviders.contains(self) }


    static var current: AIProvider {
        resolved(saved: UserDefaults.standard.string(forKey: defaultsKey),
                 hasGeminiKey: KeychainManager.shared.data(for: .geminiKey) != nil)
    }

    /// A saved choice always wins. Before OpenRouter, an unsaved choice meant Gemini, so keep
    /// Gemini for anyone who already added its key; everyone else starts on OpenRouter.
    static func resolved(saved: String?, hasGeminiKey: Bool) -> AIProvider {
        if let saved, let provider = AIProvider(rawValue: saved) { return provider }
        return hasGeminiKey ? .gemini : .openrouter
    }
}

/// Per-provider model selections (Settings → AI & Models).
enum ModelPrefs {
    static let chatgptModel = "axolotl_chatgpt_model"
    static let openaiModel = "axolotl_openai_model"
    static let anthropicModel = "axolotl_anthropic_model"
    static let openrouterModel = "axolotl_openrouter_model"
    static let codexCLIModel = "axolotl_codex_cli_model"
    static let claudeCLIModel = "axolotl_claude_cli_model"
    static let ollamaModel = "axolotl_ollama_model"
    static let ollamaBaseURL = "axolotl_ollama_base_url"

    static let defaultAnthropicModel = "claude-opus-5-5"

    static func string(_ key: String, default value: String = "") -> String {
        UserDefaults.standard.string(forKey: key) ?? value
    }
}

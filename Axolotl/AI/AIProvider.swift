import Foundation

/// AI backends. Cloud providers authenticate with a ChatGPT sign-in or an API key.
enum AIProvider: String, CaseIterable, Identifiable {
    case chatgpt = "chatgpt"
    case anthropic = "anthropic"
    case openai = "openai"
    case gemini = "gemini"
    case ollama = "ollama"

    static let defaultsKey = "axolotl_ai_provider"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatgpt: return "ChatGPT"
        case .anthropic: return "Anthropic"
        case .openai: return "OpenAI API"
        case .gemini: return "Gemini"
        case .ollama: return "Ollama (local)"
        }
    }

    var detail: String {
        switch self {
        case .chatgpt: return "Uses your ChatGPT Plus or Pro plan. Sign in with your ChatGPT account."
        case .anthropic: return "Claude models with an API key from the Claude Console."
        case .openai: return "OpenAI models with an API key from the OpenAI platform."
        case .gemini: return "Google Gemini with an API key from Google AI Studio."
        case .ollama: return "Models running on this Mac. Nothing leaves your computer."
        }
    }

    static var current: AIProvider {
        AIProvider(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .gemini
    }
}

/// Per-provider model selections (Settings → AI & Models).
enum ModelPrefs {
    static let chatgptModel = "axolotl_chatgpt_model"
    static let openaiModel = "axolotl_openai_model"
    static let anthropicModel = "axolotl_anthropic_model"
    static let ollamaModel = "axolotl_ollama_model"
    static let ollamaBaseURL = "axolotl_ollama_base_url"

    static let defaultAnthropicModel = "claude-opus-5-5"

    static func string(_ key: String, default value: String = "") -> String {
        UserDefaults.standard.string(forKey: key) ?? value
    }
}

import AppKit
import SwiftUI

/// Settings → AI: choose a provider, sign in or add a key, pick a model; the AI panel, Luna Max
/// features, computer use and grabbed keys.
struct ModelsSettingsView: View {
    var body: some View {
        AIProviderSections()
        AIPanelSection()
        LunaMaxSections()
        ComputerUseSection()
        GrabbedKeysSection()
    }
}

/// Provider picker plus that provider's sign-in or key and model (Settings → AI, welcome flow).
struct AIProviderSections: View {
    @AppStorage(AIProvider.defaultsKey) private var providerRaw: String = AIProvider.gemini.rawValue

    private var provider: Binding<AIProvider> {
        Binding(get: { AIProvider(rawValue: providerRaw) ?? .gemini }, set: { providerRaw = $0.rawValue })
    }

    var body: some View {
        Group {
            SettingsCard("Provider") {
                SettingsMenuRow("Provider", subtitle: provider.wrappedValue.detail, selection: provider,
                                options: AIProvider.allCases.map { .init($0, $0.displayName) })
            }

            switch provider.wrappedValue {
            case .chatgpt: ChatGPTSection()
            case .anthropic: AnthropicSection()
            case .openai: OpenAISection()
            case .gemini: GeminiSection()
            case .ollama: OllamaSection()
            }
        }
    }
}

// MARK: - ChatGPT

private struct ChatGPTSection: View {
    @ObservedObject private var auth = ChatGPTAuth.shared
    @AppStorage(ModelPrefs.chatgptModel) private var model = ""
    @State private var error: String?

    var body: some View {
        SettingsCard("ChatGPT account", footer: "Requires ChatGPT Plus or Pro. Requests count against your plan, up to a weekly limit you set in ChatGPT. Luna never sees your password or your ChatGPT conversations.") {
            if let creds = auth.credentials {
                SettingsRow("Signed in as", subtitle: creds.email.isEmpty ? (creds.name ?? "ChatGPT user") : creds.email,
                            icon: "person.crop.circle") {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            let revoked = await auth.signOut()
                            error = revoked ? nil : "Signed out on this Mac. OpenAI didn't confirm revoking access; you can disconnect Luna in ChatGPT settings."
                        }
                    }
                }
            } else if auth.isSigningIn {
                SettingsRow("Finish signing in in your browser…") {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { auth.cancelSignIn() }
                }
            } else {
                SettingsRow("ChatGPT", subtitle: "Use your ChatGPT plan in Luna.") {
                    Button("Sign in with ChatGPT") {
                        error = nil
                        Task {
                            do { try await auth.signIn() } catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.settingsProminent)
                }
            }
            if let error {
                SettingsNoteRow(error, isError: true)
            }
        }
        if auth.isSignedIn {
            SettingsCard("Model") {
                ModelPicker(selection: $model) {
                    try await ModelCatalog.load(.chatgpt)
                }
            }
        }
    }
}

// MARK: - API-key providers

private struct AnthropicSection: View {
    @AppStorage(ModelPrefs.anthropicModel) private var model = ModelPrefs.defaultAnthropicModel

    var body: some View {
        SettingsCard("Anthropic API key", footer: "Anthropic doesn't offer sign-in for other apps, so Luna uses an API key. Usage is billed to your Console account.") {
            APIKeyField(account: .anthropicKey, placeholder: "sk-ant-…")
            SettingsLinkRow("Get an API key from the Claude Console", external: true) {
                NSWorkspace.shared.open(URL(string: "https://console.anthropic.com/settings/keys")!)
            }
        }
        SettingsCard("Model") {
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.anthropic)
            }
        }
    }
}

private struct OpenAISection: View {
    @AppStorage(ModelPrefs.openaiModel) private var model = ""

    var body: some View {
        SettingsCard("OpenAI API key") {
            APIKeyField(account: .openAIKey, placeholder: "sk-…")
            SettingsLinkRow("Get an API key from the OpenAI platform", external: true) {
                NSWorkspace.shared.open(URL(string: "https://platform.openai.com/api-keys")!)
            }
        }
        SettingsCard("Model") {
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.openai)
            }
        }
    }
}

private struct GeminiSection: View {
    var body: some View {
        SettingsCard("Gemini API key") {
            APIKeyField(account: .geminiKey, placeholder: "AIza…")
            SettingsLinkRow("Get an API key from Google AI Studio", external: true) {
                NSWorkspace.shared.open(URL(string: "https://aistudio.google.com/apikey")!)
            }
        }
    }
}

private struct OllamaSection: View {
    @AppStorage(ModelPrefs.ollamaBaseURL) private var baseURL = "http://127.0.0.1:11434"
    @AppStorage(ModelPrefs.ollamaModel) private var model = ""

    var body: some View {
        SettingsCard("Ollama") {
            OllamaServerPicker(baseURL: $baseURL)
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.ollama)
            }
            .id(baseURL)
        }
    }
}

/// Server pop-up: Ollama instances found on this Mac, the current server, and Custom… for any URL.
private struct OllamaServerPicker: View {
    @Binding var baseURL: String
    @State private var detected: [String] = []
    @State private var searched = false
    @State private var editingCustom = false
    @State private var draft = ""
    private static let customTag = "luna.ollama.custom"

    var body: some View {
        let servers = detected + (detected.contains(baseURL) || baseURL.isEmpty ? [] : [baseURL])
        SettingsMenuRow("Server", subtitle: searched && detected.isEmpty ? "No running Ollama found on this Mac. Start Ollama, or choose Custom…" : nil,
                   selection: Binding(get: { editingCustom ? Self.customTag : baseURL },
                                      set: { value in
                                          if value == Self.customTag { draft = baseURL; editingCustom = true }
                                          else { editingCustom = false; baseURL = value }
                                      }),
                   options: servers.map { .init($0, label($0)) } + [.init(Self.customTag, "Custom…")])
            .task {
                detected = await OllamaDiscovery.running()
                searched = true
            }
        if editingCustom {
            SettingsContentRow {
                HStack {
                    TextField("Server URL", text: $draft, prompt: Text(OllamaDiscovery.defaultURL))
                        .textFieldStyle(SettingsTextFieldStyle())
                        .autocorrectionDisabled()
                        .onSubmit(applyCustom)
                    Button("Use", action: applyCustom).disabled(URL(string: draft)?.host == nil)
                }
            }
        }
    }

    private func label(_ url: String) -> String {
        let short = url.replacingOccurrences(of: "http://", with: "")
        return detected.contains(url) ? "\(short) (running)" : short
    }

    private func applyCustom() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(string: trimmed)?.host != nil else { return }
        baseURL = trimmed
        editingCustom = false
    }
}

/// Finds Ollama servers on this Mac by asking the usual local ports for `/api/version`.
enum OllamaDiscovery {
    static let defaultURL = "http://127.0.0.1:11434"
    static let candidates = [11434, 11435, 11436].map { "http://127.0.0.1:\($0)" }

    static func running(_ candidates: [String] = candidates) async -> [String] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (i, base) in candidates.enumerated() {
                group.addTask {
                    guard let url = URL(string: base + "/api/version") else { return (i, nil) }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 1
                    let ok = (try? await URLSession.shared.data(for: request)).map { ($0.1 as? HTTPURLResponse)?.statusCode == 200 } ?? false
                    return (i, ok ? base : nil)
                }
            }
            var found: [(Int, String)] = []
            for await (i, base) in group { if let base { found.append((i, base)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

// MARK: - AI panel and Luna Max

private struct AIPanelSection: View {
    @AppStorage("luma_ai_panel_font_size") private var fontSize: Int = 13

    var body: some View {
        SettingsCard("AI panel") {
            SettingsRow(RegistrySettings.setting("aiPanel.fontSize").title) {
                HStack {
                    Slider(value: Binding(get: { Double(fontSize) }, set: { fontSize = Int($0.rounded()) }),
                           in: 10...24, step: 1)
                        .frame(width: 200)
                    Text("\(fontSize) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

/// Luna Max: AI features in the browser itself.
private struct LunaMaxSections: View {
    var body: some View {
        SettingsCard("Luna Max") {
            RegistryToggle("lunaMax.askOnPage")
            RegistryToggle("lunaMax.linkPreviews")
        }
        SettingsCard("Luna Max: automatic", footer: "Automatic features send tab titles or file names to your AI provider. Tidy Today is always in the ✦ button on the sidebar's Today divider.") {
            RegistryToggle("lunaMax.tidyTitles")
            RegistryToggle("lunaMax.tidyDownloads")
        }
    }
}

// MARK: - Computer use

/// Agent mode (`/agent <goal>` in the AI panel). Uses Jev when a TypeSafe key is saved,
/// otherwise the provider above picks each step.
private struct ComputerUseSection: View {
    @AppStorage(JevClient.modelDefaultsKey) private var model = JevClient.defaultModel

    var body: some View {
        SettingsCard("Computer use (Jev)", footer: "Choose Agent in the AI panel composer (or type /agent and a goal) to let Luna operate the current tab. With a TypeSafe key, Jev picks each step; without one, your chat model does and also writes any typed values.") {
            APIKeyField(account: .typesafeKey, placeholder: "TypeSafe API key")
            ModelPicker(selection: $model) {
                guard let key = KeychainManager.shared.string(for: .typesafeKey), !key.isEmpty else {
                    throw AgentError.transport("Add a TypeSafe API key to list Jev models.")
                }
                return try await JevClient.listModels(apiKey: key)
            }
        }
    }
}

/// Keys saved by `/grab` and the `grab_api_key` tool. Values stay in the Keychain;
/// this list shows names and dates only, with Copy and Delete.
private struct GrabbedKeysSection: View {
    @AppStorage(SecretVault.autoClearKey) private var autoClear = true
    @State private var items: [SecretVault.Item] = []
    @State private var copied: String?

    var body: some View {
        SettingsCard("API keys grabbed by Luna", footer: "Saved in Keychain Access under “\(SecretVault.defaultService)”. The agent and outside agents never see the values.") {
            if items.isEmpty {
                SettingsNoteRow("None yet. Choose Grab key in the AI panel composer and pick a service.")
            }
            ForEach(items) { item in
                SettingsRow(item.account, subtitle: item.created?.formatted(date: .abbreviated, time: .shortened),
                            icon: "key") {
                    if copied == item.account { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                    Button("Copy") { if SecretVault.shared.copy(account: item.account) { copied = item.account } }
                    Button("Delete", role: .destructive) {
                        SecretVault.shared.delete(account: item.account)
                        reload()
                    }
                }
            }
            SettingsToggleRow("Clear the clipboard \(Int(SecretVault.autoClearSeconds)) s after copying a key", isOn: $autoClear)
        }
        .onAppear(perform: reload)
    }

    private func reload() { items = SecretVault.shared.items() }
}

// MARK: - Shared rows

/// Secure field that saves to the Keychain; shows a masked state once stored.
struct APIKeyField: View {
    let account: KeychainManager.Account
    let placeholder: String

    @State private var input = ""
    @State private var hasKey = false
    @State private var status: String?

    var body: some View {
        Group {
            if hasKey {
                SettingsRow("API key", subtitle: "Saved in Keychain", icon: "checkmark.seal.fill") {
                    Button("Remove", role: .destructive) {
                        try? KeychainManager.shared.delete(account)
                        hasKey = false
                    }
                }
            } else {
                SettingsRow("API key") {
                    SecureField("API key", text: $input, prompt: Text(placeholder))
                        .textFieldStyle(SettingsTextFieldStyle())
                        .frame(width: 260)
                    Button("Save") {
                        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            try KeychainManager.shared.store(key, for: account)
                            input = ""
                            hasKey = true
                            status = nil
                        } catch {
                            status = error.localizedDescription
                        }
                    }
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if let status { SettingsNoteRow(status, isError: true) }
        }
        .onAppear { hasKey = KeychainManager.shared.data(for: account) != nil }
    }
}

/// Model pop-up filled from the provider's model list, with a refresh button.
/// Keeps the current selection visible even if the list hasn't loaded.
private struct ModelPicker: View {
    @Binding var selection: String
    let load: () async throws -> [(id: String, name: String)]

    @State private var models: [(id: String, name: String)] = []
    @State private var loading = false
    @State private var error: String?

    private var options: [(id: String, name: String)] {
        if selection.isEmpty || models.contains(where: { $0.id == selection }) { return models }
        return [(selection, selection)] + models
    }

    var body: some View {
        SettingsRow("Model") {
            SettingsDropdown(title: "Model", selection: $selection,
                             options: (selection.isEmpty ? [.init("", "Choose a model")] : [])
                                 + options.map { .init($0.id, $0.name) })
            Button {
                Task { await refresh() }
            } label: {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh models")
            .accessibilityLabel("Refresh models")
            .disabled(loading)
        }
        .task { await refresh() }
        if let error {
            SettingsNoteRow(error)
        }
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        do {
            models = try await load()
            error = models.isEmpty ? "No models available." : nil
            if selection.isEmpty, let first = models.first { selection = first.id }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

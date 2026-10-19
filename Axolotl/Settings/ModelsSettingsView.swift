import AppKit
import SwiftUI

/// Settings → AI: choose a provider, sign in or add a key, pick a model; the AI panel, Axolotl Max
/// features, computer use and grabbed keys.
struct ModelsSettingsView: View {
    var body: some View {
        AIProviderSections()
        AIPanelSection()
        AxolotlMaxSections()
        ComputerUseSection()
        GrabbedKeysSection()
    }
}

/// Provider setup (Settings → AI, welcome flow): subscriptions first (ChatGPT sign-in, signed-in
/// CLIs), then "Use an API key instead" with OpenRouter recommended, then the chosen provider's model.
struct AIProviderSections: View {
    @AppStorage(AIProvider.defaultsKey) private var providerRaw: String = AIProvider.current.rawValue
    @State private var clis: [(provider: AIProvider, signedIn: Bool)] = []
    @State private var showAPI = AIProvider.current.isAPIKey && UserDefaults.standard.string(forKey: AIProvider.defaultsKey) != nil

    private var provider: AIProvider { AIProvider(rawValue: providerRaw) ?? .current }

    var body: some View {
        Group {
            SettingsCard("Use a subscription") {
                ChatGPTRow(provider: provider, use: { providerRaw = AIProvider.chatgpt.rawValue })
                ForEach(clis, id: \.provider) { cli in
                    CLIRow(cli: cli.provider, signedIn: cli.signedIn, inUse: provider == cli.provider,
                           use: { providerRaw = cli.provider.rawValue }, recheck: { Task { await scan(refresh: true) } })
                }
            }

            switch provider {
            case .chatgpt: ChatGPTSection()
            case .codexCLI, .claudeCLI: CLIModelSection(provider: provider)
            default: EmptyView()
            }

            SettingsCard {
                SettingsLinkRow(showAPI ? "Hide API keys" : "Use an API key instead",
                                subtitle: "OpenRouter, Anthropic, OpenAI, Gemini or a local Ollama", icon: "key") {
                    showAPI.toggle()
                }
            }
            if showAPI {
                SettingsCard("API provider") {
                    ForEach(AIProvider.apiProviders) { p in
                        SettingsRow(p == .openrouter ? "OpenRouter (recommended)" : p.displayName, subtitle: p.detail) {
                            UseButton(inUse: provider == p) { providerRaw = p.rawValue }
                        }
                    }
                }
                switch provider {
                case .openrouter: OpenRouterSection()
                case .anthropic: AnthropicSection()
                case .openai: OpenAISection()
                case .gemini: GeminiSection()
                case .ollama: OllamaSection()
                default: EmptyView()
                }
            }
        }
        .task { await scan(refresh: false) }
    }

    private func scan(refresh: Bool) async {
        clis = CLIChatClient.installed(await HarnessCatalog.shared.discover(refresh: refresh))
    }
}

/// "In use" when selected, else a Use button.
private struct UseButton: View {
    let inUse: Bool
    var prominent = false
    let action: () -> Void

    var body: some View {
        if inUse {
            Label("In use", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 28)
        } else {
            Button("Use", action: action).buttonStyle(prominent ? .settingsProminent : .settings)
        }
    }
}

/// One subscription in "Use a subscription": logo, name, sign-in status, then its action.
struct SubscriptionRow<Trailing: View>: View {
    let name: String
    var detail: String?
    let symbol: String
    /// The provider's Mac app, whose icon is used when it's installed.
    var appBundleID: String?
    let signedIn: Bool
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            logo.frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 14, weight: .semibold))
                    Text(signedIn ? "Signed in" : "Not signed in")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(signedIn ? Color.green : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((signedIn ? Color.green : Color.secondary).opacity(0.15)))
                }
                if let detail, !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .settingsRowPadding()
    }

    @ViewBuilder private var logo: some View {
        if let appBundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable()
        } else {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
        }
    }
}

/// A Codex / Claude Code CLI found on this Mac.
struct CLIRow: View {
    let cli: AIProvider
    let signedIn: Bool
    let inUse: Bool
    let use: () -> Void
    let recheck: () -> Void
    @State private var showSignIn = false

    private var name: String { cli.harness?.displayName ?? cli.displayName }
    private var command: String { cli == .claudeCLI ? "claude auth login" : "codex login" }
    private var appBundleID: String { cli == .claudeCLI ? "com.anthropic.claudefordesktop" : "com.openai.codex" }

    var body: some View {
        SubscriptionRow(name: name, symbol: "terminal", appBundleID: appBundleID, signedIn: signedIn) {
            if signedIn {
                UseButton(inUse: inUse, prominent: true, action: use)
            } else {
                Button("Sign in…") { showSignIn = true }
                    .buttonStyle(.settings)
                    .popover(isPresented: $showSignIn, arrowEdge: .bottom) { signInHelp }
            }
        }
    }

    private var signInHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sign in to \(name) in Terminal, then check again.").font(.system(size: 13))
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
            HStack {
                Spacer()
                Button("Check Again") { showSignIn = false; recheck() }.buttonStyle(.settingsProminent)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - ChatGPT

/// The ChatGPT entry in "Use a subscription": sign in, or use the signed-in account.
private struct ChatGPTRow: View {
    let provider: AIProvider
    let use: () -> Void
    @ObservedObject private var auth = ChatGPTAuth.shared
    @State private var error: String?
    /// A cancelled sign-in: a quiet note that clears itself.
    @State private var notice: String?

    var body: some View {
        if let creds = auth.credentials {
            SubscriptionRow(name: "ChatGPT", detail: creds.email.isEmpty ? creds.name : creds.email,
                            symbol: "bubble.left.and.text.bubble.right", appBundleID: "com.openai.chat", signedIn: true) {
                UseButton(inUse: provider == .chatgpt, prominent: true, action: use)
            }
        } else if auth.isSigningIn {
            SettingsRow("Finish signing in in your browser…", icon: "bubble.left.and.text.bubble.right") {
                ProgressView().controlSize(.small)
                Button("Cancel") { auth.cancelSignIn() }
            }
        } else {
            SubscriptionRow(name: "ChatGPT", detail: "Use your Plus or Pro plan.", symbol: "bubble.left.and.text.bubble.right",
                            appBundleID: "com.openai.chat", signedIn: false) {
                Button("Sign in with ChatGPT") {
                    error = nil
                    notice = nil
                    Task {
                        do { try await auth.signIn(); use() } catch {
                            if Self.isCancel(error) { notice = error.localizedDescription } else { self.error = error.localizedDescription }
                        }
                    }
                }
                .buttonStyle(.settingsProminent)
            }
        }
        if let error {
            SettingsNoteRow(error, isError: true)
        }
        if let notice {
            SettingsNoteRow(notice)
                .transition(.opacity)
                .task(id: notice) {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation { if self.notice == notice { self.notice = nil } }
                }
        }
    }

    static func isCancel(_ error: Error) -> Bool {
        if case .cancelled? = error as? LoopbackServer.ServerError { return true }
        if case .denied? = error as? ChatGPTAuth.AuthError { return true }
        return false
    }
}

/// The signed-in ChatGPT account and its model, shown while ChatGPT is in use.
private struct ChatGPTSection: View {
    @ObservedObject private var auth = ChatGPTAuth.shared
    @AppStorage(ModelPrefs.chatgptModel) private var model = ""
    @State private var error: String?

    var body: some View {
        if let creds = auth.credentials {
            SettingsCard("ChatGPT", footer: "Requires ChatGPT Plus or Pro. Requests count against your plan, up to a weekly limit you set in ChatGPT. Axolotl never sees your password or your ChatGPT conversations.") {
                SettingsRow("Signed in as", subtitle: creds.email.isEmpty ? (creds.name ?? "ChatGPT user") : creds.email,
                            icon: "person.crop.circle") {
                    Button("Sign Out", role: .destructive) {
                        Task {
                            let revoked = await auth.signOut()
                            error = revoked ? nil : "Signed out on this Mac. OpenAI didn't confirm revoking access; you can disconnect Axolotl in ChatGPT settings."
                        }
                    }
                }
                ModelPicker(selection: $model) {
                    try await ModelCatalog.load(.chatgpt)
                }
                if let error {
                    SettingsNoteRow(error, isError: true)
                }
            }
        }
    }
}

// MARK: - Signed-in CLIs

private struct CLIModelSection: View {
    let provider: AIProvider
    @AppStorage private var model: String

    init(provider: AIProvider) {
        self.provider = provider
        _model = AppStorage(wrappedValue: "", ModelCatalog.modelKey(for: provider) ?? "")
    }

    var body: some View {
        SettingsCard(provider.displayName, footer: "Each reply runs the CLI once with its tools off, on its own plan.") {
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(provider)
            }
        }
        .id(provider)
    }
}

// MARK: - API-key providers

private struct OpenRouterSection: View {
    @AppStorage(ModelPrefs.openrouterModel) private var model = ""

    var body: some View {
        SettingsCard("OpenRouter API key", footer: "One key for models from every major lab, billed to your OpenRouter credits. The same key also runs computer use on TypeSafe's Jev router.") {
            APIKeyField(account: .openRouterKey, placeholder: "sk-or-…")
            SettingsLinkRow("Get an API key from OpenRouter", external: true) {
                NSWorkspace.shared.open(KeyService.registry.first { $0.id == "openrouter" }!.url)
            }
        }
        SettingsCard("Model") {
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.openrouter)
            }
        }
    }
}

private struct AnthropicSection: View {
    @AppStorage(ModelPrefs.anthropicModel) private var model = ModelPrefs.defaultAnthropicModel

    var body: some View {
        SettingsCard("Anthropic API key", footer: "Anthropic doesn't offer sign-in for other apps, so Axolotl uses an API key. Usage is billed to your Console account.") {
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
    private static let customTag = "axolotl.ollama.custom"

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

// MARK: - AI panel and Axolotl Max

private struct AIPanelSection: View {
    @AppStorage("axolotl_ai_panel_font_size") private var fontSize: Int = 13

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

/// Axolotl Max: AI features in the browser itself.
private struct AxolotlMaxSections: View {
    var body: some View {
        SettingsCard("Axolotl Max") {
            RegistryToggle("axolotlMax.askOnPage")
            RegistryToggle("axolotlMax.linkPreviews")
        }
        SettingsCard("Axolotl Max: automatic", footer: "Automatic features send tab titles or file names to your AI provider. Tidy Today is always in the axolotl button on the sidebar's Today divider.") {
            RegistryToggle("axolotlMax.tidyTitles")
            RegistryToggle("axolotlMax.tidyDownloads")
        }
    }
}

// MARK: - Computer use

/// Agent mode (`/agent <goal>` in the AI panel). Uses Jev when a TypeSafe key is saved, else Jev router via OpenRouter,
/// otherwise the provider above picks each step.
private struct ComputerUseSection: View {
    @AppStorage(JevClient.modelDefaultsKey) private var model = JevClient.defaultModel

    var body: some View {
        SettingsCard("Computer use (Jev)", footer: "Choose Agent in the AI panel composer (or type /agent and a goal) to let Axolotl operate the current tab. With a TypeSafe key, Jev picks each step; without one, an OpenRouter key runs TypeSafe’s Jev router; with neither, your chat model does. Typed values come from your chat model.") {
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
        SettingsCard("API keys grabbed by Axolotl", footer: "Saved in Keychain Access under “\(SecretVault.defaultService)”. The agent and outside agents never see the values.") {
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

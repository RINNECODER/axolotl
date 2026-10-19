import AppKit
import SwiftUI

/// Settings → AI & Models: choose a provider, sign in or add a key, pick a model.
struct ModelsSettingsView: View {
    @AppStorage(AIProvider.defaultsKey) private var providerRaw: String = AIProvider.gemini.rawValue

    private var provider: Binding<AIProvider> {
        Binding(get: { AIProvider(rawValue: providerRaw) ?? .gemini }, set: { providerRaw = $0.rawValue })
    }

    var body: some View {
        Form {
            Section {
                LunaPicker("Provider", selection: provider,
                           options: AIProvider.allCases.map { .init($0, $0.displayName) })
                Text(provider.wrappedValue.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            switch provider.wrappedValue {
            case .chatgpt: ChatGPTSection()
            case .anthropic: AnthropicSection()
            case .openai: OpenAISection()
            case .gemini: GeminiSection()
            case .ollama: OllamaSection()
            }

            ComputerUseSection()
            GrabbedKeysSection()
            ConnectAgentsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - ChatGPT

private struct ChatGPTSection: View {
    @ObservedObject private var auth = ChatGPTAuth.shared
    @AppStorage(ModelPrefs.chatgptModel) private var model = ""
    @State private var error: String?

    var body: some View {
        Section("ChatGPT account") {
            if let creds = auth.credentials {
                LabeledContent("Signed in as") {
                    Text(creds.email.isEmpty ? (creds.name ?? "ChatGPT user") : creds.email)
                }
                Button("Sign Out", role: .destructive) {
                    Task {
                        let revoked = await auth.signOut()
                        error = revoked ? nil : "Signed out on this Mac. OpenAI didn't confirm revoking access; you can disconnect Luna in ChatGPT settings."
                    }
                }
            } else if auth.isSigningIn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { auth.cancelSignIn() }
                }
            } else {
                Button("Sign in with ChatGPT") {
                    error = nil
                    Task {
                        do { try await auth.signIn() } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Text("Requires ChatGPT Plus or Pro. Requests count against your plan, up to a weekly limit you set in ChatGPT. Luna never sees your password or your ChatGPT conversations.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if auth.isSignedIn {
            Section("Model") {
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
        Section("Anthropic API key") {
            APIKeyField(account: .anthropicKey, placeholder: "sk-ant-…")
            Link("Get an API key from the Claude Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
            Text("Anthropic doesn't offer sign-in for other apps, so Luna uses an API key. Usage is billed to your Console account.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        Section("Model") {
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.anthropic)
            }
        }
    }
}

private struct OpenAISection: View {
    @AppStorage(ModelPrefs.openaiModel) private var model = ""

    var body: some View {
        Section("OpenAI API key") {
            APIKeyField(account: .openAIKey, placeholder: "sk-…")
            Link("Get an API key from the OpenAI platform", destination: URL(string: "https://platform.openai.com/api-keys")!)
        }
        Section("Model") {
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.openai)
            }
        }
    }
}

private struct GeminiSection: View {
    var body: some View {
        Section("Gemini API key") {
            APIKeyField(account: .geminiKey, placeholder: "AIza…")
            Link("Get an API key from Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
        }
    }
}

private struct OllamaSection: View {
    @AppStorage(ModelPrefs.ollamaBaseURL) private var baseURL = "http://127.0.0.1:11434"
    @AppStorage(ModelPrefs.ollamaModel) private var model = ""

    var body: some View {
        Section("Ollama") {
            TextField("Server", text: $baseURL, prompt: Text("http://127.0.0.1:11434"))
                .autocorrectionDisabled()
            ModelPicker(selection: $model) {
                try await ModelCatalog.load(.ollama)
            }
            .id(baseURL)
        }
    }
}

// MARK: - Computer use

/// Agent mode (`/agent <goal>` in the AI panel). Uses Jev when a TypeSafe key is saved,
/// otherwise the provider above picks each step.
private struct ComputerUseSection: View {
    @AppStorage(JevClient.modelDefaultsKey) private var model = JevClient.defaultModel

    var body: some View {
        Section("Computer use (Jev)") {
            APIKeyField(account: .typesafeKey, placeholder: "TypeSafe API key")
            ModelPicker(selection: $model) {
                guard let key = KeychainManager.shared.string(for: .typesafeKey), !key.isEmpty else {
                    throw AgentError.transport("Add a TypeSafe API key to list Jev models.")
                }
                return try await JevClient.listModels(apiKey: key)
            }
            Text("Choose Agent in the AI panel composer (or type /agent and a goal) to let Luna operate the current tab. With a TypeSafe key, Jev picks each step; without one, your chat model does and also writes any typed values.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Keys saved by `/grab` and the `grab_api_key` tool. Values stay in the Keychain;
/// this list shows names and dates only, with Copy and Delete.
private struct GrabbedKeysSection: View {
    @AppStorage(SecretVault.autoClearKey) private var autoClear = false
    @State private var items: [SecretVault.Item] = []
    @State private var copied: String?

    var body: some View {
        Section("API keys grabbed by Luna") {
            if items.isEmpty {
                Text("None yet. Choose Grab key in the AI panel composer and pick a service.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading) {
                        Text(item.account)
                        if let created = item.created {
                            Text(created.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if copied == item.account { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                    Button("Copy") { if SecretVault.shared.copy(account: item.account) { copied = item.account } }
                    Button("Delete", role: .destructive) {
                        SecretVault.shared.delete(account: item.account)
                        reload()
                    }
                }
            }
            Toggle("Clear the clipboard \(Int(SecretVault.autoClearSeconds)) s after copying a key", isOn: $autoClear)
            Text("Saved in Keychain Access under “\(SecretVault.defaultService)”. The agent and outside agents never see the values.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear(perform: reload)
    }

    private func reload() { items = SecretVault.shared.items() }
}

/// "Connect agents": Luna's loopback MCP server for Claude Code, Codex and other MCP clients.
private struct ConnectAgentsSection: View {
    @AppStorage(LunaMCPBridge.enabledKey) private var enabled = false
    @AppStorage(LunaMCPBridge.trustedKey) private var trusted = false
    @AppStorage(LunaMCPBridge.portKey) private var port = LunaMCPBridge.defaultPort
    @ObservedObject private var bridge = LunaMCPBridge.shared
    @State private var portText = ""
    @State private var copied: String?
    @State private var confirmRegenerate = false

    var body: some View {
        Section("Connect agents") {
            Toggle("Let agents drive Luna (MCP server)", isOn: $enabled)
                .onChange(of: enabled) { _, _ in bridge.applySettings() }
            LabeledContent("Port") {
                TextField("Port", text: $portText, prompt: Text(String(LunaMCPBridge.defaultPort)))
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(applyPort)
            }
            LabeledContent("Status") { Text(statusText).foregroundStyle(statusIsError ? .red : .secondary) }
            Toggle("Don't ask before agents act (trusted)", isOn: $trusted)
            HStack {
                Button("Copy Claude Code command") { copy(bridge.claudeCommand, "Claude Code command") }
                Button("Copy Codex config") { copy(bridge.codexConfig, "Codex config") }
                Button("Copy token export") { copy(bridge.codexTokenExport, "token export") }
            }
            HStack {
                Button("Regenerate token", role: .destructive) { confirmRegenerate = true }
                if let copied { Text("Copied \(copied).").font(.callout).foregroundStyle(.secondary) }
            }
            Text("Outside agents get the same tools as /agent: tabs, navigate, snapshot, click, type, select, scroll, read, run_task and grab_api_key. Luna listens on 127.0.0.1 only and asks before an agent navigates, types, clicks or runs a task, once per agent session. For Codex, paste the config into ~/.codex/config.toml and set LUNA_MCP_TOKEN with the token export.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { portText = String(port) }
        .confirmationDialog("Regenerate the token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) {
                bridge.regenerateToken()
                copied = nil
            }
        } message: {
            Text("Connected agents stop working until you give them the new token.")
        }
    }

    private var statusText: String {
        switch bridge.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .running(let p): return "Listening on http://127.0.0.1:\(p)/mcp"
        case .failed(let message): return message
        }
    }

    private var statusIsError: Bool {
        if case .failed = bridge.status { return true }
        return false
    }

    private func applyPort() {
        guard let value = Int(portText.trimmingCharacters(in: .whitespaces)), (1024...65535).contains(value) else {
            portText = String(port)
            return
        }
        port = value
        if enabled { bridge.applySettings() }
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }
}

// MARK: - Shared rows

/// Secure field that saves to the Keychain; shows a masked state once stored.
private struct APIKeyField: View {
    let account: KeychainManager.Account
    let placeholder: String

    @State private var input = ""
    @State private var hasKey = false
    @State private var status: String?

    var body: some View {
        Group {
            if hasKey {
                LabeledContent("API key") {
                    HStack {
                        Text("Saved in Keychain").foregroundStyle(.secondary)
                        Button("Remove", role: .destructive) {
                            try? KeychainManager.shared.delete(account)
                            hasKey = false
                        }
                    }
                }
            } else {
                HStack {
                    SecureField("API key", text: $input, prompt: Text(placeholder))
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
            if let status { Text(status).font(.callout).foregroundStyle(.red) }
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
        HStack {
            LunaPicker("Model", selection: $selection,
                       options: (selection.isEmpty ? [.init("", "Choose a model")] : [])
                           + options.map { .init($0.id, $0.name) })
            Button {
                Task { await refresh() }
            } label: {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .help("Refresh models")
            .disabled(loading)
        }
        .task { await refresh() }
        if let error {
            Text(error).font(.callout).foregroundStyle(.secondary)
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

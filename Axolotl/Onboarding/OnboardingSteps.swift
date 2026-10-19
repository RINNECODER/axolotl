import SwiftUI
import UniformTypeIdentifiers

// The welcome flow's screens. Each is a set of Form sections that reuses Settings' controls, so a
// choice here applies at once and matches what Settings shows afterwards.

// MARK: 1. Welcome + default browser

struct OnboardingWelcomeStep: View {
    var body: some View {
        DefaultBrowserSection()
        Section {
            Label("Everything you choose here applies right away and can be changed later in Settings.",
                  systemImage: "slider.horizontal.3")
            Label("Press Esc to skip setup at any time.", systemImage: "escape")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

// MARK: 2. Import

struct OnboardingImportStep: View {
    @StateObject private var model = BrowserImportModel()
    @State private var pickingCSV = false
    @State private var passwordStatus: String?
    private let profileId = ProfileManager.shared.lastActiveProfileId

    var body: some View {
        Section {
            BrowserCardGrid(browsers: model.browsers, selected: model.onePasswordSelected ? nil : model.selectedKind,
                            onePasswordSelected: model.onePasswordSelected,
                            onSelect: { model.select($0) },
                            onSelectOnePassword: { model.select(nil); model.onePasswordSelected = true })
            if model.browsers.isEmpty {
                Text("No other browsers found. You can import a bookmarks file later from File → Import from Browser….")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Import from")
        }
        .onAppear { model.detect() }

        if model.onePasswordSelected {
            OnePasswordImportSection(axolotlProfileId: model.targetProfile(profileId), isFixtureMode: model.isFixtureMode)
        } else if let browser = model.selected {
            Section {
                HStack {
                    Button(model.hasAccess(browser) ? "Import" : "Allow Access…") {
                        importBookmarksAndHistory(browser)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.running)
                    if model.running { ProgressView().controlSize(.small).padding(.leading, 6) }
                    Spacer()
                }
                if let summary = model.summary {
                    Label(summary, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                if let error = model.error {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text(browser.kind.displayName)
            } footer: {
                Text("More options (profiles, keep in sync, bookmarks files) are in File → Import from Browser….")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text(browser.kind.passwordExportSteps).font(.callout).foregroundStyle(.secondary)
                Button("Choose Passwords CSV…") { pickingCSV = true }
                if let passwordStatus { Text(passwordStatus).font(.callout) }
            } header: {
                Text("Passwords")
            } footer: {
                Text("Delete the CSV after importing; it isn't encrypted.").foregroundStyle(.secondary)
            }
            .fileImporter(isPresented: $pickingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                guard case .success(let url) = result else { return }
                let target = model.targetProfile(profileId)
                Task { if let status = await BrowserImportView.importPasswordsCSV(url, into: target) { passwordStatus = status } }
            }
        }
    }

    /// One click: ask for folder access if needed, then import bookmarks and history.
    private func importBookmarksAndHistory(_ browser: DetectedBrowser) {
        model.types = browser.kind == .safari ? [.bookmarks] : [.bookmarks, .history]
        if !model.hasAccess(browser) {
            model.requestAccess()
            guard let refreshed = model.selected, model.hasAccess(refreshed) else { return }
        }
        model.runImport(into: profileId)
    }
}

// MARK: 3. AI

struct OnboardingAIStep: View {
    var body: some View {
        AIProviderSections()
        Section {
            APIKeyField(account: .typesafeKey, placeholder: "API key")
        } header: {
            Text("Computer use (Jev) — optional")
        } footer: {
            Text("With a TypeSafe key, Jev picks each step when Axolotl operates a tab for you. Without one, your chat model does.")
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: 4. Look

struct OnboardingLookStep: View {
    var body: some View {
        Section {
            LayoutTemplatePicker(source: "Welcome")
        } header: {
            Text("Layout")
        } footer: {
            Text("Undo it any time in Agents → Recent AI changes, or fine-tune it in Settings → Appearance.")
                .foregroundStyle(.secondary)
        }
        Section {
            LiquidGlassToggle()
        } header: {
            Text("Surfaces")
        }
        WallpaperSettingsSection()
    }
}

/// The Liquid Glass setting, applied through the Customizer so it's recorded and undoable.
struct LiquidGlassToggle: View {
    @AppStorage(LiquidGlass.defaultsKey) private var glassOn = LiquidGlass.defaultValue
    @State private var error: String?
    private let setting = RegistrySettings.setting("appearance.liquidGlass")

    var body: some View {
        Toggle(isOn: Binding(get: { glassOn }, set: apply)) {
            Text(setting.title)
            if let help = setting.help { Text(help) }
        }
        if let error { Text(error).font(.callout).foregroundStyle(.red) }
    }

    private func apply(_ on: Bool) {
        do {
            let plan = CustomizationPlan(settings: [SettingChange(key: setting.key, value: .bool(on))])
            _ = try Customizer.shared.apply(plan, context: nil, source: "Welcome")
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: 5. Privacy

struct OnboardingPrivacyStep: View {
    @AppStorage(PersonalizationPrefs.enabledKey) private var personalization = false
    @State private var iCloudSync = false
    @State private var status: String?
    private let profileId = ProfileManager.shared.lastActiveProfileId

    var body: some View {
        Section {
            Toggle(isOn: $personalization) {
                Text("Keep a usage record")
                Text("Counts the Axolotl features and shortcuts you use each day so your AI agent can set Axolotl up the way you use it.")
            }
        } header: {
            Text("Personalization")
        } footer: {
            Text("Off by default. It stays on this Mac — nothing is uploaded — and you can view or delete it in Settings → Privacy & Data.")
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle(isOn: Binding(get: { iCloudSync }, set: setICloudSync)) {
                Text("Sync passwords with iCloud Keychain")
                Text("Logins Axolotl saves sync to your other Macs signed in to the same Apple Account.")
            }
            if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Passwords")
        }
        .onAppear { iCloudSync = PasswordVault.shared.isICloudSyncEnabled(profile: profileId) }
    }

    private func setICloudSync(_ enabled: Bool) {
        do {
            try PasswordVault.shared.setICloudSync(enabled, profile: profileId)
            status = enabled ? "Logins now sync with iCloud Keychain." : "Logins now stay on this Mac."
        } catch {
            status = "Couldn't move every login: \(error.localizedDescription)"
        }
        iCloudSync = PasswordVault.shared.isICloudSyncEnabled(profile: profileId)
    }
}

// MARK: 6. Dev mode (Axolotl Dev only)

struct OnboardingDevStep: View {
    @State private var harnesses: [HarnessInfo] = []
    @State private var scanning = true

    var body: some View {
        Section {
            if harnesses.isEmpty {
                HStack(spacing: 8) {
                    if scanning { ProgressView().controlSize(.small) }
                    Text(scanning ? "Looking for coding-agent CLIs…" : "No coding-agent CLIs found on your PATH.")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(harnesses) { h in
                HStack(spacing: 10) {
                    Image(systemName: h.id.agentKind.map(DevPanelView.providerIcon) ?? "shippingbox")
                        .foregroundStyle(h.id.agentKind.map(DevPanelView.providerColor) ?? .secondary)
                        .frame(width: 18)
                    Text(h.name)
                    if let version = h.version {
                        Text(version).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Spacer()
                    Text(statusText(h)).font(.caption).foregroundStyle(statusColor(h))
                }
            }
        } header: {
            Text("Detected harnesses")
        } footer: {
            Text("Dev mode runs these CLIs on this Mac with your own login. Configure them in Settings → Developer.")
                .foregroundStyle(.secondary)
        }
        .task {
            harnesses = await HarnessCatalog.shared.discover(refresh: false)
            scanning = false
        }

        ConnectAgentsSection()
    }

    private func statusText(_ h: HarnessInfo) -> String {
        if !h.supported { return "Not supported yet" }
        switch h.signedIn {
        case true: return "Signed in"
        case false: return "Sign in in terminal"
        default: return "Status unknown"
        }
    }

    private func statusColor(_ h: HarnessInfo) -> Color {
        guard h.supported else { return .secondary }
        switch h.signedIn {
        case true: return .green
        case false: return .orange
        default: return .secondary
        }
    }
}

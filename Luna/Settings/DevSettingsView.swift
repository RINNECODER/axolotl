import AppKit
import SwiftUI

/// Settings → Dev (Luna Dev build only): the coding-agent harnesses Dev mode finds on this Mac and
/// how new Dev sessions start.
struct DevSettingsView: View {
    @State private var settings = DevSettings.shared
    @State private var harnesses: [HarnessInfo] = []
    @State private var scanning = false
    @State private var listings: [HarnessID: ModelListing] = [:]
    @State private var openDropdown: String?
    @State private var pathError: String?
    @Environment(\.colorScheme) private var scheme

    private var p: DevPalette { .of(scheme) }
    private var supported: [AgentCLIKind] { AgentCLIKind.allCases }

    var body: some View {
        Form {
            Section {
                if harnesses.isEmpty {
                    HStack(spacing: 8) {
                        if scanning { ProgressView().controlSize(.small) }
                        Text(scanning ? "Looking for coding-agent CLIs…" : "No coding-agent CLIs found on your PATH.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(harnesses) { harnessRow($0) }
                if let pathError {
                    Text(pathError).font(.callout).foregroundStyle(.red)
                }
            } header: {
                HStack {
                    Text("Harnesses")
                    Spacer()
                    Button {
                        Task { await scan(refresh: true) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(scanning)
                }
            } footer: {
                Text("Dev mode runs these CLIs on this Mac with your own login. Unsupported harnesses are listed so you know Luna found them.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Accent") {
                    HStack(spacing: 8) {
                        ForEach(DevAccent.allCases, id: \.self) { accent in
                            accentSwatch(accent)
                        }
                    }
                }
                Picker("Density", selection: $settings.density) {
                    ForEach(DevDensity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Text size", selection: $settings.fontScale) {
                    ForEach(DevFontScale.allCases, id: \.self) { scale in
                        Text(scale == .small ? "S" : scale == .medium ? "M" : "L").tag(scale)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Timeline style", selection: $settings.timelineStyle) {
                    ForEach(DevTimelineStyle.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $settings.showToolDetails) {
                    Text("Show tool details")
                    Text("Show tool inputs and outputs in work rows.")
                }
            } header: {
                Text("Appearance")
            }

            Section {
                if settings.projectSearchRoots.isEmpty {
                    Text("No search folders added.").foregroundStyle(.secondary)
                }
                ForEach(settings.projectSearchRoots, id: \.self) { root in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((root as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).help(root)
                        Spacer()
                        Button {
                            settings.projectSearchRoots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop searching this folder")
                        .accessibilityLabel("Remove \((root as NSString).abbreviatingWithTildeInPath)")
                    }
                }
                HStack(spacing: 8) {
                    Button("Add folder…") {
                        for path in pickFolders(multiple: true) { addSearchRoot(path) }
                    }
                    ForEach(suggestedRoots, id: \.self) { root in
                        Button("+ " + (root as NSString).abbreviatingWithTildeInPath) { addSearchRoot(root) }
                            .controlSize(.small)
                    }
                }
                Text("Projects come from your Claude Code and Codex sessions. Add folders to also find git repos in them.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.hiddenProjects.isEmpty {
                    Text("No hidden projects. Hide one from the project menu.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    LabeledContent("Hidden projects") { EmptyView() }
                    ForEach(settings.hiddenProjects.sorted(), id: \.self) { path in
                        HStack {
                            Text((path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle).help(path)
                            Spacer()
                            Button("Unhide") { settings.unhideProject(path) }.controlSize(.small)
                        }
                    }
                }
            } header: {
                Text("Projects")
            }

            Section {
                Toggle(isOn: $settings.skipHome) {
                    Text("Skip home")
                    Text("Open Dev straight into your last session, or a new one with the default setup.")
                }
                LabeledContent("Harness") {
                    dropdown(id: "setup-harness", items: installedHarnessItems,
                             selected: settings.defaultSetup.harness.harnessID.rawValue,
                             label: settings.defaultSetup.harness.displayName) { item in
                        if let kind = HarnessID(rawValue: item.id)?.agentKind {
                            settings.defaultSetup.harness = kind
                            settings.defaultSetup.model = nil
                            settings.defaultSetup.effort = nil
                            settings.defaultHarness = kind
                        }
                    }
                }
                LabeledContent("Model") { setupModelDropdown }
                if let efforts = setupEfforts {
                    LabeledContent("Effort") {
                        dropdown(id: "setup-effort",
                                 items: [DevDropdownItem(id: "", title: "Default")]
                                    + efforts.map { DevDropdownItem(id: $0, title: $0.capitalized) },
                                 selected: settings.defaultSetup.effort ?? "",
                                 label: settings.defaultSetup.effort?.capitalized ?? "Default") { item in
                            settings.defaultSetup.effort = item.id.isEmpty ? nil : item.id
                        }
                    }
                }
                Picker("Approval", selection: $settings.defaultSetup.approvalBehavior) {
                    ForEach(DevApprovalBehavior.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Project") {
                    HStack(spacing: 8) {
                        Picker("Project", selection: specificProjectBinding) {
                            Text("Last used").tag(false)
                            Text("Specific folder").tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                        if case .specific(let path) = settings.defaultSetup.project {
                            Button((path as NSString).abbreviatingWithTildeInPath) {
                                if let chosen = pickFolders(multiple: false).first {
                                    settings.defaultSetup.project = .specific(chosen)
                                }
                            }
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 220).help(path)
                        }
                    }
                }
            } header: {
                Text("Home & default setup")
            }

            Section {
                ForEach(supported, id: \.self) { kind in
                    LabeledContent {
                        modelDropdown(kind)
                    } label: {
                        Text("Default \(kind.displayName) model")
                        Text(modelCaption(kind))
                    }
                }
            } header: {
                Text("Default model per harness")
            }

            Section {
                Picker(selection: $settings.approvalBehavior) {
                    ForEach(DevApprovalBehavior.allCases, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                } label: {
                    Text("Approvals")
                    Text(approvalCaption)
                }
                .pickerStyle(.segmented)
                if settings.approvalBehavior == .fullAuto {
                    Label {
                        Text("Full auto runs every command and edit without asking: Claude Code uses bypassPermissions and Codex runs with no sandbox (danger-full-access). Only use it in projects you can afford to lose.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.callout)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    .accessibilityLabel("Warning: Full auto runs commands and edits without asking.")
                }
                Toggle(isOn: $settings.autoWireBrowserTools) {
                    Text("Luna browser tools")
                    Text("Let sessions read and drive your tabs through Luna's MCP bridge, when it is on.")
                }
                Toggle(isOn: $settings.showTerminalByDefault) {
                    Text("Open in Terminal view")
                    Text("Show the raw CLI instead of the chat when Luna opens the Dev panel.")
                }
            } header: {
                Text("Behavior")
            }

            Section {
                Toggle(isOn: $settings.liveSyncEnabled) {
                    Text("Live session sync")
                    Text("Lists the Claude Code and Codex sessions you started in a terminal for the same project. A session that a terminal is still writing opens read-only, as a mirror; Take over continues it in Luna. If both keep writing, their histories diverge.")
                }
            } header: {
                Text("Experimental")
            }
        }
        .formStyle(.grouped)
        .tint(p.primary)
        .task { await scan(refresh: false) }
    }

    // MARK: Appearance / projects / default setup helpers

    private func accentSwatch(_ accent: DevAccent) -> some View {
        let c = accent.colors
        let selected = settings.accent == accent
        return Button {
            settings.accent = accent
        } label: {
            Circle()
                .fill(scheme == .dark ? c.dark : c.light)
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.8) : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(accent.displayName)
        .accessibilityLabel(accent.displayName)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var suggestedRoots: [String] {
        DevSettings.suggestedProjectSearchRoots.filter { !settings.projectSearchRoots.contains($0) }
    }

    private func addSearchRoot(_ path: String) {
        let std = (path as NSString).standardizingPath
        if !settings.projectSearchRoots.contains(std) { settings.projectSearchRoots.append(std) }
    }

    private func pickFolders(multiple: Bool) -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = multiple
        panel.prompt = "Choose"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { ($0.path as NSString).standardizingPath }
    }

    private var specificProjectBinding: Binding<Bool> {
        Binding(
            get: { if case .specific = settings.defaultSetup.project { return true } else { return false } },
            set: { wantsSpecific in
                if !wantsSpecific { settings.defaultSetup.project = .last; return }
                if let chosen = pickFolders(multiple: false).first { settings.defaultSetup.project = .specific(chosen) }
            })
    }

    private var installedHarnessItems: [DevDropdownItem] {
        let installed = harnessItems.filter { item in
            harnesses.isEmpty || harnesses.contains { $0.id.rawValue == item.id }
        }
        return installed.isEmpty ? harnessItems : installed
    }

    private var setupModels: [HarnessModel] {
        listings[settings.defaultSetup.harness.harnessID]?.models ?? []
    }

    private var setupEfforts: [String]? {
        guard let id = settings.defaultSetup.model,
              let efforts = setupModels.first(where: { $0.id == id })?.efforts, !efforts.isEmpty else { return nil }
        return efforts
    }

    private var setupModelDropdown: some View {
        let stored = settings.defaultSetup.model
        var items = [DevDropdownItem(id: "", title: "Default")]
        items += setupModels.map { DevDropdownItem(id: $0.id, title: $0.displayName, subtitle: $0.description) }
        if let stored, !setupModels.contains(where: { $0.id == stored }) {
            items.append(DevDropdownItem(id: stored, title: stored))
        }
        let label = stored.map { id in setupModels.first { $0.id == id }?.displayName ?? id } ?? "Default"
        return dropdown(id: "setup-model", items: items, selected: stored ?? "", label: label) { item in
            settings.defaultSetup.model = item.id.isEmpty ? nil : item.id
            if let efforts = setupModels.first(where: { $0.id == item.id })?.efforts,
               let e = settings.defaultSetup.effort, efforts.contains(e) { return }
            settings.defaultSetup.effort = nil
        }
    }

    // MARK: Harness rows

    private func harnessRow(_ h: HarnessInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: h.id.agentKind.map(DevPanelView.providerIcon) ?? "shippingbox")
                .foregroundStyle(h.id.agentKind.map(DevPanelView.providerColor) ?? .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(h.name)
                    if let version = h.version {
                        Text(version).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text((h.executable as NSString).abbreviatingWithTildeInPath + (h.isOverride ? " (custom)" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(h.executable)
            }
            Spacer(minLength: 8)
            status(h)
            if h.supported {
                Button(h.isOverride ? "Change…" : "Choose…") {
                    Task {
                        pathError = nil
                        if await settings.chooseCLIPath(for: h.id) != nil { await scan(refresh: true) }
                    }
                }
                .controlSize(.small)
                .help("Use a different \(h.id.executableName) executable")
                if h.isOverride {
                    Button("Reset") {
                        settings.setCLIPathOverride(nil, for: h.id)
                        Task { await scan(refresh: true) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func status(_ h: HarnessInfo) -> some View {
        if !h.supported {
            badge("Not supported yet", color: .secondary)
        } else if h.signedIn == true {
            badge("Signed in", color: .green)
        } else if h.signedIn == false {
            badge("Sign in in terminal", color: .orange)
                .help("Run `\(h.id.executableName) login` in a terminal")
        } else {
            badge("Status unknown", color: .secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: Dropdowns

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { openDropdown == id }, set: { openDropdown = $0 ? id : nil })
    }

    private func dropdown(id: String, items: [DevDropdownItem], selected: String?, label: String,
                          footnote: String? = nil, onSelect: @escaping (DevDropdownItem) -> Void) -> some View {
        DevDropdown(isOpen: binding(id), items: items, selectedID: selected, palette: p, edge: .below, width: 280,
                    footnote: footnote, presentation: .popover, onSelect: onSelect) {
            DevPickerLabel(text: label, maxTextWidth: 180, palette: p)
                .background(RoundedRectangle(cornerRadius: DevMetrics.radiusMd).strokeBorder(p.input, lineWidth: 1))
        }
        .fixedSize()
    }

    private var harnessItems: [DevDropdownItem] {
        supported.map { kind in
            let info = harnesses.first { $0.id == kind.harnessID }
            return DevDropdownItem(id: kind.harnessID.rawValue, title: kind.displayName,
                                   subtitle: info == nil && !harnesses.isEmpty ? "Not installed" : nil,
                                   detail: info?.version.map { "v" + $0 },
                                   icon: DevPanelView.providerIcon(kind), iconColor: DevPanelView.providerColor(kind))
        }
    }

    private func modelDropdown(_ kind: AgentCLIKind) -> some View {
        let listing = listings[kind.harnessID]
        let stored = settings.defaultModel(for: kind.harnessID)
        var items = [DevDropdownItem(id: "", title: "Harness default", subtitle: "Whatever \(kind.executableName) picks",
                                     section: "Default")]
        items += (listing?.models ?? []).map { m in
            DevDropdownItem(id: m.id, title: m.displayName, subtitle: m.description,
                            badge: m.isDefault ? "Default" : nil, section: "Models")
        }
        if let stored, !(listing?.models ?? []).contains(where: { $0.id == stored }) {
            items.append(DevDropdownItem(id: stored, title: stored, section: "Models"))
        }
        let label = stored.flatMap { id in listing?.models.first { $0.id == id }?.displayName ?? id } ?? "Harness default"
        var footnote: String?
        if case .lastKnown(let date)? = listing?.source { footnote = "Last known list · \(DevResumeOffer.relative(date))" }
        return dropdown(id: "model-\(kind.rawValue)", items: items, selected: stored ?? "", label: label,
                        footnote: footnote) { item in
            settings.setDefaultModel(item.id, for: kind.harnessID)
        }
    }

    private func modelCaption(_ kind: AgentCLIKind) -> String {
        guard let listing = listings[kind.harnessID] else {
            return harnesses.contains { $0.id == kind.harnessID } ? "Loading models…" : "\(kind.displayName) is not installed."
        }
        return "\(listing.models.count) models from \(kind.executableName)"
    }

    private var approvalCaption: String {
        switch settings.approvalBehavior {
        case .ask: return "Commands and file edits ask first."
        case .allowEdits: return "File edits run without asking; commands still ask."
        case .fullAuto: return "Nothing asks first."
        }
    }

    private func scan(refresh: Bool) async {
        scanning = true
        harnesses = await HarnessCatalog.shared.discover(refresh: refresh)
        scanning = false
        for kind in supported where harnesses.contains(where: { $0.id == kind.harnessID }) {
            if let listing = try? await HarnessModelCatalog.shared.listing(for: kind.harnessID, refresh: refresh) {
                listings[kind.harnessID] = listing
            }
        }
    }
}

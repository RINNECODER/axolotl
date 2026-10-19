import AppKit
import SwiftUI

/// Dev's home: a compact composer. One row of dropdowns (harness · model · project, prefilled
/// from the last-used / default setup) sits under a prompt; Return starts the session with that
/// prompt. Below it, the five newest sessions to resume and "Show all".
struct DevHomeView: View {
    @Bindable var workspace: DevWorkspace
    let palette: DevPalette
    let harnesses: [HarnessInfo]
    var onOpenFolder: () -> Void
    var onOpenSettings: () -> Void
    /// A model list to show instead of asking the harness (offscreen snapshots).
    var initialListing: ModelListing?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = DevSettings.shared
    @State private var listing: ModelListing?
    @State private var modelsLoading = false
    @State private var prompt = ""
    @State private var editorHeight: CGFloat = 40
    @State private var openDropdown: String?
    @FocusState private var promptFocused: Bool

    static let recentCount = 5

    private var p: DevPalette { palette }
    private var flow: DevHomeFlow { workspace.flow }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86) }
    private var defaults: DevSessionSetup { settings.defaultSetup }

    /// Installed harnesses Dev can drive.
    private var usable: [AgentCLIKind] {
        let kinds = harnesses.filter(\.supported).compactMap(\.id.agentKind)
        return kinds.isEmpty && harnesses.isEmpty ? AgentCLIKind.allCases : kinds
    }

    // The choices: what the user picked here, else the default setup (Settings → Dev).
    private var harness: AgentCLIKind {
        flow.harness ?? (usable.contains(defaults.harness) ? defaults.harness : usable.first ?? defaults.harness)
    }
    private var model: String? {
        flow.harness != nil ? flow.model : (harness == defaults.harness ? defaults.model : nil)
    }
    private var effort: String? {
        flow.harness != nil ? flow.effort : (harness == defaults.harness ? defaults.effort : nil)
    }
    private var project: String? { flow.project ?? defaults.projectPath().flatMap { $0.isEmpty ? nil : $0 } }

    private var recent: [ExternalSession] {
        Array(workspace.recentSessions.filter { !settings.isHidden($0.projectDir.path) }.prefix(Self.recentCount))
    }

    var body: some View {
        if workspace.showingAllSessions {
            DevAllSessionsView(workspace: workspace, palette: p)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DevMetrics.compact ? 14 : 18) {
                    HStack(spacing: 7) {
                        DevMoonMark(size: 16, palette: p)
                        Text("New session")
                            .font(LunaType.brand(size: DevMetrics.text(17), weight: .regular))
                            .foregroundStyle(p.foreground)
                    }
                    .padding(.leading, 4)
                    startCard
                    if !recent.isEmpty { recentList }
                }
                .padding(.horizontal, 16)
                .padding(.top, 36)
                .padding(.bottom, 20)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .task(id: harness) { await loadModels() }
            .onAppear { promptFocused = true }
        }
    }

    // MARK: Start card (prompt + harness · model · project)

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelTextEditor(
                text: $prompt,
                placeholder: project == nil ? "Pick a project, then ask \(harness.displayName) anything…"
                    : "Ask \(harness.displayName) anything…",
                minHeight: 40,
                isFocused: $promptFocused,
                onSubmit: start,
                reportedHeight: $editorHeight,
                accessibilityLabel: "First message to \(harness.displayName)"
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            HStack(spacing: 2) {
                harnessDropdown
                modelDropdown
                projectDropdown
                Spacer(minLength: 4)
                Button(action: start) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(p.primaryForeground)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(p.primary))
                        .opacity(canStart ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .help("Start session (↩)")
                .accessibilityLabel("Start session")
            }
            .padding(.leading, 6)
            .padding(.trailing, 7)
            .padding(.bottom, 7)
            .padding(.top, 2)
        }
        .background(RoundedRectangle(cornerRadius: DevMetrics.radius2xl + 4, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: DevMetrics.radius2xl + 4, style: .continuous)
            .strokeBorder(promptFocused ? p.primary.opacity(0.45) : p.composerOutline, lineWidth: 1))
        .shadow(color: (p.isDark ? Color.black : p.primary).opacity(p.isDark ? 0.3 : 0.07), radius: 16, y: 6)
        .zIndex(1)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { openDropdown == id }, set: { openDropdown = $0 ? id : nil })
    }

    private var harnessDropdown: some View {
        let items = usable.map { kind in
            let info = harnesses.first { $0.id == kind.harnessID }
            return DevDropdownItem(id: kind.rawValue, title: kind.displayName,
                                   subtitle: info?.signedIn == false ? "Signed out. Run `\(kind.executableName) login`" : nil,
                                   detail: info?.version.map { "v" + $0 },
                                   icon: DevPanelView.providerIcon(kind), iconColor: DevPanelView.providerColor(kind),
                                   section: "Harnesses")
        }
        return DevDropdown(isOpen: binding("harness"), items: items, selectedID: harness.rawValue, palette: p,
                           edge: .below, width: 260, help: "Harness", onSelect: { item in
            if let kind = AgentCLIKind(rawValue: item.id) { workspace.flow.choose(harness: kind) }
        }) {
            DevPickerLabel(icon: DevPanelView.providerIcon(harness), iconColor: DevPanelView.providerColor(harness),
                           text: harness.displayName, palette: p)
        }
        .fixedSize()
        .accessibilityLabel("Harness: \(harness.displayName)")
    }

    private var models: [HarnessModel] {
        guard listing?.harness == harness.harnessID else { return [] }
        return listing?.models ?? []
    }

    private var modelDropdown: some View {
        let current = model.flatMap { id in models.first { $0.id == id } } ?? (model == nil ? models.first { $0.isDefault } : nil)
        let label = DevPanelView.shortModelName(current?.displayName ?? model.map(DevSessionRow.shortModel)
                                                ?? (modelsLoading ? "Loading…" : "Default"))
        var items = models.map { m in
            DevDropdownItem(id: m.id, title: m.displayName, subtitle: m.description,
                            badge: m.isDefault ? "Default" : nil, section: harness.displayName + " models",
                            keywords: [m.id, m.resolvedModel ?? ""])
        }
        if let model, !models.contains(where: { $0.id == model }) {
            items.insert(DevDropdownItem(id: model, title: model, subtitle: "Not in the harness's list", section: "Current"), at: 0)
        }
        return DevDropdown(isOpen: binding("model"), items: items, selectedID: current?.id ?? model, palette: p,
                           edge: .below, width: 300,
                           footnote: items.isEmpty ? (modelsLoading ? "Asking \(harness.executableName) for its models…" : "Uses the harness's default model.") : nil,
                           help: "Model", onSelect: { item in
            if flow.harness == nil { workspace.flow.choose(harness: harness) }
            workspace.flow.chooseModel(item.id, effort: nil)
        }) {
            DevPickerLabel(text: label, maxTextWidth: 130, palette: p)
        }
        .fixedSize()
        .accessibilityLabel("Model: \(label)")
    }

    private var projectDropdown: some View {
        let name = project.map { ($0 as NSString).lastPathComponent } ?? "Choose project"
        return DevDropdown(isOpen: binding("project"), items: Self.projectItems(workspace.projects, includeOpen: true, current: project),
                           selectedID: project, palette: p, edge: .below, width: 300, help: project ?? "Project",
                           onSelect: { item in
            switch item.id {
            case "__open": onOpenFolder()
            case "__hide": if let project { workspace.hide(project: project) }
            default: workspace.flow.choose(project: item.id)
            }
        }) {
            DevPickerLabel(icon: "folder", text: name, maxTextWidth: 150, palette: p)
        }
        .fixedSize()
        .accessibilityLabel("Project: \(name)")
    }

    private var canStart: Bool {
        project != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// One step: the typed prompt starts a session with the row's choices.
    private func start() {
        guard let project else { openDropdown = "project"; return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var setup = defaults
        setup.harness = harness
        setup.model = model
        setup.effort = effort
        setup.project = .specific(project)
        workspace.startNew(harness: harness, projectDir: URL(fileURLWithPath: project, isDirectory: true), setup: setup)
        _ = workspace.session?.send(text)
        prompt = ""
    }

    // MARK: Recent

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Recent")
                    .font(.system(size: DevMetrics.text2xs, weight: .medium))
                    .foregroundStyle(p.mutedForeground)
                Spacer()
                Button { withAnimation(motion) { workspace.showingAllSessions = true } } label: {
                    Text("Show all")
                        .font(.system(size: DevMetrics.text2xs, weight: .medium))
                        .padding(.horizontal, 6)
                        .frame(height: 20)
                }
                .buttonStyle(DevGhostButtonStyle(palette: p, radius: 10))
            }
            .padding(.leading, 8)
            .padding(.bottom, 2)
            ForEach(recent) { s in
                DevSessionRow(session: s, palette: p) { workspace.open(s) }
            }
        }
    }

    private func loadModels() async {
        if let initialListing { listing = initialListing; return }
        modelsLoading = true
        defer { modelsLoading = false }
        listing = try? await HarnessModelCatalog.shared.listing(for: harness.harnessID, refresh: false)
    }

    /// Projects as dropdown items (header picker and the home project picker).
    static func projectItems(_ projects: [DevProject], includeOpen: Bool, current: String? = nil) -> [DevDropdownItem] {
        var items = projects.map { project in
            DevDropdownItem(id: project.path, title: project.name,
                            subtitle: [project.branch, project.lastActivity.map { DevRelativeTime.string($0) }]
                                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
                                ?? (project.path as NSString).abbreviatingWithTildeInPath,
                            detail: project.sessionCount > 0 ? "\(project.sessionCount)" : nil,
                            icon: project.isGitRepo ? "arrow.triangle.branch" : "folder",
                            section: "Projects", keywords: [project.path] + project.harnesses.map(\.displayName))
        }
        if includeOpen {
            items.append(DevDropdownItem(id: "__open", title: "Open folder…", icon: "folder.badge.plus", role: .action))
            if let current, projects.contains(where: { $0.path == current }) {
                items.append(DevDropdownItem(id: "__hide", title: "Hide \((current as NSString).lastPathComponent) from list",
                                             icon: "eye.slash", role: .action))
            }
        }
        return items
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Sessions

/// A harness mark in a tinted circle.
struct DevHarnessBadge: View {
    let kind: AgentCLIKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: DevPanelView.providerIcon(kind))
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(DevPanelView.providerColor(kind))
            .frame(width: size, height: size)
            .background(Circle().fill(DevPanelView.providerColor(kind).opacity(0.14)))
            .accessibilityHidden(true)
    }
}

/// A session: harness badge, title, "12m ago · haiku · project", and where it is live.
struct DevSessionRow: View {
    let session: ExternalSession
    let palette: DevPalette
    var showsProject = true
    let action: () -> Void

    private var p: DevPalette { palette }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                DevHarnessBadge(kind: session.harness, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title.isEmpty ? "Untitled session" : session.title)
                        .font(.system(size: DevMetrics.text(12.5), weight: .medium))
                        .foregroundStyle(p.foreground)
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: DevMetrics.text2xs))
                        .foregroundStyle(p.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let live = Self.liveText(session.liveLocation) {
                    HStack(spacing: 5) {
                        PulsingDot(color: p.success)
                        Text(live)
                    }
                    .font(.system(size: DevMetrics.text(10), weight: .medium))
                    .foregroundStyle(p.success)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(p.success.opacity(0.1)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, DevMetrics.compact ? 5 : 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(DevGhostButtonStyle(palette: p, radius: DevMetrics.radiusMd))
        .onKeyPress(.return) { action(); return .handled }
        .help(session.liveLocation == nil ? "Resume this session" : "Open this live session")
        .accessibilityLabel([session.title, session.harness.displayName, Self.liveText(session.liveLocation).map { "live in " + $0 }]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private var caption: String {
        var parts = [DevRelativeTime.string(session.updatedAt)]
        if let model = session.model, !model.isEmpty { parts.append(Self.shortModel(model)) }
        if showsProject { parts.append(session.projectDir.lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    /// "claude-haiku-4-5-20251001" → "haiku-4-5".
    static func shortModel(_ id: String) -> String {
        var s = id.replacingOccurrences(of: "claude-", with: "")
        if let r = s.range(of: #"-\d{8}$"#, options: .regularExpression) { s.removeSubrange(r) }
        return s
    }

    static func liveText(_ location: SessionLocation?) -> String? {
        switch location {
        case .luna: return "Luna"
        case .externalTerminal(let pid): return pid.map { "Terminal \($0)" } ?? "Terminal"
        case nil: return nil
        }
    }
}

/// Every recent session across projects, newest first, with a search field.
struct DevAllSessionsView: View {
    @Bindable var workspace: DevWorkspace
    let palette: DevPalette
    @State private var query = ""

    private var p: DevPalette { palette }

    private var shown: [ExternalSession] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        return workspace.recentSessions.filter { s in
            let hay = "\(s.title) \(s.projectDir.lastPathComponent) \(s.harness.displayName) \(s.model ?? "")".lowercased()
            return words.allSatisfy(hay.contains)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { withAnimation(.smooth(duration: 0.2)) { workspace.showingAllSessions = false } } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(DevGhostButtonStyle(palette: p, radius: 12))
                .keyboardShortcut(.escape, modifiers: [])
                .accessibilityLabel("Back")
                Text("All sessions")
                    .font(LunaType.brand(size: DevMetrics.text(15)))
                    .foregroundStyle(p.foreground)
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(p.mutedForeground)
                    TextField("Search", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: DevMetrics.textXs))
                        .frame(width: 120)
                }
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(Capsule().fill(p.accent))
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            Rectangle().fill(p.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !workspace.recentLoaded {
                        ForEach(0..<6, id: \.self) { _ in skeletonRow }
                    } else if shown.isEmpty {
                        Text(query.isEmpty ? "No sessions yet." : "No matches")
                            .font(.system(size: DevMetrics.textXs))
                            .foregroundStyle(p.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(24)
                    } else {
                        ForEach(shown) { s in DevSessionRow(session: s, palette: p) { workspace.open(s) } }
                    }
                }
                .padding(6)
            }
        }
        .task { await workspace.loadRecentSessions() }
    }

    private var skeletonRow: some View {
        HStack(spacing: 9) {
            Circle().fill(p.accent).frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(p.accent).frame(width: 180, height: 9)
                Capsule().fill(p.accent.opacity(0.7)).frame(width: 110, height: 7)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }
}

import AppKit
import SwiftUI

/// Dev's home: entering Dev shows this instead of an empty chat. Centered "bubbles" choose,
/// one step at a time, the project, the harness, the model / effort, then a recent session or
/// "New session" (`DevHomeFlow`). A "Continue last" bubble jumps straight back in.
struct DevHomeView: View {
    @Bindable var workspace: DevWorkspace
    let palette: DevPalette
    let harnesses: [HarnessInfo]
    var onOpenFolder: () -> Void
    var onOpenSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settings = DevSettings.shared
    @State private var listing: ModelListing?
    @State private var modelsLoading = false
    @State private var pickedModel: String?
    @State private var pickedEffort: String?
    @State private var projectSearchOpen = false

    private var p: DevPalette { palette }
    private var flow: DevHomeFlow { workspace.flow }
    private var motion: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86) }

    /// Installed harnesses Dev can drive.
    private var usable: [AgentCLIKind] {
        let kinds = harnesses.filter(\.supported).compactMap(\.id.agentKind)
        return kinds.isEmpty && harnesses.isEmpty ? AgentCLIKind.allCases : kinds
    }

    var body: some View {
        if workspace.showingAllSessions {
            DevAllSessionsView(workspace: workspace, palette: p)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        } else {
            ScrollView {
                VStack(spacing: DevMetrics.compact ? 14 : 18) {
                    heading
                    if !trail.isEmpty { trailView }
                    stepContent
                        .id(flow.step)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                                removal: .opacity))
                    if flow.step == .project, let last = workspace.continueLast { continueBubble(last) }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
            .animation(motion, value: flow)
            .task(id: flow.harness) { await loadModels() }
            .task(id: flow.project) {
                if let path = flow.project { await workspace.loadSessions(project: path) }
            }
        }
    }

    // MARK: Heading

    private var heading: some View {
        VStack(spacing: 8) {
            DevMoonMark(size: 22, palette: p)
            Text(title)
                .font(LunaType.brand(size: DevMetrics.text(21), weight: .regular))
                .foregroundStyle(p.foreground)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Text(subtitle)
                .font(.system(size: DevMetrics.textXs))
                .foregroundStyle(p.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch flow.step {
        case .project: return "What are we building tonight?"
        case .harness: return "Who should write the code?"
        case .model: return "Pick a model"
        case .session: return "Pick up a session, or start fresh"
        }
    }

    private var subtitle: String {
        switch flow.step {
        case .project: return "Projects come from your Claude Code and Codex sessions."
        case .harness: return "Your own CLI and login, on this Mac."
        case .model: return "Fixed per session. Effort applies where the model supports it."
        case .session: return settings.approvalBehavior == .fullAuto ? "Full auto: commands and edits run without asking."
            : "The Terminal tab opens the same session."
        }
    }

    // MARK: Breadcrumb trail (chosen steps; click to change)

    private var trail: [(DevHomeFlow.Step, String, String?)] {
        var out: [(DevHomeFlow.Step, String, String?)] = []
        if let path = flow.project { out.append((.project, (path as NSString).lastPathComponent, "folder")) }
        if let h = flow.harness { out.append((.harness, h.displayName, DevPanelView.providerIcon(h))) }
        if flow.step == .session {
            let name = flow.model.flatMap { id in listing?.models.first { $0.id == id }?.displayName } ?? flow.model ?? "Default model"
            let effort = flow.effort.map { " · " + DevPanelView.effortName($0) } ?? ""
            out.append((.model, DevPanelView.shortModelName(name) + effort, "cpu"))
        }
        return out
    }

    private var trailView: some View {
        HStack(spacing: 4) {
            ForEach(Array(trail.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(p.mutedForeground.opacity(0.6))
                }
                Button { withAnimation(motion) { workspace.flow.edit(entry.0) } } label: {
                    HStack(spacing: 5) {
                        if let icon = entry.2 { Image(systemName: icon).font(.system(size: 10, weight: .medium)) }
                        Text(entry.1).lineLimit(1)
                    }
                    .font(.system(size: DevMetrics.text2xs, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Capsule().fill(p.primarySoft))
                    .foregroundStyle(p.foreground.opacity(0.85))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Change \(entry.0.title.lowercased())")
                .accessibilityLabel("\(entry.0.title): \(entry.1). Change")
            }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepContent: some View {
        switch flow.step {
        case .project: projectStep
        case .harness: harnessStep
        case .model: modelStep
        case .session: sessionStep
        }
    }

    private var projectStep: some View {
        VStack(spacing: 12) {
            if !workspace.projectsLoaded {
                DevChipFlow(spacing: 8) { ForEach(0..<5, id: \.self) { i in DevSkeletonChip(width: [96, 130, 84, 112, 70][i], palette: p) } }
            } else if workspace.projects.isEmpty {
                Text("No projects found yet. Open a folder to start.")
                    .font(.system(size: DevMetrics.textXs))
                    .foregroundStyle(p.mutedForeground)
            } else {
                DevChipFlow(spacing: 8) {
                    ForEach(workspace.projects.prefix(6)) { project in
                        DevBubble(icon: project.isGitRepo ? "arrow.triangle.branch" : "folder", title: project.name,
                                  caption: projectCaption(project), badges: project.harnesses.compactMap(\.agentKind), palette: p) {
                            withAnimation(motion) { workspace.flow.choose(project: project.path) }
                        }
                        .contextMenu {
                            Button("Hide from Dev") { withAnimation(motion) { workspace.hide(project: project.path) } }
                            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.url]) }
                        }
                        .help(project.path)
                    }
                }
            }
            HStack(spacing: 8) {
                if workspace.projects.count > 6 {
                    DevDropdown(isOpen: $projectSearchOpen, items: Self.projectItems(workspace.projects, includeOpen: false),
                                selectedID: nil, palette: p, edge: .below, width: 300, help: "All projects",
                                onSelect: { item in withAnimation(motion) { workspace.flow.choose(project: item.id) } }) {
                        DevBubbleLabel(icon: "magnifyingglass", title: "All projects (\(workspace.projects.count))", palette: p, quiet: true)
                    }
                    .fixedSize()
                }
                DevBubble(icon: "folder.badge.plus", title: "Open folder…", palette: p, quiet: true, action: onOpenFolder)
            }
        }
    }

    private func projectCaption(_ project: DevProject) -> String? {
        var parts: [String] = []
        if let branch = project.branch { parts.append(branch) }
        if let date = project.lastActivity { parts.append(DevRelativeTime.string(date)) }
        if project.sessionCount > 0 { parts.append("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var harnessStep: some View {
        VStack(spacing: 10) {
            DevChipFlow(spacing: 8) {
                ForEach(usable, id: \.self) { kind in
                    let info = harnesses.first { $0.id == kind.harnessID }
                    DevBubble(icon: DevPanelView.providerIcon(kind), iconColor: DevPanelView.providerColor(kind),
                              title: kind.displayName,
                              caption: info?.signedIn == false ? "Signed out" : info?.version.map { "v" + $0 },
                              palette: p) {
                        withAnimation(motion) { workspace.flow.choose(harness: kind) }
                    }
                }
            }
            if usable.isEmpty {
                Text("Install Claude Code or Codex to use Dev.")
                    .font(.system(size: DevMetrics.textXs))
                    .foregroundStyle(p.mutedForeground)
            }
        }
    }

    private var models: [HarnessModel] {
        guard let h = flow.harness, listing?.harness == h.harnessID else { return [] }
        return listing?.models ?? []
    }

    private var modelStep: some View {
        let current = pickedModel.flatMap { id in models.first { $0.id == id } } ?? models.first { $0.isDefault }
        let efforts = current?.efforts ?? []
        return VStack(spacing: 12) {
            if models.isEmpty, modelsLoading {
                DevChipFlow(spacing: 8) { ForEach(0..<4, id: \.self) { i in DevSkeletonChip(width: [80, 64, 92, 72][i], palette: p) } }
            } else {
                DevChipFlow(spacing: 8) {
                    if models.isEmpty {
                        DevBubble(icon: "sparkle", title: "Default", palette: p, selected: true) { commitModel(nil) }
                    }
                    ForEach(models) { m in
                        DevBubble(title: DevPanelView.shortModelName(m.displayName), caption: m.isDefault && !m.displayName.lowercased().hasPrefix("default") ? "default" : nil,
                                  palette: p, selected: m.id == current?.id) {
                            withAnimation(motion) {
                                pickedModel = m.id
                                if !(m.efforts ?? []).contains(pickedEffort ?? "") { pickedEffort = nil }
                            }
                            if (m.efforts ?? []).isEmpty { commitModel(m.id) }
                        }
                    }
                }
            }
            if !efforts.isEmpty {
                VStack(spacing: 8) {
                    Text("Effort")
                        .font(.system(size: DevMetrics.text2xs, weight: .medium))
                        .foregroundStyle(p.mutedForeground)
                    DevChipFlow(spacing: 6) {
                        ForEach(efforts, id: \.self) { e in
                            DevBubble(title: DevPanelView.effortName(e), palette: p, compact: true,
                                      selected: e == (pickedEffort ?? current?.defaultEffort)) {
                                pickedEffort = e
                            }
                        }
                    }
                }
                .transition(.opacity)
                DevBubble(icon: "arrow.right", title: "Continue", palette: p, primary: true) {
                    commitModel(current?.id, effort: pickedEffort)
                }
            }
        }
    }

    private func commitModel(_ id: String?, effort: String? = nil) {
        withAnimation(motion) { workspace.flow.chooseModel(id, effort: effort) }
    }

    private var sessionStep: some View {
        let sessions = flow.project.flatMap { workspace.projectSessions[$0] }?
            .filter { $0.harness == flow.harness } ?? []
        return VStack(spacing: 12) {
            DevBubble(icon: "plus", title: "New session", palette: p, primary: true) { startNew() }
                .keyboardShortcut(.return, modifiers: [])
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent in this project")
                        .font(.system(size: DevMetrics.text2xs, weight: .medium))
                        .foregroundStyle(p.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                    ForEach(sessions.prefix(5)) { s in
                        DevSessionRow(session: s, palette: p, showsProject: false) { workspace.open(s) }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: DevMetrics.radiusLg + 4, style: .continuous).fill(p.card))
                .overlay(RoundedRectangle(cornerRadius: DevMetrics.radiusLg + 4, style: .continuous).strokeBorder(p.border))
                .frame(maxWidth: 440)
            }
            Button { withAnimation(motion) { workspace.showingAllSessions = true } } label: {
                HStack(spacing: 3) {
                    Text("All sessions")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: DevMetrics.text2xs, weight: .medium))
                .padding(.horizontal, 8)
                .frame(height: 22)
            }
            .buttonStyle(DevGhostButtonStyle(palette: p, radius: 11))
        }
    }

    private func startNew() {
        guard let project = flow.project, let setup = flow.setup(base: settings.defaultSetup) else { return }
        workspace.startNew(harness: setup.harness, projectDir: URL(fileURLWithPath: project, isDirectory: true), setup: setup)
    }

    private func continueBubble(_ s: ExternalSession) -> some View {
        Button { workspace.open(s) } label: {
            HStack(spacing: 9) {
                DevHarnessBadge(kind: s.harness, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Continue last")
                        .font(.system(size: DevMetrics.text2xs, weight: .medium))
                        .foregroundStyle(p.primary)
                    Text(s.title.isEmpty ? "Untitled session" : s.title)
                        .font(.system(size: DevMetrics.textXs, weight: .medium))
                        .foregroundStyle(p.foreground)
                        .lineLimit(1)
                }
                Text("\(s.projectDir.lastPathComponent) · \(DevRelativeTime.string(s.updatedAt))")
                    .font(.system(size: DevMetrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
                Image(systemName: "arrow.uturn.forward").font(.system(size: 10, weight: .semibold)).foregroundStyle(p.mutedForeground)
            }
            .padding(.leading, 6)
            .padding(.trailing, 12)
            .frame(height: 40)
            .background(Capsule().fill(p.card))
            .overlay(Capsule().strokeBorder(p.primary.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 440)
        .padding(.top, 6)
        .accessibilityLabel("Continue last session: \(s.title)")
    }

    private func loadModels() async {
        guard let harness = flow.harness?.harnessID else { return }
        pickedModel = flow.model
        pickedEffort = flow.effort
        modelsLoading = true
        defer { modelsLoading = false }
        listing = try? await HarnessModelCatalog.shared.listing(for: harness, refresh: false)
    }

    /// Projects as dropdown items (header picker and "All projects").
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

// MARK: - Bubbles

/// A home-view choice: a capsule with an optional icon and a caption line.
struct DevBubble: View {
    var icon: String?
    var iconColor: Color?
    let title: String
    var caption: String?
    /// Small harness marks after the title (projects: which CLIs have sessions there).
    var badges: [AgentCLIKind] = []
    let palette: DevPalette
    var quiet = false
    var compact = false
    var selected = false
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            DevBubbleLabel(icon: icon, iconColor: iconColor, title: title, caption: caption, badges: badges, palette: palette,
                           quiet: quiet, compact: compact, selected: selected, primary: primary)
        }
        .buttonStyle(DevBubblePress())
        .accessibilityLabel([title, caption].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DevBubbleLabel: View {
    var icon: String?
    var iconColor: Color?
    let title: String
    var caption: String?
    var badges: [AgentCLIKind] = []
    let palette: DevPalette
    var quiet = false
    var compact = false
    var selected = false
    var primary = false
    @State private var hovering = false

    private var p: DevPalette { palette }

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: DevMetrics.text(11), weight: .semibold))
                    .foregroundStyle(primary ? p.primaryForeground : (iconColor ?? (selected ? p.primary : p.mutedForeground)))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(.system(size: DevMetrics.text(compact ? 11.5 : 12.5), weight: .medium))
                        .foregroundStyle(primary ? p.primaryForeground : (quiet ? p.mutedForeground : p.foreground))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ForEach(badges, id: \.self) { kind in
                        Image(systemName: DevPanelView.providerIcon(kind))
                            .font(.system(size: DevMetrics.text(8), weight: .bold))
                            .foregroundStyle(DevPanelView.providerColor(kind))
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: 230, alignment: .leading)
                if let caption {
                    Text(caption)
                        .font(.system(size: DevMetrics.text(10)))
                        .foregroundStyle(primary ? p.primaryForeground.opacity(0.8) : p.mutedForeground)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, compact ? 10 : 13)
        .frame(minHeight: compact ? 26 : (caption == nil ? 32 : 40))
        .background(Capsule(style: .continuous).fill(fill))
        .overlay(Capsule(style: .continuous).strokeBorder(stroke, lineWidth: selected ? 1.5 : 1))
        .shadow(color: .black.opacity(p.isDark || quiet ? 0 : (hovering ? 0.08 : 0.04)), radius: hovering ? 6 : 3, y: 1.5)
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var fill: Color {
        if primary { return hovering ? p.primary.opacity(0.88) : p.primary }
        if selected { return p.primarySoft }
        if quiet { return hovering ? p.accent : .clear }
        return hovering ? p.accent : p.card
    }

    private var stroke: Color {
        if primary { return .clear }
        if selected { return p.primary.opacity(0.7) }
        return hovering ? p.input : p.border
    }
}

private struct DevBubblePress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct DevSkeletonChip: View {
    let width: CGFloat
    let palette: DevPalette
    @State private var on = false

    var body: some View {
        Capsule()
            .fill(palette.accent)
            .frame(width: width, height: 32)
            .opacity(on ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
            .accessibilityHidden(true)
    }
}

/// Wraps chips onto centered lines.
struct DevChipFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for index in row.items {
                let size = fit(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// Natural size, but never wider than the line, so a long chip truncates instead of overflowing.
    private func fit(_ view: LayoutSubview, width: CGFloat) -> CGSize {
        let natural = view.sizeThatFits(.unspecified)
        guard width.isFinite, natural.width > width else { return natural }
        return view.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = fit(view, width: width)
            let extra = rows[rows.count - 1].items.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            let gap: CGFloat = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(i)
            rows[rows.count - 1].width += size.width + gap
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.items.isEmpty }
    }
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

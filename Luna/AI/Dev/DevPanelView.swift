import AppKit
import SwiftUI

/// Dev mode: drive Claude Code or Codex in a project folder from the AI panel.
///
/// Inspired by T3 Code's chat (https://github.com/pingdotgg/t3code, MIT License) — its timeline
/// of user bubbles, assistant prose and folded work-log rows, approvals inside the composer —
/// with Luna's own look: the crescent mark, the serif for titles, the accent from Settings → Dev
/// → Appearance, a one-row header and a capsule composer.
///
/// Entering Dev shows `DevHomeView` (project → harness → model → session). Once a session is
/// open, Chat and Terminal both show the same `DevSession` (`DevWorkspace.shared.session`):
/// the chat timeline follows the terminal live, and chat sends go wherever the session runs
/// (`DevSession.SendRoute`). ⌘↩ sends, Esc stops.
struct DevPanelView: View {
    let fontSize: CGFloat
    var onOpenSettings: () -> Void
    /// Opens a web link in a Luna tab; falls back to the default browser when not provided.
    var onOpenLink: ((URL) -> Void)?
    /// The compact General | Dev switch, shown in the header.
    var modeSwitch: AnyView = AnyView(EmptyView())
    var onClose: () -> Void = {}

    @AppStorage(DevPrefs.agentKey) private var agentRaw: String = AgentCLIKind.claudeCode.rawValue
    @AppStorage(DevPrefs.terminalKey) private var terminalMode: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var workspace = DevWorkspace.shared
    @State private var settings = DevSettings.shared
    @State private var input = ""
    @State private var editorHeight: CGFloat = 36
    @State private var expandedGroups: Set<Int> = []
    @State private var turnStartedAt: Date?
    /// "Worked for" durations, keyed by the index of the turn's user message.
    @State private var turnDurations: [Int: TimeInterval] = [:]
    /// The open dropdown ("harness", "model", "effort", "project"), if any.
    @State private var openDropdown: String?
    @State private var harnesses: [HarnessInfo] = []
    @State private var listing: ModelListing?
    @State private var modelsLoading = false
    @State private var modelError: String?
    @State private var confirmTakeOver = false
    @Namespace private var viewSwitchNS
    @FocusState private var inputFocused: Bool

    /// New panels apply Settings → Dev defaults (terminal tab) once per launch.
    @MainActor private static var appliedLaunchDefaults = false

    private var p: DevPalette { .of(scheme, accent: settings.accent) }
    private var session: DevSession? { workspace.session }
    private var thread: DevThreadState? { session?.timeline }
    private var agent: AgentCLIKind {
        session?.harness ?? workspace.flow.harness ?? AgentCLIKind(rawValue: agentRaw) ?? .claudeCode
    }
    private var model: String { session?.setup.model ?? "" }
    private var effort: String { session?.setup.effort ?? "" }
    private var projectURL: URL? {
        session?.projectDir ?? workspace.flow.project.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    private var projectPath: String { projectURL?.path ?? "" }
    private var projectName: String? { projectURL?.lastPathComponent }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTurnActive: Bool { thread?.isTurnActive == true }
    private var models: [HarnessModel] { listing?.harness == agent.harnessID ? listing?.models ?? [] : [] }
    private var currentModel: HarnessModel? { DevComposerSelection.current(model: model, in: models) }
    private var currentEffort: String? { DevComposerSelection.effectiveEffort(effort, for: currentModel) }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.22) }
    private var scaledFont: CGFloat { fontSize * DevMetrics.scale }
    private var hasBrowserTools: Bool { settings.autoWireBrowserTools }

    private func isInstalled(_ kind: AgentCLIKind) -> Bool? {
        guard !harnesses.isEmpty else { return nil }
        return harnesses.contains { $0.id == kind.harnessID && $0.supported }
    }

    private func dropdownBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { openDropdown == id }, set: { open in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) { openDropdown = open ? id : nil }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if terminalMode {
                    terminalArea
                        .transition(.opacity)
                } else if let session {
                    VStack(spacing: 0) {
                        threadArea(session)
                        composer(session)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
                } else {
                    DevHomeView(workspace: workspace, palette: p, harnesses: harnesses,
                                onOpenFolder: chooseFolder, onOpenSettings: onOpenSettings)
                        .transition(.opacity)
                }
            }
            .animation(motion, value: terminalMode)
            .animation(motion, value: session?.id)
        }
        .background(p.background)
        .devDropdownHost()
        .onAppear {
            applyLaunchDefaults()
            if isTurnActive, turnStartedAt == nil { turnStartedAt = Date() }
            #if DEBUG
            snapshotHooks()
            #endif
        }
        .task {
            harnesses = await HarnessCatalog.shared.discover()
            let installed = Set(harnesses.filter(\.supported).compactMap(\.id.agentKind))
            await workspace.launchIfNeeded(installed: installed)
        }
        .task {
            await workspace.loadProjects()
            await workspace.loadRecentSessions()
        }
        .task(id: agent) { await loadModels(refresh: false) }
        .onChange(of: terminalMode) { _, _ in openDropdown = nil }
        .task(id: "\(terminalMode)|\(session?.id.uuidString ?? "")|\(workspace.flow.project ?? "")|\(session?.state == .idle)") {
            if terminalMode { workspace.prepareTerminalTab() }
        }
        .onChange(of: session?.id) { _, _ in
            input = ""
            expandedGroups = []
            turnDurations = [:]
        }
        .onChange(of: isTurnActive) { _, active in
            if active {
                turnStartedAt = Date()
            } else if let start = turnStartedAt, let thread,
                      let userIndex = thread.items.lastIndex(where: { if case .user = $0 { return true }; return false }) {
                turnDurations[userIndex] = Date().timeIntervalSince(start)
                turnStartedAt = nil
            }
        }
    }

    private func applyLaunchDefaults() {
        guard !Self.appliedLaunchDefaults else { return }
        Self.appliedLaunchDefaults = true
        if settings.showTerminalByDefault, session != nil { terminalMode = true }
        // The home view starts on Chat (its Terminal tab is a plain shell).
        if session == nil, !settings.skipHome { terminalMode = false }
    }

    #if DEBUG
    private func snapshotHooks() {
        let env = ProcessInfo.processInfo.environment
        // Screenshots: approve the first pending request after the given delay.
        if let delay = env["LUNA_SNAPSHOT_DEV_ALLOW"].flatMap(Double.init) {
            Task {
                for _ in 0..<120 {
                    try? await Task.sleep(for: .seconds(delay))
                    if let pending = pendingApproval {
                        session?.respond(approvalID: pending.card.request.id, decision: .allow)
                        return
                    }
                }
            }
        }
        // Screenshots: open a dropdown ("harness", "model", "effort", "project"), the all-sessions
        // list ("sessions"), or walk the home view ("home-harness", "home-model", "home-session"
        // with LUNA_SNAPSHOT_DEV_DIR as the project).
        if let open = env["LUNA_SNAPSHOT_DEV_OPEN"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["LUNA_SNAPSHOT_DEV_OPEN_AFTER"] ?? "") ?? 2))
                let dir = env["LUNA_SNAPSHOT_DEV_DIR"]
                switch open {
                case "sessions": workspace.showingAllSessions = true
                case "home-harness":
                    if let dir { workspace.goHome(project: dir); workspace.flow.edit(.harness) }
                case "home-model":
                    if let dir { workspace.goHome(project: dir); workspace.flow.choose(harness: .claudeCode) }
                case "home-session":
                    if let dir {
                        workspace.goHome(project: dir)
                        workspace.flow.choose(harness: .claudeCode)
                        workspace.flow.chooseModel("haiku", effort: nil)
                    }
                default: openDropdown = open
                }
            }
        }
        // Screenshots: start a new Claude session in LUNA_SNAPSHOT_DEV_DIR and send a prompt
        // (LUNA_SNAPSHOT_DEV_SEND) from the Chat tab.
        if let text = env["LUNA_SNAPSHOT_DEV_SEND"], let dir = env["LUNA_SNAPSHOT_DEV_DIR"] {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                var setup = settings.defaultSetup
                setup.harness = .claudeCode
                setup.model = env["LUNA_SNAPSHOT_DEV_MODEL"] ?? "haiku"
                workspace.startNew(harness: .claudeCode, projectDir: URL(fileURLWithPath: dir, isDirectory: true), setup: setup)
                _ = workspace.session?.send(text)
            }
        }
        // Screenshots: switch to the Terminal tab after N seconds, then send a second chat message
        // (LUNA_SNAPSHOT_DEV_SEND2) M seconds later; it is typed into the running CLI.
        if let after = env["LUNA_SNAPSHOT_DEV_TERMINAL_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                terminalMode = true
                if let text = env["LUNA_SNAPSHOT_DEV_SEND2"] {
                    try? await Task.sleep(for: .seconds(Double(env["LUNA_SNAPSHOT_DEV_SEND2_AFTER"] ?? "") ?? 2))
                    _ = workspace.session?.send(text)
                }
            }
        }
        // Screenshots: answer Claude's folder-trust question ("Yes, I trust this folder" is the
        // second option) when it shows.
        if env["LUNA_SNAPSHOT_DEV_TRUST"] == "1" {
            Task {
                for _ in 0..<300 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if let term = workspace.session?.terminal, term.isShowingTrustPrompt {
                        try? await Task.sleep(for: .milliseconds(1500))
                        term.write(raw: "\u{1b}[B")
                        try? await Task.sleep(for: .milliseconds(600))
                        term.write(raw: "\r")
                        return
                    }
                }
            }
        }
        // Screenshots: back to the Chat tab after N seconds (shows the terminal's messages in chat).
        if let after = env["LUNA_SNAPSHOT_DEV_CHAT_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                terminalMode = false
            }
        }
        // Screenshots: open the newest session of LUNA_SNAPSHOT_DEV_DIR (e.g. one live elsewhere).
        if env["LUNA_SNAPSHOT_DEV_OPEN_LATEST"] == "1", let dir = env["LUNA_SNAPSHOT_DEV_DIR"] {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                await workspace.loadSessions(project: dir)
                if let s = workspace.projectSessions[dir]?.first { workspace.open(s) }
            }
        }
    }
    #endif

    // MARK: - Header (one row: crescent + project / title, Chat | Terminal, icon controls)

    private var header: some View {
        HStack(spacing: 6) {
            modeSwitch
                .fixedSize()
                .layoutPriority(2)
            Button { withAnimation(motion) { workspace.goHome() } } label: {
                DevMoonMark(size: 13, palette: p)
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(DevGhostButtonStyle(palette: p, radius: 12))
            .help("Dev home")
            .accessibilityLabel("Dev home")
            projectDropdown(id: "project", edge: .below) {
                HStack(spacing: 5) {
                    Text(projectName ?? "Project")
                        .font(.system(size: DevMetrics.text(12.5), weight: .semibold))
                        .foregroundStyle(projectName == nil ? p.mutedForeground : p.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 110)
                        .fixedSize(horizontal: true, vertical: false)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(p.mutedForeground)
                }
                .padding(.horizontal, 8)
                .frame(height: DevMetrics.controlHeight)
                .background(Capsule().fill(p.accent))
                .contentShape(Capsule())
            }
            .fixedSize()
            .layoutPriority(1)
            .accessibilityLabel("Project: \(projectName ?? "none")")
            if session != nil {
                Text(threadTitle)
                    .font(.system(size: DevMetrics.textXs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(threadTitle)
            }
            Spacer(minLength: 4)
            viewSwitch
            DevIconButton(systemName: "plus.bubble", help: "New session", palette: p) { newThread() }
            DevIconButton(systemName: "xmark", help: "Close (Esc)", palette: p) {
                // Esc stops a running turn before it closes the panel.
                if isTurnActive { session?.interrupt() } else { onClose() }
            }
            // The raw terminal needs Esc (it interrupts the CLI); an open dropdown takes it too.
            .keyboardShortcut(terminalMode || openDropdown != nil || workspace.showingAllSessions
                              ? nil : KeyboardShortcut(.escape, modifiers: []))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity)
        .frame(height: DevMetrics.compact ? 40 : 46)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    /// Chat | Terminal as a capsule toggle with a sliding accent thumb.
    private var viewSwitch: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { terminal in
                let selected = terminalMode == terminal
                Button {
                    guard terminalMode != terminal else { return }
                    withAnimation(motion) { terminalMode = terminal }
                } label: {
                    Image(systemName: terminal ? "apple.terminal" : "text.bubble")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? p.primary : p.mutedForeground)
                        .frame(width: 30, height: DevMetrics.controlHeight - 4)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(p.primarySoft)
                                    .matchedGeometryEffect(id: "viewSwitch", in: viewSwitchNS)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(terminal ? (session == nil ? "Terminal (login shell)" : "Terminal (\(agent.executableName))") : "Chat")
                .accessibilityLabel(terminal ? "Terminal" : "Chat")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .overlay(Capsule().strokeBorder(p.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private var threadTitle: String {
        if let thread {
            for item in thread.items {
                if case .user(let text) = item {
                    return text.split(separator: "\n").first.map(String.init) ?? text
                }
            }
        }
        if let id = session?.sessionID,
           let found = workspace.recentSessions.first(where: { $0.id == id }) ?? workspace.projectSessions[projectPath]?.first(where: { $0.id == id }),
           !found.title.isEmpty { return found.title }
        return "New session"
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { "-_ .".contains($0) })
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    /// Project picker: found projects (ProjectFinder), "Open folder…", and hide.
    private func projectDropdown<L: View>(id: String, edge: DevDropdownEdge, @ViewBuilder label: @escaping () -> L) -> some View {
        var projects = workspace.projects
        if projects.isEmpty {
            projects = DevPrefs.recentProjects().map {
                DevProject(path: $0, name: ($0 as NSString).lastPathComponent, lastActivity: nil, harnesses: [],
                           sessionCount: 0, isGitRepo: false, branch: nil, sources: [.lunaRecents])
            }
        }
        let items = DevHomeView.projectItems(projects, includeOpen: true, current: projectURL?.path)
        return DevDropdown(isOpen: dropdownBinding(id), items: items, selectedID: projectPath, palette: p, edge: edge,
                           width: 300, footnote: workspace.projectsLoaded ? nil : "Finding projects…", help: "Project",
                           onSelect: { item in
            switch item.id {
            case "__open": chooseFolder()
            case "__hide": if let path = projectURL?.path { workspace.hide(project: path); workspace.goHome() }
            default: selectProject(item.id)
            }
        }, label: label)
    }

    // MARK: - Terminal

    @ViewBuilder
    private var terminalArea: some View {
        if let session, isInstalled(session.harness) == false {
            terminalMessage("Install \(session.harness.executableName) to use the terminal.")
        } else if let controller = workspace.tabTerminal {
            VStack(spacing: 0) {
                DevTerminalHostView(controller: controller, isDark: p.isDark)
                    .padding(8)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: DevMetrics.radiusLg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: DevMetrics.radiusLg, style: .continuous).strokeBorder(p.border))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(session == nil ? "Shell" : "\(agent.displayName) terminal")
                HStack(spacing: 6) {
                    terminalStatus(controller)
                    Spacer(minLength: 4)
                    Text(session == nil ? "Login shell in \(projectName ?? "~")" : "Esc and arrows go to \(agent.executableName)")
                        .font(.system(size: DevMetrics.text2xs))
                        .foregroundStyle(p.mutedForeground)
                        .lineLimit(1)
                }
                .padding(.top, 6)
                .padding(.horizontal, 4)
            }
            .padding(10)
        } else if let session {
            VStack(spacing: 10) {
                if case .running(.external(let pid)) = session.state {
                    terminalMessage("Live in Terminal\(pid.map { " (pid \($0))" } ?? ""). Take over to open it here.")
                    Button("Take over") { confirmTakeOver = true }
                        .buttonStyle(DevButtonStyle(palette: p, variant: .primary))
                } else {
                    terminalMessage("\(session.harness.displayName) is answering in Chat. The terminal opens when the turn ends.")
                    Button("Stop turn") { session.interrupt() }
                        .buttonStyle(DevButtonStyle(palette: p, variant: .outline))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .takeOverConfirmation(isPresented: $confirmTakeOver) { session.takeOver() }
        }
    }

    private func terminalMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: DevMetrics.textSm))
            .foregroundStyle(p.mutedForeground)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func terminalStatus(_ controller: DevTerminalController) -> some View {
        let (text, color): (String, Color) = {
            if !controller.isRunning { return ("Exited", p.mutedForeground) }
            if controller.isShowingTrustPrompt { return ("Answer the trust question", p.warningForeground) }
            if controller.isShowingApprovalPrompt { return ("Waiting for approval", p.warningForeground) }
            if !controller.isReady { return (controller.queuedSends.isEmpty ? "Starting…" : "Starting… (\(controller.queuedSends.count) queued)", p.mutedForeground) }
            return (session == nil ? "Shell" : "Running", p.success)
        }()
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: DevMetrics.text2xs, weight: .medium))
        .foregroundStyle(color == p.success ? p.mutedForeground : color)
        .accessibilityElement(children: .combine)
        if !controller.isRunning {
            Button("Restart") {
                workspace.prepareTerminalTab(restart: true)
            }
            .buttonStyle(DevButtonStyle(palette: p, variant: .outline))
        }
    }

    // MARK: - Thread

    /// A timeline row: a single item, or a run of tool calls and approvals folded like T3's work log.
    private enum Row {
        case item(Int, DevThreadState.Item)
        case work(start: Int, entries: [(Int, DevThreadState.Item)])
    }

    private func rows(_ thread: DevThreadState) -> [Row] {
        var out: [Row] = []
        var run: [(Int, DevThreadState.Item)] = []
        func flush() { if let first = run.first { out.append(.work(start: first.0, entries: run)); run = [] } }
        for (i, item) in thread.items.enumerated() {
            switch item {
            case .tool, .approval: run.append((i, item))
            default: flush(); out.append(.item(i, item))
            }
        }
        flush()
        return out
    }

    private func threadArea(_ session: DevSession) -> some View {
        let thread = session.timeline
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: DevMetrics.rowSpacing) {
                        ForEach(Array(rows(thread).enumerated()), id: \.offset) { _, row in
                            rowView(row, thread: thread)
                        }
                        if thread.isTurnActive, !lastIsStreaming(thread), thread.pendingApprovals == 0 {
                            workingRow
                        }
                    }
                    if let error = session.lastError, thread.items.isEmpty {
                        DevErrorView(message: error,
                                     detail: isInstalled(session.harness) == false
                                     ? "Install: " + DevModelCatalog.installCommand(session.harness) : "",
                                     palette: p)
                            .padding(.top, 10)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, DevMetrics.gutter)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .overlay {
                if thread.items.isEmpty, session.sessionID == nil { newSessionHint(session) }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: thread.items) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// A new, empty session: what it runs with, and two starters.
    private func newSessionHint(_ session: DevSession) -> some View {
        VStack(spacing: 10) {
            DevMoonMark(size: 20, palette: p)
            Text("New session in \(session.projectDir.lastPathComponent)")
                .font(LunaType.brand(size: DevMetrics.text(18), weight: .regular))
                .foregroundStyle(p.foreground)
                .multilineTextAlignment(.center)
            Text("\(session.harness.displayName) · \(Self.shortModelName(currentModel?.displayName ?? (model.isEmpty ? "Default model" : model))) · \(approvalSummary(session.setup.approvalBehavior))")
                .font(.system(size: DevMetrics.textXs))
                .foregroundStyle(p.mutedForeground)
                .multilineTextAlignment(.center)
            VStack(spacing: 2) {
                suggestion("Explain this project") {
                    sendText("Give me a short overview of this project: what it does and how it is organized.")
                }
                suggestion("Review uncommitted changes") {
                    sendText("Review the uncommitted changes in this repository for bugs.")
                }
                if !hasBrowserTools {
                    suggestion("Connect browser tools…", action: onOpenSettings)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func approvalSummary(_ behavior: DevApprovalBehavior) -> String {
        switch behavior {
        case .ask: return "asks before commands and edits"
        case .allowEdits: return "edits run, commands ask"
        case .fullAuto: return "full auto"
        }
    }

    private func suggestion(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: DevMetrics.textXs))
                .padding(.horizontal, 8)
                .frame(height: 24)
        }
        .buttonStyle(DevGhostButtonStyle(palette: p, radius: DevMetrics.radiusSm))
    }

    /// T3's live "Working for 4s" status line.
    private var workingRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                PulsingDot(color: p.mutedForeground)
                Text(turnStartedAt.map { "Working for " + Self.duration(context.date.timeIntervalSince($0)) } ?? "Working…")
                    .font(.system(size: DevMetrics.textSm))
                    .foregroundStyle(p.mutedForeground)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("\(agent.displayName) is working")
    }

    /// Screenshots: open every work log and tool output.
    static var snapshotExpand: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_DEV_EXPAND"] != nil
        #else
        return false
        #endif
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return seconds < 10 ? String(format: "%.1fs", seconds) : "\(Int(seconds))s" }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private func lastIsStreaming(_ thread: DevThreadState) -> Bool {
        if case .assistant(_, true)? = thread.items.last { return true }
        return false
    }

    /// Model output may carry javascript:/file:/custom-scheme links; only http(s) is ever opened.
    static func isWebLink(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    @ViewBuilder
    private func rowView(_ row: Row, thread: DevThreadState) -> some View {
        switch row {
        case .item(_, let item):
            itemView(item, thread: thread)
        case .work(let start, let entries):
            workGroup(start: start, entries: entries, thread: thread)
        }
    }

    /// While a turn runs its work log is open; afterwards it folds behind T3's "Worked for" row.
    @ViewBuilder
    private func workGroup(start: Int, entries: [(Int, DevThreadState.Item)], thread: DevThreadState) -> some View {
        let userIndex = thread.items[..<start].lastIndex(where: { if case .user = $0 { return true }; return false }) ?? -1
        let isLive = thread.isTurnActive && !thread.items[start...].contains(where: { if case .user = $0 { return true }; return false })
            && thread.items.lastIndex(where: { if case .user = $0 { return true }; return false }) ?? -1 == userIndex
        let hasPending = entries.contains { if case .approval(let a) = $0.1 { return a.isPending }; return false }
        let open = isLive || hasPending || expandedGroups.contains(start) || Self.snapshotExpand
        VStack(alignment: .leading, spacing: 2) {
            if !isLive {
                Button {
                    if expandedGroups.contains(start) { expandedGroups.remove(start) } else { expandedGroups.insert(start) }
                } label: {
                    HStack(spacing: 4) {
                        Text(foldLabel(count: entries.count, userIndex: userIndex))
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(.system(size: DevMetrics.textSm))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                }
                .buttonStyle(DevGhostButtonStyle(palette: p, radius: DevMetrics.radiusMd))
                .accessibilityLabel(foldLabel(count: entries.count, userIndex: userIndex))
                .accessibilityHint(open ? "Hides the work log" : "Shows the work log")
            }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries, id: \.0) { _, item in
                        switch item {
                        case .tool(let card): DevWorkLogRow(card: card, palette: p)
                        case .approval(let card): approvalLogRow(card, thread: thread)
                        default: EmptyView()
                        }
                    }
                }
            }
        }
        .padding(.bottom, isLive ? 0 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if !isLive { Rectangle().fill(p.border).frame(height: 1) }
        }
    }

    private func foldLabel(count: Int, userIndex: Int) -> String {
        if let d = turnDurations[userIndex] { return "Worked for " + Self.duration(d) }
        return count == 1 ? "1 tool call" : "\(count) tool calls"
    }

    private func approvalLogRow(_ card: DevThreadState.ApprovalCard, thread: DevThreadState) -> some View {
        let state: String
        let color: Color
        switch card.status {
        case .pending: state = "Waiting for approval"; color = p.warningForeground
        case .expired: state = "Approval expired"; color = p.mutedForeground
        case .decided(let d):
            switch d {
            case .allow: state = "Allowed"; color = p.mutedForeground
            case .allowForSession: state = "Allowed for session"; color = p.mutedForeground
            case .deny, .cancel: state = "Denied"; color = p.errorForeground
            }
        }
        return HStack(spacing: 6) {
            Image(systemName: Self.approvalIcon(card.request.kind))
                .font(.system(size: 12))
                .frame(width: 22, height: 22)
                .foregroundStyle(color)
            Text(state).foregroundStyle(color)
            + Text("  " + card.request.summary).foregroundStyle(p.mutedForeground)
        }
        .font(.system(size: DevMetrics.textSm))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func itemView(_ item: DevThreadState.Item, thread: DevThreadState) -> some View {
        switch item {
        case .user(let text):
            Group {
                if settings.timelineStyle == .bubbles {
                    // Right-aligned bubble tinted with the accent; a sharper corner toward the edge.
                    HStack {
                        Spacer(minLength: 40)
                        Text(text)
                            .font(.system(size: scaledFont))
                            .foregroundStyle(p.foreground)
                            .textSelection(.enabled)
                            .padding(.horizontal, 13)
                            .padding(.vertical, DevMetrics.compact ? 7 : 9)
                            .background(UnevenRoundedRectangle(topLeadingRadius: DevMetrics.radius2xl, bottomLeadingRadius: DevMetrics.radius2xl,
                                                               bottomTrailingRadius: 6, topTrailingRadius: DevMetrics.radius2xl,
                                                               style: .continuous).fill(p.primarySoft))
                    }
                } else {
                    // Plain: a flat row with an accent rule, like a prompt line.
                    HStack(alignment: .top, spacing: 9) {
                        Capsule().fill(p.primary).frame(width: 2.5)
                        Text(text)
                            .font(.system(size: scaledFont, weight: .medium))
                            .foregroundStyle(p.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
        case .assistant(let text, _):
            RichMessageView(rawText: text, fontSize: scaledFont, linkColor: p.primary, onLinkTapped: { url in
                guard Self.isWebLink(url) else { return }
                if let onOpenLink { onOpenLink(url) } else { NSWorkspace.shared.open(url) }
            })
            .foregroundStyle(p.foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .tool(let card):
            DevWorkLogRow(card: card, palette: p)
        case .approval(let card):
            approvalLogRow(card, thread: thread)
        case .turn(let footer):
            DevTurnFooterView(footer: footer, sessionCost: thread.sessionCostUSD, palette: p)
        case .error(let message):
            DevErrorView(message: message, detail: "", palette: p)
        case .crash(let status, let signaled, let tail):
            DevErrorView(message: "\(thread.kind.displayName) quit unexpectedly (\(signaled ? "signal" : "exit") \(status)). Send a message to start a new session.",
                         detail: tail, palette: p)
        }
    }

    static func approvalIcon(_ kind: CLIApprovalKind) -> String {
        switch kind {
        case .command: return "terminal"
        case .fileChange: return "square.and.pencil"
        case .permission: return "lock.open"
        case .tool: return "wrench.and.screwdriver"
        }
    }

    static func approvalTitle(_ r: CLIApprovalRequest, agent: AgentCLIKind) -> String {
        switch r.kind {
        case .command: return "\(agent.displayName) wants to run a command"
        case .fileChange: return "\(agent.displayName) wants to edit files"
        case .permission: return "\(agent.displayName) wants more permissions"
        case .tool: return "\(agent.displayName) wants to use \(r.title)"
        }
    }

    /// T3's approval label: "Command approval", "File change approval", ...
    static func approvalLabel(_ kind: CLIApprovalKind) -> String {
        switch kind {
        case .command: return "Command approval"
        case .fileChange: return "File change approval"
        case .permission: return "Permission request"
        case .tool: return "Tool approval"
        }
    }

    // MARK: - Composer (capsule card, pickers in its footer, route + approval strip below)

    /// Where a chat message goes now (`DevSession.route`), for the strip under the composer.
    private func route(_ session: DevSession) -> DevSession.SendRoute {
        DevSession.route(terminalRunning: session.isTerminalRunning, externalLive: session.isExternalLive)
    }

    private func canSend(_ session: DevSession) -> Bool {
        !trimmedInput.isEmpty && session.canSend
    }

    private var pendingApproval: (card: DevThreadState.ApprovalCard, count: Int)? {
        guard let thread else { return nil }
        var first: DevThreadState.ApprovalCard?
        var count = 0
        for item in thread.items {
            if case .approval(let a) = item, a.isPending { count += 1; if first == nil { first = a } }
        }
        return first.map { ($0, count) }
    }

    @ViewBuilder
    private func composer(_ session: DevSession) -> some View {
        Group {
            if case .running(.external(let pid)) = session.state {
                liveBar(session, pid: pid)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                    .padding(.top, 4)
                    .transition(.opacity)
            } else {
                editableComposer(session)
            }
        }
        .takeOverConfirmation(isPresented: $confirmTakeOver) { session.takeOver() }
    }

    /// Replaces the composer while the session is live in a terminal outside Luna.
    private func liveBar(_ session: DevSession, pid: pid_t?) -> some View {
        HStack(spacing: 10) {
            PulsingDot(color: p.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("Live in Terminal" + (pid.map { " (pid \($0))" } ?? ""))
                    .font(.system(size: DevMetrics.textXs, weight: .medium))
                    .foregroundStyle(p.foreground)
                Text("Read-only while \(session.harness.executableName) writes it there.")
                    .font(.system(size: DevMetrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Take over") { confirmTakeOver = true }
                .buttonStyle(DevButtonStyle(palette: p, variant: .primary))
                .help("Write from Luna. If the terminal keeps going too, the two histories diverge.")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(Capsule(style: .continuous).fill(p.card))
        .overlay(Capsule(style: .continuous).strokeBorder(p.success.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// The CLI in Luna's terminal waits for an approval (or the folder trust question).
    private func terminalApprovalBar(_ session: DevSession) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(p.warningForeground)
            Text(session.terminal?.isShowingTrustPrompt == true
                 ? "\(session.harness.displayName) asks whether to trust this folder"
                 : "\(session.harness.displayName) is waiting for approval")
                .font(.system(size: DevMetrics.textXs, weight: .medium))
                .foregroundStyle(p.foreground)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Approve in terminal") { withAnimation(motion) { terminalMode = true } }
                .buttonStyle(DevButtonStyle(palette: p, variant: .primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private func editableComposer(_ session: DevSession) -> some View {
        VStack(spacing: 0) {
            if isInstalled(session.harness) == false { installBanner }
            VStack(alignment: .leading, spacing: 0) {
                if case .waitingApproval(.lunaTerminal) = session.state {
                    terminalApprovalBar(session)
                    Rectangle().fill(p.border).frame(height: 1)
                } else if let pending = pendingApproval {
                    approvalPanel(pending.card, count: pending.count)
                    Rectangle().fill(p.border).frame(height: 1)
                }
                PanelTextEditor(
                    text: $input,
                    placeholder: "Ask \(session.harness.displayName) anything…",
                    minHeight: 40,
                    fontSize: scaledFont,
                    isFocused: $inputFocused,
                    onSubmit: send,
                    reportedHeight: $editorHeight,
                    submitOnReturn: false,
                    onEscape: {
                        guard isTurnActive else { return false }
                        session.interrupt()
                        return true
                    },
                    accessibilityLabel: "Message to \(session.harness.displayName)"
                )
                .padding(.horizontal, 10)
                .padding(.top, 8)
                if isTurnActive, session.harness == .codex, route(session) == .headless {
                    Text("Codex takes the next message when this turn ends.")
                        .font(.system(size: DevMetrics.text2xs))
                        .foregroundStyle(p.mutedForeground)
                        .padding(.horizontal, 16)
                }
                composerFooter(session)
            }
            .background(RoundedRectangle(cornerRadius: DevMetrics.radius2xl + 4, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: DevMetrics.radius2xl + 4, style: .continuous)
                .strokeBorder(inputFocused ? p.primary.opacity(0.45) : p.composerOutline, lineWidth: 1))
            .shadow(color: (p.isDark ? Color.black : p.primary).opacity(p.isDark ? 0.3 : 0.07), radius: 16, y: 6)
            .zIndex(1)
            contextStrip(session)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private func composerFooter(_ session: DevSession) -> some View {
        HStack(spacing: 2) {
            harnessDropdown
            modelDropdown
            if agent == .codex, let efforts = currentModel?.efforts, !efforts.isEmpty { effortDropdown(efforts) }
            Spacer(minLength: 4)
            if isTurnActive, route(session) == .headless {
                Button { session.interrupt() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(p.background)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(p.foreground))
                }
                .buttonStyle(.plain)
                .help("Stop (Esc)")
                .accessibilityLabel("Stop")
            }
            if !isTurnActive || agent == .claudeCode || route(session) == .terminal {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(p.primaryForeground)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(p.primary))
                        .opacity(canSend(session) ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canSend(session))
                .help("Send (⌘↩)")
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 7)
        .padding(.bottom, 7)
        .padding(.top, 2)
    }

    // MARK: - Harness / model / effort pickers

    /// Installed harnesses, each from its own discovery; unsupported ones are listed but disabled.
    private var harnessItems: [DevDropdownItem] {
        var items: [DevDropdownItem] = []
        for h in harnesses {
            let signedOut = h.supported && h.signedIn == false
            items.append(DevDropdownItem(
                id: h.id.rawValue, title: h.name,
                subtitle: signedOut ? "Sign in in terminal (\(h.id.executableName) login)" : nil,
                detail: h.version.map { "v" + $0 },
                icon: h.id.agentKind.map(Self.providerIcon) ?? "shippingbox",
                iconColor: h.id.agentKind.map(Self.providerColor),
                section: h.supported ? "Harnesses" : "Installed, not supported yet",
                isEnabled: h.supported, disabledReason: "Not supported yet", keywords: [h.id.executableName]))
        }
        for kind in AgentCLIKind.allCases where !harnesses.contains(where: { $0.id == kind.harnessID }) {
            items.append(DevDropdownItem(
                id: kind.harnessID.rawValue, title: kind.displayName,
                subtitle: harnesses.isEmpty ? nil : DevModelCatalog.installCommand(kind),
                icon: Self.providerIcon(kind), iconColor: Self.providerColor(kind), section: "Harnesses",
                isEnabled: harnesses.isEmpty, disabledReason: "Not installed"))
        }
        return items.sorted { ($0.section == "Harnesses" ? 0 : 1) < ($1.section == "Harnesses" ? 0 : 1) }
    }

    private var harnessDropdown: some View {
        let info = harnesses.first { $0.id == agent.harnessID }
        return DevDropdown(isOpen: dropdownBinding("harness"), items: harnessItems, selectedID: agent.harnessID.rawValue,
                           palette: p, width: 290,
                           footnote: info?.signedIn == false ? "Signed out. Run `\(agent.executableName) login` in a terminal." : nil,
                           help: "Harness", onSelect: { item in
            if let kind = HarnessID(rawValue: item.id)?.agentKind { switchAgent(kind) }
        }) {
            DevPickerLabel(icon: Self.providerIcon(agent), iconColor: Self.providerColor(agent), text: agent.displayName,
                           dimmed: isInstalled(agent) == false, palette: p)
        }
        .fixedSize()
        .accessibilityLabel("Harness: \(agent.displayName)")
    }

    private var modelItems: [DevDropdownItem] {
        var items = models.map { m in
            DevDropdownItem(id: m.id, title: m.displayName, subtitle: m.description,
                            detail: agent == .codex ? m.defaultEffort : nil,
                            badge: m.isDefault ? "Default" : nil, section: agent.displayName + " models",
                            keywords: [m.id, m.resolvedModel ?? ""])
        }
        if !model.isEmpty, !models.contains(where: { $0.id == model }) {
            items.insert(DevDropdownItem(id: model, title: model, subtitle: "Not in the harness's list", section: "Current"), at: 0)
        }
        items.append(DevDropdownItem(id: "__refresh", title: modelsLoading ? "Refreshing…" : "Refresh models",
                                     icon: "arrow.clockwise", isEnabled: !modelsLoading, role: .action))
        return items
    }

    private var modelFootnote: String? {
        if modelsLoading, listing == nil { return "Asking \(agent.executableName) for its models…" }
        if let modelError, models.isEmpty { return modelError }
        if case .lastKnown(let date)? = listing?.source {
            return "Last known list · \(DevResumeOffer.relative(date)). \(agent.executableName) did not answer."
        }
        return nil
    }

    private var modelDropdown: some View {
        let label = Self.shortModelName(currentModel?.displayName ?? (model.isEmpty ? (modelsLoading ? "Loading…" : "Default") : DevSessionRow.shortModel(model)))
        return DevDropdown(isOpen: dropdownBinding("model"), items: modelItems,
                           selectedID: currentModel?.id ?? (model.isEmpty ? nil : model),
                           palette: p, width: 300, footnote: modelFootnote, help: "Model for the next session",
                           onSelect: { item in
            if item.id == "__refresh" { Task { await loadModels(refresh: true) } } else { switchModel(item.id) }
        }) {
            DevPickerLabel(text: label, dimmed: isInstalled(agent) == false, maxTextWidth: 130, palette: p)
        }
        .fixedSize()
        .accessibilityLabel("Model: \(label)")
    }

    /// "xhigh" → "Extra high", "low" → "Low".
    static func effortName(_ effort: String) -> String {
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        case "xlow": return "Extra low"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }

    /// "Default (recommended)" → "Default": the footer has no room for asides.
    static func shortModelName(_ name: String) -> String {
        guard let paren = name.firstIndex(of: "("), paren > name.startIndex else { return name }
        return name[..<paren].trimmingCharacters(in: .whitespaces)
    }

    private func effortDropdown(_ efforts: [String]) -> some View {
        let items = efforts.map { e in
            DevDropdownItem(id: e, title: Self.effortName(e), badge: e == currentModel?.defaultEffort ? "Default" : nil,
                            section: "Reasoning effort")
        }
        return DevDropdown(isOpen: dropdownBinding("effort"), items: items, selectedID: currentEffort, palette: p,
                           width: 200, help: "Reasoning effort", onSelect: { item in switchEffort(item.id) }) {
            DevPickerLabel(icon: "brain", text: Self.effortName(currentEffort ?? "default"), maxTextWidth: 80, palette: p)
        }
        .fixedSize()
        .accessibilityLabel("Reasoning effort: \(currentEffort ?? "default")")
    }

    private func loadModels(refresh: Bool) async {
        let harness = agent.harnessID
        modelsLoading = true
        defer { modelsLoading = false }
        do {
            let result = try await HarnessModelCatalog.shared.listing(for: harness, refresh: refresh)
            guard harness == agent.harnessID else { return }
            listing = result
            modelError = nil
        } catch {
            guard harness == agent.harnessID else { return }
            modelError = error.localizedDescription
        }
    }

    nonisolated static func providerIcon(_ kind: AgentCLIKind) -> String {
        kind == .claudeCode ? "asterisk" : "hexagon"
    }

    nonisolated static func providerColor(_ kind: AgentCLIKind) -> Color {
        kind == .claudeCode ? Color(hex: 0xD97757) : Color(hex: 0x10A37F)
    }

    /// Under the composer: approval mode, where sends go ("Sending to terminal" / "Headless" /
    /// "Read-only"), browser tools, and the session state.
    private func contextStrip(_ session: DevSession) -> some View {
        let approval = session.setup.approvalBehavior
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: approval == .fullAuto ? "exclamationmark.shield" : "checkmark.shield")
                    .font(.system(size: 10))
                Text(approval == .ask ? "Ask first" : approval.displayName)
            }
            .foregroundStyle(approval == .fullAuto ? p.warningForeground : p.mutedForeground)
            .help("Approval behavior (Settings → Dev)")
            routeLabel(session)
            Spacer(minLength: 4)
            if hasBrowserTools {
                Image(systemName: "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(p.mutedForeground)
                    .help("This session can use Luna's browser tools")
                    .accessibilityLabel("Luna browser tools connected")
            }
            statusText(session)
        }
        .font(.system(size: DevMetrics.text2xs))
        .padding(.horizontal, 16)
        .padding(.top, 7)
    }

    @ViewBuilder
    private func routeLabel(_ session: DevSession) -> some View {
        let (icon, text, help): (String, String, String) = {
            switch route(session) {
            case .terminal:
                let queued = session.terminal?.queuedSends.count ?? 0
                return ("apple.terminal", queued > 0 ? "Sending to terminal (\(queued) queued)" : "Sending to terminal",
                        "Messages are typed into \(session.harness.executableName) in the Terminal tab")
            case .headless:
                return ("bolt.horizontal", "Headless", "Messages go to \(session.harness.executableName) running in the background")
            case .refused:
                return ("lock", "Read-only", "Live in another terminal")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9.5))
            Text(text)
        }
        .foregroundStyle(p.mutedForeground)
        .padding(.horizontal, 6)
        .frame(height: 17)
        .background(Capsule().fill(p.accent))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Route: \(text)")
    }

    @ViewBuilder
    private func statusText(_ session: DevSession) -> some View {
        switch session.state {
        case .running(.lunaHeadless) where thread?.items.isEmpty != false || !isTurnActive:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Starting…")
            }
            .foregroundStyle(p.mutedForeground)
        case .idle:
            if let thread, thread.isAlive || session.isTerminalRunning {
                statusDot(p.success, text: sessionSummary(thread))
            } else if session.sessionID != nil {
                statusDot(p.mutedForeground.opacity(0.6), text: "Resumable")
            }
        case .running(.lunaTerminal):
            statusDot(p.success, text: "Terminal")
        case .running:
            statusDot(p.warning, text: thread.map(sessionSummary) ?? "Working")
        case .waitingApproval:
            statusDot(p.warning, text: "Needs approval")
        }
    }

    private func statusDot(_ color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).monospacedDigit()
        }
        .foregroundStyle(p.mutedForeground)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func sessionSummary(_ thread: DevThreadState) -> String {
        var parts = [thread.isTurnActive ? "Working" : "Ready"]
        if let cost = thread.sessionCostUSD { parts.append(String(format: "$%.3f", cost)) }
        return parts.joined(separator: " · ")
    }

    private var installBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(p.warning)
            Text("`\(agent.executableName)` not found. Install with ")
                + Text(DevModelCatalog.installCommand(agent)).font(.system(size: 11.5, design: .monospaced))
        }
        .font(.system(size: DevMetrics.textXs))
        .foregroundStyle(p.warningForeground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DevMetrics.radiusLg).fill(p.warning.opacity(p.isDark ? 0.12 : 0.08)))
        .padding(.bottom, 8)
    }

    /// A pending approval inside the composer: label, the request in mono, small buttons.
    private func approvalPanel(_ card: DevThreadState.ApprovalCard, count: Int) -> some View {
        let agentKind = thread?.kind ?? agent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.approvalLabel(card.request.kind))
                    .font(.system(size: DevMetrics.text2xs, weight: .medium))
                    .foregroundStyle(p.warningForeground)
                Text(card.request.kind == .tool ? card.request.title : agentKind.displayName)
                    .font(.system(size: DevMetrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 1 {
                    Text("1/\(count)").font(.system(size: DevMetrics.text2xs)).foregroundStyle(p.mutedForeground).monospacedDigit()
                }
            }
            ScrollView {
                Text(DevApprovalText.detail(for: card.request))
                    .font(.system(size: DevMetrics.textXs, design: .monospaced))
                    .foregroundStyle(p.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Allow") { session?.respond(approvalID: card.request.id, decision: .allow) }
                    .buttonStyle(DevButtonStyle(palette: p, variant: .primary))
                Button("Allow for session") { session?.respond(approvalID: card.request.id, decision: .allowForSession) }
                    .buttonStyle(DevButtonStyle(palette: p, variant: .outline))
                Button("Deny") { session?.respond(approvalID: card.request.id, decision: .deny) }
                    .buttonStyle(DevButtonStyle(palette: p, variant: .outline))
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.approvalTitle(card.request, agent: agentKind))
    }

    // MARK: - Actions

    private func sendText(_ text: String) {
        input = text
        send()
    }

    private func send() {
        guard let session, canSend(session) else { return }
        let text = trimmedInput
        input = ""
        if case .refused = session.send(text) { input = text }
    }

    /// The harness is fixed per session: another one starts a new session in the same project.
    private func switchAgent(_ kind: AgentCLIKind) {
        guard kind != agent else { return }
        guard let session else {
            workspace.flow.choose(harness: kind)
            return
        }
        var setup = session.setup
        setup.harness = kind
        setup.model = settings.defaultModel(for: kind.harnessID)
        setup.effort = nil
        workspace.startNew(harness: kind, projectDir: session.projectDir, setup: setup)
    }

    private func switchModel(_ id: String) {
        guard let session, id != model else { return }
        let next = DevComposerSelection(harness: agent, model: model, effort: effort).picking(model: id, in: models)
        var setup = session.setup
        setup.model = next.model.isEmpty ? nil : next.model
        setup.effort = next.effort.isEmpty ? nil : next.effort
        session.updateSetup(setup)
    }

    private func switchEffort(_ value: String) {
        guard let session, value != currentEffort else { return }
        var setup = session.setup
        setup.effort = value
        session.updateSetup(setup)
    }

    /// A new session with the current session's setup (or the home view when none is open).
    private func newThread() {
        input = ""
        guard let session else {
            workspace.goHome()
            return
        }
        workspace.startNew(harness: session.harness, projectDir: session.projectDir, setup: session.setup)
    }

    /// Another project: back to the home view with it chosen.
    private func selectProject(_ path: String) {
        guard path != projectPath || session != nil else { return }
        DevPrefs.remember(project: path)
        withAnimation(motion) { workspace.goHome(project: path) }
        terminalMode = false
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder to work in"
        if let projectURL { panel.directoryURL = projectURL }
        if panel.runModal() == .OK, let url = panel.url {
            DevPrefs.remember(project: url.path)
            withAnimation(motion) { workspace.goHome(project: url.path) }
            terminalMode = false
        }
    }
}

extension View {
    /// "Take over this session?" before writing to a session another terminal is running.
    func takeOverConfirmation(isPresented: Binding<Bool>, onConfirm: @escaping () -> Void) -> some View {
        confirmationDialog("Take over this session?", isPresented: isPresented) {
            Button("Take over", action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It is still open in another terminal. If both keep writing, the two histories diverge.")
        }
    }
}

// MARK: - Install hints

/// Install commands for the supported harnesses (models come from `HarnessModelCatalog`).
enum DevModelCatalog {
    static func installCommand(_ kind: AgentCLIKind) -> String {
        switch kind {
        case .claudeCode: return "npm install -g @anthropic-ai/claude-code"
        case .codex: return "npm install -g @openai/codex"
        }
    }
}

// MARK: - Work log, footer, errors (T3 Code's WorkLog / message meta / ThreadErrorBanner)

/// One tool call as a T3 work-log line: a 24pt icon cell, the label in the secondary color,
/// and its output in a bordered mono block on demand.
private struct DevWorkLogRow: View {
    let card: DevThreadState.ToolCard
    let palette: DevPalette
    @State private var expanded = DevPanelView.snapshotExpand
    @State private var hovering = false
    /// Settings → Dev → Appearance → Show tool details: the input summary and output.
    private var details: Bool { DevSettings.shared.showToolDetails }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !card.output.isEmpty, details { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    icon.frame(width: 22, height: 22)
                    (Text(card.name).foregroundStyle(palette.mutedForeground)
                     + Text(details ? "  " + card.summary : "")
                        .font(.system(size: DevMetrics.textSm - 1.5, design: .monospaced))
                        .foregroundStyle(palette.foreground.opacity(hovering ? 0.95 : 0.8)))
                        .font(.system(size: DevMetrics.textSm))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !card.output.isEmpty, details {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.mutedForeground.opacity(hovering || expanded ? 1 : 0.6))
                    }
                }
                .frame(minHeight: 26)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: DevMetrics.radiusMd).fill(hovering && !card.output.isEmpty ? palette.accent : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(card.summary)
            .accessibilityLabel("\(card.name): \(card.summary), \(statusText)")
            .accessibilityHint(card.output.isEmpty ? "" : (expanded ? "Hides the output" : "Shows the output"))
            if expanded, details {
                ScrollView {
                    Text(card.output)
                        .font(.system(size: DevMetrics.textXs - 0.5, design: .monospaced))
                        .foregroundStyle(palette.foreground.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: DevMetrics.radiusLg).fill(palette.muted))
                .overlay(RoundedRectangle(cornerRadius: DevMetrics.radiusLg).strokeBorder(palette.border))
                .padding(.leading, 30)
                .padding(.top, 2)
                .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch card.status {
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .failed:
            Image(systemName: "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(palette.errorForeground)
        case .done:
            Image(systemName: Self.symbol(for: card.name))
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
        }
    }

    /// T3's tool icons: terminal for commands, eye for reads, pen for edits, search, globe.
    static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("bash") || n.contains("command") || n.contains("exec") || n.contains("shell") { return "terminal" }
        if n.contains("luna") || n.contains("browser") || n.contains("web") || n.contains("fetch") { return "globe" }
        if n.contains("read") || n.contains("view") { return "eye" }
        if n.contains("edit") || n.contains("write") || n.contains("patch") || n.contains("file") { return "square.and.pencil" }
        if n.contains("grep") || n.contains("glob") || n.contains("search") || n == "ls" { return "magnifyingglass" }
        if n.contains("task") || n.contains("agent") { return "person.2" }
        if n.contains("todo") || n.contains("plan") { return "checklist" }
        return "wrench.adjustable"
    }

    private var statusText: String {
        switch card.status {
        case .running: return "running"
        case .done: return "done"
        case .failed: return "failed"
        }
    }
}

/// End of a turn as T3's message meta line: outcome, tokens and cost, small and muted.
private struct DevTurnFooterView: View {
    let footer: DevThreadState.TurnFooter
    let sessionCost: Double?
    let palette: DevPalette

    var body: some View {
        Text(parts.joined(separator: " · "))
            .font(.system(size: DevMetrics.textXs))
            .monospacedDigit()
            .foregroundStyle(isFailure ? palette.errorForeground : palette.mutedForeground.opacity(0.85))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -6)
            .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool { if case .failed = footer.outcome { return true }; return false }

    private var parts: [String] {
        var out: [String]
        switch footer.outcome {
        case .completed: out = ["Done"]
        case .interrupted: out = ["Interrupted"]
        case .failed(let message): out = ["Failed" + (message.map { ": \($0)" } ?? "")]
        }
        if let i = footer.inputTokens, let o = footer.outputTokens, i + o > 0 {
            out.append("\(i.formatted()) in / \(o.formatted()) out")
        }
        if let cost = footer.costUSD {
            var s = String(format: "$%.4f", cost)
            if let sessionCost, sessionCost > cost { s += String(format: " (session $%.4f)", sessionCost) }
            out.append(s)
        }
        return out
    }
}

/// T3's error banner (error surface, error foreground) with an optional mono tail (CLI stderr).
private struct DevErrorView: View {
    let message: String
    let detail: String
    let palette: DevPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                Text(message)
                    .font(.system(size: DevMetrics.textXs + 0.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.errorForeground)
            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: DevMetrics.text2xs, design: .monospaced))
                        .foregroundStyle(palette.foreground.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: DevMetrics.radiusMd).fill(palette.background.opacity(0.6)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DevMetrics.radiusLg, style: .continuous).fill(palette.errorSurface))
        .overlay(RoundedRectangle(cornerRadius: DevMetrics.radiusLg, style: .continuous)
            .strokeBorder(palette.error.opacity(0.25)))
    }
}

/// T3's status pulse for the live "Working for" line.
struct PulsingDot: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// A horizontal line for the dotted underline under T3's project selector.
private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

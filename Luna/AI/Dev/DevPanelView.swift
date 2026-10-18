import AppKit
import SwiftUI

/// Dev mode: drive Claude Code or Codex in a project folder from the AI panel.
///
/// The layout and styling mirror T3 Code's chat (https://github.com/pingdotgg/t3code, MIT License):
/// a breadcrumb header (project / thread), a timeline of user bubbles, assistant prose and folded
/// work-log rows, approvals inside the composer, and a rounded composer with the provider/model
/// pickers in its footer and the project in a strip below it. ⌘↩ sends, Esc stops.
struct DevPanelView: View {
    let fontSize: CGFloat
    var onOpenSettings: () -> Void
    /// Opens a web link in a Luna tab; falls back to the default browser when not provided.
    var onOpenLink: ((URL) -> Void)?
    /// The compact General | Dev switch, shown in the header.
    var modeSwitch: AnyView = AnyView(EmptyView())
    var onClose: () -> Void = {}

    @AppStorage(DevPrefs.agentKey) private var agentRaw: String = AgentCLIKind.claudeCode.rawValue
    @AppStorage(DevPrefs.projectKey) private var projectPath: String = ""
    @AppStorage(DevPrefs.modelKey) private var model: String = ""
    @AppStorage(DevPrefs.resumeKey) private var resume: Bool = false
    @AppStorage(DevPrefs.terminalKey) private var terminalMode: Bool = false

    @Environment(\.colorScheme) private var scheme
    @State private var controller = DevSessionController.shared
    @State private var input = ""
    @State private var editorHeight: CGFloat = 36
    @State private var terminalGeneration = 0
    @State private var expandedGroups: Set<Int> = []
    @State private var turnStartedAt: Date?
    /// "Worked for" durations, keyed by the index of the turn's user message.
    @State private var turnDurations: [Int: TimeInterval] = [:]
    @FocusState private var inputFocused: Bool

    private var p: T3Palette { .of(scheme) }
    private var agent: AgentCLIKind { AgentCLIKind(rawValue: agentRaw) ?? .claudeCode }
    private var projectURL: URL? { projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath, isDirectory: true) }
    private var projectName: String? { projectURL?.lastPathComponent }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTurnActive: Bool { controller.thread?.isTurnActive == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            if terminalMode {
                terminalArea
            } else {
                threadArea
                composer
            }
        }
        .background(p.background)
        .onAppear {
            if controller.installed.isEmpty { controller.refreshInstalled() }
            if isTurnActive, turnStartedAt == nil { turnStartedAt = Date() }
            #if DEBUG
            // Screenshots: approve the first pending request after the given delay.
            if let delay = ProcessInfo.processInfo.environment["LUNA_SNAPSHOT_DEV_ALLOW"].flatMap(Double.init) {
                Task {
                    for _ in 0..<120 {
                        try? await Task.sleep(for: .seconds(delay))
                        if let pending = pendingApproval {
                            controller.respond(approvalID: pending.card.request.id, decision: .allow)
                            return
                        }
                    }
                }
            }
            #endif
        }
        .onChange(of: isTurnActive) { _, active in
            if active {
                turnStartedAt = Date()
            } else if let start = turnStartedAt, let thread = controller.thread,
                      let userIndex = thread.items.lastIndex(where: { if case .user = $0 { return true }; return false }) {
                turnDurations[userIndex] = Date().timeIntervalSince(start)
                turnStartedAt = nil
            }
        }
    }

    // MARK: - Header (T3's ChatHeader: project badge / thread title, icon controls on the right)

    private var header: some View {
        HStack(spacing: 6) {
            modeSwitch
            HStack(spacing: 6) {
                if projectName != nil { projectBadge }
                projectMenu(label: Text(projectName ?? "No project")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(projectName == nil ? p.mutedForeground : p.foreground)
                    .padding(.horizontal, 4).frame(height: 24))
                    .layoutPriority(1)
                Text("/").font(.system(size: 13)).foregroundStyle(p.mutedForeground.opacity(0.7))
                Text(threadTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(p.foreground.opacity(controller.thread == nil ? 0.55 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(threadTitle)
            }
            .padding(.leading, 2)
            Spacer(minLength: 2)
            T3IconButton(systemName: "terminal", help: terminalMode ? "Show thread" : "Show terminal (raw CLI)",
                         palette: p, isOn: terminalMode) { terminalMode.toggle() }
            T3IconButton(systemName: "square.and.pencil", help: "New Session", palette: p) { controller.stop() }
            T3IconButton(systemName: "xmark", help: "Close (Esc)", palette: p) {
                // Esc stops a running turn before it closes the panel.
                if isTurnActive { controller.interrupt() } else { onClose() }
            }
            // The raw terminal needs Esc (it interrupts the CLI).
            .keyboardShortcut(terminalMode ? nil : KeyboardShortcut(.escape, modifiers: []))
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    private var threadTitle: String {
        if let thread = controller.thread {
            for item in thread.items {
                if case .user(let text) = item {
                    return text.split(separator: "\n").first.map(String.init) ?? text
                }
            }
        }
        return "New thread"
    }

    /// T3 shows a project's favicon or its initials in a small rounded square.
    private var projectBadge: some View {
        Text(Self.initials(projectName ?? "?"))
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(p.primary)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(p.primary.opacity(p.isDark ? 0.22 : 0.12)))
            .accessibilityHidden(true)
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { "-_ .".contains($0) })
        let letters = words.count >= 2 ? words.prefix(2).compactMap(\.first) : Array(name.prefix(2))
        return String(letters).uppercased()
    }

    private func projectMenu<L: View>(label: L, fixed: Bool = true) -> some View {
        Menu {
            Button("Choose Folder…") { chooseFolder() }
            let recents = DevPrefs.recentProjects()
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Toggle((path as NSString).abbreviatingWithTildeInPath, isOn: Binding(
                            get: { path == projectPath }, set: { if $0 { selectProject(path) } }))
                    }
                }
            }
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(T3GhostButtonStyle(palette: p, radius: T3Metrics.radiusSm))
        .menuIndicator(.hidden)
        .fixedSize(horizontal: fixed, vertical: true)
        .help(projectPath.isEmpty ? "Project folder" : (projectPath as NSString).abbreviatingWithTildeInPath)
        .accessibilityLabel("Project: \(projectName ?? "none")")
    }

    // MARK: - Terminal

    @ViewBuilder
    private var terminalArea: some View {
        if let projectURL, controller.isInstalled(agent) != false {
            DevTerminalView(kind: agent, projectDir: projectURL, isDark: p.isDark)
                .id("\(agent.rawValue)|\(projectPath)|\(terminalGeneration)")
                .padding(8)
                .background(p.card)
                .clipShape(RoundedRectangle(cornerRadius: T3Metrics.radiusLg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: T3Metrics.radiusLg, style: .continuous).strokeBorder(p.border))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("\(agent.displayName) terminal")
        } else {
            VStack(spacing: 10) {
                Text(projectURL == nil
                     ? "Choose a project to open \(agent.executableName) in a terminal."
                     : "Install \(agent.executableName) to use the terminal.")
                    .font(.system(size: T3Metrics.textSm))
                    .foregroundStyle(p.mutedForeground)
                    .multilineTextAlignment(.center)
                if projectURL == nil {
                    Button("Choose Folder…") { chooseFolder() }
                        .buttonStyle(T3ButtonStyle(palette: p, variant: .outline))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var threadArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let thread = controller.thread {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(rows(thread).enumerated()), id: \.offset) { _, row in
                                rowView(row, thread: thread)
                            }
                            if thread.isTurnActive, !lastIsStreaming(thread), thread.pendingApprovals == 0 {
                                workingRow
                            }
                        }
                    }
                    if let error = controller.startErrorText {
                        DevErrorView(message: error,
                                     detail: controller.startError == .notFound(agent.executableName)
                                     ? "Install: " + DevModelCatalog.installCommand(agent) : "",
                                     palette: p)
                            .padding(.top, 10)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            .overlay {
                if controller.thread == nil, !controller.isStarting, controller.startErrorText == nil { emptyState }
            }
            .frame(maxHeight: .infinity)
            .onChange(of: controller.thread?.items) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    /// T3's draft hero: one quiet headline with the project as a dotted-underline picker.
    private var emptyState: some View {
        VStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { heroText }
                VStack(spacing: 2) { heroText }
            }
            .font(.system(size: 20))
            .tracking(-0.3)
            .multilineTextAlignment(.center)
            Text(projectURL == nil
                 ? "\(agent.displayName) runs on this Mac with your own CLI login."
                 : "Commands and file edits ask first.")
                .font(.system(size: T3Metrics.textSm))
                .foregroundStyle(p.mutedForeground)
                .multilineTextAlignment(.center)
            if projectURL != nil {
                VStack(spacing: 2) {
                    suggestion("Explain this project") {
                        sendText("Give me a short overview of this project: what it does and how it is organized.")
                    }
                    suggestion("Review uncommitted changes") {
                        sendText("Review the uncommitted changes in this repository for bugs.")
                    }
                    if !controller.hasBrowserTools {
                        suggestion("Connect browser tools…", action: onOpenSettings)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var heroText: some View {
        if let projectName {
            Text("What should we build in").foregroundStyle(p.foreground)
            projectMenu(label: heroSelector(projectName + "?"))
        } else {
            projectMenu(label: heroSelector("Choose a project"))
            Text("to start").foregroundStyle(p.foreground)
        }
    }

    private func heroSelector(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 20))
            .foregroundStyle(p.mutedForeground.opacity(0.85))
            .overlay(alignment: .bottom) {
                Line().stroke(p.mutedForeground.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [1.5, 2.5]))
                    .frame(height: 1)
            }
    }

    private func suggestion(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: T3Metrics.textXs))
                .padding(.horizontal, 8)
                .frame(height: 24)
        }
        .buttonStyle(T3GhostButtonStyle(palette: p, radius: T3Metrics.radiusSm))
    }

    /// T3's live "Working for 4s" status line.
    private var workingRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                PulsingDot(color: p.mutedForeground)
                Text(turnStartedAt.map { "Working for " + Self.duration(context.date.timeIntervalSince($0)) } ?? "Working…")
                    .font(.system(size: T3Metrics.textSm))
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
                    .font(.system(size: T3Metrics.textSm))
                    .monospacedDigit()
                    .padding(.horizontal, 4)
                    .frame(height: 24)
                }
                .buttonStyle(T3GhostButtonStyle(palette: p, radius: T3Metrics.radiusMd))
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
        .font(.system(size: T3Metrics.textSm))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func itemView(_ item: DevThreadState.Item, thread: DevThreadState) -> some View {
        switch item {
        case .user(let text):
            // T3: right-aligned rounded-2xl bubble on the message surface, max 80% wide.
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.system(size: fontSize))
                    .foregroundStyle(p.foreground)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: T3Metrics.radius2xl, style: .continuous).fill(p.accent))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
        case .assistant(let text, _):
            RichMessageView(rawText: text, fontSize: fontSize, linkColor: p.primary, onLinkTapped: { url in
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

    // MARK: - Composer (T3's ComposerSurface: rounded-3xl card, footer pickers, context strip below)

    private var canSend: Bool {
        guard !trimmedInput.isEmpty, projectURL != nil, !controller.isStarting else { return false }
        guard let thread = controller.thread, thread.isAlive else { return true } // a send starts a session
        return thread.canSend
    }

    private var pendingApproval: (card: DevThreadState.ApprovalCard, count: Int)? {
        guard let thread = controller.thread else { return nil }
        var first: DevThreadState.ApprovalCard?
        var count = 0
        for item in thread.items {
            if case .approval(let a) = item, a.isPending { count += 1; if first == nil { first = a } }
        }
        return first.map { ($0, count) }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if controller.isInstalled(agent) == false { installBanner }
            VStack(alignment: .leading, spacing: 0) {
                if let pending = pendingApproval {
                    approvalPanel(pending.card, count: pending.count)
                    Rectangle().fill(p.border).frame(height: 1)
                }
                PanelTextEditor(
                    text: $input,
                    placeholder: projectURL == nil ? "Choose a project first" : "Ask \(agent.displayName) anything…",
                    minHeight: 40,
                    fontSize: fontSize,
                    isFocused: $inputFocused,
                    onSubmit: send,
                    reportedHeight: $editorHeight,
                    submitOnReturn: false,
                    onEscape: {
                        guard isTurnActive else { return false }
                        controller.interrupt()
                        return true
                    },
                    accessibilityLabel: "Message to \(agent.displayName)"
                )
                .padding(.horizontal, 8)
                .padding(.top, 8)
                if isTurnActive, agent == .codex {
                    Text("Codex takes the next message when this turn ends.")
                        .font(.system(size: T3Metrics.text2xs))
                        .foregroundStyle(p.mutedForeground)
                        .padding(.horizontal, 16)
                }
                composerFooter
            }
            .background(RoundedRectangle(cornerRadius: T3Metrics.radius3xl, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: T3Metrics.radius3xl, style: .continuous)
                .strokeBorder(inputFocused ? p.foreground.opacity(p.isDark ? 0.14 : 0.16) : p.composerOutline, lineWidth: 1))
            .shadow(color: .black.opacity(p.isDark ? 0 : 0.10), radius: 14, y: 8)
            .zIndex(1)
            contextStrip
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 4)
    }

    private var composerFooter: some View {
        HStack(spacing: 2) {
            modelPicker
            Rectangle().fill(p.border).frame(width: 1, height: 14).padding(.horizontal, 3)
            resumePicker
            Spacer(minLength: 4)
            if isTurnActive {
                Button(action: controller.interrupt) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(p.background)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(p.foreground))
                }
                .buttonStyle(.plain)
                .help("Stop (Esc)")
                .accessibilityLabel("Stop")
            }
            if !isTurnActive || agent == .claudeCode {
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(p.primaryForeground)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(p.primary))
                        .opacity(canSend ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (⌘↩)")
                .accessibilityLabel("Send")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .padding(.top, 2)
    }

    /// One picker for provider and model, like T3's ProviderModelPicker.
    private var modelPicker: some View {
        let current = DevModelCatalog.models(for: agent).first { $0.id == model }?.name
        let label = agent == .claudeCode ? (current.map { "Claude \($0)" } ?? "Claude Code") : (current ?? "Codex")
        return Menu {
            ForEach(AgentCLIKind.allCases, id: \.self) { kind in
                Section(kind.displayName + (controller.isInstalled(kind) == false ? " (not installed)" : "")) {
                    modelItem(kind: kind, id: "", name: "Default")
                    ForEach(DevModelCatalog.models(for: kind), id: \.id) { modelItem(kind: kind, id: $0.id, name: $0.name) }
                    if kind == agent, !model.isEmpty, !DevModelCatalog.models(for: kind).contains(where: { $0.id == model }) {
                        modelItem(kind: kind, id: model, name: model)
                    }
                }
            }
        } label: {
            footerControl(icon: Self.providerIcon(agent), iconColor: Self.providerColor(agent), text: label,
                          dimmed: controller.isInstalled(agent) == false)
        }
        .menuStyle(.button)
        .buttonStyle(T3GhostButtonStyle(palette: p))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Agent and model for the next session")
        .accessibilityLabel("Agent: \(agent.displayName), model: \(current ?? "default")")
    }

    private func modelItem(kind: AgentCLIKind, id: String, name: String) -> some View {
        Toggle(name, isOn: Binding(get: { kind == agent && id == model }, set: { on in
            guard on else { return }
            switchAgent(kind)
            switchModel(id)
        }))
    }

    private var resumePicker: some View {
        Menu {
            Toggle("New session", isOn: Binding(get: { !resume }, set: { if $0 { resume = false } }))
            Toggle("Resume last session", isOn: Binding(get: { resume }, set: { if $0 { resume = true } }))
        } label: {
            footerControl(icon: resume ? "arrow.counterclockwise" : "plus.bubble", iconColor: nil,
                          text: resume ? "Resume last" : "New session", dimmed: false)
        }
        .menuStyle(.button)
        .buttonStyle(T3GhostButtonStyle(palette: p))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Continue this project's last \(agent.displayName) session")
        .accessibilityLabel(resume ? "Resume last session" : "New session")
    }

    private func footerControl(icon: String, iconColor: Color?, text: String, dimmed: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(iconColor ?? (dimmed ? p.mutedForeground : p.foreground.opacity(0.8)))
            Text(text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(dimmed ? p.mutedForeground : p.foreground.opacity(0.9))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(p.mutedForeground)
        }
        .padding(.horizontal, 7)
        .frame(height: 26)
        .contentShape(Rectangle())
    }

    static func providerIcon(_ kind: AgentCLIKind) -> String {
        kind == .claudeCode ? "asterisk" : "hexagon"
    }

    static func providerColor(_ kind: AgentCLIKind) -> Color {
        kind == .claudeCode ? Color(hex: 0xD97757) : Color(hex: 0x10A37F)
    }

    /// T3's context strip under the composer: workspace on the left, session state on the right.
    private var contextStrip: some View {
        HStack(spacing: 8) {
            projectMenu(label: HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 11))
                Text(projectURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Choose project")
                    .lineLimit(1)
                    .truncationMode(.head)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: T3Metrics.textXs))
            .foregroundStyle(p.mutedForeground)
            .padding(.horizontal, 5).frame(height: 22), fixed: false)
            .layoutPriority(-1)
            Spacer(minLength: 4)
            if controller.hasBrowserTools {
                HStack(spacing: 4) {
                    Image(systemName: "globe").font(.system(size: 10))
                    Text("Luna tools")
                }
                .font(.system(size: T3Metrics.text2xs))
                .foregroundStyle(p.mutedForeground)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .overlay(Capsule().strokeBorder(p.border.opacity(p.isDark ? 1.5 : 1), lineWidth: 1))
                .help("This session can use Luna's browser tools")
                .accessibilityLabel("Luna browser tools connected")
            }
            statusText
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 6)
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: T3Metrics.radius2xl, bottomTrailingRadius: T3Metrics.radius2xl,
                                   style: .continuous)
                .fill(p.isDark ? Color.white.opacity(0.015) : Color.black.opacity(0.012))
        )
        .overlay(
            UnevenRoundedRectangle(bottomLeadingRadius: T3Metrics.radius2xl, bottomTrailingRadius: T3Metrics.radius2xl,
                                   style: .continuous)
                .strokeBorder(p.composerOutline, lineWidth: 1)
        )
        .padding(.horizontal, 18)
        .padding(.top, -16)
    }

    @ViewBuilder
    private var statusText: some View {
        if controller.isStarting {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Starting…")
            }
            .font(.system(size: T3Metrics.textXs))
            .foregroundStyle(p.mutedForeground)
        } else if let thread = controller.thread, thread.isAlive {
            HStack(spacing: 5) {
                Circle().fill(thread.isTurnActive ? p.warning : p.success).frame(width: 6, height: 6)
                Text(sessionSummary(thread)).monospacedDigit()
            }
            .font(.system(size: T3Metrics.textXs))
            .foregroundStyle(p.mutedForeground)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
        }
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
        .font(.system(size: T3Metrics.textXs))
        .foregroundStyle(p.warningForeground)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T3Metrics.radiusLg).fill(p.warning.opacity(p.isDark ? 0.12 : 0.08)))
        .padding(.bottom, 8)
    }

    /// T3's ComposerPendingApprovalPanel + actions: a warning label, the request in mono, xs buttons.
    private func approvalPanel(_ card: DevThreadState.ApprovalCard, count: Int) -> some View {
        let agentKind = controller.thread?.kind ?? agent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.approvalLabel(card.request.kind))
                    .font(.system(size: T3Metrics.text2xs, weight: .medium))
                    .foregroundStyle(p.warningForeground)
                Text(card.request.kind == .tool ? card.request.title : agentKind.displayName)
                    .font(.system(size: T3Metrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 1 {
                    Text("1/\(count)").font(.system(size: T3Metrics.text2xs)).foregroundStyle(p.mutedForeground).monospacedDigit()
                }
            }
            ScrollView {
                Text(DevApprovalText.detail(for: card.request))
                    .font(.system(size: T3Metrics.textXs, design: .monospaced))
                    .foregroundStyle(p.foreground)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Allow") { controller.respond(approvalID: card.request.id, decision: .allow) }
                    .buttonStyle(T3ButtonStyle(palette: p, variant: .primary))
                Button("Allow for session") { controller.respond(approvalID: card.request.id, decision: .allowForSession) }
                    .buttonStyle(T3ButtonStyle(palette: p, variant: .outline))
                Button("Deny") { controller.respond(approvalID: card.request.id, decision: .deny) }
                    .buttonStyle(T3ButtonStyle(palette: p, variant: .outline))
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
        let text = trimmedInput
        guard canSend, let projectURL else { return }
        input = ""
        if controller.thread?.isAlive == true {
            controller.send(text)
            return
        }
        Task {
            await controller.start(kind: agent, projectDir: projectURL, model: model, resume: resume)
            if controller.thread?.isAlive == true { controller.send(text) } else { input = text }
        }
    }

    private func switchAgent(_ kind: AgentCLIKind) {
        guard kind != agent else { return }
        agentRaw = kind.rawValue
        model = ""
        controller.stop()
    }

    private func switchModel(_ id: String) {
        guard id != model else { return }
        model = id
        // The model is fixed per session; the next send starts a new one.
        if controller.thread != nil, !isTurnActive { controller.stop() }
    }

    private func selectProject(_ path: String) {
        guard path != projectPath else { return }
        DevPrefs.remember(project: path)
        projectPath = path
        controller.stop()
        terminalGeneration += 1
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        panel.message = "Choose the folder \(agent.displayName) works in"
        if let projectURL { panel.directoryURL = projectURL }
        if panel.runModal() == .OK, let url = panel.url {
            selectProject(url.path)
        }
    }
}

// MARK: - Models

/// The models offered in Dev mode's model menu, so nobody types a model ID.
enum DevModelCatalog {
    typealias Model = (id: String, name: String)

    /// Claude Code accepts these aliases for the current models.
    static let claudeModels: [Model] = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]

    static func models(for kind: AgentCLIKind) -> [Model] {
        switch kind {
        case .claudeCode: return claudeModels
        case .codex: return codexModels()
        }
    }

    /// Codex keeps the models it offers in ~/.codex/models_cache.json; empty when it has not run yet.
    static func codexModels(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Model] {
        guard let data = try? Data(contentsOf: home.appending(path: ".codex/models_cache.json")) else { return [] }
        return parseCodexModels(data)
    }

    static func parseCodexModels(_ data: Data) -> [Model] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let list)? = root["models"] else { return [] }
        return list.compactMap { m in
            guard let slug = m["slug"]?.stringValue, m["visibility"]?.stringValue != "hide" else { return nil }
            return (slug, m["display_name"]?.stringValue ?? slug)
        }
    }

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
    let palette: T3Palette
    @State private var expanded = DevPanelView.snapshotExpand
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if !card.output.isEmpty { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    icon.frame(width: 22, height: 22)
                    (Text(card.name).foregroundStyle(palette.mutedForeground)
                     + Text("  " + card.summary)
                        .font(.system(size: T3Metrics.textSm - 1.5, design: .monospaced))
                        .foregroundStyle(palette.foreground.opacity(hovering ? 0.95 : 0.8)))
                        .font(.system(size: T3Metrics.textSm))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if !card.output.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(palette.mutedForeground.opacity(hovering || expanded ? 1 : 0.6))
                    }
                }
                .frame(minHeight: 26)
                .padding(.horizontal, 2)
                .background(RoundedRectangle(cornerRadius: T3Metrics.radiusMd).fill(hovering && !card.output.isEmpty ? palette.accent : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(card.summary)
            .accessibilityLabel("\(card.name): \(card.summary), \(statusText)")
            .accessibilityHint(card.output.isEmpty ? "" : (expanded ? "Hides the output" : "Shows the output"))
            if expanded {
                ScrollView {
                    Text(card.output)
                        .font(.system(size: T3Metrics.textXs - 0.5, design: .monospaced))
                        .foregroundStyle(palette.foreground.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: T3Metrics.radiusLg).fill(palette.muted))
                .overlay(RoundedRectangle(cornerRadius: T3Metrics.radiusLg).strokeBorder(palette.border))
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
    let palette: T3Palette

    var body: some View {
        Text(parts.joined(separator: " · "))
            .font(.system(size: T3Metrics.textXs))
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
    let palette: T3Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 12))
                Text(message)
                    .font(.system(size: T3Metrics.textXs + 0.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(palette.errorForeground)
            if !detail.isEmpty {
                ScrollView {
                    Text(detail)
                        .font(.system(size: T3Metrics.text2xs, design: .monospaced))
                        .foregroundStyle(palette.foreground.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .fixedSize(horizontal: false, vertical: true)
                .background(RoundedRectangle(cornerRadius: T3Metrics.radiusMd).fill(palette.background.opacity(0.6)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: T3Metrics.radiusLg, style: .continuous).fill(palette.errorSurface))
        .overlay(RoundedRectangle(cornerRadius: T3Metrics.radiusLg, style: .continuous)
            .strokeBorder(palette.error.opacity(0.25)))
    }
}

/// T3's status pulse for the live "Working for" line.
private struct PulsingDot: View {
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

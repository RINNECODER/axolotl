import AppKit
import SwiftUI

/// Dev mode: drive Claude Code or Codex in a project folder from the AI panel.
///
/// The layout and styling mirror T3 Code's chat (https://github.com/pingdotgg/t3code, MIT License):
/// a breadcrumb header (project / thread), a timeline of user bubbles, assistant prose and folded
/// work-log rows, approvals inside the composer, and a rounded composer with the harness, model and
/// effort dropdowns (`DevDropdown`) in its footer. Chat | Terminal is a segmented control in the
/// header; the project is picked from the header. ⌘↩ sends, Esc stops.
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
    @AppStorage(DevPrefs.effortKey) private var effort: String = ""
    @AppStorage(DevPrefs.terminalKey) private var terminalMode: Bool = false

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var controller = DevSessionController.shared
    @State private var settings = DevSettings.shared
    @State private var input = ""
    @State private var editorHeight: CGFloat = 36
    @State private var terminalGeneration = 0
    @State private var expandedGroups: Set<Int> = []
    @State private var turnStartedAt: Date?
    /// "Worked for" durations, keyed by the index of the turn's user message.
    @State private var turnDurations: [Int: TimeInterval] = [:]
    /// The open dropdown ("harness", "model", "effort", "project", "projectHero"), if any.
    @State private var openDropdown: String?
    @State private var harnesses: [HarnessInfo] = []
    @State private var listing: ModelListing?
    @State private var modelsLoading = false
    @State private var modelError: String?
    @State private var resumeOffer: DevResumeOffer?
    @State private var projectSessions: [ExternalSession] = []
    @State private var showingSessions = false
    @Namespace private var viewSwitchNS
    @FocusState private var inputFocused: Bool

    /// New panels apply Settings → Dev defaults (harness, terminal) once per launch.
    @MainActor private static var appliedLaunchDefaults = false

    private var p: T3Palette { .of(scheme) }
    private var agent: AgentCLIKind { AgentCLIKind(rawValue: agentRaw) ?? .claudeCode }
    private var projectURL: URL? { projectPath.isEmpty ? nil : URL(fileURLWithPath: projectPath, isDirectory: true) }
    private var projectName: String? { projectURL?.lastPathComponent }
    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTurnActive: Bool { controller.thread?.isTurnActive == true }
    private var models: [HarnessModel] { listing?.harness == agent.harnessID ? listing?.models ?? [] : [] }
    private var currentModel: HarnessModel? { DevComposerSelection.current(model: model, in: models) }
    private var currentEffort: String? { DevComposerSelection.effectiveEffort(effort, for: currentModel) }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.2) }

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
                } else {
                    VStack(spacing: 0) {
                        threadArea
                        composer
                    }
                    .transition(.opacity)
                }
            }
            .animation(motion, value: terminalMode)
        }
        .background(p.background)
        .devDropdownHost()
        .onAppear {
            applyLaunchDefaults()
            if controller.installed.isEmpty { controller.refreshInstalled() }
            if isTurnActive, turnStartedAt == nil { turnStartedAt = Date() }
            #if DEBUG
            snapshotHooks()
            #endif
        }
        .task { harnesses = await HarnessCatalog.shared.discover() }
        .task(id: agent) { await loadModels(refresh: false) }
        .task(id: "\(projectPath)|\(controller.thread == nil)|\(settings.liveSyncEnabled)") { await watchSessions() }
        .onChange(of: terminalMode) { _, _ in openDropdown = nil }
        .onChange(of: settings.defaultHarness) { _, kind in
            if controller.thread == nil { adoptHarness(kind) }
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

    private func applyLaunchDefaults() {
        guard !Self.appliedLaunchDefaults else { return }
        Self.appliedLaunchDefaults = true
        guard controller.thread == nil else { return }
        if settings.showTerminalByDefault { terminalMode = true }
        // The last harness used wins; the default only applies before the first pick.
        if UserDefaults.standard.object(forKey: DevPrefs.agentKey) == nil { adoptHarness(settings.defaultHarness) }
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
                        controller.respond(approvalID: pending.card.request.id, decision: .allow)
                        return
                    }
                }
            }
        }
        // Screenshots: open one of the dropdowns ("harness", "model", "effort", "project") or the sessions list.
        if let open = env["LUNA_SNAPSHOT_DEV_OPEN"] {
            Task {
                try? await Task.sleep(for: .seconds(Double(env["LUNA_SNAPSHOT_DEV_OPEN_AFTER"] ?? "") ?? 2))
                switch open {
                case "sessions": showingSessions = true
                case "follow": if let resumeOffer { self.open(resumeOffer) }
                default: openDropdown = open
                }
            }
        }
    }
    #endif

    // MARK: - Header (T3's ChatHeader: project badge / thread title, icon controls on the right)

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                modeSwitch
                Spacer(minLength: 4)
                if controller.isMirroring { mirroringBadge }
                T3IconButton(systemName: "square.and.pencil", help: "New thread", palette: p) { newThread() }
                T3IconButton(systemName: "xmark", help: "Close (Esc)", palette: p) {
                    // Esc stops a running turn before it closes the panel.
                    if isTurnActive { controller.interrupt() } else { onClose() }
                }
                // The raw terminal needs Esc (it interrupts the CLI); an open dropdown takes it too.
                .keyboardShortcut(terminalMode || openDropdown != nil ? nil : KeyboardShortcut(.escape, modifiers: []))
            }
            .frame(height: 38)
            HStack(spacing: 4) {
                projectDropdown(id: "project", edge: .below) {
                    HStack(spacing: 6) {
                        if projectName != nil { projectBadge }
                        Text(projectName ?? "Choose project")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(projectName == nil ? p.mutedForeground : p.foreground)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(p.mutedForeground)
                    }
                    .padding(.horizontal, 4)
                    .frame(height: 26)
                    .contentShape(Rectangle())
                }
                .fixedSize()
                .layoutPriority(1)
                .accessibilityLabel("Project: \(projectName ?? "none")")
                Text("/").font(.system(size: 13)).foregroundStyle(p.mutedForeground.opacity(0.7))
                Text(threadTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(p.foreground.opacity(controller.thread == nil ? 0.55 : 0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(threadTitle)
                Spacer(minLength: 6)
                viewSwitch
            }
            .frame(height: 36)
            .padding(.bottom, 2)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(p.border).frame(height: 1) }
    }

    /// Chat | Terminal as a labeled segmented control (T3's toggle group).
    private var viewSwitch: some View {
        HStack(spacing: 0) {
            ForEach([false, true], id: \.self) { terminal in
                let selected = terminalMode == terminal
                Button {
                    guard terminalMode != terminal else { return }
                    withAnimation(motion) { terminalMode = terminal }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: terminal ? "terminal" : "bubble.left")
                            .font(.system(size: 10.5, weight: .medium))
                        Text(terminal ? "Terminal" : "Chat")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(selected ? p.foreground : p.mutedForeground)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: T3Metrics.radiusSm, style: .continuous)
                                .fill(p.isDark ? Color.white.opacity(0.09) : Color.white)
                                .shadow(color: .black.opacity(p.isDark ? 0 : 0.08), radius: 1.5, y: 0.5)
                                .matchedGeometryEffect(id: "viewSwitch", in: viewSwitchNS)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(terminal ? "Run \(agent.executableName) in a terminal" : "Chat with \(agent.displayName)")
                .accessibilityLabel(terminal ? "Terminal" : "Chat")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: T3Metrics.radiusMd, style: .continuous)
            .fill(p.isDark ? Color.white.opacity(0.03) : Color(hex: 0xF4F4F5)))
        .overlay(RoundedRectangle(cornerRadius: T3Metrics.radiusMd, style: .continuous).strokeBorder(p.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("View")
    }

    private var mirroringBadge: some View {
        HStack(spacing: 5) {
            if controller.isReadOnly { PulsingDot(color: p.success) } else {
                Image(systemName: "eye").font(.system(size: 9.5, weight: .medium))
            }
            Text("Mirroring")
        }
        .font(.system(size: T3Metrics.text2xs, weight: .medium))
        .foregroundStyle(p.mutedForeground)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .overlay(Capsule().strokeBorder(p.border.opacity(p.isDark ? 1.5 : 1), lineWidth: 1))
        .help(controller.isReadOnly
              ? "Showing a session that is live in a terminal (read-only)"
              : "Showing a terminal session; sending a message continues it in Luna")
        .accessibilityElement(children: .combine)
    }

    private var threadTitle: String {
        if let thread = controller.thread {
            for item in thread.items {
                if case .user(let text) = item {
                    return text.split(separator: "\n").first.map(String.init) ?? text
                }
            }
        }
        if let mirror = controller.mirror, !mirror.title.isEmpty { return mirror.title }
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

    /// Project picker: recent projects by name, then "Open folder…".
    private func projectDropdown<L: View>(id: String, edge: DevDropdownEdge, @ViewBuilder label: @escaping () -> L) -> some View {
        var items = DevPrefs.recentProjects().map { path in
            DevDropdownItem(id: path, title: (path as NSString).lastPathComponent,
                            subtitle: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath,
                            icon: "folder", section: "Recent", keywords: [path])
        }
        items.append(DevDropdownItem(id: "__open", title: "Open folder…", icon: "folder.badge.plus", role: .action))
        return DevDropdown(isOpen: dropdownBinding(id), items: items, selectedID: projectPath, palette: p, edge: edge,
                           width: 280, help: "Project", onSelect: { item in
            if item.id == "__open" { chooseFolder() } else { selectProject(item.id) }
        }, label: label)
    }

    // MARK: - Terminal

    @ViewBuilder
    private var terminalArea: some View {
        if let projectURL, controller.isInstalled(agent) != false {
            VStack(spacing: 0) {
                DevTerminalView(kind: agent, projectDir: projectURL, isDark: p.isDark)
                    .id("\(agent.rawValue)|\(projectPath)|\(terminalGeneration)")
                    .padding(8)
                    .background(p.card)
                    .clipShape(RoundedRectangle(cornerRadius: T3Metrics.radiusLg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: T3Metrics.radiusLg, style: .continuous).strokeBorder(p.border))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("\(agent.displayName) terminal")
                HStack(spacing: 6) {
                    harnessDropdown
                    Spacer(minLength: 4)
                    Text("Esc and arrows go to \(agent.executableName)")
                        .font(.system(size: T3Metrics.text2xs))
                        .foregroundStyle(p.mutedForeground)
                        .lineLimit(1)
                }
                .padding(.top, 6)
            }
            .padding(10)
        } else {
            VStack(spacing: 10) {
                Text(projectURL == nil
                     ? "Choose a project to open \(agent.executableName) in a terminal."
                     : "Install \(agent.executableName) to use the terminal.")
                    .font(.system(size: T3Metrics.textSm))
                    .foregroundStyle(p.mutedForeground)
                    .multilineTextAlignment(.center)
                if projectURL == nil {
                    Button("Open folder…") { chooseFolder() }
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

    /// T3's draft hero: one quiet headline with the project as a dotted-underline picker, under a
    /// "Continue" row for the project's most recent session.
    private var emptyState: some View {
        VStack(spacing: 0) {
            if let resumeOffer, !showingSessions {
                resumeRow(resumeOffer)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showingSessions {
                sessionsList
                    .transition(.opacity)
            } else {
                hero
                    .transition(.opacity)
            }
        }
        .animation(motion, value: showingSessions)
        .animation(motion, value: resumeOffer)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var hero: some View {
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
                 : approvalSummary)
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

    private var approvalSummary: String {
        switch settings.approvalBehavior {
        case .ask: return "Commands and file edits ask first."
        case .allowEdits: return "File edits run without asking; commands ask first."
        case .fullAuto: return "Full auto: commands and edits run without asking."
        }
    }

    @ViewBuilder
    private var heroText: some View {
        if let projectName {
            Text("What should we build in").foregroundStyle(p.foreground)
            projectDropdown(id: "projectHero", edge: .below) { heroSelector(projectName + "?") }
                .fixedSize()
        } else {
            projectDropdown(id: "projectHero", edge: .below) { heroSelector("Choose a project") }
                .fixedSize()
            Text("to start").foregroundStyle(p.foreground)
        }
    }

    // MARK: - Resume

    /// "Continue <title>" over "Claude Code · 12 min ago · from Terminal", with Resume, and
    /// "All sessions" under it.
    private func resumeRow(_ offer: DevResumeOffer) -> some View {
        let s = offer.session
        return VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: T3Metrics.radiusMd, style: .continuous)
                        .fill(Self.providerColor(s.harness).opacity(p.isDark ? 0.18 : 0.12))
                    Image(systemName: Self.providerIcon(s.harness))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Self.providerColor(s.harness))
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Continue  ").foregroundStyle(p.mutedForeground)
                     + Text(s.title.isEmpty ? "Last session" : s.title).foregroundStyle(p.foreground))
                        .font(.system(size: T3Metrics.textXs, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 5) {
                        if s.isLive { PulsingDot(color: p.success) }
                        Text(DevResumeOffer.caption(harness: s.harness, updatedAt: s.updatedAt,
                                                    startedInLuna: s.startedInLuna, isLive: s.isLive))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: T3Metrics.text2xs))
                    .foregroundStyle(s.isLive ? p.success : p.mutedForeground)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(offer.action == .follow ? "Follow" : "Resume") { open(offer) }
                    .buttonStyle(T3ButtonStyle(palette: p, variant: offer.action == .unavailable ? .outline : .primary))
                    .disabled(offer.action == .unavailable)
                    .opacity(offer.action == .unavailable ? 0.5 : 1)
                    .help(offer.action == .unavailable
                          ? "Live in a terminal. Turn on Live session sync in Settings → Dev to follow it."
                          : offer.action == .follow ? "Show this live session read-only" : "Continue this session in Luna")
            }
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: T3Metrics.radiusLg + 2, style: .continuous).fill(p.card))
            .overlay(RoundedRectangle(cornerRadius: T3Metrics.radiusLg + 2, style: .continuous).strokeBorder(p.border, lineWidth: 1))
            .shadow(color: .black.opacity(p.isDark ? 0 : 0.05), radius: 6, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Continue \(s.title)")
            Button { showingSessions = true } label: {
                HStack(spacing: 3) {
                    Text(listedSessions.count > 1 ? "All sessions (\(listedSessions.count))" : "All sessions")
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                }
                .font(.system(size: T3Metrics.text2xs, weight: .medium))
                .padding(.horizontal, 6)
                .frame(height: 20)
            }
            .buttonStyle(T3GhostButtonStyle(palette: p, radius: T3Metrics.radiusSm))
            .accessibilityLabel("Show all sessions")
        }
    }

    private var listedSessions: [ExternalSession] {
        DevResumeOffer.listed(projectSessions, liveSync: settings.liveSyncEnabled)
    }

    /// Every session of this project (live dots first-class), from "Show all".
    private var sessionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button { showingSessions = false } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 24, height: 24)
                }
                .buttonStyle(T3GhostButtonStyle(palette: p, radius: T3Metrics.radiusSm))
                .accessibilityLabel("Back")
                Text("Sessions in \(projectName ?? "project")")
                    .font(.system(size: T3Metrics.textSm, weight: .medium))
                    .foregroundStyle(p.foreground)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if settings.liveSyncEnabled {
                    Text("Live sync on")
                        .font(.system(size: T3Metrics.text2xs, weight: .medium))
                        .foregroundStyle(p.success)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            Rectangle().fill(p.border).frame(height: 1)
            if listedSessions.isEmpty {
                Text(settings.liveSyncEnabled ? "No sessions yet for this project."
                     : "No Luna sessions yet. Turn on Live session sync in Settings → Dev to see terminal sessions too.")
                    .font(.system(size: T3Metrics.textXs))
                    .foregroundStyle(p.mutedForeground)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(listedSessions) { s in sessionRow(s) }
                    }
                    .padding(6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func sessionRow(_ s: ExternalSession) -> some View {
        Button { open(s) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Group {
                    if s.isLive { PulsingDot(color: p.success) } else {
                        Circle().fill(p.mutedForeground.opacity(0.35)).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title.isEmpty ? "Untitled session" : s.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(p.foreground)
                        .lineLimit(1)
                    Text(DevResumeOffer.caption(harness: s.harness, updatedAt: s.updatedAt,
                                                startedInLuna: s.startedInLuna, isLive: s.isLive))
                        .font(.system(size: T3Metrics.text2xs))
                        .foregroundStyle(s.isLive ? p.success : p.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("\(s.messageCount)")
                    .font(.system(size: T3Metrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .monospacedDigit()
                    .help("\(s.messageCount) messages")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(T3GhostButtonStyle(palette: p, radius: T3Metrics.radiusMd))
        .disabled(s.isLive && !settings.liveSyncEnabled)
        .help(s.isLive ? (settings.liveSyncEnabled ? "Follow this live session read-only" : "Live in a terminal")
              : "Resume this session in Luna")
        .accessibilityLabel("\(s.title), \(s.harness.displayName)\(s.isLive ? ", live in terminal" : "")")
    }

    /// Polls this project's sessions while the thread is empty (live dots go stale otherwise).
    private func watchSessions() async {
        guard let projectURL, controller.thread == nil else { resumeOffer = nil; return }
        while !Task.isCancelled {
            let excluding = Set([controller.activeSessionID].compactMap { $0 })
            let found = await SessionSync.shared.sessions(projectDir: projectURL, excluding: excluding, limit: 30)
            var best = DevResumeOffer.listed(found, liveSync: settings.liveSyncEnabled).first.map {
                ResumableSession(harness: $0.harness, id: $0.id, title: $0.title, updatedAt: $0.updatedAt,
                                 startedInLuna: $0.startedInLuna, isLive: $0.isLive)
            }
            if best == nil { best = await SessionSync.shared.mostRecentResumable(projectDir: projectURL, excluding: excluding) }
            guard !Task.isCancelled else { return }
            projectSessions = found
            resumeOffer = DevResumeOffer.make(best, liveSync: settings.liveSyncEnabled, activeSessionID: controller.activeSessionID)
            try? await Task.sleep(for: .seconds(8))
        }
    }

    private func open(_ offer: DevResumeOffer) {
        if let external = projectSessions.first(where: { $0.id == offer.session.id }) {
            open(external)
        } else if offer.action == .resume, let projectURL {
            resume(kind: offer.session.harness, id: offer.session.id, projectDir: projectURL)
        }
    }

    /// Live (sync on): mirror read-only. Otherwise resume it, keeping its history when sync can read it.
    private func open(_ s: ExternalSession) {
        showingSessions = false
        adoptHarness(s.harness)
        if s.isLive {
            guard settings.liveSyncEnabled else { return }
            controller.mirror(s)
        } else if settings.liveSyncEnabled {
            controller.mirror(s)
            Task {
                // Let the mirror read the history first, so it stays on screen after the take-over.
                for _ in 0..<20 where controller.thread?.items.isEmpty ?? true {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await controller.takeOver(model: model.isEmpty ? nil : model)
            }
        } else {
            resume(kind: s.harness, id: s.id, projectDir: s.projectDir)
        }
    }

    private func resume(kind: AgentCLIKind, id: String, projectDir: URL) {
        adoptHarness(kind)
        Task {
            await controller.start(kind: kind, projectDir: projectDir, model: model.isEmpty ? nil : model,
                                   resumeID: id, effort: currentEffort)
        }
    }

    /// Points the pickers at `kind` without stopping anything.
    private func adoptHarness(_ kind: AgentCLIKind) {
        guard kind != agent else { return }
        let next = DevComposerSelection(harness: agent, model: model, effort: effort)
            .switching(to: kind, defaultModel: settings.defaultModel(for:))
        agentRaw = next.harness.rawValue
        model = next.model
        effort = next.effort
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

    @ViewBuilder
    private var composer: some View {
        if controller.isReadOnly {
            liveBar
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 4)
                .transition(.opacity)
        } else {
            editableComposer
        }
    }

    /// Replaces the composer while a mirrored session is live in a terminal.
    private var liveBar: some View {
        HStack(spacing: 10) {
            PulsingDot(color: p.success)
            VStack(alignment: .leading, spacing: 1) {
                Text("Live in Terminal")
                    .font(.system(size: T3Metrics.textXs, weight: .medium))
                    .foregroundStyle(p.foreground)
                Text("Read-only while \(controller.mirror?.harness.executableName ?? "the CLI") is writing it.")
                    .font(.system(size: T3Metrics.text2xs))
                    .foregroundStyle(p.mutedForeground)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Take over") { Task { await controller.takeOver(model: nil) } }
                .buttonStyle(T3ButtonStyle(palette: p, variant: .primary))
                .help("Continue it in Luna. If the terminal keeps going too, the two histories diverge.")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: T3Metrics.radius2xl, style: .continuous).fill(p.card))
        .overlay(RoundedRectangle(cornerRadius: T3Metrics.radius2xl, style: .continuous).strokeBorder(p.composerOutline, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var editableComposer: some View {
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
            harnessDropdown
            modelDropdown
            if agent == .codex, let efforts = currentModel?.efforts, !efforts.isEmpty { effortDropdown(efforts) }
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
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
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
                           dimmed: controller.isInstalled(agent) == false, palette: p)
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
        let label = Self.shortModelName(currentModel?.displayName ?? (model.isEmpty ? (modelsLoading ? "Loading…" : "Default") : model))
        return DevDropdown(isOpen: dropdownBinding("model"), items: modelItems,
                           selectedID: currentModel?.id ?? (model.isEmpty ? nil : model),
                           palette: p, width: 300, footnote: modelFootnote, help: "Model for the next session",
                           onSelect: { item in
            if item.id == "__refresh" { Task { await loadModels(refresh: true) } } else { switchModel(item.id) }
        }) {
            DevPickerLabel(text: label, dimmed: controller.isInstalled(agent) == false, maxTextWidth: 130, palette: p)
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

    /// T3's context strip under the composer: approval mode on the left, session state on the right.
    private var contextStrip: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: settings.approvalBehavior == .fullAuto ? "exclamationmark.shield" : "checkmark.shield")
                    .font(.system(size: 10))
                Text(settings.approvalBehavior == .ask ? "Ask first" : settings.approvalBehavior.displayName)
            }
            .font(.system(size: T3Metrics.text2xs))
            .foregroundStyle(settings.approvalBehavior == .fullAuto ? p.warningForeground : p.mutedForeground)
            .help("Approval behavior (Settings → Dev)")
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
            await controller.start(kind: agent, projectDir: projectURL, model: model, resumeID: nil, effort: currentEffort)
            if controller.thread?.isAlive == true { controller.send(text) } else { input = text }
        }
    }

    private func switchAgent(_ kind: AgentCLIKind) {
        guard kind != agent else { return }
        let next = DevComposerSelection(harness: agent, model: model, effort: effort)
            .switching(to: kind, defaultModel: settings.defaultModel(for:))
        agentRaw = next.harness.rawValue
        model = next.model
        effort = next.effort
        controller.stop()
    }

    private func switchModel(_ id: String) {
        guard id != model else { return }
        let next = DevComposerSelection(harness: agent, model: model, effort: effort).picking(model: id, in: models)
        model = next.model
        effort = next.effort
        // The model is fixed per session; the next send starts a new one.
        if controller.thread != nil, !isTurnActive, !controller.isMirroring { controller.stop() }
    }

    private func switchEffort(_ value: String) {
        guard value != currentEffort else { return }
        effort = value
        if controller.thread != nil, !isTurnActive, !controller.isMirroring { controller.stop() }
    }

    private func newThread() {
        controller.stop()
        showingSessions = false
        input = ""
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

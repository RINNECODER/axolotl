import Foundation
import Observation

/// What Dev mode shows, kept outside the panel view so closing / reopening the panel (or
/// switching General ↔ Dev) keeps the open session, the home view's choices and the shell.
///
/// - `session == nil` → the home view (`flow` steps). The Terminal tab is `shell`, a login shell
///   in the chosen project (or ~).
/// - `session != nil` → Chat and Terminal both show that `DevSession` (`session.openTerminal()`).
@MainActor
@Observable
final class DevWorkspace {
    static let shared = DevWorkspace()

    var session: DevSession?
    var flow = DevHomeFlow()
    var showingAllSessions = false
    /// The home view's Terminal tab.
    let shell = DevTerminalController()

    private(set) var projects: [DevProject] = []
    private(set) var projectsLoaded = false
    /// Newest sessions across all projects ("All sessions", "Continue last").
    private(set) var recentSessions: [ExternalSession] = []
    private(set) var recentLoaded = false
    /// Per project path, newest first.
    private(set) var projectSessions: [String: [ExternalSession]] = [:]
    /// How long the last `allSessions` call took (ms), for diagnostics.
    private(set) var lastSessionsLoadMS: Int?
    @ObservationIgnored private var launched = false

    static let recentLimit = 30

    var isTurnActive: Bool { session?.timeline.isTurnActive == true }

    func interrupt() { session?.interrupt() }

    // MARK: Loading

    func loadProjects(refresh: Bool = false) async {
        let found = await ProjectFinder.shared.projects(refresh: refresh)
        projects = found.filter { !DevSettings.shared.isHidden($0.path) }
        projectsLoaded = true
    }

    func loadRecentSessions() async {
        let start = Date()
        let found = await SessionSync.shared.allSessions(limit: Self.recentLimit)
        lastSessionsLoadMS = Int(Date().timeIntervalSince(start) * 1000)
        recentSessions = found
        recentLoaded = true
    }

    func loadSessions(project path: String) async {
        let found = await SessionSync.shared.sessions(projectDir: URL(fileURLWithPath: path, isDirectory: true), limit: 30)
        projectSessions[path] = found
    }

    func hide(project path: String) {
        DevSettings.shared.hideProject(path)
        projects.removeAll { $0.path == path }
        if flow.project == path { flow.edit(.project) }
    }

    /// The newest session to offer as "Continue last".
    var continueLast: ExternalSession? {
        recentSessions.first { !DevSettings.shared.isHidden($0.projectDir.path) }
    }

    // MARK: Navigation

    /// Applies Settings → Dev → Skip home once per launch (the first time Dev shows).
    func launchIfNeeded(installed: Set<AgentCLIKind>) async {
        guard !launched else { return }
        launched = true
        let settings = DevSettings.shared
        let lastProject = UserDefaults.standard.string(forKey: DevPrefs.projectKey)
        let setup = settings.defaultSetup
        if !settings.skipHome {
            if flow.project == nil, let path = setup.projectPath(), !path.isEmpty {
                flow = DevHomeFlow(project: path, setup: setup, installed: installed)
            }
            return
        }
        var newest: [String: DevSessionRef] = [:]
        if let path = setup.projectPath(), !path.isEmpty {
            await loadSessions(project: path)
            if let s = projectSessions[path]?.first { newest[path] = s.ref }
        }
        switch DevLaunch.resolve(skipHome: true, setup: setup, lastProject: lastProject,
                                 lastSession: { newest[$0] }, installed: installed) {
        case .home:
            break
        case .resume(let ref):
            if let s = projectSessions[ref.projectDir.path]?.first(where: { $0.id == ref.id }) { open(s) }
        case .new(let kind, let dir, let s):
            startNew(harness: kind, projectDir: dir, setup: s)
        }
    }

    /// Opens an existing session (history, live mirror or resume on send).
    func open(_ external: ExternalSession) {
        var setup = DevSettings.shared.defaultSetup
        setup.project = .specific(external.projectDir.path)
        session = DevSessions.shared.session(for: external, setup: setup)
        remember(project: external.projectDir.path, harness: external.harness)
        showingAllSessions = false
    }

    func startNew(harness: AgentCLIKind, projectDir: URL, setup: DevSessionSetup) {
        session = DevSessions.shared.newSession(harness: harness, projectDir: projectDir, setup: setup)
        remember(project: projectDir.path, harness: harness)
        showingAllSessions = false
    }

    /// Back to the home view. `project` pre-selects a project (header project picker).
    func goHome(project: String? = nil) {
        let current = session
        session = nil
        showingAllSessions = false
        var next = DevHomeFlow()
        if let path = project ?? current?.projectDir.path {
            next.choose(project: path)
            if let current, project == nil || project == current.projectDir.path {
                next.choose(harness: current.harness)
            }
        }
        flow = next
    }

    private func remember(project path: String, harness: AgentCLIKind) {
        DevPrefs.remember(project: path)
        UserDefaults.standard.set(path, forKey: DevPrefs.projectKey)
        UserDefaults.standard.set(harness.rawValue, forKey: DevPrefs.agentKey)
    }

    // MARK: Terminal tab

    /// What the Terminal tab shows (set by `prepareTerminalTab`): the session's CLI, or the home
    /// shell. nil when the session cannot take a terminal yet (live elsewhere, or a headless
    /// turn is running).
    private(set) var tabTerminal: DevTerminalController?

    /// Points the Terminal tab at the right program (`DevTerminalPlan`): on the home view a
    /// login shell in the chosen project (or ~); with a session, `session.openTerminal()`
    /// (`.resume` once it has an id, else `.newSession` with its setup).
    func prepareTerminalTab(restart: Bool = false) {
        if let session {
            // An exited CLI stays on screen (with Restart) instead of relaunching by itself.
            if let t = session.terminal, !t.isRunning, !restart {
                tabTerminal = t
                return
            }
            tabTerminal = session.openTerminal() ?? (session.terminal?.isRunning == true ? session.terminal : nil)
            return
        }
        let dir = flow.project.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let mode = DevTerminalPlan.mode(session: nil, newSetup: nil, projectDir: dir)
        if restart || !shell.isRunning || shell.currentMode != mode { shell.open(mode) }
        tabTerminal = shell
    }
}

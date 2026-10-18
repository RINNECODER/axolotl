import Foundation

/// The Dev home view's step-by-step choice: project, harness, model / effort, then a session
/// (resume one, or start a new one). Pure state; `DevHomeView` renders it.
///
///     var flow = DevHomeFlow()
///     flow.choose(project: "/work/app")      // step: .harness
///     flow.choose(harness: .claudeCode)      // step: .model
///     flow.chooseModel("haiku", effort: nil) // step: .session
///     flow.edit(.harness)                    // back to .harness, model cleared
nonisolated struct DevHomeFlow: Equatable, Sendable {
    enum Step: Int, CaseIterable, Comparable, Sendable {
        case project, harness, model, session
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .project: return "Project"
            case .harness: return "Harness"
            case .model: return "Model"
            case .session: return "Session"
            }
        }
    }

    private(set) var project: String?
    private(set) var harness: AgentCLIKind?
    /// nil = the harness's default model.
    private(set) var model: String?
    private(set) var effort: String?
    private(set) var modelChosen = false

    init() {}

    /// Starts at the first unanswered step, with the defaults from `setup` pre-selected
    /// (`project` resolved by the caller; nil leaves the project step open).
    init(project: String?, setup: DevSessionSetup, installed: Set<AgentCLIKind>) {
        self.project = project
        if project != nil, installed.contains(setup.harness) || installed.isEmpty { harness = setup.harness }
        model = setup.model
        effort = setup.effort
    }

    var step: Step {
        if project == nil { return .project }
        if harness == nil { return .harness }
        if !modelChosen { return .model }
        return .session
    }

    mutating func choose(project path: String) {
        guard path != project else { if step == .project { modelChosen = false }; return }
        project = path
        modelChosen = false
    }

    mutating func choose(harness kind: AgentCLIKind) {
        if kind != harness {
            model = nil
            effort = nil
        }
        harness = kind
        modelChosen = false
    }

    mutating func chooseModel(_ id: String?, effort: String?) {
        model = id
        self.effort = effort
        modelChosen = true
    }

    /// Goes back to `step`, clearing it and every later choice (the earlier ones stay).
    mutating func edit(_ step: Step) {
        switch step {
        case .project:
            project = nil
            harness = nil
            model = nil
            effort = nil
            modelChosen = false
        case .harness:
            harness = nil
            model = nil
            effort = nil
            modelChosen = false
        case .model:
            modelChosen = false
        case .session:
            break
        }
    }

    mutating func back() {
        switch step {
        case .project: break
        case .harness: edit(.project)
        case .model: edit(.harness)
        case .session: edit(.model)
        }
    }

    /// The setup a "New session" from here starts with.
    func setup(base: DevSessionSetup) -> DevSessionSetup? {
        guard let harness, let project else { return nil }
        var s = base
        s.harness = harness
        s.model = model
        s.effort = effort
        s.project = .specific(project)
        return s
    }
}

/// What entering Dev opens: the home view, or (Settings → Dev → Skip home) straight into the
/// last session or a new one with the default setup.
nonisolated enum DevLaunch: Equatable, Sendable {
    case home
    case resume(DevSessionRef)
    case new(AgentCLIKind, projectDir: URL, setup: DevSessionSetup)

    /// - Parameters:
    ///   - lastProject: Luna's last Dev project (`DevPrefs.projectKey`), for `.last`.
    ///   - lastSession: newest session in the resolved project (any harness), if any.
    ///   - installed: installed harnesses; empty = unknown yet (trust the setup).
    static func resolve(skipHome: Bool, setup: DevSessionSetup, lastProject: String?,
                        lastSession: (String) -> DevSessionRef?, installed: Set<AgentCLIKind>) -> DevLaunch {
        guard skipHome else { return .home }
        let path: String?
        switch setup.project {
        case .last: path = lastProject
        case .specific(let p): path = p
        }
        guard let path, !path.isEmpty else { return .home }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        if let ref = lastSession(path), installed.isEmpty || installed.contains(ref.harness) { return .resume(ref) }
        var harness = setup.harness
        if !installed.isEmpty, !installed.contains(harness) {
            guard let other = AgentCLIKind.allCases.first(where: installed.contains) else { return .home }
            harness = other
        }
        var s = setup
        if harness != setup.harness {
            s.harness = harness
            s.model = nil
            s.effort = nil
        }
        return .new(harness, projectDir: dir, setup: s)
    }
}

/// Which program the Terminal tab runs: a login shell on the home view, the session's CLI
/// (resumed) once a session is chosen, or a new CLI session when only a setup is chosen.
nonisolated enum DevTerminalPlan {
    static func mode(session: DevSessionRef?, newSetup: DevSessionSetup?, projectDir: URL?) -> DevTerminalMode {
        if let session { return .resume(session) }
        if let newSetup, let projectDir { return .newSession(newSetup.harness, newSetup, projectDir: projectDir) }
        return .shell(projectDir)
    }
}

/// "12 min ago"-style times for session and project rows.
nonisolated enum DevRelativeTime {
    static func string(_ date: Date, now: Date = Date()) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 60 { return "now" }
        if s < 3_600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3_600))h ago" }
        if s < 7 * 86_400 { return "\(Int(s / 86_400))d ago" }
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

import AppKit
import Foundation
import Observation

/// Dev mode settings, shared by the panel views (UserDefaults keys).
nonisolated enum DevPrefs {
    static let panelModeKey = "luna_ai_panel_mode"
    static let agentKey = "luna_dev_agent"
    static let projectKey = "luna_dev_project"
    static let recentProjectsKey = "luna_dev_recent_projects"
    static let modelKey = "luna_dev_model"
    static let resumeKey = "luna_dev_resume"
    static let terminalKey = "luna_dev_terminal"
    static let effortKey = "luna_dev_effort"

    static func recentProjects(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: recentProjectsKey) ?? []
    }

    static func remember(project path: String, _ defaults: UserDefaults = .standard) {
        var list = recentProjects(defaults).filter { $0 != path }
        list.insert(path, at: 0)
        defaults.set(Array(list.prefix(8)), forKey: recentProjectsKey)
        defaults.set(path, forKey: projectKey)
    }
}

/// Owns the one active Dev mode CLI session and its thread. App-wide, so the session
/// survives tab switches and the panel being closed.
@MainActor
@Observable
final class DevSessionController {
    static let shared = DevSessionController()

    private(set) var thread: DevThreadState?
    private(set) var isStarting = false
    /// Error from the last start attempt (e.g. the CLI is not installed).
    private(set) var startError: AgentCLIError?
    private(set) var startErrorText: String?
    /// Whether this session was launched with Luna's browser tools (MCP bridge on).
    private(set) var hasBrowserTools = false
    private(set) var projectDir: URL?

    private var session: AgentCLISession?
    private var pump: Task<Void, Never>?
    private var resumeStore = AgentCLIResumeStore()

    var isRunning: Bool { thread?.isAlive == true }

    private init() {
        // A quitting Luna must not leave the CLI (and its tools) running.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DevSessionController.shared.stop() }
        }
    }

    /// Starts a session, replacing the current one. `resume` continues the last session Luna
    /// ran for this CLI and project (`AgentCLIResumeStore`).
    func start(kind: AgentCLIKind, projectDir: URL, model: String?, resume: Bool) async {
        let resumeID = resume ? resumeStore.lastSessionID(kind: kind, projectDir: projectDir) : nil
        await start(kind: kind, projectDir: projectDir, model: model, resumeID: resumeID)
    }

    /// Starts a session resuming `resumeID` (any Claude session / Codex thread id, e.g. one
    /// from `SessionSync`), or a new one when nil. `keeping` seeds the thread (take-over keeps
    /// the mirrored history on screen).
    /// `effort` is Codex's reasoning effort for each turn (nil = the model's default).
    func start(kind: AgentCLIKind, projectDir: URL, model: String?, resumeID: String?, effort: String? = nil,
               keeping: DevThreadState? = nil) async {
        stop()
        isStarting = true
        startError = nil
        startErrorText = nil
        self.projectDir = projectDir
        hasBrowserTools = LunaMCPBridge.shared.isEnabled && DevSettings.shared.autoWireBrowserTools
        let session = AgentCLISessions.make(kind)
        if let codex = session as? CodexAdapter, let effort, !effort.isEmpty { codex.effort = effort }
        self.session = session
        var state = keeping ?? DevThreadState(kind: kind)
        let trimmedModel = (model ?? DevSettings.shared.defaultModel(for: kind.harnessID))?.trimmingCharacters(in: .whitespaces)
        do {
            try await session.start(projectDir: projectDir,
                                    model: (trimmedModel?.isEmpty ?? true) ? nil : trimmedModel,
                                    resumeID: resumeID)
        } catch {
            isStarting = false
            startError = error as? AgentCLIError
            startErrorText = error.localizedDescription
            session.close()
            self.session = nil
            return
        }
        guard self.session === session else { return } // replaced while starting
        state.attached()
        thread = state
        isStarting = false
        pump = Task { [weak self] in
            for await event in session.events {
                guard let self, self.session === session else { return }
                self.thread?.apply(event)
                if case .sessionStarted(let id) = event {
                    self.resumeStore.save(id, kind: kind, projectDir: projectDir)
                }
            }
        }
    }

    /// The Claude session / Codex thread id Luna is running now (pass to `SessionSync` as `excluding`).
    var activeSessionID: String? { session == nil ? nil : (thread?.sessionID ?? session?.sessionID) }

    func send(_ text: String) {
        if let mirrored = mirror {
            // Sending to a session that is no longer live in a terminal attaches to it first.
            guard !mirrored.isLive else { return }
            Task { await takeOver(thenSend: text) }
            return
        }
        guard let session, thread?.canSend == true else { return }
        do {
            try session.send(text)
            thread?.userSent(text)
            if let projectDir, let id = session.sessionID ?? thread?.sessionID {
                resumeStore.noteActivity(id: id, kind: session.kind, projectDir: projectDir, prompt: text)
            }
        } catch {
            thread?.note(error: error.localizedDescription)
        }
    }

    // MARK: - Live session sync (experimental, DevSettings.liveSyncEnabled)

    /// The external session shown read-only, if any. `mirror?.isLive` is refreshed every few
    /// seconds; while true the UI should disable the composer and offer "Take over".
    private(set) var mirror: ExternalSession?
    private var mirrorPump: Task<Void, Never>?
    private var livenessPump: Task<Void, Never>?

    var isMirroring: Bool { mirror != nil }
    /// True while mirroring a session that a terminal is still writing.
    var isReadOnly: Bool { mirror?.isLive == true }

    /// Shows `external` in the thread (history, then new entries as the terminal writes them).
    /// Replaces any running Luna session. No-op unless live sync is enabled.
    func mirror(_ external: ExternalSession) {
        guard DevSettings.shared.liveSyncEnabled else { return }
        stop()
        mirror = external
        projectDir = external.projectDir
        thread = DevThreadState(kind: external.harness)
        let stream = SessionSync.shared.follow(external)
        mirrorPump = Task { [weak self] in
            for await event in stream {
                guard let self, self.mirror?.id == external.id else { return }
                self.thread?.apply(event)
            }
        }
        livenessPump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let current = self?.mirror, current.id == external.id else { return }
                let live = await SessionSync.shared.isStillLive(current)
                guard let self, self.mirror?.id == external.id else { return }
                if self.mirror?.isLive != live { self.mirror?.isLive = live }
            }
        }
    }

    /// Resumes the mirrored session in Luna (`claude --resume <id>` / Codex `thread/resume`),
    /// keeping the history on screen. If the terminal CLI is still running, both will append
    /// to the same session and diverge; the UI should say so before calling this while `isReadOnly`.
    func takeOver(model: String? = nil) async {
        await takeOver(model: model, thenSend: nil)
    }

    private func takeOver(model: String? = nil, thenSend text: String?) async {
        guard let external = mirror else { return }
        let history = thread
        stopMirror()
        resumeStore.noteActivity(id: external.id, kind: external.harness, projectDir: external.projectDir, prompt: nil)
        await start(kind: external.harness, projectDir: external.projectDir, model: model,
                    resumeID: external.id, keeping: history)
        if let text { send(text) }
    }

    private func stopMirror() {
        mirrorPump?.cancel()
        mirrorPump = nil
        livenessPump?.cancel()
        livenessPump = nil
        mirror = nil
    }

    func interrupt() {
        session?.interrupt()
    }

    func respond(approvalID: String, decision: CLIApprovalDecision) {
        session?.respond(approvalID: approvalID, decision: decision)
        thread?.decided(approvalID: approvalID, decision)
    }

    /// Ends the session and clears the thread.
    func stop() {
        stopMirror()
        pump?.cancel()
        pump = nil
        session?.close()
        session = nil
        thread = nil
    }
}

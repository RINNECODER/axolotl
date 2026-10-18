import Foundation
import Observation

/// One Claude Code / Codex session as Luna shows it: a single timeline that the Chat tab
/// renders, whoever is writing the session right now.
///
/// Exactly one writer at a time:
/// - **Luna terminal** (`openTerminal()`): the CLI runs interactively in `terminal`. The timeline
///   comes from tailing its transcript (`SessionSync.follow`), so chat shows what happens in the
///   terminal live; `send(_:)` types into the terminal (`DevTerminalController.send(text:)`).
///   Approvals are answered in the terminal; `state` is `.waitingApproval(.lunaTerminal)` while
///   the CLI's own prompt is on screen (screen heuristic, see `DevTerminalScreen`).
/// - **Luna headless** (default when no terminal runs): `send(_:)` drives the headless adapter
///   with `resume` of the same id; approvals arrive as timeline cards (`respond`).
/// - **External** (a CLI outside Luna, libproc): read-only mirror; `send(_:)` is refused until
///   the process exits (then `state` turns `.idle`, resumable) or the user calls `takeOver()`.
///
/// Switching Chat ↔ Terminal tabs never restarts anything: both views hold this object (get it
/// from `DevSessions.shared`) and `terminal` keeps its PTY when its view goes away.
@MainActor
@Observable
final class DevSession: Identifiable {
    enum Location: Equatable {
        case lunaHeadless
        case lunaTerminal
        case external(pid: pid_t?)
    }

    enum State: Equatable {
        case idle
        case running(Location)
        /// The CLI waits for an approval: answer the timeline card (headless) or in the terminal.
        case waitingApproval(Location)
    }

    enum SendRoute: Equatable {
        case terminal
        case headless
        case refused(String)
    }

    /// What the session needs from the outside world (swapped in tests).
    struct Dependencies {
        var makeHeadless: @MainActor (AgentCLIKind, DevSessionSetup) -> AgentCLISession = DevSession.makeHeadless
        var makeTerminal: @MainActor () -> DevTerminalController = { DevTerminalController() }
        var follow: (URL, AgentCLIKind) -> AsyncStream<CLIEvent> = { SessionSync.shared.follow(file: $0, harness: $1) }
        var locateFile: (DevSessionRef) async -> URL? = { await SessionSync.shared.sessionFile(harness: $0.harness, id: $0.id, projectDir: $0.projectDir) }
        var liveLocation: (ExternalSession) async -> SessionLocation? = { await SessionSync.shared.liveLocation(of: $0) }
        var resumeStore = AgentCLIResumeStore()
        /// How often an external session's liveness is re-checked.
        var livenessInterval: TimeInterval = 4
    }

    let id = UUID()
    let harness: AgentCLIKind
    let projectDir: URL
    /// Model / effort / approval for new runs (headless start and `.newSession` terminals).
    var setup: DevSessionSetup
    /// Claude session / Codex thread id; nil for a new session until the CLI creates it.
    private(set) var sessionID: String?
    /// The one event timeline the chat renders.
    private(set) var timeline: DevThreadState
    /// The Luna terminal for this session (kept after exit so its scrollback stays visible).
    private(set) var terminal: DevTerminalController?
    /// Set while a CLI outside Luna writes the session.
    private(set) var externalLocation: SessionLocation?
    private(set) var lastError: String?

    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private var headless: AgentCLISession?
    @ObservationIgnored private var headlessPump: Task<Void, Never>?
    @ObservationIgnored private var followTask: Task<Void, Never>?
    @ObservationIgnored private var followedFile: URL?
    @ObservationIgnored private var livenessTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSends: [String] = []
    @ObservationIgnored private var registeredID: String?
    private var headlessStarting = false
    private var headlessAlive = false

    /// A new session (no id yet) in `projectDir`.
    init(harness: AgentCLIKind, projectDir: URL, setup: DevSessionSetup, dependencies: Dependencies? = nil) {
        self.harness = harness
        self.projectDir = projectDir
        self.setup = setup
        self.deps = dependencies ?? Dependencies()
        timeline = DevThreadState(kind: harness)
    }

    /// An existing session from `SessionSync`: shows its history, mirrors it read-only while
    /// it is live outside Luna, and resumes it on the first send otherwise.
    init(existing: ExternalSession, setup: DevSessionSetup, dependencies: Dependencies? = nil) {
        harness = existing.harness
        projectDir = existing.projectDir
        var setup = setup
        setup.harness = existing.harness
        if setup.model == nil { setup.model = existing.model }
        self.setup = setup
        deps = dependencies ?? Dependencies()
        sessionID = existing.id
        timeline = DevThreadState(kind: existing.harness)
        if case .externalTerminal = existing.liveLocation { externalLocation = existing.liveLocation }
        follow(existing.file)
        if externalLocation != nil { watchExternal(existing) }
    }

    var ref: DevSessionRef? { sessionID.map { DevSessionRef(harness: harness, id: $0, projectDir: projectDir) } }

    var isTerminalRunning: Bool { terminal?.isRunning == true }
    var isExternalLive: Bool { externalLocation != nil }

    var state: State {
        if isTerminalRunning {
            return terminal?.isShowingApprovalPrompt == true ? .waitingApproval(.lunaTerminal) : .running(.lunaTerminal)
        }
        if case .externalTerminal(let pid) = externalLocation { return .running(.external(pid: pid)) }
        if headlessAlive || headlessStarting {
            if timeline.pendingApprovals > 0 { return .waitingApproval(.lunaHeadless) }
            if timeline.isTurnActive || headlessStarting { return .running(.lunaHeadless) }
        }
        return .idle
    }

    /// The terminal can take the session over: nothing outside Luna writes it and no headless
    /// turn is running (wait for it, or `interrupt()` first).
    var canOpenTerminal: Bool {
        !isExternalLive && !headlessStarting && !(headlessAlive && timeline.isTurnActive)
    }

    var canSend: Bool {
        if case .refused = Self.route(terminalRunning: isTerminalRunning, externalLive: isExternalLive) { return false }
        if !isTerminalRunning, headlessAlive, !timeline.canSend { return false }
        return true
    }

    /// Where a chat message goes (pure; the routing rule).
    nonisolated static func route(terminalRunning: Bool, externalLive: Bool) -> SendRoute {
        if terminalRunning { return .terminal }
        if externalLive { return .refused("Live in another terminal. Take over to write from Luna.") }
        return .headless
    }

    /// Sends a chat message to whoever writes the session now (see `route`).
    @discardableResult
    func send(_ text: String) -> SendRoute {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .refused("Empty message.") }
        let route = Self.route(terminalRunning: isTerminalRunning, externalLive: isExternalLive)
        switch route {
        case .terminal:
            // The transcript tail adds the user message to the timeline.
            terminal?.send(text: text)
        case .headless:
            sendHeadless(text)
        case .refused(let reason):
            lastError = reason
        }
        return route
    }

    /// Opens (or returns) the Luna terminal on this session: `.resume` when it has an id, else
    /// `.newSession` with `setup`. nil when `canOpenTerminal` is false. The headless adapter is
    /// closed first so the terminal is the only writer.
    @discardableResult
    func openTerminal() -> DevTerminalController? {
        if let terminal, terminal.isRunning { return terminal }
        guard canOpenTerminal else { return nil }
        closeHeadless()
        let term = terminal ?? deps.makeTerminal()
        terminal = term
        term.onSessionDiscovered = { [weak self] id, file in self?.terminalFound(id: id, file: file) }
        term.onExit = { [weak self] _ in self?.terminalExited() }
        if let ref {
            term.open(.resume(ref))
        } else {
            term.open(.newSession(harness, setup, projectDir: projectDir))
        }
        if let sessionID { register(sessionID) }
        return term
    }

    /// Stops the Luna terminal's program (the session stays resumable).
    func closeTerminal() {
        terminal?.terminate()
        terminalExited()
    }

    /// Writes from Luna even though a CLI outside Luna may still run it. Both then append to the
    /// same session and their histories diverge, so the UI should confirm first.
    func takeOver() {
        livenessTask?.cancel()
        livenessTask = nil
        externalLocation = nil
    }

    func interrupt() { headless?.interrupt() }

    /// New model / effort / approval for this session. An idle headless adapter is closed so the
    /// next send resumes the same id with the new setup; a running terminal keeps its own.
    func updateSetup(_ next: DevSessionSetup) {
        guard next != setup else { return }
        setup = next
        if headlessAlive, !timeline.isTurnActive { closeHeadless() }
    }

    func respond(approvalID: String, decision: CLIApprovalDecision) {
        headless?.respond(approvalID: approvalID, decision: decision)
        timeline.decided(approvalID: approvalID, decision)
    }

    /// Ends every Luna writer and stops following.
    func close() {
        closeHeadless()
        terminal?.terminate()
        stopFollow()
        livenessTask?.cancel()
        livenessTask = nil
        unregister()
    }

    // MARK: Headless

    private func sendHeadless(_ text: String) {
        timeline.userSent(text)
        if let headless, headlessAlive {
            do {
                try headless.send(text)
                noteActivity(prompt: text)
            } catch {
                timeline.note(error: error.localizedDescription)
            }
            return
        }
        pendingSends.append(text)
        guard !headlessStarting else { return }
        startHeadless()
    }

    private func startHeadless() {
        stopFollow() // the adapter's events take over; the history stays on screen
        headlessStarting = true
        let session = deps.makeHeadless(harness, setup)
        headless = session
        let model = setup.model
        let resumeID = sessionID
        Task { [weak self] in
            do {
                try await session.start(projectDir: self?.projectDir ?? URL(fileURLWithPath: "/"), model: model, resumeID: resumeID)
            } catch {
                guard let self, self.headless === session else { return }
                self.headlessStarting = false
                self.headless = nil
                self.pendingSends.removeAll()
                self.lastError = error.localizedDescription
                self.timeline.note(error: error.localizedDescription)
                return
            }
            guard let self, self.headless === session else { session.close(); return }
            self.headlessStarting = false
            self.headlessAlive = true
            self.timeline.attached()
            if let id = session.sessionID ?? resumeID { self.adopt(id) }
            self.headlessPump = Task { [weak self] in
                for await event in session.events {
                    guard let self, self.headless === session else { return }
                    self.timeline.apply(event)
                    if case .sessionStarted(let id) = event { self.adopt(id) }
                    if case .exited = event { self.headlessEnded(session) }
                }
            }
            let queued = self.pendingSends
            self.pendingSends.removeAll()
            for text in queued {
                do { try session.send(text); self.noteActivity(prompt: text) } catch { self.timeline.note(error: error.localizedDescription) }
            }
        }
    }

    private func headlessEnded(_ session: AgentCLISession) {
        guard headless === session else { return }
        headless = nil
        headlessAlive = false
        if !isTerminalRunning { unregister() }
    }

    private func closeHeadless() {
        headlessPump?.cancel()
        headlessPump = nil
        headless?.close()
        headless = nil
        headlessAlive = false
        headlessStarting = false
        pendingSends.removeAll()
    }

    // MARK: Terminal

    private func terminalFound(id: String, file: URL?) {
        adopt(id)
        if let file { follow(file, fresh: true); return }
        let ref = DevSessionRef(harness: harness, id: id, projectDir: projectDir)
        Task { [weak self] in
            guard let file = await self?.deps.locateFile(ref) else { return }
            self?.follow(file, fresh: true)
        }
    }

    private func terminalExited() {
        if headless == nil { unregister() }
    }

    // MARK: External

    private func watchExternal(_ external: ExternalSession) {
        let interval = deps.livenessInterval
        let liveLocation = deps.liveLocation
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                let location = await liveLocation(external)
                guard let self, !Task.isCancelled else { return }
                if case .externalTerminal = location {
                    if self.externalLocation != location { self.externalLocation = location }
                } else {
                    // The outside CLI exited: resumable from Luna now.
                    self.externalLocation = nil
                    return
                }
            }
        }
    }

    // MARK: Timeline from the transcript

    /// Tails `file` into the timeline. `fresh` rebuilds it from the file (the terminal took over
    /// from a headless run, so the transcript is the source of truth again).
    private func follow(_ file: URL, fresh: Bool = false) {
        if followedFile == file, followTask != nil { return }
        stopFollow()
        if fresh || !timeline.items.isEmpty { timeline = DevThreadState(kind: harness) }
        timeline.attached()
        followedFile = file
        let stream = deps.follow(file, harness)
        followTask = Task { [weak self] in
            for await event in stream {
                guard let self, self.followedFile == file else { return }
                self.timeline.apply(event)
            }
        }
    }

    private func stopFollow() {
        followTask?.cancel()
        followTask = nil
        followedFile = nil
    }

    // MARK: Bookkeeping

    private func adopt(_ id: String) {
        if sessionID != id {
            sessionID = id
            DevSessions.shared.adopt(self, id: id)
        }
        register(id)
        deps.resumeStore.save(id, kind: harness, projectDir: projectDir)
        noteActivity(prompt: nil)
    }

    private func noteActivity(prompt: String?) {
        guard let sessionID else { return }
        deps.resumeStore.noteActivity(id: sessionID, kind: harness, projectDir: projectDir, prompt: prompt)
    }

    private func register(_ id: String) {
        guard registeredID != id else { return }
        unregister()
        LunaActiveSessions.shared.register(id)
        registeredID = id
    }

    private func unregister() {
        if let registeredID { LunaActiveSessions.shared.unregister(registeredID) }
        registeredID = nil
    }

    /// A headless adapter configured from `setup` (approval mode, Codex effort) and DevSettings (MCP).
    static func makeHeadless(_ kind: AgentCLIKind, _ setup: DevSessionSetup) -> AgentCLISession {
        let session = AgentCLISessions.make(kind)
        if let claude = session as? ClaudeCodeAdapter { claude.permissionMode = setup.approvalBehavior.claudePermissionMode }
        if let codex = session as? CodexAdapter {
            codex.approvalPolicy = setup.approvalBehavior.codexApprovalPolicy
            codex.sandbox = setup.approvalBehavior.codexSandbox
            if let effort = setup.effort, !effort.isEmpty { codex.effort = effort }
        }
        return session
    }
}

/// One `DevSession` per session id, so the Chat and Terminal tabs (and the session list)
/// always get the same object.
@MainActor
final class DevSessions {
    static let shared = DevSessions()
    private var byID: [String: DevSession] = [:]

    /// The live object for `existing` (created on first use).
    func session(for existing: ExternalSession, setup: DevSessionSetup? = nil) -> DevSession {
        if let found = byID[existing.id] { return found }
        let session = DevSession(existing: existing, setup: setup ?? DevSettings.shared.defaultSetup)
        byID[existing.id] = session
        return session
    }

    /// A new session; registered under its id once the CLI creates one.
    func newSession(harness: AgentCLIKind, projectDir: URL, setup: DevSessionSetup? = nil) -> DevSession {
        var setup = setup ?? DevSettings.shared.defaultSetup
        setup.harness = harness
        return DevSession(harness: harness, projectDir: projectDir, setup: setup)
    }

    func session(id: String) -> DevSession? { byID[id] }

    fileprivate func adopt(_ session: DevSession, id: String) {
        if byID[id] == nil { byID[id] = session }
    }

    /// Closes and forgets a session.
    func remove(_ session: DevSession) {
        session.close()
        byID = byID.filter { $0.value !== session }
    }
}

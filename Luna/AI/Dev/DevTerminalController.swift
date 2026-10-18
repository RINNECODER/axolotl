import AppKit
import Foundation
import Observation
import SwiftTerm
import SwiftUI

// MARK: - Modes and command lines

/// What a Dev terminal runs. It is always a real terminal (PTY + SwiftTerm); the mode only
/// picks the program.
enum DevTerminalMode: Equatable {
    /// The user's login shell (`$SHELL -l`) in `dir`, or in ~ when nil. The Dev home view's terminal.
    case shell(URL?)
    /// The harness CLI, interactive, with `setup` (model, effort, approval mode) and Luna's MCP
    /// tools wired the same way the headless adapters do it.
    case newSession(AgentCLIKind, DevSessionSetup, projectDir: URL)
    /// `claude --resume <id>` / `codex resume <id>` in the session's folder.
    case resume(DevSessionRef)

    var harness: AgentCLIKind? {
        switch self {
        case .shell: return nil
        case .newSession(let kind, _, _): return kind
        case .resume(let ref): return ref.harness
        }
    }

    var workingDirectory: URL {
        switch self {
        case .shell(let dir): return dir ?? FileManager.default.homeDirectoryForCurrentUser
        case .newSession(_, _, let dir): return dir
        case .resume(let ref): return ref.projectDir
        }
    }
}

/// The exact process a mode launches. Secrets never go in `arguments`: the Codex MCP token is in
/// `environment`, the Claude one in the 0600 `--mcp-config` file.
struct DevTerminalLaunch: Equatable {
    var executable: String
    var arguments: [String]
    var workingDirectory: URL
    /// Added to the clean terminal environment.
    var environment: [String: String] = [:]
    /// Known up front: Claude new sessions get `--session-id`, resumes keep theirs.
    var sessionID: String?
}

extension DevApprovalBehavior {
    /// Interactive `codex -a` (0.163 accepts only on-request | never there; "ask" gets a
    /// read-only sandbox so every edit and command needs an approval).
    var codexInteractiveApproval: String { self == .fullAuto ? "never" : "on-request" }

    var codexInteractiveSandbox: String {
        switch self {
        case .ask: return "read-only"
        case .allowEdits: return "workspace-write"
        case .fullAuto: return "danger-full-access"
        }
    }
}

/// Builds the command line for each mode (pure; verified against claude 2.1.303 / codex 0.163.0 `--help`).
///
///     shell:       $SHELL -l
///     claude new:  claude --session-id <uuid> [--model M] --permission-mode P [--effort E] [--mcp-config <0600 file>]
///     claude res:  claude --resume <id> --permission-mode P [--mcp-config <file>]
///     codex new:   codex [-m M] -a A -s S [-c model_reasoning_effort="E"] [-c mcp_servers.luna.url=… -c mcp_servers.luna.bearer_token_env_var=…]
///     codex res:   codex resume -a A -s S [-c mcp…] <id>
enum DevTerminalCommand {
    static func launch(for mode: DevTerminalMode, approval: DevApprovalBehavior, shell: String,
                       executable: (AgentCLIKind) -> String, mcp: DevMCPAttachment?, claudeMCPConfig: URL?,
                       newSessionID: String = UUID().uuidString.lowercased()) -> DevTerminalLaunch {
        let dir = mode.workingDirectory
        switch mode {
        case .shell:
            return DevTerminalLaunch(executable: shell, arguments: ["-l"], workingDirectory: dir)

        case .newSession(.claudeCode, let setup, _):
            var args = ["--session-id", newSessionID]
            if let model = setup.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty { args += ["--model", model] }
            args += ["--permission-mode", setup.approvalBehavior.claudePermissionMode]
            if let effort = setup.effort, !effort.isEmpty { args += ["--effort", effort] }
            if let claudeMCPConfig { args += ["--mcp-config", claudeMCPConfig.path] }
            return DevTerminalLaunch(executable: executable(.claudeCode), arguments: args, workingDirectory: dir,
                                     sessionID: newSessionID)

        case .newSession(.codex, let setup, _):
            var args: [String] = []
            if let model = setup.model?.trimmingCharacters(in: .whitespaces), !model.isEmpty { args += ["-m", model] }
            args += ["-a", setup.approvalBehavior.codexInteractiveApproval, "-s", setup.approvalBehavior.codexInteractiveSandbox]
            if let effort = setup.effort, !effort.isEmpty { args += ["-c", "model_reasoning_effort=\"\(effort)\""] }
            args += mcp?.codexArguments ?? []
            return DevTerminalLaunch(executable: executable(.codex), arguments: args, workingDirectory: dir,
                                     environment: codexEnvironment(mcp))

        case .resume(let ref) where ref.harness == .claudeCode:
            var args = ["--resume", ref.id, "--permission-mode", approval.claudePermissionMode]
            if let claudeMCPConfig { args += ["--mcp-config", claudeMCPConfig.path] }
            return DevTerminalLaunch(executable: executable(.claudeCode), arguments: args, workingDirectory: dir, sessionID: ref.id)

        case .resume(let ref):
            var args = ["resume", "-a", approval.codexInteractiveApproval, "-s", approval.codexInteractiveSandbox]
            args += mcp?.codexArguments ?? []
            args.append(ref.id)
            return DevTerminalLaunch(executable: executable(.codex), arguments: args, workingDirectory: dir,
                                     environment: codexEnvironment(mcp), sessionID: ref.id)
        }
    }

    private static func codexEnvironment(_ mcp: DevMCPAttachment?) -> [String: String] {
        mcp.map { [LunaMCPBridge.tokenEnvVar: $0.token] } ?? [:]
    }

    /// What `send(text:)` writes: the text (bracketed paste when it has a newline, so a
    /// multi-line prompt is one input instead of several submits), then Return on its own.
    static func keystrokes(for text: String) -> (body: String, submit: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        if normalized.contains("\n") { return ("\u{1b}[200~" + normalized + "\u{1b}[201~", "\r") }
        return (normalized, "\r")
    }
}

// MARK: - New session capture

/// Watches a harness's own session store for the session a just-launched CLI creates in `cwd`.
nonisolated struct SessionStoreWatcher: Sendable {
    var claudeRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    var codexRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true)

    /// One check. Claude: `<folder for cwd>/<expectedID>.jsonl` (or any new .jsonl since `since`);
    /// Codex: a rollout in today's / yesterday's folder created since `since` whose
    /// `session_meta.cwd` is `cwd`. Returns the id and file.
    func find(harness: AgentCLIKind, cwd: URL, since: Date, expectedID: String?, ignoring: Set<String> = []) -> (id: String, file: URL)? {
        let fm = FileManager.default
        switch harness {
        case .claudeCode:
            for path in SessionSync.pathVariants(cwd) {
                let dir = claudeRoot.appendingPathComponent(SessionSync.claudeProjectFolderName(path), isDirectory: true)
                if let expectedID {
                    let file = dir.appendingPathComponent("\(expectedID).jsonl")
                    if fm.fileExists(atPath: file.path) { return (expectedID, file) }
                    continue
                }
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
                for file in files where file.pathExtension == "jsonl" {
                    let id = file.deletingPathExtension().lastPathComponent
                    if !ignoring.contains(id), Self.created(file) >= since.addingTimeInterval(-1) { return (id, file) }
                }
            }
            return nil
        case .codex:
            let calendar = Calendar.current
            var days: [URL] = []
            for offset in [0, -1] {
                guard let day = calendar.date(byAdding: .day, value: offset, to: Date()) else { continue }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                days.append(codexRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0), isDirectory: true))
            }
            for dir in days {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey])) ?? []
                for file in files where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                    guard Self.created(file) >= since.addingTimeInterval(-1), let head = SessionSync.readCodexHead(file),
                          !ignoring.contains(head.id), SessionSync.samePath(head.cwd, cwd) else { continue }
                    if let expectedID, head.id != expectedID { continue }
                    return (head.id, file)
                }
            }
            return nil
        }
    }

    /// Polls `find` every `interval` until found, cancelled or `timeout`.
    func wait(harness: AgentCLIKind, cwd: URL, since: Date, expectedID: String?, ignoring: Set<String> = [],
              interval: TimeInterval = 0.5, timeout: TimeInterval = 1_800) async -> (id: String, file: URL)? {
        let deadline = Date().addingTimeInterval(timeout)
        while !Task.isCancelled, Date() < deadline {
            if let hit = find(harness: harness, cwd: cwd, since: since, expectedID: expectedID, ignoring: ignoring) { return hit }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        return nil
    }

    private static func created(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? .distantPast
    }
}

// MARK: - Approval prompt detection

/// Spots a CLI's own approval prompt on screen. Heuristic: the TUIs draw fixed questions;
/// the transcript has no "waiting for approval" record (Claude writes the tool_use line and
/// then nothing until the user answers), so the screen is the only reliable signal.
nonisolated enum DevTerminalScreen {
    static let approvalMarkers = [
        "Do you want to proceed?", "Do you want to make this edit", "Do you want to create",
        "Do you want to allow", "Would you like to run the following command", "Would you like to make the following edits",
        "Allow command?", "Approve this", "Yes, and don't ask again",
    ] + trustMarkers

    /// Claude Code's / Codex's "trust this folder?" screen on a project's first run.
    static let trustMarkers = [
        "Do you trust the files in this folder", "Is this a project you created or one you trust",
        "Do you trust the contents of this directory", "Yes, I trust this folder",
    ]

    /// What the terminal emulator answers on its own to the program's queries (device
    /// attributes `ESC[?…c`, cursor position `ESC[…R`, keyboard protocol `ESC[?…u`, OSC / DCS
    /// replies, focus in / out). Claude Code asks these at startup; they are not the user typing.
    static func isTerminalReply(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == 0x1B else { return false }
        if bytes[1] == 0x5D || bytes[1] == 0x50 { return true } // OSC, DCS
        guard bytes[1] == 0x5B, let last = bytes.last else { return false }
        if bytes.count == 3 { return last == 0x49 || last == 0x4F } // ESC[I / ESC[O focus
        let params = bytes[2..<(bytes.count - 1)]
        guard params.allSatisfy({ (0x30...0x3F).contains($0) }) else { return false }
        return [0x63, 0x52, 0x6E, 0x75, 0x74, 0x79].contains(last) // c R n u t y
    }

    static func showsTrustPrompt(_ text: String) -> Bool {
        let flat = text.filter { !$0.isWhitespace }
        return trustMarkers.contains { flat.contains($0.filter { !$0.isWhitespace }) }
    }

    /// Printable text of terminal output, escape sequences removed.
    static func plainText(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        var out = ""
        var it = text.unicodeScalars.makeIterator()
        while let c = it.next() {
            if c == "\u{1b}" {
                guard let next = it.next() else { break }
                if next == "[" {
                    // CSI … final byte; cursor-forward (`C`) stands in for spaces in TUIs.
                    while let d = it.next() {
                        if (0x40...0x7E).contains(d.value) { if d == "C" { out.append(" ") }; break }
                    }
                }
                else if next == "]" { while let d = it.next(), d != "\u{7}", d != "\u{1b}" {} } // OSC … BEL
                continue
            }
            if c.value < 0x20, c != "\n" { out.append(" "); continue }
            out.unicodeScalars.append(c)
        }
        return out
    }

    /// Whitespace-insensitive: TUIs often move the cursor instead of printing spaces.
    static func showsApprovalPrompt(_ text: String) -> Bool {
        let flat = text.filter { !$0.isWhitespace }
        return approvalMarkers.contains { flat.contains($0.filter { !$0.isWhitespace }) }
    }
}

/// When a freshly launched CLI can take typed input. Text typed while the TUI is still drawing
/// its first screen is dropped, so `DevTerminalController.send(text:)` queues until this says
/// ready: some output has arrived and gone quiet, not before `minimum` after launch, and never
/// while a trust prompt is on screen. After `maximum` it is ready anyway (no output to wait on).
nonisolated struct DevCLIReadiness: Equatable, Sendable {
    var launchedAt: Date
    var firstOutputAt: Date?
    var lastOutputAt: Date?
    var showsTrustPrompt = false
    /// Once ready, stays ready (later output is the CLI working, not starting).
    private(set) var latched = false
    var quiet: TimeInterval = 1.0
    var minimum: TimeInterval = 2
    var maximum: TimeInterval = 12

    init(launchedAt: Date) { self.launchedAt = launchedAt }

    /// A shell is ready at once.
    static func immediate(_ now: Date = Date()) -> DevCLIReadiness {
        var r = DevCLIReadiness(launchedAt: now)
        r.latched = true
        return r
    }

    /// `visible`: the chunk printed something (mode switches and cursor moves alone don't count,
    /// so a CLI that sets up the screen and then loads for a while is not taken as ready).
    mutating func noteOutput(screen: String, visible: Bool = true, at now: Date) {
        showsTrustPrompt = DevTerminalScreen.showsTrustPrompt(screen)
        guard visible else { return }
        if firstOutputAt == nil { firstOutputAt = now }
        lastOutputAt = now
    }

    /// The user answered what was on screen (any keystroke).
    mutating func noteUserInput() { showsTrustPrompt = false }

    mutating func isReady(at now: Date) -> Bool {
        if showsTrustPrompt { return false }
        if latched { return true }
        let age = now.timeIntervalSince(launchedAt)
        var ready = age >= maximum
        if let last = lastOutputAt, age >= minimum, now.timeIntervalSince(last) >= quiet { ready = true }
        if ready { latched = true }
        return ready
    }
}

// MARK: - Controller

/// One real terminal that outlives its view: the PTY and the SwiftTerm view are owned here, so
/// switching Chat ↔ Terminal tabs (or closing the panel) never restarts the CLI. Show it with
/// `DevTerminalHostView(controller:)`.
///
///     let term = DevTerminalController()
///     term.open(.resume(session.ref))
///     term.send(text: "run the tests")      // typed into the CLI, then Return
///     term.sessionID                        // known at once for resumes / Claude, found on disk for Codex
@MainActor
@Observable
final class DevTerminalController {
    private(set) var currentMode: DevTerminalMode?
    /// The harness session this terminal runs, once it exists on disk (resumes: at once).
    private(set) var sessionID: String?
    /// Its transcript, once written.
    private(set) var sessionFile: URL?
    private(set) var isRunning = false
    /// Exit code of the last run (nil while running or when killed by a signal).
    private(set) var exitCode: Int32?
    private(set) var launchError: String?
    /// The CLI is showing its own approval question (see `DevTerminalScreen`).
    private(set) var isShowingApprovalPrompt = false
    /// The exact launch (for tests and a "command" tooltip; contains no secrets).
    private(set) var lastLaunch: DevTerminalLaunch?
    /// The CLI can take typed text (see `DevCLIReadiness`); sends before that are queued.
    private(set) var isReady = false
    /// Chat messages waiting for the CLI to be ready.
    private(set) var queuedSends: [String] = []
    /// Claude's / Codex's folder trust question is on screen (answer it in the terminal).
    private(set) var isShowingTrustPrompt = false

    /// Called once the session id is known (`sessionID` set). `DevSession` uses it to follow the file.
    @ObservationIgnored var onSessionDiscovered: ((String, URL?) -> Void)?
    @ObservationIgnored var onExit: ((Int32?) -> Void)?

    @ObservationIgnored private var pty: PTYSession?
    @ObservationIgnored private var reader: Task<Void, Never>?
    @ObservationIgnored private var watcherTask: Task<Void, Never>?
    @ObservationIgnored private var mcp: DevMCPAttachment?
    @ObservationIgnored private var mcpConfig: URL?
    @ObservationIgnored private var screenTail = Data()
    @ObservationIgnored private var pendingLaunch: DevTerminalLaunch?
    @ObservationIgnored private var readiness = DevCLIReadiness.immediate()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var bridge: TerminalBridge?
    @ObservationIgnored private var _view: TerminalView?
    @ObservationIgnored private let watcher: SessionStoreWatcher
    @ObservationIgnored private let approval: () -> DevApprovalBehavior
    @ObservationIgnored private let mcpProvider: () -> DevMCPAttachment?
    @ObservationIgnored private let executable: (AgentCLIKind) -> String
    /// Test hook: every byte the PTY prints.
    @ObservationIgnored var outputObserver: ((Data) -> Void)?

    /// nil arguments use `DevSettings.shared` (approval mode, MCP auto-wire, CLI path overrides).
    init(watcher: SessionStoreWatcher = SessionStoreWatcher(),
         approval: (() -> DevApprovalBehavior)? = nil,
         mcpProvider: (() -> DevMCPAttachment?)? = nil,
         executable: ((AgentCLIKind) -> String)? = nil) {
        self.watcher = watcher
        self.approval = approval ?? { DevSettings.shared.approvalBehavior }
        self.mcpProvider = mcpProvider ?? { DevSettings.shared.autoWireBrowserTools ? LunaMCPBridge.shared.devAttachment() : nil }
        self.executable = executable ?? { DevSettings.executable(for: $0) }
    }

    /// The persistent SwiftTerm view (created on first use).
    var terminalView: TerminalView {
        if let _view { return _view }
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        view.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        let bridge = TerminalBridge(owner: self)
        view.terminalDelegate = bridge
        self.bridge = bridge
        _view = view
        return view
    }

    /// The user's login shell (for `.shell`).
    nonisolated static var loginShell: String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: shell) ? shell : "/bin/zsh"
    }

    /// Ends whatever runs and starts `mode`. Launches once the view has a real size (or after
    /// 0.5 s at 120x40 when nothing shows it), so the TUI draws its first screen at the right width.
    func open(_ mode: DevTerminalMode) {
        terminate()
        currentMode = mode
        launchError = nil
        exitCode = nil
        sessionID = nil
        sessionFile = nil
        isShowingApprovalPrompt = false
        isShowingTrustPrompt = false
        queuedSends = []
        if mode.harness != nil {
            readiness = DevCLIReadiness(launchedAt: Date())
            isReady = false
        } else {
            readiness = .immediate()
            isReady = true
        }
        if mode.harness != nil {
            mcp = mcpProvider()
            if let mcp, mode.harness == .claudeCode { mcpConfig = try? mcp.writeClaudeConfig() }
        }
        let launch = DevTerminalCommand.launch(for: mode, approval: approval(), shell: Self.loginShell,
                                               executable: executable, mcp: mcp, claudeMCPConfig: mcpConfig)
        lastLaunch = launch
        pendingLaunch = launch
        isRunning = true
        let terminal = terminalView.getTerminal()
        if terminalView.window != nil, terminal.cols >= 20, terminal.rows >= 5 {
            launchPending()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.launchPending() }
        }
    }

    fileprivate func launchPending() {
        guard let launch = pendingLaunch, let mode = currentMode else { return }
        pendingLaunch = nil
        let view = terminalView
        let terminal = view.getTerminal()
        let hasWindow = view.window != nil
        let pty = PTYSession(executable: launch.executable, arguments: launch.arguments, workingDirectory: launch.workingDirectory,
                             environment: LoginShellEnvironment.terminalEnvironment(adding: launch.environment))
        let started = Date()
        do {
            try pty.start(columns: UInt16(hasWindow ? max(terminal.cols, 20) : 120),
                          rows: UInt16(hasWindow ? max(terminal.rows, 5) : 40)) { [weak self] status in
                let owner = self
                Task { @MainActor in owner?.processEnded(PTYSession.exitCode(status), pty: pty) }
            }
        } catch {
            launchError = error.localizedDescription
            isRunning = false
            view.feed(text: "\r\n\(error.localizedDescription)\r\n")
            cleanUpMCP()
            return
        }
        self.pty = pty
        scheduleFlush() // also flips `isReady` once the CLI has drawn its first screen
        reader = Task { @MainActor [weak self] in
            for await chunk in pty.output {
                guard let self, self.pty === pty else { return }
                self.terminalView.feed(byteArray: ArraySlice([UInt8](chunk)))
                self.outputObserver?(chunk)
                self.noteScreen(chunk)
            }
        }
        if let harness = mode.harness {
            if case .resume(let ref) = mode { discovered(ref.id, file: nil) }
            let cwd = launch.workingDirectory
            let expected = launch.sessionID
            let watcher = self.watcher
            watcherTask = Task { [weak self] in
                guard let hit = await watcher.wait(harness: harness, cwd: cwd, since: started.addingTimeInterval(-2), expectedID: expected) else { return }
                guard let self, self.pty === pty else { return }
                self.discovered(hit.id, file: hit.file)
            }
        }
    }

    private func discovered(_ id: String, file: URL?) {
        let changed = sessionID != id
        sessionID = id
        if let file { sessionFile = file }
        if changed || file != nil { onSessionDiscovered?(id, file) }
    }

    private func noteScreen(_ chunk: Data) {
        screenTail.append(chunk)
        if screenTail.count > 8_192 { screenTail = screenTail.suffix(8_192) }
        let screen = DevTerminalScreen.plainText(screenTail)
        let showing = DevTerminalScreen.showsApprovalPrompt(screen)
        if showing != isShowingApprovalPrompt { isShowingApprovalPrompt = showing }
        let visible = DevTerminalScreen.plainText(chunk).contains { !$0.isWhitespace }
        readiness.noteOutput(screen: screen, visible: visible, at: Date())
        if readiness.showsTrustPrompt != isShowingTrustPrompt { isShowingTrustPrompt = readiness.showsTrustPrompt }
    }

    private func checkReady() -> Bool {
        let ready = readiness.isReady(at: Date())
        if ready != isReady { isReady = ready }
        return ready
    }

    /// Sends queued messages once the CLI is ready, one at a time.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, !Task.isCancelled {
                if self.checkReady() {
                    if self.queuedSends.isEmpty { break }
                    self.type(self.queuedSends.removeFirst())
                    try? await Task.sleep(for: .milliseconds(600))
                    continue
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            self?.flushTask = nil
        }
    }

    /// Any keystroke answers / dismisses what is on screen; detection restarts from new output.
    fileprivate func userTyped(_ data: Data) {
        if DevTerminalScreen.isTerminalReply(data) {
            pty?.write(data)
            return
        }
        screenTail.removeAll()
        if isShowingApprovalPrompt { isShowingApprovalPrompt = false }
        readiness.noteUserInput()
        if isShowingTrustPrompt { isShowingTrustPrompt = false }
        pty?.write(data)
    }

    fileprivate func resize(columns: Int, rows: Int) {
        if pty == nil, pendingLaunch != nil, columns >= 20, rows >= 5 {
            DispatchQueue.main.async { [weak self] in self?.launchPending() }
            return
        }
        pty?.resize(columns: UInt16(max(columns, 1)), rows: UInt16(max(rows, 1)))
    }

    /// Types `text` into the running program and presses Return (bracketed paste for multi-line).
    /// The Return goes separately after a short pause: Ink and ratatui treat a burst ending in
    /// "\r" as pasted text and would not submit it.
    /// Queued (in order) until the CLI is ready to take input.
    func send(text: String) {
        guard isRunning else { return }
        if !queuedSends.isEmpty || !checkReady() {
            queuedSends.append(text)
            scheduleFlush()
            return
        }
        type(text)
    }

    private func type(_ text: String) {
        guard let pty, isRunning else { return }
        let keys = DevTerminalCommand.keystrokes(for: text)
        screenTail.removeAll()
        pty.write(keys.body)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.pty === pty else { return }
            pty.write(keys.submit)
        }
    }

    /// Raw keystrokes (e.g. "\u{1b}[B" for Down, "\u{3}" for Ctrl-C), written as is.
    func write(raw: String) {
        guard let pty, isRunning else { return }
        screenTail.removeAll()
        pty.write(raw)
    }

    /// SIGHUP to the program (SIGKILL after 2 s), like closing a Terminal tab.
    func terminate() {
        pendingLaunch = nil
        flushTask?.cancel()
        flushTask = nil
        queuedSends = []
        watcherTask?.cancel()
        watcherTask = nil
        reader?.cancel()
        reader = nil
        pty?.terminate()
        pty = nil
        if isRunning { isRunning = false }
        cleanUpMCP()
    }

    private func processEnded(_ code: Int32?, pty ended: PTYSession) {
        guard pty === ended else { return }
        exitCode = code
        isRunning = false
        isShowingApprovalPrompt = false
        watcherTask?.cancel()
        terminalView.feed(text: "\r\n[process exited]\r\n")
        cleanUpMCP()
        onExit?(code)
    }

    private func cleanUpMCP() {
        if let mcpConfig { DevMCPAttachment.removeClaudeConfig(mcpConfig) }
        mcpConfig = nil
        mcp?.revoke()
        mcp = nil
    }

    // MARK: SwiftTerm delegate

    private final class TerminalBridge: NSObject, TerminalViewDelegate {
        weak var owner: DevTerminalController?
        init(owner: DevTerminalController) { self.owner = owner }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            MainActor.assumeIsolated { owner?.userTyped(Data(data)) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { owner?.resize(columns: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

/// Shows a `DevTerminalController`'s terminal. Dismantling the view does not stop the program.
struct DevTerminalHostView: NSViewRepresentable {
    let controller: DevTerminalController
    var isDark = true

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if controller.terminalView.superview !== nsView { attach(to: nsView) }
        DevTerminalView.applyColors(to: controller.terminalView, isDark: isDark)
    }

    private func attach(to container: NSView) {
        let view = controller.terminalView
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DevTerminalView.applyColors(to: view, isDark: isDark)
    }
}

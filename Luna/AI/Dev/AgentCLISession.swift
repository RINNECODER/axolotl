import CryptoKit
import Foundation

// MARK: - Normalized events

/// Which coding-agent CLI a Dev session drives.
nonisolated enum AgentCLIKind: String, CaseIterable, Codable {
    case claudeCode
    case codex

    var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    var executableName: String { self == .claudeCode ? "claude" : "codex" }
}

/// What an approval is about. The UI words its prompt from this.
enum CLIApprovalKind: String, Codable {
    case command      // run a shell command
    case fileChange   // write / edit files
    case permission   // widen sandbox permissions (Codex)
    case tool         // any other tool call (MCP, web, elicitation)
}

enum CLIApprovalDecision: String, Codable {
    case allow
    /// Allow and stop asking for the same thing this session (when the CLI supports it).
    case allowForSession
    case deny
    /// Deny and also stop the current turn.
    case cancel
}

struct CLIApprovalRequest: Equatable {
    /// Pass back to `respond(approvalID:decision:)`.
    let id: String
    let kind: CLIApprovalKind
    /// Tool or request name, e.g. "Bash", "Write", "item/commandExecution/requestApproval".
    let title: String
    /// One line for the prompt: the command, the file path, the tool input.
    let summary: String
    /// The raw request from the CLI, for a details view.
    let payload: JSONValue
}

struct CLIUsage: Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double?
}

enum CLITurnOutcome: Equatable {
    case completed
    case interrupted
    case failed(String?)
}

struct CLIExit: Equatable {
    let status: Int32
    /// True when the process died from a signal.
    let signaled: Bool
    /// True when `close()` asked for it; false means it crashed or quit on its own.
    let expected: Bool
    /// Last bytes of stderr, for crash reports.
    let stderrTail: String
}

enum CLIEvent: Equatable {
    /// Session (Claude) or thread (Codex) id; save it to resume later. Emitted once per session.
    case sessionStarted(id: String)
    /// A user message read back from a session transcript (history replay / live sync).
    /// Adapters never emit it for Luna's own sends; `DevThreadState.userSent` covers those.
    case userMessage(String)
    /// Streaming assistant text.
    case textDelta(String)
    /// One finished assistant message (the full text of what the deltas built).
    case messageDone(String)
    case toolStarted(id: String, name: String, summary: String)
    case toolOutput(id: String, text: String)
    case toolFinished(id: String, isError: Bool)
    case approvalRequest(CLIApprovalRequest)
    case turnDone(usage: CLIUsage?, outcome: CLITurnOutcome)
    case error(String)
    /// History replay started near the end of a very large transcript: this many bytes of older
    /// history were not loaded. Emitted first, only by `SessionSync.follow`.
    case historyTruncated(skippedBytes: UInt64)
    /// The CLI process ended. Always the last event; the stream finishes after it.
    case exited(CLIExit)
}

enum AgentCLIError: LocalizedError, Equatable {
    case unavailable(String)
    case notFound(String)
    case notStarted
    case alreadyStarted
    case busy
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .notFound(let name): return "Could not find `\(name)` on your login shell PATH. Install it, or check that `which \(name)` works in Terminal."
        case .notStarted: return "The session is not running."
        case .alreadyStarted: return "The session has already been started."
        case .busy: return "Wait for the current turn to finish or interrupt it first."
        case .launchFailed(let why): return "Could not start the CLI: \(why)"
        }
    }
}

// MARK: - Session API (for the Dev mode UI)

/// One conversation with a coding-agent CLI, normalized across Claude Code and Codex.
/// Lifecycle: `start` once, then `send` per user message; read everything from `events`.
@MainActor
protocol AgentCLISession: AnyObject {
    var kind: AgentCLIKind { get }
    /// Single-consumer stream; ends after `.exited`.
    var events: AsyncStream<CLIEvent> { get }
    /// Known after `.sessionStarted`.
    var sessionID: String? { get }
    var isRunning: Bool { get }
    /// Launches the CLI in `projectDir`. `resumeID` continues an earlier session/thread
    /// (see `AgentCLIResumeStore`). Throws if the CLI is missing or cannot start.
    func start(projectDir: URL, model: String?, resumeID: String?) async throws
    func send(_ text: String) throws
    /// Stops the current turn; the session stays usable.
    func interrupt()
    func respond(approvalID: String, decision: CLIApprovalDecision)
    /// Ends the process and cleans up (temp MCP config, trusted bridge token).
    func close()
}

enum AgentCLISessions {
    /// A new session configured from `DevSettings` (approval behavior; Luna's MCP bridge
    /// attached when the bridge is on and `autoWireBrowserTools` is set).
    static func make(_ kind: AgentCLIKind, settings: DevSettings? = nil) -> AgentCLISession {
        let settings = settings ?? .shared
        let mcp = settings.autoWireBrowserTools ? LunaMCPBridge.shared.devAttachment() : nil
        let behavior = settings.approvalBehavior
        switch kind {
        case .claudeCode:
            let adapter = ClaudeCodeAdapter(mcp: mcp)
            adapter.permissionMode = behavior.claudePermissionMode
            return adapter
        case .codex:
            let adapter = CodexAdapter(mcp: mcp)
            adapter.approvalPolicy = behavior.codexApprovalPolicy
            adapter.sandbox = behavior.codexSandbox
            return adapter
        }
    }
}

// MARK: - Resume ids per project

/// Remembers the last session/thread id per CLI and project folder.
nonisolated struct AgentCLIResumeStore {
    var defaults: UserDefaults = .standard
    /// Where first-prompt titles live (0600 JSON, `[id: title]`), so prompt text never sits in
    /// UserDefaults. nil keeps titles in `defaults` (tests with a scratch suite).
    var titlesURL: URL?

    init(defaults: UserDefaults = .standard, titlesURL: URL? = nil) {
        self.defaults = defaults
        self.titlesURL = titlesURL ?? (defaults === UserDefaults.standard ? Self.defaultTitlesURL : nil)
    }

    static var defaultTitlesURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Luna/Dev/resume-titles.json")
    }

    private func loadTitles() -> [String: String] {
        guard let titlesURL, let data = try? Data(contentsOf: titlesURL),
              let titles = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return titles
    }

    private func saveTitles(_ titles: [String: String]) {
        guard let titlesURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(titles) { PrivateFile.write(data, to: titlesURL) }
    }

    static func key(kind: AgentCLIKind, projectDir: URL) -> String {
        let path = projectDir.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "devCLI.resume.\(kind.rawValue).\(digest)"
    }

    func lastSessionID(kind: AgentCLIKind, projectDir: URL) -> String? {
        defaults.string(forKey: Self.key(kind: kind, projectDir: projectDir))
    }

    func save(_ id: String, kind: AgentCLIKind, projectDir: URL) {
        defaults.set(id, forKey: Self.key(kind: kind, projectDir: projectDir))
        upsert(id: id, kind: kind, projectDir: projectDir) { _ in }
    }

    // MARK: Sessions started in Luna (for resume identification)

    /// A session Luna started (or took over) in a project.
    struct Record: Codable, Equatable {
        let id: String
        let kind: AgentCLIKind
        var updatedAt: Date
        /// First user message, truncated (`SessionSync.titleLimit`).
        var title: String?
    }

    static let historyLimit = 20

    static func historyKey(projectDir: URL) -> String {
        let path = projectDir.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "devCLI.history.\(digest)"
    }

    /// Newest first, both CLIs.
    func history(projectDir: URL) -> [Record] {
        guard let data = defaults.data(forKey: Self.historyKey(projectDir: projectDir)),
              var records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        if titlesURL != nil {
            var titles = loadTitles()
            var migrated = false
            for i in records.indices {
                if let legacy = records[i].title { titles[records[i].id] = titles[records[i].id] ?? legacy; migrated = true }
                records[i].title = titles[records[i].id]
            }
            if migrated { saveTitles(titles); store(records, projectDir: projectDir) } // moves old UserDefaults titles out
        }
        return records.sorted { $0.updatedAt > $1.updatedAt }
    }

    func isLunaSession(_ id: String, projectDir: URL) -> Bool {
        history(projectDir: projectDir).contains { $0.id == id }
    }

    /// Records the first prompt as the title (later calls keep the first one) and bumps `updatedAt`.
    func noteActivity(id: String, kind: AgentCLIKind, projectDir: URL, prompt: String?) {
        upsert(id: id, kind: kind, projectDir: projectDir) { record in
            if record.title == nil, let prompt { record.title = SessionSync.title(from: prompt) }
        }
    }

    private func upsert(id: String, kind: AgentCLIKind, projectDir: URL, _ change: (inout Record) -> Void) {
        var records = history(projectDir: projectDir)
        var record = records.first { $0.id == id } ?? Record(id: id, kind: kind, updatedAt: Date(), title: nil)
        records.removeAll { $0.id == id }
        record.updatedAt = Date()
        change(&record)
        records.insert(record, at: 0)
        let kept = Array(records.prefix(Self.historyLimit))
        if titlesURL != nil {
            var titles = loadTitles()
            for r in kept { if let t = r.title { titles[r.id] = t } }
            saveTitles(titles)
        }
        store(kept, projectDir: projectDir)
    }

    /// Writes the record list to UserDefaults, without titles when they live in the file.
    private func store(_ records: [Record], projectDir: URL) {
        var out = records
        if titlesURL != nil { for i in out.indices { out[i].title = nil } }
        if let data = try? JSONEncoder().encode(out) { defaults.set(data, forKey: Self.historyKey(projectDir: projectDir)) }
    }

    func forget(kind: AgentCLIKind, projectDir: URL) {
        defaults.removeObject(forKey: Self.key(kind: kind, projectDir: projectDir))
    }
}

// MARK: - Luna MCP for CLI sessions

/// Luna's browser tools for one CLI session: a per-session bearer token the bridge trusts
/// (so Luna does not prompt on top of the CLI's own approvals). Revoke it on close.
struct DevMCPAttachment {
    static let serverName = "luna"
    let url: String
    let token: String
    let revoke: () -> Void

    /// `--mcp-config` JSON for Claude Code (additive; the user's own servers still load).
    func claudeConfigJSON() -> String {
        JSONValue.object(["mcpServers": .object([Self.serverName: .object([
            "type": "http",
            "url": .string(url),
            "headers": .object(["Authorization": .string("Bearer \(token)")]),
        ])])]).jsonString()
    }

    /// `-c` overrides for `codex app-server`; the token goes only in the child env.
    var codexArguments: [String] {
        ["-c", "mcp_servers.\(Self.serverName).url=\"\(url)\"",
         "-c", "mcp_servers.\(Self.serverName).bearer_token_env_var=\"\(LunaMCPBridge.tokenEnvVar)\""]
    }

    /// Writes the Claude config to a new 0600 file in a private temp folder.
    func writeClaudeConfig() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luna-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("mcp.json")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(claudeConfigJSON().utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw AgentCLIError.launchFailed("could not write the MCP config")
        }
        return file
    }

    static func removeClaudeConfig(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

// MARK: - Shared helpers

enum CLIText {
    /// Short single-line description of a tool input for prompts and tool rows.
    static func summary(of input: JSONValue?, limit: Int = 300) -> String {
        guard let input else { return "" }
        let preferred = ["command", "cmd", "file_path", "path", "url", "pattern", "query", "description"]
        if let object = input.objectValue {
            for key in preferred { if let value = object[key]?.stringValue, !value.isEmpty { return clip(value, limit) } }
        }
        if let s = input.stringValue { return clip(s, limit) }
        return clip(input.jsonString(), limit)
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func parse(_ line: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: line)
    }

    static func line(_ value: JSONValue) -> Data {
        var data = (try? JSONValue.encoder.encode(value)) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func int(_ value: JSONValue?) -> Int? { value?.numberValue.map { Int($0) } }
}

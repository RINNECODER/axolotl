import Darwin
import Foundation

// MARK: - Public types

/// A Claude Code or Codex session found in the harness's own storage for a project.
nonisolated struct ExternalSession: Identifiable, Hashable, Sendable {
    let harness: AgentCLIKind
    /// Claude session id / Codex thread id: what `--resume` / `thread/resume` take.
    let id: String
    /// The transcript (`~/.claude/projects/…/<id>.jsonl`, `~/.codex/sessions/…/rollout-….jsonl`).
    let file: URL
    let projectDir: URL
    /// Claude's AI title when it wrote one, else the first user prompt; truncated.
    let title: String
    /// First user prompt, truncated (`SessionSync.titleLimit`); "" when there is none yet.
    let firstPrompt: String
    let updatedAt: Date
    /// Being written by a CLI outside Luna right now (see `SessionSync.isLive`). Luna must
    /// mirror a live session read-only until the user takes it over.
    var isLive: Bool
    /// User + assistant messages (tool calls not counted).
    let messageCount: Int
    /// Started (or taken over) by Luna rather than in a terminal.
    let startedInLuna: Bool
}

/// The session the UI should offer to resume for a project.
nonisolated struct ResumableSession: Equatable, Sendable {
    let harness: AgentCLIKind
    let id: String
    let title: String
    let updatedAt: Date
    let startedInLuna: Bool
    let isLive: Bool
}

// MARK: - SessionSync

/// Experimental live session sync (behind `DevSettings.liveSyncEnabled`): finds the sessions a
/// project has in Claude Code's and Codex's own storage, tells which are live in a terminal,
/// and tails one as `CLIEvent`s.
///
/// Read-only: transcripts are parsed in memory and never written. To continue a session in Luna,
/// resume its id through the normal adapter (`DevSessionController.takeOver()`).
///
/// Caveat: two writers on one session (a terminal CLI and Luna) each append their own turns
/// and neither sees the other's until it reloads, so the histories diverge. Luna therefore
/// stays a read-only mirror while `isLive`, and "Take over" is an explicit user action.
actor SessionSync {
    static let shared = SessionSync()

    /// Titles and first prompts are cut to this many characters.
    static let titleLimit = 80
    /// A transcript written within this window counts as live.
    static let recentWindow: TimeInterval = 120
    /// Codex rollouts older than this are not scanned.
    static let codexLookback: TimeInterval = 30 * 86_400

    private let claudeRoot: URL
    private let codexRoot: URL
    private let processes: @Sendable () -> [AgentProcess]
    private let now: @Sendable () -> Date
    private let resumeStore: AgentCLIResumeStore
    private var summaries: [String: (stamp: FileStamp, summary: TranscriptSummary)] = [:]
    private var codexHeads: [String: (stamp: FileStamp, head: CodexHead?)] = [:]

    init(claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true),
         codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
         processes: @escaping @Sendable () -> [AgentProcess] = { LiveProcessScanner.agentProcesses() },
         now: @escaping @Sendable () -> Date = { Date() },
         resumeStore: AgentCLIResumeStore = AgentCLIResumeStore()) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.processes = processes
        self.now = now
        self.resumeStore = resumeStore
    }

    /// Sessions for `projectDir`, newest first, both harnesses. `excluding` drops ids Luna is
    /// running itself right now (pass `DevSessionController.shared.activeSessionID`).
    func sessions(projectDir: URL, excluding: Set<String> = [], limit: Int = 30) -> [ExternalSession] {
        let live = processes()
        let claude = claudeSessions(projectDir: projectDir, limit: limit)
        let codex = codexSessions(projectDir: projectDir, limit: limit)
        var out: [ExternalSession] = []
        for (kind, found) in [(AgentCLIKind.claudeCode, claude), (.codex, codex)] {
            let processInProject = live.contains { $0.harness == kind && Self.samePath($0.cwd, projectDir) }
            let newest = found.max { $0.1.updatedAt < $1.1.updatedAt }?.1.id
            for (file, summary) in found where !excluding.contains(summary.id) {
                let startedInLuna = resumeStore.isLunaSession(summary.id, projectDir: projectDir) || summary.originatedInLuna
                let isLive = Self.isLive(updatedAt: summary.updatedAt, now: now(), processInProject: processInProject,
                                         isNewest: summary.id == newest, startedInLuna: startedInLuna)
                out.append(ExternalSession(harness: kind, id: summary.id, file: file, projectDir: projectDir,
                                           title: summary.title, firstPrompt: summary.firstPrompt,
                                           updatedAt: summary.updatedAt, isLive: isLive,
                                           messageCount: summary.messageCount, startedInLuna: startedInLuna))
            }
        }
        return Array(out.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// The most recent session to offer for "Resume" in `projectDir`, from disk, else from
    /// Luna's own records (e.g. when the storage folders cannot be read).
    func mostRecentResumable(projectDir: URL, excluding: Set<String> = []) -> ResumableSession? {
        if let s = sessions(projectDir: projectDir, excluding: excluding, limit: 1).first {
            return ResumableSession(harness: s.harness, id: s.id, title: s.title, updatedAt: s.updatedAt,
                                    startedInLuna: s.startedInLuna, isLive: s.isLive)
        }
        guard let r = resumeStore.history(projectDir: projectDir).first(where: { !excluding.contains($0.id) }) else { return nil }
        return ResumableSession(harness: r.kind, id: r.id, title: r.title ?? "", updatedAt: r.updatedAt, startedInLuna: true, isLive: false)
    }

    /// Re-checks whether `session` is still live (for the mirror's read-only guard).
    func isStillLive(_ session: ExternalSession) -> Bool {
        let stamp = FileStamp(session.file)
        let updated = stamp?.modified ?? session.updatedAt
        let live = processes().contains { $0.harness == session.harness && Self.samePath($0.cwd, session.projectDir) }
        let newest = sessions(projectDir: session.projectDir, limit: 5).first { $0.harness == session.harness }?.id
        return Self.isLive(updatedAt: updated, now: now(), processInProject: live,
                           isNewest: newest == nil || newest == session.id, startedInLuna: session.startedInLuna)
    }

    /// History first, then new entries as they are appended (polled every `interval`).
    /// Ends when the consumer stops iterating.
    nonisolated func follow(_ session: ExternalSession, interval: TimeInterval = 0.4) -> AsyncStream<CLIEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CLIEvent.self, bufferingPolicy: .unbounded)
        let file = session.file
        let harness = session.harness
        let task = Task.detached(priority: .utility) {
            var tailer = TranscriptTailer(harness: harness)
            var offset: UInt64 = 0
            var framer = NDJSONFramer()
            while !Task.isCancelled {
                guard let handle = try? FileHandle(forReadingFrom: file) else {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    continue
                }
                let size = (try? handle.seekToEnd()) ?? 0
                if size < offset { offset = 0; framer = NDJSONFramer() } // truncated or replaced
                if size > offset {
                    try? handle.seek(toOffset: offset)
                    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                        offset += UInt64(chunk.count)
                        for line in framer.append(chunk) {
                            for event in tailer.events(forLine: line) { continuation.yield(event) }
                        }
                    }
                }
                try? handle.close()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Liveness (pure)

    /// Live = written in the last `recentWindow`, or a CLI of that harness runs in the project
    /// (outside Luna) and this is its newest session. A Luna session with no outside process is never live.
    static func isLive(updatedAt: Date, now: Date, processInProject: Bool, isNewest: Bool, startedInLuna: Bool,
                       recentWindow: TimeInterval = SessionSync.recentWindow) -> Bool {
        if startedInLuna && !processInProject { return false }
        if now.timeIntervalSince(updatedAt) <= recentWindow { return true }
        return processInProject && isNewest
    }

    // MARK: Claude Code storage

    /// `~/.claude/projects/<cwd with every non-alphanumeric character replaced by "-">`.
    static func claudeProjectFolderName(_ path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    private func claudeSessions(projectDir: URL, limit: Int) -> [(URL, TranscriptSummary)] {
        var files: [URL] = []
        var seenDirs = Set<String>()
        for path in Self.pathVariants(projectDir) {
            let dir = claudeRoot.appendingPathComponent(Self.claudeProjectFolderName(path), isDirectory: true)
            guard seenDirs.insert(dir.path).inserted,
                  let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            files += items.filter { $0.pathExtension == "jsonl" }
        }
        return newest(files, limit: limit).compactMap { file in
            summary(of: file, harness: .claudeCode).map { (file, $0) }
        }
    }

    // MARK: Codex storage

    private struct CodexHead: Sendable { let id: String; let cwd: String; let originator: String? }

    private func codexSessions(projectDir: URL, limit: Int) -> [(URL, TranscriptSummary)] {
        let cutoff = now().addingTimeInterval(-Self.codexLookback)
        guard let enumerator = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var candidates: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            if let modified = FileStamp(url)?.modified, modified >= cutoff { candidates.append(url) }
        }
        let variants = Set(Self.pathVariants(projectDir))
        var matched: [URL] = []
        for url in newest(candidates, limit: 400) {
            guard let stamp = FileStamp(url) else { continue }
            let head: CodexHead?
            if let cached = codexHeads[url.path], cached.stamp.modified == stamp.modified || cached.head != nil {
                head = cached.head
            } else {
                head = Self.readCodexHead(url)
                codexHeads[url.path] = (stamp, head)
            }
            guard let head, variants.contains(head.cwd) || Self.samePath(head.cwd, projectDir) else { continue }
            matched.append(url)
            if matched.count >= limit { break }
        }
        return matched.compactMap { file in summary(of: file, harness: .codex).map { (file, $0) } }
    }

    /// Reads `session_meta` from the first line (which can be long: it embeds instructions).
    private static func readCodexHead(_ url: URL) -> CodexHead? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while data.count < 4 << 20, let chunk = try? handle.read(upToCount: 64 << 10), !chunk.isEmpty {
            if let nl = chunk.firstIndex(of: 0x0A) { data.append(chunk[chunk.startIndex..<nl]); break }
            data.append(chunk)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = payload["id"] as? String, let cwd = payload["cwd"] as? String else { return nil }
        return CodexHead(id: id, cwd: cwd, originator: payload["originator"] as? String)
    }

    // MARK: Summaries (cached by mtime + size)

    private func summary(of file: URL, harness: AgentCLIKind) -> TranscriptSummary? {
        guard let stamp = FileStamp(file) else { return nil }
        if let cached = summaries[file.path], cached.stamp == stamp { return cached.summary }
        guard let summary = Self.summarize(file: file, harness: harness, modified: stamp.modified) else { return nil }
        summaries[file.path] = (stamp, summary)
        return summary
    }

    static func summarize(file: URL, harness: AgentCLIKind, modified: Date) -> TranscriptSummary? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var builder = TranscriptSummary.Builder(harness: harness)
        var framer = NDJSONFramer()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            for line in framer.append(chunk) { builder.add(line) }
        }
        if let rest = framer.finish() { builder.add(rest) }
        let fallbackID = harness == .claudeCode ? file.deletingPathExtension().lastPathComponent : nil
        return builder.build(updatedAt: modified, fallbackID: fallbackID)
    }

    // MARK: Helpers

    private func newest(_ files: [URL], limit: Int) -> [URL] {
        files.compactMap { url in FileStamp(url).map { (url, $0.modified) } }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// The project path as written, standardized and with symlinks resolved. Foundation strips a
    /// leading `/private` when it standardizes or resolves, but the CLIs record the real path
    /// (`/private/tmp/…`), so that form is added back for `/tmp`, `/var` and `/etc`.
    static func pathVariants(_ url: URL) -> [String] {
        var out: [String] = []
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        for path in [url.path, url.standardizedFileURL.path, resolved] where !out.contains(path) { out.append(path) }
        for path in out where ["/tmp/", "/var/", "/etc/"].contains(where: { path.hasPrefix($0) }) {
            if !out.contains("/private" + path) { out.append("/private" + path) }
        }
        return out
    }

    static func samePath(_ path: String, _ url: URL) -> Bool {
        let other = URL(fileURLWithPath: path)
        return Set(pathVariants(url)).intersection(pathVariants(other)).isEmpty == false
    }

    /// One line, whitespace collapsed, cut to `titleLimit` with an ellipsis.
    static func title(from text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > titleLimit ? String(flat.prefix(titleLimit - 1)) + "…" : flat
    }
}

nonisolated struct FileStamp: Equatable, Sendable {
    let modified: Date
    let size: Int

    init?(_ url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modified = values.contentModificationDate else { return nil }
        self.modified = modified
        size = values.fileSize ?? 0
    }
}

// MARK: - Transcript parsing

/// What `sessions()` needs from a transcript, built in one pass. Only short strings are kept.
nonisolated struct TranscriptSummary: Equatable, Sendable {
    let id: String
    let title: String
    let firstPrompt: String
    let messageCount: Int
    let updatedAt: Date
    /// Codex `originator == "luna"` (Luna's app-server clientInfo name).
    let originatedInLuna: Bool

    struct Builder {
        let harness: AgentCLIKind
        private var id: String?
        private var firstPrompt: String?
        private var aiTitle: String?
        private var count = 0
        private var originatedInLuna = false

        init(harness: AgentCLIKind) { self.harness = harness }

        mutating func add(_ line: Data) {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            switch harness {
            case .claudeCode: addClaude(object)
            case .codex: addCodex(object)
            }
        }

        private mutating func addClaude(_ o: [String: Any]) {
            if id == nil, let sid = o["sessionId"] as? String { id = sid }
            if o["type"] as? String == "ai-title", let t = o["aiTitle"] as? String, !t.isEmpty { aiTitle = t }
            for entry in TranscriptMapper.claude(o) {
                switch entry {
                case .user(let text):
                    count += 1
                    if firstPrompt == nil { firstPrompt = text }
                case .assistant: count += 1
                default: break
                }
            }
        }

        private mutating func addCodex(_ o: [String: Any]) {
            if o["type"] as? String == "session_meta", let p = o["payload"] as? [String: Any] {
                if id == nil { id = p["id"] as? String }
                if (p["originator"] as? String)?.lowercased() == "luna" { originatedInLuna = true }
            }
            for entry in TranscriptMapper.codex(o) {
                switch entry {
                case .user(let text):
                    count += 1
                    if firstPrompt == nil { firstPrompt = text }
                case .assistant: count += 1
                default: break
                }
            }
        }

        func build(updatedAt: Date, fallbackID: String?) -> TranscriptSummary? {
            guard let id = id ?? fallbackID else { return nil }
            let prompt = firstPrompt.map(SessionSync.title(from:)) ?? ""
            let title = aiTitle.map(SessionSync.title(from:)) ?? prompt
            return TranscriptSummary(id: id, title: title, firstPrompt: prompt, messageCount: count,
                                     updatedAt: updatedAt, originatedInLuna: originatedInLuna)
        }
    }
}

/// One transcript entry, normalized across harnesses (no MainActor types, so it is parsed off-main).
nonisolated enum TranscriptEntry: Equatable, Sendable {
    case session(String)
    case user(String)
    case assistant(String)
    case toolStarted(id: String, name: String, summary: String)
    case toolResult(id: String, output: String, isError: Bool)
}

/// Maps transcript records to `TranscriptEntry`s. Sidechains (subagents), meta entries and
/// wrapper messages (`<command-name>`, `<environment_context>`, …) are skipped.
nonisolated enum TranscriptMapper {
    static let outputLimit = 4000

    /// Claude Code `~/.claude/projects/…/<id>.jsonl` record.
    static func claude(_ o: [String: Any]) -> [TranscriptEntry] {
        if o["isSidechain"] as? Bool == true || o["isMeta"] as? Bool == true { return [] }
        let message = o["message"] as? [String: Any]
        switch o["type"] as? String {
        case "user":
            if let text = message?["content"] as? String {
                return userText(text).map { [.user($0)] } ?? []
            }
            var out: [TranscriptEntry] = []
            for block in message?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = userText(block["text"] as? String) { out.append(.user(text)) }
                case "tool_result":
                    out.append(.toolResult(id: block["tool_use_id"] as? String ?? "",
                                           output: clip(resultText(block["content"])),
                                           isError: block["is_error"] as? Bool == true))
                default: break
                }
            }
            return out
        case "assistant":
            var out: [TranscriptEntry] = []
            for block in message?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { out.append(.assistant(text)) }
                case "tool_use":
                    out.append(.toolStarted(id: block["id"] as? String ?? "", name: block["name"] as? String ?? "tool",
                                            summary: summary(block["input"])))
                default: break
                }
            }
            return out
        default:
            return []
        }
    }

    /// Codex `~/.codex/sessions/YYYY/MM/DD/rollout-….jsonl` record.
    static func codex(_ o: [String: Any]) -> [TranscriptEntry] {
        guard let payload = o["payload"] as? [String: Any] else { return [] }
        switch o["type"] as? String {
        case "session_meta":
            return (payload["id"] as? String).map { [.session($0)] } ?? []
        case "response_item":
            switch payload["type"] as? String {
            case "message":
                let blocks = payload["content"] as? [[String: Any]] ?? []
                switch payload["role"] as? String {
                case "user":
                    return blocks.compactMap { b in
                        b["type"] as? String == "input_text" ? userText(b["text"] as? String).map(TranscriptEntry.user) : nil
                    }
                case "assistant":
                    let text = blocks.compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }.joined()
                    return text.isEmpty ? [] : [.assistant(text)]
                default:
                    return []
                }
            case "function_call", "custom_tool_call":
                var input: Any? = payload["input"]
                if let args = payload["arguments"] as? String {
                    input = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) ?? args
                }
                return [.toolStarted(id: payload["call_id"] as? String ?? "", name: payload["name"] as? String ?? "tool",
                                     summary: summary(input))]
            case "function_call_output", "custom_tool_call_output":
                let output = payload["output"]
                var text = resultText(output)
                if let object = output as? [String: Any], let content = object["content"] { text = resultText(content) }
                return [.toolResult(id: payload["call_id"] as? String ?? "", output: clip(text), isError: false)]
            default:
                return []
            }
        default:
            return []
        }
    }

    /// A real user prompt, or nil for empty / wrapper text (`<command-name>…`, `<environment_context>`…).
    static func userText(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    static func resultText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
    }

    static func summary(_ input: Any?, limit: Int = 300) -> String {
        let preferred = ["command", "cmd", "file_path", "path", "url", "pattern", "query", "description"]
        if let object = input as? [String: Any] {
            for key in preferred {
                if let value = object[key] as? String, !value.isEmpty { return clipLine(value, limit) }
                if let parts = object[key] as? [String], !parts.isEmpty { return clipLine(parts.joined(separator: " "), limit) }
            }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                return clipLine(String(decoding: data, as: UTF8.self), limit)
            }
        }
        if let s = input as? String { return clipLine(s, limit) }
        return ""
    }

    static func clipLine(_ s: String, _ limit: Int) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func clip(_ s: String) -> String {
        s.count > outputLimit ? String(s.prefix(outputLimit)) + "…" : s
    }
}

/// Turns appended transcript lines into the `CLIEvent`s `DevThreadState` renders.
nonisolated struct TranscriptTailer {
    let harness: AgentCLIKind
    private var announced = false

    init(harness: AgentCLIKind) { self.harness = harness }

    mutating func events(forLine line: Data) -> [CLIEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return [] }
        var out: [CLIEvent] = []
        if harness == .claudeCode, !announced, let id = object["sessionId"] as? String {
            announced = true
            out.append(.sessionStarted(id: id))
        }
        let entries = harness == .claudeCode ? TranscriptMapper.claude(object) : TranscriptMapper.codex(object)
        for entry in entries {
            switch entry {
            case .session(let id):
                if !announced { announced = true; out.append(.sessionStarted(id: id)) }
            case .user(let text): out.append(.userMessage(text))
            case .assistant(let text): out.append(.messageDone(text))
            case .toolStarted(let id, let name, let summary): out.append(.toolStarted(id: id, name: name, summary: summary))
            case .toolResult(let id, let output, let isError):
                if !output.isEmpty { out.append(.toolOutput(id: id, text: output)) }
                out.append(.toolFinished(id: id, isError: isError))
            }
        }
        return out
    }
}

// MARK: - Live process detection

/// A `claude` / `codex` process running outside Luna.
nonisolated struct AgentProcess: Equatable, Sendable {
    let pid: pid_t
    let harness: AgentCLIKind
    let cwd: String
}

/// Finds running agent CLIs and their working directories with libproc (no shelling out).
/// Luna's own children are excluded: those are Luna sessions, not terminals.
nonisolated enum LiveProcessScanner {
    static func agentProcesses() -> [AgentProcess] {
        let own = Set(CLIProcess.descendants(of: getpid()) + [getpid()])
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        var found: [AgentProcess] = []
        for pid in pids.prefix(Int(bytes)) where pid > 0 && !own.contains(pid) {
            guard let harness = harness(arguments: arguments(of: pid)), let cwd = workingDirectory(of: pid) else { continue }
            found.append(AgentProcess(pid: pid, harness: harness, cwd: cwd))
        }
        return found
    }

    /// Which harness argv[0] / argv[1] belong to ("claude", "/…/bin/codex", `node …/codex`).
    static func harness(arguments: [String]) -> AgentCLIKind? {
        for arg in arguments.prefix(2) {
            switch (arg as NSString).lastPathComponent {
            case "claude": return .claudeCode
            case "codex": return arguments.contains("app-server") ? nil : .codex
            default: continue
            }
        }
        return nil
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// argv via `KERN_PROCARGS2` (first two arguments are enough).
    static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // exec path
        while index < size, buffer[index] == 0 { index += 1 } // padding
        var args: [String] = []
        while index < size, args.count < min(Int(argc), 3) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}

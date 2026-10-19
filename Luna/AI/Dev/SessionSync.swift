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
    /// Where the session is live right now: `.luna` (a Luna terminal or headless run, see
    /// `LunaActiveSessions`), `.externalTerminal` (a CLI outside Luna; its pid when libproc
    /// found the process, nil when only the recent write gave it away), nil = not live.
    var liveLocation: SessionLocation? = nil
    /// Last model the transcript recorded (Claude `message.model`, Codex `turn_context.model`).
    var model: String? = nil

    /// Live in Luna or outside it. (`isLive` alone means "outside Luna": the read-only case.)
    var isLiveAnywhere: Bool { liveLocation != nil }
    var ref: DevSessionRef { DevSessionRef(harness: harness, id: id, projectDir: projectDir) }
}

/// Where a session is being written right now.
nonisolated enum SessionLocation: Equatable, Hashable, Sendable {
    /// Luna runs it (its terminal or a headless adapter).
    case luna
    /// A CLI outside Luna (Terminal, iTerm, an IDE). pid nil = found only by a recent write.
    case externalTerminal(pid: pid_t?)
}

/// Enough to resume a session: harness, id and the folder it runs in.
nonisolated struct DevSessionRef: Equatable, Hashable, Sendable {
    /// `id` as a safe command-line value: letters, digits, `_` and `-`, never starting with `-`
    /// (transcript data must not turn into a CLI option). nil when it is not.
    static func validID(_ id: String?) -> String? {
        guard let id, !id.isEmpty, id.count <= 128, id.first != "-",
              id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F || $0 == 0x2D })
        else { return nil }
        return id
    }

    let harness: AgentCLIKind
    let id: String
    let projectDir: URL
}

/// Session ids Luna is running right now (terminal or headless), readable from any thread.
/// `DevSession` registers and unregisters ids; `SessionSync` reports them as `.luna`.
nonisolated final class LunaActiveSessions: @unchecked Sendable {
    static let shared = LunaActiveSessions()
    private let lock = NSLock()
    private var ids: [String: Int] = [:]

    func register(_ id: String) { lock.lock(); ids[id, default: 0] += 1; lock.unlock() }
    func unregister(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard let n = ids[id] else { return }
        if n <= 1 { ids[id] = nil } else { ids[id] = n - 1 }
    }
    func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return ids[id] != nil }
    var all: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(ids.keys) }
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
    static let shared = SessionSync(indexURL: SessionIndexStore.defaultURL)

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
    private let indexURL: URL?
    private var indexLoaded = false
    private var indexDirty = false
    // Liveness polling runs every few seconds per open session: keep it from walking
    // ~/.codex/sessions or reading every process's arguments each time. Wall-clock TTLs.
    private var processCache: (at: Date, list: [AgentProcess])?
    private var rolloutCache: (at: Date, list: [(URL, FileStamp)])?
    private var newestCache: [String: (at: Date, id: String?)] = [:]
    private static let processTTL: TimeInterval = 3
    private static let listingTTL: TimeInterval = 10

    init(claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true),
         codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
         processes: @escaping @Sendable () -> [AgentProcess] = { LiveProcessScanner.agentProcesses() },
         now: @escaping @Sendable () -> Date = { Date() },
         resumeStore: AgentCLIResumeStore = AgentCLIResumeStore(),
         indexURL: URL? = nil) {
        self.indexURL = indexURL
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.processes = processes
        self.now = now
        self.resumeStore = resumeStore
    }

    /// Sessions for `projectDir`, newest first, both harnesses. `excluding` drops ids Luna is
    /// running itself right now (pass `DevSessionController.shared.activeSessionID`).
    func sessions(projectDir: URL, excluding: Set<String> = [], limit: Int = 30) -> [ExternalSession] {
        loadIndexIfNeeded()
        defer { saveIndexIfNeeded() }
        let live = processes()
        let claude = claudeSessions(projectDir: projectDir, limit: limit)
        let codex = codexSessions(projectDir: projectDir, limit: limit)
        var out: [ExternalSession] = []
        for (kind, found) in [(AgentCLIKind.claudeCode, claude), (.codex, codex)] {
            let newest = found.max { $0.1.updatedAt < $1.1.updatedAt }?.1.id
            let pid = live.first { $0.harness == kind && Self.samePath($0.cwd, projectDir) }?.pid
            for (file, summary) in found where !excluding.contains(summary.id) {
                out.append(makeSession(kind: kind, file: file, projectDir: projectDir, summary: summary,
                                       processPID: pid, isNewest: summary.id == newest))
            }
        }
        return Array(out.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    /// Every session across both harnesses and all projects, newest first (T3 Code's
    /// AgentSessionScanner does the same walk: Claude project folders + Codex rollouts, grouped
    /// by the transcript's own `cwd`; MIT, apps/server/src/project/AgentSessionScanner.ts).
    /// Only titles / first prompts (truncated) are kept in memory; nothing is written or logged.
    func allSessions(limit: Int = 50) -> [ExternalSession] {
        loadIndexIfNeeded()
        defer { saveIndexIfNeeded() }
        var files: [(URL, AgentCLIKind, FileStamp)] = []
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            where file.pathExtension == "jsonl" {
                if let stamp = FileStamp(file) { files.append((file, .claudeCode, stamp)) }
            }
        }
        files += codexRollouts(since: now().addingTimeInterval(-Self.codexLookback)).map { ($0.0, .codex, $0.1) }
        let newestFiles = files.sorted { $0.2.modified > $1.2.modified }.prefix(limit)
        let live = processes()
        var found: [(URL, AgentCLIKind, URL, TranscriptSummary)] = []
        for (file, kind, stamp) in newestFiles {
            guard let summary = summary(of: file, harness: kind, stamp: stamp) else { continue }
            let cwd = summary.cwd ?? (kind == .codex ? codexHead(file, stamp: stamp)?.cwd : nil)
                ?? ProjectFinder.decodeClaudeFolderName(file.deletingLastPathComponent().lastPathComponent).first
            guard let cwd else { continue }
            found.append((file, kind, URL(fileURLWithPath: cwd, isDirectory: true), summary))
        }
        var newestPerProject: [String: String] = [:]
        for (_, kind, dir, summary) in found {
            let key = "\(kind.rawValue)|\(dir.standardizedFileURL.path)"
            if newestPerProject[key] == nil { newestPerProject[key] = summary.id } // `found` is newest first
        }
        return found.map { file, kind, dir, summary in
            let pid = live.first { $0.harness == kind && Self.samePath($0.cwd, dir) }?.pid
            return makeSession(kind: kind, file: file, projectDir: dir, summary: summary, processPID: pid,
                               isNewest: newestPerProject["\(kind.rawValue)|\(dir.standardizedFileURL.path)"] == summary.id)
        }
    }

    private func makeSession(kind: AgentCLIKind, file: URL, projectDir: URL, summary: TranscriptSummary,
                             processPID: pid_t?, isNewest: Bool) -> ExternalSession {
        let startedInLuna = resumeStore.isLunaSession(summary.id, projectDir: projectDir) || summary.originatedInLuna
        let inLuna = LunaActiveSessions.shared.contains(summary.id)
        let isLive = !inLuna && Self.isLive(updatedAt: summary.updatedAt, now: now(), processInProject: processPID != nil,
                                            isNewest: isNewest, startedInLuna: startedInLuna)
        let location: SessionLocation? = inLuna ? .luna : (isLive ? .externalTerminal(pid: processPID) : nil)
        return ExternalSession(harness: kind, id: summary.id, file: file, projectDir: projectDir,
                               title: summary.title, firstPrompt: summary.firstPrompt,
                               updatedAt: summary.updatedAt, isLive: isLive,
                               messageCount: summary.messageCount, startedInLuna: startedInLuna,
                               liveLocation: location, model: summary.model)
    }

    /// Where `session` is live now (`.luna`, an outside CLI, or nil = resumable).
    func liveLocation(of session: ExternalSession) -> SessionLocation? {
        if LunaActiveSessions.shared.contains(session.id) { return .luna }
        guard isStillLive(session) else { return nil }
        let pid = cachedProcesses().first { $0.harness == session.harness && Self.samePath($0.cwd, session.projectDir) }?.pid
        return .externalTerminal(pid: pid)
    }

    /// The transcript for a known id: Claude `<project folder>/<id>.jsonl`, Codex
    /// `rollout-…-<id>.jsonl`. nil until the CLI has written it.
    func sessionFile(harness: AgentCLIKind, id: String, projectDir: URL) -> URL? {
        switch harness {
        case .claudeCode:
            for path in Self.pathVariants(projectDir) {
                let file = claudeRoot.appendingPathComponent(Self.claudeProjectFolderName(path), isDirectory: true)
                    .appendingPathComponent("\(id).jsonl")
                if FileManager.default.fileExists(atPath: file.path) { return file }
            }
            return nil
        case .codex:
            return cachedCodexRollouts().first { $0.0.lastPathComponent.hasSuffix("-\(id).jsonl") }?.0
        }
    }

    private func cachedProcesses() -> [AgentProcess] {
        let wall = Date()
        if let processCache, wall.timeIntervalSince(processCache.at) < Self.processTTL { return processCache.list }
        let list = processes()
        processCache = (wall, list)
        return list
    }

    /// Every rollout file, listing cached for `listingTTL` (used for id -> file lookups).
    private func cachedCodexRollouts() -> [(URL, FileStamp)] {
        let wall = Date()
        if let rolloutCache, wall.timeIntervalSince(rolloutCache.at) < Self.listingTTL { return rolloutCache.list }
        let list = codexRollouts(since: .distantPast)
        rolloutCache = (wall, list)
        return list
    }

    /// Rollout files modified since `since`.
    private func codexRollouts(since: Date) -> [(URL, FileStamp)] {
        guard let enumerator = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return [] }
        var out: [(URL, FileStamp)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            guard let stamp = FileStamp(url) else { continue }
            if since == .distantPast || stamp.modified >= since { out.append((url, stamp)) }
        }
        return out
    }

    private func codexHead(_ url: URL, stamp: FileStamp? = nil) -> CodexHead? {
        guard let stamp = stamp ?? FileStamp(url) else { return nil }
        if let cached = codexHeads[url.path], cached.stamp.modified == stamp.modified || cached.head != nil { return cached.head }
        let head = Self.readCodexHead(url)
        codexHeads[url.path] = (stamp, head)
        indexDirty = true
        return head
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
        let live = cachedProcesses().contains { $0.harness == session.harness && Self.samePath($0.cwd, session.projectDir) }
        let key = "\(session.harness.rawValue)|\(session.projectDir.path)"
        let wall = Date()
        let newest: String?
        if let hit = newestCache[key], wall.timeIntervalSince(hit.at) < Self.listingTTL {
            newest = hit.id
        } else {
            newest = sessions(projectDir: session.projectDir, limit: 5).first { $0.harness == session.harness }?.id
            newestCache[key] = (wall, newest)
        }
        return Self.isLive(updatedAt: updated, now: now(), processInProject: live,
                           isNewest: newest == nil || newest == session.id, startedInLuna: session.startedInLuna)
    }

    /// History first, then new entries as they are appended (polled every `interval`).
    /// Ends when the consumer stops iterating.
    nonisolated func follow(_ session: ExternalSession, interval: TimeInterval = 0.4) -> AsyncStream<CLIEvent> {
        follow(file: session.file, harness: session.harness, interval: interval)
    }

    /// Tails any transcript file; waits for it to appear (a new Claude session writes its
    /// file only after the first prompt).
    nonisolated func follow(file: URL, harness: AgentCLIKind, interval: TimeInterval = 0.4,
                            maxHistoryBytes: UInt64 = SessionSync.followHistoryBytes) -> AsyncStream<CLIEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: CLIEvent.self, bufferingPolicy: .unbounded)
        let task = Task.detached(priority: .utility) {
            var tailer = TranscriptTailer(harness: harness)
            var offset: UInt64 = 0
            var started = false
            var skipPartialLine = false
            var framer = NDJSONFramer()
            while !Task.isCancelled {
                guard let handle = try? FileHandle(forReadingFrom: file) else {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    continue
                }
                let size = (try? handle.seekToEnd()) ?? 0
                if !started {
                    started = true
                    let start = Self.tailStartOffset(size: size, maxBytes: maxHistoryBytes)
                    if start > 0 {
                        // Begin one byte early and drop up to the first newline, so replay starts on a line boundary.
                        offset = start - 1
                        skipPartialLine = true
                        continuation.yield(.historyTruncated(skippedBytes: start))
                    }
                } else if size < offset { offset = 0; framer = NDJSONFramer(); skipPartialLine = false } // truncated or replaced
                if size > offset {
                    try? handle.seek(toOffset: offset)
                    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                        offset += UInt64(chunk.count)
                        var data = chunk
                        if skipPartialLine {
                            guard let nl = data.firstIndex(of: 0x0A) else { continue }
                            data = data[data.index(after: nl)...]
                            skipPartialLine = false
                        }
                        for line in framer.append(data) {
                            for event in tailer.events(forLine: line) { continuation.yield(event) }
                        }
                        await Task.yield()
                        if Task.isCancelled { break }
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

    /// History replay reads at most this much from the end of a transcript.
    static let followHistoryBytes: UInt64 = 8 << 20

    /// Where replay starts: 0, or `size - maxBytes` for a larger file.
    nonisolated static func tailStartOffset(size: UInt64, maxBytes: UInt64) -> UInt64 {
        size > maxBytes ? size - maxBytes : 0
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
        return newest(files, limit: limit).compactMap { file, stamp in
            summary(of: file, harness: .claudeCode, stamp: stamp).map { (file, $0) }
        }
    }

    // MARK: Codex storage

    struct CodexHead: Sendable { let id: String; let cwd: String; let originator: String? }

    private func codexSessions(projectDir: URL, limit: Int) -> [(URL, TranscriptSummary)] {
        let cutoff = now().addingTimeInterval(-Self.codexLookback)
        guard let enumerator = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var candidates: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            if let stamp = FileStamp(url), stamp.modified >= cutoff { candidates.append(url) }
        }
        let variants = Set(Self.pathVariants(projectDir))
        var matched: [(URL, FileStamp)] = []
        for (url, stamp) in newest(candidates, limit: 400) {
            let head: CodexHead?
            if let cached = codexHeads[url.path], cached.stamp.modified == stamp.modified || cached.head != nil {
                head = cached.head
            } else {
                head = Self.readCodexHead(url)
                codexHeads[url.path] = (stamp, head)
                indexDirty = true
            }
            guard let head, variants.contains(head.cwd) || Self.samePath(head.cwd, projectDir) else { continue }
            matched.append((url, stamp))
            if matched.count >= limit { break }
        }
        return matched.compactMap { file, stamp in summary(of: file, harness: .codex, stamp: stamp).map { (file, $0) } }
    }

    /// Reads `session_meta` from the first line (which can be long: it embeds instructions).
    static func readCodexHead(_ url: URL) -> CodexHead? {
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
              let id = DevSessionRef.validID(payload["id"] as? String), let cwd = payload["cwd"] as? String else { return nil }
        return CodexHead(id: id, cwd: cwd, originator: payload["originator"] as? String)
    }

    // MARK: Summaries (cached by mtime + size)

    private func summary(of file: URL, harness: AgentCLIKind, stamp known: FileStamp? = nil) -> TranscriptSummary? {
        guard let stamp = known ?? FileStamp(file) else { return nil }
        if let cached = summaries[file.path], cached.stamp.matches(stamp) {
            var hit = cached.summary
            hit.updatedAt = stamp.modified
            return hit
        }
        guard let summary = Self.summarize(file: file, harness: harness, modified: stamp.modified) else { return nil }
        summaries[file.path] = (stamp, summary)
        indexDirty = true
        return summary
    }

    // MARK: Persisted index

    private func loadIndexIfNeeded() {
        guard !indexLoaded else { return }
        indexLoaded = true
        guard let indexURL else { return }
        let snapshot = SessionIndexStore(url: indexURL).load()
        for (path, entry) in snapshot.summaries where summaries[path] == nil {
            summaries[path] = (FileStamp(modified: Date(timeIntervalSinceReferenceDate: entry.mtime), size: entry.size), entry.summary)
        }
        for (path, entry) in snapshot.heads where codexHeads[path] == nil {
            codexHeads[path] = (FileStamp(modified: Date(timeIntervalSinceReferenceDate: entry.mtime), size: entry.size), entry.head)
        }
    }

    private func saveIndexIfNeeded() {
        guard indexDirty, let indexURL else { return }
        indexDirty = false
        prune(&summaries, &codexHeads)
        var snapshot = SessionIndexStore.Snapshot()
        for (path, v) in summaries { snapshot.summaries[path] = .init(mtime: v.stamp.modified.timeIntervalSinceReferenceDate, size: v.stamp.size, summary: v.summary) }
        for (path, v) in codexHeads { if let head = v.head { snapshot.heads[path] = .init(mtime: v.stamp.modified.timeIntervalSinceReferenceDate, size: v.stamp.size, head: head) } }
        SessionIndexStore(url: indexURL).save(snapshot)
    }

    /// Drops in-memory entries for files that no longer exist (cheap: one stat each, only after a save).
    private func prune(_ s: inout [String: (stamp: FileStamp, summary: TranscriptSummary)],
                       _ h: inout [String: (stamp: FileStamp, head: CodexHead?)]) {
        let fm = FileManager.default
        for path in s.keys where !fm.fileExists(atPath: path) { s[path] = nil }
        for path in h.keys where !fm.fileExists(atPath: path) { h[path] = nil }
    }

    /// Transcripts larger than this are summarized from their head and tail only (id, cwd and
    /// first prompt sit at the start, the latest model and title near the end); their
    /// `messageCount` is then a lower bound. Keeps a cold "All sessions" load to a few seconds.
    static let fullParseLimit: UInt64 = 2 << 20
    static let headTailBytes = 512 << 10

    static func summarize(file: URL, harness: AgentCLIKind, modified: Date) -> TranscriptSummary? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var builder = TranscriptSummary.Builder(harness: harness)
        var framer = NDJSONFramer()
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        if size > fullParseLimit {
            if let head = try? handle.read(upToCount: headTailBytes) {
                for line in framer.append(head) { builder.add(line) } // the cut last line is dropped
            }
            framer = NDJSONFramer()
            try? handle.seek(toOffset: size - UInt64(headTailBytes))
            if let tail = try? handle.readToEnd(), let firstBreak = tail.firstIndex(of: 0x0A) {
                for line in framer.append(tail[tail.index(after: firstBreak)...]) { builder.add(line) }
            }
        } else {
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                for line in framer.append(chunk) { builder.add(line) }
            }
        }
        if let rest = framer.finish() { builder.add(rest) }
        let fallbackID = harness == .claudeCode ? file.deletingPathExtension().lastPathComponent : nil
        return builder.build(updatedAt: modified, fallbackID: fallbackID)
    }

    // MARK: Helpers

    private func newest(_ files: [URL], limit: Int) -> [(URL, FileStamp)] {
        files.compactMap { url in FileStamp(url).map { (url, $0) } }
            .sorted { $0.1.modified > $1.1.modified }
            .prefix(limit)
            .map { $0 }
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

    init(modified: Date, size: Int) {
        self.modified = modified
        self.size = size
    }

    /// Same size and mtime within 1 ms (the persisted index stores mtime as a Double).
    func matches(_ other: FileStamp) -> Bool {
        size == other.size && abs(modified.timeIntervalSince(other.modified)) < 0.001
    }

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
    var updatedAt: Date
    /// Codex `originator == "luna"` (Luna's app-server clientInfo name).
    let originatedInLuna: Bool
    /// Working directory the CLI recorded (Claude entries' `cwd`, Codex `session_meta.cwd`).
    var cwd: String? = nil
    /// Last model recorded.
    var model: String? = nil

    struct Builder {
        let harness: AgentCLIKind
        private var id: String?
        private var firstPrompt: String?
        private var aiTitle: String?
        private var count = 0
        private var originatedInLuna = false
        private var cwd: String?
        private var model: String?

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
            if cwd == nil, let c = o["cwd"] as? String, !c.isEmpty { cwd = c }
            if o["type"] as? String == "assistant", let m = (o["message"] as? [String: Any])?["model"] as? String,
               !m.isEmpty, !m.hasPrefix("<") { model = m }
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
                if cwd == nil, let c = p["cwd"] as? String, !c.isEmpty { cwd = c }
            }
            if o["type"] as? String == "turn_context", let m = (o["payload"] as? [String: Any])?["model"] as? String, !m.isEmpty {
                model = m
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
            guard let id = DevSessionRef.validID(id) ?? DevSessionRef.validID(fallbackID) else { return nil }
            let prompt = firstPrompt.map(SessionSync.title(from:)) ?? ""
            let title = aiTitle.map(SessionSync.title(from:)) ?? prompt
            return TranscriptSummary(id: id, title: title, firstPrompt: prompt, messageCount: count,
                                     updatedAt: updatedAt, originatedInLuna: originatedInLuna, cwd: cwd, model: model)
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
        if o["isSidechain"] as? Bool == true || o["isMeta"] as? Bool == true
            || o["isCompactSummary"] as? Bool == true { return [] }
        let message = o["message"] as? [String: Any]
        switch o["type"] as? String {
        case "user":
            if let text = message?["content"] as? String {
                return userText(text).map { [.user($0)] } ?? []
            }
            var out: [TranscriptEntry] = []
            var typed: [String] = []
            for block in message?["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = userText(block["text"] as? String) { typed.append(text) }
                case "image", "document":
                    typed.append(attachmentChip(block["type"] as? String))
                case "tool_result":
                    out.append(.toolResult(id: block["tool_use_id"] as? String ?? "",
                                           output: clip(resultText(block["content"])),
                                           isError: block["is_error"] as? Bool == true))
                default: break
                }
            }
            if typed.contains(where: { !isChip($0) }) {
                out.insert(.user(typed.joined(separator: "\n")), at: 0)
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
            return DevSessionRef.validID(payload["id"] as? String).map { [.session($0)] } ?? []
        case "response_item":
            switch payload["type"] as? String {
            case "message":
                let blocks = payload["content"] as? [[String: Any]] ?? []
                switch payload["role"] as? String {
                case "user":
                    var parts: [String] = []
                    for b in blocks {
                        switch b["type"] as? String {
                        case "input_text": if let t = userText(b["text"] as? String) { parts.append(t) }
                        case "input_image": parts.append(attachmentChip("image"))
                        default: break
                        }
                    }
                    return parts.isEmpty ? [] : [.user(parts.joined(separator: "\n"))]
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

    /// Wrapper blocks the CLIs add around (or beside) what the user typed.
    private static let wrapperTags = ["system-reminder", "command-name", "command-message", "command-args",
                                      "local-command-stdout", "local-command-stderr", "local-command-caveat",
                                      "user-prompt-submit-hook", "environment_context", "user_instructions",
                                      "ide_opened_file", "ide_selection", "ide_diagnostics", "task-notification",
                                      "INSTRUCTIONS", "permissions instructions", "collaboration_mode",
                                      "bash-input", "bash-stdout", "bash-stderr"]

    static func attachmentChip(_ kind: String?) -> String { kind == "document" ? "[Attachment]" : "[Image]" }
    private static func isChip(_ s: String) -> Bool { s == "[Image]" || s == "[Attachment]" }

    /// What the user typed: wrapper blocks removed, pasted-content tags unwrapped. Nil for empty
    /// text, pure wrappers (`<command-name>…`, `<environment_context>`) and injected instructions.
    static func userText(_ text: String?) -> String? {
        guard var t = text else { return nil }
        var unclosedWrapper = false
        for tag in wrapperTags { t = removingBlocks(of: tag, from: t, unclosed: &unclosedWrapper) }
        // Pasted text keeps its content, loses the tags (bounded pattern: no runaway scan on an unclosed "<").
        t = t.replacingOccurrences(of: "</?pasted[-_ ]content[^>]{0,200}>", with: "", options: .regularExpression)
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !unclosedWrapper,
              !trimmed.hasPrefix("# AGENTS.md instructions"),
              !trimmed.hasPrefix("Caveat: The messages below were generated by the user while running local commands"),
              !trimmed.hasPrefix("This session is being continued from a previous conversation") else { return nil }
        return trimmed
    }

    /// Removes `<tag …>…</tag>` blocks with literal searches (linear; no lazy regex). An opening tag
    /// with no closing one sets `unclosed` (the message is then a truncated wrapper, not user text).
    private static func removingBlocks(of tag: String, from text: String, unclosed: inout Bool) -> String {
        let open = "<" + tag, close = "</" + tag + ">"
        var out = ""
        var cursor = text.startIndex
        while let start = text.range(of: open, options: .literal, range: cursor..<text.endIndex) {
            let after = start.upperBound
            guard after < text.endIndex, text[after] == ">" || text[after].isWhitespace else {
                out += text[cursor..<after]; cursor = after; continue // "<tagx": a different tag
            }
            guard let end = text.range(of: close, options: .literal, range: after..<text.endIndex) else {
                unclosed = true
                out += text[cursor..<start.lowerBound]
                return out
            }
            out += text[cursor..<start.lowerBound]
            cursor = end.upperBound
        }
        out += text[cursor...]
        return out
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
        if harness == .claudeCode, !announced, let id = DevSessionRef.validID(object["sessionId"] as? String) {
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

// MARK: - Persisted index

/// Lightweight JSON index of transcript summaries, keyed by path and valid only while the file's
/// mtime + size match. Stores titles only (never first prompts or transcript content).
nonisolated struct SessionIndexStore: Sendable {
    static let version = 1
    static let maxEntries = 2000

    let url: URL

    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Luna/Dev/session-index.json")
    }

    struct SummaryEntry: Codable, Sendable {
        var mtime: Double
        var size: Int
        var id: String
        var title: String
        var messageCount: Int
        var originatedInLuna: Bool
        var cwd: String?
        var model: String?

        init(mtime: Double, size: Int, summary: TranscriptSummary) {
            self.mtime = mtime; self.size = size
            id = summary.id; title = summary.title; messageCount = summary.messageCount
            originatedInLuna = summary.originatedInLuna; cwd = summary.cwd; model = summary.model
        }

        /// `firstPrompt` is not persisted; it falls back to the title.
        var summary: TranscriptSummary {
            TranscriptSummary(id: id, title: title, firstPrompt: title, messageCount: messageCount,
                              updatedAt: Date(timeIntervalSinceReferenceDate: mtime),
                              originatedInLuna: originatedInLuna, cwd: cwd, model: model)
        }
    }

    struct HeadEntry: Codable, Sendable {
        var mtime: Double
        var size: Int
        var id: String
        var cwd: String
        var originator: String?

        init(mtime: Double, size: Int, head: SessionSync.CodexHead) {
            self.mtime = mtime; self.size = size
            id = head.id; cwd = head.cwd; originator = head.originator
        }

        var head: SessionSync.CodexHead { .init(id: id, cwd: cwd, originator: originator) }
    }

    struct Snapshot: Codable, Sendable {
        var version = SessionIndexStore.version
        var summaries: [String: SummaryEntry] = [:]
        var heads: [String: HeadEntry] = [:]
    }

    /// Empty on a missing file, decode failure or version mismatch.
    func load() -> Snapshot {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.version == Self.version else { return Snapshot() }
        return snapshot
    }

    /// Atomic write, keeping the newest `maxEntries` of each kind. Failures are ignored.
    func save(_ snapshot: Snapshot) {
        var out = snapshot
        out.version = Self.version
        if out.summaries.count > Self.maxEntries {
            let keep = out.summaries.sorted { $0.value.mtime > $1.value.mtime }.prefix(Self.maxEntries)
            out.summaries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if out.heads.count > Self.maxEntries {
            let keep = out.heads.sorted { $0.value.mtime > $1.value.mtime }.prefix(Self.maxEntries)
            out.heads = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(out) else { return }
        PrivateFile.write(data, to: url)
    }
}

/// Files holding prompt-derived text (titles): created 0600 in a 0700 folder, replaced atomically.
nonisolated enum PrivateFile {
    static func write(_ data: Data, to url: URL) {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, url.path) != 0 { try? fm.removeItem(at: temp) }
    }
}

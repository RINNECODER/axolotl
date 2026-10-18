import Foundation

/// A folder the user works in, found without them picking it.
nonisolated struct DevProject: Identifiable, Hashable, Sendable {
    enum Source: String, Hashable, Sendable {
        /// `~/.claude/projects/<encoded cwd>`.
        case claudeSessions
        /// `cwd` in a Codex rollout's `session_meta`.
        case codexSessions
        /// Luna's own recent Dev projects.
        case lunaRecents
        /// A git repo under one of `DevSettings.projectSearchRoots`.
        case gitScan
    }

    var id: String { path }
    let path: String
    /// Folder name.
    let name: String
    /// Newest session file (or Luna recent use); nil when only the git scan found it.
    var lastActivity: Date?
    /// Harnesses with sessions here.
    var harnesses: [HarnessID]
    var sessionCount: Int
    var isGitRepo: Bool
    /// Current branch from `.git/HEAD`; nil when detached or not a repo.
    var branch: String?
    var sources: Set<Source>

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Finds the user's projects the way T3 Code's AgentSessionScanner does (MIT,
/// apps/server/src/project/AgentSessionScanner.ts): walk the agents' own session stores, take
/// each transcript's working directory, keep the ones that still exist as folders, merge them
/// by real path and sort by last activity. Luna adds its recents and an optional shallow git
/// scan of a few common roots.
///
///     let projects = await ProjectFinder.shared.projects()            // cached
///     let fresh = await ProjectFinder.shared.projects(refresh: true)  // rescan
///
/// Read-only and off the main thread (actor). Transcript contents are never kept: only the
/// `cwd` field of the first lines is read. Hidden projects (`DevSettings.hideProject`) are
/// filtered on every call, so hiding needs no rescan.
actor ProjectFinder {
    static let shared = ProjectFinder()

    /// Bytes read from the head of a Claude transcript to find its `cwd` (T3 reads 32 KB).
    static let cwdPrefixBytes = 64 * 1024
    /// Codex rollouts older than this are not scanned.
    static let codexLookback: TimeInterval = 90 * 86_400
    /// Newest Codex rollouts read at most.
    static let codexFileLimit = 1_500
    /// Git scan bounds.
    static let gitScanDepth = 2
    static let gitScanDirectoryLimit = 4_000
    /// Folder names the git scan never enters.
    static let ignoredNames: Set<String> = [
        "node_modules", "Library", "Applications", "Pictures", "Music", "Movies", "Public", "Downloads", "Desktop",
        "DerivedData", "build", "Build", "dist", "target", "Pods", "vendor", "venv", "__pycache__", "Caches",
    ]
    /// Ephemeral folders (scratch sessions, test runs) are not projects.
    static let excludedPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"]

    private let claudeRoot: URL
    private let codexRoot: URL
    private let recents: @Sendable () -> [String]
    private let searchRoots: @Sendable () -> [String]
    private let hidden: @Sendable () -> Set<String>
    private let excludedPrefixes: [String]
    private var cache: [DevProject]?
    private var codexHeads: [String: (Date, SessionSync.CodexHead?)] = [:]

    init(claudeRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true),
         codexRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
         recents: @escaping @Sendable () -> [String] = { DevPrefs.recentProjects() },
         searchRoots: @escaping @Sendable () -> [String] = { DevSettings.storedProjectSearchRoots() },
         hidden: @escaping @Sendable () -> Set<String> = { DevSettings.storedHiddenProjects() },
         excludedPrefixes: [String] = ProjectFinder.excludedPrefixes) {
        self.claudeRoot = claudeRoot
        self.codexRoot = codexRoot
        self.recents = recents
        self.searchRoots = searchRoots
        self.hidden = hidden
        self.excludedPrefixes = excludedPrefixes
    }

    /// Projects newest activity first (git-scan-only projects last, by name). Cached until `refresh`.
    func projects(refresh: Bool = false) async -> [DevProject] {
        if refresh || cache == nil { cache = scan() }
        let hidden = hidden()
        return (cache ?? []).filter { !hidden.contains($0.path) }
    }

    // MARK: Scan

    private struct Accumulator {
        var path: String
        var lastActivity: Date?
        var harnesses: Set<HarnessID> = []
        var sessions = 0
        var sources: Set<DevProject.Source> = []
    }

    private func scan() -> [DevProject] {
        var merged: [String: Accumulator] = [:]
        func add(_ path: String, source: DevProject.Source, harness: HarnessID? = nil, sessions: Int = 0, activity: Date? = nil) {
            guard let key = projectKey(path) else { return }
            var entry = merged[key] ?? Accumulator(path: path)
            entry.sources.insert(source)
            if let harness { entry.harnesses.insert(harness) }
            entry.sessions += sessions
            if let activity { entry.lastActivity = max(entry.lastActivity ?? activity, activity) }
            merged[key] = entry
        }

        for folder in claudeProjectFolders() {
            add(folder.path, source: .claudeSessions, harness: .claudeCode, sessions: folder.sessions, activity: folder.newest)
        }
        for (cwd, stats) in codexProjects() {
            add(cwd, source: .codexSessions, harness: .codex, sessions: stats.count, activity: stats.newest)
        }
        for path in recents() { add(path, source: .lunaRecents) }
        let roots = searchRoots().map { URL(fileURLWithPath: $0, isDirectory: true) }
        for repo in Self.scanGitRepos(roots: roots) { add(repo.path, source: .gitScan) }

        return merged.values.map { entry in
            let git = Self.gitInfo(URL(fileURLWithPath: entry.path, isDirectory: true))
            return DevProject(path: entry.path, name: (entry.path as NSString).lastPathComponent,
                              lastActivity: entry.lastActivity,
                              harnesses: HarnessID.allCases.filter(entry.harnesses.contains),
                              sessionCount: entry.sessions, isGitRepo: git.isRepo, branch: git.branch,
                              sources: entry.sources)
        }.sorted(by: Self.order)
    }

    static func order(_ a: DevProject, _ b: DevProject) -> Bool {
        switch (a.lastActivity, b.lastActivity) {
        case let (x?, y?) where x != y: return x > y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.path.localizedStandardCompare(b.path) == .orderedAscending
        }
    }

    /// Merge key: the real path of an existing, non-excluded folder; nil otherwise.
    private func projectKey(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let spellings = [path, real, "/private" + real]
        if spellings.contains(where: { p in excludedPrefixes.contains { p.hasPrefix($0) || p + "/" == $0 } }) { return nil }
        return real
    }

    // MARK: Claude Code

    private struct ClaudeFolder { let path: String; let sessions: Int; let newest: Date? }

    /// One entry per `~/.claude/projects/<encoded>` folder that maps to an existing directory.
    private func claudeProjectFolders() -> [ClaudeFolder] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [ClaudeFolder] = []
        for dir in dirs {
            let files = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            guard !files.isEmpty else { continue }
            let dated = files.compactMap { f in FileStamp(f).map { (f, $0.modified) } }.sorted { $0.1 > $1.1 }
            guard let path = Self.resolveClaudeFolder(name: dir.lastPathComponent, transcripts: dated.map(\.0)) else { continue }
            out.append(ClaudeFolder(path: path, sessions: files.count, newest: dated.first?.1))
        }
        return out
    }

    /// The real path for a Claude project folder: the decoded name when exactly one existing
    /// directory encodes to it, else the `cwd` the transcripts recorded (the encoding maps every
    /// non-alphanumeric character to "-", so `my-app` and `my_app` collide).
    static func resolveClaudeFolder(name: String, transcripts: [URL], fsRoot: String = "/") -> String? {
        let decoded = decodeClaudeFolderName(name, fsRoot: fsRoot)
        if decoded.count == 1 { return decoded[0] }
        for file in transcripts.prefix(3) {
            if let cwd = claudeCWD(in: file), SessionSync.claudeProjectFolderName(cwd) == name || decoded.isEmpty || decoded.contains(cwd) {
                return cwd
            }
        }
        return decoded.first
    }

    /// Existing directories whose Claude folder name is `name`, found by walking the file
    /// system one component at a time (bounded: at most `maxListings` directory reads, 4 matches).
    static func decodeClaudeFolderName(_ name: String, fsRoot: String = "/", maxListings: Int = 300) -> [String] {
        var matches: [String] = []
        var listings = 0
        let fm = FileManager.default
        func join(_ dir: String, _ child: String) -> String { dir == "/" ? "/" + child : dir + "/" + child }
        // `fsRoot` lets tests decode inside a temp tree: paths are matched relative to it.
        func encoded(_ path: String) -> String {
            let relative = fsRoot == "/" ? path : String(path.dropFirst(fsRoot.count))
            return SessionSync.claudeProjectFolderName(relative.isEmpty ? "/" : relative)
        }
        func walk(_ dir: String) {
            guard matches.count < 4 else { return }
            let enc = encoded(dir)
            if enc == name { matches.append(dir); return }
            guard listings < maxListings else { return }
            listings += 1
            guard let children = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for child in children.sorted() {
                let path = join(dir, child)
                let e = encoded(path)
                guard name == e || name.hasPrefix(e + "-") else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { continue }
                walk(path)
            }
        }
        walk(fsRoot)
        return matches
    }

    /// First `cwd` in the first `cwdPrefixBytes` of a Claude transcript.
    static func claudeCWD(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: cwdPrefixBytes) else { return nil }
        for line in data.split(separator: 0x0A) {
            if let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
               let cwd = o["cwd"] as? String, cwd.hasPrefix("/") { return cwd }
        }
        return nil
    }

    // MARK: Codex

    private func codexProjects() -> [String: (count: Int, newest: Date)] {
        let cutoff = Date().addingTimeInterval(-Self.codexLookback)
        guard let enumerator = FileManager.default.enumerator(at: codexRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [:] }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
            if let modified = FileStamp(url)?.modified, modified >= cutoff { files.append((url, modified)) }
        }
        var out: [String: (count: Int, newest: Date)] = [:]
        for (url, modified) in files.sorted(by: { $0.1 > $1.1 }).prefix(Self.codexFileLimit) {
            let head: SessionSync.CodexHead?
            if let cached = codexHeads[url.path], cached.0 == modified || cached.1 != nil {
                head = cached.1
            } else {
                head = SessionSync.readCodexHead(url)
                codexHeads[url.path] = (modified, head)
            }
            guard let cwd = head?.cwd else { continue }
            let current = out[cwd]
            out[cwd] = ((current?.count ?? 0) + 1, max(current?.newest ?? modified, modified))
        }
        return out
    }

    // MARK: Git

    /// Repos (folders with a `.git` directory) under `roots`, at most `maxDepth` levels down.
    /// Never enters hidden folders, `ignoredNames`, packages, or a repo it already found;
    /// worktrees (`.git` file) are skipped like T3 does. Stops after `maxDirectories` reads.
    static func scanGitRepos(roots: [URL], maxDepth: Int = gitScanDepth, maxDirectories: Int = gitScanDirectoryLimit) -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        var seen = Set<String>()
        var budget = maxDirectories
        var queue: [(URL, Int)] = roots.map { ($0.standardizedFileURL, 0) }
        // A root inside another root (~/Documents under ~) is scanned as its own root, to full depth.
        let rootPaths = Set(queue.map { $0.0.path })
        while !queue.isEmpty, budget > 0 {
            let (dir, depth) = queue.removeFirst()
            guard seen.insert(dir.path).inserted else { continue }
            budget -= 1
            guard let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                             options: [.skipsHiddenFiles]) else { continue }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                guard !ignoredNames.contains(name), !rootPaths.contains(child.standardizedFileURL.path),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                      values.isDirectory == true, values.isPackage != true else { continue }
                var isDir: ObjCBool = false
                let git = child.appendingPathComponent(".git").path
                if fm.fileExists(atPath: git, isDirectory: &isDir) {
                    if isDir.boolValue, seen.insert(child.path).inserted { found.append(child) }
                    continue
                }
                if depth + 1 < maxDepth { queue.append((child, depth + 1)) }
            }
        }
        return found
    }

    /// Whether `dir` is a repo root (`.git` folder, or a worktree's `.git` file) and its branch.
    static func gitInfo(_ dir: URL) -> (isRepo: Bool, branch: String?) {
        let fm = FileManager.default
        let dotGit = dir.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return (false, nil) }
        var gitDir = dotGit
        if !isDir.boolValue {
            // Worktree / submodule: "gitdir: <path>".
            guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return (true, nil) }
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
        }
        guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return (true, nil) }
        let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "ref: refs/heads/"
        return (true, ref.hasPrefix(prefix) ? String(ref.dropFirst(prefix.count)) : nil)
    }
}

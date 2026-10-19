import XCTest
#if AXOLOTL_DEV
@testable import AxolotlDev
#else
@testable import Axolotl
#endif

/// Dev mode round 3: project finder, global session listing, terminal command lines, new-session
/// capture, and Chat ↔ Terminal routing on one `DevSession`. Synthetic fixtures only.
@MainActor
final class DevSessionTests: XCTestCase {

    // MARK: Helpers

    private func scratchDefaults() -> UserDefaults {
        let name = "DevSessionTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// A temp folder with its real (symlink-resolved, /private) path.
    private func scratchDir(_ label: String = "dir") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-devsession-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return URL(fileURLWithPath: realpath(dir.path), isDirectory: true)
    }

    private func mkdir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private func write(_ lines: [[String: Any]], to file: URL, modified: Date? = nil) throws {
        try mkdir(file.deletingLastPathComponent())
        try (lines.map(line).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path) }
    }

    private func realpath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.replacingOccurrences(of: "^/var/", with: "/private/var/", options: .regularExpression)
    }

    private func eventually(_ condition: () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        let ok = await waitUntil(5, condition)
        XCTAssertTrue(ok, message, file: file, line: line)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    private func claudeLine(_ id: String, cwd: String, user: String) -> [String: Any] {
        ["type": "user", "sessionId": id, "cwd": cwd, "message": ["role": "user", "content": user]]
    }

    private func codexMeta(_ id: String, cwd: String) -> [String: Any] {
        ["type": "session_meta", "payload": ["id": id, "cwd": cwd, "originator": "codex_cli_rs", "instructions": "x"]]
    }

    // MARK: Claude folder decoding

    func testDecodesClaudeFolderNamesAndFallsBackToCWDWhenAmbiguous() throws {
        let root = try scratchDir("fs")
        try mkdir(root.appendingPathComponent("Users/me/solo.proj"))
        try mkdir(root.appendingPathComponent("Users/me/my-app"))
        try mkdir(root.appendingPathComponent("Users/me/my_app"))
        try mkdir(root.appendingPathComponent("Users/me/.hidden/x"))

        XCTAssertEqual(ProjectFinder.decodeClaudeFolderName("-Users-me-solo-proj", fsRoot: root.path),
                       [root.path + "/Users/me/solo.proj"])
        XCTAssertEqual(ProjectFinder.decodeClaudeFolderName("-Users-me--hidden-x", fsRoot: root.path),
                       [root.path + "/Users/me/.hidden/x"], "dots in hidden folders encode to '-'")
        XCTAssertEqual(ProjectFinder.decodeClaudeFolderName("-Users-me-gone", fsRoot: root.path), [], "deleted folder")
        let both = ProjectFinder.decodeClaudeFolderName("-Users-me-my-app", fsRoot: root.path)
        XCTAssertEqual(Set(both), [root.path + "/Users/me/my-app", root.path + "/Users/me/my_app"])

        // Ambiguous: the transcripts' cwd decides.
        let transcript = root.appendingPathComponent("t.jsonl")
        try write([["type": "summary"], claudeLine("s1", cwd: root.path + "/Users/me/my_app", user: "hi")], to: transcript)
        XCTAssertEqual(ProjectFinder.resolveClaudeFolder(name: "-Users-me-my-app", transcripts: [transcript], fsRoot: root.path),
                       root.path + "/Users/me/my_app")
        XCTAssertEqual(ProjectFinder.claudeCWD(in: transcript), root.path + "/Users/me/my_app")
    }

    // MARK: Git scan

    func testGitScanIsShallowAndSkipsIgnoredFolders() throws {
        let root = try scratchDir("git")
        func repo(_ path: String, branch: String? = "main") throws {
            let git = root.appendingPathComponent(path).appendingPathComponent(".git")
            try mkdir(git)
            try (branch.map { "ref: refs/heads/\($0)\n" } ?? "0123abcd\n").write(to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        }
        try repo("alpha")
        try repo("group/beta", branch: "feature/x")
        try repo("group/deep/gamma")            // depth 3: not scanned
        try repo("node_modules/pkg")            // ignored folder
        try repo(".hidden/delta")               // hidden folder
        try repo("alpha/nested")                // inside a found repo: not entered
        let worktree = root.appendingPathComponent("wt")
        try mkdir(worktree)
        try "gitdir: /nowhere\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let found = ProjectFinder.scanGitRepos(roots: [root]).map { $0.lastPathComponent }
        XCTAssertEqual(Set(found), ["alpha", "beta"])
        XCTAssertEqual(ProjectFinder.scanGitRepos(roots: [root], maxDirectories: 1).count, 1, "directory budget bounds the scan")

        let beta = ProjectFinder.gitInfo(root.appendingPathComponent("group/beta"))
        XCTAssertTrue(beta.isRepo)
        XCTAssertEqual(beta.branch, "feature/x")
        XCTAssertNil(ProjectFinder.gitInfo(root.appendingPathComponent("group")).branch)
    }

    // MARK: Project finder

    func testFindsProjectsFromSessionStoresRecentsAndGitAndHonorsHidden() async throws {
        let base = try scratchDir("finder")
        let claudeRoot = base.appendingPathComponent("claude"), codexRoot = base.appendingPathComponent("codex")
        let work = base.appendingPathComponent("work")
        let projA = work.appendingPathComponent("proj-a"), projB = work.appendingPathComponent("proj_b")
        let projC = work.appendingPathComponent("recent"), projD = work.appendingPathComponent("repo")
        for dir in [projA, projB, projC, projD] { try mkdir(dir) }
        try mkdir(projD.appendingPathComponent(".git"))
        try "ref: refs/heads/main\n".write(to: projD.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

        let now = Date()
        let aFolder = claudeRoot.appendingPathComponent(SessionSync.claudeProjectFolderName(projA.path))
        try write([claudeLine("a1", cwd: projA.path, user: "one")], to: aFolder.appendingPathComponent("a1.jsonl"), modified: now.addingTimeInterval(-60))
        try write([claudeLine("a2", cwd: projA.path, user: "two")], to: aFolder.appendingPathComponent("a2.jsonl"), modified: now.addingTimeInterval(-3_600))
        let gone = claudeRoot.appendingPathComponent(SessionSync.claudeProjectFolderName(work.path + "/deleted"))
        try write([claudeLine("g1", cwd: work.path + "/deleted", user: "x")], to: gone.appendingPathComponent("g1.jsonl"))
        try write([codexMeta("c1", cwd: projB.path)], to: codexRoot.appendingPathComponent("2026/10/18/rollout-2026-10-18T10-00-00-c1.jsonl"),
                  modified: now.addingTimeInterval(-10))
        try write([codexMeta("c2", cwd: projA.path)], to: codexRoot.appendingPathComponent("2026/10/18/rollout-2026-10-18T09-00-00-c2.jsonl"),
                  modified: now.addingTimeInterval(-7_200))

        let hidden = LockedBox<Set<String>>([])
        let finder = ProjectFinder(claudeRoot: claudeRoot, codexRoot: codexRoot, recents: { [projC.path] },
                                   searchRoots: { [work.path] }, hidden: { hidden.value }, excludedPrefixes: [])
        let projects = await finder.projects()
        XCTAssertEqual(projects.map(\.name), ["proj_b", "proj-a", "recent", "repo"],
                       "by activity; recents and scan-only after; deleted folder dropped")
        let a = try XCTUnwrap(projects.first { $0.name == "proj-a" })
        XCTAssertEqual(a.harnesses, [.claudeCode, .codex])
        XCTAssertEqual(a.sessionCount, 3)
        XCTAssertEqual(a.sources, [.claudeSessions, .codexSessions])
        XCTAssertFalse(a.isGitRepo)
        let repo = try XCTUnwrap(projects.first { $0.name == "repo" })
        XCTAssertTrue(repo.isGitRepo)
        XCTAssertEqual(repo.branch, "main")
        XCTAssertEqual(repo.sources, [.gitScan])

        hidden.value = [projB.path]
        let afterHide = await finder.projects()
        XCTAssertFalse(afterHide.contains { $0.path == projB.path }, "hidden without a rescan")
        XCTAssertEqual(afterHide.count, 3)

        // Default exclusions drop scratch folders (everything here is under the temp dir).
        let strict = ProjectFinder(claudeRoot: claudeRoot, codexRoot: codexRoot, recents: { [] }, searchRoots: { [] }, hidden: { [] })
        let none = await strict.projects()
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: Session listing

    func testAllSessionsAcrossProjectsWithCWDModelAndLiveLocation() async throws {
        let base = try scratchDir("all")
        let claudeRoot = base.appendingPathComponent("claude"), codexRoot = base.appendingPathComponent("codex")
        let p1 = base.appendingPathComponent("p1"), p2 = base.appendingPathComponent("p2")
        try mkdir(p1); try mkdir(p2)
        let now = Date()
        var assistant: [String: Any] = ["type": "assistant", "sessionId": "cl-1", "cwd": p1.path,
                                        "message": ["role": "assistant", "model": "claude-haiku-9", "content": [["type": "text", "text": "ok"]]]]
        assistant["uuid"] = "u2"
        try write([claudeLine("cl-1", cwd: p1.path, user: "Fix the build please"), assistant],
                  to: claudeRoot.appendingPathComponent(SessionSync.claudeProjectFolderName(p1.path) + "/cl-1.jsonl"),
                  modified: now.addingTimeInterval(-600))
        try write([codexMeta("cx-1", cwd: p2.path),
                   ["type": "turn_context", "payload": ["model": "gpt-test", "cwd": p2.path]],
                   ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "List files"]]]]],
                  to: codexRoot.appendingPathComponent("2026/10/18/rollout-2026-10-18T10-00-00-cx-1.jsonl"),
                  modified: now.addingTimeInterval(-5))

        let sync = SessionSync(claudeRoot: claudeRoot, codexRoot: codexRoot,
                               processes: { [AgentProcess(pid: 4242, harness: .codex, cwd: p2.path)] },
                               resumeStore: AgentCLIResumeStore(defaults: scratchDefaults()))
        let all = await sync.allSessions(limit: 10)
        XCTAssertEqual(all.map(\.id), ["cx-1", "cl-1"])
        let codex = all[0], claude = all[1]
        XCTAssertEqual(codex.projectDir.path, p2.path)
        XCTAssertEqual(codex.model, "gpt-test")
        XCTAssertEqual(codex.liveLocation, .externalTerminal(pid: 4242))
        XCTAssertTrue(codex.isLive)
        XCTAssertEqual(claude.projectDir.path, p1.path)
        XCTAssertEqual(claude.title, "Fix the build please")
        XCTAssertEqual(claude.model, "claude-haiku-9")
        XCTAssertNil(claude.liveLocation)

        AxolotlActiveSessions.shared.register("cl-1")
        defer { AxolotlActiveSessions.shared.unregister("cl-1") }
        let again = await sync.sessions(projectDir: p1)
        XCTAssertEqual(again.first?.liveLocation, .axolotl)
        XCTAssertEqual(again.first?.isLive, false, "isLive stays 'outside Axolotl'")
        let file = await sync.sessionFile(harness: .codex, id: "cx-1", projectDir: p2)
        XCTAssertEqual(file?.lastPathComponent, "rollout-2026-10-18T10-00-00-cx-1.jsonl")
    }

    // MARK: Terminal command lines

    private func attachment() -> DevMCPAttachment {
        DevMCPAttachment(url: "http://127.0.0.1:7/mcp", token: "SECRET-TOKEN-123", revoke: {})
    }

    func testTerminalCommandLinesPerModeAndHarness() throws {
        let dir = URL(fileURLWithPath: "/work/app", isDirectory: true)
        let mcp = attachment()
        let config = try mcp.writeClaudeConfig()
        defer { DevMCPAttachment.removeClaudeConfig(config) }
        let exe: (AgentCLIKind) -> String = { $0.executableName }
        let setup = DevSessionSetup(harness: .claudeCode, model: "haiku", effort: "low", approvalBehavior: .allowEdits)

        let shell = DevTerminalCommand.launch(for: .shell(nil), approval: .ask, shell: "/bin/zsh", executable: exe, mcp: nil, claudeMCPConfig: nil)
        XCTAssertEqual(shell.executable, "/bin/zsh")
        XCTAssertEqual(shell.arguments, ["-l"])
        XCTAssertEqual(shell.workingDirectory, FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(DevTerminalCommand.launch(for: .shell(dir), approval: .ask, shell: "/bin/zsh", executable: exe, mcp: nil,
                                                 claudeMCPConfig: nil).workingDirectory, dir)

        let claudeNew = DevTerminalCommand.launch(for: .newSession(.claudeCode, setup, projectDir: dir), approval: .ask, shell: "/bin/zsh",
                                                  executable: exe, mcp: mcp, claudeMCPConfig: config, newSessionID: "uuid-1")
        XCTAssertEqual(claudeNew.executable, "claude")
        XCTAssertEqual(claudeNew.arguments, ["--session-id", "uuid-1", "--model", "haiku", "--permission-mode", "acceptEdits",
                                             "--effort", "low", "--mcp-config", config.path])
        XCTAssertEqual(claudeNew.sessionID, "uuid-1")
        XCTAssertEqual(claudeNew.workingDirectory, dir)
        XCTAssertTrue(claudeNew.environment.isEmpty)

        let ref = DevSessionRef(harness: .claudeCode, id: "sess-9", projectDir: dir)
        let claudeResume = DevTerminalCommand.launch(for: .resume(ref), approval: .fullAuto, shell: "/bin/zsh", executable: exe,
                                                     mcp: mcp, claudeMCPConfig: config)
        XCTAssertEqual(claudeResume.arguments, ["--resume", "sess-9", "--permission-mode", "bypassPermissions", "--mcp-config", config.path])
        XCTAssertEqual(claudeResume.sessionID, "sess-9")

        var codexSetup = setup
        codexSetup.harness = .codex
        codexSetup.model = "gpt-5.5"
        codexSetup.effort = "high"
        codexSetup.approvalBehavior = .ask
        let codexNew = DevTerminalCommand.launch(for: .newSession(.codex, codexSetup, projectDir: dir), approval: .ask, shell: "/bin/zsh",
                                                 executable: exe, mcp: mcp, claudeMCPConfig: nil)
        XCTAssertEqual(codexNew.executable, "codex")
        XCTAssertEqual(codexNew.arguments, ["-m", "gpt-5.5", "-a", "on-request", "-s", "read-only", "-c", "model_reasoning_effort=\"high\"",
                                            "-c", "mcp_servers.axolotl.url=\"http://127.0.0.1:7/mcp\"",
                                            "-c", "mcp_servers.axolotl.bearer_token_env_var=\"\(AxolotlMCPBridge.tokenEnvVar)\""])
        XCTAssertEqual(codexNew.environment, [AxolotlMCPBridge.tokenEnvVar: "SECRET-TOKEN-123"])
        XCTAssertNil(codexNew.sessionID, "found on disk after launch")

        let codexResume = DevTerminalCommand.launch(for: .resume(DevSessionRef(harness: .codex, id: "th-1", projectDir: dir)),
                                                    approval: .fullAuto, shell: "/bin/zsh", executable: exe, mcp: mcp, claudeMCPConfig: nil)
        XCTAssertEqual(codexResume.arguments, ["resume", "-a", "never", "-s", "danger-full-access",
                                               "-c", "mcp_servers.axolotl.url=\"http://127.0.0.1:7/mcp\"",
                                               "-c", "mcp_servers.axolotl.bearer_token_env_var=\"\(AxolotlMCPBridge.tokenEnvVar)\"", "th-1"])

        for launch in [claudeNew, claudeResume, codexNew, codexResume] {
            XCTAssertFalse(launch.arguments.joined(separator: " ").contains("SECRET-TOKEN-123"), "token never in argv")
        }
        // The Claude token lives only in the 0600 config file.
        let perms = try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertTrue(try String(contentsOf: config, encoding: .utf8).contains("SECRET-TOKEN-123"))

        let without = DevTerminalCommand.launch(for: .newSession(.claudeCode, DevSessionSetup(), projectDir: dir), approval: .ask,
                                                shell: "/bin/zsh", executable: exe, mcp: nil, claudeMCPConfig: nil, newSessionID: "u")
        XCTAssertEqual(without.arguments, ["--session-id", "u", "--permission-mode", "manual"])
    }

    func testSendKeystrokesUseBracketedPasteForMultiline() {
        XCTAssertEqual(DevTerminalCommand.keystrokes(for: "run tests").body, "run tests")
        XCTAssertEqual(DevTerminalCommand.keystrokes(for: "run tests").submit, "\r")
        XCTAssertEqual(DevTerminalCommand.keystrokes(for: "a\r\nb").body, "\u{1b}[200~a\nb\u{1b}[201~")
        // Chat text is data: no escape, CR or ^C reaches the PTY, so it cannot end the paste early or press keys.
        XCTAssertEqual(DevTerminalCommand.keystrokes(for: "x\u{1b}[201~!rm -rf\r\u{3}y").body, "x[201~!rm -rfy")
        XCTAssertEqual(DevTerminalCommand.keystrokes(for: "a\u{1b}[201~\nb").body, "\u{1b}[200~a[201~\nb\u{1b}[201~")
        XCTAssertEqual(DevTerminalCommand.keystrokes(for: "tab\there\u{7f}").body, "tab\there")
    }

    func testApprovalPromptDetectionOnScreenText() {
        let screen = Data("\u{1b}[2K\u{1b}[1mBash command\u{1b}[0m\r\n  rm -rf build\r\n Do you want\u{1b}[1Cto proceed?\r\n ❯ 1. Yes".utf8)
        let text = DevTerminalScreen.plainText(screen)
        XCTAssertFalse(text.contains("\u{1b}"))
        XCTAssertTrue(DevTerminalScreen.showsApprovalPrompt(text), "cursor-forward counts as a space")
        let clean = Data("\u{1b}[1mDo you want to proceed?\u{1b}[0m\r\n".utf8)
        XCTAssertTrue(DevTerminalScreen.showsApprovalPrompt(DevTerminalScreen.plainText(clean)))
        XCTAssertFalse(DevTerminalScreen.showsApprovalPrompt("Thinking… esc to interrupt"))
    }

    // MARK: New session capture

    func testCapturesNewSessionIDFromFakeStores() async throws {
        let base = try scratchDir("store")
        let watcher = SessionStoreWatcher(claudeRoot: base.appendingPathComponent("claude"), codexRoot: base.appendingPathComponent("codex"))
        let project = base.appendingPathComponent("proj")
        try mkdir(project)
        let since = Date()

        // Claude: the preset --session-id file appears after the first prompt.
        XCTAssertNil(watcher.find(harness: .claudeCode, cwd: project, since: since, expectedID: "abc"))
        let claudeFile = base.appendingPathComponent("claude/\(SessionSync.claudeProjectFolderName(project.path))/abc.jsonl")
        Task.detached {
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? FileManager.default.createDirectory(at: claudeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: claudeFile.path, contents: Data("{}\n".utf8))
        }
        let claude = await watcher.wait(harness: .claudeCode, cwd: project, since: since, expectedID: "abc", interval: 0.05, timeout: 5)
        XCTAssertEqual(claude?.id, "abc")

        // Codex: a new rollout in today's folder whose cwd matches; others ignored.
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = base.appendingPathComponent(String(format: "codex/%04d/%02d/%02d", c.year!, c.month!, c.day!))
        let old = day.appendingPathComponent("rollout-old-th-old.jsonl")
        try write([codexMeta("th-old", cwd: project.path)], to: old)
        try FileManager.default.setAttributes([.creationDate: since.addingTimeInterval(-600)], ofItemAtPath: old.path)
        try write([codexMeta("th-other", cwd: "/elsewhere")], to: day.appendingPathComponent("rollout-x-th-other.jsonl"))
        XCTAssertNil(watcher.find(harness: .codex, cwd: project, since: since, expectedID: nil), "older + other cwd ignored")
        try write([codexMeta("th-new", cwd: project.path)], to: day.appendingPathComponent("rollout-y-th-new.jsonl"))
        XCTAssertEqual(watcher.find(harness: .codex, cwd: project, since: since, expectedID: nil)?.id, "th-new")
    }

    // MARK: Routing

    func testRoutingRule() {
        XCTAssertEqual(DevSession.route(terminalRunning: true, externalLive: false), .terminal)
        XCTAssertEqual(DevSession.route(terminalRunning: true, externalLive: true), .terminal)
        XCTAssertEqual(DevSession.route(terminalRunning: false, externalLive: false), .headless)
        guard case .refused = DevSession.route(terminalRunning: false, externalLive: true) else { return XCTFail("external must refuse") }
    }

    private final class FakeHeadless: AgentCLISession {
        let kind: AgentCLIKind
        let events: AsyncStream<CLIEvent>
        private let continuation: AsyncStream<CLIEvent>.Continuation
        var sessionID: String?
        var isRunning = false
        var sent: [String] = []
        var resumedID: String?
        var closed = false

        init(kind: AgentCLIKind) {
            self.kind = kind
            (events, continuation) = AsyncStream.makeStream(of: CLIEvent.self)
        }

        func start(projectDir: URL, model: String?, resumeID: String?) async throws {
            resumedID = resumeID
            isRunning = true
            sessionID = resumeID ?? "fresh-id"
            continuation.yield(.sessionStarted(id: sessionID!))
        }

        func send(_ text: String) throws {
            sent.append(text)
            continuation.yield(.messageDone("echo: \(text)"))
            continuation.yield(.turnDone(usage: nil, outcome: .completed))
        }

        func interrupt() {}
        func respond(approvalID: String, decision: CLIApprovalDecision) {}
        func close() { closed = true; isRunning = false; continuation.finish() }
    }

    private struct Harness {
        var deps: DevSession.Dependencies
        var headless: () -> FakeHeadless?
        var location: LockedBox<SessionLocation?>
        var terminalOutput: LockedBox<String>
    }

    /// Dependencies with a fake headless adapter, a terminal that runs a fake CLI (`cat`, so
    /// typed text echoes back), and a controllable liveness answer.
    private func harness(store: URL) throws -> Harness {
        let bin = try scratchDir("bin")
        let fake = bin.appendingPathComponent("fakecli")
        try "#!/bin/sh\nprintf 'fake> '\nexec /bin/cat\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var made: FakeHeadless?
        let location = LockedBox<SessionLocation?>(nil)
        let output = LockedBox("")
        var deps = DevSession.Dependencies()
        deps.makeHeadless = { kind, _ in let f = FakeHeadless(kind: kind); made = f; return f }
        deps.makeTerminal = {
            let t = DevTerminalController(watcher: SessionStoreWatcher(claudeRoot: store, codexRoot: store),
                                          approval: { .ask }, mcpProvider: { _ in nil }, executable: { _ in fake.path })
            t.outputObserver = { output.value += String(decoding: $0, as: UTF8.self) }
            return t
        }
        deps.liveLocation = { _ in location.value }
        deps.locateFile = { _ in nil }
        deps.resumeStore = AgentCLIResumeStore(defaults: scratchDefaults())
        deps.livenessInterval = 0.05
        return Harness(deps: deps, headless: { made }, location: location, terminalOutput: output)
    }

    private func existing(_ id: String, project: URL, file: URL, live: SessionLocation?) -> ExternalSession {
        ExternalSession(harness: .claudeCode, id: id, file: file, projectDir: project, title: "t", firstPrompt: "t", updatedAt: Date(),
                        isLive: live != nil, messageCount: 2, startedInAxolotl: false, liveLocation: live)
    }

    func testChatSendRoutesToTerminalWhenItRunsElseHeadless() async throws {
        let base = try scratchDir("route")
        let transcript = base.appendingPathComponent("s.jsonl")
        try write([claudeLine("sess-1", cwd: base.path, user: "earlier prompt"),
                   ["type": "assistant", "sessionId": "sess-1", "message": ["role": "assistant", "content": [["type": "text", "text": "earlier answer"]]]]],
                  to: transcript)
        let h = try harness(store: base.appendingPathComponent("store"))
        let session = DevSession(existing: existing("sess-1", project: base, file: transcript, live: nil), setup: DevSessionSetup(), dependencies: h.deps)
        await eventually({ session.timeline.items.count == 2 }, "history from the transcript")
        XCTAssertEqual(session.state, .idle)
        XCTAssertTrue(session.canOpenTerminal)

        // No terminal: headless, resuming the same id.
        XCTAssertEqual(session.send("hello headless"), .headless)
        await eventually({ h.headless()?.sent == ["hello headless"] })
        XCTAssertEqual(h.headless()?.resumedID, "sess-1")
        await eventually({ session.timeline.items.contains(.assistant(text: "echo: hello headless", streaming: false)) })
        XCTAssertTrue(AxolotlActiveSessions.shared.contains("sess-1"))

        // Terminal opens with .resume, closes the headless writer, and takes the sends.
        let terminal = try XCTUnwrap(session.openTerminal())
        XCTAssertEqual(h.headless()?.closed, true, "one writer")
        XCTAssertEqual(terminal.currentMode, .resume(DevSessionRef(harness: .claudeCode, id: "sess-1", projectDir: base)))
        XCTAssertEqual(terminal.sessionID, nil, "set at launch")
        await eventually({ terminal.sessionID == "sess-1" })
        XCTAssertEqual(session.state, .running(.axolotlTerminal))
        XCTAssertEqual(session.send("typed into the cli"), .terminal)
        await eventually({ h.terminalOutput.value.contains("typed into the cli") }, "echoed by the PTY")
        XCTAssertEqual(h.headless()?.sent, ["hello headless"], "headless got nothing")
        XCTAssertIdentical(session.openTerminal(), terminal, "reopening never restarts")

        session.closeTerminal()
        XCTAssertEqual(session.state, .idle)
        XCTAssertFalse(AxolotlActiveSessions.shared.contains("sess-1"))
        session.close()
    }

    func testExternalSessionIsReadOnlyUntilItsProcessExits() async throws {
        let base = try scratchDir("ext")
        let transcript = base.appendingPathComponent("e.jsonl")
        try write([claudeLine("ext-1", cwd: base.path, user: "from iTerm")], to: transcript)
        let h = try harness(store: base.appendingPathComponent("store"))
        h.location.value = .externalTerminal(pid: 777)
        let session = DevSession(existing: existing("ext-1", project: base, file: transcript, live: .externalTerminal(pid: 777)),
                                 setup: DevSessionSetup(), dependencies: h.deps)
        XCTAssertEqual(session.state, .running(.external(pid: 777)))
        XCTAssertFalse(session.canSend)
        XCTAssertFalse(session.canOpenTerminal)
        guard case .refused = session.send("no") else { return XCTFail("must refuse while live elsewhere") }
        XCTAssertNil(h.headless(), "Axolotl never wrote")
        XCTAssertNil(session.openTerminal())

        h.location.value = nil // the outside CLI exits
        await eventually({ session.state == .idle }, "auto-switches to resumable")
        XCTAssertTrue(session.canOpenTerminal)
        XCTAssertEqual(session.send("now mine"), .headless)
        await eventually({ h.headless()?.sent == ["now mine"] })
        XCTAssertEqual(h.headless()?.resumedID, "ext-1")
        session.close()
    }

    func testTakeOverAllowsWritingWhileExternalStillLive() async throws {
        let base = try scratchDir("take")
        let transcript = base.appendingPathComponent("t.jsonl")
        try write([claudeLine("ext-2", cwd: base.path, user: "x")], to: transcript)
        let h = try harness(store: base.appendingPathComponent("store"))
        h.location.value = .externalTerminal(pid: nil)
        let session = DevSession(existing: existing("ext-2", project: base, file: transcript, live: .externalTerminal(pid: nil)),
                                 setup: DevSessionSetup(), dependencies: h.deps)
        session.takeOver()
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.send("taking over"), .headless)
        session.close()
    }

    // MARK: Settings

    func testDevHomeSettingsPersist() {
        let defaults = scratchDefaults()
        let settings = DevSettings(defaults: defaults)
        XCTAssertFalse(settings.skipHome)
        XCTAssertEqual(settings.accent, .axolotl)
        XCTAssertEqual(settings.density, .comfortable)
        XCTAssertEqual(settings.fontScale, .medium)
        XCTAssertTrue(settings.showToolDetails)
        XCTAssertEqual(settings.timelineStyle, .bubbles)
        XCTAssertEqual(settings.projectSearchRoots, [], "no scan roots until the user adds some")

        settings.skipHome = true
        settings.defaultSetup = DevSessionSetup(harness: .codex, model: "gpt-x", effort: "high", approvalBehavior: .fullAuto,
                                                project: .specific("/work/app"))
        settings.hideProject("/work/secret")
        settings.projectSearchRoots = ["/work"]
        settings.accent = .violet
        settings.density = .compact
        settings.fontScale = .large
        settings.showToolDetails = false
        settings.timelineStyle = .plain

        let reloaded = DevSettings(defaults: defaults)
        XCTAssertTrue(reloaded.skipHome)
        XCTAssertEqual(reloaded.defaultSetup, settings.defaultSetup)
        XCTAssertEqual(reloaded.defaultSetup.projectPath(defaults), "/work/app")
        XCTAssertTrue(reloaded.isHidden("/work/secret"))
        XCTAssertEqual(DevSettings.storedHiddenProjects(defaults), ["/work/secret"])
        XCTAssertEqual(DevSettings.storedProjectSearchRoots(defaults), ["/work"])
        XCTAssertEqual(reloaded.accent, .violet)
        XCTAssertEqual(reloaded.density, .compact)
        XCTAssertEqual(reloaded.fontScale, .large)
        XCTAssertFalse(reloaded.showToolDetails)
        XCTAssertEqual(reloaded.timelineStyle, .plain)
        reloaded.unhideProject("/work/secret")
        XCTAssertTrue(DevSettings(defaults: defaults).hiddenProjects.isEmpty)
    }
}

/// A value shared with @Sendable closures in tests.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@MainActor
final class DevEventCoalescerTests: XCTestCase {
    func testBurstIsDeliveredAsOneBatchInOrder() async throws {
        var batches: [[CLIEvent]] = []
        let c = DevEventCoalescer(window: .milliseconds(20)) { batches.append($0) }
        for i in 0..<600 { c.add(.textDelta("\(i)")) }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches.first?.count, 600)
    }

    func testCancelDropsBufferedEventsInsteadOfDeliveringThem() async throws {
        var batches: [[CLIEvent]] = []
        let c = DevEventCoalescer(window: .milliseconds(20)) { batches.append($0) }
        c.add(.textDelta("stale"))
        c.cancel()
        c.flush()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(batches.isEmpty, "a cancelled follow must not duplicate its tail into a re-followed timeline")
    }

    func testFlushDeliversPendingImmediately() {
        var batches: [[CLIEvent]] = []
        let c = DevEventCoalescer(window: .seconds(10)) { batches.append($0) }
        c.add(.textDelta("a"))
        c.flush()
        XCTAssertEqual(batches.count, 1)
    }
}

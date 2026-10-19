import XCTest
@testable import Luna

/// Dev mode discovery and sync: harness discovery on a fake PATH, model-list parsing from
/// captured response shapes, transcript parsing / tailing from synthetic transcripts, live
/// detection, settings persistence, and the clean CLI environment.
@MainActor
final class DevSyncTests: XCTestCase {

    // MARK: Helpers

    private func scratchDefaults() -> UserDefaults {
        let name = "DevSyncTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func scratchDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luna-devsync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func script(_ dir: URL, _ name: String, _ body: String, executable: Bool = true) throws {
        let url = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
    }

    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Harness discovery

    func testDiscoversHarnessesOnFakePATH() async throws {
        let bin = try scratchDir()
        try script(bin, "claude", """
        case "$1" in --version) echo "2.1.300 (Claude Code)";; auth) echo '{"loggedIn": true, "authMethod": "x"}';; esac
        """)
        try script(bin, "codex", """
        case "$1" in --version) echo "codex-cli 0.160.0";; login) echo "Not logged in"; exit 1;; esac
        """)
        try script(bin, "opencode", "echo 1.18.0")
        try script(bin, "gemini", "echo 0.1", executable: false) // not executable: not installed
        let other = try scratchDir()
        try script(other, "my-pi", "echo 'pi 1.3.0'")

        let catalog = HarnessCatalog(path: { bin.path }, environment: { [:] },
                                     overrides: { [.pi: other.appendingPathComponent("my-pi").path] })
        let found = await catalog.discover()
        XCTAssertEqual(found.map(\.id), [.claudeCode, .codex, .opencode, .pi])

        let claude = try XCTUnwrap(found.first { $0.id == .claudeCode })
        XCTAssertEqual(claude.version, "2.1.300")
        XCTAssertEqual(claude.signedIn, true)
        XCTAssertTrue(claude.supported)
        XCTAssertEqual(claude.executable, bin.appendingPathComponent("claude").path)

        let codex = try XCTUnwrap(found.first { $0.id == .codex })
        XCTAssertEqual(codex.version, "0.160.0")
        XCTAssertEqual(codex.signedIn, false)

        let opencode = try XCTUnwrap(found.first { $0.id == .opencode })
        XCTAssertFalse(opencode.supported, "installed but unsupported")
        XCTAssertNil(opencode.signedIn)

        let pi = try XCTUnwrap(found.first { $0.id == .pi })
        XCTAssertTrue(pi.isOverride)
        XCTAssertEqual(pi.version, "1.3.0")

        // Cached until refresh.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("opencode"))
        let cachedCount = await catalog.discover().count
        XCTAssertEqual(cachedCount, 4)
        let refreshed = await catalog.discover(refresh: true)
        XCTAssertFalse(refreshed.contains { $0.id == .opencode })
    }

    func testVersionAndAuthParsing() {
        XCTAssertEqual(HarnessCatalog.parseVersion("2.1.302 (Claude Code)\n"), "2.1.302")
        XCTAssertEqual(HarnessCatalog.parseVersion("codex-cli 0.163.0"), "0.163.0")
        XCTAssertEqual(HarnessCatalog.parseVersion("nightly"), "nightly")
        XCTAssertNil(HarnessCatalog.parseVersion(""))
        XCTAssertEqual(HarnessCatalog.parseClaudeAuthStatus(#"{"loggedIn":false}"#), false)
        XCTAssertNil(HarnessCatalog.parseClaudeAuthStatus("not json"))
        XCTAssertEqual(HarnessCatalog.parseCodexLoginStatus(status: 0, output: "Logged in using ChatGPT"), true)
        // Codex writes the status line to stderr, so captured stdout is empty when signed in.
        XCTAssertEqual(HarnessCatalog.parseCodexLoginStatus(status: 0, output: ""), true)
        XCTAssertEqual(HarnessCatalog.parseCodexLoginStatus(status: 1, output: "Not logged in"), false)
    }

    // MARK: Model discovery

    /// Shape of codex-cli 0.163.0 `model/list` (ids and texts made up).
    static let codexModelList = """
    {"data":[
      {"id":"gpt-x-sol","model":"gpt-x-sol","displayName":"GPT-X-Sol","description":"Frontier","hidden":false,"isDefault":true,
       "defaultReasoningEffort":"low","supportedReasoningEfforts":[{"reasoningEffort":"low","description":"a"},{"reasoningEffort":"high","description":"b"}]},
      {"id":"gpt-x-mini","model":"gpt-x-mini","displayName":"GPT-X-Mini","description":"Small","hidden":false,"isDefault":false,
       "defaultReasoningEffort":"medium","supportedReasoningEfforts":[]},
      {"id":"internal","model":"internal","displayName":"Hidden","description":"","hidden":true,"isDefault":false,
       "defaultReasoningEffort":"low","supportedReasoningEfforts":[]}
    ],"nextCursor":"page2"}
    """

    /// Shape of Claude Code 2.1.302's `initialize` control response `response.response` (trimmed).
    static let claudeInitialize = """
    {"commands":[],"models":[
      {"value":"default","resolvedModel":"claude-model-a","displayName":"Default (recommended)","description":"Model A","supportsEffort":true,"supportedEffortLevels":["low","high","max"]},
      {"value":"opus","resolvedModel":"claude-model-b","displayName":"Opus","description":"Model B","supportsEffort":true,"supportedEffortLevels":["low","max"]},
      {"value":"claude-old-1","resolvedModel":"claude-old-1","displayName":"Old","description":"Older","supportsThinkingOff":true}
    ],"account":{"apiProvider":"firstParty"}}
    """

    func testParsesCodexModelList() {
        let page = HarnessModelCatalog.parseCodexModelList(json(Self.codexModelList))
        XCTAssertEqual(page.models.map(\.id), ["gpt-x-sol", "gpt-x-mini"], "hidden models dropped")
        XCTAssertEqual(page.nextCursor, "page2")
        XCTAssertTrue(page.models[0].isDefault)
        XCTAssertEqual(page.models[0].efforts, ["low", "high"])
        XCTAssertEqual(page.models[0].defaultEffort, "low")
        XCTAssertNil(page.models[1].efforts)
    }

    func testParsesClaudeInitializeModels() {
        let models = HarnessModelCatalog.parseClaudeInitialize(json(Self.claudeInitialize))
        XCTAssertEqual(models.map(\.id), ["default", "opus", "claude-old-1"])
        XCTAssertEqual(models.filter(\.isDefault).map(\.id), ["default"])
        XCTAssertEqual(models[1].resolvedModel, "claude-model-b")
        XCTAssertEqual(models[1].efforts, ["low", "max"])
        XCTAssertNil(models[2].efforts)
    }

    func testModelCatalogFallsBackToLastKnownList() async throws {
        let defaults = scratchDefaults()
        final class Flag: @unchecked Sendable { var fail = false }
        let flag = Flag()
        let catalog = HarnessModelCatalog(defaults: defaults, executable: { _ in "/bin/true" }, probe: { _, _ in
            if flag.fail { throw ModelCatalogError.discoveryFailed("offline") }
            return [HarnessModel(id: "m1", displayName: "M1", isDefault: true)]
        })
        let live = try await catalog.listing(for: .codex)
        XCTAssertEqual(live.source, .live)
        flag.fail = true
        let fallback = try await catalog.listing(for: .codex, refresh: true)
        XCTAssertEqual(fallback.models.map(\.id), ["m1"])
        guard case .lastKnown = fallback.source else { return XCTFail("labelled as last known") }
        // Never discovered → the error surfaces.
        do { _ = try await catalog.listing(for: .claudeCode, refresh: true); XCTFail("should throw") } catch {}
        do { _ = try await catalog.listing(for: .opencode); XCTFail("unsupported") } catch {
            XCTAssertEqual(error as? ModelCatalogError, .unsupported(.opencode))
        }
    }

    // MARK: Session files (synthetic transcripts)

    private func line(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func claudeTranscript(session: String, cwd: String) -> [String] {
        let base: [String: Any] = ["sessionId": session, "cwd": cwd, "isSidechain": false, "entrypoint": "cli"]
        func entry(_ extra: [String: Any]) -> String { line(base.merging(extra) { $1 }) }
        return [
            entry(["type": "user", "isMeta": true, "message": ["role": "user", "content": "<local-command-caveat>meta</local-command-caveat>"]]),
            entry(["type": "user", "message": ["role": "user", "content": "Add a   greeting\nfunction to hello.py please"]]),
            entry(["type": "assistant", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hmm"]]]]),
            entry(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Sure."]]]]),
            entry(["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": "Write", "input": ["file_path": "hello.py", "content": "x"]]]]]),
            entry(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "File created"]]]]),
            entry(["type": "assistant", "isSidechain": true, "message": ["role": "assistant", "content": [["type": "text", "text": "subagent"]]]]),
            entry(["type": "user", "message": ["role": "user", "content": "<command-name>/clear</command-name>"]]),
            line(["type": "ai-title", "aiTitle": "Greeting function", "sessionId": session]),
            entry(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Done."]]]]),
        ]
    }

    private func codexRollout(thread: String, cwd: String, originator: String = "codex-tui") -> [String] {
        [
            line(["type": "session_meta", "payload": ["id": thread, "cwd": cwd, "originator": originator, "base_instructions": "long"]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "rules"]]]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "<environment_context>x</environment_context>"]]]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "List the files"]]]]),
            line(["type": "response_item", "payload": ["type": "reasoning", "summary": []]]),
            line(["type": "response_item", "payload": ["type": "function_call", "call_id": "c1", "name": "exec_command", "arguments": #"{"cmd":["ls","-la"]}"#]]),
            line(["type": "response_item", "payload": ["type": "function_call_output", "call_id": "c1", "output": "a.txt"]]),
            line(["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "One file."]]]]),
        ]
    }

    private struct Fixture {
        let claudeRoot: URL
        let codexRoot: URL
        let project: URL
        let claudeFile: URL
        let codexFile: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = try scratchDir()
        let project = root.appendingPathComponent("my.project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let path = project.standardizedFileURL.resolvingSymlinksInPath().path
        let claudeRoot = root.appendingPathComponent("claude-projects", isDirectory: true)
        let claudeDir = claudeRoot.appendingPathComponent(SessionSync.claudeProjectFolderName(path), isDirectory: true)
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let claudeFile = claudeDir.appendingPathComponent("11111111-aaaa.jsonl")
        try claudeTranscript(session: "11111111-aaaa", cwd: path).joined(separator: "\n").appending("\n").write(to: claudeFile, atomically: true, encoding: .utf8)
        // Another project's session must not show up.
        let otherDir = claudeRoot.appendingPathComponent(SessionSync.claudeProjectFolderName("/elsewhere"), isDirectory: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try claudeTranscript(session: "other", cwd: "/elsewhere").joined(separator: "\n").write(to: otherDir.appendingPathComponent("other.jsonl"), atomically: true, encoding: .utf8)

        let codexRoot = root.appendingPathComponent("codex-sessions", isDirectory: true)
        let day = codexRoot.appendingPathComponent("2026/10/18", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let codexFile = day.appendingPathComponent("rollout-2026-10-18T01-00-00-thread-1.jsonl")
        try codexRollout(thread: "thread-1", cwd: path).joined(separator: "\n").appending("\n").write(to: codexFile, atomically: true, encoding: .utf8)
        try codexRollout(thread: "thread-2", cwd: "/elsewhere").joined(separator: "\n")
            .write(to: day.appendingPathComponent("rollout-2026-10-18T02-00-00-thread-2.jsonl"), atomically: true, encoding: .utf8)
        // Codex older; Claude newer.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: codexFile.path)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: claudeFile.path)
        return Fixture(claudeRoot: claudeRoot, codexRoot: codexRoot, project: project, claudeFile: claudeFile, codexFile: codexFile)
    }

    func testClaudeFolderEncoding() {
        XCTAssertEqual(SessionSync.claudeProjectFolderName("/Users/me/my.app_v2"), "-Users-me-my-app-v2")
    }

    func testPathVariantsKeepThePrivatePrefixTheCLIsRecord() {
        // Foundation drops "/private" when standardizing; Claude Code names the folder after the real path.
        let variants = SessionSync.pathVariants(URL(fileURLWithPath: "/private/tmp/luna-proj", isDirectory: true))
        XCTAssertTrue(variants.contains("/private/tmp/luna-proj"))
        XCTAssertTrue(SessionSync.samePath("/tmp/luna-proj", URL(fileURLWithPath: "/private/tmp/luna-proj")))
    }

    func testListsSessionsForProject() async throws {
        let f = try makeFixture()
        let store = AgentCLIResumeStore(defaults: scratchDefaults())
        store.save("thread-1", kind: .codex, projectDir: f.project)
        let sync = SessionSync(claudeRoot: f.claudeRoot, codexRoot: f.codexRoot, processes: { [] }, resumeStore: store)
        let sessions = await sync.sessions(projectDir: f.project)
        XCTAssertEqual(sessions.map(\.id), ["11111111-aaaa", "thread-1"], "newest first, other projects excluded")

        let claude = sessions[0]
        XCTAssertEqual(claude.harness, .claudeCode)
        XCTAssertEqual(claude.title, "Greeting function", "AI title preferred")
        XCTAssertEqual(claude.firstPrompt, "Add a greeting function to hello.py please")
        XCTAssertEqual(claude.messageCount, 3, "1 prompt + 2 texts; meta, wrappers and sidechains skipped")
        XCTAssertFalse(claude.startedInLuna)
        XCTAssertFalse(claude.isLive, "written 10 min ago, no process")

        let codex = sessions[1]
        XCTAssertEqual(codex.title, "List the files")
        XCTAssertEqual(codex.messageCount, 2)
        XCTAssertTrue(codex.startedInLuna, "recorded by the resume store")

        let resumable = await sync.mostRecentResumable(projectDir: f.project)
        XCTAssertEqual(resumable?.id, "11111111-aaaa")
        let excluding = await sync.mostRecentResumable(projectDir: f.project, excluding: ["11111111-aaaa"])
        XCTAssertEqual(excluding?.id, "thread-1")

        // A claude running in the project (outside Luna) makes its newest session live.
        let live = SessionSync(claudeRoot: f.claudeRoot, codexRoot: f.codexRoot,
                               processes: { [AgentProcess(pid: 1, harness: .claudeCode, cwd: f.project.path)] }, resumeStore: store)
        let liveSessions = await live.sessions(projectDir: f.project)
        XCTAssertEqual(liveSessions.first { $0.harness == .claudeCode }?.isLive, true)
        XCTAssertEqual(liveSessions.first { $0.harness == .codex }?.isLive, false)
    }

    func testFollowReplaysHistoryThenTails() async throws {
        let f = try makeFixture()
        let sync = SessionSync(claudeRoot: f.claudeRoot, codexRoot: f.codexRoot, processes: { [] },
                               resumeStore: AgentCLIResumeStore(defaults: scratchDefaults()))
        let all = await sync.sessions(projectDir: f.project)
        let session = try XCTUnwrap(all.first { $0.harness == .claudeCode })
        var iterator = sync.follow(session, interval: 0.05).makeAsyncIterator()
        var events: [CLIEvent] = []
        for _ in 0..<7 { if let e = await iterator.next() { events.append(e) } }
        XCTAssertEqual(events, [
            .sessionStarted(id: "11111111-aaaa"),
            .userMessage("Add a   greeting\nfunction to hello.py please"),
            .messageDone("Sure."),
            .toolStarted(id: "t1", name: "Write", summary: "hello.py"),
            .toolOutput(id: "t1", text: "File created"),
            .toolFinished(id: "t1", isError: false),
            .messageDone("Done."),
        ])

        // A terminal appends a new turn.
        let handle = try FileHandle(forWritingTo: f.claudeFile)
        try handle.seekToEnd()
        handle.write(Data((line(["type": "user", "sessionId": "11111111-aaaa", "message": ["role": "user", "content": "And tests"]]) + "\n").utf8))
        try handle.close()
        let next = await iterator.next()
        XCTAssertEqual(next, .userMessage("And tests"))

        var thread = DevThreadState(kind: .claudeCode)
        (events + [next!]).forEach { thread.apply($0) }
        XCTAssertEqual(thread.items.filter { if case .user = $0 { return true }; return false }.count, 2)
    }

    func testCodexTailMapping() throws {
        var tailer = TranscriptTailer(harness: .codex)
        let events = codexRollout(thread: "thread-9", cwd: "/p").flatMap { tailer.events(forLine: Data($0.utf8)) }
        XCTAssertEqual(events, [
            .sessionStarted(id: "thread-9"),
            .userMessage("List the files"),
            .toolStarted(id: "c1", name: "exec_command", summary: "ls -la"),
            .toolOutput(id: "c1", text: "a.txt"),
            .toolFinished(id: "c1", isError: false),
            .messageDone("One file."),
        ])
    }

    // MARK: Live detection

    func testLiveDetectionRules() {
        let now = Date()
        XCTAssertTrue(SessionSync.isLive(updatedAt: now.addingTimeInterval(-30), now: now, processInProject: false, isNewest: false, startedInLuna: false))
        XCTAssertFalse(SessionSync.isLive(updatedAt: now.addingTimeInterval(-600), now: now, processInProject: false, isNewest: true, startedInLuna: false))
        XCTAssertTrue(SessionSync.isLive(updatedAt: now.addingTimeInterval(-3600), now: now, processInProject: true, isNewest: true, startedInLuna: false),
                      "idle terminal CLI still owns its newest session")
        XCTAssertFalse(SessionSync.isLive(updatedAt: now.addingTimeInterval(-3600), now: now, processInProject: true, isNewest: false, startedInLuna: false))
        XCTAssertFalse(SessionSync.isLive(updatedAt: now, now: now, processInProject: false, isNewest: true, startedInLuna: true),
                       "Luna's own session is not a terminal session")
    }

    func testProcessHarnessMatching() {
        XCTAssertEqual(LiveProcessScanner.harness(arguments: ["/Users/me/.local/bin/claude", "--resume"]), .claudeCode)
        XCTAssertEqual(LiveProcessScanner.harness(arguments: ["node", "/opt/bin/codex"]), .codex)
        XCTAssertNil(LiveProcessScanner.harness(arguments: ["codex", "app-server"]), "app-server is a client's backend, not a terminal")
        XCTAssertNil(LiveProcessScanner.harness(arguments: ["/bin/zsh", "-l"]))
        // Our own process is found by libproc but never reported.
        XCTAssertNotNil(LiveProcessScanner.workingDirectory(of: getpid()))
        XCTAssertFalse(LiveProcessScanner.agentProcesses().contains { $0.pid == getpid() })
    }

    // MARK: Settings

    func testDevSettingsPersist() throws {
        let defaults = scratchDefaults()
        let bin = try scratchDir()
        try script(bin, "claude-custom", "echo hi")
        try script(bin, "not-exec", "echo hi", executable: false)

        let settings = DevSettings(defaults: defaults)
        XCTAssertEqual(settings.approvalBehavior, .ask)
        XCTAssertTrue(settings.autoWireBrowserTools)
        XCTAssertFalse(settings.liveSyncEnabled, "experimental: off by default")
        settings.defaultHarness = .codex
        settings.setDefaultModel("gpt-x-sol", for: .codex)
        settings.approvalBehavior = .allowEdits
        settings.autoWireBrowserTools = false
        settings.liveSyncEnabled = true
        settings.showTerminalByDefault = true
        XCTAssertTrue(settings.setCLIPathOverride(bin.appendingPathComponent("claude-custom"), for: .claudeCode))
        XCTAssertFalse(settings.setCLIPathOverride(bin.appendingPathComponent("not-exec"), for: .codex))

        let reloaded = DevSettings(defaults: defaults)
        XCTAssertEqual(reloaded.defaultHarness, .codex)
        XCTAssertEqual(reloaded.defaultModel(for: .codex), "gpt-x-sol")
        XCTAssertEqual(reloaded.approvalBehavior, .allowEdits)
        XCTAssertFalse(reloaded.autoWireBrowserTools)
        XCTAssertTrue(reloaded.liveSyncEnabled)
        XCTAssertTrue(reloaded.showTerminalByDefault)
        XCTAssertEqual(reloaded.cliPathOverrides, [.claudeCode: bin.appendingPathComponent("claude-custom").path])
        XCTAssertEqual(DevSettings.executable(for: .claudeCode, defaults: defaults), bin.appendingPathComponent("claude-custom").path)
        XCTAssertEqual(DevSettings.executable(for: .codex, defaults: defaults), "codex")

        reloaded.setCLIPathOverride(nil, for: .claudeCode)
        XCTAssertEqual(DevSettings(defaults: defaults).cliPathOverrides, [:])
    }

    func testApprovalBehaviorMapsToRealModes() {
        XCTAssertEqual(DevApprovalBehavior.ask.claudePermissionMode, "manual")
        XCTAssertEqual(DevApprovalBehavior.allowEdits.claudePermissionMode, "acceptEdits")
        XCTAssertEqual(DevApprovalBehavior.fullAuto.claudePermissionMode, "bypassPermissions")
        XCTAssertEqual(DevApprovalBehavior.ask.codexApprovalPolicy, "untrusted")
        XCTAssertEqual(DevApprovalBehavior.allowEdits.codexApprovalPolicy, "on-request")
        XCTAssertEqual(DevApprovalBehavior.fullAuto.codexApprovalPolicy, "never")
        XCTAssertEqual(DevApprovalBehavior.fullAuto.codexSandbox, "danger-full-access")
        XCTAssertEqual(DevApprovalBehavior.allowEdits.codexSandbox, "workspace-write")
    }

    // MARK: Clean CLI environment (terminal breakage)

    func testInheritedAgentAndTerminalVariablesAreDropped() {
        let inherited = [
            "PATH": "/usr/bin", "HOME": "/Users/me", "CODEX_HOME": "/Users/me/.codex", "ANTHROPIC_MODEL": "x",
            "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_PID": "42",
            "CODEX_THREAD_ID": "t", "CODEX_SANDBOX": "seatbelt", "TERM": "xterm-ghostty", "TERM_PROGRAM": "ghostty",
            "TERMINFO": "/Applications/Ghostty.app/terminfo", "GHOSTTY_RESOURCES_DIR": "/x", "XPC_SERVICE_NAME": "app",
        ]
        let clean = LoginShellEnvironment.sanitized(inherited)
        XCTAssertEqual(Set(clean.keys), ["PATH", "HOME", "CODEX_HOME", "ANTHROPIC_MODEL"])
    }

    func testParsesLoginShellEnvironment() {
        var out = Data("motd noise\n__LUNA_PATH_START__".utf8)
        out.append(Data("PATH=/opt/homebrew/bin:/usr/bin".utf8)); out.append(0)
        out.append(Data("MULTI=a=b".utf8)); out.append(0)
        out.append(Data("__LUNA_PATH_END__".utf8))
        XCTAssertEqual(LoginShellEnvironment.parseEnvironment(out), ["PATH": "/opt/homebrew/bin:/usr/bin", "MULTI": "a=b"])
        XCTAssertNil(LoginShellEnvironment.parseEnvironment(Data("nothing".utf8)))
        let seed = LoginShellEnvironment.cleanSeed(from: ["CLAUDECODE": "1", "USER": "me", "SSH_AUTH_SOCK": "/s"], home: "/Users/me")
        XCTAssertEqual(seed["HOME"], "/Users/me")
        XCTAssertEqual(seed["USER"], "me")
        XCTAssertNil(seed["CLAUDECODE"])
    }

    func testPTYChildGetsCleanTerminalEnvironment() async throws {
        let pty = PTYSession(executable: "/bin/sh",
                             arguments: ["-c", "echo \"T=$TERM C=$COLORTERM CC=${CLAUDECODE:-none} TI=${TERMINFO:-none} L=${LANG:-none}\""],
                             workingDirectory: URL(fileURLWithPath: "/tmp"),
                             environment: ["PATH": "/usr/bin:/bin", "CLAUDECODE": "1", "TERM": "xterm-ghostty", "TERMINFO": "/x"])
        try pty.start(columns: 80, rows: 24)
        var output = ""
        for await chunk in pty.output { output += String(decoding: chunk, as: UTF8.self) }
        XCTAssertTrue(output.contains("T=xterm-256color C=truecolor CC=none TI=none L=en_US.UTF-8"), output)
    }
}

/// Real discovery against the installed CLIs (no turns, so no usage). Opt in with
/// LUNA_LIVE_CLI=1 (xcodebuild: TEST_RUNNER_LUNA_LIVE_CLI=1).
final class DevDiscoveryLiveTests: XCTestCase {
    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["LUNA_LIVE_CLI"] == "1" else { throw XCTSkip("LUNA_LIVE_CLI not set") }
    }

    func testDiscoversInstalledHarnessesAndTheirModels() async throws {
        let harnesses = await HarnessCatalog().discover()
        XCTAssertFalse(harnesses.isEmpty)
        for info in harnesses where info.supported {
            let catalog = HarnessModelCatalog(defaults: UserDefaults(suiteName: "DevDiscoveryLiveTests")!,
                                              executable: { _ in info.executable })
            let listing = try await catalog.listing(for: info.id, refresh: true)
            XCTAssertEqual(listing.source, .live, "\(info.id)")
            XCTAssertFalse(listing.models.isEmpty, "\(info.id)")
            XCTAssertEqual(listing.models.filter(\.isDefault).count, 1, "\(info.id): one default")
        }
        UserDefaults().removePersistentDomain(forName: "DevDiscoveryLiveTests")
    }
}

/// User bubbles show what was typed, not the context the CLI added. Synthetic records only.
final class TranscriptUserTextTests: XCTestCase {
    private func claudeUser(_ content: Any, extra: [String: Any] = [:]) -> [TranscriptEntry] {
        TranscriptMapper.claude(["type": "user", "message": ["role": "user", "content": content]].merging(extra) { $1 })
    }
    private func users(_ e: [TranscriptEntry]) -> [String] { e.compactMap { if case .user(let t) = $0 { t } else { nil } } }

    func testStripsSystemReminderAroundTypedText() {
        let t = "<system-reminder>ctx</system-reminder>\nfix the bug\n<system-reminder>more\nlines</system-reminder>"
        XCTAssertEqual(users(claudeUser(t)), ["fix the bug"])
    }
    func testCommandWrappersAndStdoutAreDropped() {
        XCTAssertEqual(users(claudeUser("<command-name>/clear</command-name><command-message>clear</command-message><command-args></command-args>")), [])
        XCTAssertEqual(users(claudeUser("<local-command-stdout>ok</local-command-stdout>")), [])
        XCTAssertEqual(users(claudeUser("<local-command-caveat>Caveat: x</local-command-caveat>")), [])
        XCTAssertEqual(users(claudeUser("Caveat: The messages below were generated by the user while running local commands. DO NOT respond")), [])
    }
    func testIdeContextAndHookOutputStripped() {
        let t = "<ide_opened_file>The user opened a.swift</ide_opened_file>look at this<user-prompt-submit-hook>hook</user-prompt-submit-hook>"
        XCTAssertEqual(users(claudeUser(t)), ["look at this"])
    }
    func testPastedContentKeepsTextNotTags() {
        XCTAssertEqual(users(claudeUser("see <pasted-content id=\"1\">line a\nline b</pasted-content>")), ["see line a\nline b"])
    }
    func testToolResultsStayToolResultsAndMetaEntriesAreSkipped() {
        let blocks: [[String: Any]] = [["type": "tool_result", "tool_use_id": "t1", "content": "out"]]
        let e = claudeUser(blocks)
        XCTAssertEqual(users(e), [])
        XCTAssertEqual(e.count, 1)
        XCTAssertEqual(claudeUser("hi", extra: ["isMeta": true]).count, 0)
        XCTAssertEqual(claudeUser("summary", extra: ["isCompactSummary": true]).count, 0)
        XCTAssertEqual(users(claudeUser("This session is being continued from a previous conversation that ran out")), [])
    }
    func testImageBecomesChipWithTypedText() {
        let blocks: [[String: Any]] = [["type": "image", "source": ["data": "AAAA"]], ["type": "text", "text": "what is this"]]
        XCTAssertEqual(users(claudeUser(blocks)), ["[Image]\nwhat is this"])
    }
    func testCodexInjectionsSkippedAndTypedTextKept() {
        func rec(_ role: String, _ text: String) -> [TranscriptEntry] {
            TranscriptMapper.codex(["type": "response_item", "payload": ["type": "message", "role": role,
                                    "content": [["type": "input_text", "text": text]]]])
        }
        XCTAssertEqual(users(rec("user", "<environment_context>cwd</environment_context>")), [])
        XCTAssertEqual(users(rec("user", "# AGENTS.md instructions for /x\n\n<INSTRUCTIONS>be nice</INSTRUCTIONS>")), [])
        XCTAssertEqual(users(rec("user", "<user_instructions>x</user_instructions>")), [])
        XCTAssertEqual(users(rec("developer", "<permissions instructions>x</permissions instructions>")), [])
        XCTAssertEqual(users(rec("user", "ship it")), ["ship it"])
    }
}

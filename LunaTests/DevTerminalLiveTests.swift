import XCTest
#if LUNA_DEV
@testable import LunaDev
#else
@testable import Luna
#endif

/// A real interactive `claude` (haiku) in a Luna terminal, driven from chat: the reply must reach
/// the chat timeline through the transcript tail, then the session is resumed in a new terminal.
/// Costs a few cents; opt in with LUNA_LIVE_TERMINAL=1 (xcodebuild: TEST_RUNNER_LUNA_LIVE_TERMINAL=1).
/// Cleans up its project folder and its `~/.claude/projects` folder; Claude's folder-trust entry in
/// `~/.claude.json` is left for the person running it to remove.
@MainActor
final class DevTerminalLiveTests: XCTestCase {
    private var project: URL!
    private var defaultsName = "DevTerminalLiveTests-\(UUID().uuidString)"

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["LUNA_LIVE_TERMINAL"] == "1" else { throw XCTSkip("LUNA_LIVE_TERMINAL not set") }
        let base = ProcessInfo.processInfo.environment["LUNA_LIVE_TERMINAL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        project = base.appendingPathComponent("luna-live-term-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        project = URL(fileURLWithPath: project.resolvingSymlinksInPath().path, isDirectory: true)
    }

    override func tearDown() async throws {
        guard let project else { return }
        try? await Task.sleep(nanoseconds: 1_500_000_000) // a closing CLI may still flush its transcript
        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        for path in SessionSync.pathVariants(project) {
            try? FileManager.default.removeItem(at: claudeProjects.appendingPathComponent(SessionSync.claudeProjectFolderName(path)))
        }
        try? FileManager.default.removeItem(at: project)
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return condition()
    }

    private func assistantTexts(_ session: DevSession) -> [String] {
        session.timeline.items.compactMap { if case .assistant(let text, _) = $0 { return text.lowercased() }; return nil }
    }

    func testNewClaudeSessionInTerminalSyncsToChatThenResumes() async throws {
        let output = LockedBox("")
        var deps = DevSession.Dependencies()
        deps.resumeStore = AgentCLIResumeStore(defaults: UserDefaults(suiteName: defaultsName)!)
        deps.makeTerminal = {
            let t = DevTerminalController(approval: { .ask }, mcpProvider: { nil })
            t.outputObserver = { output.value += DevTerminalScreen.plainText($0) }
            return t
        }
        let session = DevSession(harness: .claudeCode, projectDir: project,
                                 setup: DevSessionSetup(harness: .claudeCode, model: "haiku", approvalBehavior: .ask), dependencies: deps)
        defer { session.close() }

        let term = try XCTUnwrap(session.openTerminal())
        let ready = await wait(40) { output.value.localizedCaseInsensitiveContains("trust") || output.value.contains("for shortcuts") }
        XCTAssertTrue(ready, "claude drew its first screen")
        if output.value.localizedCaseInsensitiveContains("trust") {
            // Folder-trust question; outside a project Claude preselects "No, exit".
            try await Task.sleep(nanoseconds: 2_000_000_000) // let the TUI switch the tty to raw input
            if output.value.contains("No, exit") || output.value.contains("No,exit") {
                term.write(raw: "\u{1b}OB")
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            term.send(text: "")
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        if let log = ProcessInfo.processInfo.environment["LUNA_LIVE_TERMINAL_LOG"] {
            try? "exit=\(String(describing: term.exitCode)) running=\(term.isRunning) args=\(term.lastLaunch?.arguments ?? [])\n\(output.value)"
                .write(toFile: log, atomically: true, encoding: .utf8)
        }
        XCTAssertTrue(term.isRunning)
        guard term.isRunning else { return }
        XCTAssertEqual(session.send("Reply with just the word ok"), .terminal)

        let replied = await wait(120) { self.assistantTexts(session).contains { $0.contains("ok") } }
        XCTAssertTrue(replied, "the terminal's reply reached the chat timeline via follow()")
        XCTAssertEqual(session.sessionID, term.lastLaunch?.sessionID, "captured the preset --session-id")
        XCTAssertNotNil(term.sessionFile)

        session.closeTerminal()
        _ = await wait(5) { !term.isRunning }
        output.value = ""

        let resumed = try XCTUnwrap(session.openTerminal())
        XCTAssertEqual(resumed.currentMode, .resume(try XCTUnwrap(session.ref)))
        XCTAssertEqual(resumed.lastLaunch?.arguments.prefix(2), ["--resume", session.sessionID!])
        let resumedReady = await wait(40) { output.value.contains("for shortcuts") || output.value.count > 400 }
        XCTAssertTrue(resumedReady)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertEqual(session.send("Now reply with just the word done"), .terminal)
        let second = await wait(120) { self.assistantTexts(session).contains { $0.contains("done") } }
        XCTAssertTrue(second, "the resumed terminal keeps syncing")
        XCTAssertTrue(assistantTexts(session).contains { $0.contains("ok") }, "history replayed after resume")
        session.closeTerminal()
    }
}

/// Prints how much the finders see on this Mac (counts only, no names). Opt in with
/// LUNA_FINDER_REPORT=1. The git scan skips ~/Documents here so the test host never triggers a
/// privacy prompt.
final class DevFinderReportTests: XCTestCase {
    func testReportCounts() async throws {
        guard ProcessInfo.processInfo.environment["LUNA_FINDER_REPORT"] == "1" else { throw XCTSkip("LUNA_FINDER_REPORT not set") }
        let home = NSHomeDirectory()
        let finder = ProjectFinder(recents: { [] }, searchRoots: { ["Developer", "Projects", "code"].map { home + "/" + $0 } }, hidden: { [] })
        let started = Date()
        let projects = await finder.projects(refresh: true)
        let elapsed = Date().timeIntervalSince(started)
        func count(_ s: DevProject.Source) -> Int { projects.filter { $0.sources.contains(s) }.count }
        let sessions = await SessionSync.shared.allSessions(limit: 200)
        print("FINDER_REPORT projects=\(projects.count) claude=\(count(.claudeSessions)) codex=\(count(.codexSessions)) git=\(count(.gitScan)) gitRepos=\(projects.filter(\.isGitRepo).count) scan=\(String(format: "%.2f", elapsed))s")
        print("FINDER_REPORT sessions=\(sessions.count) claude=\(sessions.filter { $0.harness == .claudeCode }.count) codex=\(sessions.filter { $0.harness == .codex }.count) liveExternal=\(sessions.filter(\.isLive).count) withModel=\(sessions.filter { $0.model != nil }.count)")
    }
}

import XCTest
@testable import Luna

/// Dev home: the step state machine, Skip home / default setup resolution, which program the
/// Terminal tab runs, and queuing chat sends until a freshly launched CLI is ready.
@MainActor
final class DevHomeTests: XCTestCase {
    private let setup = DevSessionSetup(harness: .codex, model: "gpt-x", effort: "high", approvalBehavior: .ask, project: .last)

    // MARK: Home steps

    func testHomeFlowStepsForwardAndBack() {
        var flow = DevHomeFlow()
        XCTAssertEqual(flow.step, .project)
        flow.choose(project: "/work/app")
        XCTAssertEqual(flow.step, .harness)
        flow.choose(harness: .claudeCode)
        XCTAssertEqual(flow.step, .model)
        flow.chooseModel("haiku", effort: nil)
        XCTAssertEqual(flow.step, .session)
        XCTAssertEqual(flow.setup(base: setup)?.model, "haiku")
        XCTAssertEqual(flow.setup(base: setup)?.harness, .claudeCode)
        XCTAssertEqual(flow.setup(base: setup)?.project, .specific("/work/app"))

        flow.edit(.harness)
        XCTAssertEqual(flow.step, .harness)
        XCTAssertEqual(flow.project, "/work/app", "earlier choices stay")
        XCTAssertNil(flow.model, "later choices are cleared")
        XCTAssertNil(flow.setup(base: setup))

        flow.choose(harness: .codex)
        flow.chooseModel("gpt-x", effort: "low")
        flow.back()
        XCTAssertEqual(flow.step, .model)
        flow.choose(harness: .codex)
        XCTAssertEqual(flow.model, "gpt-x", "re-picking the same harness keeps its model")
        flow.choose(harness: .claudeCode)
        XCTAssertNil(flow.model, "another harness clears the model")
        XCTAssertNil(flow.effort)
        flow.edit(.project)
        XCTAssertEqual(flow.step, .project)
        XCTAssertNil(flow.harness)
    }

    func testHomeFlowPreselectsDefaultHarnessOnlyWhenInstalled() {
        XCTAssertEqual(DevHomeFlow(project: "/p", setup: setup, installed: [.codex]).step, .model)
        XCTAssertEqual(DevHomeFlow(project: "/p", setup: setup, installed: [.claudeCode]).step, .harness)
        XCTAssertEqual(DevHomeFlow(project: nil, setup: setup, installed: [.codex]).step, .project)
    }

    // MARK: Skip home / default setup

    func testLaunchResolution() {
        let last = DevSessionRef(harness: .claudeCode, id: "s-1", projectDir: URL(fileURLWithPath: "/last", isDirectory: true))
        let none: (String) -> DevSessionRef? = { _ in nil }

        XCTAssertEqual(DevLaunch.resolve(skipHome: false, setup: setup, lastProject: "/last", lastSession: { _ in last },
                                         installed: [.codex]), .home)
        XCTAssertEqual(DevLaunch.resolve(skipHome: true, setup: setup, lastProject: nil, lastSession: none, installed: []), .home,
                       "no project to open")
        XCTAssertEqual(DevLaunch.resolve(skipHome: true, setup: setup, lastProject: "/last", lastSession: { $0 == "/last" ? last : nil },
                                         installed: [.codex, .claudeCode]), .resume(last))

        var specific = setup
        specific.project = .specific("/spec")
        guard case .new(let kind, let dir, let s) = DevLaunch.resolve(skipHome: true, setup: specific, lastProject: "/last",
                                                                     lastSession: { $0 == "/last" ? last : nil }, installed: [.codex])
        else { return XCTFail("expected a new session") }
        XCTAssertEqual(kind, .codex)
        XCTAssertEqual(dir.path, "/spec")
        XCTAssertEqual(s.model, "gpt-x")
        XCTAssertEqual(s.effort, "high")

        // The default harness is not installed: the installed one, without its model / effort.
        guard case .new(let other, _, let s2) = DevLaunch.resolve(skipHome: true, setup: specific, lastProject: nil,
                                                                 lastSession: none, installed: [.claudeCode])
        else { return XCTFail("expected a new session") }
        XCTAssertEqual(other, .claudeCode)
        XCTAssertNil(s2.model)
        XCTAssertNil(s2.effort)

        // The last session's harness is not installed: start new instead of resuming.
        guard case .new = DevLaunch.resolve(skipHome: true, setup: setup, lastProject: "/last", lastSession: { _ in last },
                                            installed: [.codex])
        else { return XCTFail("expected a new session") }
    }

    // MARK: Terminal tab

    func testTerminalModeFromHomeState() {
        let dir = URL(fileURLWithPath: "/work/app", isDirectory: true)
        XCTAssertEqual(DevTerminalPlan.mode(session: nil, newSetup: nil, projectDir: nil), .shell(nil), "home without project: shell in ~")
        XCTAssertEqual(DevTerminalPlan.mode(session: nil, newSetup: nil, projectDir: dir), .shell(dir))
        XCTAssertEqual(DevTerminalPlan.mode(session: nil, newSetup: setup, projectDir: dir), .newSession(.codex, setup, projectDir: dir))
        let ref = DevSessionRef(harness: .claudeCode, id: "abc", projectDir: dir)
        XCTAssertEqual(DevTerminalPlan.mode(session: ref, newSetup: setup, projectDir: dir), .resume(ref), "a chosen session wins")
    }

    // MARK: Readiness / send queue

    func testReadinessWaitsForQuietOutputAndTrust() {
        let t0 = Date()
        var r = DevCLIReadiness(launchedAt: t0)
        XCTAssertFalse(r.isReady(at: t0.addingTimeInterval(1)), "no output yet")
        r.noteOutput(screen: "Welcome to Claude Code", at: t0.addingTimeInterval(1))
        XCTAssertFalse(r.isReady(at: t0.addingTimeInterval(1.8)), "still drawing")
        r.noteOutput(screen: "Is this a project you created or one you trust? 1. Yes, proceed", at: t0.addingTimeInterval(1.4))
        XCTAssertFalse(r.isReady(at: t0.addingTimeInterval(5)), "trust prompt blocks")
        r.noteUserInput()
        XCTAssertTrue(r.isReady(at: t0.addingTimeInterval(5)))
        r.noteOutput(screen: "working", at: t0.addingTimeInterval(5.1))
        XCTAssertTrue(r.isReady(at: t0.addingTimeInterval(5.2)), "stays ready once ready")
        r.noteOutput(screen: "Do you trust the files in this folder?", at: t0.addingTimeInterval(6))
        XCTAssertFalse(r.isReady(at: t0.addingTimeInterval(9)), "a trust prompt blocks even after ready")

        var setupOnly = DevCLIReadiness(launchedAt: t0)
        setupOnly.noteOutput(screen: "", visible: false, at: t0.addingTimeInterval(0.1))
        XCTAssertFalse(setupOnly.isReady(at: t0.addingTimeInterval(4)), "screen setup without text is not a prompt")

        var silent = DevCLIReadiness(launchedAt: t0)
        XCTAssertFalse(silent.isReady(at: t0.addingTimeInterval(silent.maximum - 1)))
        XCTAssertTrue(silent.isReady(at: t0.addingTimeInterval(silent.maximum + 0.1)), "ready after the maximum wait")
        var shell = DevCLIReadiness.immediate(t0)
        XCTAssertTrue(shell.isReady(at: t0))
    }

    func testTerminalRepliesAreNotUserInput() {
        for reply in ["\u{1b}[?1;2c", "\u{1b}[?0u", "\u{1b}[12;40R", "\u{1b}]11;rgb:0000/0000/0000\u{7}", "\u{1b}[I"] {
            XCTAssertTrue(DevTerminalScreen.isTerminalReply(Data(reply.utf8)), reply.debugDescription)
        }
        for key in ["\u{1b}[A", "\u{1b}[B", "\r", "y", "\u{1b}", "\u{1b}[1;5C"] {
            XCTAssertFalse(DevTerminalScreen.isTerminalReply(Data(key.utf8)), key.debugDescription)
        }
    }

    /// A fake CLI that throws away anything typed before it has drawn its prompt (as Ink TUIs do),
    /// then echoes lines. A send right after launch must arrive anyway.
    func testSendIsQueuedUntilTheCLIIsReady() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("luna-devhome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let script = base.appendingPathComponent("fake-cli")
        try """
        #!/bin/bash
        sleep 0.7
        while read -t 0.1 -r junk; do :; done
        printf 'READY> '
        while IFS= read -r line; do printf 'GOT:%s\\n' "$line"; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let output = LockedBox("")
        let term = DevTerminalController(watcher: SessionStoreWatcher(claudeRoot: base.appendingPathComponent("c"), codexRoot: base.appendingPathComponent("x")),
                                         approval: { .ask }, mcpProvider: { nil }, executable: { _ in script.path })
        term.outputObserver = { data in output.value += String(decoding: data, as: UTF8.self) }
        term.open(.newSession(.claudeCode, setup, projectDir: base))
        defer { term.terminate() }
        XCTAssertFalse(term.isReady)
        term.send(text: "reply with ok")
        XCTAssertEqual(term.queuedSends, ["reply with ok"], "queued while the CLI starts")

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !output.value.contains("GOT:reply with ok") {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(output.value.contains("GOT:reply with ok"), "the queued message reached the CLI after its prompt")
        XCTAssertTrue(term.isReady)
        XCTAssertTrue(term.queuedSends.isEmpty)
    }
}

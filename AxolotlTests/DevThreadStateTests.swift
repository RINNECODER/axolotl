import XCTest
#if AXOLOTL_DEV
@testable import AxolotlDev
#else
@testable import Axolotl
#endif

/// Dev mode thread reduction, fed with events mapped from captured real CLI output.
@MainActor
final class DevThreadStateTests: XCTestCase {

    private func records(_ fixture: String) -> [JSONValue] {
        fixture.split(separator: "\n").filter { !$0.hasPrefix(">>") }.compactMap { CLIText.parse(Data($0.utf8)) }
    }

    private func claudeEvents(_ fixture: String) -> [CLIEvent] {
        var mapper = ClaudeStreamMapper()
        return records(fixture).flatMap { mapper.map($0).events }
    }

    private func codexEvents(_ fixture: String) -> [CLIEvent] {
        var mapper = CodexRPCMapper()
        mapper.expect(id: 2, method: "thread/start")
        for id in 3...5 { mapper.expect(id: id, method: "turn/start") }
        return records(fixture).flatMap { mapper.map($0).events }
    }

    private func footers(_ state: DevThreadState) -> [DevThreadState.TurnFooter] {
        state.items.compactMap { if case .turn(let f) = $0 { return f }; return nil }
    }

    private func tools(_ state: DevThreadState) -> [DevThreadState.ToolCard] {
        state.items.compactMap { if case .tool(let t) = $0 { return t }; return nil }
    }

    private func approvals(_ state: DevThreadState) -> [DevThreadState.ApprovalCard] {
        state.items.compactMap { if case .approval(let a) = $0 { return a }; return nil }
    }

    func testClaudeTextTurnStreamsIntoOneMessage() {
        var state = DevThreadState(kind: .claudeCode)
        state.attached()
        state.userSent("reply with ok")
        let events = claudeEvents(CLIFixtures.claudeTextTurn)
        let firstDelta = events.firstIndex { if case .textDelta = $0 { return true }; return false }!
        for event in events[...firstDelta] { state.apply(event) }
        XCTAssertEqual(state.items.last, .assistant(text: "ok", streaming: true))
        for event in events[(firstDelta + 1)...] { state.apply(event) }

        XCTAssertEqual(state.sessionID, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(Array(state.items.prefix(2)), [.user("reply with ok"), .assistant(text: "ok", streaming: false)])
        XCTAssertEqual(footers(state).map(\.outcome), [.completed])
        XCTAssertEqual(footers(state).first?.costUSD ?? 0, 0.00366919, accuracy: 1e-9)
        XCTAssertFalse(state.isTurnActive)
        XCTAssertTrue(state.canSend)
    }

    func testClaudeToolApprovalAndPerTurnCost() {
        var state = DevThreadState(kind: .claudeCode)
        state.attached()
        state.userSent("write a.txt")
        state.userSent("stop")  // Claude queues a message sent mid-turn
        XCTAssertTrue(state.canSend, "Claude accepts sends mid-turn")
        for event in claudeEvents(CLIFixtures.claudeToolTurn) {
            state.apply(event)
            if case .approvalRequest(let request) = event {
                XCTAssertEqual(state.pendingApprovals, 1)
                XCTAssertTrue(DevApprovalText.detail(for: request).contains("+ hi"))
                state.decided(approvalID: request.id, .allow)
            }
        }
        XCTAssertEqual(approvals(state).map(\.status), [.decided(.allow)])
        XCTAssertEqual(tools(state).map(\.name), ["Write"])
        XCTAssertEqual(tools(state).map(\.status), [.done])
        let turns = footers(state)
        XCTAssertEqual(turns.map(\.outcome), [.completed, .interrupted])
        // Claude's cost is cumulative; each footer shows only its own turn.
        XCTAssertEqual(turns[0].costUSD ?? 0, 0.0068513, accuracy: 1e-9)
        XCTAssertEqual(turns[1].costUSD ?? -1, 0, accuracy: 1e-9)
        XCTAssertFalse(state.isTurnActive, "both queued turns finished")
        guard case .assistant(let text, false)? = state.items.first(where: { if case .assistant(let t, _) = $0 { return t.hasPrefix("Yes") }; return false }) else {
            return XCTFail("the reply after the tool is its own message")
        }
        XCTAssertTrue(text.hasSuffix("/tmp/axolotl-fixture/proj/a.txt`."))
    }

    func testCodexBlocksSendMidTurnAndExpiresUnansweredApproval() {
        var state = DevThreadState(kind: .codex)
        state.attached()
        state.userSent("go")
        XCTAssertFalse(state.canSend, "Codex rejects a send mid-turn")
        var turnsDone = 0
        for event in codexEvents(CLIFixtures.codexTurns) {
            state.apply(event)
            if case .turnDone = event {
                turnsDone += 1
                XCTAssertTrue(state.canSend)
                if turnsDone < 3 { state.userSent("next") }
            }
        }
        let approval = approvals(state)
        XCTAssertEqual(approval.map(\.status), [.expired], "nobody answered before the turn ended")
        XCTAssertEqual(DevApprovalText.detail(for: approval[0].request), "$ /bin/zsh -lc 'touch made.txt'")
        XCTAssertEqual(tools(state).map(\.status), [.failed], "declined command")
        XCTAssertEqual(footers(state).map(\.outcome), [.completed, .completed, .interrupted])
        XCTAssertNil(footers(state).first?.costUSD)
    }

    func testCrashFailsRunningWorkAndShowsStderr() {
        var state = DevThreadState(kind: .claudeCode)
        state.attached()
        state.userSent("go")
        state.apply(.toolStarted(id: "t1", name: "Bash", summary: "sleep 9"))
        state.apply(.toolOutput(id: "t1", text: "partial"))
        state.apply(.approvalRequest(CLIApprovalRequest(id: "a1", kind: .command, title: "Bash", summary: "rm x", payload: .object(["command": "rm x"]))))
        state.apply(.exited(CLIExit(status: 1, signaled: false, expected: false, stderrTail: "panic: boom")))

        XCTAssertEqual(tools(state).map(\.status), [.failed])
        XCTAssertEqual(tools(state).first?.output, "partial")
        XCTAssertEqual(approvals(state).map(\.status), [.expired])
        XCTAssertEqual(state.items.last, .crash(status: 1, signaled: false, stderrTail: "panic: boom"))
        XCTAssertFalse(state.isAlive)
        XCTAssertFalse(state.isTurnActive)
        XCTAssertFalse(state.canSend)
    }

    func testExpectedExitIsNotACrash() {
        var state = DevThreadState(kind: .codex)
        state.attached()
        state.apply(.exited(CLIExit(status: 0, signaled: false, expected: true, stderrTail: "")))
        XCTAssertTrue(state.items.isEmpty)
        XCTAssertFalse(state.isAlive)
    }

    func testEditApprovalShowsADiff() {
        let request = CLIApprovalRequest(id: "e", kind: .fileChange, title: "Edit", summary: "a.swift",
                                         payload: .object(["request": .object(["input": .object([
                                             "file_path": "/p/a.swift", "old_string": "let a = 1", "new_string": "let a = 2"])])]))
        XCTAssertEqual(DevApprovalText.detail(for: request), "/p/a.swift\n- let a = 1\n+ let a = 2")
    }
}

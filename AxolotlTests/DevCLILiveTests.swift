import XCTest
#if AXOLOTL_DEV
@testable import AxolotlDev
#else
@testable import Axolotl
#endif

/// Real Claude Code and Codex turns in a throwaway project folder. Costs a few cents of
/// usage, so opt in with AXOLOTL_LIVE_CLI=1 (xcodebuild: TEST_RUNNER_AXOLOTL_LIVE_CLI=1).
@MainActor
final class DevCLILiveTests: XCTestCase {
    private var project: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["AXOLOTL_LIVE_CLI"] == "1" else { throw XCTSkip("AXOLOTL_LIVE_CLI not set") }
        project = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-live-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "DevCLILiveTests")
    }

    override func tearDown() async throws {
        if let project { try? FileManager.default.removeItem(at: project) }
        UserDefaults().removePersistentDomain(forName: "DevCLILiveTests")
    }

    /// Sends `prompt`, answers approvals with `decision`, and returns events through the first turnDone.
    private func turn(_ session: AgentCLISession, model: String, prompt: String,
                      decision: CLIApprovalDecision = .deny, timeout: TimeInterval = 120) async throws -> [CLIEvent] {
        try await session.start(projectDir: project, model: model, resumeID: nil)
        try session.send(prompt)
        let collector = Task { @MainActor in
            var events: [CLIEvent] = []
            for await event in session.events {
                events.append(event)
                if case .approvalRequest(let request) = event { session.respond(approvalID: request.id, decision: decision) }
                if case .turnDone = event { break }
            }
            return events
        }
        let timer = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); session.close() }
        let events = await collector.value
        timer.cancel()
        session.close()
        return events
    }

    private func assertBasicTurn(_ events: [CLIEvent], file: StaticString = #filePath, line: UInt = #line) {
        guard case .sessionStarted? = events.first else { return XCTFail("sessionStarted first: \(events)", file: file, line: line) }
        let text = events.compactMap { if case .textDelta(let t) = $0 { return t }; return nil }.joined()
        XCTAssertTrue(text.lowercased().contains("ok"), "text: \(text)", file: file, line: line)
        guard case .turnDone(_, .completed)? = events.last else { return XCTFail("turnDone last: \(events.suffix(3))", file: file, line: line) }
    }

    func testClaudeHaikuTurn() async throws {
        let session = ClaudeCodeAdapter(mcp: nil, resumeStore: AgentCLIResumeStore(defaults: defaults))
        session.persistSession = false
        assertBasicTurn(try await turn(session, model: "haiku", prompt: "Reply with the word ok"))
    }

    func testClaudeApprovalDeclined() async throws {
        let session = ClaudeCodeAdapter(mcp: nil, resumeStore: AgentCLIResumeStore(defaults: defaults))
        session.persistSession = false
        let events = try await turn(session, model: "haiku",
                                    prompt: "Use the Write tool to create a.txt containing hi. If that is refused, reply with the word ok.")
        let kinds = events.compactMap { if case .approvalRequest(let a) = $0 { return a.kind }; return nil }
        XCTAssertEqual(kinds.first, .fileChange, "events: \(events)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("a.txt").path))
        guard case .turnDone(_, .completed)? = events.last else { return XCTFail("turn should finish") }
    }

    func testCodexTurn() async throws {
        let session = CodexAdapter(mcp: nil, resumeStore: AgentCLIResumeStore(defaults: defaults))
        session.effort = "low"
        session.persistSession = false
        assertBasicTurn(try await turn(session, model: "gpt-6-axolotl", prompt: "Reply with the word ok"))
    }
}

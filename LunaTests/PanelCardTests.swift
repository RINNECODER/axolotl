import XCTest
@testable import Luna

/// The AI panel's run and key-grab cards, folded from agent events, and their storage.
@MainActor
final class PanelCardTests: XCTestCase {

    private func decided(_ op: String, target: String?, label: String, confidence: Double?) -> AgentEvent {
        .decided(AgentDecision(choice: "e1", operation: op, target: target, confidence: confidence,
                               probability: nil, latencyMs: 120, model: "jev"), label: label)
    }

    private func executed(_ step: Int, text: String? = nil, changed: Bool?) -> AgentEvent {
        .executed(AgentStepRecord(step: step, action: "e1", kind: "click", choice: "e1", operation: "CLICK",
                                  text: text, confidence: nil, latencyMs: 0, url: "https://example.com",
                                  pageChanged: changed))
    }

    func testRunFoldsDecisionsAndResultsIntoStepsThenAnOutcome() {
        var run = AgentRunCard(goal: "search for Dune", model: "jev")
        let events: [AgentEvent] = [
            .observed(url: "https://example.com", title: "Example", actions: 4),
            decided("TYPE_TEXT", target: "2", label: "Search", confidence: 0.91),
            executed(1, text: "Dune", changed: true),
            .stale("The page changed; looking again."),
            decided("SCROLL_DOWN", target: nil, label: "", confidence: nil),
            executed(2, changed: false),
            .finished(.blocked("No results."), steps: 2, elapsedMs: 3400),
        ]
        for e in events { run.apply(e) }

        XCTAssertEqual(run.steps.map(\.operation), ["Type", "Scroll down"])
        XCTAssertEqual(run.steps[0].target, "Search")
        XCTAssertEqual(run.steps[0].result, "“Dune”")
        XCTAssertEqual(run.steps[0].confidence, 0.91)
        XCTAssertFalse(run.steps[0].noChange)
        XCTAssertEqual(run.steps[1].target, "", "page-level actions have no target")
        XCTAssertTrue(run.steps[1].noChange)
        XCTAssertTrue(run.steps.allSatisfy(\.executed))
        XCTAssertEqual(run.status, .blocked)
        XCTAssertEqual(run.reason, "No results.")
        XCTAssertNil(run.note, "a stale notice is cleared once the run moves on")
        XCTAssertEqual(run.outcomeLine, "Blocked · 2 steps · 3.4 s")
        XCTAssertEqual(run.transcript, "Agent run: search for Dune\nBlocked · 2 steps · 3.4 s: No results.")
    }

    func testStopEndsOnlyARunningRun() {
        var running = AgentRunCard(goal: "g", model: "m")
        running.apply(decided("CLICK", target: "1", label: "Go", confidence: 0.5))
        running.markStopped()
        XCTAssertEqual(running.status, .stopped)
        XCTAssertEqual(running.outcomeLine, "Stopped · 1 step")

        var done = AgentRunCard(goal: "g", model: "m")
        done.apply(.finished(.done, steps: 0, elapsedMs: 10))
        done.markStopped()
        XCTAssertEqual(done.status, .done, "Stop after the agent finished must not rewrite the outcome")
    }

    func testGrabCardKeepsTheKeychainItemButNeverAValue() {
        let service = KeyService.registry.first { $0.id == "openai" }!
        var card = GrabCard(service: service, keyName: "luna-1", model: "jev")
        card.run.apply(decided("CLICK", target: "3", label: "Create key", confidence: 0.8))
        let saved = SecretVault.Saved(handle: "h1", keychainItem: "Luna API Keys / openai/luna-1", account: "openai/luna-1")
        card.finish(GrabResult(status: .saved, service: "OpenAI", keyName: "luna-1", saved: saved, message: "Saved."))
        XCTAssertEqual(card.status, .saved)
        XCTAssertEqual(card.keychainItem, "Luna API Keys / openai/luna-1")
        XCTAssertEqual(card.run.status, .stopped, "the step list stops spinning once the grab returns")

        var waiting = GrabCard(service: service, keyName: "k", model: "jev")
        waiting.finish(GrabResult(status: .waitingForSignIn, service: "OpenAI", keyName: "k", message: "Sign in."))
        XCTAssertEqual(waiting.status, .waitingForSignIn)
        XCTAssertNil(waiting.keychainItem)
    }

    /// Chat history on disk predates cards: it must still load, and cards must round-trip.
    func testChatHistoryWithoutCardsStillDecodesAndCardsRoundTrip() throws {
        let legacy = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","role":"assistant","text":"hi","timestamp":0}"#
        let old = try JSONDecoder().decode(ChatMessage.self, from: Data(legacy.utf8))
        XCTAssertEqual(old.text, "hi")
        XCTAssertNil(old.card)

        var run = AgentRunCard(goal: "g", model: "m")
        run.apply(decided("CLICK", target: "1", label: "Go", confidence: 0.7))
        let message = ChatMessage(role: .assistant, text: run.transcript, card: .agentRun(run))
        let back = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(back.card, .agentRun(run))
    }
}

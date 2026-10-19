import XCTest
@testable import Axolotl

final class LLMStreamTests: XCTestCase {
    private func lines(_ events: [String]) -> AsyncStream<String> {
        AsyncStream { c in events.forEach { c.yield($0) }; c.finish() }
    }

    private func run(_ events: [String]) async -> (String, Error?) {
        var text = ""
        do {
            try await AnthropicClient.consume(lines: lines(events), onToken: { text += $0 })
            return (text, nil)
        } catch { return (text, error) }
    }

    private let delta = #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#
    private let stop = #"data: {"type":"message_stop"}"#

    func testAnthropicCompleteStreamSucceeds() async {
        let (text, error) = await run([delta, #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#, stop])
        XCTAssertEqual(text, "Hi")
        XCTAssertNil(error)
    }

    func testAnthropicStreamWithoutMessageStopIsIncomplete() async {
        let (text, error) = await run([delta])
        XCTAssertEqual(text, "Hi")
        guard case .incomplete? = error as? LLMError else { return XCTFail("got \(String(describing: error))") }
    }

    func testAnthropicMaxTokensIsReported() async {
        let (_, error) = await run([delta, #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#, stop])
        guard case .incomplete(let msg)? = error as? LLMError else { return XCTFail("got \(String(describing: error))") }
        XCTAssertTrue(msg.contains("limit"))
    }

    func testCollectReturnsTextOnSuccess() async throws {
        let text = try await LLMService.collect { onToken, onCompletion in
            Task { onToken(" a"); onToken("b "); onCompletion(.success(())) }
        }
        XCTAssertEqual(text, "ab")
    }

    func testCollectThrowsOnCancelEvenThoughStreamNeverCompletes() async {
        let streamCancelled = expectation(description: "inner stream cancelled")
        let outer = Task {
            try await LLMService.collect { _, _ in
                // Like LLMService.stream: never calls onCompletion once cancelled.
                Task {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    streamCancelled.fulfill()
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        outer.cancel()
        let result = await outer.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        await fulfillment(of: [streamCancelled], timeout: 2)
    }

    func testStatusNotesAreNotSentToTheModel() {
        var reply = ChatMessage(role: .assistant, text: "Partial answer")
        reply.status = "Error: Network down"
        var failed = ChatMessage(role: .assistant, text: "")
        failed.status = "Generation stopped"
        let request = LLMRequest(prompt: "next", recentMessages: [
            ChatMessage(role: .user, text: "q1"), reply, ChatMessage(role: .user, text: "q2"), failed,
        ])
        let all = request.turns.map(\.text).joined(separator: "\n")
        XCTAssertFalse(all.contains("Error"))
        XCTAssertFalse(all.contains("stopped"))
        XCTAssertTrue(all.contains("Partial answer"))
    }

    func testSummaryRequestFoldsPreviousSummary() {
        let req = LLMService.summaryRequest(previous: "User planned a trip.", messages: [ChatMessage(role: .user, text: "Book Rome")])
        XCTAssertTrue(req.prompt.contains("User planned a trip."))
        XCTAssertTrue(req.prompt.contains("Book Rome"))
        XCTAssertFalse(LLMService.summaryRequest(previous: nil, messages: []).prompt.contains("Earlier summary"))
    }
}

import XCTest
@testable import Axolotl

// MARK: - Fixtures

private func action(_ id: String, _ kind: String, node: Int? = nil, label: String, value: String? = nil,
                    current: String? = nil, role: String? = nil) -> PageAction {
    PageAction(id: id, kind: kind, label: label, node: node, role: role, value: value, currentValue: current,
               checked: nil, selected: nil, expanded: nil, delta: kind == "scroll" ? 560 : nil)
}

private func page(_ fingerprint: String = "f0", actions: [PageAction]? = nil) -> PageSnapshot {
    PageSnapshot(
        url: "https://example.test/", title: "Shop", text: "Find a book",
        actions: actions ?? [
            action("e1", "fill", node: 1, label: "Search", value: "", role: "searchbox"),
            action("e2", "click", node: 1, label: "Open Search", value: "", role: "searchbox"),
            action("e3", "select", node: 2, label: "Category → Books", value: "books", current: "All", role: "combobox"),
            action("e4", "select", node: 2, label: "Category → Movies", value: "movies", current: "All", role: "combobox"),
            action("e5", "click", node: 3, label: "Go", role: "button"),
            action("scroll_down", "scroll", label: "Scroll down"),
            action("wait", "wait", label: "Wait for the page to update"),
        ],
        scroll: .init(y: 0, height: 2000), omittedActions: 0, marker: "m-" + fingerprint,
        nodeKeys: ["1": "k1", "2": "k2", "3": "k3"], fingerprint: fingerprint)
}

private final class StubTransport: AgentHTTPTransport {
    var responses: [(Int, JSONValue)]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [(Int, JSONValue)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (try JSONValue.encoder.encode(body), status)
    }
    func body(_ i: Int = 0) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: requests[i].httpBody ?? Data())
    }
}

private func answer(_ choice: String, _ probs: [String: Double], confidence: Double = 0.9) -> JSONValue {
    .object(["choice": .string(choice), "probabilities": .object(probs.mapValues(JSONValue.number)),
             "confidence": .number(confidence)])
}

private func keys(_ v: JSONValue?) -> Set<String> { Set(v?.objectValue?.keys.map { $0 } ?? []) }

private func jevResponse(_ answers: [String: JSONValue]) -> JSONValue {
    .object(["answers": .object(answers), "model": "jev-1.14.0"])
}

// MARK: - JevClient

@MainActor
final class JevClientTests: XCTestCase {
    func testListModelsReadsNamesFromTheModelsEndpoint() async throws {
        let stub = StubTransport([(200, .object(["models": .array([.object(["name": "jev-latest"]), .object(["name": "jev-preview"])])]))])
        let models = try await JevClient.listModels(apiKey: "k", transport: stub)
        XCTAssertEqual(models.map { $0.id }, ["jev-latest", "jev-preview"])
        XCTAssertEqual(stub.requests.first?.url, JevClient.modelsEndpoint)
        XCTAssertEqual(stub.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testListModelsThrowsOnHTTPError() async {
        let stub = StubTransport([(401, .object(["detail": "Unauthorized"]))])
        do {
            _ = try await JevClient.listModels(apiKey: "bad", transport: stub)
            XCTFail("expected an error")
        } catch {}
    }

    func testValidateChoiceAcceptsArgmaxOverExactlyTheOfferedIds() throws {
        let c = try JevClient.validateChoice(answer("a", ["a": 0.7, "b": 0.3]), ids: ["a", "b"])
        XCTAssertEqual(c.choice, "a")
        XCTAssertEqual(c.confidence, 0.9)
    }

    func testValidateChoiceRejectsMalformedAnswers() {
        let ids: Set<String> = ["a", "b"]
        let bad: [(String, JSONValue?)] = [
            ("unknown id", answer("c", ["a": 0.5, "b": 0.5])),
            ("not the argmax", answer("b", ["a": 0.7, "b": 0.3])),
            ("probabilities do not sum to 1", answer("a", ["a": 0.6, "b": 0.2])),
            ("missing an offered id", answer("a", ["a": 1.0])),
            ("extra id", answer("a", ["a": 0.6, "b": 0.3, "c": 0.1])),
            ("confidence out of range", answer("a", ["a": 0.7, "b": 0.3], confidence: 1.5)),
            ("negative probability", answer("a", ["a": 1.2, "b": -0.2])),
            ("string probability", .object(["choice": "a", "confidence": .number(0.9),
                                            "probabilities": .object(["a": "0.9", "b": .number(0.1)])])),
            ("missing answer", nil),
        ]
        for (why, value) in bad {
            XCTAssertThrowsError(try JevClient.validateChoice(value, ids: ids), why)
        }
    }

    func testRequestBodyHasOneQuestionPerOperationAndIndexedElements() throws {
        let history = (1...12).map {
            AgentStepRecord(step: $0, action: "a\($0)", kind: "click", choice: "e5", operation: "CLICK",
                            text: nil, confidence: 0.9, latencyMs: 10, url: "u", pageChanged: true)
        }
        let transport = StubTransport([])
        let client = JevClient(apiKey: "test-key", model: "jev-1.14.0", transport: transport)
        let (body, _) = client.requestBody(snapshot: page(), goal: "Find Dune in Books", history: history)

        XCTAssertEqual(body["model"], "jev-1.14.0")
        XCTAssertEqual(body["state"]?["page"], .object(["url": "https://example.test/", "title": "Shop", "text": "Find a book"]))
        guard case .array(let elements)? = body["state"]?["elements"],
              case .array(let recent)? = body["state"]?["recent_actions"] else { return XCTFail("state shape") }
        // Search box (fill + click on one node), Category select, Go button.
        XCTAssertEqual(elements.count, 3)
        XCTAssertEqual(elements[0]["operations"], .array(["TYPE_TEXT", "CLICK"]))
        XCTAssertEqual(elements[1]["label"], "Category")
        XCTAssertEqual(elements[1]["value"], "All")
        guard case .array(let options)? = elements[1]["options"] else { return XCTFail("options") }
        XCTAssertEqual(options.map { $0["index"] }, ["2:1", "2:2"])
        XCTAssertEqual(recent.count, 10)
        XCTAssertEqual(recent.first?["action"], "a3")

        let questions = try XCTUnwrap(body["questions"]?.objectValue)
        XCTAssertEqual(Set(questions.keys), ["operation", "click_target", "type_text_target", "select_target"])
        XCTAssertEqual(keys(questions["operation"]?["criteria"]),
                       ["CLICK", "TYPE_TEXT", "SELECT", "SCROLL_DOWN", "WAIT", "DONE", "BLOCKED"])
        XCTAssertEqual(questions["operation"]?["type"], "choice")
        XCTAssertEqual(questions["operation"]?["instructions"]?["goal"], "Find Dune in Books")
        XCTAssertEqual(keys(questions["click_target"]?["criteria"]), ["1", "3"])
        XCTAssertEqual(questions["select_target"]?["criteria"]?["2:2"]?["element"], "[2:2] Category → Movies")
        guard case .array(let rules)? = questions["select_target"]?["instructions"]?["rules"] else { return XCTFail("rules") }
        XCTAssertEqual(rules.count, 2)
    }

    func testChooseMapsTheSelectedTargetHeadToTheObservedActionAndSendsBearerKey() async throws {
        let transport = StubTransport([(200, jevResponse([
            "operation": answer("SELECT", ["CLICK": 0.05, "TYPE_TEXT": 0.05, "SELECT": 0.8, "SCROLL_DOWN": 0.025,
                                           "WAIT": 0.025, "DONE": 0.025, "BLOCKED": 0.025]),
            "select_target": answer("2:1", ["2:1": 0.9, "2:2": 0.1]),
            // Unused heads are not validated: this one is malformed and must not matter.
            "click_target": .object(["choice": "nope"]),
        ]))])
        let client = JevClient(apiKey: "test-key", transport: transport)
        let d = try await client.choose(snapshot: page(), goal: "g", history: [])

        XCTAssertEqual(d.choice, "e3")
        XCTAssertEqual(d.operation, "SELECT")
        XCTAssertEqual(d.target, "2:1")
        XCTAssertEqual(d.probability, 0.9)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url, JevClient.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertFalse(String(data: request.httpBody ?? Data(), encoding: .utf8)!.contains("test-key"))
    }

    func testChooseRejectsAnInvalidSelectedTargetHead() async {
        let transport = StubTransport([(200, jevResponse([
            "operation": answer("CLICK", ["CLICK": 0.7, "TYPE_TEXT": 0.1, "SELECT": 0.1, "SCROLL_DOWN": 0.025,
                                          "WAIT": 0.025, "DONE": 0.025, "BLOCKED": 0.025]),
            "click_target": answer("9", ["1": 0.5, "3": 0.5]),
        ]))])
        let client = JevClient(apiKey: "k", transport: transport)
        do {
            _ = try await client.choose(snapshot: page(), goal: "g", history: [])
            XCTFail("expected invalid response")
        } catch {
            XCTAssertEqual(error as? AgentError, .invalidResponse("Invalid TypeSafe response; no action executed."))
        }
    }

    func testRetriesOverloadButNotServerErrors() async throws {
        let done = jevResponse(["operation": answer("DONE", ["CLICK": 0, "TYPE_TEXT": 0, "SELECT": 0, "SCROLL_DOWN": 0,
                                                              "WAIT": 0, "DONE": 1, "BLOCKED": 0])])
        let flaky = StubTransport([(429, .null), (529, .null), (200, done)])
        let d = try await JevClient(apiKey: "k", transport: flaky, retryDelayNanos: { _ in 0 })
            .choose(snapshot: page(), goal: "g", history: [])
        XCTAssertEqual(d.choice, "DONE")
        XCTAssertEqual(flaky.requests.count, 3)

        let broken = StubTransport([(500, .null), (200, done)])
        do {
            _ = try await JevClient(apiKey: "k", transport: broken, retryDelayNanos: { _ in 0 })
                .choose(snapshot: page(), goal: "g", history: [])
            XCTFail("expected HTTP error")
        } catch {
            XCTAssertEqual(broken.requests.count, 1)
            XCTAssertEqual(error.localizedDescription, "Jev returned HTTP 500; no action executed.")
        }
    }

    func testLLMPolicyAcceptsFencedJSONAndRejectsTargetsOutsideTheTable() async throws {
        let ok = LLMPolicy(complete: { _ in "```json\n{\"operation\": \"TYPE_TEXT\", \"target\": \"1\"}\n```" }, modelName: "m")
        let d = try await ok.decide(snapshot: page(), goal: "g", history: [])
        XCTAssertEqual(d.choice, "e1")
        XCTAssertNil(d.confidence)

        let bad = LLMPolicy(complete: { _ in "{\"operation\": \"CLICK\", \"target\": \"2\"}" }, modelName: "m")
        do {
            _ = try await bad.decide(snapshot: page(), goal: "g", history: [])
            XCTFail("target 2 offers no CLICK")
        } catch {
            XCTAssertTrue(error is AgentError)
        }
    }
}

// MARK: - Loop

private final class StubDriver: AgentPageDriving {
    var current: PageSnapshot
    /// Changes the fingerprint after each performed action.
    var actionsChangePage = true
    /// Pops one value per `isFresh(_, for: action)` check before input; then true.
    var actionFreshness: [Bool] = []
    private(set) var performed: [(String, String?)] = []

    init(_ page: PageSnapshot) { current = page }

    func snapshot() async throws -> PageSnapshot { current }
    func isFresh(_ snapshot: PageSnapshot, for action: PageAction?) async -> Bool {
        if action != nil, !actionFreshness.isEmpty {
            let fresh = actionFreshness.removeFirst()
            if !fresh { current = page("changed-\(performed.count)") }
            return fresh
        }
        return snapshot.marker == current.marker
    }
    func perform(_ action: PageAction, text: String?) async throws {
        performed.append((action.id, text))
        if actionsChangePage { current = page("after-\(performed.count)") }
    }
    func settle(after action: PageAction) async {}
}

private final class ScriptedPolicy: AgentPolicy {
    var choices: [String]
    private(set) var calls = 0
    init(_ choices: [String]) { self.choices = choices }
    func decide(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) async throws -> AgentDecision {
        calls += 1
        let choice = choices.count > 1 ? choices.removeFirst() : choices[0]
        return AgentDecision(choice: choice, operation: choice.uppercased(), target: nil, confidence: 0.9,
                             probability: 0.9, latencyMs: 1, model: "stub")
    }
}

private struct FixedText: FieldTextProviding {
    func text(for context: JSONValue) async throws -> String { "Dune" }
}

@MainActor
final class ComputerUseAgentLoopTests: XCTestCase {
    private func agent(_ driver: StubDriver, _ policy: ScriptedPolicy, maxSteps: Int = 60) -> ComputerUseAgent {
        ComputerUseAgent(driver: driver, policy: policy, textProvider: FixedText(), maxSteps: maxSteps)
    }

    func testRunsActionsThenStopsOnDone() async {
        let driver = StubDriver(page())
        let outcome = await agent(driver, ScriptedPolicy(["e1", "e3", "e5", "DONE"])).execute(goal: "g")
        XCTAssertEqual(outcome, .done)
        XCTAssertEqual(driver.performed.map(\.0), ["e1", "e3", "e5"])
        XCTAssertEqual(driver.performed.first?.1, "Dune")
    }

    func testBlocksAfterThreeActionsThatChangeNothing() async {
        let driver = StubDriver(page())
        driver.actionsChangePage = false
        let outcome = await agent(driver, ScriptedPolicy(["e5"])).execute(goal: "g")
        XCTAssertEqual(outcome, .blocked("The last 3 actions changed nothing on the page."))
        XCTAssertEqual(driver.performed.count, 3)
    }

    func testUnchangedWaitsDoNotCountAsNoProgressButHitTheStepBudget() async {
        let driver = StubDriver(page())
        driver.actionsChangePage = false
        let outcome = await agent(driver, ScriptedPolicy(["wait"]), maxSteps: 5).execute(goal: "g")
        XCTAssertEqual(outcome, .blocked("Stopped at the 5-action budget."))
        XCTAssertEqual(driver.performed.count, 5)
    }

    func testStaleDecisionIsDroppedAndTheModelAsksAgain() async {
        let driver = StubDriver(page())
        driver.actionFreshness = [false]
        let policy = ScriptedPolicy(["e5", "e5", "DONE"])
        var events: [AgentEvent] = []
        let outcome = await agent(driver, policy).execute(goal: "g") { events.append($0) }
        XCTAssertEqual(outcome, .done)
        // The first e5 was never executed; the second was.
        XCTAssertEqual(driver.performed.map(\.0), ["e5"])
        XCTAssertEqual(policy.calls, 3)
        XCTAssertTrue(events.contains { if case .stale = $0 { return true }; return false })
    }

    func testBlockedFromPolicyAndPolicyErrorsEndTheRun() async {
        let blocked = await agent(StubDriver(page()), ScriptedPolicy(["BLOCKED"])).execute(goal: "g")
        XCTAssertEqual(blocked, .blocked("No supported operation can progress."))

        let unknown = await agent(StubDriver(page()), ScriptedPolicy(["e99"])).execute(goal: "g")
        XCTAssertEqual(unknown, .failed("Decision refers to no observed action; nothing executed."))
    }

    func testCancellationStopsWithoutFurtherActions() async {
        let driver = StubDriver(page())
        let task = Task { await agent(driver, ScriptedPolicy(["wait"])).execute(goal: "g") }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(driver.performed.isEmpty)
    }

    func testAgentCommandParsing() {
        XCTAssertEqual(CommandSurfaceView.agentGoal(in: "/agent  find Dune "), "find Dune")
        XCTAssertEqual(CommandSurfaceView.agentGoal(in: "/AGENT go"), "go")
        XCTAssertNil(CommandSurfaceView.agentGoal(in: "/agent "))
        XCTAssertNil(CommandSurfaceView.agentGoal(in: "what is an /agent"))
    }
}

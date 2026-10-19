import WebKit
import XCTest
@testable import Axolotl

/// Tabs without pages: enough for protocol, validation and approval tests.
@MainActor
final class StubBrowserHost: AgentBrowserHost {
    var tabs: [AgentTabInfo]
    var webViews: [UUID: WKWebView] = [:]
    private(set) var navigations: [URL] = []

    init(tabs: [AgentTabInfo] = [AgentTabInfo(id: UUID(), title: "Start", url: "https://example.test/", active: true)]) {
        self.tabs = tabs
    }

    var activeTabId: UUID? { tabs.first(where: \.active)?.id }
    func webView(for tab: UUID) -> WKWebView? { webViews[tab] }
    func openTab(url: URL) -> UUID {
        let id = UUID()
        tabs = tabs.map { AgentTabInfo(id: $0.id, title: $0.title, url: $0.url, active: false) }
        tabs.append(AgentTabInfo(id: id, title: "", url: url.absoluteString, active: true))
        return id
    }
    func selectTab(_ id: UUID) {
        tabs = tabs.map { AgentTabInfo(id: $0.id, title: $0.title, url: $0.url, active: $0.id == id) }
    }
    func navigate(_ tab: UUID, to url: URL) {
        navigations.append(url)
        webViews[tab]?.load(URLRequest(url: url))
    }
}

@MainActor
final class StubApprover: MCPApproving {
    var answer: MCPApproval = .deny
    private(set) var asked: [String] = []
    func approve(client: String, tool: String, detail: String) async -> MCPApproval {
        asked.append(tool)
        return answer
    }
}

@MainActor
final class MCPBridgeTests: XCTestCase {
    private let token = "test-token-0123456789abcdef"
    private let port: UInt16 = 47821
    private var host: StubBrowserHost!
    private var approver: StubApprover!
    private var endpoint: MCPEndpoint!
    private var trusted = false

    override func setUp() async throws {
        host = StubBrowserHost()
        approver = StubApprover()
        trusted = false
        let host = self.host!
        endpoint = MCPEndpoint(toolbox: AxolotlToolbox { host }, port: { [port] in port }, token: { [token] in token },
                               isTrusted: { [unowned self] in self.trusted }, approver: approver)
    }

    private func request(_ method: String = "POST", path: String = "/mcp", body: String = "",
                         headers: [String: String?] = [:], loopback: Bool = true) -> MCPHTTPRequest {
        var h: [String: String] = ["host": "127.0.0.1:\(port)", "authorization": "Bearer \(token)",
                                   "content-type": "application/json"]
        for (k, v) in headers { h[k] = v }
        return MCPHTTPRequest(method: method, path: path, headers: h, body: Data(body.utf8), remoteIsLoopback: loopback)
    }

    private func json(_ response: MCPHTTPResponse) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: response.body)
    }

    /// Initializes a session and returns its id.
    private func initialize() async throws -> String {
        let r = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test-agent","version":"1"}}}"#))
        XCTAssertEqual(r.status, 200)
        let session = try XCTUnwrap(r.headers["Mcp-Session-Id"])
        let init_ = try json(r)
        XCTAssertEqual(init_["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertNotNil(init_["result"]?["capabilities"]?["tools"])
        return session
    }

    private func call(_ session: String, _ tool: String, _ arguments: String = "{}", id: Int = 7) async throws -> JSONValue {
        let r = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(arguments)}}"#,
                                              headers: ["mcp-session-id": session]))
        XCTAssertEqual(r.status, 200)
        return try json(r)
    }

    private func isError(_ response: JSONValue) -> Bool? {
        if case .bool(let b)? = response["result"]?["isError"] { return b }
        return nil
    }

    private func text(_ response: JSONValue) -> String {
        if case .array(let items)? = response["result"]?["content"] { return items.first?["text"]?.stringValue ?? "" }
        return ""
    }

    // MARK: Token, Host, Origin

    func testTokenComparison() {
        XCTAssertTrue(MCPGate.tokensMatch(token, token))
        XCTAssertFalse(MCPGate.tokensMatch("test-token-0123456789abcdeX", token), "same length, one byte off")
        XCTAssertFalse(MCPGate.tokensMatch("test", token), "prefix")
        XCTAssertFalse(MCPGate.tokensMatch(token + "x", token), "longer")
        XCTAssertFalse(MCPGate.tokensMatch("", ""), "no token configured never matches")
    }

    func testGateRejectsUnauthenticatedForeignAndRebindingRequests() async {
        let cases: [(String, MCPHTTPRequest, Int)] = [
            ("missing token", request(headers: ["authorization": nil]), 401),
            ("wrong token", request(headers: ["authorization": "Bearer nope"]), 401),
            ("wrong scheme", request(headers: ["authorization": "Basic \(token)"]), 401),
            ("non-loopback peer", request(loopback: false), 403),
            ("missing Host", request(headers: ["host": nil]), 403),
            ("rebinding Host", request(headers: ["host": "evil.example:\(port)"]), 403),
            ("other port Host", request(headers: ["host": "127.0.0.1:1"]), 403),
            ("foreign Origin", request(headers: ["origin": "https://evil.example"]), 403),
            ("null Origin", request(headers: ["origin": "null"]), 403),
            ("other path", request(path: "/admin"), 404),
        ]
        for (name, req, status) in cases {
            let r = await endpoint.handle(req)
            XCTAssertEqual(r.status, status, name)
        }
        // Loopback Origin and localhost Host pass the gate (then fail JSON parsing on an empty body).
        let ok = await endpoint.handle(request(headers: ["origin": "http://localhost:5173", "host": "localhost:\(port)"]))
        XCTAssertEqual(ok.status, 400)
    }

    // MARK: JSON-RPC

    func testInitializeListAndProtocolErrors() async throws {
        let session = try await initialize()

        let list = try json(await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#,
                                                          headers: ["mcp-session-id": session])))
        XCTAssertEqual(list["id"], "a")
        guard case .array(let tools)? = list["result"]?["tools"] else { return XCTFail("no tools") }
        let names = Set(tools.compactMap { $0["name"]?.stringValue })
        XCTAssertEqual(names, ["tabs_list", "tab_open", "tab_select", "navigate", "snapshot", "click", "type",
                               "select", "scroll", "read", "run_task", "grab_api_key",
                               "usage_summary", "top_sites", "history_search", "feature_usage", "settings_list", "settings_set",
                               "tabs_group", "tabs_reorder", "tab_pin", "favorites_add", "bookmarks_add", "undo_change"])
        let navigate = tools.first { $0["name"] == "navigate" }
        XCTAssertEqual(navigate?["inputSchema"]?["required"], .array(["url"]))

        let unknown = try json(await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":2,"method":"resources/list"}"#,
                                                             headers: ["mcp-session-id": session])))
        XCTAssertEqual(unknown["error"]?["code"], .number(-32601))

        let malformed = await endpoint.handle(request(body: "{not json", headers: ["mcp-session-id": session]))
        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(try json(malformed)["error"]?["code"], .number(-32700))

        let batch = await endpoint.handle(request(body: #"[{"jsonrpc":"2.0","id":3,"method":"ping"}]"#, headers: ["mcp-session-id": session]))
        XCTAssertEqual(batch.status, 400)

        let note = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                                                 headers: ["mcp-session-id": session]))
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)

        let noSession = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#))
        XCTAssertEqual(noSession.status, 400)
        let staleSession = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":5,"method":"tools/list"}"#,
                                                         headers: ["mcp-session-id": "gone"]))
        XCTAssertEqual(staleSession.status, 404)
        let badVersion = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#,
                                                       headers: ["mcp-session-id": session, "mcp-protocol-version": "1999-01-01"]))
        XCTAssertEqual(badVersion.status, 400)
        let sse = await endpoint.handle(request("GET", headers: ["mcp-session-id": session]))
        XCTAssertEqual(sse.status, 405)

        let unknownTool = try await call(session, "format_disk")
        XCTAssertEqual(unknownTool["error"]?["code"], .number(-32602))
    }

    // MARK: Validation and approval

    func testToolArgumentValidation() throws {
        let cases: [(AxolotlTool, [String: JSONValue], String?)] = [
            (AxolotlTools.navigate, [:], "'url' is required"),
            (AxolotlTools.navigate, ["url": .number(3)], "must be a string"),
            (AxolotlTools.navigate, ["url": "https://a.test", "extra": "x"], "unknown argument 'extra'"),
            (AxolotlTools.scroll, ["direction": "sideways"], "must be one of up, down"),
            (AxolotlTools.runTask, ["goal": "x", "max_steps": .number(0)], "must be 1–60"),
            (AxolotlTools.runTask, ["goal": "x", "max_steps": .number(2.5)], "must be an integer"),
            (AxolotlTools.click, ["id": "  "], "must not be empty"),
            (AxolotlTools.type, ["id": "e1", "text": ""], nil),
            (AxolotlTools.navigate, ["url": "https://a.test", "tab_id": "t"], nil),
        ]
        for (tool, args, expected) in cases {
            do {
                try tool.validate(args)
                XCTAssertNil(expected, "\(tool.name) \(args) should fail")
            } catch {
                let message = error.localizedDescription
                XCTAssertTrue(expected.map(message.contains) ?? false, "\(tool.name): \(message)")
            }
        }
    }

    func testMutatingToolsAskOncePerSessionAndReadOnlyToolsDoNot() async throws {
        let session = try await initialize()

        // Read-only: no prompt.
        let tabs = try await call(session, "tabs_list")
        XCTAssertEqual(isError(tabs), false)
        XCTAssertTrue(text(tabs).contains("Start"))
        XCTAssertEqual(approver.asked, [])

        // Invalid arguments are rejected before the user is asked; unsafe URLs never load.
        let invalid = try await call(session, "navigate", #"{}"#)
        XCTAssertEqual(isError(invalid), true)
        approver.answer = .once
        let fileURL = try await call(session, "navigate", #"{"url":"file:///etc/passwd"}"#)
        XCTAssertEqual(isError(fileURL), true)
        XCTAssertTrue(text(fileURL).contains("Only http and https"))
        XCTAssertEqual(host.navigations, [])

        // Deny: nothing runs.
        approver.answer = .deny
        let denied = try await call(session, "tab_open", #"{"url":"https://denied.test"}"#)
        XCTAssertEqual(isError(denied), true)
        XCTAssertEqual(host.tabs.count, 1)

        // Allow for this session: later mutating calls in this session don't ask again.
        approver.answer = .session
        _ = try await call(session, "tab_open", #"{"url":"https://one.test"}"#)
        _ = try await call(session, "tab_open", #"{"url":"https://two.test"}"#)
        XCTAssertEqual(host.tabs.count, 3)
        XCTAssertEqual(approver.asked, ["navigate", "tab_open", "tab_open"])

        // A new client session asks again; "trusted" skips the prompt entirely.
        let other = try await initialize()
        approver.answer = .deny
        _ = try await call(other, "tab_open", #"{"url":"https://three.test"}"#)
        XCTAssertEqual(approver.asked.count, 4)
        trusted = true
        _ = try await call(other, "tab_open", #"{"url":"https://four.test"}"#)
        XCTAssertEqual(approver.asked.count, 4)
        XCTAssertEqual(host.tabs.count, 4)
    }

    // MARK: Redaction

    func testSnapshotOutputMasksSecrets() {
        let key = "sk-ant-api03-" + String(repeating: "A1b2", count: 8)
        let snap = PageSnapshot(
            url: "https://console.test/keys", title: "Keys", text: "Your key: \(key) (keep it safe)",
            actions: [PageAction(id: "e1", kind: "fill", label: "Key \(key)", node: 1, role: "textbox", value: key,
                                 currentValue: nil, checked: nil, selected: nil, expanded: nil, delta: nil)],
            scroll: .init(y: 0, height: 100), omittedActions: 0, marker: "m", nodeKeys: [:], fingerprint: "f")
        let out = AxolotlToolbox.describe(snap)
        XCTAssertFalse(out.contains("A1b2A1b2"), out)
        XCTAssertTrue(out.contains("Your key: \(AgentRedaction.mask) (keep it safe)"), out)
        XCTAssertEqual(AgentRedaction.redact("token ghp_" + String(repeating: "x", count: 36) + " end"),
                       "token \(AgentRedaction.mask) end")
        XCTAssertEqual(AgentRedaction.redact("sk-short and plain text"), "sk-short and plain text")
    }
}

// MARK: - Dev mode session tokens

extension MCPBridgeTests {
    func testDevSessionTokenIsAcceptedAndSkipsAxolotlPrompt() async throws {
        let devToken = "dev-session-token-0123456789"
        var accepted: Set<String> = [devToken]
        endpoint.trustedTokens = { accepted }
        approver.answer = .deny

        let r = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"1"}}}"#,
                                              headers: ["authorization": "Bearer \(devToken)"]))
        XCTAssertEqual(r.status, 200)
        let session = try XCTUnwrap(r.headers["Mcp-Session-Id"])
        let opened = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tab_open","arguments":{"url":"https://dev.test"}}}"#,
                                                   headers: ["mcp-session-id": session, "authorization": "Bearer \(devToken)"]))
        XCTAssertEqual(isError(try json(opened)), false)
        XCTAssertEqual(approver.asked, [], "the CLI asks the user itself; Axolotl must not prompt again")

        // The main token still prompts, and a revoked dev token is refused outright.
        let main = try await initialize()
        _ = try await call(main, "tab_open", #"{"url":"https://main.test"}"#)
        XCTAssertEqual(approver.asked, ["tab_open"])
        accepted = []
        let revoked = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#,
                                                    headers: ["mcp-session-id": session, "authorization": "Bearer \(devToken)"]))
        XCTAssertEqual(revoked.status, 401)
    }
}

extension MCPBridgeTests {
    func testFullAutoDevTokenIsAcceptedButStillPrompts() async throws {
        let devToken = "dev-full-auto-token-0123456789"
        endpoint.promptingTokens = { [devToken] }
        approver.answer = .deny
        let r = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex","version":"1"}}}"#,
                                              headers: ["authorization": "Bearer \(devToken)"]))
        XCTAssertEqual(r.status, 200)
        let session = try XCTUnwrap(r.headers["Mcp-Session-Id"])
        let opened = await endpoint.handle(request(body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"tab_open","arguments":{"url":"https://dev.test"}}}"#,
                                                   headers: ["mcp-session-id": session, "authorization": "Bearer \(devToken)"]))
        XCTAssertEqual(isError(try json(opened)), true, "a Full auto CLI asks nobody, so Axolotl must")
        XCTAssertEqual(approver.asked, ["tab_open"])
        XCTAssertEqual(host.tabs.count, 1)
    }
}

extension MCPBridgeTests {
    func testSessionApprovalIsScopedToOneToolAndPreviewNamesTheTarget() async throws {
        let session = try await initialize()
        approver.answer = .session
        _ = try await call(session, "tab_open", #"{"url":"https://one.test"}"#)
        _ = try await call(session, "tab_open", #"{"url":"https://two.test"}"#)
        approver.answer = .deny
        _ = try await call(session, "navigate", #"{"url":"https://three.test"}"#)
        XCTAssertEqual(approver.asked, ["tab_open", "navigate"], "allowing tab_open must not cover navigate")

        XCTAssertEqual(AxolotlTools.elementPreview("Click", id: "e3", label: "Delete account", pageHost: "bank.test"),
                       "Click “Delete account” (e3) on bank.test")
        XCTAssertEqual(AxolotlTools.elementPreview("Click", id: "e9", label: nil, pageHost: nil), "Click e9 on the current page")
    }
}

// MARK: - HTTP parsing limits

extension MCPBridgeTests {
    private func status(_ result: MCPServer.ParseResult) -> Int? {
        switch result {
        case .invalid(let status, _): return status
        case .complete: return 200
        case .incomplete: return nil
        }
    }

    func testParserBoundsChunkedHeadersAndBodies() {
        let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        // A chunked body that never sends its final 0-chunk is refused once past the cap, not buffered forever.
        var chunked = Data((head + "Transfer-Encoding: chunked\r\n\r\n").utf8)
        XCTAssertNil(status(MCPServer.parse(chunked, loopback: true)))
        chunked.append(Data("1;\(String(repeating: "x", count: MCPServer.maxHeaderBytes + MCPServer.maxBodyBytes + 2048))".utf8))
        XCTAssertEqual(status(MCPServer.parse(chunked, loopback: true)), 413)

        XCTAssertEqual(status(MCPServer.parse(Data((head + "X: " + String(repeating: "a", count: MCPServer.maxHeaderBytes + 1)).utf8), loopback: true)), 431)
        XCTAssertEqual(status(MCPServer.parse(Data((head + "Content-Length: \(MCPServer.maxBodyBytes + 1)\r\n\r\n").utf8), loopback: true)), 413)
        XCTAssertEqual(status(MCPServer.parse(Data((head + "Host: evil.test\r\n\r\n").utf8), loopback: true)), 400)
        XCTAssertEqual(status(MCPServer.parse(Data((head + "Content-Length: 2\r\n\r\nok").utf8), loopback: true)), 200)
    }
}

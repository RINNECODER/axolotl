import AppKit
import WebKit
import XCTest
@testable import Axolotl

/// The real Jev loop grabs keys from the fake dashboards in `KeyGrabberTests`.
/// Needs TYPESAFE_API_KEY (xcodebuild: TEST_RUNNER_TYPESAFE_API_KEY); skipped otherwise.
/// A spy on every outbound channel (Jev request and response bodies, policy inputs, MCP
/// responses, agent events, panel lines) must never contain the key or any 12-character piece of it.
@MainActor
final class KeyGrabberLiveTests: XCTestCase {
    var vault: SecretVault!
    var board: NSPasteboard!
    var host: FixtureHost!
    var spy: LeakSpy!
    private var savedShared: KeyGrabber!

    override func setUp() async throws {
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("TYPESAFE_API_KEY not set")
        }
        board = NSPasteboard(name: NSPasteboard.Name("axolotl.grab.live.\(UUID().uuidString)"))
        vault = SecretVault(service: "Axolotl API Keys Test \(UUID().uuidString)", pasteboard: board)
        host = FixtureHost(pages: ["keys.axolotl.test": KeyFixtures.openAIStyle, "tokens.axolotl.test": KeyFixtures.tokenStyle])
        spy = LeakSpy()
        savedShared = KeyGrabber.shared
        let spy = self.spy!
        KeyGrabber.shared = KeyGrabber(vault: vault, makePolicy: {
            SpyPolicy(inner: JevPolicy(client: JevClient(apiKey: key, transport: SpyTransport(spy: spy))), spy: spy)
        })
    }

    override func tearDown() async throws {
        guard vault != nil else { return }
        KeyGrabber.shared = savedShared
        for item in vault.items() { vault.delete(account: item.account) }
        board.releaseGlobally()
        host.closeAll()
    }

    /// sk-proj- dashboard, driven through the MCP endpoint like an outside agent would.
    func testJevGrabsPrefixedKeyOverMCP() async throws {
        let host = self.host!
        let endpoint = MCPEndpoint(toolbox: AxolotlToolbox { host }, port: { 47821 }, token: { "live-token-0123456789abcdef" },
                                   isTrusted: { true }, approver: StubApprover())
        func post(_ body: String, session: String? = nil) async -> MCPHTTPResponse {
            var headers = ["host": "127.0.0.1:47821", "authorization": "Bearer live-token-0123456789abcdef",
                           "content-type": "application/json"]
            if let session { headers["mcp-session-id"] = session }
            return await endpoint.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8),
                                                        remoteIsLoopback: true))
        }
        let initialize = await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"live","version":"1"}}}"#)
        let session = try XCTUnwrap(initialize.headers["Mcp-Session-Id"])
        let started = Date()
        let response = await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"grab_api_key","arguments":{"service":"Fixture","url":"https://keys.axolotl.test/","key_name":"axolotl-live"}}}"#,
                                  session: session)
        let body = String(decoding: response.body, as: UTF8.self)
        spy.record("mcp-response", body)
        let result = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: response.body)["result"])
        guard case .array(let content)? = result["content"], let text = content.first?["text"]?.stringValue else {
            return XCTFail("No tool result: \(body.prefix(300))")
        }
        let grab = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let jevCalls = spy.records.filter { $0.channel == "jev-request" }.count
        print("GRAB_LIVE mcp status=\(grab["status"]?.stringValue ?? "?") jev_calls=\(jevCalls) wall_ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        XCTAssertEqual(grab["status"]?.stringValue, "saved", text)
        XCTAssertGreaterThan(jevCalls, 0)

        let tab = try XCTUnwrap(host.activeTabId)
        let shown = try await pageText(try XCTUnwrap(host.webView(for: tab)), "document.getElementById('key').textContent")
        XCTAssertTrue(shown.hasPrefix("sk-proj-") && shown.count == 56)
        XCTAssertEqual(vault.value(account: "fixture/axolotl-live"), shown)
        XCTAssertEqual(board.string(forType: .string), shown)
        let leaks = spy.leaks(of: shown)
        print("GRAB_LIVE mcp leak_channels=\(leaks) records=\(spy.records.count)")
        XCTAssertEqual(leaks, [])
    }

    /// Unprefixed token in a readonly field, through `KeyGrabber` directly so every event is recorded.
    func testJevGrabsUnprefixedToken() async throws {
        let tab = host.openTab(url: URL(string: "https://tokens.axolotl.test/")!)
        let webView = try XCTUnwrap(host.webView(for: tab))
        let service = KeyService(id: "tokens", name: "Tokens", url: URL(string: "https://tokens.axolotl.test/")!)
        let result = await KeyGrabber.shared.grab(service: service, keyName: "ci-live", webView: webView, navigate: { _ in },
                                                  onEvent: { [spy] in
                                                      spy!.record("event", "\($0)")
                                                      spy!.record("panel", $0.panelLine ?? "")
                                                  })
        spy.record("result", result.json + result.message)
        let jevCalls = spy.records.filter { $0.channel == "jev-request" }.count
        print("GRAB_LIVE token status=\(result.status.rawValue) jev_calls=\(jevCalls)")
        XCTAssertEqual(result.status, .saved, result.message)
        let token = try await pageText(webView, "document.getElementById('tok').value")
        XCTAssertEqual(token.count, 40)
        XCTAssertEqual(vault.value(account: "tokens/ci-live"), token)
        XCTAssertEqual(board.string(forType: .string), token)
        let leaks = spy.leaks(of: token)
        print("GRAB_LIVE token leak_channels=\(leaks) records=\(spy.records.count)")
        XCTAssertEqual(leaks, [])
    }

    func pageText(_ webView: WKWebView, _ expression: String) async throws -> String {
        try await webView.callAsyncJavaScript("return " + expression, arguments: [:], in: nil, contentWorld: .defaultClient) as? String ?? ""
    }
}

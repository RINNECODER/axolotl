import AppKit
import WebKit
import XCTest
@testable import Axolotl

/// The MCP server on a real loopback port, driven over HTTP against the Phase 1 fixture page
/// in an offscreen WKWebView. No API keys needed.
@MainActor
final class MCPLiveTests: XCTestCase {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var host: StubBrowserHost!
    private var server: MCPServer!
    private var port: UInt16 = 0
    private let token = MCPLiveTests.makeToken()
    private var session: String?

    static func makeToken() -> String { AxolotlMCPBridge.makeToken() }

    override func setUp() async throws {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        webView.loadHTMLString(ComputerUseLiveTests.fixture, baseURL: URL(string: "https://fixture.axolotl.test/"))
        let deadline = Date().addingTimeInterval(10)
        repeat { try await Task.sleep(nanoseconds: 50_000_000) } while (webView.isLoading || webView.url == nil) && Date() < deadline

        let tab = UUID()
        host = StubBrowserHost(tabs: [AgentTabInfo(id: tab, title: "Axolotl Library", url: "https://fixture.axolotl.test/", active: true)])
        host.webViews[tab] = webView
        let host = self.host!
        let endpoint = MCPEndpoint(toolbox: AxolotlToolbox { host }, port: { [unowned self] in self.port }, token: { [token] in token },
                                   isTrusted: { true }, approver: nil)
        server = MCPServer(endpoint: endpoint)
        port = try await server.start(port: 0)
    }

    override func tearDown() async throws {
        server?.stop()
        window?.orderOut(nil)
    }

    private func post(_ body: String) async throws -> (Int, JSONValue?) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let session { req.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { session = id }
        return (http.statusCode, data.isEmpty ? nil : try JSONDecoder().decode(JSONValue.self, from: data))
    }

    private func tool(_ name: String, _ arguments: String = "{}") async throws -> String {
        let (status, body) = try await post(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#)
        XCTAssertEqual(status, 200)
        guard case .array(let content)? = body?["result"]?["content"], let text = content.first?["text"]?.stringValue else {
            XCTFail("\(name): no content in \(String(describing: body))")
            return ""
        }
        XCTAssertEqual(body?["result"]?["isError"], .bool(false), "\(name): \(text)")
        return text
    }

    /// The id of the first action whose row contains all of `parts`.
    private func actionId(in snapshot: String, _ parts: String...) throws -> String {
        let row = snapshot.split(separator: "\n").first { line in parts.allSatisfy { line.contains($0) } }
        return try XCTUnwrap(row?.split(separator: "\t").first.map(String.init), "no row with \(parts) in\n\(snapshot)")
    }

    func testOutsideAgentDrivesFixtureOverHTTP() async throws {
        let (status, initBody) = try await post(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"live-test","version":"1"}}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertNotNil(session)
        XCTAssertEqual(initBody?["result"]?["serverInfo"]?["name"], "axolotl")
        let (noteStatus, noteBody) = try await post(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(noteStatus, 202)
        XCTAssertNil(noteBody)
        let (_, list) = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let tools)? = list?["result"]?["tools"] else { return XCTFail("no tools") }
        XCTAssertEqual(tools.count, AxolotlTools.all.count)

        var snap = try await tool("snapshot")
        XCTAssertTrue(snap.contains("Title: Axolotl Library"), snap)
        let search = try actionId(in: snap, "\tfill\t", "Search")

        // A secret typed into the page never comes back to the agent.
        let secret = "sk-ant-api03-" + String(repeating: "Zz9", count: 10)
        snap = try await tool("type", #"{"id":"\#(search)","text":"\#(secret)"}"#)
        XCTAssertFalse(snap.contains("Zz9Zz9"), snap)
        XCTAssertTrue(snap.contains(AgentRedaction.mask), snap)

        snap = try await tool("type", #"{"id":"\#(search)","text":"Dune"}"#)
        let category = try actionId(in: snap, "\tselect\t", "Books")
        snap = try await tool("select", #"{"id":"\#(category)","option":"Books"}"#)
        XCTAssertTrue(snap.contains("current=\"Books\""), snap)
        let submit = try actionId(in: snap, "\tclick\t", "Search", "[button]")
        _ = try await tool("click", #"{"id":"\#(submit)"}"#)

        let text = try await tool("read")
        XCTAssertTrue(text.contains("Results for “dune” in Books"), text)
        XCTAssertTrue(text.contains("Dune (Books)"), text)
        XCTAssertFalse(text.contains("Dune (Movies)"), text)
        let page = try await webView.evaluateJavaScript("document.getElementById('cat').value") as? String
        XCTAssertEqual(page, "books")

        // A stale id is refused instead of acting on the wrong element.
        let (_, stale) = try await post(#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"click","arguments":{"id":"e999"}}}"#)
        XCTAssertEqual(stale?["result"]?["isError"], .bool(true))
    }

    /// One real outside agent: Claude Code calls `snapshot` through this server.
    /// Set TEST_RUNNER_AXOLOTL_MCP_SMOKE_CLAUDE to the claude binary to run it; skipped otherwise.
    func testClaudeCodeReadsFixtureTitle() async throws {
        guard let claude = ProcessInfo.processInfo.environment["AXOLOTL_MCP_SMOKE_CLAUDE"], !claude.isEmpty else {
            throw XCTSkip("AXOLOTL_MCP_SMOKE_CLAUDE not set")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-mcp-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("mcp.json")
        let json: JSONValue = .object(["mcpServers": .object(["axolotl": .object([
            "type": "http", "url": .string("http://127.0.0.1:\(port)/mcp"),
            "headers": .object(["Authorization": .string("Bearer \(token)")]),
        ])])])
        FileManager.default.createFile(atPath: config.path, contents: Data(json.jsonString().utf8),
                                       attributes: [.posixPermissions: 0o600])

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "Call the axolotl snapshot tool once and reply with only the page title it reports.",
                             "--model", "haiku", "--strict-mcp-config", "--mcp-config", config.path,
                             "--allowedTools", "mcp__axolotl__snapshot", "--max-turns", "3"]
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        // Wait off the main thread so the server (on the main queue) keeps answering.
        let output: String = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { _ in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        print("AXOLOTL_MCP_SMOKE exit=\(process.terminationStatus) reply=\(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.contains("Axolotl Library"), output)
    }
}

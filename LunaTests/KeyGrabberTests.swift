import AppKit
import WebKit
import XCTest
@testable import Luna

// MARK: - Fixtures

/// Login-free fake key dashboards. Each key is random per load, so tests read it back from the
/// Keychain (never from a model-facing channel) and compare it with what the page shows.
enum KeyFixtures {
    static let random = """
    const rand=(n,abc)=>[...crypto.getRandomValues(new Uint8Array(n))].map(x=>abc[x%abc.length]).join('');
    const $=id=>document.getElementById(id);
    """

    /// "Create new secret key" → modal with a name field → `sk-proj-` + 48 random chars and a Copy button.
    static let openAIStyle = """
    <!doctype html><html><head><meta charset="utf-8"><title>Fixture API keys</title>
    <style>body{font:16px -apple-system,sans-serif;margin:24px} [hidden]{display:none!important}
    #modal{border:1px solid #888;padding:16px;margin-top:12px}</style></head><body>
    <h1>API keys</h1><p>Secret keys let your apps call the Fixture API. Build 3f9c2b7e1d4a6c8b9e0f2a1d3c5b7e9f0a2c4e6b.</p>
    <table><tr><td>old-key</td><td>sk-...a1Zq</td></tr></table>
    <button id="open">Create new secret key</button>
    <div id="modal" role="dialog" aria-label="Create new secret key" hidden>
      <div id="step1"><label>Name <input id="keyname" type="text"></label>
        <button id="create">Create secret key</button> <button id="cancel">Cancel</button></div>
      <div id="step2" hidden><h2>Save your key</h2><p>Your new secret key:</p><code id="key"></code>
        <button id="copy">Copy</button> <button id="done">Done</button></div>
    </div>
    <script>\(random)
    $('open').onclick=()=>{$('modal').hidden=false;$('open').hidden=true};
    $('cancel').onclick=()=>{$('modal').hidden=true;$('open').hidden=false};
    $('create').onclick=()=>{ if(!$('keyname').value.trim()) return;
      $('key').textContent='sk-proj-'+rand(48,'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789');
      $('step1').hidden=true;$('step2').hidden=false};
    $('copy').onclick=()=>navigator.clipboard?.writeText($('key').textContent).catch(()=>{});
    </script></body></html>
    """

    /// No known prefix: a readonly "Access token" field with 40 random lowercase letters and digits,
    /// next to an unlabeled request id (a UUID) that must not be taken for the token.
    static let tokenStyle = """
    <!doctype html><html><head><meta charset="utf-8"><title>Fixture tokens</title>
    <style>body{font:16px -apple-system,sans-serif;margin:24px} [hidden]{display:none!important}</style></head><body>
    <h1>Access tokens</h1>
    <label>Token name <input id="tname" type="text"></label>
    <button id="gen">Generate token</button>
    <section id="result" hidden>
      <p>Request id: <span id="rid"></span></p>
      <label>Access token <input id="tok" readonly size="48"></label>
      <p>Copy it now. You won't see it again.</p>
    </section>
    <script>\(random)
    $('gen').onclick=()=>{ if(!$('tname').value.trim()) return;
      $('rid').textContent=crypto.randomUUID();
      $('tok').value=rand(40,'abcdefghijklmnopqrstuvwxyz0123456789');
      $('result').hidden=false;$('gen').disabled=true};
    </script></body></html>
    """

    static let loginWall = """
    <!doctype html><html><head><meta charset="utf-8"><title>Sign in</title></head><body>
    <h1>Sign in to Fixture</h1>
    <form><label>Email <input id="email" type="email" autocomplete="username"></label>
    <label>Password <input id="pw" type="password"></label><button>Sign in</button></form>
    </body></html>
    """
}

/// Tabs backed by offscreen web views; each host name serves fixture HTML.
@MainActor
final class FixtureHost: AgentBrowserHost {
    var pages: [String: String]
    private(set) var tabs: [AgentTabInfo] = []
    private var views: [UUID: WKWebView] = [:]
    private var windows: [NSWindow] = []

    init(pages: [String: String]) { self.pages = pages }

    var activeTabId: UUID? { tabs.first(where: \.active)?.id }
    func webView(for tab: UUID) -> WKWebView? { views[tab] }

    func openTab(url: URL) -> UUID {
        let id = UUID()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1120, height: 780), configuration: config)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.alphaValue = 0.01
        window.orderFrontRegardless()
        windows.append(window)
        views[id] = webView
        tabs = tabs.map { AgentTabInfo(id: $0.id, title: $0.title, url: $0.url, active: false) }
        tabs.append(AgentTabInfo(id: id, title: "", url: url.absoluteString, active: true))
        navigate(id, to: url)
        return id
    }

    func selectTab(_ id: UUID) {
        tabs = tabs.map { AgentTabInfo(id: $0.id, title: $0.title, url: $0.url, active: $0.id == id) }
    }

    func navigate(_ tab: UUID, to url: URL) {
        views[tab]?.loadHTMLString(pages[url.host ?? ""] ?? "<p>Not found</p>", baseURL: url)
    }

    func closeAll() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        views = [:]
    }
}

/// Records everything that leaves Luna for a model or a caller, and finds a secret in it.
final class LeakSpy {
    private(set) var records: [(channel: String, text: String)] = []

    func record(_ channel: String, _ text: String) { records.append((channel, text)) }

    /// Channels containing the value or any 12-character piece of it.
    func leaks(of secret: String) -> [String] {
        let chars = Array(secret)
        let pieces = chars.count < 12 ? [secret] : (0...(chars.count - 12)).map { String(chars[$0..<$0 + 12]) }
        return records.filter { r in pieces.contains { r.text.contains($0) } }.map(\.channel)
    }
}

/// Wraps a policy and records every page and history it is shown.
struct SpyPolicy: AgentPolicy {
    let inner: AgentPolicy
    let spy: LeakSpy
    func decide(snapshot: PageSnapshot, goal: String, history: [AgentStepRecord]) async throws -> AgentDecision {
        spy.record("policy-input", "\(snapshot) \(goal) \(history)")
        return try await inner.decide(snapshot: snapshot, goal: goal, history: history)
    }
}

/// Records Jev request bodies (never the Authorization header) and forwards them.
struct SpyTransport: AgentHTTPTransport {
    let spy: LeakSpy
    var inner: AgentHTTPTransport = URLSessionAgentTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        spy.record("jev-request", String(decoding: request.httpBody ?? Data(), as: UTF8.self) + (request.url?.absoluteString ?? ""))
        let (data, status) = try await inner.send(request)
        spy.record("jev-response", String(decoding: data, as: UTF8.self))
        return (data, status)
    }
}

/// The chat-model fallback (LLMPolicy) with a scripted "model" that records every request:
/// type the name if a name field is empty, else click the most specific create/generate button.
func scriptedLLMPolicy(spy: LeakSpy) -> LLMPolicy {
    LLMPolicy(complete: { request in
        spy.record("llm-request", request.prompt + request.systemPrompt + (request.context ?? ""))
        guard let state = try? JSONDecoder().decode(JSONValue.self, from: Data(request.prompt.utf8)),
              case .array(let elements)? = state["elements"] else { return #"{"operation":"BLOCKED","target":null}"# }
        func ops(_ e: JSONValue) -> [String] {
            if case .array(let a)? = e["operations"] { return a.compactMap(\.stringValue) }
            return []
        }
        if let field = elements.first(where: { ops($0).contains("TYPE_TEXT") &&
            ($0["label"]?.stringValue ?? "").lowercased().contains("name") && ($0["value"]?.stringValue ?? "").isEmpty }) {
            return #"{"operation":"TYPE_TEXT","target":"\#(field["index"]?.stringValue ?? "")"}"#
        }
        for word in ["create secret key", "generate token", "create new secret key"] {
            if let button = elements.first(where: { ops($0).contains("CLICK") &&
                ($0["label"]?.stringValue ?? "").lowercased() == word }) {
                return #"{"operation":"CLICK","target":"\#(button["index"]?.stringValue ?? "")"}"#
            }
        }
        return #"{"operation":"DONE","target":null}"#
    }, modelName: "scripted")
}

// MARK: - Tests

@MainActor
final class KeyGrabberTests: XCTestCase {
    var vault: SecretVault!
    var board: NSPasteboard!
    var host: FixtureHost!
    var spy: LeakSpy!
    private var savedShared: KeyGrabber!

    override func setUp() async throws {
        board = NSPasteboard(name: NSPasteboard.Name("luna.grab.test.\(UUID().uuidString)"))
        vault = SecretVault(service: "Luna API Keys Test \(UUID().uuidString)", pasteboard: board)
        host = FixtureHost(pages: ["keys.luna.test": KeyFixtures.openAIStyle, "tokens.luna.test": KeyFixtures.tokenStyle,
                                   "login.luna.test": KeyFixtures.loginWall])
        spy = LeakSpy()
        savedShared = KeyGrabber.shared
    }

    override func tearDown() async throws {
        KeyGrabber.shared = savedShared
        for item in vault.items() { vault.delete(account: item.account) }
        XCTAssertEqual(vault.items(), [])
        board.releaseGlobally()
        host.closeAll()
    }

    // MARK: Detector

    func testDetectorRule() {
        let mixed = "Q7rT2kLm9XvB4nWc8YpZ3hJd6FsG1aKe5UoR0tIy"     // 40, upper+lower+digits
        let lower = "k3j9x2m7q8w1e4r5t6y0u9i8o7p6a5s4d3f2g1h0"     // 40, lowercase + digits
        let sha = "3f9c2b7e1d4a6c8b9e0f2a1d3c5b7e9f0a2c4e6b"
        let uuid = "1b4e28ba-2fa1-11d2-883f-0016d3cca427"
        let positives: [(String, String)] = [
            ("Your new secret key: sk-proj-" + mixed, "known prefix"),
            ("Here it is: " + mixed, "random-looking on its own"),
            ("Access token " + lower, "labeled lowercase token"),
            ("API key: " + uuid, "labeled UUID"),
            ("token: " + sha, "labeled SHA"),
        ]
        for (text, why) in positives {
            XCTAssertEqual(SecretDetector.secretRanges(in: text).count, 1, why)
            XCTAssertTrue(AgentRedaction.redact(text).hasSuffix(AgentRedaction.mask), why)
        }
        let negatives: [(String, String)] = [
            ("Open https://app.test/items/\(uuid)/edit", "UUID in a URL"),
            ("Request id: \(uuid)", "unlabeled UUID"),
            ("Merged commit \(sha) into main", "commit SHA in text"),
            ("<link href=\"/static/main.\(sha.prefix(24)).css\">", "bundle hash"),
            ("class css-1a2b3c4d5e6f7a8b9c0d1e2f", "CSS hash class"),
            ("See https://x.test/cb?token=\(lower)", "token inside a URL query"),
            ("Call getUserAccountSettingsForProfile2 first", "camelCase identifier"),
            ("internationalization_localization_settings", "long word without digits"),
        ]
        for (text, why) in negatives {
            XCTAssertEqual(SecretDetector.secretRanges(in: text).count, 0, why)
            XCTAssertEqual(AgentRedaction.redact(text), text, why)
        }
        // A field's label is context for its value.
        XCTAssertEqual(AgentRedaction.redact(lower, label: "Access token"), AgentRedaction.mask)
        XCTAssertEqual(AgentRedaction.redact(lower, label: "Search"), lower)
    }

    func testRegistryAndCommandParsing() {
        XCTAssertEqual(KeyService.resolve("OpenAI")?.url.absoluteString, "https://platform.openai.com/api-keys")
        XCTAssertEqual(KeyService.resolve("hugging face")?.id, "huggingface")
        let fallback = KeyService.resolve("example.org")
        XCTAssertEqual(fallback?.known, false)
        XCTAssertEqual(fallback?.url.absoluteString, "https://example.org")
        XCTAssertNil(KeyService.resolve("  "))
        XCTAssertTrue(KeyGrabber.goal(service: fallback!, keyName: "k").hasPrefix("Find"))
        let multi = CommandSurfaceView.grabRequest(in: "/grab hugging face my key")
        XCTAssertEqual(multi?.service, "hugging face")
        XCTAssertEqual(multi?.keyName, "my key")
        XCTAssertEqual(CommandSurfaceView.grabRequest(in: "/grab openai")?.service, "openai")
        XCTAssertNil(CommandSurfaceView.grabRequest(in: "/grab openai")?.keyName)
        XCTAssertNil(CommandSurfaceView.grabRequest(in: "/grab "))
    }

    func testStoreNeverOverwritesAnExistingAccount() throws {
        let first = try vault.store("first-value", account: "openai/luna-x")
        let second = try vault.store("second-value", account: "openai/luna-x")
        let third = try vault.store("third-value", account: "openai/luna-x")
        XCTAssertEqual([first.account, second.account, third.account], ["openai/luna-x", "openai/luna-x-2", "openai/luna-x-3"])
        XCTAssertEqual(vault.value(account: "openai/luna-x"), "first-value")
        XCTAssertEqual(vault.value(account: "openai/luna-x-2"), "second-value")
        XCTAssertEqual(vault.items().count, 3)
        XCTAssertNotNil(board.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")))
    }

    func testDefaultKeyNameIncludesTime() {
        var c = DateComponents(year: 2026, month: 10, day: 15, hour: 9, minute: 8, second: 7)
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        XCTAssertEqual(KeyGrabber.defaultKeyName(c.date!), "luna-20261015-090807")
    }

    func testURLRedactionMasksSecretsKeepsShape() {
        let url = "https://app.example.com/auth/callback?code=abc123&state=xyz&page=2&q=hello#access_token=eyJhbGciOi"
        let out = AgentRedaction.redactURL(url)
        XCTAssertTrue(out.hasPrefix("https://app.example.com/auth/callback?"), out)
        XCTAssertFalse(out.contains("abc123"), out)
        XCTAssertFalse(out.contains("eyJhbGciOi"), out)
        XCTAssertTrue(out.contains("page=2") && out.contains("q=hello"), out)
        XCTAssertTrue(out.contains("code=REDACTED") && out.contains("state=xyz"), out)
        let flagged = AgentRedaction.redactURL("https://x.example.com/p?blob=sk-proj-" + String(repeating: "a1B2", count: 12))
        XCTAssertFalse(flagged.contains("a1B2a1B2"), flagged)
        XCTAssertEqual(AgentRedaction.redactURL("https://example.com/a/b"), "https://example.com/a/b")
    }

    private func randomToken(_ count: Int) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var seed: UInt64 = 0x9E3779B97F4A7C15
        return String((0..<count).map { _ in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return alphabet[Int(seed >> 33) % alphabet.count]
        })
    }

    func testRedactionMasksPathTokensAndLongTokens() {
        let mixed = randomToken(43)
        let reset = AgentRedaction.redactURL("https://accounts.example.com/reset-password/\(mixed)?lang=en")
        XCTAssertEqual(reset, "https://accounts.example.com/reset-password/REDACTED?lang=en")
        let hex = "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b"
        XCTAssertEqual(AgentRedaction.redactURL("https://example.com/reset-password/\(hex)"), "https://example.com/reset-password/REDACTED")
        let long = randomToken(300)
        XCTAssertEqual(AgentRedaction.redact("session \(long) end"), "session \(AgentRedaction.mask) end")

        for normal in ["https://github.com/apple/swift/commit/\(hex)", "https://example.com/blog/2024/how-to-write-swift-tests-well",
                       "https://en.wikipedia.org/wiki/Representational_state_transfer"] {
            XCTAssertEqual(AgentRedaction.redactURL(normal), normal)
        }
        let prose = "Internationalization and representational considerations remain"
        XCTAssertEqual(AgentRedaction.redact(prose), prose)
    }

    // MARK: Fixtures with the chat-model policy (no network)

    /// The full loop with the LLM fallback, on the sk-proj- fixture: the key lands in the Keychain
    /// and on the pasteboard, and no LLM request, policy input, event, panel line or result has it.
    func testGrabSavesKeyWithoutExposingItToTheModel() async throws {
        let grabber = KeyGrabber(vault: vault, makePolicy: { [spy] in SpyPolicy(inner: scriptedLLMPolicy(spy: spy!), spy: spy!) })
        let tab = host.openTab(url: URL(string: "https://keys.luna.test/")!)
        let webView = try XCTUnwrap(host.webView(for: tab))
        let service = KeyService(id: "fixture", name: "Fixture", url: URL(string: "https://keys.luna.test/")!)
        let result = await grabber.grab(service: service, keyName: "luna-test", webView: webView, navigate: { _ in },
                                        onEvent: { [spy] in spy!.record("event", "\($0)"); spy!.record("panel", $0.panelLine ?? "") })
        spy.record("result", result.json + result.message)

        XCTAssertEqual(result.status, .saved, result.message)
        XCTAssertEqual(result.saved?.keychainItem, "\(vault.service) / fixture/luna-test")
        XCTAssertEqual(result.message, "Saved Fixture key to Keychain and clipboard — not shared with the agent.")
        let shown = try await pageText(webView, "document.getElementById('key').textContent")
        XCTAssertTrue(shown.hasPrefix("sk-proj-") && shown.count == 56)
        XCTAssertEqual(vault.value(account: "fixture/luna-test"), shown)
        XCTAssertEqual(board.string(forType: .string), shown)
        XCTAssertEqual(vault.items().map(\.account), ["fixture/luna-test"])
        XCTAssertTrue(spy.records.contains { $0.channel == "llm-request" }, "the model was used")
        XCTAssertEqual(spy.leaks(of: shown), [])
        XCTAssertFalse(result.json.contains(shown))
    }

    /// Generic path: no known prefix; the unlabeled UUID beside it is not taken.
    func testGrabCapturesUnprefixedTokenFromReadonlyField() async throws {
        let grabber = KeyGrabber(vault: vault, makePolicy: { [spy] in SpyPolicy(inner: scriptedLLMPolicy(spy: spy!), spy: spy!) })
        let tab = host.openTab(url: URL(string: "https://tokens.luna.test/")!)
        let webView = try XCTUnwrap(host.webView(for: tab))
        let service = KeyService(id: "tokens", name: "Tokens", url: URL(string: "https://tokens.luna.test/")!)
        let result = await grabber.grab(service: service, keyName: "ci", webView: webView, navigate: { _ in },
                                        onEvent: { [spy] in spy!.record("event", "\($0)") })
        spy.record("result", result.json)
        XCTAssertEqual(result.status, .saved, result.message)
        let token = try await pageText(webView, "document.getElementById('tok').value")
        XCTAssertEqual(token.count, 40)
        XCTAssertEqual(vault.value(account: "tokens/ci"), token)
        XCTAssertEqual(board.string(forType: .string), token)
        XCTAssertEqual(spy.leaks(of: token), [])
    }

    /// Sign-in wall over MCP: the call pauses with waiting_for_user_sign_in before the agent acts
    /// (no field touched); after the user signs in, calling again with the tab id finishes the grab.
    func testLoginWallPausesThenResumesOverMCP() async throws {
        KeyGrabber.shared = KeyGrabber(vault: vault, makePolicy: { [spy] in SpyPolicy(inner: scriptedLLMPolicy(spy: spy!), spy: spy!) })
        let host = self.host!
        let toolbox = LunaToolbox { host }
        let first = try await toolbox.call("grab_api_key", arguments: ["service": "Fixture", "url": "https://login.luna.test/", "key_name": "after-login"])
        spy.record("mcp", first.text)
        let paused = try JSONDecoder().decode(JSONValue.self, from: Data(first.text.utf8))
        XCTAssertEqual(paused["status"]?.stringValue, "waiting_for_user_sign_in", first.text)
        XCTAssertFalse(spy.records.contains { $0.channel == "llm-request" }, "the agent must not act on a sign-in page")
        let tabId = try XCTUnwrap(paused["tab_id"]?.stringValue)
        let webView = try XCTUnwrap(host.webView(for: UUID(uuidString: tabId)!))
        let typed = try await pageText(webView, "document.getElementById('email').value + document.getElementById('pw').value")
        XCTAssertEqual(typed, "")

        // The user signs in: the site now serves the dashboard at that address.
        host.pages["login.luna.test"] = KeyFixtures.openAIStyle
        let second = try await toolbox.call("grab_api_key", arguments: ["service": "Fixture", "url": "https://login.luna.test/",
                                                                         "key_name": "after-login", "tab_id": .string(tabId)])
        spy.record("mcp", second.text)
        let done = try JSONDecoder().decode(JSONValue.self, from: Data(second.text.utf8))
        XCTAssertEqual(done["status"]?.stringValue, "saved", second.text)
        XCTAssertNotNil(done["keychain_item"]?.stringValue)
        let shown = try await pageText(webView, "document.getElementById('key').textContent")
        XCTAssertEqual(vault.value(account: "fixture/after-login"), shown)
        XCTAssertEqual(spy.leaks(of: shown), [])
    }

    func pageText(_ webView: WKWebView, _ expression: String) async throws -> String {
        try await webView.callAsyncJavaScript("return " + expression, arguments: [:], in: nil, contentWorld: .defaultClient) as? String ?? ""
    }
}

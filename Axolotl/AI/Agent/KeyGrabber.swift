import CryptoKit
import Foundation
import WebKit

// MARK: - Known key dashboards

/// A service whose API-key page Axolotl knows. Anything else falls back to the site's home page.
struct KeyService: Equatable {
    let id: String
    let name: String
    let url: URL
    var aliases: [String] = []
    var known = true

    static let registry: [KeyService] = [
        KeyService(id: "openai", name: "OpenAI", url: URL(string: "https://platform.openai.com/api-keys")!, aliases: ["chatgpt", "gpt"]),
        KeyService(id: "anthropic", name: "Anthropic", url: URL(string: "https://platform.claude.com/settings/keys")!, aliases: ["claude"]),
        KeyService(id: "google-ai-studio", name: "Google AI Studio", url: URL(string: "https://aistudio.google.com/apikey")!, aliases: ["gemini", "google", "aistudio"]),
        KeyService(id: "github", name: "GitHub", url: URL(string: "https://github.com/settings/personal-access-tokens/new")!, aliases: ["gh"]),
        KeyService(id: "stripe", name: "Stripe", url: URL(string: "https://dashboard.stripe.com/apikeys")!),
        KeyService(id: "huggingface", name: "Hugging Face", url: URL(string: "https://huggingface.co/settings/tokens")!, aliases: ["hf", "hugging face"]),
        KeyService(id: "vercel", name: "Vercel", url: URL(string: "https://vercel.com/account/settings/tokens")!),
        KeyService(id: "replicate", name: "Replicate", url: URL(string: "https://replicate.com/account/api-tokens")!),
        KeyService(id: "openrouter", name: "OpenRouter", url: URL(string: "https://openrouter.ai/settings/keys")!),
        KeyService(id: "groq", name: "Groq", url: URL(string: "https://console.groq.com/keys")!),
    ]

    /// A registry entry by id, name or alias; otherwise the site itself ("example.com" or "example" → example.com).
    static func resolve(_ input: String) -> KeyService? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = raw.lowercased()
        guard !q.isEmpty else { return nil }
        if let hit = registry.first(where: { $0.id == q || $0.name.lowercased() == q || $0.aliases.contains(q) }) { return hit }
        let host = q.contains(".") ? q : q.replacingOccurrences(of: " ", with: "") + ".com"
        guard let url = URL(string: host.contains("://") ? host : "https://" + host), isSafeBrowserURL(url) else { return nil }
        let id = q.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: "-")
        return KeyService(id: id, name: raw, url: url, known: false)
    }
}

// MARK: - Capture

/// Reads new key-like values in the private `axolotlAgent` world and hands them straight to
/// `SecretVault` through a message handler registered only in that world. Page scripts cannot
/// see or call it; the value never passes through a snapshot, redaction, a model or a log.
final class SecretCapture: NSObject, WKScriptMessageHandler {
    static let handlerName = "axolotlSecretCapture"

    private weak var webView: WKWebView?
    private let vault: SecretVault
    private let account: String
    private let keyName: String
    private var scanId = 0
    private var received: [Int: Int] = [:]
    private var baselineScan = -1
    /// Hashes of values on the page before the agent acted, so an old value is never taken for the new key.
    private var baseline: Set<String> = []
    private(set) var capturedHashes: Set<String> = []
    private(set) var saved: SecretVault.Saved?
    private(set) var saveError: String?

    init(webView: WKWebView, vault: SecretVault, account: String, keyName: String) {
        self.webView = webView
        self.vault = vault
        self.account = account
        self.keyName = keyName
    }

    private final class WeakHandler: NSObject, WKScriptMessageHandler {
        weak var target: SecretCapture?
        init(_ target: SecretCapture) { self.target = target }
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            target?.userContentController(c, didReceive: message)
        }
    }

    func install() {
        guard let controller = webView?.configuration.userContentController else { return }
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: PageDriver.world)
        controller.add(WeakHandler(self), contentWorld: PageDriver.world, name: Self.handlerName)
    }

    func uninstall() {
        webView?.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.handlerName, contentWorld: PageDriver.world)
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.world == PageDriver.world, let body = message.body as? [String: Any],
              let value = body["value"] as? String, let scan = body["scan"] as? Int else { return }
        received[scan, default: 0] += 1
        let context = body["context"] as? String ?? ""
        let h = Self.hash(value)
        if scan == baselineScan { baseline.insert(h); return }
        guard saved == nil, !baseline.contains(h), value != keyName, !keyName.contains(value),
              SecretDetector.isSecret(value, context: context) else { return }
        do {
            saved = try vault.store(value, account: account)
            capturedHashes.insert(h)
        } catch {
            saveError = error.localizedDescription
        }
    }

    struct ScanResult { var posted = 0; var loginWall = false }

    /// Posts every candidate token on the page to the handler, then waits until all arrived.
    /// The script returns only a count and a sign-in flag, never a value.
    @discardableResult
    func scan(baseline isBaseline: Bool = false) async -> ScanResult {
        guard let webView else { return ScanResult() }
        scanId += 1
        let id = scanId
        if isBaseline { baselineScan = id }
        let result = try? await webView.callAsyncJavaScript(Self.scanScript, arguments: ["scan": id, "name": keyName],
                                                           in: nil, contentWorld: PageDriver.world)
        let dict = result as? [String: Any] ?? [:]
        let posted = (dict["posted"] as? NSNumber)?.intValue ?? 0
        let deadline = Date().addingTimeInterval(1)
        while received[id, default: 0] < posted, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return ScanResult(posted: posted, loginWall: (dict["login"] as? NSNumber)?.boolValue ?? false)
    }

    /// Text nodes (including `<code>`), and visible input/textarea values (password fields are
    /// skipped). Tokens inside URLs/paths are not candidates. Each value is posted once per document.
    /// The page's own Copy button writes to the clipboard from the page world, which this world
    /// cannot wrap without exposing the handler to the page, so the shown value is read instead.
    static let scanScript = #"""
    const handler = window.webkit?.messageHandlers?.axolotlSecretCapture;
    const vis = e => !!e && (!e.checkVisibility || e.checkVisibility({checkOpacity:true, checkVisibilityCSS:true}));
    const pw = [...document.querySelectorAll('input[type=password]:not([readonly]):not([disabled])')].some(vis);
    const user = [...document.querySelectorAll('input[type=email],input[autocomplete~=username],input[name*=email i],input[name*=login i]')].some(vis);
    const loginPlace = /(log-?in|sign-?in|auth|sso)/i.test(location.pathname) || /^(accounts?|login|auth|sso|signin)\./i.test(location.hostname);
    // A password field with a username field, or on a sign-in URL. A lone password-type field
    // (some dashboards show a key that way) is not a sign-in wall.
    const login = (pw && (user || loginPlace)) || (loginPlace && user);
    if (!handler || !document.body) return {posted: 0, login};
    const seen = window.__axolotlSecretSeen ||= new Set();
    const re = /(?<![A-Za-z0-9_\-\/=.?&#%@])[A-Za-z0-9_\-]{20,256}(?![A-Za-z0-9_\-\/])/g;
    // Context = the label right next to the value, not the whole container, so an unlabeled
    // id below a "token" field is not mistaken for the token (see SecretDetector).
    const near = el => (el?.previousElementSibling?.textContent || '').slice(-80);
    const fieldContext = e => {
      const own = [e.getAttribute('aria-label'), e.getAttribute('placeholder'), e.getAttribute('title'),
        e.getAttribute('name'), e.id, ...[...(e.labels || [])].map(l => l.textContent)].filter(Boolean).join(' ');
      return own || near(e) || near(e.parentElement);
    };
    const out = [];
    const add = (text, contextFor) => {
      for (const m of text.matchAll(re)) {
        const v = m[0];
        if (seen.has(v) || v === name) continue;
        seen.add(v);
        out.push({value: v, context: contextFor(m.index).replace(/\s+/g, ' ').slice(-300), scan});
      }
    };
    for (const e of document.querySelectorAll('input,textarea')) {
      if (['password', 'hidden', 'file'].includes(e.type) || !vis(e) || !e.value) continue;
      add(e.value, () => fieldContext(e));
    }
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const p = n.parentElement, t = n.textContent;
      if (!p || t.length < 20 || p.closest('script,style,noscript,template') || !vis(p)) continue;
      add(t, i => {
        const before = t.slice(Math.max(0, i - 48), i);
        const label = p.getAttribute('aria-label') || '';
        return before.trim() || label ? label + ' ' + before : near(p) || near(p.parentElement);
      });
    }
    for (const x of out) handler.postMessage(x);
    return {posted: out.length, login};
    """#
}

/// The tab's page driver plus a capture scan before every snapshot. Captured values are
/// masked (by hash) in what the agent sees, on top of `AgentRedaction`.
final class GrabPageDriver: AgentPageDriving {
    let inner: PageDriver
    let capture: SecretCapture
    private(set) var loginWall = false

    init(inner: PageDriver, capture: SecretCapture) {
        self.inner = inner
        self.capture = capture
    }

    func snapshot() async throws -> PageSnapshot {
        var snap = try await inner.snapshot()
        loginWall = await capture.scan().loginWall
        let hashes = capture.capturedHashes
        guard !hashes.isEmpty else { return snap }
        let mask: (String) -> String = { text in
            var out = text
            for c in Set(SecretDetector.candidates(in: text)) where hashes.contains(SecretCapture.hash(c)) {
                out = out.replacingOccurrences(of: c, with: AgentRedaction.mask)
            }
            return out
        }
        snap.title = mask(snap.title)
        snap.text = mask(snap.text)
        snap.actions = snap.actions.map { a in
            var a = a
            a.label = mask(a.label)
            a.value = a.value.map(mask)
            a.currentValue = a.currentValue.map(mask)
            return a
        }
        return snap
    }

    func isFresh(_ snapshot: PageSnapshot, for action: PageAction?) async -> Bool {
        await inner.isFresh(snapshot, for: action)
    }

    func perform(_ action: PageAction, text: String?) async throws {
        try await inner.perform(action, text: text)
    }

    func settle(after action: PageAction) async {
        await inner.settle(after: action)
    }
}

// MARK: - Grabber

struct GrabResult: Equatable {
    enum Status: String {
        case saved
        case waitingForSignIn = "waiting_for_user_sign_in"
        case notFound = "not_found"
        case failed
        case cancelled
    }

    let status: Status
    let service: String
    let keyName: String
    var saved: SecretVault.Saved?
    var message: String
    /// Set by the tool so a caller can resume in the same tab.
    var tabId: String?

    /// What a tool caller gets: status and Keychain item. Never the value.
    var json: String {
        var o: [String: JSONValue] = ["status": .string(status.rawValue), "service": .string(service),
                                      "key_name": .string(keyName), "message": .string(message)]
        if let tabId { o["tab_id"] = .string(tabId) }
        if let saved {
            o["keychain_item"] = .string(saved.keychainItem)
        }
        return JSONValue.object(o).jsonString()
    }
}

/// Runs the computer-use agent to create a key and captures it without any model seeing it.
final class KeyGrabber {
    static var shared = KeyGrabber()

    let vault: SecretVault
    private let makePolicy: () -> AgentPolicy

    init(vault: SecretVault = .shared, makePolicy: (() -> AgentPolicy)? = nil) {
        self.vault = vault
        self.makePolicy = makePolicy ?? { ComputerUseAgent.defaultPolicy() }
    }

    /// One grab per web view: the capture handler is registered per page controller, so a second
    /// concurrent grab would replace the first one's handler.
    private static let claimLock = NSLock()
    private static var claimed: Set<ObjectIdentifier> = []
    private static func claim(_ webView: WKWebView) -> Bool {
        claimLock.lock(); defer { claimLock.unlock() }
        return claimed.insert(ObjectIdentifier(webView)).inserted
    }
    private static func release(_ webView: WKWebView) {
        claimLock.lock(); defer { claimLock.unlock() }
        claimed.remove(ObjectIdentifier(webView))
    }

    static func defaultKeyName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "axolotl-" + f.string(from: date)
    }

    static func goal(service: KeyService, keyName: String) -> String {
        let find = service.known ? "" : "Find \(service.name)'s API keys page (developer settings, account or dashboard), then "
        return find + "create a new API key named '\(keyName)' and make the full new key visible on the page " +
            "(reveal it or open the view that shows it). Stop as soon as the new key is shown. " +
            "Do not sign in, and do not delete or change existing keys."
    }

    /// Loads the service's key page in `webView` (via `navigate`), then runs the agent until a new
    /// key is captured, a sign-in page appears, or the agent stops. Resuming is calling it again.
    func grab(service: KeyService, keyName: String, webView: WKWebView, navigate: (URL) -> Void,
              maxSteps: Int = 30, onEvent: (AgentEvent) -> Void = { _ in }) async -> GrabResult {
        let account = "\(service.id)/\(keyName)"
        var result = GrabResult(status: .failed, service: service.name, keyName: keyName, message: "")
        guard Self.claim(webView) else {
            result.message = "Another key grab is already running in this tab. Wait for it to finish."
            return result
        }
        defer { Self.release(webView) }
        let oldURL = webView.url
        navigate(service.url)
        await AxolotlToolbox.waitForNavigationStart(webView, from: oldURL)

        let capture = SecretCapture(webView: webView, vault: vault, account: account, keyName: keyName)
        capture.install()
        defer { capture.uninstall() }
        let driver = GrabPageDriver(inner: AxolotlToolbox.driver(for: webView), capture: capture)

        do {
            _ = try await driver.inner.snapshot()
        } catch {
            result.message = "The page did not load."
            return result
        }
        if await capture.scan(baseline: true).loginWall {
            return signIn(result)
        }

        let agent = ComputerUseAgent(driver: driver, policy: makePolicy(), textProvider: FixedText(text: keyName),
                                     maxSteps: maxSteps)
        agent.shouldStop = {
            if capture.saved != nil { return .done }
            if driver.loginWall { return .blocked("Sign-in required.") }
            return nil
        }
        var outcome: AgentOutcome = .cancelled
        for await event in agent.run(goal: Self.goal(service: service, keyName: keyName)) {
            onEvent(event)
            if case .finished(let o, _, _) = event { outcome = o }
        }
        if capture.saved == nil, outcome != .cancelled {
            let last = await capture.scan()
            if capture.saved == nil, last.loginWall || driver.loginWall { return signIn(result) }
        }
        if let saved = capture.saved {
            result = GrabResult(status: .saved, service: service.name, keyName: keyName, saved: saved,
                                message: "Saved \(service.name) key to Keychain and clipboard — not shared with the agent.")
            return result
        }
        if let error = capture.saveError {
            result.message = "Found a key but could not save it: \(error)"
            return result
        }
        switch outcome {
        case .cancelled:
            return GrabResult(status: .cancelled, service: service.name, keyName: keyName, message: "Stopped.")
        case .failed(let why):
            result.message = "The agent stopped: \(why)"
        case .done, .blocked:
            result = GrabResult(status: .notFound, service: service.name, keyName: keyName,
                                message: "No new key appeared on the page. Create it by hand or try again.")
        }
        return result
    }

    private func signIn(_ base: GrabResult) -> GrabResult {
        GrabResult(status: .waitingForSignIn, service: base.service, keyName: base.keyName,
                   message: "Waiting for user sign-in: sign in to \(base.service) in this Axolotl tab, then resume. Axolotl never types passwords.")
    }

    /// The only text the agent types during a grab is the key name: no model writes field values.
    struct FixedText: FieldTextProviding {
        let text: String
        func text(for context: JSONValue) async throws -> String { text }
    }
}

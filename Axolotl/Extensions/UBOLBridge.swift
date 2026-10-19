import WebKit

/// Sends messages to uBlock Origin Lite's background the way its own popup does: from one of its
/// extension pages (`browser.runtime.sendMessage`, a trusted origin). WebKit gives native code no
/// other way in. The hidden page is loaded on demand and dropped 2 s after its last message is answered,
/// so a burst (every site's mode) shares one page and nothing runs while Shields is idle.
@MainActor
final class UBOLBridge: NSObject, WKNavigationDelegate {
    private let context: WKWebExtensionContext
    private var webView: WKWebView?
    private var isReady = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight = 0
    private var teardown: Task<Void, Never>?
    /// Hidden-page loads so far (one per burst of messages).
    private(set) var pageLoads = 0

    init(context: WKWebExtensionContext) {
        self.context = context
    }

    nonisolated deinit {}

    /// One uBOL message (`{what: …}`) and its reply, or nil if the page or message failed.
    @discardableResult
    func send(_ message: [String: Any]) async -> Any? {
        inFlight += 1
        teardown?.cancel()
        defer {
            inFlight -= 1
            if inFlight == 0 {
                teardown = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self, self.inFlight == 0 else { return }
                    self.webView = nil
                    self.isReady = false
                }
            }
        }
        guard let page = await page() else { return nil }
        return try? await page.callAsyncJavaScript("return await browser.runtime.sendMessage(m)",
                                                   arguments: ["m": message], contentWorld: .page)
    }

    private func page() async -> WKWebView? {
        if webView == nil {
            guard let config = context.webViewConfiguration else { return nil }
            let wv = WKWebView(frame: .zero, configuration: config)
            wv.navigationDelegate = self
            webView = wv
            pageLoads += 1
            // A read-only uBOL page (it only lists matched rules); any extension page gets the API.
            wv.load(URLRequest(url: context.baseURL.appendingPathComponent("matched-rules.html")))
        }
        if !isReady { await withCheckedContinuation { waiters.append($0) } }
        return webView
    }

    /// A failed load is dropped at once so the next message loads a fresh page instead of waiting.
    private func failed() {
        webView = nil
        resume()
    }

    private func resume() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed() }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed() }
}

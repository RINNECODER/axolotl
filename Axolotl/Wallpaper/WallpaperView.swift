// Axolotl — the start page wallpaper: a transparent, non-interactive web view that
// runs the bundled WebGPU shaders. It has its own configuration and data store,
// can only load Axolotl's bundled files, and draws only while the start page is on
// screen.
import SwiftUI
import AppKit
import WebKit
import Combine

struct WallpaperView: View {
    let config: WallpaperRenderConfig
    /// Called on the main thread when the page can't use WebGPU.
    var onFallback: (() -> Void)?

    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activity = WallpaperActivity(isOnScreen: onScreen, reduceMotion: reduceMotion, lowPower: lowPower)
        WallpaperWebViewRepresentable(config: config, mode: activity.mode, onFallback: onFallback)
            .background(WindowVisibilityReader(isVisible: $onScreen))
            .onDisappear { onScreen = false }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                DispatchQueue.main.async { lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct WallpaperWebViewRepresentable: NSViewRepresentable {
    let config: WallpaperRenderConfig
    let mode: WallpaperActivity.Mode
    let onFallback: (() -> Void)?

    func makeCoordinator() -> WallpaperBridge { WallpaperBridge() }

    func makeNSView(context: Context) -> PassthroughWebView {
        context.coordinator.onState = { state in
            if state == "fallback" { DispatchQueue.main.async { onFallback?() } }
        }
        let webView = WallpaperWeb.makeWebView(bridge: context.coordinator)
        context.coordinator.webView = webView
        webView.onMouseMoved = { [weak bridge = context.coordinator] in bridge?.pointerMoved($0) }
        return webView
    }

    func updateNSView(_ webView: PassthroughWebView, context: Context) {
        context.coordinator.update(config: config, mode: mode)
    }

    static func dismantleNSView(_ webView: PassthroughWebView, coordinator: WallpaperBridge) {
        coordinator.update(config: nil, mode: .paused)
        webView.onMouseMoved = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }
}

/// Talks to `window.axolotlWallpaper`, queuing calls until the page has loaded.
final class WallpaperBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var webView: PassthroughWebView?
    private var loaded = false
    private var config: WallpaperRenderConfig?
    private var mode: WallpaperActivity.Mode = .paused
    private var sentConfig: WallpaperRenderConfig?
    private var sentActive: Bool?
    var onState: ((String) -> Void)?
    private var crashCount = 0
    private var tracking: NSTrackingArea?
    private var clickMonitor: Any?
    private var pendingPointer: CGPoint?
    private var lastPointerSent: CFTimeInterval = 0
    static let maxReloads = 3

    /// Only the initial `axolotl-wallpaper` page load is allowed; everything else is cancelled.
    static func allowsNavigation(to url: URL?, isMainFrame: Bool?) -> Bool {
        guard isMainFrame ?? false else { return false }
        return url.map { WallpaperSchemeHandler.fileURL(for: $0) != nil } ?? false
    }

    /// Seconds to wait before reload attempt `n` (1-based); nil once we give up.
    static func reloadDelay(attempt n: Int) -> TimeInterval? {
        n >= 1 && n <= maxReloads ? 0.5 * pow(2, Double(n - 1)) : nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(Self.allowsNavigation(to: action.request.url, isMainFrame: action.targetFrame?.isMainFrame) ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashCount += 1
        loaded = false
        guard let delay = Self.reloadDelay(attempt: crashCount), let url = webView.url else {
            onState?("fallback")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
            webView?.load(URLRequest(url: url))
        }
    }

    func update(config: WallpaperRenderConfig?, mode: WallpaperActivity.Mode) {
        var config = config
        if let held = config?.still { config?.still = held || mode == .still }
        self.config = config
        self.mode = mode
        flush()
    }

    private func flush() {
        guard loaded, let webView else { return }
        if let config, config != sentConfig {
            sentConfig = config
            webView.evaluateJavaScript("window.axolotlWallpaper && window.axolotlWallpaper.apply(\(config.json()))")
        }
        let active = mode != .paused
        if active != sentActive {
            sentActive = active
            webView.evaluateJavaScript("window.axolotlWallpaper && window.axolotlWallpaper.setActive(\(active))")
        }
        syncPointerInput()
    }

    // MARK: Pointer input
    // Only while the wallpaper is animating on screen with an effect on; otherwise no
    // tracking area or event monitor exists, so the pointer costs nothing.

    private func syncPointerInput() {
        let on = loaded && mode == .running
        let wantsMove = on && (config?.pointer ?? "off") != "off"
        let wantsClick = on && (config?.click ?? "off") != "off"
        if wantsMove != (tracking != nil), let webView {
            if let tracking { webView.removeTrackingArea(tracking); self.tracking = nil }
            if wantsMove {
                let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
                                          owner: webView, userInfo: nil)
                webView.addTrackingArea(area)
                tracking = area
            }
        }
        if wantsClick != (clickMonitor != nil) {
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
            if wantsClick {
                // Clicks still go to the start page; the wallpaper only watches them.
                clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                    self?.send(event, click: true)
                    return event
                }
            }
        }
    }

    func pointerMoved(_ event: NSEvent) {
        guard tracking != nil, let webView, let p = Self.normalized(event, in: webView) else { return }
        // At most 60 updates a second; the latest position wins.
        let due = pendingPointer == nil
        pendingPointer = p
        guard due else { return }
        let wait = max(0, lastPointerSent + 1.0 / 60 - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, let p = self.pendingPointer else { return }
            self.pendingPointer = nil
            self.lastPointerSent = CACurrentMediaTime()
            self.sendPointer(p, click: false)
        }
    }

    private func send(_ event: NSEvent, click: Bool) {
        guard let webView, event.window === webView.window, let p = Self.normalized(event, in: webView) else { return }
        sendPointer(p, click: click)
    }

    private func sendPointer(_ p: CGPoint, click: Bool) {
        guard loaded, mode == .running else { return }
        webView?.evaluateJavaScript("window.axolotlWallpaper && window.axolotlWallpaper.pointer(\(p.x), \(p.y), \(click))")
    }

    /// The event's position in `view` as 0...1 with y down, or nil outside it.
    static func normalized(_ event: NSEvent, in view: NSView) -> CGPoint? {
        let p = view.convert(event.locationInWindow, from: nil)
        let b = view.bounds
        guard b.width > 0, b.height > 0, b.contains(p) else { return nil }
        let y = (p.y - b.minY) / b.height
        return CGPoint(x: (p.x - b.minX) / b.width, y: view.isFlipped ? y : 1 - y)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let state = body["state"] as? String else { return }
        #if DEBUG
        NSLog("[wallpaper] %@", body.description)
        #endif
        if state == "loaded" {
            loaded = true
            sentConfig = nil
            sentActive = nil
            flush()
        }
        onState?(state)
    }
}

enum WallpaperWeb {
    static let scheme = "axolotl-wallpaper"

    static let pageURL = URL(string: "\(scheme)://app/index.html")!

    /// Blocks every network load; the page only ever needs `axolotl-wallpaper://`.
    private static var ruleList: WKContentRuleList?
    private static let rules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^file://"},"action":{"type":"block"}}]
    """

    static func prepareRules(_ done: @escaping (WKContentRuleList?) -> Void) {
        if let ruleList { done(ruleList); return }
        WKContentRuleListStore.default()?.compileContentRuleList(
            forIdentifier: "AxolotlWallpaperNoNetwork", encodedContentRuleList: rules) { list, _ in
            ruleList = list
            done(list)
        }
    }

    /// One process pool and in-memory data store for every wallpaper view, so they
    /// share a WebContent process (and the parsed shaders) instead of one each.
    private static let processPool = WKProcessPool()
    private static let dataStore = WKWebsiteDataStore.nonPersistent()

    static func makeWebView(bridge: WallpaperBridge) -> PassthroughWebView {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.websiteDataStore = dataStore
        config.setURLSchemeHandler(WallpaperSchemeHandler(), forURLScheme: scheme)
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(WeakMessageHandler(bridge), name: "axolotlWallpaper")

        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityElement(false)
        webView.navigationDelegate = bridge
        prepareRules { [weak webView, weak bridge] list in
            // Never load without the no-network rules; show the static fallback instead.
            guard let list, let webView else { bridge?.onState?("fallback"); return }
            config.userContentController.add(list)
            webView.load(URLRequest(url: pageURL))
        }
        return webView
    }
}

/// Ignores the mouse so clicks and scrolls go to the start page above it. Pointer moves
/// reach the page only through `onMouseMoved` (see `WallpaperBridge.syncPointerInput`).
final class PassthroughWebView: WKWebView {
    var onMouseMoved: ((NSEvent) -> Void)?
    override func mouseMoved(with event: NSEvent) { onMouseMoved?(event) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// The content controller retains its handlers; this breaks the cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Serves the files in the app's Wallpaper/WallpaperWeb folder, nothing else.
final class WallpaperSchemeHandler: NSObject, WKURLSchemeHandler {
    static let folder: URL? = Bundle.main.resourceURL?.appendingPathComponent("WallpaperWeb", isDirectory: true)

    /// The only files the pages may load.
    static let allowedFiles: Set<String> = ["index.html", "wallpaper.js", "shaders.js"]

    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == WallpaperWeb.scheme, url.host == "app", let folder else { return nil }
        guard url.pathComponents.count == 2, allowedFiles.contains(url.pathComponents[1]) else { return nil }
        return folder.appendingPathComponent(url.pathComponents[1])
    }

    private static func mimeType(_ ext: String) -> String {
        switch ext {
        case "html": return "text/html"
        case "js": return "text/javascript"
        case "css": return "text/css"
        default: return "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let file = Self.fileURL(for: url),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
            "Content-Type": "\(Self.mimeType(file.pathExtension)); charset=utf-8",
            "Content-Length": "\(data.count)",
        ])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

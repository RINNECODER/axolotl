// Luna — the start page wallpaper: a transparent, non-interactive web view that
// runs the bundled WebGPU shaders. It has its own configuration and data store,
// can only load Luna's bundled files, and draws only while the start page is on
// screen.
import SwiftUI
import AppKit
import WebKit
import Combine

struct WallpaperView: View {
    let config: WallpaperRenderConfig
    var page: WallpaperWeb.Page = .wallpaper
    /// Called on the main thread when the page can't use WebGPU.
    var onFallback: (() -> Void)?

    @State private var onScreen = false
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let activity = WallpaperActivity(isOnScreen: onScreen, reduceMotion: reduceMotion, lowPower: lowPower)
        WallpaperWebViewRepresentable(config: config, mode: activity.mode, page: page, onFallback: onFallback)
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
    let page: WallpaperWeb.Page
    let onFallback: (() -> Void)?

    func makeCoordinator() -> WallpaperBridge { WallpaperBridge() }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.onState = { state in
            if state == "fallback" { DispatchQueue.main.async { onFallback?() } }
        }
        let webView = WallpaperWeb.makeWebView(bridge: context.coordinator, page: page)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(config: config, mode: mode)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: WallpaperBridge) {
        coordinator.update(config: nil, mode: .paused)
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
    }
}

/// Talks to `window.lunaWallpaper`, queuing calls until the page has loaded.
final class WallpaperBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    private var loaded = false
    private var config: WallpaperRenderConfig?
    private var mode: WallpaperActivity.Mode = .paused
    private var sentConfig: WallpaperRenderConfig?
    private var sentActive: Bool?
    var onState: ((String) -> Void)?

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
            webView.evaluateJavaScript("window.lunaWallpaper && window.lunaWallpaper.apply(\(config.json()))")
        }
        let active = mode != .paused
        if active != sentActive {
            sentActive = active
            webView.evaluateJavaScript("window.lunaWallpaper && window.lunaWallpaper.setActive(\(active))")
        }
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
    static let scheme = "luna-wallpaper"

    enum Page: String {
        case wallpaper = "index.html"
        case moon = "moon.html"
        var url: URL { URL(string: "\(WallpaperWeb.scheme)://app/\(rawValue)")! }
    }

    /// Blocks every network load; the page only ever needs `luna-wallpaper://`.
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
            forIdentifier: "LunaWallpaperNoNetwork", encodedContentRuleList: rules) { list, _ in
            ruleList = list
            done(list)
        }
    }

    static func makeWebView(bridge: WallpaperBridge, page: Page = .wallpaper) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(WallpaperSchemeHandler(), forURLScheme: scheme)
        config.suppressesIncrementalRendering = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.isElementFullscreenEnabled = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(WeakMessageHandler(bridge), name: "lunaWallpaper")

        let webView = PassthroughWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.setAccessibilityElement(false)
        prepareRules { list in
            if let list { config.userContentController.add(list) }
            webView.load(URLRequest(url: page.url))
        }
        return webView
    }
}

/// Ignores the mouse so clicks and scrolls go to the start page above it.
private final class PassthroughWebView: WKWebView {
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

    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == WallpaperWeb.scheme, url.host == "app", let folder else { return nil }
        let name = url.lastPathComponent
        guard !name.isEmpty, !name.hasPrefix("."), url.pathComponents.count == 2 else { return nil }
        return folder.appendingPathComponent(name)
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

/// The start page moon drawn by a WebGPU shader. Same frame as `AsciiMoon`, transparent
/// around the sphere so wallpapers show through; falls back to the ASCII moon.
struct ShaderMoon: View {
    var diameter: CGFloat = 170
    var isBusy: Bool = false

    @ObservedObject private var store = WallpaperStore.shared
    @State private var failed = false

    var body: some View {
        if failed {
            AsciiMoon(diameter: diameter, isBusy: isBusy)
        } else {
            WallpaperView(config: config, page: .moon, onFallback: { failed = true })
                .frame(width: diameter * 1.3, height: diameter * 1.15)
        }
    }

    private var config: WallpaperRenderConfig {
        var config = WallpaperRenderConfig(preset: .none, style: WallpaperPreset.none.defaultStyle,
                                           fps: store.frameRate, still: false, scale: 1)
        config.busy = isBusy
        return config
    }
}

import WebKit

/// Reader mode (Safari Reader / Brave Speedreader): Mozilla's Readability.js (Apache-2.0, bundled,
/// see Readability-LICENSE.md) runs in an isolated content world the page can't see. The cheap
/// `isProbablyReaderable` check runs once per main-frame load; the full parse only on a click.
enum ReaderMode {
    struct Article: Equatable {
        var title: String
        var byline: String?
        var siteName: String?
        /// Readability's cleaned article HTML; shown with scripts off and a strict CSP.
        var content: String
        var url: URL?
    }

    static let world = WKContentWorld.world(name: "LunaReader")

    private static func bundled(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    static let checkScript = bundled("Readability-readerable") + """

    return !!document.body && isProbablyReaderable(document);
    """

    static let extractScript = bundled("Readability") + """

    const a = new Readability(document.cloneNode(true)).parse();
    return a && a.content ? { title: a.title || document.title, byline: a.byline, siteName: a.siteName, content: a.content } : null;
    """

    @MainActor
    static func isReaderable(_ webView: WKWebView) async -> Bool {
        guard let scheme = webView.url?.scheme, scheme == "http" || scheme == "https" || scheme == "file" else { return false }
        return (try? await webView.callAsyncJavaScript(checkScript, contentWorld: world)) as? Bool == true
    }

    @MainActor
    static func extract(_ webView: WKWebView) async -> Article? {
        guard let dict = (try? await webView.callAsyncJavaScript(extractScript, contentWorld: world)) as? [String: Any],
              let content = dict["content"] as? String else { return nil }
        func text(_ key: String) -> String? { (dict[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        return Article(title: text("title") ?? webView.title ?? "", byline: text("byline"), siteName: text("siteName"),
                       content: content, url: webView.url)
    }

    // MARK: Rendering

    struct Style: Equatable {
        var fontSize = 19
        var serif = true
        var theme = "light"
        var width = 680

        init() {}
        init(defaults d: UserDefaults) {
            if d.object(forKey: ReaderPrefs.fontSize) != nil { fontSize = d.integer(forKey: ReaderPrefs.fontSize) }
            serif = (d.string(forKey: ReaderPrefs.font) ?? "serif") != "sans"
            theme = d.string(forKey: ReaderPrefs.theme) ?? "light"
            if d.object(forKey: ReaderPrefs.width) != nil { width = d.integer(forKey: ReaderPrefs.width) }
        }

        var colors: (bg: String, fg: String, muted: String, link: String) {
            switch theme {
            case "sepia": return ("#f4ecd8", "#3b2f22", "#7a6650", "#8a4b12")
            case "dark": return ("#1c1c1e", "#e5e5e7", "#9a9aa0", "#7ab4ff")
            default: return ("#ffffff", "#1d1d1f", "#6e6e73", "#0a64d8")
            }
        }

        /// CSS custom properties, also applied live (no reload, scroll kept) by `applyScript`.
        var cssVariables: String {
            let c = colors
            let font = serif ? "'New York', 'Iowan Old Style', Georgia, serif" : "-apple-system, 'SF Pro Text', 'Helvetica Neue', sans-serif"
            return "--bg:\(c.bg);--fg:\(c.fg);--muted:\(c.muted);--link:\(c.link);--size:\(fontSize)px;--width:\(width)px;--font:\(font);"
        }
    }

    static let applyScript = "document.documentElement.setAttribute('style', vars);"

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The reader page. Scripts are off in the reader web view and the CSP allows no scripts,
    /// frames, fonts or fetches: only inline styles and images.
    static func html(for article: Article, style: Style) -> String {
        let meta = [article.siteName, article.byline].compactMap { $0 }.map(escape).joined(separator: " · ")
        return """
        <!doctype html><html style="\(style.cssVariables)"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; media-src https:; style-src 'unsafe-inline'">
        <title>\(escape(article.title))</title>
        <style>
        html { background: var(--bg); color: var(--fg); }
        body { margin: 0; padding: 56px 24px 96px; font: var(--size)/1.6 var(--font); -webkit-font-smoothing: antialiased; }
        main { max-width: var(--width); margin: 0 auto; }
        h1.luna-title { font-size: 1.9em; line-height: 1.2; margin: 0 0 .4em; }
        .luna-meta { color: var(--muted); font: 600 .75em -apple-system, sans-serif; margin-bottom: 2em; }
        a { color: var(--link); }
        img, video, figure { max-width: 100%; height: auto; }
        figure { margin: 1.5em 0; } figcaption { color: var(--muted); font-size: .8em; }
        pre, code { font: .85em ui-monospace, Menlo, monospace; } pre { overflow-x: auto; padding: 12px; background: rgba(127,127,127,.12); border-radius: 8px; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid var(--muted); color: var(--muted); }
        table { border-collapse: collapse; max-width: 100%; } td, th { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; }
        </style></head><body><main>
        <h1 class="luna-title">\(escape(article.title))</h1>
        \(meta.isEmpty ? "" : "<div class=\"luna-meta\">\(meta)</div>")
        \(article.content)
        </main></body></html>
        """
    }
}

/// Reader preferences (UserDefaults keys; registry entries `reader.*`).
enum ReaderPrefs {
    static let fontSize = "luna_reader_font_size"
    static let font = "luna_reader_font"
    static let theme = "luna_reader_theme"
    static let width = "luna_reader_width"
    static let fontSizes = 14...28
    static let widths = [560, 680, 820]
}

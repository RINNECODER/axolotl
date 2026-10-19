import SwiftUI
import WebKit

/// The reader for one tab, drawn over its page: the article in a script-less web view, with
/// font size, serif/sans, theme and width controls. Esc or the address-field button closes it.
struct ReaderView: View {
    let article: ReaderMode.Article
    let onClose: () -> Void
    let onOpenLink: (URL) -> Void

    @AppStorage(ReaderPrefs.fontSize) private var fontSize = 19
    @AppStorage(ReaderPrefs.font) private var font = "serif"
    @AppStorage(ReaderPrefs.theme) private var theme = "light"
    @AppStorage(ReaderPrefs.width) private var width = 680

    private var style: ReaderMode.Style {
        var s = ReaderMode.Style()
        s.fontSize = fontSize
        s.serif = font != "sans"
        s.theme = theme
        s.width = width
        return s
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ReaderWebView(article: article, style: style, onClose: onClose, onOpenLink: onOpenLink)
            ReaderControls(fontSize: $fontSize, font: $font, theme: $theme, width: $width, onClose: onClose)
                .padding(10)
        }
    }
}

/// − / + text size, serif / sans, light / sepia / dark, narrower / wider, close.
struct ReaderControls: View {
    @Binding var fontSize: Int
    @Binding var font: String
    @Binding var theme: String
    @Binding var width: Int
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            button("textformat.size.smaller", "Smaller text") { fontSize = max(ReaderPrefs.fontSizes.lowerBound, fontSize - 1) }
                .disabled(fontSize <= ReaderPrefs.fontSizes.lowerBound)
            button("textformat.size.larger", "Larger text") { fontSize = min(ReaderPrefs.fontSizes.upperBound, fontSize + 1) }
                .disabled(fontSize >= ReaderPrefs.fontSizes.upperBound)
            Divider().frame(height: 16)
            Picker("Font", selection: $font) {
                Text("Serif").tag("serif")
                Text("Sans").tag("sans")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Divider().frame(height: 16)
            ForEach([("light", Color.white, "Light"), ("sepia", Color(red: 0.96, green: 0.93, blue: 0.85), "Sepia"),
                     ("dark", Color(white: 0.11), "Dark")], id: \.0) { value, color, title in
                Button { theme = value } label: {
                    Circle().fill(color)
                        .overlay(Circle().strokeBorder(theme == value ? Color.accentColor : Color.primary.opacity(0.25),
                                                       lineWidth: theme == value ? 2 : 1))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("\(title) theme")
                .accessibilityLabel("\(title) theme")
                .accessibilityAddTraits(theme == value ? .isSelected : [])
            }
            Divider().frame(height: 16)
            let index = ReaderPrefs.widths.firstIndex(of: width) ?? 1
            button("arrow.right.and.line.vertical.and.arrow.left", "Narrower") { width = ReaderPrefs.widths[max(0, index - 1)] }
                .disabled(index == 0)
            button("arrow.left.and.line.vertical.and.arrow.right", "Wider") { width = ReaderPrefs.widths[min(ReaderPrefs.widths.count - 1, index + 1)] }
                .disabled(index == ReaderPrefs.widths.count - 1)
            Divider().frame(height: 16)
            button("xmark", "Close Reader (Esc)", action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }

    private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 20, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A web view with page scripts off that only shows the reader HTML; links open in the tab.
struct ReaderWebView: NSViewRepresentable {
    let article: ReaderMode.Article
    let style: ReaderMode.Style
    let onClose: () -> Void
    let onOpenLink: (URL) -> Void

    final class EscWebView: WKWebView {
        var onEscape: (() -> Void)?
        override func cancelOperation(_ sender: Any?) { onEscape?() }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.makeFirstResponder(self)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: ReaderWebView
        var shown: (article: ReaderMode.Article, style: ReaderMode.Style)?
        init(_ parent: ReaderWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = false
            // Only the reader document (and its #anchors) loads here; web links open in the tab.
            let url = action.request.url
            if url?.scheme == "about" { return (.allow, preferences) }
            if action.navigationType == .linkActivated, let url, url.scheme == "https" || url.scheme == "http" {
                parent.onOpenLink(url)
            }
            return (.cancel, preferences)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func makeWebView() -> EscWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        return EscWebView(frame: .zero, configuration: config)
    }

    func makeNSView(context: Context) -> EscWebView {
        let view = Self.makeWebView()
        view.navigationDelegate = context.coordinator
        view.setAccessibilityLabel("Reader")
        return view
    }

    func updateNSView(_ view: EscWebView, context: Context) {
        context.coordinator.parent = self
        view.onEscape = onClose
        let c = context.coordinator
        if c.shown?.article != article {
            view.loadHTMLString(ReaderMode.html(for: article, style: style), baseURL: nil)
        } else if c.shown?.style != style {
            // Restyle in place so the reading position stays.
            view.callAsyncJavaScript(ReaderMode.applyScript, arguments: ["vars": style.cssVariables], in: nil,
                                     in: ReaderMode.world, completionHandler: nil)
        }
        c.shown = (article, style)
    }
}

/// The reader button in the address field: shown on article pages, filled while reading.
struct ReaderChip: View {
    @ObservedObject var web: WebViewWrapper

    var body: some View {
        if let id = web.activeTab, web.readerableTabs.contains(id) {
            let on = web.readerArticleByTab[id] != nil
            Button { web.toggleReader(in: id) } label: {
                Image(systemName: on ? "doc.plaintext.fill" : "doc.plaintext")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(on ? "Close Reader (Esc)" : "Show Reader")
            .accessibilityLabel(on ? "Close Reader" : "Show Reader")
        }
    }
}

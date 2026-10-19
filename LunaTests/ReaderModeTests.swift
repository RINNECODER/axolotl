import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Luna

/// Reader mode on real offscreen web views: the button only for articles, the extracted
/// article, and (with LUNA_READER_SHOTS set) PNGs of the reader view.
@MainActor
final class ReaderModeTests: XCTestCase {
    static let paragraph = "The harbor town woke slowly, fog lifting off the water while the fishing boats came back with the night's catch. "
        + "Merchants opened their shutters, children ran down the cobbled streets, and the smell of bread drifted from the bakery on the corner."
    static let article = """
    <html><head><title>Morning in the Harbor Town | Example News</title><script>window.tracked = true</script></head><body>
    <nav><a href="/">Home</a> <a href="/world">World</a> <a href="/sports">Sports</a></nav>
    <article><h1>Morning in the Harbor Town</h1><p class="byline">By Ana Ruiz</p>
    \((1...8).map { "<p>\(paragraph) Part \($0) of the story continues here with more detail.</p>" }.joined())
    <p>Read <a href="https://example.com/more">more stories</a>.</p>
    </article><footer>© Example News</footer></body></html>
    """
    static let notArticle = """
    <html><head><title>Example Shop</title></head><body>
    <nav><a href="/">Home</a> <a href="/cart">Cart</a></nav><h1>Shop</h1>
    <ul><li><a href="/a">Shoes</a></li><li><a href="/b">Hats</a></li><li><a href="/c">Bags</a></li></ul>
    <button>Sign in</button></body></html>
    """

    private func spin(until done: () -> Bool, timeout: TimeInterval = 10) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testReaderButtonShowsOnlyOnArticlesAndOpensTheArticle() throws {
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let article = UUID(), shop = UUID()
        web.ensureWebView(for: article).loadHTMLString(Self.article, baseURL: URL(string: "https://example.com/news/harbor"))
        web.ensureWebView(for: shop).loadHTMLString(Self.notArticle, baseURL: URL(string: "https://example.com/shop"))
        spin(until: { web.readerableTabs.contains(article) })
        XCTAssertTrue(web.readerableTabs.contains(article))
        spin(until: { false }, timeout: 1)  // the shop page has had time to finish too
        XCTAssertFalse(web.readerableTabs.contains(shop), "no reader button on a non-article page")

        web.toggleReader(in: article)
        spin(until: { web.readerArticleByTab[article] != nil })
        let shown = try XCTUnwrap(web.readerArticleByTab[article])
        XCTAssertEqual(shown.title, "Morning in the Harbor Town")
        XCTAssertTrue(shown.content.contains("Part 8 of the story"))
        XCTAssertFalse(shown.content.contains("<script"))
        XCTAssertFalse(shown.content.contains("Cart"))

        web.toggleReader(in: article)
        XCTAssertNil(web.readerArticleByTab[article], "the same button closes Reader")
    }

    func testReaderPageEscapesMetadataAndAllowsNoScripts() {
        let html = ReaderMode.html(for: .init(title: "<script>x()</script>", byline: "A & B", content: "<p>Hi</p>"),
                                   style: .init())
        XCTAssertFalse(html.contains("<script>x()"))
        XCTAssertTrue(html.contains("A &amp; B"))
        XCTAssertTrue(html.contains("default-src 'none'"))
    }

    /// Renders the reader (article + controls) to PNGs when LUNA_READER_SHOTS names a folder.
    func testRenderReaderView() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_READER_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_READER_SHOTS to a folder name to render reader PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        print("Reader shots: \(dir.path)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = WKWebView()
        source.loadHTMLString(Self.article, baseURL: URL(string: "https://example.com/news/harbor"))
        spin(until: { !source.isLoading && source.url != nil })
        var article: ReaderMode.Article?
        Task { article = await ReaderMode.extract(source) }
        spin(until: { article != nil })
        let found = try XCTUnwrap(article)

        let size = NSSize(width: 1000, height: 700)
        for (theme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            var style = ReaderMode.Style()
            style.theme = theme
            let page = ReaderWebView.makeWebView()
            page.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: page.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = page
            page.loadHTMLString(ReaderMode.html(for: found, style: style), baseURL: nil)
            spin(until: { !page.isLoading })
            spin(until: { false }, timeout: 0.5)
            var shot: NSImage?
            page.takeSnapshot(with: nil) { image, _ in shot = image }
            spin(until: { shot != nil })

            let controls = NSHostingView(rootView: ReaderControls(fontSize: .constant(19), font: .constant("serif"),
                                                                  theme: .constant(theme), width: .constant(680), onClose: {}))
            controls.appearance = NSAppearance(named: appearance)
            controls.frame = NSRect(origin: .zero, size: controls.fittingSize)
            let bar = NSWindow(contentRect: controls.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            bar.contentView = controls
            controls.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            let rep = try XCTUnwrap(controls.bitmapImageRepForCachingDisplay(in: controls.bounds))
            controls.cacheDisplay(in: controls.bounds, to: rep)

            let out = NSImage(size: size)
            out.lockFocus()
            try XCTUnwrap(shot).draw(in: NSRect(origin: .zero, size: size))
            rep.draw(in: NSRect(x: size.width - controls.frame.width - 10, y: size.height - controls.frame.height - 10,
                                width: controls.frame.width, height: controls.frame.height))
            out.unlockFocus()
            let png = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(out.tiffRepresentation))?.representation(using: .png, properties: [:]))
            try png.write(to: dir.appendingPathComponent("reader-\(theme).png"))
            window.contentView = nil
            bar.contentView = nil
        }
    }
}

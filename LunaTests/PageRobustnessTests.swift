import XCTest
import WebKit
@testable import Luna

/// Error pages, link-click dispositions, the context menus and data: favicons.
@MainActor
final class PageRobustnessTests: XCTestCase {
    private let page = URL(string: "https://example.com/a")!

    private func urlError(_ code: Int) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: [NSURLErrorFailingURLErrorKey: page])
    }

    func testCancelledAndInterruptedLoadsShowNoErrorPage() {
        XCTAssertNil(PageError.classify(urlError(NSURLErrorCancelled), url: nil))
        // 102: frame load interrupted (a navigation became a download or was handled elsewhere).
        XCTAssertNil(PageError.classify(NSError(domain: "WebKitErrorDomain", code: 102), url: page))
    }

    func testNetworkFailuresMapToChromeKindsWithTheFailingHost() {
        let cases: [(Int, PageError.Kind)] = [
            (NSURLErrorNotConnectedToInternet, .noInternet),
            (NSURLErrorCannotFindHost, .dnsFailed),
            (NSURLErrorCannotConnectToHost, .connectionRefused),
            (NSURLErrorTimedOut, .timedOut),
            (NSURLErrorServerCertificateUntrusted, .secureConnectionFailed),
            (NSURLErrorBadServerResponse, .cantReach),
        ]
        for (code, kind) in cases {
            let error = PageError.classify(urlError(code), url: URL(string: "https://old.example/"))
            XCTAssertEqual(error?.kind, kind, "code \(code)")
            // The page that failed, not the one the web view still shows.
            XCTAssertEqual(error?.host, "example.com")
        }
    }

    func testModifierAndMiddleClicksOpenNewTabs() {
        XCTAssertNil(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: [], button: 1))
        XCTAssertEqual(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: .command, button: 1), false)
        XCTAssertEqual(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: [.command, .shift], button: 1), true)
        XCTAssertEqual(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: [], button: 4), false)
        // ⌘ held while a form submits or the page navigates itself is not a link click.
        XCTAssertNil(WebViewWrapper.newTabDisposition(type: .formSubmitted, modifiers: .command, button: 1))
    }

    func testTabMenuCloseCommandsSparePinnedTabs() {
        let pinned = UUID(), a = UUID(), b = UUID(), c = UUID()
        let order = [pinned, a, b, c]
        let sections = TabContextMenu.sections(for: b, order: order, persistent: [pinned],
                                               hasPage: true, hasSite: true, isMuted: true)
        XCTAssertEqual(sections.last, [.close(reset: false), .closeOthers, .closeToRight])
        XCTAssertTrue(sections.flatMap { $0 }.contains(.unmute))
        XCTAssertEqual(TabContextMenu.tabsToClose(.closeOthers, from: b, order: order, persistent: [pinned]), [a, c])
        XCTAssertEqual(TabContextMenu.tabsToClose(.closeToRight, from: a, order: order, persistent: [pinned]), [b, c])

        // Last tab: nothing to its right; a pinned tab resets and offers Unpin; no page → no Reload/Duplicate/Mute.
        let last = TabContextMenu.sections(for: c, order: order, persistent: [pinned], hasPage: true, hasSite: false, isMuted: false)
        XCTAssertFalse(last.flatMap { $0 }.contains(.closeToRight))
        let onPinned = TabContextMenu.sections(for: pinned, order: [pinned], persistent: [pinned],
                                               hasPage: false, hasSite: false, isMuted: false)
        XCTAssertEqual(onPinned, [[.newTabToRight], [.unpin], [.close(reset: true)]])
    }

    func testLinkAndImageMenusGainChromeItems() {
        let edits = LunaWebView.menuEdits(for: [LunaWebView.openLinkInNewWindowID, "WKMenuItemIdentifierCopyLink",
                                                LunaWebView.openImageInNewWindowID, LunaWebView.copyImageID])
        XCTAssertTrue(edits.contains(.insert(.openLinkInNewTab, before: LunaWebView.openLinkInNewWindowID)))
        XCTAssertTrue(edits.contains(.retitle(LunaWebView.openImageInNewWindowID, to: "Open Image in New Tab")))
        XCTAssertTrue(edits.contains(.insertAfter(.copyImageAddress, after: LunaWebView.copyImageID)))
        XCTAssertFalse(edits.contains(.insertAfter(.print, after: LunaWebView.reloadID)))
        XCTAssertEqual(LunaWebView.menuEdits(for: [LunaWebView.reloadID]), [.insertAfter(.print, after: LunaWebView.reloadID)])
    }

    func testDataURIFaviconsDecodeWithoutANetworkRequest() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let b64 = URL(string: "data:image/png;base64," + png.base64EncodedString())!
        XCTAssertEqual(FaviconCache.decodeDataURI(b64), png)
        // Unpadded base64, as some sites emit.
        let unpadded = URL(string: "data:image/png;base64," + png.base64EncodedString().replacingOccurrences(of: "=", with: ""))!
        XCTAssertEqual(FaviconCache.decodeDataURI(unpadded), png)
        let svg = URL(string: "data:image/svg+xml,%3Csvg%20xmlns='http://www.w3.org/2000/svg'/%3E")!
        XCTAssertEqual(FaviconCache.decodeDataURI(svg).flatMap { String(data: $0, encoding: .utf8) },
                       "<svg xmlns='http://www.w3.org/2000/svg'/>")
        XCTAssertNil(FaviconCache.decodeDataURI(URL(string: "https://example.com/favicon.ico")!))
    }

    func testMuteIsPerSiteIgnoringWWW() {
        XCTAssertEqual(WebViewWrapper.siteKey(URL(string: "https://www.YouTube.com/watch")), "youtube.com")
        XCTAssertNil(WebViewWrapper.siteKey(URL(string: "about:blank")))
    }
}

import XCTest
import WebKit
@testable import Axolotl

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

    func testBlockedPortShowsAnErrorPage() {
        // http://127.0.0.1:1: WebKit refuses restricted ports itself (103) before connecting.
        let error = PageError.classify(NSError(domain: "WebKitErrorDomain", code: 103), url: URL(string: "http://127.0.0.1:1/"))
        XCTAssertEqual(error?.kind, .cantReach)
        XCTAssertEqual(error?.host, "127.0.0.1")
    }

    func testOnlySavedOrUnshowableResponsesDownload() {
        func policy(_ mime: String?, status: Int? = 200, disposition: String? = nil, main: Bool = true,
                    canShow: Bool = true) -> WKNavigationResponsePolicy {
            WebViewWrapper.responsePolicy(url: URL(string: "http://127.0.0.1:8080/x"), mimeType: mime, statusCode: status,
                                          contentDisposition: disposition, isMainFrame: main, canShowMIMEType: canShow)
        }
        // No MIME type or an error status displays (WebKit can't "show" an empty type).
        XCTAssertEqual(policy(nil, canShow: false), .allow)
        XCTAssertEqual(policy("", status: nil, canShow: false), .allow)
        XCTAssertEqual(policy("application/octet-stream", status: 502, canShow: false), .allow)
        XCTAssertEqual(policy("text/html"), .allow)
        // Real downloads still download.
        XCTAssertEqual(policy("text/html", disposition: "attachment; filename=a.html"), .download)
        XCTAssertEqual(policy("application/zip", canShow: false), .download)
        XCTAssertEqual(policy("image/png"), .download)
        XCTAssertEqual(policy("image/png", main: false), .allow)
    }

    func testModifierAndMiddleClicksOpenNewTabs() {
        XCTAssertNil(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: [], button: 1))
        XCTAssertEqual(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: .command, button: 1), false)
        XCTAssertEqual(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: [.command, .shift], button: 1), true)
        XCTAssertEqual(WebViewWrapper.newTabDisposition(type: .linkActivated, modifiers: [], button: 4), false)
        // ⌘ held while a form submits or the page navigates itself is not a link click.
        XCTAssertNil(WebViewWrapper.newTabDisposition(type: .formSubmitted, modifiers: .command, button: 1))
    }

    func testWebPagesCannotOpenFileURLsInNewTabs() {
        let file = URL(fileURLWithPath: "/etc/hosts")
        XCTAssertFalse(WebViewWrapper.canOpenInNewTab(file, from: URL(string: "https://evil.example/")))
        XCTAssertFalse(WebViewWrapper.canOpenInNewTab(file, from: nil))
        XCTAssertTrue(WebViewWrapper.canOpenInNewTab(file, from: URL(fileURLWithPath: "/tmp/index.html")))
        XCTAssertTrue(WebViewWrapper.canOpenInNewTab(URL(string: "https://a.example/")!, from: nil))
        XCTAssertFalse(WebViewWrapper.canOpenInNewTab(URL(string: "javascript:alert(1)")!, from: nil))
    }

    func testPopupsNeedAUserGestureAndAreCappedPerMinute() {
        let now = Date()
        XCTAssertFalse(WebViewWrapper.allowsPopup(userActivated: false, recent: [], now: now))
        XCTAssertTrue(WebViewWrapper.allowsPopup(userActivated: true, recent: Array(repeating: now, count: 4), now: now))
        XCTAssertFalse(WebViewWrapper.allowsPopup(userActivated: true, recent: Array(repeating: now, count: 5), now: now))
        // Popups older than a minute no longer count.
        XCTAssertTrue(WebViewWrapper.allowsPopup(userActivated: true, recent: Array(repeating: now - 61, count: 5), now: now))
    }

    func testPrivateNetworkHosts() {
        for host in ["localhost", "127.0.0.1", "10.1.2.3", "192.168.0.1", "172.20.0.1", "169.254.1.1", "printer.local", "[::1]", "fd00::1"] {
            XCTAssertTrue(WebViewWrapper.isPrivateNetworkHost(host), host)
        }
        for host in ["example.com", "8.8.8.8", "172.32.0.1", "fd.example.com", "fcbarcelona.com"] {
            XCTAssertFalse(WebViewWrapper.isPrivateNetworkHost(host), host)
        }
    }

    func testHistoryCapsPageControlledTitleAndURL() {
        let profile = UUID()
        defer {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Axolotl/Profiles/\(profile.uuidString)")
            try? FileManager.default.removeItem(at: dir)
        }
        let history = HistoryManager(profileId: profile)
        history.recordPageVisit(url: URL(string: "https://a.example/?q=" + String(repeating: "x", count: 5000))!,
                                title: String(repeating: "t", count: 1000))
        XCTAssertEqual(history.historyEvents.first?.url?.count, 2000)
        XCTAssertEqual(history.historyEvents.first?.pageTitle?.count, 300)
        history.flush()
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
        let edits = AxolotlWebView.menuEdits(for: [AxolotlWebView.openLinkInNewWindowID, "WKMenuItemIdentifierCopyLink",
                                                AxolotlWebView.openImageInNewWindowID, AxolotlWebView.copyImageID])
        XCTAssertTrue(edits.contains(.insert(.openLinkInNewTab, before: AxolotlWebView.openLinkInNewWindowID)))
        XCTAssertTrue(edits.contains(.retitle(AxolotlWebView.openImageInNewWindowID, to: "Open Image in New Tab")))
        XCTAssertTrue(edits.contains(.insertAfter(.copyImageAddress, after: AxolotlWebView.copyImageID)))
        XCTAssertFalse(edits.contains(.insertAfter(.print, after: AxolotlWebView.reloadID)))
        XCTAssertEqual(AxolotlWebView.menuEdits(for: [AxolotlWebView.reloadID]), [.insertAfter(.print, after: AxolotlWebView.reloadID)])
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

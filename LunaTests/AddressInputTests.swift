import XCTest
@testable import Luna

final class AddressInputTests: XCTestCase {
    private func resolved(_ text: String) -> String? {
        AddressInput.url(for: text, engine: .duckduckgo)?.absoluteString
    }

    func testLocalHostsAndHostPortOpenOverHTTP() {
        for input in ["localhost", "localhost:3000", "localhost:8080/api?x=1", "printer.local", "nas.local:5000/admin",
                      "127.0.0.1", "10.0.0.5", "172.16.4.2", "172.31.255.1", "192.168.1.1:8080", "169.254.10.1",
                      "[::1]", "[::1]:8080/path", "[fe80::1]", "[fd12:3456::1]:443", "devbox:8000", "example.com:8443"] {
            XCTAssertEqual(resolved(input), "http://" + input, input)
        }
    }

    func testPublicHostsStayHTTPSAndPlainWordsSearch() {
        XCTAssertEqual(resolved("example.com"), "https://example.com")
        XCTAssertEqual(resolved("8.8.8.8"), "https://8.8.8.8")
        XCTAssertEqual(resolved("172.32.0.1"), "https://172.32.0.1")
        XCTAssertEqual(resolved("[2001:db8::1]"), "https://[2001:db8::1]")
        XCTAssertEqual(resolved("https://localhost:3000"), "https://localhost:3000")
        XCTAssertEqual(resolved("luma://history"), "luma://history")
        XCTAssertEqual(resolved("swift"), "https://duckduckgo.com/?q=swift")
        XCTAssertEqual(resolved("mailto:x"), "https://duckduckgo.com/?q=mailto:x")
        XCTAssertEqual(resolved("localhost is down"), "https://duckduckgo.com/?q=localhost%20is%20down")
        XCTAssertEqual(resolved("host:99999"), "https://duckduckgo.com/?q=host:99999")
        XCTAssertNil(resolved("   "))
    }

    func testEachEngineSuggestsFromItsOwnEndpoint() {
        let hosts = SearchEngine.allCases.map { $0.suggestURL(for: "a b")?.host }
        XCTAssertEqual(hosts, ["suggestqueries.google.com", "ac.duckduckgo.com", "www.bing.com", "search.brave.com", "ac.ecosia.org"])
        XCTAssertTrue(SearchEngine.bing.suggestURL(for: "a b")!.absoluteString.contains("query=a%20b"))
    }

    func testSearchQueryKeepsReservedCharactersInsideTheValue() {
        let url = SearchEngine.google.searchURL(for: "AT&T stock C++ a=b?#/")!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(q, "AT&T stock C++ a=b?#/")
        let suggest = SearchEngine.duckduckgo.suggestURL(for: "C++")!
        XCTAssertEqual(URLComponents(url: suggest, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "C++")
    }

    func testShortcutsAcceptOnlyWebURLs() {
        XCTAssertEqual(SiteShortcut.siteURL(from: "github.com")?.absoluteString, "https://github.com")
        XCTAssertEqual(SiteShortcut.siteURL(from: "http://example.com/a")?.absoluteString, "http://example.com/a")
        XCTAssertNil(SiteShortcut.siteURL(from: "javascript://example.com/%0Aalert(1)"))
        XCTAssertNil(SiteShortcut.siteURL(from: "file://example.com/etc/passwd"))
        XCTAssertNil(SiteShortcut.siteURL(from: "ftp://example.com"))
    }

    func testLargePasteKeepsTypedTextAndLeavesURLsAsText() {
        let big = String(repeating: "lorem ipsum ", count: 40)
        let split = LargePaste.split(old: "summarize ", new: "summarize " + big)
        XCTAssertEqual(split?.kept, "summarize ")
        XCTAssertEqual(split?.pasted, big)
        XCTAssertEqual(LargePaste.split(old: "ab", new: "a" + big + "b")?.kept, "ab")
        let longURL = "https://example.com/search?q=" + String(repeating: "x", count: 400)
        XCTAssertNil(LargePaste.split(old: "", new: longURL))
        XCTAssertFalse(LargePaste.shouldAttach(longURL))
        XCTAssertTrue(LargePaste.shouldAttach(big))
        XCTAssertNil(LargePaste.split(old: "", new: "short"))
    }

    func testSuggestionsPutBookmarksFirstDedupeAndOfferOpenTabs() {
        let docs = URL(string: "https://docs.swift.org/")!
        let forum = URL(string: "https://forums.swift.org")!
        let blog = URL(string: "https://swift.org/blog")!
        let tabId = UUID()
        let rows = AddressSuggestions.merge(
            query: "swift",
            bookmarks: [Bookmark(title: "Swift Docs", url: docs), Bookmark(title: "Cooking", url: URL(string: "https://food.example")!)],
            history: [(display: "Docs", url: URL(string: "https://docs.swift.org")!), (display: "Forums", url: forum)],
            openTabs: [(id: tabId, title: "Swift Blog", url: blog), (id: UUID(), title: "Mail", url: URL(string: "https://mail.example")!)])
        XCTAssertEqual(rows.map(\.url), [docs, forum, blog])
        XCTAssertEqual(rows.map(\.kind), [.bookmark, .history, .openTab(tabId)])

        // A history page that is already open becomes "Switch to tab", not a second row.
        let open = AddressSuggestions.merge(query: "forums", bookmarks: [], history: [(display: "Forums", url: forum)],
                                            openTabs: [(id: tabId, title: "Forums", url: forum)])
        XCTAssertEqual(open.map(\.kind), [.openTab(tabId)])
    }
}

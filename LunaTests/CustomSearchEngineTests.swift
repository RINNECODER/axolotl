import XCTest
@testable import Luna

final class CustomSearchEngineTests: XCTestCase {
    private let yt = CustomSearchEngine(name: "YouTube", keyword: "yt", template: "https://www.youtube.com/results?search_query=%s")

    func testTemplateMustBeHTTPWithPlaceholder() {
        XCTAssertTrue(CustomSearchEngine.isValidTemplate("https://a.com/s?q=%s"))
        XCTAssertTrue(CustomSearchEngine.isValidTemplate("http://a.com/%s"))
        XCTAssertFalse(CustomSearchEngine.isValidTemplate("https://a.com/s?q="))
        XCTAssertFalse(CustomSearchEngine.isValidTemplate("javascript:alert(%s)"))
        XCTAssertFalse(CustomSearchEngine.isValidTemplate("file:///tmp/%s"))
        XCTAssertFalse(CustomSearchEngine.isValidTemplate("https:///%s"))
    }

    func testExpansionEncodesTheWholeQuery() {
        XCTAssertEqual(yt.searchURL(for: "cats & dogs #1+2/3")?.absoluteString,
                       "https://www.youtube.com/results?search_query=cats%20%26%20dogs%20%231%2B2%2F3")
        XCTAssertNil(CustomSearchEngine(name: "x", keyword: "x", template: "ftp://a/%s").searchURL(for: "q"))
    }

    func testKeywordParsing() {
        XCTAssertEqual(CustomSearchEngine.keywordSearch("YT  funny cats ", in: [yt])?.query, "funny cats")
        XCTAssertNil(CustomSearchEngine.keywordSearch("yt", in: [yt]))
        XCTAssertNil(CustomSearchEngine.keywordSearch("yt   ", in: [yt]))
        XCTAssertNil(CustomSearchEngine.keywordSearch("ytx cats", in: [yt]))
        XCTAssertNil(CustomSearchEngine.keywordSearch("cats yt", in: [yt]))
    }

    func testResolutionKeywordThenCustomDefaultThenBuiltIn() throws {
        let suite = "CustomSearchEngineTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ddg = CustomSearchEngine(name: "Mine", keyword: "m", template: "https://mine.example/?q=%s")
        CustomSearchEngine.save([yt, ddg], defaults)

        XCTAssertEqual(SearchEngine.url(searching: "yt cats", defaults: defaults)?.host, "www.youtube.com")
        XCTAssertEqual(SearchEngine.url(searching: "cats", defaults: defaults)?.host, "www.google.com")
        defaults.set(ddg.selectionValue, forKey: SearchEngine.defaultsKey)
        XCTAssertEqual(SearchEngine.selectedCustom(defaults), ddg)
        XCTAssertEqual(SearchEngine.url(searching: "cats", defaults: defaults)?.absoluteString, "https://mine.example/?q=cats")
        XCTAssertEqual(SearchEngine.url(searching: "cats", engine: .bing, defaults: defaults)?.host, "www.bing.com")

        // Removing the default engine falls back to Google.
        CustomSearchEngine.save([yt], defaults)
        XCTAssertEqual(defaults.string(forKey: SearchEngine.defaultsKey), SearchEngine.google.rawValue)
        XCTAssertNil(SearchEngine.selectedCustom(defaults))
    }
}

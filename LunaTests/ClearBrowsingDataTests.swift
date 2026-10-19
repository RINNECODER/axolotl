import WebKit
import XCTest
@testable import Luna

final class ClearBrowsingDataTests: XCTestCase {
    func testCheckboxesPickWebKitDataTypes() {
        let all = WKWebsiteDataStore.allWebsiteDataTypes()
        let siteData = ClearBrowsingDataSheet.websiteDataTypes(siteData: true, cache: false)
        let cache = ClearBrowsingDataSheet.websiteDataTypes(siteData: false, cache: true)

        XCTAssertTrue(siteData.contains(WKWebsiteDataTypeCookies))
        XCTAssertTrue(siteData.contains(WKWebsiteDataTypeLocalStorage))
        XCTAssertFalse(siteData.contains(WKWebsiteDataTypeDiskCache))
        XCTAssertEqual(cache, all.intersection([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
                                                WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeOfflineWebApplicationCache]))
        XCTAssertFalse(cache.contains(WKWebsiteDataTypeCookies))
        XCTAssertEqual(ClearBrowsingDataSheet.websiteDataTypes(siteData: true, cache: true), all)
        XCTAssertTrue(ClearBrowsingDataSheet.websiteDataTypes(siteData: false, cache: false).isEmpty)
    }
}

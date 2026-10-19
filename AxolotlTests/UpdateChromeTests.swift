import XCTest
@testable import Axolotl

@MainActor
final class UpdateChromeTests: XCTestCase {
    private func titles(_ entries: [AxolotlMenuEntry]) -> [String] {
        entries.compactMap { if case .item(let item) = $0 { return item.title } else { return nil } }
    }

    func testReadyUpdateShowsPillAndRelaunchItem() {
        XCTAssertTrue(UpdateChrome.showsPill(.ready, isDevBuild: false))
        XCTAssertEqual(titles(UpdateChrome.menuEntries(.ready, isDevBuild: false) {}), ["Relaunch to update"])
    }

    func testNoUpdateShowsNothing() {
        for status: UpdateStatus in [.idle, .checking, .upToDate, .failed("x")] {
            XCTAssertFalse(UpdateChrome.showsPill(status, isDevBuild: false), "\(status)")
            XCTAssertTrue(UpdateChrome.menuEntries(status, isDevBuild: false) {}.isEmpty, "\(status)")
        }
    }

    func testDevBuildNeverShowsUpdateUI() {
        XCTAssertFalse(UpdateChrome.showsPill(.ready, isDevBuild: true))
        XCTAssertTrue(UpdateChrome.menuEntries(.ready, isDevBuild: true) {}.isEmpty)
    }

    func testRelaunchItemRunsInstall() {
        var installed = false
        guard case .item(let item)? = UpdateChrome.menuEntries(.ready, isDevBuild: false, action: { installed = true }).first
        else { return XCTFail("no relaunch item") }
        item.action?()
        XCTAssertTrue(installed)
    }
}

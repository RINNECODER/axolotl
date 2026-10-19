import XCTest
@testable import Axolotl

@MainActor
final class AxolotlMaxTests: XCTestCase {
    func testCleanTitleStripsQuotesAndRejectsRambling() {
        XCTAssertEqual(AxolotlMax.cleanTitle("\"Swift Docs\"\n", fallback: "x"), "Swift Docs")
        XCTAssertEqual(AxolotlMax.cleanTitle("Title: GitHub Issues.", fallback: "x"), "GitHub Issues")
        XCTAssertEqual(AxolotlMax.cleanTitle("", fallback: "Original"), "Original")
        XCTAssertEqual(AxolotlMax.cleanTitle(String(repeating: "word ", count: 20), fallback: "Original"), "Original")
    }

    func testCleanFilenameKeepsExtensionAndRemovesIllegalCharacters() {
        XCTAssertEqual(AxolotlMax.cleanFilename("Q3 Report: Final/v2", original: "dl_8812.pdf"), "Q3 Report- Final-v2.pdf")
        XCTAssertEqual(AxolotlMax.cleanFilename("Invoice March.pdf", original: "x.pdf"), "Invoice March.pdf")
        XCTAssertEqual(AxolotlMax.cleanFilename("  ", original: "keep.zip"), "keep.zip")
        XCTAssertEqual(AxolotlMax.cleanFilename("Notes", original: "README"), "Notes")
    }

    func testParseGroupsToleratesFencesAndDropsBadGroups() {
        let tabs = (0..<5).map { AxolotlMax.TabSummary(id: UUID(), title: "t\($0)", host: "h") }
        let raw = """
        Here you go:
        ```json
        [{"name": "Shopping", "tabs": [0, 2]},
         {"name": "Solo", "tabs": [1]},
         {"name": "Dupes", "tabs": [2, 3, "4", 99]}]
        ```
        """
        let groups = AxolotlMax.parseGroups(raw, tabs: tabs)
        XCTAssertEqual(groups.map(\.name), ["Shopping", "Dupes"])
        XCTAssertEqual(groups[0].tabIds, [tabs[0].id, tabs[2].id])
        XCTAssertEqual(groups[1].tabIds, [tabs[3].id, tabs[4].id], "tab 2 already used; 99 out of range")
        XCTAssertEqual(AxolotlMax.parseGroups("not json", tabs: tabs), [])
    }

    func testApplyTidyGroupsMakesFoldersInOneUndoStep() {
        let store = WorkspaceStore(persistence: nil)
        store.undoManager.groupsByEvent = false
        let ids = (0..<4).map { store.newTab(url: URL(string: "https://s\($0).com")) }
        store.applyTidyGroups([AxolotlMax.Group(name: "Work", tabIds: [ids[1], ids[3]])], inSpace: store.activeSpace.id)
        XCTAssertEqual(store.activeSpace.today.count, 3)
        XCTAssertEqual(store.workspace.location(ofNode: ids[3])?.parentFolderId != nil, true)
        XCTAssertEqual(store.workspace.integrityProblems(), [])
        store.undoManager.undo()
        XCTAssertEqual(store.activeSpace.today, ids.map { .tab($0) })
    }

    func testBlankPageTitleShowsAsNewTab() {
        let store = WorkspaceStore(persistence: nil)
        let id = store.newTab(url: URL(string: "about:blank"))
        store.updateTitle(id, "about:blank")
        XCTAssertEqual(displayTitle(for: store.tab(id)!), "New Tab")
    }

    func testCustomTitleWinsOverPageTitleAndCanBeCleared() {
        let store = WorkspaceStore(persistence: nil)
        let id = store.newTab(url: URL(string: "https://example.com"))
        store.updateTitle(id, "Example Domain — a very long page title")
        store.setCustomTitle(id, "Example")
        XCTAssertEqual(displayTitle(for: store.tab(id)!), "Example")
        store.updateTitle(id, "Navigated")
        XCTAssertEqual(displayTitle(for: store.tab(id)!), "Example")
        store.setCustomTitle(id, nil)
        XCTAssertEqual(displayTitle(for: store.tab(id)!), "Navigated")
    }

    func testPinningNotifiesOnceForTidyTitles() {
        let store = WorkspaceStore(persistence: nil)
        let id = store.newTab(url: URL(string: "https://example.com"))
        var pinned: [UUID] = []
        store.onTabPinned = { pinned.append($0) }
        store.pin(id)
        store.moveToFavorites(id) // already persistent: no second notification
        XCTAssertEqual(pinned, [id])
    }
}

import XCTest
@testable import Luna

final class BookmarkFolderTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bookmarks-\(UUID().uuidString).json")
    }

    /// A file from before folders (no parentId/isFolder keys) loads every bookmark onto the bar, and saves back readable.
    func testMigratesFlatFile() throws {
        let file = tempFile()
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","title":"GitHub","url":"https:\/\/github.com"}]"#
        try Data(old.utf8).write(to: file)
        let store = BookmarkStore(fileURL: file)
        XCTAssertEqual(store.children(of: nil).map(\.id), [id])
        XCTAssertFalse(store.items[0].isFolder)
        XCTAssertTrue(store.contains(URL(string: "https://github.com/")!))

        let folder = store.addFolder("Work")
        store.move(id, to: folder)
        let reloaded = BookmarkStore(fileURL: file)
        XCTAssertEqual(reloaded.children(of: folder).map(\.title), ["GitHub"])
        XCTAssertEqual(reloaded.folders.map(\.title), ["Work"])
    }

    func testOrphanReturnsToBar() throws {
        let file = tempFile()
        let json = #"[{"id":"\#(UUID().uuidString)","title":"A","url":"https:\/\/a.com","parentId":"\#(UUID().uuidString)"}]"#
        try Data(json.utf8).write(to: file)
        XCTAssertEqual(BookmarkStore(fileURL: file).children(of: nil).map(\.title), ["A"])
    }

    func testFolderOps() {
        let store = BookmarkStore(fileURL: tempFile())
        let a = store.add(url: URL(string: "https://a.com")!, title: "A")
        let b = store.add(url: URL(string: "https://b.com")!, title: "B")
        let folder = store.addFolder("F")
        let inner = store.addFolder("Inner", in: folder)
        let c = store.add(url: URL(string: "https://c.com")!, title: "C", in: inner)

        // Reorder on the bar: B before A.
        store.move(b, to: nil, before: a)
        XCTAssertEqual(store.children(of: nil).map(\.title), ["B", "A", "F"])
        // Into Other bookmarks, at the end.
        store.move(a, to: BookmarkStore.otherBookmarksId)
        XCTAssertEqual(store.children(of: BookmarkStore.otherBookmarksId).map(\.id), [a])
        // A folder can't move inside itself.
        store.move(folder, to: inner)
        XCTAssertNil(store.item(folder)?.parentId)

        store.update(c, title: "  ", url: BookmarkMenus.parseURL("example.com"))
        XCTAssertEqual(store.item(c)?.title, "C")
        XCTAssertEqual(store.item(c)?.url.absoluteString, "https://example.com")
        XCTAssertEqual(store.search("exam").map(\.id), [c])

        // Deleting a folder deletes what's inside.
        store.remove(folder)
        XCTAssertNil(store.item(inner))
        XCTAssertNil(store.item(c))
        XCTAssertEqual(store.bookmarks.map(\.title).sorted(), ["A", "B"])
    }

    func testBarOverflowCount() {
        XCTAssertEqual(BookmarksBar.fittingCount([50, 50, 50], in: 160, spacing: 2, overflowWidth: 28), 3)
        // 50+2+50 = 102, +2+28 = 132 fits; a third chip would not.
        XCTAssertEqual(BookmarksBar.fittingCount([50, 50, 50, 50], in: 160, spacing: 2, overflowWidth: 28), 2)
        XCTAssertEqual(BookmarksBar.fittingCount([200], in: 100, spacing: 2, overflowWidth: 28), 0)
    }

    func testTabSearchFilter() {
        let items = [
            TabSearchItem(id: UUID(), title: "Pull requests", url: URL(string: "https://github.com/pulls")),
            TabSearchItem(id: UUID(), title: "Hacker News", url: URL(string: "https://news.ycombinator.com")),
            TabSearchItem(id: UUID(), title: "GitHub Docs", url: URL(string: "https://docs.github.com")),
        ]
        XCTAssertEqual(TabSearch.filter(items, query: "").count, 3)
        // Substring in the title beats a match only in the host.
        XCTAssertEqual(TabSearch.filter(items, query: "github").map(\.title), ["GitHub Docs", "Pull requests"])
        // Fuzzy: letters in order.
        XCTAssertEqual(TabSearch.filter(items, query: "hknws").map(\.title), ["Hacker News"])
        XCTAssertTrue(TabSearch.filter(items, query: "zzz").isEmpty)
    }
}

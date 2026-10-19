import XCTest
@testable import Luna

/// Chrome tab groups are Workspace folders with a color.
@MainActor
final class TabGroupTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(persistence: nil)
        store.undoManager.groupsByEvent = false
        return store
    }
    private func url(_ s: String) -> URL { URL(string: "https://\(s).com")! }

    func testNewGroupAddMoveRemoveAndColors() throws {
        let store = makeStore()
        let a = store.newTab(url: url("a")), b = store.newTab(url: url("b")), c = store.newTab(url: url("c"))
        let g1 = try XCTUnwrap(store.addToNewTabGroup(b))
        XCTAssertEqual(store.workspace.tabGroup(containing: b)?.groupColor, .grey, "first unused color")
        XCTAssertEqual(store.activeSpace.today.map(\.id), [a, g1, c], "group sits where the tab was")

        store.addToTabGroup(c, group: g1)
        XCTAssertEqual(store.workspace.tabGroup(containing: c)?.tabIds, [b, c])

        let g2 = try XCTUnwrap(store.addToNewTabGroup(a))
        XCTAssertEqual(store.workspace.tabGroups.first { $0.id == g2 }?.groupColor, .blue)
        store.setTabGroupColor(g2, .orange)
        XCTAssertEqual(store.workspace.tabGroup(containing: a)?.groupColor, .orange)

        // Removing lands the tab just after its group; the emptied group disappears.
        store.removeFromTabGroup(b)
        XCTAssertEqual(store.activeSpace.today.map(\.id), [g2, g1, b])
        store.removeFromTabGroup(c)
        XCTAssertEqual(store.workspace.tabGroups.map(\.id), [g2])
        XCTAssertEqual(store.workspace.integrityProblems(), [])

        // Pinned tabs don't group (Chrome).
        store.pin(b)
        XCTAssertNil(store.addToNewTabGroup(b))
        XCTAssertTrue(TabContextMenu.groupItems(for: b, store: store).isEmpty)
    }

    func testMenuOffersOtherGroupsAndUndo() throws {
        let store = makeStore()
        let a = store.newTab(url: url("a")), b = store.newTab(url: url("b"))
        let before = store.activeSpace.today
        let g = try XCTUnwrap(store.addToNewTabGroup(a))
        store.renameFolder(g, to: "Work")
        let items = TabContextMenu.groupItems(for: b, store: store)
        XCTAssertEqual(items.map(\.command.title), ["Add Tab to New Group", "Add Tab to Group"])
        XCTAssertEqual(items[1].children.map(\.command.title), ["Work"])
        items[1].children[0].action()
        XCTAssertEqual(store.workspace.tabGroup(containing: b)?.id, g)
        XCTAssertEqual(TabContextMenu.groupItems(for: b, store: store).map(\.command.title),
                       ["Add Tab to New Group", "Remove from Group"])
        while store.activeSpace.today != before, store.undoManager.canUndo { store.undoManager.undo() }
        XCTAssertEqual(store.activeSpace.today, before)
    }

    func testOldFolderJSONDecodesAndRepairDropsUnknownColor() throws {
        let tab = UUID(), folder = UUID()
        let legacy = #"{"id":"\#(folder)","name":"Old","isExpanded":false,"children":[{"type":"tab","id":"\#(tab)"}]}"#
        let old = try JSONDecoder().decode(Folder.self, from: Data(legacy.utf8))
        XCTAssertNil(old.color)
        XCTAssertEqual(old.groupColor, .grey)
        XCTAssertEqual(old.tabIds, [tab])

        var future = Folder(name: "New", color: .cyan)
        let round = try JSONDecoder().decode(Folder.self, from: JSONEncoder().encode(future))
        XCTAssertEqual(round, future)

        future.color = "chartreuse" // from a newer build: decodes, shows grey, repair clears it
        var ws = Workspace()
        ws.spaces[0].today = [.folder(future)]
        let decoded = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        XCTAssertEqual(decoded.tabGroups.first?.groupColor, .grey)
        var repaired = decoded
        repaired.repair()
        XCTAssertNil(repaired.tabGroups.first?.color)
    }
}

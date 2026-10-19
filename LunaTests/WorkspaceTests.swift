import XCTest
@testable import Luna

@MainActor
final class WorkspaceTests: XCTestCase {
    private func makeStore() -> WorkspaceStore {
        let store = WorkspaceStore(persistence: nil)
        store.undoManager.groupsByEvent = false
        return store
    }
    private func url(_ s: String) -> URL { URL(string: "https://\(s).com")! }

    private func assertValid(_ store: WorkspaceStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(store.workspace.integrityProblems(), [], file: file, line: line)
    }

    // MARK: Tabs

    func testNewTabsAppendToTodayAndActivate() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        XCTAssertEqual(store.orderedTabIds, [a, b])
        XCTAssertEqual(store.activeTabId, b)
        XCTAssertEqual(store.activeSpace.today, [.tab(a), .tab(b)])
        assertValid(store)
    }

    func testClosingActiveTabSelectsPreviousThenNext() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        store.activate(b)
        XCTAssertEqual(store.close(b), .removed)
        XCTAssertEqual(store.activeTabId, a)
        store.activate(a)
        store.close(a)
        XCTAssertEqual(store.activeTabId, c)
        store.close(c)
        XCTAssertNil(store.activeTabId)
        XCTAssertTrue(store.orderedTabIds.isEmpty)
        assertValid(store)
    }

    func testClosingPinnedTabResetsInsteadOfRemoving() {
        let store = makeStore()
        let a = store.newTab(url: url("home"))
        store.pin(a)
        store.updateURL(a, url("elsewhere"))
        XCTAssertEqual(store.close(a), .reset)
        XCTAssertEqual(store.tab(a)?.url, url("home"))
        XCTAssertEqual(store.activeSpace.pinned, [.tab(a)])
        assertValid(store)
    }

    func testReopenClosedTabRestoresPosition() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        store.close(b)
        XCTAssertEqual(store.reopenClosedTab(), b)
        XCTAssertEqual(store.orderedTabIds, [a, b, c])
        XCTAssertEqual(store.activeTabId, b)
        XCTAssertEqual(store.workspace.archive.first?.tab.id, b)
        assertValid(store)
    }

    func testReopenSkipsTabsAlreadyRestoredByUndo() {
        let store = makeStore()
        _ = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        store.close(b)
        store.undoManager.undo()
        XCTAssertNotNil(store.tab(b))
        XCTAssertNil(store.reopenClosedTab())
        assertValid(store)
    }

    // MARK: Favorites & pinning

    func testFavoritesComeFirstAndReorder() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        store.moveToFavorites(c)
        store.moveToFavorites(a)
        XCTAssertEqual(store.orderedTabIds, [c, a, b])
        store.moveToFavorites(a, at: 0)
        XCTAssertEqual(store.workspace.favorites, [a, c])
        XCTAssertTrue(store.workspace.isPersistent(a))
        assertValid(store)
    }

    func testPinAndUnpin() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        store.pin(b)
        XCTAssertEqual(store.orderedTabIds, [b, a])
        XCTAssertEqual(store.tab(b)?.savedURL, url("b"))
        store.unpin(b)
        XCTAssertEqual(store.activeSpace.today, [.tab(b), .tab(a)])
        XCTAssertNil(store.tab(b)?.savedURL)
        assertValid(store)
    }

    // MARK: Moving

    func testMoveWithinSameListAccountsForRemoval() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        let sid = store.activeSpace.id
        // Drop `a` before index 2 (i.e. before `c`).
        store.move(a, to: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 2))
        XCTAssertEqual(store.orderedTabIds, [b, a, c])
        store.move(c, to: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 0))
        XCTAssertEqual(store.orderedTabIds, [c, b, a])
        assertValid(store)
    }

    func testFacadeMoveTabMatchesOldSemantics() {
        let manager = TabManager()
        let a = manager.newTab(url: url("a"))
        let b = manager.newTab(url: url("b"))
        let c = manager.newTab(url: url("c"))
        manager.moveTab(from: 0, to: 3)
        XCTAssertEqual(manager.tabOrder, [b, c, a])
        manager.moveTab(from: 2, to: 0)
        XCTAssertEqual(manager.tabOrder, [a, b, c])
        manager.moveTab(from: 0, to: 2)
        XCTAssertEqual(manager.tabOrder, [b, a, c])
        assertValid(manager.store)
    }

    // MARK: Folders

    func testFoldersNestAndUngroup() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        let sid = store.activeSpace.id
        let outer = store.createFolder(name: "Work", containing: [b, c],
                                       at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 1))
        XCTAssertEqual(store.orderedTabIds, [a, b, c])
        XCTAssertEqual(store.activeSpace.today.count, 2)

        let inner = store.createFolder(name: "Inner", containing: [c],
                                       at: NodeLocation(spaceId: sid, section: .today, parentFolderId: outer, index: 1))
        XCTAssertEqual(store.workspace.location(ofNode: c)?.parentFolderId, inner)

        // A folder can't be dropped into its own descendant.
        store.move(outer, to: NodeLocation(spaceId: sid, section: .today, parentFolderId: inner, index: 0))
        XCTAssertEqual(store.workspace.location(ofNode: outer)?.parentFolderId, nil)

        store.renameFolder(outer, to: "Renamed")
        guard case .folder(let f)? = store.workspace.node(withId: outer) else { return XCTFail("missing folder") }
        XCTAssertEqual(f.name, "Renamed")

        store.ungroupFolder(outer)
        XCTAssertEqual(store.orderedTabIds, [a, b, c])
        XCTAssertEqual(store.workspace.location(ofNode: b)?.parentFolderId, nil)
        XCTAssertEqual(store.workspace.location(ofNode: inner)?.index, 2)
        assertValid(store)
    }

    func testClosingTabInsideFolderKeepsFolder() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let sid = store.activeSpace.id
        let folder = store.createFolder(containing: [a], at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 0))
        store.close(a)
        XCTAssertNotNil(store.workspace.node(withId: folder))
        assertValid(store)
    }

    // MARK: Splits

    func testSplitCreateShrinkAndCollapse() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        let d = store.newTab(url: url("d"))
        let split = try! XCTUnwrap(store.split([b, d, c]))
        XCTAssertEqual(store.orderedTabIds, [a, b, d, c])
        XCTAssertEqual(store.activeSpace.today.count, 2)
        XCTAssertEqual(store.workspace.splitGroup(containing: d)?.ratios.count, 3)

        store.close(d)
        XCTAssertEqual(store.workspace.splitGroup(containing: b)?.panes, [b, c])

        store.removeFromSplit(c)
        XCTAssertNil(store.workspace.node(withId: split))
        XCTAssertEqual(store.activeSpace.today, [.tab(a), .tab(b), .tab(c)])
        assertValid(store)
    }

    func testSplitRejectsFavoritesAndCapsPanes() {
        let store = makeStore()
        let ids = (0..<6).map { store.newTab(url: url("t\($0)")) }
        store.moveToFavorites(ids[0])
        XCTAssertNil(store.split([ids[0], ids[1]]))
        let split = try! XCTUnwrap(store.split(Array(ids[1...])))
        XCTAssertEqual(store.workspace.splitGroup(containing: ids[1])?.id, split)
        XCTAssertEqual(store.workspace.splitGroup(containing: ids[1])?.panes.count, SplitGroup.maxPanes)
        assertValid(store)
    }

    func testDroppingATabOntoAnotherSplitsThenJoins() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        let split = try! XCTUnwrap(store.splitTab(c, onto: a))
        XCTAssertEqual(store.workspace.splitGroup(containing: a)?.panes, [a, c])
        XCTAssertEqual(store.activeSpace.today, [.split(store.workspace.splitGroup(containing: a)!), .tab(b)])
        XCTAssertEqual(store.activeTabId, c)
        // Dropping onto a pane joins that split, right after the pane.
        XCTAssertEqual(store.splitTab(b, onto: a), split)
        XCTAssertEqual(store.workspace.splitGroup(containing: a)?.panes, [a, b, c])
        XCTAssertEqual(store.workspace.splitGroup(containing: a)?.ratios.count, 3)
        XCTAssertNil(store.splitTab(a, onto: a))
        assertValid(store)
    }

    func testClosingASplitPaneKeepsItsPartnerOnScreen() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        _ = store.splitTab(c, onto: b)
        store.activate(b)
        store.close(b)
        XCTAssertEqual(store.activeTabId, c)
        XCTAssertEqual(store.visibleTabIds, [c])
        XCTAssertEqual(store.orderedTabIds, [a, c])
        // A pinned pane is reset, leaves the split, and its partner stays focused.
        let d = store.newTab(url: url("d"))
        store.pin(d)
        _ = store.splitTab(c, onto: d)
        store.activate(d)
        store.close(d)
        XCTAssertNil(store.workspace.splitGroup(containing: c))
        XCTAssertEqual(store.activeTabId, c)
        assertValid(store)
    }

    func testSplitDropRejectsFavoritesAndFullSplits() {
        let store = makeStore()
        let ids = (0..<6).map { store.newTab(url: url("t\($0)")) }
        store.moveToFavorites(ids[0])
        XCTAssertNil(store.splitTab(ids[0], onto: ids[1]))
        XCTAssertNil(store.splitTab(ids[1], onto: ids[0]))
        _ = store.split(Array(ids[1...4]))
        XCTAssertNil(store.splitTab(ids[5], onto: ids[1]))
        assertValid(store)
    }

    func testMoveTabNextToReordersAndPullsOutOfSplits() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        store.moveTab(a, nextTo: c, after: true)
        XCTAssertEqual(store.orderedTabIds, [b, c, a])
        store.moveTab(a, nextTo: b, after: false)
        XCTAssertEqual(store.orderedTabIds, [a, b, c])
        _ = store.split([b, c])
        store.moveTab(c, nextTo: a, after: false)
        XCTAssertEqual(store.orderedTabIds, [c, a, b])
        XCTAssertNil(store.workspace.splitGroup(containing: b))
        assertValid(store)
    }

    func testPlacingIntoPinnedRemembersPageAndBackForgets() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let sid = store.activeSpace.id
        store.place(a, at: NodeLocation(spaceId: sid, section: .pinned, parentFolderId: nil, index: 0))
        XCTAssertEqual(store.workspace.section(containing: a), .pinned)
        XCTAssertEqual(store.tab(a)?.savedURL, url("a"))
        store.place(a, at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 0))
        XCTAssertEqual(store.workspace.section(containing: a), .today)
        XCTAssertNil(store.tab(a)?.savedURL)
        assertValid(store)
    }

    func testMovingATabBetweenWindowsKeepsItsStateAndSelectsANeighbour() {
        let source = makeStore()
        let a = source.newTab(url: url("a"))
        let b = source.newTab(url: url("b"))
        let c = source.newTab(url: url("c"))
        _ = source.splitTab(c, onto: b)
        source.activate(b)
        var tab = try! XCTUnwrap(source.takeTab(b))
        tab.interactionState = Data([1, 2, 3])
        XCTAssertEqual(source.orderedTabIds, [a, c])
        XCTAssertEqual(source.activeTabId, c, "the split partner stays on screen")
        XCTAssertTrue(source.workspace.archive.isEmpty, "moving isn't closing")
        assertValid(source)

        let dest = makeStore()
        let blank = dest.newTab(url: nil)
        dest.adopt(tab)
        XCTAssertEqual(dest.orderedTabIds, [blank, b])
        XCTAssertEqual(dest.activeTabId, b)
        XCTAssertEqual(dest.tab(b)?.url, url("b"))
        XCTAssertEqual(dest.tab(b)?.interactionState, Data([1, 2, 3]))
        assertValid(dest)
    }

    func testWindowWorkspaceSavesAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luna-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = WorkspacePersistence(fileURL: dir.appendingPathComponent("window-x.json"))
        let store = WorkspaceStore(persistence: persistence)
        let t = store.newTab(url: url("torn"))
        store.flush()
        let reloaded = WorkspaceStore(persistence: persistence)
        XCTAssertEqual(reloaded.orderedTabIds, [t])
        XCTAssertEqual(reloaded.activeTabId, t)
    }

    func testSplitRatiosNormalize() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let split = try! XCTUnwrap(store.split([a, b]))
        store.setSplitRatios(split, [3, 1])
        XCTAssertEqual(store.workspace.splitGroup(containing: a)?.ratios, [0.75, 0.25])
    }

    // MARK: Spaces

    func testSpacesKeepTheirOwnTabsAndActiveTab() {
        let store = makeStore()
        let home = store.activeSpace.id
        let a = store.newTab(url: url("a"))
        let work = store.createSpace(name: "Work")
        XCTAssertEqual(store.orderedTabIds, [])
        let b = store.newTab(url: url("b"))
        XCTAssertEqual(store.orderedTabIds, [b])

        store.switchSpace(home)
        XCTAssertEqual(store.activeTabId, a)
        store.activate(b) // activating a tab in another space switches to it
        XCTAssertEqual(store.activeSpace.id, work)

        store.moveTab(a, toSpace: work)
        XCTAssertEqual(store.workspace.orderedTabIds(inSpace: work), [a, b])
        XCTAssertEqual(store.workspace.orderedTabIds(inSpace: home), [])

        let removed = store.deleteSpace(work)
        XCTAssertEqual(Set(removed), [a, b])
        XCTAssertEqual(store.activeSpace.id, home)
        XCTAssertNil(store.tab(a))
        XCTAssertEqual(store.deleteSpace(home), [], "last space can't be deleted")
        assertValid(store)
    }

    // MARK: Undo

    func testUndoRedoStructureButNotNavigation() {
        let store = makeStore()
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        store.pin(b)
        store.updateURL(b, url("b2"))
        store.undoManager.undo()
        XCTAssertEqual(store.orderedTabIds, [a, b])
        XCTAssertEqual(store.workspace.section(containing: b), .today)
        XCTAssertEqual(store.tab(b)?.url, url("b2"), "undo must not revert navigation")
        store.undoManager.redo()
        XCTAssertEqual(store.workspace.section(containing: b), .pinned)
        assertValid(store)
    }

    // MARK: Archive

    func testArchiveStaleTodayTabsKeepsActiveAndPinned() {
        let store = makeStore()
        let old = store.newTab(url: url("old"))
        let pinned = store.newTab(url: url("pinned"))
        store.pin(pinned)
        let active = store.newTab(url: url("active"))
        let later = Date().addingTimeInterval(13 * 3600)
        let archived = store.archiveStaleTodayTabs(olderThan: 12 * 3600, now: later)
        XCTAssertEqual(archived, [old])
        XCTAssertEqual(Set(store.orderedTabIds), [pinned, active])
        assertValid(store)
    }

    // MARK: Persistence

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("workspace.json")

        let store = WorkspaceStore(persistence: WorkspacePersistence(fileURL: fileURL))
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        store.moveToFavorites(a)
        _ = store.split([b, c], axis: .vertical)
        store.updateTitle(b, "Bee")
        let state = Data([1, 2, 3])
        store.captureInteractionStates = { [b: state] }
        store.flush()

        let reloaded = WorkspaceStore(persistence: WorkspacePersistence(fileURL: fileURL))
        XCTAssertEqual(reloaded.orderedTabIds, [a, b, c])
        XCTAssertEqual(reloaded.activeTabId, c)
        XCTAssertEqual(reloaded.tab(b)?.title, "Bee")
        XCTAssertEqual(reloaded.tab(b)?.interactionState, state)
        XCTAssertEqual(reloaded.workspace.splitGroup(containing: b)?.axis, .vertical)
        assertValid(reloaded)
    }

    func testWorkspaceFromNewerBuildIsKeptAndNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("workspace.json")
        let newer = Data(#"{"version":\#(Workspace.currentVersion + 1),"future":true}"#.utf8)
        try newer.write(to: fileURL)

        let store = WorkspaceStore(persistence: WorkspacePersistence(fileURL: fileURL))
        _ = store.newTab(url: url("a"))
        store.flush()

        XCTAssertEqual(try Data(contentsOf: fileURL), newer, "a newer build's file is left alone")
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("workspace.newer-\(Workspace.currentVersion + 1).json")), newer)
    }

    func testCorruptFileIsBackedUpAndReplacedWithFreshWorkspace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fileURL = dir.appendingPathComponent("workspace.json")
        try Data("not json".utf8).write(to: fileURL)

        let store = WorkspaceStore(persistence: WorkspacePersistence(fileURL: fileURL))
        XCTAssertTrue(store.orderedTabIds.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace.corrupt.json").path))
    }

    func testRepairFixesDanglingAndOrphanedTabs() {
        var ws = Workspace()
        let orphan = Tab(url: url("orphan"))
        ws.tabs[orphan.id] = orphan
        let dangling = UUID()
        ws.spaces[0].today = [.tab(dangling), .split(SplitGroup(panes: [dangling, orphan.id]))]
        ws.favorites = [dangling]
        ws.spaces[0].activeTabId = dangling
        ws.repair()
        XCTAssertEqual(ws.integrityProblems(), [])
        XCTAssertEqual(ws.orderedTabIds(), [orphan.id])
        XCTAssertNil(ws.activeTabId)
    }

    func testRepairRehomesOrphansInStableOrder() {
        var ws = Workspace()
        let base = Date(timeIntervalSince1970: 1_000)
        let orphans = (0..<12).map { Tab(url: url("o\($0)"), lastActiveAt: base.addingTimeInterval(Double($0))) }
        for t in orphans.reversed() { ws.tabs[t.id] = t }
        ws.repair()
        XCTAssertEqual(ws.orderedTabIds(), orphans.map(\.id))
    }
}

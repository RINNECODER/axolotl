import XCTest
import WebKit
@testable import Axolotl

/// Drives the real NSOutlineView-backed sidebar offscreen.
@MainActor
final class SidebarOutlineTests: XCTestCase {
    private var store: WorkspaceStore!
    private var web: WebViewWrapper!
    private var coordinator: SidebarOutline.Coordinator!
    private var outline: SidebarOutlineView!
    private var activated: [UUID] = []
    private var newTabs = 0
    private var window: NSWindow!

    override func setUp() {
        store = WorkspaceStore(persistence: nil)
        web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        activated = []
        newTabs = 0
        let actions = SidebarActions(
            activate: { [unowned self] id in activated.append(id); store.activate(id) },
            close: { [unowned self] id in store.close(id) },
            newTab: { [unowned self] in newTabs += 1 },
            store: store
        )
        coordinator = SidebarOutline.Coordinator(actions: actions)
        let scroll = SidebarOutline.makeScrollView(coordinator: coordinator)
        // A window gives the outline real geometry so rows exist.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(scroll)
        outline = scroll.documentView as? SidebarOutlineView
    }

    override func tearDown() {
        window.close()
        window = nil
    }

    private func refresh() {
        coordinator.apply(.make(store: store, web: web))
        outline.layoutSubtreeIfNeeded()
    }

    private func row(of nodeId: UUID) -> Int {
        (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarOutline.Item)?.key == nodeId } ?? -1
    }

    private func url(_ s: String) -> URL { URL(string: "https://\(s).com")! }

    func testActiveTabHighlightIsThemeDrawn() {
        let a = store.newTab(url: url("a"))
        refresh()
        let rowView = outline.rowView(atRow: row(of: a), makeIfNecessary: true)
        XCTAssertTrue(rowView is ThemedSidebarRowView)
        XCTAssertEqual(rowView?.isSelected, true)
    }

    func testRowsMirrorPinnedDividerNewTabAndToday() {
        let p = store.newTab(url: url("p"))
        store.pin(p)
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let sid = store.activeSpace.id
        let folder = store.createFolder(name: "F", containing: [b], at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 1))
        refresh()

        // pinned p, divider, New Tab, a, folder, b (expanded)
        XCTAssertEqual(outline.numberOfRows, 6)
        XCTAssertEqual(row(of: p), 0)
        XCTAssertEqual(row(of: a), 3)
        XCTAssertEqual(row(of: folder), 4)
        XCTAssertEqual(row(of: b), 5)
        XCTAssertEqual(outline.level(forRow: 5), 1)
    }

    func testSelectionFollowsActiveTabAndSelectingActivates() {
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        refresh()
        XCTAssertEqual(outline.selectedRow, row(of: b))

        outline.selectRowIndexes([row(of: a)], byExtendingSelection: false)
        XCTAssertEqual(activated, [a])
        XCTAssertEqual(store.activeTabId, a)

        // Programmatic sync (store → outline) must not echo back as an activation.
        store.activate(b)
        refresh()
        XCTAssertEqual(outline.selectedRow, row(of: b))
        XCTAssertEqual(activated, [a])
    }

    func testCollapsingFolderPersistsAndHidesChildren() {
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let sid = store.activeSpace.id
        let folder = store.createFolder(containing: [a, b], at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 0))
        refresh()
        XCTAssertEqual(outline.numberOfRows, 5)

        outline.collapseItem(outline.item(atRow: row(of: folder)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        guard case .folder(let f)? = store.workspace.node(withId: folder) else { return XCTFail("folder missing") }
        XCTAssertFalse(f.isExpanded)

        refresh()
        XCTAssertEqual(outline.numberOfRows, 3)
        // The active tab is hidden inside the collapsed folder, so the folder row shows selection context.
        XCTAssertEqual(store.activeTabId, b)
    }

    func testDropRulesForReorderFoldersAndSplits() {
        let p = store.newTab(url: url("p"))
        store.pin(p)
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let sid = store.activeSpace.id
        let folder = store.createFolder(name: "F", containing: [b], at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 1))
        refresh()
        let item = { (id: UUID) in self.outline.item(atRow: self.row(of: id)) as? SidebarOutline.Item }

        // Root index past pinned + divider + New Tab maps into Today.
        XCTAssertEqual(coordinator.dropAction(for: a, item: nil, index: 0),
                       .place(NodeLocation(spaceId: sid, section: .pinned, parentFolderId: nil, index: 0)))
        XCTAssertEqual(coordinator.dropAction(for: p, item: nil, index: 4),
                       .place(NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 1)))
        // Onto a tab: split. Onto a folder: into it. A folder can't go into itself.
        XCTAssertEqual(coordinator.dropAction(for: a, item: item(p), index: NSOutlineViewDropOnItemIndex), .split(onto: p))
        XCTAssertEqual(coordinator.dropAction(for: a, item: item(folder), index: NSOutlineViewDropOnItemIndex),
                       .place(NodeLocation(spaceId: sid, section: .today, parentFolderId: folder, index: 1)))
        XCTAssertNil(coordinator.dropAction(for: folder, item: item(folder), index: 0))
        XCTAssertNil(coordinator.dropAction(for: a, item: item(a), index: NSOutlineViewDropOnItemIndex))
    }

    func testSplitRowActivatesFocusedOrFirstPane() {
        let a = store.newTab(url: url("a"))
        let b = store.newTab(url: url("b"))
        let c = store.newTab(url: url("c"))
        let split = store.split([a, b])!
        store.activate(c)
        refresh()

        outline.selectRowIndexes([row(of: split)], byExtendingSelection: false)
        XCTAssertEqual(activated.last, a)
        XCTAssertEqual(Set(store.visibleTabIds), [a, b])
    }

    /// Clicking the New Tab row (not selectable) must still open a tab.
    func testClickingNewTabRowOpensTab() throws {
        _ = store.newTab(url: url("a"))
        refresh()
        let row = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarOutline.Item)?.kind == .newTab }!
        let rect = outline.rect(ofRow: row)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        // Queue the mouse-up so the table's click tracking loop returns.
        window.postEvent(event(.leftMouseUp), atStart: false)
        outline.mouseDown(with: event(.leftMouseDown))
        XCTAssertEqual(newTabs, 1)
    }

    func testDividerAndNewTabRowsAreNotSelectable() {
        _ = store.newTab(url: url("a"))
        refresh()
        let divider = (0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarOutline.Item)?.kind == .divider }!
        XCTAssertFalse(coordinator.outlineView(outline, shouldSelectItem: outline.item(atRow: divider)!))
        XCTAssertFalse(coordinator.outlineView(outline, shouldSelectItem: outline.item(atRow: divider + 1)!))
    }
}

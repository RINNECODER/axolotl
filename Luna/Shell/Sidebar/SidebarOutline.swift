import AppKit
import SwiftUI

/// Everything the outline needs to render one space, captured as a value so
/// updates can be diffed cheaply.
struct SidebarSnapshot: Equatable {
    var space: Space
    var tabs: [UUID: Tab]
    var activeTabId: UUID?
    var faviconURLs: [UUID: URL]
    var loading: Set<UUID>
    /// Tabs playing sound, and tabs on a muted site (speaker in the row).
    var audible: Set<UUID> = []
    var muted: Set<UUID> = []
    /// Other spaces, for "Move to Space".
    var otherSpaces: [(id: UUID, name: String)]

    static func make(store: WorkspaceStore, web: WebViewWrapper) -> SidebarSnapshot {
        let ws = store.workspace
        let space = ws.activeSpace
        return SidebarSnapshot(
            space: space,
            tabs: ws.tabs,
            activeTabId: ws.activeTabId,
            faviconURLs: web.tabRuntime.faviconURLByTab,
            loading: Set(web.tabRuntime.loadingProgressByTab.keys),
            audible: web.tabRuntime.audibleTabs,
            muted: web.mutedHosts.isEmpty ? [] : Set(ws.tabs.keys.filter { web.isMuted($0) }),
            otherSpaces: ws.spaces.filter { $0.id != space.id }.map { ($0.id, $0.name) }
        )
    }

    static func == (a: SidebarSnapshot, b: SidebarSnapshot) -> Bool {
        a.space == b.space && a.tabs == b.tabs && a.activeTabId == b.activeTabId
            && a.faviconURLs == b.faviconURLs && a.loading == b.loading && a.audible == b.audible && a.muted == b.muted
            && a.otherSpaces.map(\.id) == b.otherSpaces.map(\.id) && a.otherSpaces.map(\.name) == b.otherSpaces.map(\.name)
    }
}

/// Commands the sidebar sends back to the shell. Closing and activating go
/// through the shell so web views and chat state are cleaned up consistently.
struct SidebarActions {
    var activate: (UUID) -> Void
    var close: (UUID) -> Void
    var newTab: () -> Void
    var store: WorkspaceStore
    /// Luna Max: AI-rename a tab, and group Today tabs into folders.
    var tidyTitle: (UUID) -> Void = { _ in }
    var tidyToday: () -> Void = {}
    /// A tab dragged out of the window, released at a screen point.
    var tearOff: (UUID, CGPoint) -> Void = { _, _ in }
    /// Tab menu: move the tab (or, with true, its group) to a new window.
    var moveToNewWindow: ((UUID, Bool) -> Void)? = nil
    /// ⋯ → Bookmark This Page (⌘D); nil when the current tab has no web page.
    var bookmarkPage: (() -> Void)? = nil
    /// Reload, Duplicate and Mute in the tab menu.
    var web: WebViewWrapper? = nil
}

/// Native source-list sidebar (NSOutlineView): pinned tabs, a divider, a New
/// Tab row, then Today. Folders use the system disclosure triangle and the
/// active tab uses the system selection highlight.
struct SidebarOutline: NSViewRepresentable {
    let snapshot: SidebarSnapshot
    let actions: SidebarActions

    func makeCoordinator() -> Coordinator { Coordinator(actions: actions) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeScrollView(coordinator: context.coordinator)
        context.coordinator.apply(snapshot)
        return scroll
    }

    static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.style = .sourceList
        outline.selectionHighlightStyle = .none  // ThemedSidebarRowView draws the active tab
        outline.headerView = nil
        outline.rowSizeStyle = .default
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.backgroundColor = .clear
        outline.allowsEmptySelection = true
        outline.focusRingType = .none
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = coordinator
        outline.delegate = coordinator
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        outline.onRowClick = { [weak coordinator] row in coordinator?.rowClicked(row) }
        // Drag to reorder (rows part to make room), into folders, or onto
        // another tab to open both in split view.
        outline.registerForDraggedTypes([LunaDrag.tabType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .gap

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.apply(snapshot)
        context.coordinator.applyTheme(ThemeStore.shared.theme)
    }

    // MARK: - Items

    final class Item: NSObject {
        enum Kind: Equatable {
            case node(SidebarNode)
            case divider
            case newTab
        }
        let key: UUID
        var kind: Kind
        var children: [Item] = []
        init(key: UUID, kind: Kind) {
            self.key = key
            self.kind = kind
        }
        var node: SidebarNode? { if case .node(let n) = kind { return n } else { return nil } }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var actions: SidebarActions
        weak var outline: SidebarOutlineView?
        private(set) var snapshot: SidebarSnapshot?
        private var theme: Theme?
        private var roots: [Item] = []
        /// Items are reused across reloads so AppKit keeps expansion state.
        private var cache: [UUID: Item] = [:]
        private var structureKey: [String] = []
        private var isSyncingSelection = false
        private static let dividerKey = UUID()
        private static let newTabKey = UUID()

        nonisolated deinit {}

        init(actions: SidebarActions) {
            self.actions = actions
        }

        // MARK: Snapshot → items

        func apply(_ new: SidebarSnapshot) {
            guard let outline else { return }
            guard new != snapshot else { return }
            snapshot = new
            let key = Self.makeStructureKey(new.space)
            if key != structureKey {
                structureKey = key
                roots = buildRoots(new.space)
                outline.reloadData()
                expandFolders(roots)
            } else {
                // Same tree; refresh row contents in place (titles, favicons, loading).
                refreshItems(roots, from: new.space)
                outline.enumerateAvailableRowViews { _, row in
                    if let item = outline.item(atRow: row) as? Item,
                       let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarCell {
                        configure(cell, for: item)
                    }
                }
            }
            syncSelection()
        }

        private static func makeStructureKey(_ space: Space) -> [String] {
            func walk(_ nodes: [SidebarNode], _ depth: Int, _ out: inout [String]) {
                for n in nodes {
                    switch n {
                    case .tab(let id): out.append("\(depth)t\(id)")
                    case .split(let g): out.append("\(depth)s\(g.id)\(g.panes)")
                    case .folder(let f):
                        out.append("\(depth)f\(f.id)\(f.isExpanded)\(f.name)\(f.color ?? "")")
                        walk(f.children, depth + 1, &out)
                    }
                }
            }
            var out: [String] = []
            walk(space.pinned, 0, &out)
            out.append("|")
            walk(space.today, 0, &out)
            return out
        }

        private func buildRoots(_ space: Space) -> [Item] {
            var seen = Set<UUID>()
            func make(_ node: SidebarNode) -> Item {
                let item = cache[node.id] ?? Item(key: node.id, kind: .node(node))
                item.kind = .node(node)
                seen.insert(node.id)
                if case .folder(let f) = node {
                    item.children = f.children.map(make)
                } else {
                    item.children = []
                }
                cache[node.id] = item
                return item
            }
            let divider = cache[Self.dividerKey] ?? Item(key: Self.dividerKey, kind: .divider)
            let newTab = cache[Self.newTabKey] ?? Item(key: Self.newTabKey, kind: .newTab)
            cache[Self.dividerKey] = divider
            cache[Self.newTabKey] = newTab
            seen.formUnion([Self.dividerKey, Self.newTabKey])
            let result = space.pinned.map(make) + [divider, newTab] + space.today.map(make)
            cache = cache.filter { seen.contains($0.key) }
            return result
        }

        private func refreshItems(_ items: [Item], from space: Space) {
            var lookup: [UUID: SidebarNode] = [:]
            func index(_ nodes: [SidebarNode]) {
                for n in nodes {
                    lookup[n.id] = n
                    if case .folder(let f) = n { index(f.children) }
                }
            }
            index(space.pinned)
            index(space.today)
            func walk(_ items: [Item]) {
                for item in items {
                    if let n = lookup[item.key] { item.kind = .node(n) }
                    walk(item.children)
                }
            }
            walk(items)
        }

        private func expandFolders(_ items: [Item]) {
            for item in items {
                guard case .folder(let f)? = item.node else { continue }
                if f.isExpanded {
                    outline?.expandItem(item)
                    expandFolders(item.children)
                } else {
                    outline?.collapseItem(item)
                }
            }
        }

        private func syncSelection() {
            guard let outline, let snapshot else { return }
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            guard let active = snapshot.activeTabId, let item = itemContaining(active, in: roots) else {
                outline.deselectAll(nil)
                return
            }
            let row = outline.row(forItem: item)
            if row >= 0 {
                if outline.selectedRow != row { outline.selectRowIndexes([row], byExtendingSelection: false) }
            } else {
                outline.deselectAll(nil)
            }
        }

        /// The visible item for a tab: the tab row, its split row, or the
        /// nearest collapsed folder containing it.
        private func itemContaining(_ tabId: UUID, in items: [Item]) -> Item? {
            for item in items {
                guard let node = item.node, node.tabIds.contains(tabId) else { continue }
                if case .folder = node, let outline, outline.isItemExpanded(item) {
                    return itemContaining(tabId, in: item.children) ?? item
                }
                return item
            }
            return nil
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let item = item as? Item else { return roots.count }
            return item.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let item = item as? Item else { return roots[index] }
            return item.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard case .folder? = (item as? Item)?.node else { return false }
            return true
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? Item)?.kind == .divider ? 20 : (ThemeStore.shared.theme.compact ? 26 : 30)
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { ThemedSidebarRowView() }

        /// Density changes row heights; colors and radius redraw the selection.
        func applyTheme(_ new: Theme) {
            guard let outline, new != theme else { return }
            let densityChanged = theme.map { $0.compact != new.compact } ?? false
            theme = new
            if densityChanged { outline.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outline.numberOfRows)) }
            outline.enumerateAvailableRowViews { row, _ in row.needsDisplay = true }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let id = NSUserInterfaceItemIdentifier("SidebarCell")
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? SidebarCell) ?? SidebarCell(identifier: id)
            configure(cell, for: item)
            return cell
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let item = item as? Item else { return false }
            switch item.kind {
            case .divider, .newTab: return false
            case .node(let n):
                if case .folder = n { return false }
                return true
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let outline,
                  let item = outline.item(atRow: outline.selectedRow) as? Item, let node = item.node else { return }
            switch node {
            case .tab(let id): actions.activate(id)
            case .split(let g):
                let target = snapshot?.activeTabId.flatMap { g.panes.contains($0) ? $0 : nil } ?? g.panes[0]
                actions.activate(target)
            case .folder: break
            }
        }

        /// Clicks on rows that can't be selected (folders, New Tab).
        func rowClicked(_ row: Int) {
            guard let outline, row >= 0, let item = outline.item(atRow: row) as? Item else { return }
            switch item.kind {
            case .newTab: actions.newTab()
            case .node(.folder):
                if outline.isItemExpanded(item) { outline.animator().collapseItem(item) } else { outline.animator().expandItem(item) }
            default: break
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            folderExpansionChanged(notification, expanded: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            folderExpansionChanged(notification, expanded: false)
        }

        private func folderExpansionChanged(_ notification: Notification, expanded: Bool) {
            guard let item = notification.userInfo?["NSObject"] as? Item, case .folder(let f)? = item.node,
                  f.isExpanded != expanded else { return }
            DispatchQueue.main.async { [actions] in actions.store.setFolderExpanded(f.id, expanded) }
        }

        // MARK: Drag and drop

        enum DropAction: Equatable {
            case place(NodeLocation)
            /// Open the dragged tab beside this tab (or in its split).
            case split(onto: UUID)
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = (item as? Item)?.node else { return nil }
            let pb = NSPasteboardItem()
            pb.setString(node.id.uuidString, forType: LunaDrag.tabType)
            return pb
        }

        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let dragged = Self.draggedId(info),
                  let action = dropAction(for: dragged, item: item as? Item, index: index) else { return [] }
            if case .place(let loc) = action, loc.parentFolderId == nil, index == NSOutlineViewDropOnItemIndex {
                // Dropping on a divider/New Tab row: show it as a gap at the spot instead.
                outlineView.setDropItem(nil, dropChildIndex: rootIndex(for: loc))
            }
            return .move
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                         item: Any?, childIndex index: Int) -> Bool {
            guard let dragged = Self.draggedId(info),
                  let action = dropAction(for: dragged, item: item as? Item, index: index) else { return false }
            switch action {
            case .place(let loc):
                actions.store.place(dragged, at: loc)
            case .split(let target):
                guard actions.store.splitTab(dragged, onto: target) != nil else { return false }
                actions.activate(dragged)
            }
            return true
        }

        /// Tab rows dropped outside the window move to their own window.
        func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            guard operation.isEmpty, let window = outlineView.window, !window.frame.contains(screenPoint),
                  let id = session.draggingPasteboard.string(forType: LunaDrag.tabType).flatMap(UUID.init(uuidString:)),
                  actions.store.workspace.tabs[id] != nil else { return }
            actions.tearOff(id, screenPoint)
        }

        static func draggedId(_ info: NSDraggingInfo) -> UUID? {
            info.draggingPasteboard.string(forType: LunaDrag.tabType).flatMap(UUID.init(uuidString:))
        }

        /// What dropping `dragged` at the proposed spot would do (nil = not allowed).
        func dropAction(for dragged: UUID, item: Item?, index: Int) -> DropAction? {
            let ws = actions.store.workspace
            let space = ws.activeSpace
            let draggedIsTab = ws.tabs[dragged] != nil
            let action: DropAction
            if index == NSOutlineViewDropOnItemIndex {
                guard let item else { return nil }
                switch item.kind {
                case .divider, .newTab:
                    action = .place(NodeLocation(spaceId: space.id, section: .today, parentFolderId: nil, index: 0))
                case .node(.tab(let target)):
                    guard draggedIsTab, target != dragged else { return nil }
                    action = .split(onto: target)
                case .node(.split(let g)):
                    guard draggedIsTab, !g.panes.contains(dragged), g.panes.count < SplitGroup.maxPanes else { return nil }
                    action = .split(onto: g.panes[g.panes.count - 1])
                case .node(.folder(let f)):
                    guard let loc = ws.location(ofNode: f.id) else { return nil }
                    action = .place(NodeLocation(spaceId: loc.spaceId, section: loc.section, parentFolderId: f.id, index: f.children.count))
                }
            } else if let item {
                guard case .folder(let f)? = item.node, let loc = ws.location(ofNode: f.id) else { return nil }
                action = .place(NodeLocation(spaceId: loc.spaceId, section: loc.section, parentFolderId: f.id, index: index))
            } else {
                // Root list: pinned rows, then the divider and New Tab rows, then Today.
                let pinned = space.pinned.count
                if index <= pinned {
                    action = .place(NodeLocation(spaceId: space.id, section: .pinned, parentFolderId: nil, index: index))
                } else {
                    action = .place(NodeLocation(spaceId: space.id, section: .today, parentFolderId: nil, index: max(0, index - pinned - 2)))
                }
            }
            // Reject moves the model refuses (e.g. a folder into itself).
            var trial = ws
            switch action {
            case .place(let loc): return trial.placeNode(dragged, at: loc) ? action : nil
            case .split(let t): return trial.splitTab(dragged, onto: t) != nil ? action : nil
            }
        }

        private func rootIndex(for loc: NodeLocation) -> Int {
            guard let snapshot else { return 0 }
            return loc.section == .pinned ? loc.index : snapshot.space.pinned.count + 2 + loc.index
        }

        // MARK: Cells

        private func configure(_ cell: SidebarCell, for item: Item) {
            guard let snapshot else { return }
            switch item.kind {
            case .divider:
                let canTidy = snapshot.space.today.count >= 3
                cell.show(AnyView(SidebarDividerRow()), closeAction: canTidy ? { [actions] in actions.tidyToday() } : nil,
                          closeSymbol: "sparkles", closeHelp: "Tidy Today's tabs into folders")
            case .newTab:
                cell.show(AnyView(SidebarNewTabRow()), closeAction: nil)
            case .node(let node):
                switch node {
                case .tab(let id):
                    guard let tab = snapshot.tabs[id] else { return cell.show(AnyView(EmptyView()), closeAction: nil) }
                    let pinned = snapshot.space.pinned.contains { $0.tabIds.contains(id) }
                    cell.show(AnyView(SidebarTabRow(tab: tab,
                                                    faviconURL: snapshot.faviconURLs[id],
                                                    isLoading: snapshot.loading.contains(id),
                                                    audio: TabAudioState(isAudible: snapshot.audible.contains(id),
                                                                         isMuted: snapshot.muted.contains(id)))),
                              closeAction: { [actions] in actions.close(id) },
                              closeSymbol: pinned ? "minus" : "xmark")
                case .folder(let f):
                    cell.show(AnyView(SidebarFolderRow(name: f.name, isExpanded: f.isExpanded, color: f.color.flatMap(TabGroupColor.init(rawValue:)))), closeAction: nil)
                case .split(let g):
                    let panes = g.panes.compactMap { snapshot.tabs[$0] }
                    cell.show(AnyView(SidebarSplitRow(panes: panes, faviconURLs: snapshot.faviconURLs,
                                                      focused: snapshot.activeTabId)),
                              closeAction: nil)
                }
            }
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, let snapshot, outline.clickedRow >= 0,
                  let item = outline.item(atRow: outline.clickedRow) as? Item, let node = item.node else { return }
            let store = actions.store
            switch node {
            case .tab(let id):
                // Chrome's items (shared with the tab strip), then the sidebar's own, then the close group.
                let shared = TabContextMenu.items(for: id, store: store, web: actions.web, close: actions.close,
                                                  moveToNewWindow: actions.moveToNewWindow)
                for section in shared.dropLast() {
                    TabContextMenu.addItems(section, to: menu)
                    menu.addItem(.separator())
                }
                menu.addItem(MenuAction("Add to Favorites") { store.moveToFavorites(id) })
                if let active = snapshot.activeTabId, active != id, !store.workspace.isFavorite(active) {
                    menu.addItem(MenuAction("Open in Split View with Current Tab") { [actions] in
                        if store.splitTab(id, onto: active) != nil { actions.activate(id) }
                    })
                }
                if let loc = store.workspace.location(ofNode: id) {
                    menu.addItem(MenuAction("New Folder with Tab") {
                        store.createFolder(containing: [id], at: loc)
                    })
                }
                menu.addItem(.separator())
                menu.addItem(MenuAction("Rename Tab…") {
                    let current = snapshot.tabs[id].map(displayTitle(for:)) ?? ""
                    if let name = TextPrompt.name(title: "Rename Tab", initial: current) { store.setCustomTitle(id, name) }
                })
                menu.addItem(MenuAction("Tidy Title") { [actions] in actions.tidyTitle(id) })
                if snapshot.tabs[id]?.customTitle != nil {
                    menu.addItem(MenuAction("Use Page Title") { store.setCustomTitle(id, nil) })
                }
                if !snapshot.otherSpaces.isEmpty {
                    let sub = NSMenu()
                    for space in snapshot.otherSpaces {
                        sub.addItem(MenuAction(space.name) { store.moveTab(id, toSpace: space.id) })
                    }
                    let parent = NSMenuItem(title: "Move to Space", action: nil, keyEquivalent: "")
                    parent.submenu = sub
                    menu.addItem(parent)
                }
                if let url = snapshot.tabs[id]?.url, url.scheme?.hasPrefix("http") == true {
                    menu.addItem(.separator())
                    menu.addItem(MenuAction("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    })
                }
                menu.addItem(.separator())
                if let close = shared.last { TabContextMenu.addItems(close, to: menu) }
            case .folder(let f):
                menu.addItem(MenuAction("Rename Folder…") {
                    if let name = TextPrompt.name(title: "Rename Folder", initial: f.name) {
                        store.renameFolder(f.id, to: name)
                    }
                })
                let colors = NSMenu()
                for c in TabGroupColor.allCases {
                    let item = MenuAction(c.rawValue.capitalized) { store.setTabGroupColor(f.id, c) }
                    item.state = f.color == c.rawValue ? .on : .off
                    colors.addItem(item)
                }
                let colorItem = NSMenuItem(title: "Group Color", action: nil, keyEquivalent: "")
                colorItem.submenu = colors
                menu.addItem(colorItem)
                menu.addItem(MenuAction("Ungroup") { store.ungroupFolder(f.id) })
                if let move = actions.moveToNewWindow, let first = f.tabIds.first, f.tabIds.count < store.orderedTabIds.count,
                   store.workspace.tabGroup(containing: first)?.id == f.id {
                    menu.addItem(MenuAction(TabContextMenu.Command.moveGroupToNewWindow.title) { move(first, true) })
                }
                menu.addItem(MenuAction("Close Group") { [actions] in store.closeTabGroup(f.id, closingWith: actions.close) })
            case .split(let g):
                menu.addItem(MenuAction("Separate Split View") { store.dissolveSplit(g.id) })
                if let active = snapshot.activeTabId, !g.panes.contains(active), g.panes.count < SplitGroup.maxPanes,
                   !store.workspace.isFavorite(active) {
                    menu.addItem(MenuAction("Add Current Tab to Split") { [actions] in
                        if store.splitTab(active, onto: g.panes[g.panes.count - 1]) != nil { actions.activate(active) }
                    })
                }
            }
        }
    }
}

// MARK: - AppKit pieces

/// Pasteboard type for dragging tabs, folders and splits inside Luna.
enum LunaDrag {
    static let tabType = NSPasteboard.PasteboardType("com.luna.browser.node")
}

/// Outline view that reports single clicks (for rows that can't be selected).
final class SidebarOutlineView: NSOutlineView {
    /// Clicked row, captured before AppKit handles the click: for rows that
    /// can't be selected (New Tab, folders) `clickedRow` is reset afterward.
    var onRowClick: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        // The disclosure triangle already toggles the folder itself.
        let onDisclosure = row >= 0 && frameOfOutlineCell(atRow: row).contains(point)
        super.mouseDown(with: event)
        if !onDisclosure { onRowClick?(row) }
    }

    /// Right-click: the rows' NSMenu (filled by the coordinator) is shown as a Luna menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = super.menu(for: event) else { return nil }
        let entries = LunaMenuEntry.from(menu)
        if !entries.isEmpty { presentLunaContextMenu({ entries }, for: event, in: self) }
        return nil
    }

    // No focus ring / key-view highlight: the sidebar isn't a text target.
    override var acceptsFirstResponder: Bool { false }
}

/// The active tab's highlight in the theme's active tab color (instead of the system selection).
final class ThemedSidebarRowView: NSTableRowView {
    override var isEmphasized: Bool { get { false } set {} }
    /// Theme colors exactly as chosen, not blended with what's behind the window.
    override var allowsVibrancy: Bool { false }

    // The outline's highlight style is .none (the system source-list highlight is its own vibrancy layer),
    // so the active row is painted here.
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isSelected else { return }
        let theme = ThemeStore.shared.theme
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let radius = theme.radius(6)
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSColor.lunaHex(theme.pair(.activeTab).hex(dark: dark)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSColor.black.withAlphaComponent(dark ? 0.25 : 0.08).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        border.lineWidth = 1
        border.stroke()
    }

    /// Labels keep their normal colors on the light highlight.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
}

/// A row: SwiftUI content (non-interactive, so AppKit owns clicks and drags)
/// plus an AppKit close button revealed on hover.
final class SidebarCell: NSTableCellView {
    private let hosting = PassthroughHostingView(rootView: AnyView(EmptyView()))
    private let closeButton = NSButton()
    private var closeAction: (() -> Void)?
    private var tracking: NSTrackingArea?
    private var isHovering = false { didSet { updateCloseVisibility() } }

    nonisolated deinit {}

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setAccessibilityLabel("Close Tab")
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -2),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
        ])
        updateCloseVisibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show(_ view: AnyView, closeAction: (() -> Void)?, closeSymbol: String = "xmark", closeHelp: String = "Close Tab") {
        hosting.rootView = view
        self.closeAction = closeAction
        closeButton.toolTip = closeHelp
        closeButton.setAccessibilityLabel(closeHelp)
        closeButton.image = NSImage(systemSymbolName: closeSymbol, accessibilityDescription: "Close")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        updateCloseVisibility()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
    }

    private func updateCloseVisibility() {
        closeButton.isHidden = closeAction == nil || !isHovering
    }

    @objc private func closeClicked() { closeAction?() }
}

/// Hosting view that never takes clicks, so the outline handles selection,
/// context menus and drag and drop.
final class PassthroughHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// NSMenuItem that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}

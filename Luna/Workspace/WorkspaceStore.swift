import Combine
import Foundation

/// Single source of truth for a profile window's tabs, spaces and sidebar tree.
///
/// Every structural change goes through `perform`, which records undo and
/// schedules a save. The sidebar, horizontal tab strip, keyboard shortcuts,
/// command bar and AI command router all mutate tabs through this API.
final class WorkspaceStore: ObservableObject {
    enum CloseResult: Equatable {
        /// Tab removed from the workspace; tear down its web view.
        case removed
        /// Pinned/favorite tab kept but reset to its saved URL; unload its web view.
        case reset
        case notFound
    }

    @Published private(set) var workspace: Workspace

    let undoManager = UndoManager()
    /// Called after a tab becomes pinned or a favorite (Luna Max tidy titles).
    var onTabPinned: ((UUID) -> Void)?
    /// Called right before each save so live web views can contribute
    /// back/forward state (`WKWebView.interactionState`).
    var captureInteractionStates: (() -> [UUID: Data])?

    private let persistence: WorkspacePersistence?
    private var pendingSave: DispatchWorkItem?
    private var recentlyClosed: [(tab: Tab, location: NodeLocation?, favoriteIndex: Int?)] = []
    private let recentlyClosedLimit = 25

    // Avoid the MainActor isolated-deinit executor hop that double-frees
    // task-local storage on current macOS runtimes (swiftlang/swift#88036).
    nonisolated deinit {}

    /// - Parameter persistence: nil keeps the workspace in memory only (tests,
    ///   secondary windows on an already-open profile).
    init(persistence: WorkspacePersistence?) {
        self.persistence = persistence
        var ws = persistence?.load() ?? Workspace()
        ws.repair()
        self.workspace = ws
    }

    var isPersistent: Bool { persistence != nil }

    // MARK: - Reads

    var activeTabId: UUID? { workspace.activeTabId }
    var activeSpace: Space { workspace.activeSpace }
    var orderedTabIds: [UUID] { workspace.orderedTabIds() }
    func tab(_ id: UUID) -> Tab? { workspace.tabs[id] }

    /// Tabs on screen right now: the active tab, or every pane of its split.
    var visibleTabIds: [UUID] { workspace.visibleTabIds }

    // MARK: - Mutation core

    private func perform(_ actionName: String?, _ change: (inout Workspace) -> Void) {
        let before = workspace
        var next = workspace
        change(&next)
        guard next != before else { return }
        #if DEBUG
        let problems = next.integrityProblems()
        assert(problems.isEmpty, "Workspace invariant broken by \(actionName ?? "update"): \(problems)")
        #endif
        workspace = next
        if let actionName {
            // With event grouping off (tests, scripted batches) each action is its own undo step.
            let explicitGroup = !undoManager.groupsByEvent
            if explicitGroup { undoManager.beginUndoGrouping() }
            undoManager.registerUndo(withTarget: self) { store in
                store.restore(before, actionName: actionName)
            }
            undoManager.setActionName(actionName)
            if explicitGroup { undoManager.endUndoGrouping() }
        }
        scheduleSave()
    }

    /// Undo/redo swap whole snapshots. Content fields (url/title/history) that
    /// changed since are kept from the current state so undo never navigates.
    private func restore(_ snapshot: Workspace, actionName: String) {
        let current = workspace
        var restored = snapshot
        for (id, tab) in current.tabs where restored.tabs[id] != nil {
            restored.tabs[id]?.url = tab.url
            restored.tabs[id]?.title = tab.title
            restored.tabs[id]?.interactionState = tab.interactionState
        }
        workspace = restored
        undoManager.registerUndo(withTarget: self) { store in
            store.restore(current, actionName: actionName)
        }
        undoManager.setActionName(actionName)
        scheduleSave()
    }

    // MARK: - Tabs

    @discardableResult
    func newTab(url: URL?, placement: TabPlacement = .section(.today, spaceId: nil), index: Int? = nil, activate: Bool = true) -> UUID {
        let tab = Tab(url: url ?? URL(string: "about:blank")!)
        perform("New Tab") { ws in
            ws.addTab(tab, placement: placement, index: index)
            if activate { Self.activate(tab.id, in: &ws) }
        }
        return tab.id
    }

    func activate(_ tabId: UUID) {
        perform(nil) { Self.activate(tabId, in: &$0) }
    }

    func activate(index: Int) {
        let ids = orderedTabIds
        guard ids.indices.contains(index) else { return }
        activate(ids[index])
    }

    /// Closes a tab and selects a neighbour if it was active. Pinned and favorite
    /// tabs are reset to their saved URL instead of removed (Arc behaviour).
    @discardableResult
    func close(_ tabId: UUID) -> CloseResult {
        guard workspace.tabs[tabId] != nil else { return .notFound }
        let persistent = workspace.isPersistent(tabId)
        perform(persistent ? "Reset Tab" : "Close Tab") { ws in
            let wasActive = ws.activeTabId == tabId
            let spaceId = ws.spaceId(containing: tabId) ?? ws.activeSpaceId
            let order = ws.orderedTabIds(inSpace: spaceId)
            // Closing a split pane leaves its partner on screen (Helium does the same).
            let partner: UUID? = ws.splitGroup(containing: tabId).flatMap { g in
                guard let i = g.panes.firstIndex(of: tabId) else { return nil }
                return i > 0 ? g.panes[i - 1] : g.panes.dropFirst().first
            }
            if persistent {
                // A pinned pane leaves the split when it's reset.
                if partner != nil { ws.detachTabFromAnySplit(tabId) }
                if let saved = ws.tabs[tabId]?.savedURL { ws.tabs[tabId]?.url = saved }
                ws.tabs[tabId]?.interactionState = nil
            } else {
                let loc = ws.location(ofNode: tabId)
                if let tab = ws.removeTab(tabId) {
                    ws.archive(tab)
                    recentlyClosed.append((tab, loc, nil))
                    if recentlyClosed.count > recentlyClosedLimit { recentlyClosed.removeFirst() }
                }
            }
            if wasActive, let i = order.firstIndex(of: tabId) {
                let remaining = order.filter { $0 != tabId }
                let next = partner ?? (remaining.isEmpty ? nil : remaining[max(0, min(i - 1, remaining.count - 1))])
                if let si = ws.spaceIndex(spaceId) { ws.spaces[si].activeTabId = next }
                if let next { ws.tabs[next]?.lastActiveAt = Date() }
            }
        }
        return persistent ? .reset : .removed
    }

    /// Reopens the most recently closed tab where it was (Cmd+Shift+T).
    @discardableResult
    func reopenClosedTab() -> UUID? {
        // Skip entries already brought back by Undo.
        while let last = recentlyClosed.last, workspace.tabs[last.tab.id] != nil { recentlyClosed.removeLast() }
        guard let entry = recentlyClosed.popLast() else { return nil }
        var tab = entry.tab
        tab.lastActiveAt = Date()
        perform("Reopen Tab") { ws in
            ws.tabs[tab.id] = tab
            if let loc = entry.location, ws.spaceIndex(loc.spaceId) != nil {
                ws.insertNode(.tab(tab.id), at: loc)
            } else {
                ws.spaces[ws.activeSpaceIndex].today.append(.tab(tab.id))
            }
            Self.activate(tab.id, in: &ws)
        }
        return tab.id
    }

    func updateURL(_ tabId: UUID, _ url: URL?) {
        guard workspace.tabs[tabId] != nil, workspace.tabs[tabId]?.url != url else { return }
        perform(nil) { $0.tabs[tabId]?.url = url }
    }

    func updateTitle(_ tabId: UUID, _ title: String) {
        guard workspace.tabs[tabId] != nil, workspace.tabs[tabId]?.title != title else { return }
        perform(nil) { $0.tabs[tabId]?.title = title }
    }

    /// Saves back/forward state for a tab whose web view is being unloaded.
    func setInteractionState(_ tabId: UUID, _ data: Data?) {
        guard workspace.tabs[tabId] != nil, workspace.tabs[tabId]?.interactionState != data else { return }
        perform(nil) { $0.tabs[tabId]?.interactionState = data }
    }

    func clearInteractionState(_ tabId: UUID) {
        guard workspace.tabs[tabId]?.interactionState != nil else { return }
        perform(nil) { $0.tabs[tabId]?.interactionState = nil }
    }

    // MARK: - Structure

    /// Several structural edits as one undoable step (AI customization tools and their undo).
    func update(_ actionName: String, _ change: (inout Workspace) -> Void) {
        perform(actionName, change)
    }

    func move(_ nodeId: UUID, to location: NodeLocation) {
        perform("Move") { _ = $0.moveNode(nodeId, to: location) }
    }

    func moveToFavorites(_ tabId: UUID, at index: Int? = nil) {
        let wasPersistent = workspace.isPersistent(tabId)
        perform("Add to Favorites") { $0.addToFavorites(tabId, at: index) }
        if !wasPersistent, workspace.isFavorite(tabId) { onTabPinned?(tabId) }
    }

    func pin(_ tabId: UUID, at index: Int? = nil) {
        let wasPersistent = workspace.isPersistent(tabId)
        perform("Pin Tab") { $0.pin(tabId, at: index) }
        if !wasPersistent, workspace.section(containing: tabId) == .pinned { onTabPinned?(tabId) }
    }

    /// nil restores the page's own title.
    func setCustomTitle(_ tabId: UUID, _ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        perform("Rename Tab") { $0.tabs[tabId]?.customTitle = (trimmed?.isEmpty ?? true) ? nil : trimmed }
    }

    /// Groups tabs into new folders in one undoable step (Tidy Today).
    func applyTidyGroups(_ groups: [LunaMax.Group], inSpace spaceId: UUID) {
        guard !groups.isEmpty else { return }
        perform("Tidy Tabs") { ws in
            for group in groups {
                let ids = group.tabIds.filter { ws.section(containing: $0) == .today && ws.spaceId(containing: $0) == spaceId }
                guard ids.count >= 2 else { continue }
                ids.forEach { ws.detachTabFromAnySplit($0) }
                guard let first = ws.location(ofNode: ids[0]) else { continue }
                var loc = NodeLocation(spaceId: spaceId, section: .today, parentFolderId: nil, index: first.parentFolderId == nil ? first.index : 0)
                loc.index = min(loc.index, ws.spaces[ws.spaceIndex(spaceId)!].today.count)
                ws.createFolder(name: group.name, containing: ids, at: loc)
            }
        }
    }

    func unpin(_ tabId: UUID) {
        perform("Unpin Tab") { $0.unpin(tabId) }
    }

    @discardableResult
    func createFolder(name: String = "New Folder", containing nodeIds: [UUID], at location: NodeLocation) -> UUID {
        var id = UUID()
        perform("New Folder") { id = $0.createFolder(name: name, containing: nodeIds, at: location) }
        return id
    }

    func renameFolder(_ id: UUID, to name: String) {
        perform("Rename Folder") { $0.updateFolder(id) { $0.name = name } }
    }

    func setFolderExpanded(_ id: UUID, _ expanded: Bool) {
        perform(nil) { $0.updateFolder(id) { $0.isExpanded = expanded } }
    }

    func ungroupFolder(_ id: UUID) {
        perform("Ungroup Folder") { $0.ungroupFolder(id) }
    }

    @discardableResult
    func split(_ tabIds: [UUID], axis: SplitAxis = .horizontal) -> UUID? {
        var id: UUID?
        perform("Split View") { id = $0.createSplit(tabIds, axis: axis) }
        return id
    }

    /// Drops one tab onto another to view them side by side.
    @discardableResult
    func splitTab(_ tabId: UUID, onto targetId: UUID) -> UUID? {
        var id: UUID?
        perform("Split View") { ws in
            id = ws.splitTab(tabId, onto: targetId)
            if id != nil { Self.activate(tabId, in: &ws) }
        }
        return id
    }

    /// Drag and drop: moves a tab, folder or split to a spot in the sidebar.
    func place(_ nodeId: UUID, at location: NodeLocation) {
        perform("Move") { _ = $0.placeNode(nodeId, at: location) }
    }

    func moveTab(_ tabId: UUID, nextTo targetId: UUID, after: Bool) {
        perform("Move") { $0.moveTab(tabId, nextTo: targetId, after: after) }
    }

    /// Takes a tab out of this window to move it to another one: removed
    /// without archiving, its neighbour (or split partner) selected. Returns it.
    func takeTab(_ tabId: UUID) -> Tab? {
        guard workspace.tabs[tabId] != nil else { return nil }
        var taken: Tab?
        perform("Move Tab to Window") { ws in
            let wasActive = ws.activeTabId == tabId
            let spaceId = ws.spaceId(containing: tabId) ?? ws.activeSpaceId
            let order = ws.orderedTabIds(inSpace: spaceId)
            let partner = ws.splitGroup(containing: tabId)?.panes.first { $0 != tabId }
            taken = ws.removeTab(tabId)
            taken?.savedURL = nil
            if wasActive, let i = order.firstIndex(of: tabId) {
                let remaining = order.filter { $0 != tabId }
                let next = partner ?? (remaining.isEmpty ? nil : remaining[max(0, min(i - 1, remaining.count - 1))])
                if let si = ws.spaceIndex(spaceId) { ws.spaces[si].activeTabId = next }
            }
        }
        return taken
    }

    /// Brings in a tab from another window, at the end of Today (or next to
    /// `target`, where it was dropped in the tab strip), and selects it.
    func adopt(_ tab: Tab, nextTo target: UUID? = nil, after: Bool = true) {
        var tab = tab
        tab.lastActiveAt = Date()
        perform("Move Tab to Window") { ws in
            ws.addTab(tab, placement: .section(.today, spaceId: nil))
            if let target, ws.tabs[target] != nil { ws.moveTab(tab.id, nextTo: target, after: after) }
            Self.activate(tab.id, in: &ws)
        }
    }

    func removeFromSplit(_ tabId: UUID) {
        perform("Remove from Split") { _ = $0.detachTabFromAnySplit(tabId) }
    }

    func dissolveSplit(_ id: UUID) {
        perform("Separate Split") { $0.dissolveSplit(id) }
    }

    func setSplitRatios(_ id: UUID, _ ratios: [Double]) {
        let total = ratios.reduce(0, +)
        guard total > 0 else { return }
        perform(nil) { ws in
            ws.updateSplit(id) { g in
                guard ratios.count == g.panes.count else { return }
                g.ratios = ratios.map { $0 / total }
            }
        }
    }

    /// One undoable change made outside the sidebar (e.g. importing bookmarks).
    func applyChange(_ actionName: String, _ change: (inout Workspace) -> Void) {
        perform(actionName, change)
    }

    // MARK: - Spaces

    @discardableResult
    func createSpace(name: String, icon: String = "circle.fill", theme: SpaceTheme = .system) -> UUID {
        var id = UUID()
        perform("New Space") { ws in
            id = ws.addSpace(name: name, icon: icon, theme: theme)
            ws.activeSpaceId = id
        }
        return id
    }

    func updateSpace(_ id: UUID, _ change: @escaping (inout Space) -> Void) {
        perform("Edit Space") { ws in
            guard let i = ws.spaceIndex(id) else { return }
            change(&ws.spaces[i])
        }
    }

    /// Returns the removed tab ids so callers can tear down web views.
    @discardableResult
    func deleteSpace(_ id: UUID) -> [UUID] {
        var removed: [UUID] = []
        perform("Delete Space") { removed = $0.removeSpace(id).map(\.id) }
        return removed
    }

    func switchSpace(_ id: UUID) {
        perform(nil) { ws in
            guard ws.spaceIndex(id) != nil else { return }
            ws.activeSpaceId = id
        }
    }

    func moveTab(_ tabId: UUID, toSpace spaceId: UUID) {
        perform("Move to Space") { $0.moveTab(tabId, toSpace: spaceId) }
    }

    // MARK: - Maintenance

    /// Arc-style auto-archive: closes Today tabs untouched for `age` seconds.
    /// The active tab of each space is kept. Returns the archived tab ids.
    @discardableResult
    func archiveStaleTodayTabs(olderThan age: TimeInterval, now: Date = Date()) -> [UUID] {
        let active = Set(workspace.spaces.compactMap(\.activeTabId))
        let stale = workspace.spaces.flatMap { $0.today.flatMap(\.tabIds) }.filter { id in
            guard !active.contains(id), let t = workspace.tabs[id] else { return false }
            return now.timeIntervalSince(t.lastActiveAt) > age
        }
        guard !stale.isEmpty else { return [] }
        perform(nil) { ws in
            for id in stale {
                if let tab = ws.removeTab(id) { ws.archive(tab) }
            }
        }
        return stale
    }

    // MARK: - Persistence

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
        persistence?.drain()
    }

    private func scheduleSave() {
        guard persistence != nil else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func saveNow() {
        guard let persistence else { return }
        var snapshot = workspace
        if let states = captureInteractionStates?() {
            for (id, data) in states where snapshot.tabs[id] != nil {
                snapshot.tabs[id]?.interactionState = data
            }
        }
        persistence.save(snapshot)
    }

    // MARK: - Helpers

    private static func activate(_ tabId: UUID, in ws: inout Workspace) {
        guard ws.tabs[tabId] != nil else { return }
        if let sid = ws.spaceId(containing: tabId) { ws.activeSpaceId = sid }
        ws.spaces[ws.activeSpaceIndex].activeTabId = tabId
        ws.tabs[tabId]?.lastActiveAt = Date()
    }
}

/// JSON file persistence for one profile's workspace. Writes happen on a
/// serial background queue; `drain()` blocks until they're on disk.
final class WorkspacePersistence {
    let fileURL: URL
    private let queue = DispatchQueue(label: "com.luna.workspace-save", qos: .utility)

    nonisolated deinit {}

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// An extra window's workspace, saved next to the profile's main one.
    static func forWindow(_ windowId: UUID, profileId: UUID, fileManager: FileManager = .default) -> WorkspacePersistence {
        let main = forProfile(profileId, fileManager: fileManager)
        return WorkspacePersistence(fileURL: main.fileURL.deletingLastPathComponent()
            .appendingPathComponent("window-\(windowId.uuidString).json"))
    }

    static func forProfile(_ profileId: UUID, fileManager: FileManager = .default) -> WorkspacePersistence {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Luna/Profiles/\(profileId.uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return WorkspacePersistence(fileURL: base.appendingPathComponent("workspace.json"))
    }

    func load() -> Workspace? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            let ws = try JSONDecoder().decode(Workspace.self, from: data)
            return ws.version <= Workspace.currentVersion ? ws : nil
        } catch {
            // Keep the unreadable file for inspection instead of overwriting it silently.
            let backup = fileURL.deletingPathExtension().appendingPathExtension("corrupt.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            print("WorkspacePersistence: failed to decode workspace (\(error)); backed up to \(backup.lastPathComponent)")
            return nil
        }
    }

    func save(_ workspace: Workspace) {
        let url = fileURL
        queue.async {
            do {
                let data = try JSONEncoder().encode(workspace)
                try data.write(to: url, options: .atomic)
            } catch {
                print("WorkspacePersistence: failed to save workspace: \(error)")
            }
        }
    }

    func drain() {
        queue.sync {}
    }
}

/// Only one window per profile persists its workspace; additional windows on
/// the same profile get an in-memory workspace so they never overwrite each
/// other's file (last-write-wins). Ownership is released when the store dies.
enum WorkspaceOwnership {
    private final class WeakStore {
        weak var store: WorkspaceStore?
        init(_ store: WorkspaceStore) { self.store = store }
    }
    private static var owners: [UUID: WeakStore] = [:]

    static func makeStore(for profileId: UUID, windowId: UUID? = nil) -> WorkspaceStore {
        // Extra windows always save to their own file.
        if let windowId { return WorkspaceStore(persistence: .forWindow(windowId, profileId: profileId)) }
        if owners[profileId]?.store != nil {
            return WorkspaceStore(persistence: nil)
        }
        let store = WorkspaceStore(persistence: .forProfile(profileId))
        owners[profileId] = WeakStore(store)
        return store
    }

    /// The live store that persists this profile's workspace, if a window has it open.
    static func owner(for profileId: UUID) -> WorkspaceStore? { owners[profileId]?.store }

    static func release(_ store: WorkspaceStore, profileId: UUID) {
        if owners[profileId]?.store === store { owners.removeValue(forKey: profileId) }
    }
}

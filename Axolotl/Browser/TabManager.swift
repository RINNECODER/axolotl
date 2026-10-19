import Foundation
import SwiftUI
import Combine

/// Compatibility facade over `WorkspaceStore` exposing the original flat tab API
/// (ordered list + URL/title lookups) used by the shell, CommandRouter and
/// SmartSearch. New code should talk to `WorkspaceStore` directly; this goes
/// away once the shell is rebuilt (see docs/ARC_REFACTOR_PLAN.md, phase 9).
final class TabManager: ObservableObject {
    let store: WorkspaceStore
    private var cancellable: AnyCancellable?

    // Opt out of the MainActor-isolated deinit synthesized under
    // SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor: the isolated executor hop
    // double-frees task-local storage on current macOS runtimes
    // (swiftlang/swift#88036) and aborts with a malloc error.
    nonisolated deinit {}

    init(store: WorkspaceStore = WorkspaceStore(persistence: nil)) {
        self.store = store
        cancellable = store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Visual order for the active space: favorites, pinned, today.
    var tabOrder: [UUID] { store.orderedTabIds }
    var tabURL: [UUID: URL?] { store.workspace.tabs.mapValues { $0.url } }
    var tabTitle: [UUID: String] { store.workspace.tabs.mapValues { $0.title } }
    var currentTab: UUID? { store.activeTabId }

    func newTab(url: URL?) -> UUID {
        store.newTab(url: url)
    }

    func closeTab(_ id: UUID) {
        store.close(id)
    }

    func switchToTab(_ id: UUID) {
        guard store.tab(id) != nil else { return }
        store.activate(id)
    }

    /// Switch to tab by index (0-based). Used for Cmd+1...9.
    func switchToTab(index: Int) {
        store.activate(index: index)
    }

    /// Reorder within the flat order (horizontal tab strip drag and drop):
    /// moves the tab at `sourceIndex` so it lands before the tab currently at
    /// `destinationIndex` (or at the end when `destinationIndex == count`).
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        let ids = tabOrder
        guard ids.indices.contains(sourceIndex), destinationIndex >= 0, destinationIndex <= ids.count,
              destinationIndex != sourceIndex, destinationIndex != sourceIndex + 1 else { return }
        let moving = ids[sourceIndex]
        if store.workspace.splitGroup(containing: moving) != nil { store.removeFromSplit(moving) }
        let ws = store.workspace

        if destinationIndex == ids.count {
            let space = store.activeSpace
            store.move(moving, to: NodeLocation(spaceId: space.id, section: .today, parentFolderId: nil, index: space.today.count))
            return
        }
        let target = ids[destinationIndex]
        if let favIndex = ws.favorites.firstIndex(of: target) {
            let adjusted = ws.favorites.firstIndex(of: moving).map { $0 < favIndex ? favIndex - 1 : favIndex } ?? favIndex
            store.moveToFavorites(moving, at: adjusted)
            return
        }
        // Insert before the target's top-level node (its split, if any).
        let anchor = ws.splitGroup(containing: target)?.id ?? target
        guard let loc = ws.location(ofNode: anchor) else { return }
        store.move(moving, to: loc)
    }

    func navigate(tab id: UUID, to url: URL) {
        store.updateURL(id, url)
    }

    func updateTitle(tab id: UUID, title: String) {
        store.updateTitle(id, title)
    }

    func navigateCurrentTab(to url: URL) {
        guard let currentId = currentTab else { return }
        store.updateURL(currentId, url)
    }

    func currentURL() -> URL? {
        guard let id = currentTab else { return nil }
        return store.tab(id)?.url
    }

    func currentIndex() -> Int? {
        guard let id = currentTab else { return nil }
        return tabOrder.firstIndex(of: id)
    }

    func tabCount() -> Int {
        tabOrder.count
    }
}

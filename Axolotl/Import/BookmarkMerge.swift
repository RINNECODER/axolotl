import Foundation

/// Imports used to land as pinned tabs in a workspace folder ("Imported from
/// Chrome"), which crowded the tab strip. They now go to the bookmark store;
/// this takes such an old folder back out so it can be moved there.
nonisolated extension Workspace {
    /// Removes the folder and its tabs; returns its contents as a bookmark tree (nil if it's gone).
    mutating func takeImportedFolder(_ id: UUID) -> [ImportedBookmark]? {
        guard case .folder(let folder)? = node(withId: id) else { return nil }
        func tree(_ nodes: [SidebarNode]) -> [ImportedBookmark] {
            nodes.flatMap { node -> [ImportedBookmark] in
                if case .folder(let f) = node { return [.folder(name: f.name, children: tree(f.children))] }
                return node.tabIds.compactMap { id in
                    guard let tab = tabs[id], let url = tab.savedURL ?? tab.url else { return nil }
                    return .link(title: tab.title, url: url)
                }
            }
        }
        let result = tree(folder.children)
        for tabId in SidebarNode.folder(folder).tabIds { removeTab(tabId) }
        _ = detachNode(id)
        return result
    }

    /// Normalized for duplicate checks: no fragment, no trailing slash, lowercase host.
    static func bookmarkKey(_ url: URL?) -> String? {
        guard let url, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = nil
        c.host = c.host?.lowercased()
        c.scheme = c.scheme?.lowercased()
        var s = c.string ?? url.absoluteString
        if s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

/// Keep-in-sync bookkeeping: links a source already imported once are not
/// imported again, so bookmarks the user deleted stay deleted.
nonisolated extension ImportedBookmark {
    /// The duplicate-check key of every link in `items`.
    static func keys(_ items: [ImportedBookmark]) -> Set<String> {
        items.reduce(into: Set<String>()) { all, item in
            switch item {
            case .link(_, let url): if let key = Workspace.bookmarkKey(url) { all.insert(key) }
            case .folder(_, let children): all.formUnion(keys(children))
            }
        }
    }

    /// `items` without the links whose key is in `keys`, and without folders left empty.
    static func removing(_ keys: Set<String>, from items: [ImportedBookmark]) -> [ImportedBookmark] {
        items.compactMap { item in
            switch item {
            case .link(_, let url): return Workspace.bookmarkKey(url).map(keys.contains) == true ? nil : item
            case .folder(let name, let children):
                let kept = removing(keys, from: children)
                return kept.isEmpty ? nil : .folder(name: name, children: kept)
            }
        }
    }
}

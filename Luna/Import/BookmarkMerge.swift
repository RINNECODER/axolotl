import Foundation

/// Imported bookmarks become pinned tabs inside one collapsed folder per source
/// ("Imported from Chrome"), mirroring the source's folder tree. Re-importing
/// merges into that folder: folders match by name, links by URL, so nothing is
/// duplicated and the user's own edits elsewhere are left alone.
nonisolated extension Workspace {
    struct BookmarkMergeResult: Equatable {
        /// nil when there was nothing to import and no folder yet.
        var folderId: UUID?
        var added: Int
    }

    /// - Parameters:
    ///   - existingFolderId: the folder a previous import created, if any.
    ///   - spaceId: where to create the folder the first time (default: active space).
    @discardableResult
    mutating func mergeImportedBookmarks(_ bookmarks: [ImportedBookmark], folderName: String,
                                         existingFolderId: UUID?, spaceId: UUID? = nil) -> BookmarkMergeResult {
        let rootId: UUID
        if let existingFolderId, case .folder? = node(withId: existingFolderId) {
            rootId = existingFolderId
        } else if let found = Self.pinnedFolder(named: folderName, in: self) {
            rootId = found
        } else {
            guard !bookmarks.isEmpty else { return BookmarkMergeResult(folderId: nil, added: 0) }
            let sid = spaceId.flatMap { spaceIndex($0) != nil ? $0 : nil } ?? activeSpaceId
            let folder = Folder(name: folderName, isExpanded: false)
            let count = spaces[spaceIndex(sid) ?? activeSpaceIndex].pinned.count
            insertNode(.folder(folder), at: NodeLocation(spaceId: sid, section: .pinned, parentFolderId: nil, index: count))
            rootId = folder.id
        }
        var added = 0
        var newTabs: [Tab] = []
        let snapshot = tabs
        updateFolder(rootId) { folder in
            Self.merge(bookmarks, into: &folder.children, tabs: snapshot, newTabs: &newTabs)
        }
        for tab in newTabs { tabs[tab.id] = tab }
        added = newTabs.count
        return BookmarkMergeResult(folderId: rootId, added: added)
    }

    private static func pinnedFolder(named name: String, in ws: Workspace) -> UUID? {
        for space in ws.spaces {
            for node in space.pinned {
                if case .folder(let f) = node, f.name == name { return f.id }
            }
        }
        return nil
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

    private static func merge(_ items: [ImportedBookmark], into list: inout [SidebarNode],
                              tabs: [UUID: Tab], newTabs: inout [Tab]) {
        var existing = Set(list.compactMap { node -> String? in
            guard case .tab(let id) = node, let tab = tabs[id] ?? newTabs.first(where: { $0.id == id }) else { return nil }
            return bookmarkKey(tab.savedURL ?? tab.url)
        })
        for item in items {
            switch item {
            case .link(let title, let url):
                guard let key = bookmarkKey(url), existing.insert(key).inserted else { continue }
                let tab = Tab(url: url, title: title.isEmpty ? (url.host ?? url.absoluteString) : title, savedURL: url)
                newTabs.append(tab)
                list.append(.tab(tab.id))
            case .folder(let name, let children):
                if let i = list.firstIndex(where: { if case .folder(let f) = $0 { return f.name == name }; return false }),
                   case .folder(var f) = list[i] {
                    merge(children, into: &f.children, tabs: tabs, newTabs: &newTabs)
                    list[i] = .folder(f)
                } else {
                    var children2: [SidebarNode] = []
                    merge(children, into: &children2, tabs: tabs, newTabs: &newTabs)
                    if !children2.isEmpty { list.append(.folder(Folder(name: name, isExpanded: false, children: children2))) }
                }
            }
        }
    }
}

import Foundation

// MARK: - Workspace model
//
// Pure value types describing everything a profile's sidebar shows: favorites,
// spaces, pinned/today lists, nested folders and split groups. All mutations go
// through `Workspace`'s methods (and from the UI via `WorkspaceStore`), so the
// tree invariant — every tab id appears in exactly one place — holds everywhere.

nonisolated struct Tab: Identifiable, Codable, Equatable {
    let id: UUID
    var url: URL?
    var title: String
    /// User- or AI-chosen name shown instead of the page title (Tidy Titles, Rename).
    var customTitle: String?
    /// Pinned/favorite tabs return here when "closed" (Arc-style reset).
    var savedURL: URL?
    var lastActiveAt: Date
    /// Opaque WKWebView back/forward state, captured on save and restored lazily.
    var interactionState: Data?

    init(id: UUID = UUID(), url: URL?, title: String = "", customTitle: String? = nil, savedURL: URL? = nil,
         lastActiveAt: Date = Date(), interactionState: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title
        self.customTitle = customTitle
        self.savedURL = savedURL
        self.lastActiveAt = lastActiveAt
        self.interactionState = interactionState
    }
}

nonisolated struct Folder: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var isExpanded: Bool
    var children: [SidebarNode]
    /// Chrome tab-group color (a `TabGroupColor` raw value). Kept as a string so an
    /// unknown value from a newer build can't fail decoding the whole workspace.
    var color: String?

    init(id: UUID = UUID(), name: String, isExpanded: Bool = true, children: [SidebarNode] = [],
         color: TabGroupColor? = nil) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
        self.children = children
        self.color = color?.rawValue
    }

    var tabIds: [UUID] { children.flatMap(\.tabIds) }

    /// Every folder is also a Chrome tab group; one without a color is grey.
    var groupColor: TabGroupColor { color.flatMap(TabGroupColor.init(rawValue:)) ?? .grey }
}

/// Chrome's nine tab-group colors, in its picker order.
nonisolated enum TabGroupColor: String, Codable, CaseIterable {
    case grey, blue, red, yellow, green, pink, purple, cyan, orange
}

nonisolated enum SplitAxis: String, Codable, Equatable {
    case horizontal  // panes side by side
    case vertical    // panes stacked
}

nonisolated struct SplitGroup: Identifiable, Codable, Equatable {
    static let maxPanes = 4

    let id: UUID
    var panes: [UUID]
    var axis: SplitAxis
    /// Fraction of the available space per pane; always sums to 1.
    var ratios: [Double]

    init(id: UUID = UUID(), panes: [UUID], axis: SplitAxis = .horizontal) {
        self.id = id
        self.panes = panes
        self.axis = axis
        self.ratios = SplitGroup.evenRatios(panes.count)
    }

    static func evenRatios(_ count: Int) -> [Double] {
        count > 0 ? Array(repeating: 1.0 / Double(count), count: count) : []
    }
}

nonisolated indirect enum SidebarNode: Identifiable, Codable, Equatable {
    case tab(UUID)
    case folder(Folder)
    case split(SplitGroup)

    var id: UUID {
        switch self {
        case .tab(let id): return id
        case .folder(let f): return f.id
        case .split(let s): return s.id
        }
    }

    /// Every tab id contained in this node, in visual order.
    var tabIds: [UUID] {
        switch self {
        case .tab(let id): return [id]
        case .folder(let f): return f.children.flatMap(\.tabIds)
        case .split(let s): return s.panes
        }
    }
}

// On disk: {"type":"tab","id":…} / {"type":"folder","folder":{…}} / {"type":"split","split":{…}}
extension SidebarNode {
    private enum CodingKeys: String, CodingKey { case type, id, folder, split }
    private enum Kind: String, Codable { case tab, folder, split }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .tab: self = .tab(try c.decode(UUID.self, forKey: .id))
        case .folder: self = .folder(try c.decode(Folder.self, forKey: .folder))
        case .split: self = .split(try c.decode(SplitGroup.self, forKey: .split))
        }
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tab(let id):
            try c.encode(Kind.tab, forKey: .type)
            try c.encode(id, forKey: .id)
        case .folder(let f):
            try c.encode(Kind.folder, forKey: .type)
            try c.encode(f, forKey: .folder)
        case .split(let g):
            try c.encode(Kind.split, forKey: .type)
            try c.encode(g, forKey: .split)
        }
    }
}

nonisolated struct SpaceTheme: Codable, Equatable {
    /// Hex colors for the sidebar gradient (1 = flat). Empty = follow system.
    var colors: [String]

    static let system = SpaceTheme(colors: [])
}

nonisolated struct Space: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var theme: SpaceTheme
    var pinned: [SidebarNode]
    var today: [SidebarNode]
    var activeTabId: UUID?

    init(id: UUID = UUID(), name: String, icon: String = "circle.fill", theme: SpaceTheme = .system,
         pinned: [SidebarNode] = [], today: [SidebarNode] = [], activeTabId: UUID? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.theme = theme
        self.pinned = pinned
        self.today = today
        self.activeTabId = activeTabId
    }
}

nonisolated enum SidebarSection: String, Codable, Equatable {
    case pinned
    case today
}

/// Where a node sits (or should be inserted). `parentFolderId == nil` means the
/// section's root list. `index` is clamped on insert.
nonisolated struct NodeLocation: Equatable {
    var spaceId: UUID
    var section: SidebarSection
    var parentFolderId: UUID?
    var index: Int

    func isSameList(as other: NodeLocation) -> Bool {
        spaceId == other.spaceId && section == other.section && parentFolderId == other.parentFolderId
    }
}

nonisolated struct ArchivedTab: Codable, Equatable {
    var tab: Tab
    var closedAt: Date
}

nonisolated enum TabPlacement: Equatable {
    case favorites
    case section(SidebarSection, spaceId: UUID?)
}

// MARK: - Workspace

nonisolated struct Workspace: Codable, Equatable {
    static let currentVersion = 1
    static let archiveLimit = 200

    var version: Int = Workspace.currentVersion
    var favorites: [UUID] = []
    var spaces: [Space]
    var activeSpaceId: UUID
    var tabs: [UUID: Tab] = [:]
    var archive: [ArchivedTab] = []

    private enum CodingKeys: String, CodingKey {
        case version, favorites, spaces, activeSpaceId, tabs, archive
    }

    init(spaces: [Space]? = nil) {
        let initial = spaces ?? [Space(name: "Home", icon: "house.fill")]
        self.spaces = initial
        self.activeSpaceId = initial[0].id
    }

    // Tabs are stored as an array on disk (UUID-keyed dictionaries encode as
    // alternating key/value arrays, which is unreadable and brittle).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Workspace.currentVersion
        favorites = try c.decodeIfPresent([UUID].self, forKey: .favorites) ?? []
        spaces = try c.decode([Space].self, forKey: .spaces)
        activeSpaceId = try c.decode(UUID.self, forKey: .activeSpaceId)
        let list = try c.decodeIfPresent([Tab].self, forKey: .tabs) ?? []
        tabs = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        archive = try c.decodeIfPresent([ArchivedTab].self, forKey: .archive) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(favorites, forKey: .favorites)
        try c.encode(spaces, forKey: .spaces)
        try c.encode(activeSpaceId, forKey: .activeSpaceId)
        try c.encode(allPlacedTabIds.compactMap { tabs[$0] }, forKey: .tabs)
        try c.encode(archive, forKey: .archive)
    }

    // MARK: Lookup

    var activeSpaceIndex: Int {
        spaces.firstIndex { $0.id == activeSpaceId } ?? 0
    }

    var activeSpace: Space { spaces[activeSpaceIndex] }

    var activeTabId: UUID? { activeSpace.activeTabId }

    func spaceIndex(_ id: UUID) -> Int? { spaces.firstIndex { $0.id == id } }

    /// Tabs in visual order for a space: favorites, then pinned, then today.
    /// This is the order used by Cmd+1…9 and the horizontal tab strip.
    func orderedTabIds(inSpace spaceId: UUID? = nil) -> [UUID] {
        guard let idx = spaceIndex(spaceId ?? activeSpaceId) else { return favorites }
        let space = spaces[idx]
        return favorites + space.pinned.flatMap(\.tabIds) + space.today.flatMap(\.tabIds)
    }

    /// Every tab id referenced by the tree, in visual order across all spaces.
    var allPlacedTabIds: [UUID] {
        favorites + spaces.flatMap { $0.pinned.flatMap(\.tabIds) + $0.today.flatMap(\.tabIds) }
    }

    func isFavorite(_ tabId: UUID) -> Bool { favorites.contains(tabId) }

    /// The active tab, or every pane of the split it belongs to.
    var visibleTabIds: [UUID] {
        guard let active = activeTabId else { return [] }
        return splitGroup(containing: active)?.panes ?? [active]
    }

    /// The space containing the tab (nil for favorites or unknown tabs).
    func spaceId(containing tabId: UUID) -> UUID? {
        spaces.first { s in s.pinned.contains { $0.tabIds.contains(tabId) } || s.today.contains { $0.tabIds.contains(tabId) } }?.id
    }

    func section(containing tabId: UUID) -> SidebarSection? {
        for s in spaces {
            if s.pinned.contains(where: { $0.tabIds.contains(tabId) }) { return .pinned }
            if s.today.contains(where: { $0.tabIds.contains(tabId) }) { return .today }
        }
        return nil
    }

    /// Pinned and favorite tabs persist across "close"; today tabs do not.
    func isPersistent(_ tabId: UUID) -> Bool {
        isFavorite(tabId) || section(containing: tabId) == .pinned
    }

    func splitGroup(containing tabId: UUID) -> SplitGroup? {
        for s in spaces {
            for list in [s.pinned, s.today] {
                if let g = Self.findSplit(containing: tabId, in: list) { return g }
            }
        }
        return nil
    }

    func node(withId id: UUID) -> SidebarNode? {
        for s in spaces {
            for list in [s.pinned, s.today] {
                if let n = Self.findNode(id, in: list) { return n }
            }
        }
        return nil
    }

    func location(ofNode id: UUID) -> NodeLocation? {
        for s in spaces {
            for section in [SidebarSection.pinned, .today] {
                if let (parent, index) = Self.findPosition(id, in: s[section], parent: nil) {
                    return NodeLocation(spaceId: s.id, section: section, parentFolderId: parent, index: index)
                }
            }
        }
        return nil
    }

    // MARK: Tabs

    @discardableResult
    mutating func addTab(_ tab: Tab, placement: TabPlacement, index: Int? = nil) -> UUID {
        tabs[tab.id] = tab
        switch placement {
        case .favorites:
            favorites.insert(tab.id, at: Self.clamp(index ?? favorites.count, favorites.count))
        case .section(let section, let sid):
            let si = sid.flatMap(spaceIndex) ?? activeSpaceIndex
            let list = spaces[si][section]
            spaces[si][section].insert(.tab(tab.id), at: Self.clamp(index ?? list.count, list.count))
        }
        return tab.id
    }

    /// Removes the tab from the tree and the tab table. Splits that drop to one
    /// pane collapse back into a plain tab. Returns the removed tab.
    @discardableResult
    mutating func removeTab(_ tabId: UUID) -> Tab? {
        favorites.removeAll { $0 == tabId }
        for i in spaces.indices {
            spaces[i].pinned = Self.removingTab(tabId, from: spaces[i].pinned)
            spaces[i].today = Self.removingTab(tabId, from: spaces[i].today)
            if spaces[i].activeTabId == tabId { spaces[i].activeTabId = nil }
        }
        return tabs.removeValue(forKey: tabId)
    }

    mutating func archive(_ tab: Tab) {
        guard let url = tab.url, url.absoluteString != "about:blank" else { return }
        archive.insert(ArchivedTab(tab: tab, closedAt: Date()), at: 0)
        if archive.count > Self.archiveLimit { archive.removeLast(archive.count - Self.archiveLimit) }
    }

    // MARK: Nodes

    /// Detaches a node (tab, folder or split) from wherever it lives.
    mutating func detachNode(_ id: UUID) -> SidebarNode? {
        if let i = favorites.firstIndex(of: id) {
            favorites.remove(at: i)
            return .tab(id)
        }
        for si in spaces.indices {
            for section in [SidebarSection.pinned, .today] {
                var list = spaces[si][section]
                if let node = Self.detach(id, from: &list) {
                    spaces[si][section] = list
                    return node
                }
            }
        }
        return nil
    }

    /// Inserts a node at a location. Inserting into a folder that doesn't exist
    /// falls back to the section root.
    mutating func insertNode(_ node: SidebarNode, at loc: NodeLocation) {
        let si = spaceIndex(loc.spaceId) ?? activeSpaceIndex
        var list = spaces[si][loc.section]
        if let parent = loc.parentFolderId, Self.insert(node, intoFolder: parent, at: loc.index, in: &list) {
            spaces[si][loc.section] = list
        } else {
            list.insert(node, at: Self.clamp(loc.index, list.count))
            spaces[si][loc.section] = list
        }
    }

    /// Moves a node. Returns false (and changes nothing) for illegal moves such as
    /// dropping a folder into itself.
    @discardableResult
    mutating func moveNode(_ id: UUID, to loc: NodeLocation) -> Bool {
        if let parent = loc.parentFolderId {
            if parent == id { return false }
            if case .folder(let f)? = node(withId: id), Self.findNode(parent, in: f.children) != nil { return false }
        }
        var dest = loc
        // Moving within the same list: account for the removal shifting indices.
        if let from = location(ofNode: id), from.isSameList(as: loc), from.index < loc.index {
            dest.index -= 1
        }
        guard let node = detachNode(id) else { return false }
        insertNode(node, at: dest)
        return true
    }

    // MARK: Favorites & pinning

    mutating func addToFavorites(_ tabId: UUID, at index: Int? = nil) {
        guard tabs[tabId] != nil else { return }
        if let current = favorites.firstIndex(of: tabId) {
            // Reorder within favorites; `index` is relative to the list without this tab.
            favorites.remove(at: current)
            favorites.insert(tabId, at: Self.clamp(index ?? favorites.count, favorites.count))
            return
        }
        _ = detachTabFromAnySplit(tabId)
        _ = detachNode(tabId)
        favorites.insert(tabId, at: Self.clamp(index ?? favorites.count, favorites.count))
        let url = tabs[tabId]?.url
        tabs[tabId]?.savedURL = url
    }

    mutating func pin(_ tabId: UUID, at index: Int? = nil) {
        guard tabs[tabId] != nil, section(containing: tabId) != .pinned || isFavorite(tabId) else { return }
        let sid = spaceId(containing: tabId) ?? activeSpaceId
        _ = detachTabFromAnySplit(tabId)
        _ = detachNode(tabId)
        insertNode(.tab(tabId), at: NodeLocation(spaceId: sid, section: .pinned, parentFolderId: nil,
                                                 index: index ?? (spaces[spaceIndex(sid)!].pinned.count)))
        let url = tabs[tabId]?.url
        tabs[tabId]?.savedURL = url
    }

    /// Moves a pinned/favorite tab to the top of Today in its space.
    mutating func unpin(_ tabId: UUID) {
        guard isPersistent(tabId) else { return }
        let sid = spaceId(containing: tabId) ?? activeSpaceId
        _ = detachTabFromAnySplit(tabId)
        _ = detachNode(tabId)
        insertNode(.tab(tabId), at: NodeLocation(spaceId: sid, section: .today, parentFolderId: nil, index: 0))
        tabs[tabId]?.savedURL = nil
    }

    // MARK: Folders

    @discardableResult
    mutating func createFolder(name: String, containing nodeIds: [UUID], at loc: NodeLocation,
                               color: TabGroupColor? = nil) -> UUID {
        var children: [SidebarNode] = []
        var dest = loc
        for id in nodeIds {
            // Keep the insertion point stable as nodes above it in the same list are removed.
            if let from = location(ofNode: id), from.isSameList(as: dest), from.index < dest.index {
                dest.index -= 1
            }
            if let n = detachNode(id) { children.append(n) }
        }
        let folder = Folder(name: name, children: children, color: color)
        insertNode(.folder(folder), at: dest)
        return folder.id
    }

    // MARK: Tab groups (Chrome)

    /// The active space's tab groups: its top-level Today folders, as the strip shows them.
    var tabGroups: [Folder] {
        activeSpace.today.compactMap { if case .folder(let f) = $0 { return f } else { return nil } }
    }

    /// The tab group (top-level Today folder of the active space) a tab sits in, at any depth.
    func tabGroup(containing tabId: UUID) -> Folder? {
        tabGroups.first { $0.tabIds.contains(tabId) }
    }

    /// Chrome picks the first color no group in the space uses yet.
    func nextGroupColor() -> TabGroupColor {
        let used = Set(tabGroups.map(\.groupColor))
        return TabGroupColor.allCases.first { !used.contains($0) } ?? .grey
    }

    /// Wraps a Today tab in a new, unnamed group where it is. Nil for favorites and pinned tabs.
    @discardableResult
    mutating func addToNewTabGroup(_ tabId: UUID) -> UUID? {
        guard tabs[tabId] != nil, section(containing: tabId) == .today else { return nil }
        if let g = tabGroup(containing: tabId), g.tabIds.count == 1 { return g.id }
        let color = nextGroupColor()
        _ = detachTabFromAnySplit(tabId)
        removeFromTabGroup(tabId)
        guard let loc = location(ofNode: tabId) else { return nil }
        return createFolder(name: "", containing: [tabId], at: loc, color: color)
    }

    /// Moves a Today tab to the end of a group in the same space.
    @discardableResult
    mutating func addToTabGroup(_ tabId: UUID, group groupId: UUID) -> Bool {
        guard tabs[tabId] != nil, section(containing: tabId) == .today,
              tabGroup(containing: tabId)?.id != groupId,
              let gloc = location(ofNode: groupId), gloc.parentFolderId == nil, gloc.section == .today,
              case .folder? = node(withId: groupId) else { return false }
        _ = detachTabFromAnySplit(tabId)
        guard case .folder(let g)? = node(withId: groupId) else { return false }
        return placeNode(tabId, at: NodeLocation(spaceId: gloc.spaceId, section: .today, parentFolderId: groupId,
                                                 index: g.children.count))
    }

    /// Takes a tab out of its group, just after the group (Chrome); an emptied group goes away.
    mutating func removeFromTabGroup(_ tabId: UUID) {
        guard let g = tabGroup(containing: tabId), let gloc = location(ofNode: g.id) else { return }
        _ = detachTabFromAnySplit(tabId)
        _ = placeNode(tabId, at: NodeLocation(spaceId: gloc.spaceId, section: .today, parentFolderId: nil,
                                              index: gloc.index + 1))
        if case .folder(let f)? = node(withId: g.id), f.tabIds.isEmpty { ungroupFolder(g.id) }
    }

    mutating func updateFolder(_ id: UUID, _ change: (inout Folder) -> Void) {
        for si in spaces.indices {
            for section in [SidebarSection.pinned, .today] {
                var list = spaces[si][section]
                if Self.mutateFolder(id, in: &list, change) {
                    spaces[si][section] = list
                    return
                }
            }
        }
    }

    /// Replaces a folder with its children, in place.
    mutating func ungroupFolder(_ id: UUID) {
        guard let loc = location(ofNode: id), case .folder(let f)? = detachNode(id) else { return }
        for (offset, child) in f.children.enumerated() {
            insertNode(child, at: NodeLocation(spaceId: loc.spaceId, section: loc.section,
                                               parentFolderId: loc.parentFolderId, index: loc.index + offset))
        }
    }

    // MARK: Splits

    /// Groups tabs into a split placed where the first tab was. Favorites can't
    /// be split (they live in the grid); they are skipped.
    @discardableResult
    mutating func createSplit(_ tabIds: [UUID], axis: SplitAxis = .horizontal) -> UUID? {
        let ids = Array(tabIds.filter { tabs[$0] != nil && !isFavorite($0) }.prefix(SplitGroup.maxPanes))
        guard ids.count >= 2 else { return nil }
        for id in ids { detachTabFromAnySplit(id) }
        guard var loc = location(ofNode: ids[0]) else { return nil }
        for id in ids {
            if let from = location(ofNode: id), from.isSameList(as: loc), from.index < loc.index { loc.index -= 1 }
            _ = detachNode(id)
        }
        let group = SplitGroup(panes: ids, axis: axis)
        insertNode(.split(group), at: loc)
        return group.id
    }

    /// Puts a split back as it was (same id, axis and ratios) at `loc`, pulling its panes out
    /// of wherever they are now. Panes that are gone are skipped.
    mutating func restoreSplit(_ group: SplitGroup, at loc: NodeLocation) {
        let panes = group.panes.filter { tabs[$0] != nil && !isFavorite($0) }
        guard panes.count >= 2 else { return }
        for id in panes {
            _ = detachTabFromAnySplit(id)
            _ = detachNode(id)
        }
        var restored = group
        if panes != group.panes {
            restored.panes = panes
            restored.ratios = SplitGroup.evenRatios(panes.count)
        }
        insertNode(.split(restored), at: loc)
    }

    /// Adds a tab to an existing split as a new pane (at `index`, default last).
    /// Returns false when the split is full, missing, or the tab can't be split.
    @discardableResult
    mutating func addToSplit(_ tabId: UUID, group groupId: UUID, at index: Int? = nil) -> Bool {
        guard tabs[tabId] != nil, !isFavorite(tabId),
              case .split(let g)? = node(withId: groupId), !g.panes.contains(tabId),
              g.panes.count < SplitGroup.maxPanes else { return false }
        _ = detachTabFromAnySplit(tabId)
        _ = detachNode(tabId)
        updateSplit(groupId) { g in
            g.panes.insert(tabId, at: Self.clamp(index ?? g.panes.count, g.panes.count))
            g.ratios = SplitGroup.evenRatios(g.panes.count)
        }
        return true
    }

    /// Drag-and-drop split: drops `tabId` onto `targetId`. Joins the target's
    /// split if it has one, otherwise makes a new split where the target is,
    /// with the dropped tab on the right. Returns the split id.
    @discardableResult
    mutating func splitTab(_ tabId: UUID, onto targetId: UUID) -> UUID? {
        guard tabId != targetId, tabs[tabId] != nil, tabs[targetId] != nil,
              !isFavorite(tabId), !isFavorite(targetId) else { return nil }
        if let g = splitGroup(containing: targetId) {
            if g.panes.contains(tabId) { return g.id }
            let at = (g.panes.firstIndex(of: targetId) ?? g.panes.count - 1) + 1
            return addToSplit(tabId, group: g.id, at: at) ? g.id : nil
        }
        _ = detachTabFromAnySplit(tabId)
        return createSplit([targetId, tabId])
    }

    /// Moves a tab right before or after another tab in the sidebar tree
    /// (into the other tab's folder; next to its split if it has one).
    /// Favorites reorder within the favorites list.
    mutating func moveTab(_ tabId: UUID, nextTo targetId: UUID, after: Bool) {
        guard tabId != targetId, tabs[tabId] != nil, tabs[targetId] != nil else { return }
        if let fi = favorites.firstIndex(of: targetId) {
            var index = fi + (after ? 1 : 0)
            if let current = favorites.firstIndex(of: tabId), current < index { index -= 1 }
            addToFavorites(tabId, at: index)
            return
        }
        _ = detachTabFromAnySplit(tabId)
        let anchor = splitGroup(containing: targetId)?.id ?? targetId
        guard var loc = location(ofNode: anchor) else { return }
        if after { loc.index += 1 }
        placeNode(tabId, at: loc)
    }

    /// Moves any node (tab, folder, split) to a location, keeping pin state in
    /// step with the section: tabs landing in Pinned remember their page,
    /// tabs landing in Today forget it. Returns false for illegal moves.
    @discardableResult
    mutating func placeNode(_ id: UUID, at loc: NodeLocation) -> Bool {
        if isFavorite(id) {
            // A favorite becomes a regular tab where it's dropped.
            favorites.removeAll { $0 == id }
            insertNode(.tab(id), at: loc)
        } else if !moveNode(id, to: loc) {
            return false
        }
        for tabId in node(withId: id)?.tabIds ?? [] {
            if loc.section == .pinned, tabs[tabId]?.savedURL == nil {
                let url = tabs[tabId]?.url
                tabs[tabId]?.savedURL = url
            }
            if loc.section == .today { tabs[tabId]?.savedURL = nil }
        }
        return true
    }

    /// Replaces a split with its panes as individual tabs, in place.
    mutating func dissolveSplit(_ id: UUID) {
        guard let loc = location(ofNode: id), case .split(let g)? = detachNode(id) else { return }
        for (offset, tabId) in g.panes.enumerated() {
            insertNode(.tab(tabId), at: NodeLocation(spaceId: loc.spaceId, section: loc.section,
                                                     parentFolderId: loc.parentFolderId, index: loc.index + offset))
        }
    }

    mutating func updateSplit(_ id: UUID, _ change: (inout SplitGroup) -> Void) {
        for si in spaces.indices {
            for section in [SidebarSection.pinned, .today] {
                var list = spaces[si][section]
                if Self.mutateSplit(id, in: &list, change) {
                    spaces[si][section] = list
                    return
                }
            }
        }
    }

    /// If the tab is a split pane, pulls it out (collapsing the split if needed)
    /// and leaves it as a plain tab right after the split. Returns that location.
    @discardableResult
    mutating func detachTabFromAnySplit(_ tabId: UUID) -> NodeLocation? {
        guard let group = splitGroup(containing: tabId), let loc = location(ofNode: group.id) else { return nil }
        let remaining = group.panes.filter { $0 != tabId }
        _ = detachNode(group.id)
        if remaining.count >= 2 {
            var g = group
            g.panes = remaining
            g.ratios = SplitGroup.evenRatios(remaining.count)
            insertNode(.split(g), at: loc)
        } else {
            insertNode(.tab(remaining[0]), at: loc)
        }
        var after = loc
        after.index += 1
        insertNode(.tab(tabId), at: after)
        return after
    }

    // MARK: Spaces

    @discardableResult
    mutating func addSpace(name: String, icon: String = "circle.fill", theme: SpaceTheme = .system) -> UUID {
        let s = Space(name: name, icon: icon, theme: theme)
        spaces.append(s)
        return s.id
    }

    /// Deletes a space and its tabs. The last space can't be deleted.
    /// Returns the removed tabs so callers can tear down their web views.
    mutating func removeSpace(_ id: UUID) -> [Tab] {
        guard spaces.count > 1, let si = spaceIndex(id) else { return [] }
        let removed = (spaces[si].pinned + spaces[si].today).flatMap(\.tabIds).compactMap { tabs.removeValue(forKey: $0) }
        spaces.remove(at: si)
        if activeSpaceId == id { activeSpaceId = spaces[max(0, si - 1)].id }
        return removed
    }

    mutating func moveTab(_ tabId: UUID, toSpace spaceId: UUID) {
        guard spaceIndex(spaceId) != nil, !isFavorite(tabId) else { return }
        let section = self.section(containing: tabId) ?? .today
        _ = detachTabFromAnySplit(tabId)
        _ = detachNode(tabId)
        for i in spaces.indices where spaces[i].activeTabId == tabId { spaces[i].activeTabId = nil }
        let count = spaces[spaceIndex(spaceId)!][section].count
        insertNode(.tab(tabId), at: NodeLocation(spaceId: spaceId, section: section, parentFolderId: nil,
                                                 index: section == .today ? 0 : count))
    }

    // MARK: Integrity

    /// Returns a description of each invariant violation (empty = valid).
    func integrityProblems() -> [String] {
        var problems: [String] = []
        let placed = allPlacedTabIds
        let dupes = Dictionary(grouping: placed, by: { $0 }).filter { $0.value.count > 1 }.keys
        if !dupes.isEmpty { problems.append("tabs placed more than once: \(dupes)") }
        let placedSet = Set(placed)
        let tableSet = Set(tabs.keys)
        if placedSet != tableSet {
            problems.append("orphaned=\(tableSet.subtracting(placedSet)) dangling=\(placedSet.subtracting(tableSet))")
        }
        for s in spaces {
            for list in [s.pinned, s.today] {
                Self.forEachSplit(in: list) { g in
                    if g.panes.count < 2 || g.panes.count > SplitGroup.maxPanes { problems.append("split \(g.id) has \(g.panes.count) panes") }
                    if g.ratios.count != g.panes.count { problems.append("split \(g.id) ratio count mismatch") }
                }
            }
            if let a = s.activeTabId, !orderedTabIds(inSpace: s.id).contains(a) {
                problems.append("space \(s.name) active tab not in space")
            }
        }
        if spaceIndex(activeSpaceId) == nil { problems.append("active space missing") }
        return problems
    }

    /// Repairs a decoded workspace so it always satisfies the invariants
    /// (drops dangling ids, re-homes orphaned tabs into Today).
    mutating func repair() {
        if spaces.isEmpty { spaces = [Space(name: "Home", icon: "house.fill")] }
        if spaceIndex(activeSpaceId) == nil { activeSpaceId = spaces[0].id }
        var seen = Set<UUID>()
        favorites = favorites.filter { tabs[$0] != nil && seen.insert($0).inserted }
        for i in spaces.indices {
            spaces[i].pinned = Self.sanitized(spaces[i].pinned, tabs: tabs, seen: &seen)
            spaces[i].today = Self.sanitized(spaces[i].today, tabs: tabs, seen: &seen)
        }
        for id in tabs.keys where !seen.contains(id) {
            spaces[activeSpaceIndex].today.append(.tab(id))
            seen.insert(id)
        }
        for i in spaces.indices {
            if let a = spaces[i].activeTabId, !orderedTabIds(inSpace: spaces[i].id).contains(a) {
                spaces[i].activeTabId = nil
            }
        }
    }

    // MARK: - Tree helpers

    private static func clamp(_ i: Int, _ count: Int) -> Int { min(max(0, i), count) }

    private static func findNode(_ id: UUID, in list: [SidebarNode]) -> SidebarNode? {
        for n in list {
            if n.id == id { return n }
            if case .folder(let f) = n, let found = findNode(id, in: f.children) { return found }
        }
        return nil
    }

    private static func findSplit(containing tabId: UUID, in list: [SidebarNode]) -> SplitGroup? {
        for n in list {
            switch n {
            case .split(let g) where g.panes.contains(tabId): return g
            case .folder(let f): if let g = findSplit(containing: tabId, in: f.children) { return g }
            default: break
            }
        }
        return nil
    }

    private static func forEachSplit(in list: [SidebarNode], _ body: (SplitGroup) -> Void) {
        for n in list {
            switch n {
            case .split(let g): body(g)
            case .folder(let f): forEachSplit(in: f.children, body)
            case .tab: break
            }
        }
    }

    private static func findPosition(_ id: UUID, in list: [SidebarNode], parent: UUID?) -> (UUID?, Int)? {
        for (i, n) in list.enumerated() {
            if n.id == id { return (parent, i) }
            if case .folder(let f) = n, let found = findPosition(id, in: f.children, parent: f.id) { return found }
        }
        return nil
    }

    private static func detach(_ id: UUID, from list: inout [SidebarNode]) -> SidebarNode? {
        if let i = list.firstIndex(where: { $0.id == id }) { return list.remove(at: i) }
        for i in list.indices {
            if case .folder(var f) = list[i], let found = detach(id, from: &f.children) {
                list[i] = .folder(f)
                return found
            }
        }
        return nil
    }

    private static func insert(_ node: SidebarNode, intoFolder folderId: UUID, at index: Int, in list: inout [SidebarNode]) -> Bool {
        for i in list.indices {
            guard case .folder(var f) = list[i] else { continue }
            if f.id == folderId {
                f.children.insert(node, at: clamp(index, f.children.count))
                list[i] = .folder(f)
                return true
            }
            if insert(node, intoFolder: folderId, at: index, in: &f.children) {
                list[i] = .folder(f)
                return true
            }
        }
        return false
    }

    private static func mutateFolder(_ id: UUID, in list: inout [SidebarNode], _ change: (inout Folder) -> Void) -> Bool {
        for i in list.indices {
            guard case .folder(var f) = list[i] else { continue }
            if f.id == id {
                change(&f)
                list[i] = .folder(f)
                return true
            }
            if mutateFolder(id, in: &f.children, change) {
                list[i] = .folder(f)
                return true
            }
        }
        return false
    }

    private static func mutateSplit(_ id: UUID, in list: inout [SidebarNode], _ change: (inout SplitGroup) -> Void) -> Bool {
        for i in list.indices {
            switch list[i] {
            case .split(var g) where g.id == id:
                change(&g)
                list[i] = .split(g)
                return true
            case .folder(var f):
                if mutateSplit(id, in: &f.children, change) {
                    list[i] = .folder(f)
                    return true
                }
            default: break
            }
        }
        return false
    }

    private static func removingTab(_ tabId: UUID, from list: [SidebarNode]) -> [SidebarNode] {
        list.compactMap { node in
            switch node {
            case .tab(let id):
                return id == tabId ? nil : node
            case .folder(var f):
                f.children = removingTab(tabId, from: f.children)
                return .folder(f)
            case .split(var g):
                guard g.panes.contains(tabId) else { return node }
                g.panes.removeAll { $0 == tabId }
                if g.panes.count < 2 { return g.panes.first.map { .tab($0) } }
                g.ratios = SplitGroup.evenRatios(g.panes.count)
                return .split(g)
            }
        }
    }

    private static func sanitized(_ list: [SidebarNode], tabs: [UUID: Tab], seen: inout Set<UUID>) -> [SidebarNode] {
        list.compactMap { node in
            switch node {
            case .tab(let id):
                return (tabs[id] != nil && seen.insert(id).inserted) ? node : nil
            case .folder(var f):
                f.children = sanitized(f.children, tabs: tabs, seen: &seen)
                if let c = f.color, TabGroupColor(rawValue: c) == nil { f.color = nil }
                return .folder(f)
            case .split(var g):
                g.panes = g.panes.filter { tabs[$0] != nil && seen.insert($0).inserted }
                if g.panes.count < 2 { return g.panes.first.map { .tab($0) } }
                if g.panes.count > SplitGroup.maxPanes {
                    // Can't happen via the API; keep the first maxPanes and release the rest.
                    g.panes.dropFirst(SplitGroup.maxPanes).forEach { seen.remove($0) }
                    g.panes = Array(g.panes.prefix(SplitGroup.maxPanes))
                }
                if g.ratios.count != g.panes.count { g.ratios = SplitGroup.evenRatios(g.panes.count) }
                return .split(g)
            }
        }
    }
}

extension Space {
    nonisolated subscript(section: SidebarSection) -> [SidebarNode] {
        get { section == .pinned ? pinned : today }
        set { if section == .pinned { pinned = newValue } else { today = newValue } }
    }
}

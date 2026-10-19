import Combine
import Foundation

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: URL
    /// The folder it's in: nil is the bookmarks bar, `BookmarkStore.otherBookmarksId` is "Other bookmarks".
    var parentId: UUID?
    /// A folder; its `url` is a placeholder.
    var isFolder = false
}

extension Bookmark {
    /// Files written before folders existed have no `parentId`/`isFolder`: they load as bar bookmarks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(URL.self, forKey: .url)
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        isFolder = try c.decodeIfPresent(Bool.self, forKey: .isFolder) ?? false
    }
}

/// A profile's bookmarks and folders, shown in the bookmarks bar (Settings → Appearance) and axolotl://bookmarks.
/// Stored with the profile's other data (Application Support/Axolotl/Profiles/<id>/bookmarks.json) as one flat
/// ordered array; an item's `parentId` places it in a folder.
final class BookmarkStore: ObservableObject {
    /// Bookmarks and folders, in display order within each folder.
    @Published private(set) var items: [Bookmark] = []
    let fileURL: URL

    /// The "Other bookmarks" root (Chrome): bookmarks kept off the bar.
    static let otherBookmarksId = UUID(uuidString: "0B0B0B0B-0000-4000-8000-000000000001")!
    static let folderURL = URL(string: "axolotl://bookmarks")!

    /// Every bookmark (not folders), in any folder.
    var bookmarks: [Bookmark] { items.filter { !$0.isFolder } }
    var folders: [Bookmark] { items.filter(\.isFolder) }

    nonisolated deinit {}

    init(fileURL: URL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        // One bad item skips only itself; a damaged file is copied aside before anything overwrites it.
        let all = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        let decoded = (try? JSONDecoder().decode([Lossy].self, from: data))?.compactMap(\.value)
        if all == nil || decoded?.count != all?.count {
            let backup = fileURL.appendingPathExtension("bak")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        if let saved = decoded {
            // An item whose folder is gone goes back to the bar.
            let folderIds = Set(saved.filter(\.isFolder).map(\.id)).union([Self.otherBookmarksId])
            items = saved.map { item in
                var item = item
                if let parent = item.parentId, !folderIds.contains(parent) { item.parentId = nil }
                return item
            }
        }
    }

    private struct Lossy: Decodable {
        let value: Bookmark?
        init(from decoder: Decoder) throws { value = try? Bookmark(from: decoder) }
    }

    private static var stores: [UUID: BookmarkStore] = [:]

    static func forProfile(_ id: UUID) -> BookmarkStore {
        if let store = stores[id] { return store }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Axolotl/Profiles/\(id.uuidString)", isDirectory: true)
        let store = BookmarkStore(fileURL: dir.appendingPathComponent("bookmarks.json"))
        stores[id] = store
        return store
    }

    #if DEBUG
    /// Screenshots: a throwaway store (temp file) with these bookmarks, so the profile's real bookmarks are untouched.
    static func useSnapshotStore(for id: UUID, urls: [URL]) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-snapshot-bookmarks-\(UUID().uuidString).json")
        let store = BookmarkStore(fileURL: file)
        for url in urls { _ = store.add(url: url, title: nil) }
        stores[id] = store
    }
    #endif

    func contains(_ url: URL) -> Bool { bookmarks.contains { Self.same($0.url, url) } }

    /// Adds a bookmark (to the bar unless `parent` says otherwise) unless the URL is already there; returns its id.
    @discardableResult
    func add(url: URL, title: String?, in parent: UUID? = nil) -> UUID {
        if let existing = bookmarks.first(where: { Self.same($0.url, url) }) { return existing.id }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(title: (name?.isEmpty ?? true) ? Self.defaultTitle(for: url) : name!, url: url,
                                parentId: parent)
        items.append(bookmark)
        save()
        return bookmark.id
    }

    /// Adds a bookmark tree from another browser with one save. Folders merge by
    /// name; a link already bookmarked anywhere is skipped, and folders that would
    /// end up empty aren't created. Returns how many links were added.
    @discardableResult
    func addImported(_ tree: [ImportedBookmark], in parent: UUID? = nil) -> Int {
        var known = Set(bookmarks.compactMap { Workspace.bookmarkKey($0.url) })
        func place(_ nodes: [ImportedBookmark], _ parent: UUID?) -> Int {
            var added = 0
            for node in nodes {
                switch node {
                case .link(let title, let url):
                    guard let key = Workspace.bookmarkKey(url), known.insert(key).inserted else { continue }
                    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    items.append(Bookmark(title: name.isEmpty ? Self.defaultTitle(for: url) : name, url: url, parentId: parent))
                    added += 1
                case .folder(let name, let children):
                    if let existing = items.first(where: { $0.isFolder && $0.parentId == parent && $0.title == name }) {
                        added += place(children, existing.id)
                    } else {
                        let folder = Bookmark(title: name, url: Self.folderURL, parentId: parent, isFolder: true)
                        items.append(folder)
                        let inside = place(children, folder.id)
                        if inside == 0 { items.removeAll { $0.id == folder.id } }
                        added += inside
                    }
                }
            }
            return added
        }
        let added = place(tree, parent)
        if added > 0 { save() }
        return added
    }

    @discardableResult
    func addFolder(_ title: String, in parent: UUID? = nil) -> UUID {
        let folder = Bookmark(title: title, url: Self.folderURL, parentId: parent, isFolder: true)
        items.append(folder)
        save()
        return folder.id
    }

    func bookmark(for url: URL) -> Bookmark? { bookmarks.first { Self.same($0.url, url) } }
    func item(_ id: UUID) -> Bookmark? { items.first { $0.id == id } }

    /// A folder's contents in order (nil = the bookmarks bar).
    func children(of parent: UUID?) -> [Bookmark] { items.filter { $0.parentId == parent } }

    /// Removes a bookmark, or a folder with everything in it.
    func remove(_ id: UUID) {
        var gone: Set<UUID> = [id]
        while true {
            let next = gone.union(items.filter { $0.parentId.map(gone.contains) ?? false }.map(\.id))
            if next.count == gone.count { break }
            gone = next
        }
        items.removeAll { gone.contains($0.id) }
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title
        save()
    }

    /// Edit…: a new title (blank keeps the old one) and, for a bookmark, a new URL.
    func update(_ id: UUID, title: String, url: URL?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { items[i].title = name }
        if let url, !items[i].isFolder { items[i].url = url }
        save()
    }

    /// Whether `id` is `folder` or inside it.
    func isInside(_ id: UUID, folder: UUID) -> Bool {
        var current: UUID? = id
        while let c = current {
            if c == folder { return true }
            current = item(c)?.parentId
        }
        return false
    }

    /// Moves an item into `parent`, before `sibling` (nil: at the end). A folder can't go inside itself.
    func move(_ id: UUID, to parent: UUID?, before sibling: UUID? = nil) {
        guard id != sibling, let from = items.firstIndex(where: { $0.id == id }) else { return }
        if let parent, isInside(parent, folder: id) { return }
        var item = items.remove(at: from)
        item.parentId = parent
        if let sibling, let to = items.firstIndex(where: { $0.id == sibling }) {
            items.insert(item, at: to)
        } else if let last = items.lastIndex(where: { $0.parentId == parent }) {
            items.insert(item, at: last + 1)
        } else {
            items.append(item)
        }
        save()
    }

    /// Bookmarks (any folder) whose title or URL contains every word of `query`.
    func search(_ query: String) -> [Bookmark] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return [] }
        return bookmarks.filter { b in
            let text = (b.title + " " + b.url.absoluteString).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// The site's name from its domain: "news.ycombinator.com" → "Ycombinator", "en.wikipedia.org" → "Wikipedia".
    static func defaultTitle(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let parts = SiteShortcut.normalizedHost(host).split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? Substring(host))
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Same page, ignoring a trailing slash.
    static func same(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            b.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) { try? data.write(to: fileURL, options: .atomic) }
    }
}

import Combine
import Foundation

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: URL
}

/// A profile's bookmarks, shown in the bookmarks bar (Settings → Appearance).
/// Stored with the profile's other data (Application Support/Luna/Profiles/<id>/bookmarks.json).
final class BookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [Bookmark] = []
    let fileURL: URL

    nonisolated deinit {}

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = saved
        }
    }

    private static var stores: [UUID: BookmarkStore] = [:]

    static func forProfile(_ id: UUID) -> BookmarkStore {
        if let store = stores[id] { return store }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Luna/Profiles/\(id.uuidString)", isDirectory: true)
        let store = BookmarkStore(fileURL: dir.appendingPathComponent("bookmarks.json"))
        stores[id] = store
        return store
    }

    #if DEBUG
    /// Screenshots: a throwaway store (temp file) with these bookmarks, so the profile's real bookmarks are untouched.
    static func useSnapshotStore(for id: UUID, urls: [URL]) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("luna-snapshot-bookmarks-\(UUID().uuidString).json")
        let store = BookmarkStore(fileURL: file)
        for url in urls { _ = store.add(url: url, title: nil) }
        stores[id] = store
    }
    #endif

    func contains(_ url: URL) -> Bool { bookmarks.contains { Self.same($0.url, url) } }

    /// Adds a bookmark unless the URL is already there; returns its id.
    @discardableResult
    func add(url: URL, title: String?) -> UUID {
        if let existing = bookmarks.first(where: { Self.same($0.url, url) }) { return existing.id }
        let name = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookmark = Bookmark(title: (name?.isEmpty ?? true) ? Self.defaultTitle(for: url) : name!, url: url)
        bookmarks.append(bookmark)
        save()
        return bookmark.id
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = bookmarks.firstIndex(where: { $0.id == id }) else { return }
        bookmarks[i].title = title
        save()
    }

    /// The site's name from its domain: "news.ycombinator.com" → "Ycombinator", "en.wikipedia.org" → "Wikipedia".
    static func defaultTitle(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        let parts = SiteShortcut.normalizedHost(host).split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? Substring(host))
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            b.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(bookmarks) { try? data.write(to: fileURL, options: .atomic) }
    }
}

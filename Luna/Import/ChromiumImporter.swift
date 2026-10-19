import Foundation

/// Chrome, Brave, Edge, Vivaldi and Arc share Chromium's profile layout:
/// `<profile>/Bookmarks` (JSON) and `<profile>/History` (SQLite).
nonisolated enum ChromiumImporter {
    /// Chromium timestamps are microseconds since 1601-01-01 UTC.
    static let epochOffset: Int64 = 11_644_473_600 * 1_000_000

    static func date(fromChromium value: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value - epochOffset) / 1_000_000)
    }

    static func chromiumTime(from date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000_000) + epochOffset
    }

    // MARK: Bookmarks

    static func bookmarks(profileFolder: URL) throws -> [ImportedBookmark] {
        let file = profileFolder.appendingPathComponent("Bookmarks")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file) else { throw ImportError.unreadable("Bookmarks") }
        return try parseBookmarks(data)
    }

    static func parseBookmarks(_ data: Data) throws -> [ImportedBookmark] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { throw ImportError.unreadable("Bookmarks") }
        let named: [(key: String, title: String)] = [
            ("bookmark_bar", "Bookmarks Bar"), ("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks"),
        ]
        var result: [ImportedBookmark] = []
        for (key, title) in named {
            guard let root = roots[key] as? [String: Any] else { continue }
            let children = convert(root["children"] as? [[String: Any]] ?? [])
            if children.isEmpty { continue }
            // The bar is what people use; keep its items at the top level.
            if key == "bookmark_bar" { result.append(contentsOf: children) } else { result.append(.folder(name: title, children: children)) }
        }
        return result
    }

    private static func convert(_ nodes: [[String: Any]]) -> [ImportedBookmark] {
        nodes.compactMap { node in
            let name = node["name"] as? String ?? ""
            switch node["type"] as? String {
            case "url":
                guard let url = importableURL(node["url"] as? String ?? "") else { return nil }
                return .link(title: name, url: url)
            case "folder":
                let children = convert(node["children"] as? [[String: Any]] ?? [])
                return children.isEmpty ? nil : .folder(name: name.isEmpty ? "Folder" : name, children: children)
            default:
                return nil
            }
        }
    }

    // MARK: History

    /// Most recent visits first, only those after `since`. The limit matches the
    /// history store's cap (HistoryManager keeps the newest 10,000), so older rows would be dropped anyway;
    /// web URLs are filtered in SQL so the limit counts only importable visits.
    static func history(profileFolder: URL, since: Date? = nil, limit: Int = 10_000) throws -> [ImportedVisit] {
        let file = profileFolder.appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let db = try SQLiteSnapshot(copying: file)
        let after = since.map(chromiumTime(from:)) ?? 0
        let rows = try db.rows("""
            SELECT urls.url, urls.title, visits.visit_time FROM visits
            JOIN urls ON urls.id = visits.url
            WHERE visits.visit_time > ? AND (urls.url LIKE 'http://%' OR urls.url LIKE 'https://%')
            ORDER BY visits.visit_time DESC LIMIT ?
            """, bind: [after, Int64(limit)])
        return rows.compactMap { r in
            guard r.count == 3, let urlString = r[0].text, importableURL(urlString) != nil, let t = r[2].int else { return nil }
            return ImportedVisit(url: urlString, title: r[1].text ?? "", date: date(fromChromium: t))
        }
    }
}

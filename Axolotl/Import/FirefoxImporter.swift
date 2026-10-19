import Foundation

/// Firefox keeps bookmarks and history together in `<profile>/places.sqlite`.
nonisolated enum FirefoxImporter {
    /// Built-in root folders (by guid) and how Axolotl names them; "toolbar" items go top level.
    static let roots: [(guid: String, title: String?)] = [
        ("toolbar_____", nil), ("menu________", "Bookmarks Menu"),
        ("unfiled_____", "Other Bookmarks"), ("mobile______", "Mobile Bookmarks"),
    ]

    static func bookmarks(profileFolder: URL) throws -> [ImportedBookmark] {
        let db = try SQLiteSnapshot(copying: profileFolder.appendingPathComponent("places.sqlite"))
        // type 1 = bookmark, 2 = folder.
        let rows = try db.rows("""
            SELECT b.id, b.type, b.parent, b.title, b.guid, p.url FROM moz_bookmarks b
            LEFT JOIN moz_places p ON p.id = b.fk
            ORDER BY b.parent, b.position
            """)
        struct Row { var id: Int64; var type: Int64; var title: String; var url: String? }
        var children: [Int64: [Row]] = [:]
        var idByGuid: [String: Int64] = [:]
        for r in rows {
            guard r.count == 6, let id = r[0].int, let type = r[1].int, let parent = r[2].int else { continue }
            if let guid = r[4].text { idByGuid[guid] = id }
            children[parent, default: []].append(Row(id: id, type: type, title: r[3].text ?? "", url: r[5].text))
        }
        func build(_ parent: Int64) -> [ImportedBookmark] {
            (children[parent] ?? []).compactMap { row in
                switch row.type {
                case 1:
                    guard let url = row.url.flatMap(importableURL) else { return nil }
                    return .link(title: row.title, url: url)
                case 2:
                    let kids = build(row.id)
                    return kids.isEmpty ? nil : .folder(name: row.title.isEmpty ? "Folder" : row.title, children: kids)
                default:
                    return nil
                }
            }
        }
        var result: [ImportedBookmark] = []
        for (guid, title) in roots {
            guard let id = idByGuid[guid] else { continue }
            let items = build(id)
            if items.isEmpty { continue }
            if let title { result.append(.folder(name: title, children: items)) } else { result.append(contentsOf: items) }
        }
        return result
    }

    /// Most recent visits first, only those after `since`, handed to `onBatch` in pages of `batchSize`.
    /// The limit matches the history store's cap (HistoryStore keeps the newest 100,000), so older rows
    /// would be dropped anyway; web URLs are filtered in SQL so the limit counts only importable visits.
    /// Firefox stores microseconds since 1970.
    static func history(profileFolder: URL, since: Date? = nil, limit: Int = HistoryStore.maxVisits, batchSize: Int = 5_000,
                        onBatch: ([ImportedVisit]) throws -> Void) throws {
        let db = try SQLiteSnapshot(copying: profileFolder.appendingPathComponent("places.sqlite"))
        try db.pageVisits("""
            SELECT p.url, p.title, v.visit_date, v.id FROM moz_historyvisits v
            JOIN moz_places p ON p.id = v.place_id
            WHERE v.visit_date > ?1 AND (p.url LIKE 'http://%' OR p.url LIKE 'https://%')
              AND (v.visit_date < ?2 OR (v.visit_date = ?2 AND v.id < ?3))
            ORDER BY v.visit_date DESC, v.id DESC LIMIT ?4
            """, after: since.map { Int64($0.timeIntervalSince1970 * 1_000_000) } ?? 0, limit: limit, batchSize: batchSize,
            date: { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) }, onBatch: onBatch)
    }

}

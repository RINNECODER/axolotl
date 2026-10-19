import Foundation
import SQLite3

/// SQLite-backed page-visit store (`history.sqlite`, WAL). Inserts are incremental,
/// queries use indexes and LIMIT, so ~100k visits stay cheap to save and query.
/// Not thread-safe: confine every call to one serial queue (HistoryManager's `ioQueue`).
nonisolated final class HistoryStore: @unchecked Sendable {
    static let maxVisits = 100_000
    static let maxAge: TimeInterval = 365 * 24 * 3600

    struct Row: Equatable, Sendable {
        var id: UUID
        var date: Date
        var url: String
        var title: String
    }

    /// nil = in memory only (private windows).
    private let fileURL: URL?
    private var db: OpaquePointer?

    /// Cheap: the file is opened on first use, on the caller's queue.
    init(fileURL: URL?) { self.fileURL = fileURL }

    deinit { sqlite3_close(db) }

    private func open() -> OpaquePointer? {
        if let db { return db }
        if let fileURL { try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
        let path = fileURL?.path ?? ":memory:"
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            print("History: cannot open \((path as NSString).lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
            sqlite3_close(db)
            db = nil
            return nil
        }
        // `sec` + the unique (url, sec) index dedupe the same URL within one second (imports, reload bursts).
        exec("""
            PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, uid TEXT NOT NULL, ts REAL NOT NULL,
                sec INTEGER NOT NULL, url TEXT NOT NULL, title TEXT NOT NULL DEFAULT '');
            CREATE INDEX IF NOT EXISTS visits_ts ON visits(ts);
            CREATE UNIQUE INDEX IF NOT EXISTS visits_url_sec ON visits(url, sec);
            """)
        return db
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            print("History SQL failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private enum Arg { case text(String), real(Double), int(Int64) }

    /// Prepares, binds and steps `sql`, calling `row` for each result row.
    @discardableResult
    private func run(_ sql: String, _ args: [Arg] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        guard let db = open() else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            print("History SQL failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, args)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row?(stmt); continue }
            return rc == SQLITE_DONE
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer, _ args: [Arg]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            }
        }
    }

    private static func text(_ stmt: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(stmt, col).map { String(cString: $0) } ?? ""
    }

    private static func visitRow(_ stmt: OpaquePointer) -> Row {
        Row(id: UUID(uuidString: text(stmt, 0)) ?? UUID(), date: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
            url: text(stmt, 2), title: text(stmt, 3))
    }

    // MARK: Writes

    /// Inserts in one transaction; returns the rows actually added (duplicates are skipped), nil if the write failed.
    @discardableResult
    func insert(_ rows: [Row]) -> [Row]? {
        guard let db = open() else { return nil }
        if rows.isEmpty { return [] }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO visits(uid, ts, sec, url, title) VALUES (?,?,?,?,?)",
                                 -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        exec("BEGIN")
        var added: [Row] = []
        for r in rows {
            let t = r.date.timeIntervalSince1970
            bind(stmt, [.text(r.id.uuidString), .real(t), .int(Int64(t.rounded(.down))), .text(r.url), .text(r.title)])
            if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) == 1 { added.append(r) }
            sqlite3_reset(stmt)
        }
        guard exec("COMMIT") else { exec("ROLLBACK"); return nil }
        return added
    }

    func deleteAll() { run("DELETE FROM visits") }
    func delete(since cutoff: Date) { run("DELETE FROM visits WHERE ts >= ?", [.real(cutoff.timeIntervalSince1970)]) }
    // shortcut: uid has no index, so this scans (~ms at 100k); index it if single deletes become frequent.
    func delete(id: UUID) { run("DELETE FROM visits WHERE uid = ?", [.text(id.uuidString)]) }

    /// Chrome-style expiry: drops visits older than `maxAge`, then all but the newest `maxCount`.
    func expire(now: Date = Date(), maxAge: TimeInterval = HistoryStore.maxAge, maxCount: Int = HistoryStore.maxVisits) {
        run("DELETE FROM visits WHERE ts < ?", [.real(now.timeIntervalSince1970 - maxAge)])
        run("DELETE FROM visits WHERE id IN (SELECT id FROM visits ORDER BY ts DESC LIMIT -1 OFFSET ?)", [.int(Int64(maxCount))])
    }

    // MARK: Reads

    func count() -> Int {
        var n = 0
        run("SELECT COUNT(*) FROM visits") { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }

    /// Newest first, strictly older than `before` when given (for paging).
    func recent(limit: Int, before: Date? = nil) -> [Row] {
        var out: [Row] = []
        run("SELECT uid, ts, url, title FROM visits WHERE ts < ? ORDER BY ts DESC LIMIT ?",
            [.real(before?.timeIntervalSince1970 ?? .infinity), .int(Int64(limit))]) { out.append(Self.visitRow($0)) }
        return out
    }

    private static func likePattern(_ query: String) -> String {
        let escaped = query.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    /// Visits whose URL or title contains `query` (case-insensitive for ASCII), newest first.
    func search(_ query: String, limit: Int) -> [Row] {
        var out: [Row] = []
        run("""
            SELECT uid, ts, url, title FROM visits WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
            ORDER BY ts DESC LIMIT ?2
            """, [.text(Self.likePattern(query)), .int(Int64(limit))]) { out.append(Self.visitRow($0)) }
        return out
    }

    struct URLMatch: Sendable {
        var url: String
        var title: String // from the most recent visit
        var lastVisit: Date
        var visitCount: Int
    }

    /// One row per matching URL, most visited first.
    func urlMatches(_ query: String, limit: Int) -> [URLMatch] {
        var out: [URLMatch] = []
        // SQLite returns the bare `title` column from the row holding MAX(ts).
        run("""
            SELECT url, title, MAX(ts), COUNT(*) AS n FROM visits
            WHERE url LIKE ?1 ESCAPE '\\' OR title LIKE ?1 ESCAPE '\\'
            GROUP BY url ORDER BY n DESC, MAX(ts) DESC LIMIT ?2
            """, [.text(Self.likePattern(query)), .int(Int64(limit))]) { s in
            out.append(URLMatch(url: Self.text(s, 0), title: Self.text(s, 1),
                                lastVisit: Date(timeIntervalSince1970: sqlite3_column_double(s, 2)),
                                visitCount: Int(sqlite3_column_int64(s, 3))))
        }
        return out
    }

    // MARK: Migration

    /// The fields of the old `HistoryEvent` JSON that page visits need (decoding ignores the rest).
    private struct LegacyEvent: Decodable {
        var id: UUID
        var timestamp: Date
        var type: String
        var url: String?
        var pageTitle: String?
    }

    /// One-time import of the old JSON history. Renames it to `<name>.migrated` (never deletes)
    /// only after the rows are committed; an unreadable file is left in place untouched.
    func migrateJSON(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let events = try? decoder.decode([LegacyEvent].self, from: data) else {
            print("History: could not decode \(url.lastPathComponent); leaving it in place")
            return
        }
        let rows = events.compactMap { e in
            e.type == "pageVisit" ? e.url.map { Row(id: e.id, date: e.timestamp, url: $0, title: e.pageTitle ?? "") } : nil
        }
        guard insert(rows) != nil else { return }
        let done = URL(fileURLWithPath: url.path + ".migrated")
        try? FileManager.default.removeItem(at: done)
        try? FileManager.default.moveItem(at: url, to: done)
    }
}

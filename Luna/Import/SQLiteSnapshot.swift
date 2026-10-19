import Foundation
import SQLite3

/// Read-only access to another browser's SQLite database. Browsers keep these
/// files locked (and recent writes in a `-wal` file) while running, so the
/// database is copied to a private temp folder first and read from the copy.
nonisolated final class SQLiteSnapshot {
    private var db: OpaquePointer?
    private let tempDir: URL

    init(copying source: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: source.path) else { throw ImportError.missingFile(source.lastPathComponent) }
        tempDir = fileManager.temporaryDirectory.appendingPathComponent("luna-import-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let copy = tempDir.appendingPathComponent(source.lastPathComponent)
        do {
            try fileManager.copyItem(at: source, to: copy)
            for suffix in ["-wal", "-shm"] {
                let side = URL(fileURLWithPath: source.path + suffix)
                if fileManager.fileExists(atPath: side.path) {
                    try? fileManager.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
        } catch {
            try? fileManager.removeItem(at: tempDir)
            throw ImportError.unreadable(source.lastPathComponent)
        }
        // Opened read-write on the private copy so SQLite can replay the WAL.
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            try? fileManager.removeItem(at: tempDir)
            throw ImportError.unreadable(source.lastPathComponent)
        }
    }

    deinit {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: tempDir)
    }

    enum Value { case int(Int64), text(String), null }

    /// Runs a query and returns each row's columns.
    func rows(_ sql: String, bind: [Int64] = []) throws -> [[Value]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            throw ImportError.unreadable(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, v) in bind.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), v) }
        var out: [[Value]] = []
        let count = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [Value] = []
            for c in 0..<count {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_NULL: row.append(.null)
                default:
                    if let p = sqlite3_column_text(stmt, c) { row.append(.text(String(cString: p))) } else { row.append(.null) }
                }
            }
            out.append(row)
        }
        return out
    }

    /// Pages a newest-first visits query in batches so huge histories never sit in memory at once.
    /// `sql` must select (url, title, time, rowid), filter `time > ?1`, continue from the keyset cursor
    /// `(time < ?2 OR (time = ?2 AND rowid < ?3))`, order by time DESC, rowid DESC, and `LIMIT ?4`.
    func pageVisits(_ sql: String, after: Int64, limit: Int, batchSize: Int, date: (Int64) -> Date,
                    onBatch: ([ImportedVisit]) throws -> Void) throws {
        var cursor = (time: Int64.max, id: Int64.max)
        var remaining = limit
        while remaining > 0 {
            let page = min(batchSize, remaining)
            let rows = try rows(sql, bind: [after, cursor.time, cursor.id, Int64(page)])
            guard let last = rows.last, last.count == 4, let t = last[2].int, let id = last[3].int else { return }
            cursor = (t, id)
            remaining -= rows.count
            let batch = rows.compactMap { r -> ImportedVisit? in
                guard r.count == 4, let urlString = r[0].text, importableURL(urlString) != nil, let t = r[2].int else { return nil }
                return ImportedVisit(url: urlString, title: r[1].text ?? "", date: date(t))
            }
            if !batch.isEmpty { try onBatch(batch) }
            if rows.count < page { return }
        }
    }
}

nonisolated extension SQLiteSnapshot.Value {
    var int: Int64? { if case .int(let v) = self { return v }; return nil }
    var text: String? {
        switch self {
        case .text(let s): return s
        case .int(let v): return String(v)
        case .null: return nil
        }
    }
}

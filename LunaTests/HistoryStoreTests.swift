import XCTest
@testable import Luna

final class HistoryStoreTests: XCTestCase {
    private var dir: URL!
    private var store: HistoryStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = HistoryStore(fileURL: dir.appendingPathComponent("history.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func row(_ url: String, _ t: TimeInterval, _ title: String = "") -> HistoryStore.Row {
        HistoryStore.Row(id: UUID(), date: Date(timeIntervalSince1970: t), url: url, title: title)
    }

    func testMigratesLegacyJSONOnceAndKeepsTheFile() throws {
        let json = dir.appendingPathComponent("browsing_history.json")
        try Data("""
            [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":"2026-10-01T10:00:00Z","type":"pageVisit","url":"https://a.com/","pageTitle":"A"},
             {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":"2026-10-02T10:00:00Z","type":"chatConversation"},
             {"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","timestamp":"2026-10-03T10:00:00Z","type":"pageVisit","url":"https://b.com/x"}]
            """.utf8).write(to: json)
        store.migrateJSON(at: json)
        XCTAssertEqual(store.recent(limit: 10).map(\.url), ["https://b.com/x", "https://a.com/"])
        XCTAssertEqual(store.recent(limit: 10).last?.id, UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: json.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path + ".migrated"), "renamed, never deleted")
        store.migrateJSON(at: json)
        XCTAssertEqual(store.count(), 2, "second launch does nothing")
    }

    func testUnreadableJSONIsLeftInPlace() throws {
        let json = dir.appendingPathComponent("browsing_history.json")
        try Data("not json".utf8).write(to: json)
        store.migrateJSON(at: json)
        XCTAssertTrue(FileManager.default.fileExists(atPath: json.path))
        XCTAssertEqual(store.count(), 0)
    }

    func testInsertDedupesAndQueriesPageAndSearch() {
        XCTAssertEqual(store.insert([row("https://a.com/", 100, "Alpha"), row("https://b.com/docs", 300, "Beta Docs"),
                                     row("https://a.com/", 100.5, "dup in same second")])?.count, 2)
        store.insert([row("https://a.com/", 200, "Alpha 2"), row("https://c.com/100%_off", 400)])
        XCTAssertEqual(store.recent(limit: 2).map(\.date.timeIntervalSince1970), [400, 300])
        XCTAssertEqual(store.recent(limit: 10, before: Date(timeIntervalSince1970: 300)).map(\.date.timeIntervalSince1970), [200, 100])
        XCTAssertEqual(store.search("beta", limit: 10).map(\.url), ["https://b.com/docs"], "title match, case-insensitive")
        XCTAssertEqual(store.search("100%_", limit: 10).map(\.url), ["https://c.com/100%_off"], "LIKE wildcards are literal")
        XCTAssertEqual(store.search("0%", limit: 10).count, 1)
        let matches = store.urlMatches("a.com", limit: 5)
        XCTAssertEqual(matches.map(\.url), ["https://a.com/"])
        XCTAssertEqual(matches.first?.visitCount, 2)
        XCTAssertEqual(matches.first?.title, "Alpha 2", "title from the most recent visit")
    }

    func testExpiryDropsOldVisitsAndEnforcesTheCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        store.insert([row("https://old.com/", now.timeIntervalSince1970 - 400 * day)]
                     + (0..<5).map { row("https://n\($0).com/", now.timeIntervalSince1970 - Double($0) * day) })
        store.expire(now: now, maxCount: 3)
        XCTAssertEqual(store.recent(limit: 10).map(\.url), ["https://n0.com/", "https://n1.com/", "https://n2.com/"])
    }

    func testClearByRangeAndSingleVisit() {
        let keep = row("https://keep.com/", 100)
        let single = row("https://single.com/", 150)
        store.insert([keep, single, row("https://recent.com/", 500), row("https://recent2.com/", 600)])
        store.delete(since: Date(timeIntervalSince1970: 500))
        store.delete(id: single.id)
        XCTAssertEqual(store.recent(limit: 10).map(\.url), [keep.url])
        store.deleteAll()
        XCTAssertEqual(store.count(), 0)
    }

    func testHundredThousandVisitsInsertAndSuggestQuickly() {
        let base = Date().timeIntervalSince1970 - 100_000
        let rows = (0..<100_000).map { row("https://site\($0 % 5_000).example.com/page/\($0)", base + Double($0), "Page \($0)") }
        var start = Date()
        for batch in stride(from: 0, to: rows.count, by: 5_000) { store.insert(Array(rows[batch..<batch + 5_000])) }
        let insertTime = Date().timeIntervalSince(start)
        XCTAssertEqual(store.count(), 100_000)
        start = Date()
        let matches = store.urlMatches("site42.example", limit: 200)
        let suggestTime = Date().timeIntervalSince(start)
        start = Date()
        let page = store.recent(limit: 500)
        let pageTime = Date().timeIntervalSince(start)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(page.count, 500)
        print(String(format: "HISTORY_PERF insert100k=%.3fs suggest=%.4fs page500=%.4fs", insertTime, suggestTime, pageTime))
        XCTAssertLessThan(insertTime, 10)
        XCTAssertLessThan(suggestTime, 1)
    }
}

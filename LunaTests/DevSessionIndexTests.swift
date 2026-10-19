import XCTest
#if LUNA_DEV
@testable import LunaDev
#else
@testable import Luna
#endif

/// Persisted session index: warm loads reuse it, mtime/size changes invalidate it, and only
/// titles reach disk. Synthetic fixtures only.
@MainActor
final class DevSessionIndexTests: XCTestCase {

    // MARK: Helpers

    private func scratchDir(_ label: String = "dir") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("luna-sessindex-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func claudeLine(_ id: String, cwd: String, user: String) -> String {
        let object: [String: Any] = ["type": "user", "sessionId": id, "cwd": cwd, "message": ["role": "user", "content": user]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }

    private func write(_ text: String, to file: URL, modified: Date) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
    }

    private struct Fixture {
        let claudeRoot: URL
        let codexRoot: URL
        let indexURL: URL
        let file: URL
    }

    private func fixture() throws -> Fixture {
        let root = try scratchDir()
        return Fixture(claudeRoot: root.appendingPathComponent("claude"), codexRoot: root.appendingPathComponent("codex"),
                       indexURL: root.appendingPathComponent("index/session-index.json"),
                       file: root.appendingPathComponent("claude/-tmp-proj/abc.jsonl"))
    }

    private func sync(_ f: Fixture) -> SessionSync {
        SessionSync(claudeRoot: f.claudeRoot, codexRoot: f.codexRoot, processes: { [] }, indexURL: f.indexURL)
    }

    // MARK: Tests

    func testWarmLoadUsesPersistedIndex() async throws {
        let f = try fixture()
        let when = Date(timeIntervalSinceNow: -3600)
        let text = claudeLine("abc", cwd: "/tmp/proj", user: "hello index")
        try write(text, to: f.file, modified: when)
        let cold = await sync(f).allSessions(limit: 10)
        XCTAssertEqual(cold.map(\.title), ["hello index"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.indexURL.path))

        // Same byte length, same mtime, different content: only the index can still say "hello index".
        let garbage = String(repeating: "x", count: text.utf8.count - 1) + "\n"
        try write(garbage, to: f.file, modified: when)
        let warm = await sync(f).allSessions(limit: 10)
        XCTAssertEqual(warm.map(\.title), ["hello index"])
    }

    func testMtimeChangeInvalidatesIndex() async throws {
        let f = try fixture()
        try write(claudeLine("abc", cwd: "/tmp/proj", user: "first title"), to: f.file, modified: Date(timeIntervalSinceNow: -3600))
        _ = await sync(f).allSessions(limit: 10)

        try write(claudeLine("abc", cwd: "/tmp/proj", user: "second title"), to: f.file, modified: Date(timeIntervalSinceNow: -1800))
        let fresh = await sync(f).allSessions(limit: 10)
        XCTAssertEqual(fresh.map(\.title), ["second title"])
    }

    func testIndexHoldsOnlyTitles() async throws {
        let f = try fixture()
        let long = String(repeating: "secret-body-", count: 20) + "TAILMARKER"
        try write(claudeLine("abc", cwd: "/tmp/proj", user: long), to: f.file, modified: Date(timeIntervalSinceNow: -60))
        let found = await sync(f).allSessions(limit: 10)
        XCTAssertEqual(found.count, 1)
        let data = try Data(contentsOf: f.indexURL)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("TAILMARKER"))
        XCTAssertFalse(text.contains("firstPrompt"))
        XCTAssertLessThanOrEqual(found[0].title.count, SessionSync.titleLimit + 1)
    }

    func testVersionMismatchStartsEmpty() async throws {
        let f = try fixture()
        try FileManager.default.createDirectory(at: f.indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"version\":999,\"summaries\":{},\"heads\":{}}".utf8).write(to: f.indexURL)
        let store = SessionIndexStore(url: f.indexURL)
        XCTAssertTrue(store.load().summaries.isEmpty)
        try Data("not json".utf8).write(to: f.indexURL)
        XCTAssertTrue(store.load().summaries.isEmpty)
    }

    /// Opt in with LUNA_LIVE_INDEX=1. Prints counts and milliseconds only.
    func testLiveColdWarmTimings() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUNA_LIVE_INDEX"] == "1", "set LUNA_LIVE_INDEX=1")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("luna-live-index-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: index) }
        func make() -> SessionSync {
            SessionSync(claudeRoot: home.appendingPathComponent(".claude/projects", isDirectory: true),
                        codexRoot: home.appendingPathComponent(".codex/sessions", isDirectory: true),
                        processes: { [] }, indexURL: index)
        }
        let t0 = Date()
        let cold = await make().allSessions(limit: 30)
        let coldMS = Int(Date().timeIntervalSince(t0) * 1000)
        let t1 = Date()
        let warm = await make().allSessions(limit: 30)
        let warmMS = Int(Date().timeIntervalSince(t1) * 1000)
        print("INDEX cold=\(coldMS)ms warm=\(warmMS)ms n=\(warm.count)")
        XCTAssertEqual(cold.count, warm.count)
    }
}

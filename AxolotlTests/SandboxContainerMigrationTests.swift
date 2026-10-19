import XCTest
@testable import Axolotl

/// The sandbox container → unsandboxed copy, against a temp fake home and a throwaway defaults
/// suite (never the real ~/Library or defaults).
final class SandboxContainerMigrationTests: XCTestCase {
    private let id = "com.axolotl.browser"
    private var root: URL!
    private var library: URL!
    private var container: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-container-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        container = library.appendingPathComponent("Containers/\(id)/Data/Library")
        suite = "axolotl.container.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private var migration: SandboxContainerMigration {
        SandboxContainerMigration(bundleID: id, container: container, library: library, defaults: defaults)
    }

    private func write(_ text: String, _ path: String, in lib: URL) throws {
        let url = lib.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ path: String, in lib: URL) -> String? {
        try? String(contentsOf: lib.appendingPathComponent(path), encoding: .utf8)
    }

    func testCopiesContainerDataAndSettingsWithoutTouchingTheContainer() throws {
        try write("ws", "Application Support/Axolotl/Profiles/P/workspace.json", in: container)
        try write("db", "Application Support/Axolotl/history.sqlite", in: container)
        try write("default", "WebKit/WebsiteData/LocalStorage/x", in: container)
        try write("profile", "WebKit/WebsiteDataStore/UUID-1/IndexedDB/y", in: container)
        try write("hs", "HTTPStorages/\(id)/httpstorages.sqlite", in: container)
        try write("cookies", "HTTPStorages/\(id).binarycookies", in: container)
        try write("cache", "Caches/\(id)/c", in: container)
        try write("existing", "Application Support/Axolotl/history.sqlite", in: library)
        let prefs = container.appendingPathComponent("Preferences/\(id).plist")
        try FileManager.default.createDirectory(at: prefs.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue((["theme": "dark", "kept": "old"] as NSDictionary).write(to: prefs, atomically: true))
        defaults.set("new", forKey: "kept")

        migration.run()

        XCTAssertEqual(read("Application Support/Axolotl/Profiles/P/workspace.json", in: library), "ws")
        XCTAssertEqual(read("Application Support/Axolotl/history.sqlite", in: library), "existing", "never overwrites")
        XCTAssertEqual(read("WebKit/\(id)/WebsiteData/LocalStorage/x", in: library), "default")
        XCTAssertEqual(read("WebKit/\(id)/WebsiteDataStore/UUID-1/IndexedDB/y", in: library), "profile")
        XCTAssertEqual(read("HTTPStorages/\(id)/httpstorages.sqlite", in: library), "hs")
        XCTAssertEqual(read("HTTPStorages/\(id).binarycookies", in: library), "cookies")
        XCTAssertNil(read("Caches/\(id)/c", in: library))
        XCTAssertEqual(defaults.string(forKey: "theme"), "dark")
        XCTAssertEqual(defaults.string(forKey: "kept"), "new")
        XCTAssertTrue(defaults.bool(forKey: LegacyLunaMigration.doneKey), "the container already holds any Luna data")
        XCTAssertEqual(read("Application Support/Axolotl/history.sqlite", in: container), "db", "container untouched")
    }

    func testWithoutAContainerLeavesLunaMigrationToRun() {
        migration.run()
        XCTAssertTrue(defaults.bool(forKey: SandboxContainerMigration.doneKey))
        XCTAssertFalse(defaults.bool(forKey: LegacyLunaMigration.doneKey))
    }

    func testRunsOnlyOnce() throws {
        migration.run()
        try write("late", "Application Support/Axolotl/late.json", in: container)
        migration.run()
        XCTAssertNil(read("Application Support/Axolotl/late.json", in: library))
    }
}

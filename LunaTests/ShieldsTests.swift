import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Luna

@MainActor
final class ShieldsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var file: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ShieldsTests-\(UUID().uuidString)")
        file = FileManager.default.temporaryDirectory.appendingPathComponent("shields-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    func testSiteSettingsPersistPerHostAndFollowDefaults() {
        let store = ShieldsStore(fileURL: file, defaults: defaults)
        store.update(host: "News.Example") { $0.level = .aggressive; $0.blockScripts = true }
        store.update(host: "shop.example") { $0.up = false }

        let reloaded = ShieldsStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(reloaded.policy(host: "news.example").level, .aggressive)
        XCTAssertTrue(reloaded.policy(host: "news.example").blocksScripts)
        XCTAssertFalse(reloaded.policy(host: "shop.example").up)
        XCTAssertEqual(reloaded.policy(host: "other.example"), ShieldsPolicy())

        // Setting a value back to the default drops the exception, so the site follows the default again.
        reloaded.update(host: "news.example") { $0.level = .standard; $0.blockScripts = false }
        XCTAssertNil(reloaded.sites["news.example"])
        defaults.set(ShieldsLevel.off.rawValue, forKey: ShieldsPrefs.level)
        XCTAssertEqual(reloaded.policy(host: "news.example").level, .off)
        reloaded.remove(host: "shop.example")
        XCTAssertTrue(ShieldsStore(fileURL: file, defaults: defaults).sites.isEmpty)
    }

    func testPrivateStoreIsMemoryOnly() {
        let store = ShieldsStore(fileURL: nil, defaults: defaults)
        store.update(host: "a.example") { $0.up = false }
        XCTAssertFalse(store.policy(host: "a.example").up)
        let privateWeb = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        privateWeb.shields.update(host: "b.example") { $0.up = false }
        XCTAssertFalse(privateWeb.shields.policy(host: "b.example").up)
        XCTAssertFalse(privateWeb.shields === ShieldsStore.forProfile(privateWeb.profileId))
    }

    func testShieldsDownTurnsEverythingOff() {
        var p = ShieldsPolicy(up: true, level: .aggressive, httpsUpgrade: true, blockScripts: true)
        XCTAssertEqual(p.effectiveLevel.uBOLMode, 3)
        XCTAssertTrue(p.blocksScripts)
        XCTAssertTrue(p.upgradesHTTPS)
        p.up = false
        XCTAssertEqual(p.effectiveLevel, .off)
        XCTAssertEqual(p.effectiveLevel.uBOLMode, 0)
        XCTAssertFalse(p.blocksScripts)
        XCTAssertFalse(p.upgradesHTTPS)
        XCTAssertEqual(ShieldsLevel.standard.uBOLMode, 2)
        // HTTPS default is the existing HTTPS-first setting.
        defaults.set(false, forKey: PrivacyPrefs.httpsFirst)
        XCTAssertFalse(ShieldsPrefs.defaults(defaults).httpsUpgrade)
        // Luna's own pages are never shielded.
        XCTAssertNil(ShieldsStore.host(of: URL(string: "luna://settings")))
        XCTAssertEqual(ShieldsStore.host(of: URL(string: "https://WWW.Example.com/a")), "www.example.com")
    }

    func testCounterBatchesWrites() {
        let key = "total"
        let counter = ShieldsCounter(key: key, defaults: defaults, flushEvery: 5)
        let tab = UUID()
        counter.observe(tab: tab, count: 2)
        counter.observe(tab: tab, count: 4)
        XCTAssertEqual(counter.total, 4)
        XCTAssertNil(defaults.object(forKey: key), "no write before the batch fills")
        counter.observe(tab: tab, count: 0) // badge went empty…
        counter.observe(tab: tab, count: 4) // …and back: nothing new
        XCTAssertEqual(counter.total, 4)
        counter.navigationCommitted(tab)
        counter.observe(tab: tab, count: 1) // new page: count restarted
        XCTAssertEqual(counter.total, 5)
        XCTAssertEqual(defaults.integer(forKey: key), 5)
        counter.observe(tab: tab, count: 1) // same count again adds nothing
        counter.observe(tab: tab, count: 3)
        XCTAssertEqual(defaults.integer(forKey: key), 5)
        counter.flush()
        XCTAssertEqual(defaults.integer(forKey: key), 7)
        XCTAssertEqual(ShieldsCounter(key: key, defaults: defaults).total, 7)

        let memoryOnly = ShieldsCounter(key: nil, defaults: defaults, flushEvery: 1)
        memoryOnly.observe(tab: tab, count: 9)
        memoryOnly.flush()
        XCTAssertEqual(memoryOnly.total, 9)
        XCTAssertEqual(defaults.integer(forKey: key), 7)
    }

    /// The real channel: uBOL's background takes a per-site filtering mode from the bridge page.
    func testBridgeSetsUBOLFilteringMode() async throws {
        // The installed copy, as the app loads it (WebKit traps loading straight from the app bundle).
        guard let record = ExtensionLibrary.shared.records.first(where: { $0.builtInID == "ubolite" }) else {
            throw XCTSkip("uBlock Origin Lite isn't installed in this container.")
        }
        let dir = ExtensionLibrary.shared.directory(for: record)
        let ext = try await WKWebExtension(resourceBaseURL: dir)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = WKWebExtensionContext(for: ext)
        for p in ext.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: p) }
        for m in ext.allRequestedMatchPatterns { context.setPermissionStatus(.grantedExplicitly, for: m) }
        try controller.load(context)
        defer { try? controller.unload(context) }
        let bridge = UBOLBridge(context: context)
        _ = await bridge.send(["what": "setFilteringMode", "hostname": "shields.example", "level": 0])
        let mode = await bridge.send(["what": "getFilteringMode", "hostname": "shields.example"]) as? Int
        XCTAssertEqual(mode, 0)
        _ = await bridge.send(["what": "setFilteringMode", "hostname": "shields.example", "level": 3])
        let after = await bridge.send(["what": "getFilteringMode", "hostname": "shields.example"]) as? Int
        XCTAssertEqual(after, 3)
        XCTAssertEqual(bridge.pageLoads, 1, "back-to-back messages share one hidden page")
    }

    /// Panel PNGs (Shields up and down), only when LUNA_SETTINGS_SHOTS names an output folder.
    func testRenderShieldsPanel() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_SETTINGS_SHOTS to a folder name to render the Shields panel.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        print("Shields shots: \(dir.path)")
        let store = ShieldsStore(fileURL: nil, defaults: defaults)
        store.update(host: "down.example.com") { $0.up = false }
        for (host, file, appearance) in [("www.theverge.com", "shields-up-light", NSAppearance.Name.aqua),
                                         ("down.example.com", "shields-down-dark", .darkAqua)] {
            let size = NSSize(width: 300, height: 300)
            let view = ShieldsPanel(host: host, blocked: 23, store: store, onChange: {})
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = hosting
            for _ in 0..<5 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            }
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("\(file).png"))
            window.contentView = nil
        }
    }
}

import AppKit
import SwiftUI
import WebKit
import XCTest
@testable import Luna

@MainActor
final class SitePermissionsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var file: URL!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SitePermissionsTests-\(UUID().uuidString)")
        file = FileManager.default.temporaryDirectory.appendingPathComponent("site-perms-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
        super.tearDown()
    }

    func testDecisionsPersistPerHostAndFollowDefaults() {
        let store = SitePermissionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(store.decision(.camera, host: "meet.example"), .ask)
        XCTAssertEqual(store.decision(.popups, host: "meet.example"), .block)
        store.set(.allow, .camera, host: "Meet.Example")
        store.set(.block, .location, host: "meet.example")

        let reloaded = SitePermissionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(reloaded.decision(.camera, host: "meet.example"), .allow)
        XCTAssertEqual(reloaded.decision(.location, host: "meet.example"), .block)
        XCTAssertEqual(reloaded.decision(.microphone, host: "meet.example"), .ask)
        XCTAssertEqual(reloaded.decision(.camera, host: "other.example"), .ask)

        // Choosing the default drops the exception; a stricter global default then applies.
        reloaded.set(.ask, .camera, host: "meet.example")
        XCTAssertNil(reloaded.sites["https://meet.example"]?[.camera])
        defaults.set("block", forKey: SitePermission.camera.defaultsKey)
        XCTAssertEqual(reloaded.decision(.camera, host: "meet.example"), .block)
        // An "ask" exception now differs from the default, so it is kept.
        reloaded.set(.ask, .camera, host: "meet.example")
        XCTAssertEqual(reloaded.decision(.camera, host: "meet.example"), .ask)

        reloaded.removeAll(host: "meet.example")
        XCTAssertTrue(SitePermissionStore(fileURL: file, defaults: defaults).sites.isEmpty)
    }

    func testGrantsAreKeyedByOriginAndHostFilesMigrate() throws {
        try JSONEncoder().encode(["meet.example": [SitePermission.camera: SitePermissionDecision.allow]]).write(to: file)
        let store = SitePermissionStore(fileURL: file, defaults: defaults)
        XCTAssertEqual(Array(store.sites.keys), ["https://meet.example"])
        XCTAssertEqual(store.decision(.camera, host: "https://meet.example"), .allow)
        // Another scheme or port is another origin.
        XCTAssertEqual(store.decision(.camera, host: "http://meet.example"), .ask)
        XCTAssertEqual(store.decision(.camera, host: "https://meet.example:8443"), .ask)
        XCTAssertEqual(SitePermissionStore.origin(URL(string: "https://Meet.Example:443/a")), "https://meet.example")
        // Plain-http grants aren't remembered; localhost's are.
        store.set(.allow, .camera, host: "http://evil.example")
        XCTAssertEqual(store.decision(.camera, host: "http://evil.example"), .ask)
        store.set(.allow, .camera, host: "http://localhost:3000")
        XCTAssertEqual(store.decision(.camera, host: "http://localhost:3000"), .allow)
        XCTAssertEqual(Set(SitePermissionStore(fileURL: file, defaults: defaults).sites.keys),
                       ["https://meet.example", "http://localhost:3000"])
    }

    func testInMemoryStoreWritesNothing() {
        let store = SitePermissionStore(fileURL: nil, defaults: defaults)
        store.set(.allow, .camera, host: "a.example")
        XCTAssertEqual(store.decision(.camera, host: "a.example"), .allow)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testInvalidDefaultFallsBackToBuiltIn() {
        defaults.set("allow", forKey: SitePermission.camera.defaultsKey) // not offered for camera
        XCTAssertEqual(SitePermissionStore(fileURL: nil, defaults: defaults).decision(.camera, host: "x"), .ask)
    }

    func testNotSecureRule() {
        let notSecure = ["http://example.com", "http://192.168.1.4/"]
        let secure = ["https://example.com", "http://localhost:3000", "http://127.0.0.1:8080", "http://app.localhost",
                      "http://[::1]:8000", "file:///tmp/a.html", "luna://settings"]
        for s in notSecure { XCTAssertTrue(SiteSecurity.showsNotSecure(URL(string: s)), s) }
        for s in secure { XCTAssertFalse(SiteSecurity.showsNotSecure(URL(string: s)), s) }
        XCTAssertFalse(SiteSecurity.showsNotSecure(nil))
    }

    func testLockNeedsLoadedSecurePage() {
        let https = URL(string: "https://example.com")!
        // An https URL alone (no page, a pending error, or plain http) never earns the lock.
        XCTAssertFalse(SiteSecurity.isSecure(https, webView: nil, hasPageError: false))
        XCTAssertFalse(SiteSecurity.isSecure(https, webView: WKWebView(), hasPageError: false))
        XCTAssertFalse(SiteSecurity.isSecure(https, webView: WKWebView(), hasPageError: true))
        XCTAssertFalse(SiteSecurity.isSecure(URL(string: "http://example.com")!, webView: WKWebView(), hasPageError: false))
    }

    func testDelegateDecisionMapping() {
        XCTAssertEqual(SitePermission.forMedia(.camera), [.camera])
        XCTAssertEqual(SitePermission.forMedia(.microphone), [.microphone])
        XCTAssertEqual(SitePermission.forMedia(.cameraAndMicrophone), [.camera, .microphone])
        XCTAssertEqual(SitePermissionDecision.combined([.allow, .allow]), .allow)
        XCTAssertEqual(SitePermissionDecision.combined([.allow, .ask]), .ask)
        XCTAssertEqual(SitePermissionDecision.combined([.ask, .block]), .block)
    }

    /// Saved decisions answer WebKit without a prompt; "ask" shows the bubble, and Remember saves the answer.
    func testWrapperRequestFlow() {
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let store = TabStoreHelper.tab(in: web)
        var results: [WKPermissionDecision] = []
        web.sitePermissions.set(.allow, .camera, host: "a.example")
        web.requestSitePermissions([.camera], host: "a.example", webView: store.webView) { results.append($0) }
        XCTAssertEqual(results, [.grant])
        XCTAssertTrue(web.pendingPermissions.isEmpty)

        web.requestSitePermissions([.camera, .microphone], host: "a.example", webView: store.webView) { results.append($0) }
        let request = try? XCTUnwrap(web.pendingPermissions[store.id])
        XCTAssertEqual(request?.permissions, [.microphone])
        request?.respond(allow: false, remember: true)
        request?.respond(allow: true, remember: true) // second answer is ignored
        XCTAssertEqual(results, [.grant, .deny])
        XCTAssertTrue(web.pendingPermissions.isEmpty)
        XCTAssertEqual(web.sitePermissions.decision(.microphone, host: "a.example"), .block)
    }

    // MARK: - Offscreen renders (LUNA_SETTINGS_SHOTS)

    func testRenderSitePermissionUI() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_SETTINGS_SHOTS to a folder name to render PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        print("Site permission shots: \(dir)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = SitePermissionStore(fileURL: nil, defaults: defaults)
        store.set(.allow, .camera, host: "meet.google.com")
        store.set(.block, .location, host: "meet.google.com")
        SitePermissionStore.useSnapshotStore(for: ProfileManager.shared.lastActiveProfileId, sites: [
            "meet.google.com": [.camera: .allow, .microphone: .allow],
            "maps.example.com": [.location: .block],
            "news.example.org": [.popups: .allow],
        ])
        let request = SitePermissionRequest(host: "meet.google.com", permissions: [.camera, .microphone]) { _, _ in }
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(SitePermissionBubble(request: request).padding(20).background(LunaSurface.window),
                       appearance: appearance, size: NSSize(width: 360, height: 230), to: "\(dir)/bubble-\(mode).png")
            try render(SiteInfoPopover(url: URL(string: "https://meet.google.com/abc")!, store: store, webView: nil)
                        .background(LunaSurface.raised),
                       appearance: appearance, size: NSSize(width: 340, height: 440), to: "\(dir)/siteinfo-\(mode).png")
            try render(SiteInfoPopover(url: URL(string: "http://example.com")!, store: store, webView: nil)
                        .background(LunaSurface.raised),
                       appearance: appearance, size: NSSize(width: 340, height: 440), to: "\(dir)/siteinfo-http-\(mode).png")
            try render(SettingsView(initialPane: .siteSettings), appearance: appearance, size: NSSize(width: 1100, height: 900),
                       to: "\(dir)/site-settings-\(mode).png")
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize, to path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        window.contentView = nil
    }
}

/// A registered tab web view in a wrapper, without a TabManager.
@MainActor
private enum TabStoreHelper {
    static func tab(in web: WebViewWrapper) -> (id: UUID, webView: WKWebView) {
        let id = UUID()
        return (id, web.ensureWebView(for: id))
    }
}

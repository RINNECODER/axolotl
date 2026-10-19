import AppKit
import JavaScriptCore
import SwiftUI
import WebKit
import XCTest
@testable import Axolotl

@MainActor
final class PageToolsTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pagetools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: Find in page

    func testFindMatcherIsCaseInsensitiveAndNonOverlapping() throws {
        let js = try XCTUnwrap(JSContext())
        js.evaluateScript(FindInPage.matcherJS)
        let offsets = { (text: String, q: String) in
            js.objectForKeyedSubscript("axolotlFindOffsets").call(withArguments: [text, q]).toArray() as? [Int]
        }
        XCTAssertEqual(offsets("Hello hello HELLO", "hello"), [0, 6, 12])
        XCTAssertEqual(offsets("aaaa", "aa"), [0, 2])
        XCTAssertEqual(offsets("abc", ""), [])
        XCTAssertEqual(offsets("foo\nbar", "foobar"), [])
    }

    /// The full script in a real (offscreen) web view: counts visible matches across inline
    /// elements, skips hidden text and scripts, cycles, and clears its highlights.
    func testFindScriptCountsCyclesAndClearsInWebView() async throws {
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let loaded = expectation(description: "load")
        let delegate = LoadDelegate { loaded.fulfill() }
        wv.navigationDelegate = delegate
        wv.loadHTMLString("""
            <p>Foo <b>bar</b> and foo</p><p style="display:none">foo</p><script>var foo = 1</script>
            <div>FOO</div><div>foo</div><div>bar</div>
            """, baseURL: nil)
        await fulfillment(of: [loaded], timeout: 10)

        func run(_ op: String, _ q: String, _ dir: Int = 0) async throws -> [String: Int] {
            let value = try await wv.callAsyncJavaScript(FindInPage.script, arguments: ["op": op, "q": q, "dir": dir],
                                                         in: nil, contentWorld: FindInPage.world)
            let dict = try XCTUnwrap(value as? [String: Any])
            return dict.mapValues { ($0 as? NSNumber)?.intValue ?? -99 }
        }
        var r = try await run("run", "foo"); XCTAssertEqual(r, ["index": 0, "count": 4])
        r = try await run("step", "foo", 1); XCTAssertEqual(r, ["index": 1, "count": 4])
        r = try await run("step", "foo", -1); XCTAssertEqual(r, ["index": 0, "count": 4])
        r = try await run("step", "foo", -1); XCTAssertEqual(r, ["index": 3, "count": 4], "wraps to the last match")
        r = try await run("run", "foo bar"); XCTAssertEqual(r, ["index": 0, "count": 1], "spans <b> but not two blocks")
        r = try await run("run", "zzz"); XCTAssertEqual(r, ["index": -1, "count": 0])
        _ = try await run("run", "foo")
        let painted = try await wv.callAsyncJavaScript("return CSS.highlights.has('axolotl-find')", arguments: [:],
                                                       in: nil, contentWorld: FindInPage.world) as? Bool
        XCTAssertEqual(painted, true)
        r = try await run("clear", ""); XCTAssertEqual(r, ["index": -1, "count": 0])
        let cleared = try await wv.callAsyncJavaScript("return CSS.highlights.size", arguments: [:],
                                                       in: nil, contentWorld: FindInPage.world) as? NSNumber
        XCTAssertEqual(cleared?.intValue, 0)
        // The page's own world never sees Axolotl's state.
        let leaked = try await wv.evaluateJavaScript("typeof window.__axolotlFind") as? String
        XCTAssertEqual(leaked, "undefined")
    }

    // MARK: Zoom per site

    func testSiteZoomPersistsPerHostAndResetRemoves() throws {
        let file = try tempDir().appendingPathComponent("zoom.json")
        let store = SiteZoomStore(fileURL: file)
        store.set(1.25, for: "Example.com")
        store.set(0.9, for: "other.org")
        XCTAssertEqual(SiteZoomStore(fileURL: file).zoom(for: "example.com"), 1.25)
        XCTAssertEqual(SiteZoomStore(fileURL: file).zoom(for: "unknown.net"), 1)
        store.set(1, for: "example.com")
        let saved = try JSONDecoder().decode([String: Double].self, from: Data(contentsOf: file))
        XCTAssertEqual(saved, ["other.org": 0.9])
    }

    func testPrivateSiteZoomStaysInMemory() {
        let store = SiteZoomStore(fileURL: nil)
        store.set(1.5, for: "example.com")
        XCTAssertEqual(store.zoom(for: "example.com"), 1.5)
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        web.isPrivate = true
        web.siteZoom.set(1.5, for: "example.com")
        XCTAssertFalse(web.siteZoom === SiteZoomStore.forProfile(web.profileId))
        XCTAssertEqual(SiteZoomStore.forProfile(web.profileId).zoom(for: "example.com"), 1)
    }

    // MARK: Downloads

    private func item(_ name: String, profile: UUID, state: DownloadItem.State = .finished, isPrivate: Bool = false,
                      resumeData: Data? = nil) -> DownloadItem {
        var item = DownloadItem(url: URL(string: "https://files.example.com/\(name)")!,
                                fileURL: URL(fileURLWithPath: "/tmp/\(name)"), suggestedFilename: name,
                                date: Date(timeIntervalSince1970: 1_790_000_000), state: state,
                                profileId: profile, isPrivate: isPrivate)
        item.resumeData = resumeData
        return item
    }

    func testDownloadListPersistsPerProfileWithoutPrivateItems() throws {
        let store = DownloadListStore(profilesDirectory: try tempDir())
        let a = UUID(), b = UUID()
        store.save([item("a.zip", profile: a), item("secret.zip", profile: a, isPrivate: true),
                    item("run.iso", profile: a, state: .downloading), item("b.pdf", profile: b)], profiles: [a, b])
        let loaded = store.load()
        XCTAssertEqual(Set(loaded.map(\.displayName)), ["a.zip", "run.iso", "b.pdf"])
        XCTAssertEqual(loaded.first { $0.displayName == "run.iso" }?.state, .failed("Interrupted"))
        XCTAssertEqual(loaded.first { $0.displayName == "b.pdf" }?.profileId, b)
        // Removing a profile's last item rewrites its file empty.
        store.save([], profiles: [b])
        XCTAssertEqual(store.load().map(\.displayName).sorted(), ["a.zip", "run.iso"])
    }

    func testRetryPlanResumesWithDataElseRestarts() {
        let p = UUID(), data = Data([1, 2, 3])
        XCTAssertEqual(item("x", profile: p, state: .paused, resumeData: data).retryPlan, .resume(data))
        XCTAssertEqual(item("x", profile: p, state: .failed("net"), resumeData: data).retryPlan, .resume(data))
        XCTAssertEqual(item("x", profile: p, state: .failed("net")).retryPlan, .restart(URL(string: "https://files.example.com/x")!))
        XCTAssertEqual(item("x", profile: p, state: .cancelled).retryPlan, .restart(URL(string: "https://files.example.com/x")!))
        XCTAssertNil(item("x", profile: p).retryPlan)
        XCTAssertNil(item("x", profile: p, state: .downloading).retryPlan)
    }

    func testResumeRoutesToAWindowOfTheSameProfileAndPrivacy() throws {
        let p = UUID(), data = Data([9])
        let store = DownloadListStore(profilesDirectory: try tempDir())
        store.save([item("paused.zip", profile: p, state: .paused, resumeData: data),
                    item("failed.zip", profile: p, state: .failed("net"))], profiles: [p])
        let manager = DownloadManager(store: store)
        let other = FakeResumer(profileId: UUID()), privateOne = FakeResumer(profileId: p, isPrivate: true)
        let mine = FakeResumer(profileId: p)
        [other, privateOne, mine].forEach(manager.register)
        let paused = try XCTUnwrap(manager.recentDownloads.first { $0.displayName == "paused.zip" })
        let failed = try XCTUnwrap(manager.recentDownloads.first { $0.displayName == "failed.zip" })
        manager.resume(paused.id)
        manager.resume(failed.id)
        XCTAssertEqual(mine.calls, ["resume \(paused.id) 1", "restart \(failed.id) https://files.example.com/failed.zip"])
        XCTAssertTrue(other.calls.isEmpty && privateOne.calls.isEmpty)
        // Clear all keeps paused downloads (they can still resume).
        manager.clearInactive()
        XCTAssertEqual(manager.recentDownloads.map(\.displayName), ["paused.zip"])
    }

    // MARK: Offscreen UI shots (env-gated)

    func testRenderPageTools() throws {
        guard let name = ProcessInfo.processInfo.environment["AXOLOTL_PAGETOOLS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set AXOLOTL_PAGETOOLS_SHOTS to a folder name to render page-tool PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        print("Page tools shots: \(dir.path)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = UUID()
        let store = DownloadListStore(profilesDirectory: try tempDir())
        var running = item("ubuntu-26.04-desktop-arm64.iso", profile: profile, state: .downloading)
        running.bytesReceived = 1_200_000_000; running.bytesExpected = 3_100_000_000; running.fraction = 0.39
        var paused = item("dataset.tar.gz", profile: profile, state: .paused, resumeData: Data([1]))
        paused.bytesReceived = 48_000_000
        var done = item("report-q3.pdf", profile: profile)
        done.bytesReceived = 2_400_000
        store.save([running, paused, item("installer.dmg", profile: profile, state: .failed("Network connection lost")), done,
                    item("photo.jpg", profile: profile, state: .cancelled)], profiles: [profile])
        let manager = DownloadManager(store: store)
        try render(DownloadsPageView(profileId: profile, isPrivate: false, manager: manager), size: NSSize(width: 900, height: 620),
                   to: dir.appendingPathComponent("downloads-page.png"))
        let sourceTab = UUID()
        ViewSourceStore.html[sourceTab] = ("""
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="utf-8">
              <title>Example Domain</title>
            </head>
            <body>
              <div>
                <h1>Example Domain</h1>
                <p>This domain is for use in illustrative examples in documents.</p>
              </div>
            </body>
            </html>
            """, false)
        try render(ViewSourceView(page: URL(string: "https://example.com/")!, tabId: sourceTab), size: NSSize(width: 700, height: 320),
                   to: dir.appendingPathComponent("view-source.png"))
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let tab = UUID()
        web.setActiveTab(tab)
        web.zoomIn(tab)
        let chrome = VStack(alignment: .trailing, spacing: 16) {
            BrowserFindBar(query: .constant("domain"), result: FindInPage.Result(index: 2, count: 17),
                           onFind: { _ in }, onNext: {}, onPrevious: {}, onDismiss: {})
            HStack(spacing: 8) {
                Text("example.com").font(.system(size: 13))
                Spacer()
                ZoomChip(web: web)
            }
            .padding(.horizontal, 10).frame(width: 360, height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
            ZoomControls(web: web).background(RoundedRectangle(cornerRadius: 10).fill(.background))
        }
        .padding(20)
        .background(Color(white: 0.3))
        try render(chrome, size: NSSize(width: 460, height: 220), to: dir.appendingPathComponent("find-zoom.png"))
    }

    private func render<V: View>(_ view: V, size: NSSize, to url: URL) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
    }
}

private final class LoadDelegate: NSObject, WKNavigationDelegate {
    let done: () -> Void
    init(done: @escaping () -> Void) { self.done = done }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done() }
}

private final class FakeResumer: DownloadResuming {
    let profileId: UUID
    let isPrivate: Bool
    var calls: [String] = []
    init(profileId: UUID, isPrivate: Bool = false) {
        self.profileId = profileId
        self.isPrivate = isPrivate
    }
    func resumeDownload(from data: Data, item: UUID) { calls.append("resume \(item) \(data.count)") }
    func restartDownload(from url: URL, item: UUID) { calls.append("restart \(item) \(url.absoluteString)") }
}

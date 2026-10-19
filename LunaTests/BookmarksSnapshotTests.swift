import AppKit
import SwiftUI
import XCTest
@testable import Luna

/// Renders the bookmarks bar, bookmark manager, tab search and tab hover card offscreen (a window that is never
/// shown) to PNGs. Runs only when LUNA_SETTINGS_SHOTS names an output folder.
@MainActor
final class BookmarksSnapshotTests: XCTestCase {
    func testRenderBookmarksAndTabSearch() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_SETTINGS_SHOTS to a folder name to render PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        print("Bookmark shots: \(dir)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = BookmarkStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("shots-bm-\(UUID()).json"))
        let work = store.addFolder("Work")
        for (url, title) in [("https://github.com", "GitHub"), ("https://news.ycombinator.com", "Hacker News"),
                             ("https://developer.apple.com", "Apple Developer"), ("https://en.wikipedia.org", "Wikipedia"),
                             ("https://www.youtube.com", "YouTube"), ("https://maps.google.com", "Google Maps")] {
            store.add(url: URL(string: url)!, title: title)
        }
        store.add(url: URL(string: "https://linear.app")!, title: "Linear", in: work)
        store.add(url: URL(string: "https://swift.org")!, title: "Swift.org", in: store.addFolder("Reading", in: work))
        store.add(url: URL(string: "https://example.com")!, title: "Example", in: BookmarkStore.otherBookmarksId)

        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let bars = VStack(spacing: 8) {
                BookmarksBar(store: store, onOpen: { _, _ in }, chromeStyle: true, onManage: {})
                BookmarksBar(store: store, onOpen: { _, _ in })
                BookmarksBar(store: store, onOpen: { _, _ in }, chromeStyle: true, onManage: {}).frame(width: 520)
            }
            try render(bars, appearance: appearance, size: NSSize(width: 900, height: 110), to: "\(dir)/bar-\(mode).png")
            try render(BookmarkManagerView(store: store, onOpen: { _, _ in }, selection: work), appearance: appearance,
                       size: NSSize(width: 1000, height: 520), to: "\(dir)/manager-\(mode).png")
            try render(BookmarkManagerView(store: store, onOpen: { _, _ in }, query: "git"), appearance: appearance,
                       size: NSSize(width: 1000, height: 300), to: "\(dir)/manager-search-\(mode).png")
            let open = [("GitHub · Pull requests", "https://github.com/pulls"), ("Hacker News", "https://news.ycombinator.com"),
                        ("Swift Forums", "https://forums.swift.org")].map {
                TabSearchItem(id: UUID(), title: $0.0, url: URL(string: $0.1))
            }
            let closed = [TabSearchItem(id: UUID(), title: "Wikipedia", url: URL(string: "https://en.wikipedia.org"), isClosed: true)]
            let search = HStack(alignment: .top, spacing: 20) {
                TabSearchView(openTabs: open, closedTabs: closed, onSelect: { _ in }, onClose: { _ in }, onDismiss: {})
                TabSearchView(openTabs: open, closedTabs: closed, onSelect: { _ in }, onClose: { _ in }, onDismiss: {}, query: "swft")
                TabHoverCard.Card(title: "GitHub · Pull requests · a very long tab title that wraps onto two lines", host: "github.com")
            }
            .padding(20)
            try render(search, appearance: appearance, size: NSSize(width: 1180, height: 360), to: "\(dir)/tabsearch-\(mode).png")
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize, to path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor)))
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

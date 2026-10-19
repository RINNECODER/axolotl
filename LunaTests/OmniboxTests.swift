import AppKit
import SwiftUI
import XCTest
@testable import Luna

final class OmniboxTests: XCTestCase {
    private func page(_ url: String, _ title: String = "", _ kind: AddressSuggestion.Kind = .history) -> AddressSuggestion {
        AddressSuggestion(display: title, url: URL(string: url)!, kind: kind)
    }

    func testShowsOnlyWhileTypingNonEmptyText() {
        XCTAssertTrue(Omnibox.shouldShow(focused: true, edited: true, text: "git"))
        XCTAssertFalse(Omnibox.shouldShow(focused: true, edited: false, text: "https://github.com"), "focus alone")
        XCTAssertFalse(Omnibox.shouldShow(focused: true, edited: true, text: "  "))
        XCTAssertFalse(Omnibox.shouldShow(focused: false, edited: true, text: "git"))
    }

    func testFirstRowIsWhatWasTyped() {
        let url = Omnibox.rows(typed: "github.com", pages: [], phrases: [], engine: .google)
        guard case .typedURL("github.com", let u)? = url.first?.kind else { return XCTFail("\(url)") }
        XCTAssertEqual(u.host, "github.com")
        let search = Omnibox.rows(typed: "swift ui", pages: [], phrases: [], engine: .google)
        XCTAssertEqual(search.first?.kind, .typedSearch("swift ui"))
        XCTAssertTrue(Omnibox.rows(typed: " ", pages: [], phrases: [], engine: .google).isEmpty)
    }

    func testDedupesAndCapsAtSixWithRoomForSearches() {
        let pages = (1...8).map { page("https://site\($0).com/a", "Site \($0)") } + [page("https://site1.com/a", "dup")]
        let rows = Omnibox.rows(typed: "site", pages: pages, phrases: ["site", "site map", "Site Map", "site speed", "site x"], engine: .google)
        XCTAssertEqual(rows.count, Omnibox.maxRows)
        XCTAssertEqual(rows.map(\.kind).filter { if case .page = $0 { return true } else { return false } }.count, 3)
        // Phrase equal to what was typed and case duplicates are dropped.
        XCTAssertEqual(rows.suffix(2).map(\.kind), [.search("site map"), .search("site speed")])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testTypedURLHidesTheSamePageRow() {
        let rows = Omnibox.rows(typed: "github.com", pages: [page("https://github.com", "GitHub")], phrases: [], engine: .google)
        XCTAssertEqual(rows.count, 1)
    }

    func testSearchRowsFillWhenNoPages() {
        let rows = Omnibox.rows(typed: "weather", pages: [], phrases: ["a", "b", "c", "d"], engine: .google)
        XCTAssertEqual(rows.count, 4, "typed + 3 searches")
    }

    func testInlineCompletesHostPrefix() {
        let pages = [page("https://www.youtube.com/watch?v=1", "Video")]
        XCTAssertEqual(Omnibox.inlineCompletion(typed: "you", previous: "yo", pages: pages), "tube.com")
        XCTAssertEqual(Omnibox.inlineCompletion(typed: "www.you", previous: "www.yo", pages: pages), "tube.com")
        XCTAssertEqual(Omnibox.inlineCompletion(typed: "YOU", previous: "", pages: pages), "tube.com")
        XCTAssertEqual(Omnibox.inlineCompletion(typed: "youtube.com/wa", previous: "", pages: pages), "tch")
    }

    func testNoInlineCompletionAfterDeleteSpacesOrMismatch() {
        let pages = [page("https://youtube.com/", "YouTube")]
        XCTAssertNil(Omnibox.inlineCompletion(typed: "you", previous: "yout", pages: pages), "backspace")
        XCTAssertNil(Omnibox.inlineCompletion(typed: "you", previous: "you", pages: pages), "completion removed")
        XCTAssertNil(Omnibox.inlineCompletion(typed: "you tube", previous: "you tub", pages: pages))
        XCTAssertNil(Omnibox.inlineCompletion(typed: "tube", previous: "", pages: pages), "title/path matches don't complete")
        XCTAssertNil(Omnibox.inlineCompletion(typed: "youtube.com", previous: "", pages: pages), "nothing left to add")
    }

    /// Renders the dropdown offscreen (never-shown window) to PNGs for review. Runs only with LUNA_OMNIBOX_SHOTS.
    @MainActor
    func testRenderDropdown() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_OMNIBOX_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_OMNIBOX_SHOTS to a folder name to render omnibox PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        print("Omnibox shots: \(dir.path)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rows = Omnibox.rows(typed: "github.com", pages: [
            page("https://github.com/anthropics/claude-code", "anthropics/claude-code: agentic coding tool"),
            page("https://github.com/notifications", "Notifications", .bookmark),
            page("https://github.com/RINNECODER/luna-private/pulls", "Pull requests · luna-private", .openTab(UUID())),
        ], phrases: ["github copilot", "github desktop"], engine: .google)
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let view = VStack(spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium)).foregroundStyle(.tertiary)
                    Text("github.com").font(.system(size: 13))
                    Spacer()
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(LunaSurface.raised))
                OmniboxDropdown(rows: rows, query: "github", selectedIndex: 1, onSelect: { _ in })
                Spacer()
            }
            .padding(20)
            .background(LunaSurface.toolbar)
            let size = NSSize(width: 640, height: 300)
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
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: dir.appendingPathComponent("omnibox-\(mode).png"))
            window.contentView = nil
        }
    }
}

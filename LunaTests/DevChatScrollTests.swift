import XCTest
#if LUNA_DEV
@testable import LunaDev
#else
@testable import Luna
#endif

/// A resumed session's history arrives in batches after the chat appears: the chat must end on the
/// last message, keep following new output, and stop only when the reader scrolls up.
@MainActor
final class DevChatScrollTests: XCTestCase {
    private let viewport: CGFloat = 400
    private let rowHeight: CGFloat = 60

    private func events() -> [CLIEvent] {
        var mapper = ClaudeStreamMapper()
        let lines = String(repeating: CLIFixtures.claudeToolTurn + "\n" + CLIFixtures.claudeTextTurn + "\n", count: 6)
        return lines.split(separator: "\n").filter { !$0.hasPrefix(">>") }
            .compactMap { CLIText.parse(Data($0.utf8)) }.flatMap { mapper.map($0).events }
    }

    /// Feeds `batch` into the timeline and replays what the view does after layout.
    private func load(_ batch: ArraySlice<CLIEvent>, into state: inout DevThreadState, follow: inout DevChatFollow,
                      geometry: inout DevChatFollow.Geometry) {
        for event in batch { state.apply(event) }
        let new = DevChatFollow.Geometry(offsetY: geometry.offsetY, contentHeight: CGFloat(state.items.count) * rowHeight,
                                         viewportHeight: viewport)
        let scroll = follow.update(from: geometry, to: new)
        geometry = new
        if scroll { // proxy.scrollTo("bottom") moves the offset; that is a geometry change too.
            let scrolled = DevChatFollow.Geometry(offsetY: max(0, new.contentHeight - viewport),
                                                  contentHeight: new.contentHeight, viewportHeight: viewport)
            XCTAssertFalse(follow.update(from: geometry, to: scrolled))
            geometry = scrolled
        }
    }

    func testResumedHistoryLandsOnLastMessageAndStopsFollowingWhenScrolledUp() {
        let all = events()
        var state = DevThreadState(kind: .claudeCode)
        var follow = DevChatFollow()
        var geometry = DevChatFollow.Geometry(offsetY: 0, contentHeight: 0, viewportHeight: viewport)
        for start in stride(from: 0, to: all.count, by: 7) {
            load(all[start..<min(start + 7, all.count)], into: &state, follow: &follow, geometry: &geometry)
        }
        XCTAssertGreaterThan(geometry.contentHeight, viewport * 3, "fixture must be taller than the viewport")
        XCTAssertTrue(follow.following)
        XCTAssertTrue(geometry.atBottom)
        XCTAssertEqual(geometry.offsetY + viewport, geometry.contentHeight, "last message is the scroll target")

        // The reader scrolls up: following stops (the "Jump to latest" button shows) and new output stays put.
        let up = DevChatFollow.Geometry(offsetY: 0, contentHeight: geometry.contentHeight, viewportHeight: viewport)
        XCTAssertFalse(follow.update(from: geometry, to: up))
        XCTAssertFalse(follow.following)
        geometry = up
        load(events()[...], into: &state, follow: &follow, geometry: &geometry)
        XCTAssertEqual(geometry.offsetY, 0)

        // Back at the bottom by hand: following resumes.
        let down = DevChatFollow.Geometry(offsetY: geometry.contentHeight - viewport, contentHeight: geometry.contentHeight,
                                          viewportHeight: viewport)
        _ = follow.update(from: geometry, to: down)
        XCTAssertTrue(follow.following)
    }
}

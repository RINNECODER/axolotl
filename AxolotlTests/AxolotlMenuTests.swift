import XCTest
import AppKit
@testable import Axolotl

@MainActor
final class AxolotlMenuTests: XCTestCase {
    private var ran: [String] = []

    private func menu() -> [AxolotlMenuEntry] {
        [
            .header("Tabs"),
            .button("New tab") { self.ran.append("New tab") },
            .button("Print", enabled: false) { self.ran.append("Print") },
            .divider("a"),
            .submenu("Extensions", [
                .button("uBlock") { self.ran.append("uBlock") },
                .button("Manage") { self.ran.append("Manage") },
            ]),
            .button("Settings") { self.ran.append("Settings") },
        ]
    }

    private func highlightedTitle(_ nav: AxolotlMenuNavigator, level: Int? = nil) -> String? {
        let l = level ?? nav.depth - 1
        guard let id = nav.highlightedID(level: l) else { return nil }
        return nav.levels[l].entries.first { $0.id == id }?.selectableItem?.title
    }

    func testArrowKeysSkipHeadersSeparatorsAndDisabledRowsAndWrap() {
        var nav = AxolotlMenuNavigator(entries: menu())
        nav.move(1)
        XCTAssertEqual(highlightedTitle(nav), "New tab")
        nav.move(1)
        XCTAssertEqual(highlightedTitle(nav), "Extensions")
        nav.move(1)
        XCTAssertEqual(highlightedTitle(nav), "Settings")
        nav.move(1)
        XCTAssertEqual(highlightedTitle(nav), "New tab")
        nav.move(-1)
        XCTAssertEqual(highlightedTitle(nav), "Settings")
    }

    func testRightOpensSubmenuOnFirstRowAndLeftClosesIt() {
        var nav = AxolotlMenuNavigator(entries: menu())
        nav.typeAhead("ext")
        XCTAssertTrue(nav.openSubmenu())
        XCTAssertEqual(nav.depth, 2)
        XCTAssertEqual(highlightedTitle(nav), "uBlock")
        XCTAssertTrue(nav.closeSubmenu())
        XCTAssertEqual(nav.depth, 1)
        XCTAssertEqual(highlightedTitle(nav), "Extensions")
        XCTAssertFalse(nav.closeSubmenu(), "the root menu is not a submenu")
    }

    func testRightOnAPlainRowDoesNothing() {
        var nav = AxolotlMenuNavigator(entries: menu())
        nav.move(1)
        XCTAssertFalse(nav.openSubmenu())
        XCTAssertEqual(nav.depth, 1)
    }

    func testReturnRunsTheRowOrOpensItsSubmenu() {
        var nav = AxolotlMenuNavigator(entries: menu())
        nav.typeAhead("s")
        guard case .perform(let item) = nav.activate() else { return XCTFail("expected an action") }
        item.action?()
        XCTAssertEqual(ran, ["Settings"])

        nav.typeAhead("e")
        guard case .openedSubmenu = nav.activate() else { return XCTFail("expected the submenu to open") }
        nav.move(1)
        guard case .perform(let sub) = nav.activate() else { return XCTFail("expected an action") }
        sub.action?()
        XCTAssertEqual(ran, ["Settings", "Manage"])
    }

    func testReturnWithNothingHighlightedDoesNothing() {
        var nav = AxolotlMenuNavigator(entries: menu())
        guard case .none = nav.activate() else { return XCTFail("nothing should run") }
    }

    func testHoveringAnotherRowClosesTheOpenSubmenuButHoveringItsParentKeepsIt() {
        var nav = AxolotlMenuNavigator(entries: menu())
        let ext = menu()[4].id
        nav.hover(level: 0, id: ext)
        nav.openSubmenu(level: 0, highlightFirst: false)
        XCTAssertEqual(nav.depth, 2)
        nav.hover(level: 0, id: ext)
        XCTAssertEqual(nav.depth, 2)
        nav.hover(level: 0, id: menu()[5].id)
        XCTAssertEqual(nav.depth, 1)
        XCTAssertEqual(highlightedTitle(nav), "Settings")
    }

    func testHoveringADisabledRowClearsTheHighlight() {
        var nav = AxolotlMenuNavigator(entries: menu())
        nav.move(1)
        nav.hover(level: 0, id: menu()[2].id)
        XCTAssertNil(nav.highlightedID(level: 0))
    }

    func testTypeAheadCyclesThroughMatches() {
        var nav = AxolotlMenuNavigator(entries: [
            .button("Save") {}, .button("Share") {}, .button("Open") {},
        ])
        nav.typeAhead("s")
        XCTAssertEqual(highlightedTitle(nav), "Save")
        nav.typeAhead("s")
        XCTAssertEqual(highlightedTitle(nav), "Share")
        nav.typeAhead("s")
        XCTAssertEqual(highlightedTitle(nav), "Save")
        nav.typeAhead("x")
        XCTAssertEqual(highlightedTitle(nav), "Save", "no match keeps the highlight")
    }

    func testReloadKeepsTheOpenSubmenuAndHighlightAndDropsVanishedOnes() {
        var nav = AxolotlMenuNavigator(entries: menu())
        nav.typeAhead("e")
        nav.openSubmenu()
        nav.move(1)
        nav.reload(menu())
        XCTAssertEqual(nav.depth, 2)
        XCTAssertEqual(highlightedTitle(nav), "Manage")

        nav.reload([.button("New tab") {}])
        XCTAssertEqual(nav.depth, 1, "the submenu's row is gone")
        XCTAssertNil(nav.highlightedID(level: 0))
    }

    func testOptionsCheckTheSelection() {
        var picked: String?
        let entries = AxolotlMenuEntry.options([("a", "Alpha"), ("b", "Beta")], selection: "b") { picked = $0 }
        let items = entries.compactMap(\.selectableItem)
        XCTAssertEqual(items.map(\.isChecked), [false, true])
        items[0].action?()
        XCTAssertEqual(picked, "a")
    }

    func testNSMenuConversionKeepsStructureShortcutsStateAndSendsActions() {
        final class Target: NSObject {
            var fired = 0
            @objc func fire(_ sender: Any?) { fired += 1 }
        }
        let target = Target()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let open = NSMenuItem(title: "Open", action: #selector(Target.fire(_:)), keyEquivalent: "O")
        open.keyEquivalentModifierMask = [.command]
        open.target = target
        open.state = .on
        menu.addItem(open)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "Off", action: #selector(Target.fire(_:)), keyEquivalent: "")
        off.isEnabled = false
        menu.addItem(off)
        let hidden = NSMenuItem(title: "Hidden", action: nil, keyEquivalent: "")
        hidden.isHidden = true
        menu.addItem(hidden)
        let parent = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        parent.submenu = NSMenu()
        parent.submenu?.addItem(withTitle: "Child", action: nil, keyEquivalent: "")
        menu.addItem(parent)

        let entries = AxolotlMenuEntry.from(menu)
        XCTAssertEqual(entries.count, 4, "hidden items are dropped")
        guard case .item(let first) = entries[0], case .separator = entries[1],
              case .item(let disabled) = entries[2], case .item(let more) = entries[3] else {
            return XCTFail("unexpected structure")
        }
        XCTAssertEqual(first.shortcut, "⇧⌘O")
        XCTAssertTrue(first.isChecked)
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(more.children?.count, 1)
        first.action?()
        XCTAssertEqual(target.fired, 1)
    }
}

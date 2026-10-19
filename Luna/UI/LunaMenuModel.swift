// LunaMenu — the data model and keyboard navigation for Luna's own menus.
// Pure values (no AppKit windows) so the navigation logic is unit-testable.
import SwiftUI
import AppKit

enum LunaMenuIcon {
    case system(String)
    case image(NSImage)
}

/// One clickable row (or a submenu when `children` is set).
struct LunaMenuItem: Identifiable {
    var id: String
    var title: String
    var icon: LunaMenuIcon?
    /// Display text for the shortcut column, e.g. "⌘T".
    var shortcut: String?
    var isEnabled = true
    var isChecked = false
    var isDestructive = false
    /// Run the action without closing the menu (the menu rebuilds to show the new state).
    var keepsOpen = false
    var children: [LunaMenuEntry]?
    var action: (() -> Void)?

    var isSubmenu: Bool { children != nil }
}

/// Chrome's zoom row: "Zoom   –  100%  +  | ⛶".
struct LunaMenuZoom {
    var level: String
    var zoomOut: () -> Void
    var zoomIn: () -> Void
    var fullScreen: (() -> Void)?
}

enum LunaMenuEntry: Identifiable {
    case item(LunaMenuItem)
    case separator(String)
    case header(String)
    case zoom(LunaMenuZoom)

    var id: String {
        switch self {
        case .item(let item): return item.id
        case .separator(let id): return "sep." + id
        case .header(let title): return "header." + title
        case .zoom: return "zoom"
        }
    }

    /// Rows the keyboard can land on.
    var selectableItem: LunaMenuItem? {
        if case .item(let item) = self, item.isEnabled { return item }
        return nil
    }

    // MARK: Builders

    static func button(_ title: String, icon: String? = nil, shortcut: String? = nil, id: String? = nil,
                       enabled: Bool = true, checked: Bool = false, destructive: Bool = false,
                       keepsOpen: Bool = false, action: @escaping () -> Void) -> LunaMenuEntry {
        .item(LunaMenuItem(id: id ?? title, title: title, icon: icon.map { .system($0) }, shortcut: shortcut,
                           isEnabled: enabled, isChecked: checked, isDestructive: destructive,
                           keepsOpen: keepsOpen, action: action))
    }

    static func button(_ title: String, image: NSImage?, id: String? = nil, enabled: Bool = true,
                       action: @escaping () -> Void) -> LunaMenuEntry {
        .item(LunaMenuItem(id: id ?? title, title: title, icon: image.map { .image($0) }, isEnabled: enabled,
                           action: action))
    }

    static func submenu(_ title: String, icon: String? = nil, id: String? = nil, enabled: Bool = true,
                        _ children: [LunaMenuEntry]) -> LunaMenuEntry {
        .item(LunaMenuItem(id: id ?? title, title: title, icon: icon.map { .system($0) },
                           isEnabled: enabled && !children.isEmpty, children: children))
    }

    /// A page's cached favicon, or a globe.
    @MainActor
    static func favicon(_ url: URL?) -> NSImage? {
        url.flatMap { FaviconCache.shared.cachedImage(for: $0) }
            ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
    }

    /// A separator. Pass a distinct `id` when a menu has several.
    static func divider(_ id: String = UUID().uuidString) -> LunaMenuEntry { .separator(id) }

    /// A checkmarked option list (a picker as menu rows).
    static func options<V: Equatable>(_ options: [(value: V, title: String)], selection: V,
                                      onSelect: @escaping (V) -> Void) -> [LunaMenuEntry] {
        options.enumerated().map { index, option in
            .button(option.title, id: "opt.\(index).\(option.title)", checked: option.value == selection) {
                onSelect(option.value)
            }
        }
    }
}

extension LunaMenuEntry {
    /// Converts an AppKit menu (after letting its delegate fill it) into Luna menu rows.
    /// Item actions are sent through the responder chain exactly as NSMenu would.
    @MainActor
    static func from(_ menu: NSMenu) -> [LunaMenuEntry] {
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        var out: [LunaMenuEntry] = []
        for (index, item) in menu.items.enumerated() where !item.isHidden {
            if item.isSeparatorItem {
                out.append(.divider("ns.\(index)"))
            } else if item.isSectionHeader {
                out.append(.header(item.title))
            } else if let sub = item.submenu {
                out.append(.item(LunaMenuItem(id: "ns.\(index).\(item.title)", title: item.title,
                                              icon: item.image.map { .image($0) },
                                              isEnabled: item.isEnabled, children: from(sub))))
            } else {
                out.append(.item(LunaMenuItem(
                    id: "ns.\(index).\(item.title)", title: item.title, icon: item.image.map { .image($0) },
                    shortcut: shortcutText(item), isEnabled: item.isEnabled, isChecked: item.state == .on,
                    action: {
                        guard let action = item.action else { return }
                        NSApp.sendAction(action, to: item.target, from: item)
                    })))
            }
        }
        return out
    }

    private static func shortcutText(_ item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var flags = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        if key != key.lowercased() { flags.insert(.shift) }
        key = key.uppercased()
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + key
    }
}

// MARK: - Keyboard navigation

/// Which rows are highlighted and which submenus are open. Level 0 is the
/// root menu; each open submenu adds a level.
struct LunaMenuNavigator {
    struct Level {
        var entries: [LunaMenuEntry]
        var highlighted: Int?
        /// The row in the parent level this submenu hangs off.
        var parentID: String?
    }

    private(set) var levels: [Level]

    init(entries: [LunaMenuEntry]) {
        levels = [Level(entries: entries, highlighted: nil, parentID: nil)]
    }

    var depth: Int { levels.count }

    func highlightedID(level: Int) -> String? {
        guard levels.indices.contains(level), let i = levels[level].highlighted else { return nil }
        return levels[level].entries[i].id
    }

    /// ↑ / ↓ on the deepest open menu, skipping separators, headers and disabled rows; wraps.
    mutating func move(_ delta: Int) {
        let l = levels.count - 1
        let entries = levels[l].entries
        let selectable = entries.indices.filter { entries[$0].selectableItem != nil }
        guard !selectable.isEmpty else { return }
        guard let current = levels[l].highlighted, let pos = selectable.firstIndex(of: current) else {
            levels[l].highlighted = delta >= 0 ? selectable.first : selectable.last
            return
        }
        let next = (pos + delta % selectable.count + selectable.count) % selectable.count
        levels[l].highlighted = selectable[next]
    }

    /// Pointer over a row: highlight it there and close menus deeper than its level
    /// (keeping its own submenu open if it is the one already showing).
    mutating func hover(level: Int, id: String) {
        guard levels.indices.contains(level),
              let index = levels[level].entries.firstIndex(where: { $0.id == id }) else { return }
        levels[level].highlighted = levels[level].entries[index].selectableItem == nil ? nil : index
        if levels.count > level + 1, levels[level + 1].parentID != id {
            levels.removeSubrange((level + 1)...)
        }
    }

    /// → or hover-dwell: opens the highlighted row's submenu. `highlightFirst` for keyboard.
    @discardableResult
    mutating func openSubmenu(level: Int? = nil, highlightFirst: Bool = true) -> Bool {
        let l = level ?? levels.count - 1
        guard levels.indices.contains(l), let i = levels[l].highlighted,
              let item = levels[l].entries[i].selectableItem, let children = item.children else { return false }
        if levels.count > l + 1 {
            if levels[l + 1].parentID == item.id {
                if highlightFirst, levels[l + 1].highlighted == nil { levels[l + 1].highlighted = Self.first(children) }
                levels.removeSubrange((l + 2)...)
                return true
            }
            levels.removeSubrange((l + 1)...)
        }
        levels.append(Level(entries: children, highlighted: highlightFirst ? Self.first(children) : nil, parentID: item.id))
        return true
    }

    /// ←: closes the deepest submenu.
    @discardableResult
    mutating func closeSubmenu() -> Bool {
        guard levels.count > 1 else { return false }
        levels.removeLast()
        return true
    }

    enum Activation {
        case perform(LunaMenuItem)
        case openedSubmenu
        case none
    }

    /// ↩ / click: run the highlighted row, or open its submenu.
    mutating func activate() -> Activation {
        let l = levels.count - 1
        guard let i = levels[l].highlighted, let item = levels[l].entries[i].selectableItem else { return .none }
        if item.isSubmenu { return openSubmenu() ? .openedSubmenu : .none }
        return .perform(item)
    }

    /// Type-ahead: jumps to the next row (after the current one) whose title starts with `prefix`.
    mutating func typeAhead(_ prefix: String) {
        let l = levels.count - 1
        let entries = levels[l].entries
        let start = (levels[l].highlighted ?? -1) + 1
        let order = Array(entries.indices[min(start, entries.count)...]) + Array(entries.indices[..<min(start, entries.count)])
        if let hit = order.first(where: {
            entries[$0].selectableItem?.title.lowercased().hasPrefix(prefix.lowercased()) == true
        }) {
            levels[l].highlighted = hit
        }
    }

    /// Swaps in rebuilt entries (state changed while open), keeping open submenus
    /// and highlights by id where they still exist.
    mutating func reload(_ root: [LunaMenuEntry]) {
        var rebuilt: [Level] = []
        var entries = root
        for (depth, old) in levels.enumerated() {
            let highlightedID = old.highlighted.map { old.entries[$0].id }
            let parentID = depth == 0 ? nil : old.parentID
            if depth > 0 {
                guard let parent = rebuilt.last?.entries.first(where: { $0.id == parentID })?.selectableItem,
                      let children = parent.children else { break }
                entries = children
            }
            rebuilt.append(Level(entries: entries, highlighted: highlightedID.flatMap { id in
                entries.firstIndex { $0.id == id && $0.selectableItem != nil }
            }, parentID: parentID))
        }
        levels = rebuilt
    }

    private static func first(_ entries: [LunaMenuEntry]) -> Int? {
        entries.firstIndex { $0.selectableItem != nil }
    }
}

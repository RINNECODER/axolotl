// Luna — Chrome's tab context menu, shared by the tab strip and the sidebar rows.
import AppKit
import Foundation
import WebKit

enum TabContextMenu {
    enum Command: Equatable {
        case newTabToRight, reload, duplicate, pin, unpin, mute, unmute
        /// Pinned and favorite tabs reset to their saved page instead of closing (Arc).
        case close(reset: Bool)
        case closeOthers, closeToRight

        var title: String {
            switch self {
            case .newTabToRight: return "New Tab to the Right"
            case .reload: return "Reload"
            case .duplicate: return "Duplicate"
            case .pin: return "Pin Tab"
            case .unpin: return "Unpin Tab"
            case .mute: return "Mute Site"
            case .unmute: return "Unmute Site"
            case .close(let reset): return reset ? "Reset Tab" : "Close Tab"
            case .closeOthers: return "Close Other Tabs"
            case .closeToRight: return "Close Tabs to the Right"
            }
        }

        var icon: String? {
            switch self {
            case .newTabToRight: return "plus"
            case .reload: return "arrow.clockwise"
            case .duplicate: return "plus.square.on.square"
            case .pin: return "pin"
            case .unpin: return "pin.slash"
            case .mute: return "speaker.slash"
            case .unmute: return "speaker.wave.2"
            case .close: return "xmark"
            case .closeOthers, .closeToRight: return nil
            }
        }

        var shortcut: String? {
            switch self {
            case .reload: return "⌘R"
            case .close: return "⌘W"
            default: return nil
            }
        }
    }

    /// The menu's sections, in order; the last is the close group.
    /// `order` is the tab strip's order and `persistent` its pinned and favorite tabs.
    nonisolated static func sections(for tabId: UUID, order: [UUID], persistent: Set<UUID>,
                                     hasPage: Bool, hasSite: Bool, isMuted: Bool) -> [[Command]] {
        var page: [Command] = []
        if hasPage { page += [.reload, .duplicate] }
        page.append(persistent.contains(tabId) ? .unpin : .pin)
        if hasSite { page.append(isMuted ? .unmute : .mute) }

        var close: [Command] = [.close(reset: persistent.contains(tabId))]
        if order.contains(where: { $0 != tabId && !persistent.contains($0) }) { close.append(.closeOthers) }
        if let i = order.firstIndex(of: tabId), order[(i + 1)...].contains(where: { !persistent.contains($0) }) {
            close.append(.closeToRight)
        }
        return [[.newTabToRight], page, close]
    }

    /// Tabs that "Close Other Tabs" / "Close Tabs to the Right" close: never pinned or favorite ones.
    nonisolated static func tabsToClose(_ command: Command, from tabId: UUID, order: [UUID], persistent: Set<UUID>) -> [UUID] {
        switch command {
        case .closeOthers:
            return order.filter { $0 != tabId && !persistent.contains($0) }
        case .closeToRight:
            guard let i = order.firstIndex(of: tabId) else { return [] }
            return order[(i + 1)...].filter { !persistent.contains($0) }
        case .close:
            return [tabId]
        default:
            return []
        }
    }

    struct Item {
        let command: Command
        let action: () -> Void
    }

    /// The live menu for a tab. `close` goes through the shell so web views and chat state are cleaned up.
    static func items(for tabId: UUID, store: WorkspaceStore, web: WebViewWrapper?,
                      close: @escaping (UUID) -> Void) -> [[Item]] {
        let ws = store.workspace
        let order = store.orderedTabIds
        let persistent = Set(order.filter { ws.isPersistent($0) })
        let url = ws.tabs[tabId]?.url
        let hasPage = url.map { $0.absoluteString != "about:blank" && !InternalPage.isInternal($0) } ?? false
        let hasSite = web.flatMap { WebViewWrapper.siteKey($0.webViewIfLoaded(for: tabId)?.url) } != nil
        let isMuted = web?.isMuted(tabId) ?? false
        return sections(for: tabId, order: order, persistent: persistent, hasPage: hasPage, hasSite: hasSite, isMuted: isMuted)
            .map { section in
                section.map { command in
                    Item(command: command) {
                        perform(command, on: tabId, store: store, web: web, order: order, persistent: persistent, close: close)
                    }
                }
            }
    }

    private static func perform(_ command: Command, on tabId: UUID, store: WorkspaceStore, web: WebViewWrapper?,
                                order: [UUID], persistent: Set<UUID>, close: (UUID) -> Void) {
        switch command {
        case .newTabToRight:
            let id = store.newTab(url: nil)
            if !persistent.contains(tabId) { store.moveTab(id, nextTo: tabId, after: true) }
        case .reload:
            web?.reload(in: tabId)
        case .duplicate:
            guard let tab = store.tab(tabId), let url = tab.url else { return }
            let id = store.newTab(url: url, activate: false)
            // Keep back/forward: the copy restores the original's history when it loads.
            let state = (web?.webViewIfLoaded(for: tabId)?.interactionState as? Data) ?? tab.interactionState
            if let state { store.setInteractionState(id, state) }
            if !persistent.contains(tabId) { store.moveTab(id, nextTo: tabId, after: true) }
            store.activate(id)
        case .pin:
            store.pin(tabId)
        case .unpin:
            store.unpin(tabId)
        case .mute, .unmute:
            web?.setMuted(command == .mute, tab: tabId)
        case .close, .closeOthers, .closeToRight:
            tabsToClose(command, from: tabId, order: order, persistent: persistent).forEach(close)
        }
    }

    // MARK: Renderers

    /// For Luna menus (the tab strip): sections separated by dividers, after any `leading` entries.
    static func lunaEntries(_ sections: [[Item]], leading: [LunaMenuEntry] = []) -> [LunaMenuEntry] {
        var entries = leading
        for (i, section) in sections.enumerated() {
            if !entries.isEmpty { entries.append(.divider("tab.\(i)")) }
            entries += section.map { .button($0.command.title, icon: $0.command.icon, shortcut: $0.command.shortcut, action: $0.action) }
        }
        return entries
    }

    /// For the sidebar's NSMenu.
    static func addItems(_ section: [Item], to menu: NSMenu) {
        for item in section { menu.addItem(MenuAction(item.command.title, handler: item.action)) }
    }
}

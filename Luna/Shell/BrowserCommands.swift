import AppKit
import SwiftUI

/// What a browser window does for the menu bar's File / View / History / Bookmarks commands.
struct BrowserCommandActions {
    var profileId: () -> UUID
    var newTab: () -> Void
    var reopenClosedTab: () -> Void
    var closeTab: () -> Void
    var printPage: () -> Void
    var reload: () -> Void
    var hardReload: () -> Void
    var zoomIn: () -> Void
    var zoomOut: () -> Void
    var zoomReset: () -> Void
    var back: () -> Void
    var forward: () -> Void
    var showHistory: () -> Void
    var toggleBookmark: () -> Void
    /// Opens or focuses this window's Settings tab, on a pane.
    var openSettings: (SettingsPane?) -> Void
    var showBookmarkManager: () -> Void = {}
    var searchTabs: () -> Void = {}
}

/// Browser windows by NSWindow, so menu commands reach the key window's shell. Extra windows
/// are AppKit-hosted, where SwiftUI focused scene values don't reach the menu bar.
final class BrowserCommandTargets {
    static let shared = BrowserCommandTargets()
    private init() {}

    final class Entry {
        weak var window: NSWindow?
        let actions: BrowserCommandActions
        init(window: NSWindow, actions: BrowserCommandActions) {
            self.window = window
            self.actions = actions
        }
    }

    private var entries: [Entry] = []

    /// Settings was asked for while no browser window was open (outer nil = nothing pending).
    var pendingSettings: SettingsPane?? = nil

    func register(window: NSWindow, actions: BrowserCommandActions) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(Entry(window: window, actions: actions))
        if let pane = pendingSettings {
            pendingSettings = nil
            DispatchQueue.main.async { actions.openSettings(pane) }
        }
    }

    /// The key browser window, else the front-most visible one (Settings opens there).
    var keyOrFrontmost: Entry? {
        entries.removeAll { $0.window == nil }
        if let key = NSApp.keyWindow, let entry = entries.first(where: { $0.window === key }) { return entry }
        let visible = entries.filter { $0.window?.isVisible == true }
        let order = NSApp.orderedWindows
        return visible.min { a, b in
            (order.firstIndex { $0 === a.window } ?? .max) < (order.firstIndex { $0 === b.window } ?? .max)
        }
    }

    /// The key browser window's actions; nil while a sheet or another window is key.
    var key: BrowserCommandActions? {
        entries.removeAll { $0.window == nil }
        guard let window = NSApp.keyWindow else { return nil }
        return entries.first { $0.window === window }?.actions
    }
}

/// Chrome's File, View, History and Bookmarks menu items. These own their shortcuts;
/// the shell's key monitor only handles keys a menu item can't (focus- or repeat-dependent).
struct BrowserCommands: Commands {
    @AppStorage(ChromePrefs.showBookmarksBar) private var showBookmarksBar = false

    private var browser: BrowserCommandActions? { BrowserCommandTargets.shared.key }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser?.newTab() }
                .keyboardShortcut("t")
            Button("New Window") {
                BrowserWindows.open(profileId: browser?.profileId() ?? ProfileManager.shared.lastActiveProfileId)
            }
            .keyboardShortcut("n")
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Search Tabs…") { browser?.searchTabs() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                // Other windows (downloads, sheets) still close with ⌘W.
                if let browser { browser.closeTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { browser?.printPage() }
                .keyboardShortcut("p")
        }
        CommandGroup(before: .toolbar) {
            Toggle("Always Show Bookmarks Bar", isOn: $showBookmarksBar)
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Divider()
            Button("Reload This Page") { browser?.reload() }
                .keyboardShortcut("r")
            Button("Hard Reload This Page") { browser?.hardReload() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Actual Size") { browser?.zoomReset() }
                .keyboardShortcut("0")
            Button("Zoom In") { browser?.zoomIn() }
                .keyboardShortcut("=")
            Button("Zoom Out") { browser?.zoomOut() }
                .keyboardShortcut("-")
            Divider()
        }
        CommandGroup(after: .toolbar) {
            // Chrome's ⌃⌘F. AppKit's own item (fn-F) is turned off in LunaApp so this is the only one.
            Button("Enter Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.command, .control])
        }
        CommandMenu("History") {
            Button("Back") { browser?.back() }
                .keyboardShortcut("[")
            Button("Forward") { browser?.forward() }
                .keyboardShortcut("]")
            Divider()
            Button("Show Full History") { browser?.showHistory() }
                .keyboardShortcut("y")
        }
        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") { browser?.toggleBookmark() }
                .keyboardShortcut("d")
            Toggle("Show Bookmarks Bar", isOn: $showBookmarksBar)
            Button("Bookmark Manager") { browser?.showBookmarkManager() }
                .keyboardShortcut("b", modifiers: [.command, .option])
        }
    }
}

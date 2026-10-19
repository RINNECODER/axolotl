import AppKit
import Foundation

/// Axolotl's own pages that show in a tab without a web view: `axolotl://history`, `axolotl://ai/…`,
/// and Settings at `axolotl://settings[/<pane>]` (like Chrome's chrome://settings).
enum InternalPage {
    static let settingsScheme = "axolotl"
    static let settingsHost = "settings"

    /// A page Axolotl draws itself (never loaded in a web view, never saved to history).
    static func isInternal(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == settingsScheme
    }

    static func isSettings(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == settingsScheme && url?.host?.lowercased() == settingsHost
    }

    /// axolotl://bookmarks: the bookmark manager.
    static let bookmarksURL = URL(string: "\(settingsScheme)://bookmarks")!

    static func isBookmarks(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == settingsScheme && url?.host?.lowercased() == "bookmarks"
    }

    /// axolotl://downloads: Chrome's downloads page (⇧⌘J).
    static let downloadsURL = URL(string: "\(settingsScheme)://downloads")!

    /// axolotl://passwords: the password manager (Chrome's chrome://password-manager).
    static let passwordsURL = URL(string: "\(settingsScheme)://passwords")!

    static func isPasswords(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == settingsScheme && url?.host?.lowercased() == "passwords"
    }

    static func isDownloads(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == settingsScheme && url?.host?.lowercased() == "downloads"
    }

    /// axolotl://source?url=<page>: the page's HTML, read-only (⌥⌘U).
    static func viewSourceURL(for page: URL) -> URL {
        var c = URLComponents()
        c.scheme = settingsScheme
        c.host = "source"
        c.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        return c.url!
    }

    /// The page a axolotl://source URL shows; nil for any other URL.
    static func viewSourcePage(_ url: URL?) -> URL? {
        guard let url, url.scheme?.lowercased() == settingsScheme, url.host?.lowercased() == "source",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value
        else { return nil }
        return URL(string: value)
    }

    /// `axolotl://settings` or `axolotl://settings/<pane>`.
    static func settingsURL(_ pane: SettingsPane? = nil) -> URL {
        URL(string: "\(settingsScheme)://\(settingsHost)" + (pane.map { "/\($0.rawValue)" } ?? ""))!
    }

    /// The pane a settings URL names (old names too, e.g. `axolotl://settings/dev`); nil for the default pane.
    static func settingsPane(_ url: URL?) -> SettingsPane? {
        guard isSettings(url), let name = url?.pathComponents.first(where: { $0 != "/" }) else { return nil }
        return SettingsPane.resolve(name)
    }

    /// Tab title for an internal page.
    static func title(_ url: URL) -> String {
        if isSettings(url) { return "Settings" }
        if isBookmarks(url) { return "Bookmarks" }
        if isDownloads(url) { return "Downloads" }
        if isPasswords(url) { return "Passwords" }
        if let page = viewSourcePage(url) { return "view-source:\(page.absoluteString)" }
        return url.host == "history" ? "History" : "AI Chat"
    }

    /// SF Symbol for an internal page's tab icon.
    static func icon(_ url: URL?) -> String {
        if isSettings(url) { return "gearshape" }
        if isBookmarks(url) { return "book" }
        if isDownloads(url) { return "arrow.down.circle" }
        if isPasswords(url) { return "key" }
        if viewSourcePage(url) != nil { return "chevron.left.forwardslash.chevron.right" }
        return url?.host == "history" ? "clock" : "axolotl"
    }
}

/// Opens (or focuses) the Settings tab in the current browser window, on a pane.
/// Every "Open Settings" entry point goes through here: ⌘,, menus, onboarding, agents.
enum SettingsOpener {
    static func open(_ pane: SettingsPane? = nil) {
        if let target = BrowserCommandTargets.shared.keyOrFrontmost {
            target.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            target.actions.openSettings(pane)
            return
        }
        // No browser window: open one; it shows Settings when it registers.
        BrowserCommandTargets.shared.pendingSettings = .some(pane)
        _ = BrowserWindows.open(profileId: ProfileManager.shared.lastActiveProfileId)
    }

    /// Opens a pane by name (old names too). Returns false for unknown names.
    @discardableResult
    static func open(named raw: String) -> Bool {
        guard SettingsRouter.shared.request(raw) else { return false }
        let pane = SettingsRouter.shared.requestedPane
        SettingsRouter.shared.requestedPane = nil
        open(pane)
        return true
    }
}

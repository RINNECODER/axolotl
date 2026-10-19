import AppKit
import Foundation

/// Luna's own pages that show in a tab without a web view: `luma://history`, `luma://ai/…`,
/// and Settings at `luna://settings[/<pane>]` (like Chrome's chrome://settings).
enum InternalPage {
    static let settingsScheme = "luna"
    static let settingsHost = "settings"

    /// A page Luna draws itself (never loaded in a web view, never saved to history).
    static func isInternal(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "luma" || scheme == settingsScheme
    }

    static func isSettings(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == settingsScheme && url?.host?.lowercased() == settingsHost
    }

    /// `luna://settings` or `luna://settings/<pane>`.
    static func settingsURL(_ pane: SettingsPane? = nil) -> URL {
        URL(string: "\(settingsScheme)://\(settingsHost)" + (pane.map { "/\($0.rawValue)" } ?? ""))!
    }

    /// The pane a settings URL names (old names too, e.g. `luna://settings/dev`); nil for the default pane.
    static func settingsPane(_ url: URL?) -> SettingsPane? {
        guard isSettings(url), let name = url?.pathComponents.first(where: { $0 != "/" }) else { return nil }
        return SettingsPane.resolve(name)
    }

    /// Tab title for an internal page.
    static func title(_ url: URL) -> String {
        if isSettings(url) { return "Settings" }
        return url.host == "history" ? "History" : "AI Chat"
    }

    /// SF Symbol for an internal page's tab icon.
    static func icon(_ url: URL?) -> String {
        if isSettings(url) { return "gearshape" }
        return url?.host == "history" ? "clock" : "sparkles"
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

import AppKit
import Foundation

/// Axolotl is sandboxed, so reading another browser's data folder needs the
/// user's one-time OK through an open panel. The grant is kept as a
/// security-scoped bookmark per browser, so later imports and sync don't ask again.
enum BrowserAccess {
    static func defaultsKey(_ kind: BrowserKind) -> String { "browserImport.access.\(kind.rawValue)" }

    static func hasAccess(_ kind: BrowserKind) -> Bool {
        UserDefaults.standard.data(forKey: defaultsKey(kind)) != nil
    }

    static func revoke(_ kind: BrowserKind) {
        UserDefaults.standard.removeObject(forKey: defaultsKey(kind))
    }

    /// Resolves the stored grant. The caller must balance with `stopAccessingSecurityScopedResource()`.
    static func resolve(_ kind: BrowserKind) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(kind)) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else {
            revoke(kind)
            return nil
        }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) {
            UserDefaults.standard.set(fresh, forKey: defaultsKey(kind))
        }
        return url
    }

    /// Asks once, with the panel already showing the browser's data folder.
    /// Returns false if the user cancels or picks a different folder.
    static func request(_ browser: DetectedBrowser) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.directoryURL = browser.dataFolder
        panel.prompt = "Allow Access"
        panel.title = "Import from \(browser.kind.displayName)"
        panel.message = "To import from \(browser.kind.displayName), Axolotl needs to read its data folder. "
            + "“\(browser.dataFolder.lastPathComponent)” is already selected, so just click Allow Access. "
            + "Axolotl only reads bookmarks and history, and remembers this so it won't ask again."
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard url.standardizedFileURL.path == browser.dataFolder.standardizedFileURL.path else { return false }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]) else { return false }
        UserDefaults.standard.set(data, forKey: defaultsKey(browser.kind))
        return true
    }
}

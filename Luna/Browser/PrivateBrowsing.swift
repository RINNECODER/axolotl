import AppKit
import SwiftUI
import WebKit

/// Private windows (File ▸ New Private Window, ⌘⇧N). All of them share one non-persistent
/// website data store, dropped when the last one closes, so cookies and site data go with it.
/// Their sessions keep workspace, history and chats in memory (`ProfileSession(isPrivate:)`),
/// offer no password saving, record no usage, and aren't visible to agents (MCP host list).
enum PrivateBrowsing {
    private static var store: WKWebsiteDataStore?
    private static var openWindows = 0
    /// Favicon and tint fetches from private tabs: memory-only cache, reset with the data store.
    private(set) static var urlSession = URLSession(configuration: .ephemeral)

    static func dataStore() -> WKWebsiteDataStore {
        if let store { return store }
        let fresh = WKWebsiteDataStore.nonPersistent()
        store = fresh
        return fresh
    }

    /// Tracks a private window: pauses usage recording while it's key; the last close discards everything.
    static func track(_ window: NSWindow) {
        openWindows += 1
        let center = NotificationCenter.default
        var tokens: [NSObjectProtocol] = []
        tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { Usage.paused = true }
        })
        tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { Usage.paused = false }
        })
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                tokens.forEach(center.removeObserver)
                Usage.paused = false
                windowClosed()
            }
        })
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        guard openWindows == 0 else { return }
        store = nil
        urlSession.invalidateAndCancel()
        urlSession = URLSession(configuration: .ephemeral)
    }

    /// Stands in for the profile id in tab drag-and-drop, so private tabs can't land in a normal window.
    static let dropTargetId = UUID()

    /// Brave's private-window purple, over the dark appearance private windows use.
    static let tint = Color(lunaHex: 0x7B4DDB)
}

extension EnvironmentValues {
    /// True inside a private window.
    @Entry var isPrivateBrowsing = false
}

/// Stands in for the profile button in a private window, like Chrome's Incognito chip.
struct PrivateWindowBadge: View {
    var body: some View {
        Image(systemName: "eyeglasses")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Circle().fill(PrivateBrowsing.tint))
            .help("Private window: history, cookies and site data are discarded when you close all private windows.")
            .accessibilityElement()
            .accessibilityLabel("Private window")
    }
}

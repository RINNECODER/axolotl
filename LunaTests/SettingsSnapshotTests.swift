import AppKit
import SwiftUI
import XCTest
@testable import Luna

/// Renders each settings pane offscreen (a window that is never shown) to PNGs, light and dark, for
/// visual review. Runs only when LUNA_SETTINGS_SHOTS names an output folder, so CI writes nothing.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    func testRenderSettingsPanes() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_SETTINGS_SHOTS to a folder name to render settings PNGs.")
        }
        // The sandboxed host can only write inside its container, so shots go to its temp folder.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        print("Settings shots: \(dir)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS_PANES"]?.split(separator: ",").map(String.init)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for pane in SettingsPane.available where only?.contains(pane.rawValue) ?? true {
                try render(SettingsView(initialPane: pane), appearance: appearance,
                           to: "\(dir)/\(pane.rawValue)-\(name).png")
            }
            try render(SettingsView(initialPane: .general, query: "tab"), appearance: appearance, to: "\(dir)/search-\(name).png")
            // Sheets and popovers opened from Settings, each at its own size.
            try render(UsageDataSheet(usage: UsageStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("shots-usage.json"))), appearance: appearance, size: NSSize(width: 460, height: 560), to: "\(dir)/sheet-usage-\(name).png")
            try render(ClearBrowsingDataSheet(profileId: Usage.profileId()) { _ in },
                       appearance: appearance, size: NSSize(width: 420, height: 440), to: "\(dir)/sheet-clear-\(name).png")
            try render(MCPPortChooser(current: 8765) { _ in }, appearance: appearance, size: NSSize(width: 340, height: 260), to: "\(dir)/popover-port-\(name).png")
            try render(BrowserImportView(onDone: {}), appearance: appearance, size: NSSize(width: 640, height: 600), to: "\(dir)/sheet-import-\(name).png")
            // Left nav with Liquid Glass on.
            let glass = LiquidGlass.defaultsKey
            let previous = UserDefaults.standard.object(forKey: glass)
            UserDefaults.standard.set(true, forKey: glass)
            defer { if let previous { UserDefaults.standard.set(previous, forKey: glass) } else { UserDefaults.standard.removeObject(forKey: glass) } }
            try render(SettingsView(initialPane: .general), appearance: appearance, to: "\(dir)/nav-glass-\(name).png")
        }
    }

    /// Themed shell pieces (sidebar, Luna and Chrome tab strips) and the Appearance pane under a few presets,
    /// with Liquid Glass off so the theme's solid colors show. Pins ThemeStore; preferences are untouched.
    func testRenderThemedShell() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_SETTINGS_SHOTS to a folder name to render theme PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = WorkspaceStore(persistence: nil)
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        for url in ["https://apple.com", "https://github.com", "https://news.ycombinator.com"] { _ = store.newTab(url: URL(string: url)) }
        let actions = SidebarActions(activate: { store.activate($0) }, close: { store.close($0) }, newTab: {}, store: store)
        var glass = GlassSettings()
        glass.master = false
        for preset in [ThemePreset.luna, .ocean, .rose] {
            var theme = Theme(colors: Dictionary(uniqueKeysWithValues: ThemeColorToken.allCases.map { ($0, preset.color($0)) }))
            if preset == .rose { theme.radiusScale = 150; theme.compact = true; theme.fontScale = 110 }
            ThemeStore.shared.pin(theme: theme, glass: glass)
            for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let shell = HStack(spacing: 0) {
                    SidebarOutline(snapshot: .make(store: store, web: web), actions: actions)
                        .frame(width: 240)
                        .background(LunaBackdrop(material: .sidebar, solid: LunaSurface.sidebar, surface: .sidebar))
                    VStack(spacing: 0) {
                        HorizontalTabStrip(store: store, web: web, height: 36, onActivate: { _ in }, onClose: { _ in },
                                           onNewTab: {}, onSplit: { _, _ in })
                            .frame(height: 36)
                            .background(LunaBackdrop(material: .titlebar, solid: LunaSurface.toolbar, surface: .toolbar))
                        HorizontalTabStrip(store: store, web: web, height: ChromeMetrics.tabStripHeight, onActivate: { _ in },
                                           onClose: { _ in }, onNewTab: {}, onSplit: { _, _ in }, chromeStyle: true)
                            .frame(height: ChromeMetrics.tabStripHeight)
                            .background(ChromePalette.for(mode == "dark" ? .dark : .light).frame)
                        LunaSurface.window
                    }
                }
                try render(shell, appearance: appearance, size: NSSize(width: 900, height: 260),
                           to: "\(dir)/shell-\(preset.rawValue)-\(mode).png")
                try render(SettingsView(initialPane: .appearance), appearance: appearance, size: NSSize(width: 1100, height: 3000),
                           to: "\(dir)/appearance-\(preset.rawValue)-\(mode).png")
            }
        }
    }

    /// Chrome tab groups in both strips and the sidebar, and luna://passwords (list, detail) on a fake vault.
    func testRenderTabGroupsAndPasswords() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_SETTINGS_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_SETTINGS_SHOTS to a folder name to render PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = WorkspaceStore(persistence: nil)
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let ids = ["https://apple.com", "https://github.com", "https://news.ycombinator.com", "https://swift.org", "https://wikipedia.org"]
            .map { store.newTab(url: URL(string: $0)) }
        let work = try XCTUnwrap(store.addToNewTabGroup(ids[1]))
        store.renameFolder(work, to: "Work")
        store.addToTabGroup(ids[2], group: work)
        let read = try XCTUnwrap(store.addToNewTabGroup(ids[3]))
        store.setTabGroupColor(read, .orange)
        let later = try XCTUnwrap(store.addToNewTabGroup(ids[4]))
        store.renameFolder(later, to: "Later")
        store.setFolderExpanded(later, false)
        store.activate(ids[2])
        let actions = SidebarActions(activate: { store.activate($0) }, close: { store.close($0) }, newTab: {}, store: store)

        let profile = UUID()
        let defaults = UserDefaults(suiteName: "shots.\(profile)")!
        defaults.set(false, forKey: PasswordVault.syncKey(profile.uuidString))
        let vault = PasswordVault(store: KeychainStore(backend: FakeKeychain(), accessGroup: "TEAMID.com.luna.browser"),
                                  defaults: defaults, profileNames: { [] })
        for (host, user) in [("github.com", "octo"), ("github.com", "work@corp.com"), ("apple.com", "me@icloud.com"),
                             ("news.ycombinator.com", "pg"), ("wikipedia.org", "")] {
            try vault.save(host: host, username: user, password: "x", profile: profile)
        }
        defer { defaults.removePersistentDomain(forName: "shots.\(profile)") }

        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let shell = HStack(spacing: 0) {
                SidebarOutline(snapshot: .make(store: store, web: web), actions: actions)
                    .frame(width: 240)
                    .background(LunaBackdrop(material: .sidebar, solid: LunaSurface.sidebar, surface: .sidebar))
                VStack(spacing: 0) {
                    HorizontalTabStrip(store: store, web: web, height: 36, onActivate: { _ in }, onClose: { _ in },
                                       onNewTab: {}, onSplit: { _, _ in })
                        .frame(height: 36)
                        .background(LunaBackdrop(material: .titlebar, solid: LunaSurface.toolbar, surface: .toolbar))
                    HorizontalTabStrip(store: store, web: web, height: ChromeMetrics.tabStripHeight, onActivate: { _ in },
                                       onClose: { _ in }, onNewTab: {}, onSplit: { _, _ in }, chromeStyle: true)
                        .frame(height: ChromeMetrics.tabStripHeight)
                        .background(ChromePalette.for(mode == "dark" ? .dark : .light).frame)
                    LunaSurface.window
                }
            }
            try render(shell, appearance: appearance, size: NSSize(width: 1000, height: 260), to: "\(dir)/tabgroups-\(mode).png")
            let list = PasswordManagerModel(vault: vault, profileId: profile, authenticate: { _ in false })
            try render(PasswordManagerPageView(model: list), appearance: appearance, size: NSSize(width: 900, height: 480),
                       to: "\(dir)/passwords-\(mode).png")
            let detail = PasswordManagerModel(vault: vault, profileId: profile, authenticate: { _ in false })
            detail.select(detail.credentials.first { $0.username == "octo" })
            try render(PasswordManagerPageView(model: detail), appearance: appearance, size: NSSize(width: 900, height: 400),
                       to: "\(dir)/password-detail-\(mode).png")
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize = NSSize(width: 1100, height: 760),
                                 to path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        // Let SwiftUI lay out and settle (menus/tasks); the window is never ordered front.
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        window.contentView = nil
    }
}

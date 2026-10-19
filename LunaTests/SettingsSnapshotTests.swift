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
            try render(ClearHistorySheet(history: ProfileStoreRegistry.stores(for: Usage.profileId()).history) { _ in },
                       appearance: appearance, size: NSSize(width: 420, height: 260), to: "\(dir)/sheet-clear-\(name).png")
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

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize = NSSize(width: 1100, height: 760), to path: String) throws {
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

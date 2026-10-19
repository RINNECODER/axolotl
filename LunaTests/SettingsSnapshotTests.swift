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
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, to path: String) throws {
        let size = NSSize(width: 1100, height: 760)
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

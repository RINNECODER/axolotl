import AppKit
import WebKit
import XCTest
@testable import Luna

/// Renders the shader moon offscreen (a window that is never shown) to PNGs, at its start-page
/// size, after a resize, and after pause/resume. Runs only when LUNA_MOON_SHOTS names an output
/// folder, so CI writes nothing. A never-shown window gets no animation frames and WebKit presents
/// its canvas lazily, so a shot can come out empty; rerun when it does.
@MainActor
final class MoonSnapshotTests: XCTestCase {
    func testRenderShaderMoon() throws {
        guard let name = ProcessInfo.processInfo.environment["LUNA_MOON_SHOTS"], !name.isEmpty else {
            throw XCTSkip("Set LUNA_MOON_SHOTS to a folder name to render moon PNGs.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        print("Moon shots: \(dir.path)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let bridge = WallpaperBridge()
        var states: [String] = []
        bridge.onState = { states.append($0) }
        let webView = WallpaperWeb.makeWebView(bridge: bridge, page: .moon)
        bridge.webView = webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = NSColor(red: 0.12, green: 0.18, blue: 0.25, alpha: 1)
        window.contentView = NSView(frame: window.contentLayoutRect)
        // Start at zero size, like SwiftUI's first layout pass, then take the moon's frame.
        webView.frame = .zero
        window.contentView?.addSubview(webView)
        settle(1)
        webView.frame = NSRect(x: 0, y: 0, width: 221, height: 195.5)
        bridge.update(config: WallpaperRenderConfig(preset: .none, style: WallpaperPreset.none.defaultStyle,
                                                    fps: 30, still: false, scale: 1), mode: .running)
        settle(2)
        print("Moon states: \(states)")
        try snapshot(webView, to: dir.appendingPathComponent("moon-170.png"))

        // Window shrinks: the moon gets smaller while paused (app inactive).
        bridge.update(config: nil, mode: .paused)
        settle(0.5)
        webView.frame = NSRect(x: 0, y: 0, width: 130, height: 115)
        settle(1)
        try snapshot(webView, to: dir.appendingPathComponent("moon-100-paused.png"))
        bridge.update(config: nil, mode: .running)
        settle(1)
        try snapshot(webView, to: dir.appendingPathComponent("moon-100-resumed.png"))
        window.contentView = nil
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ webView: WKWebView, to url: URL) throws {
        var image: NSImage?
        webView.takeSnapshot(with: nil) { img, _ in image = img }
        let deadline = Date().addingTimeInterval(5)
        while image == nil, Date() < deadline { settle(0.05) }
        let cg = try XCTUnwrap(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try XCTUnwrap(NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])).write(to: url)
    }
}

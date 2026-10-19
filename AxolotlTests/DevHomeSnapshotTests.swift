import AppKit
import SwiftUI
import XCTest
#if AXOLOTL_DEV
@testable import AxolotlDev
#else
@testable import Axolotl
#endif

/// Renders the Dev home view with fixture projects and sessions offscreen (a window that is never
/// shown), light and dark. Runs only when AXOLOTL_DEV_SHOTS names an output folder.
@MainActor
final class DevHomeSnapshotTests: XCTestCase {
    func testRenderDevHome() throws {
        guard let dir = ProcessInfo.processInfo.environment["AXOLOTL_DEV_SHOTS"], !dir.isEmpty else {
            throw XCTSkip("Set AXOLOTL_DEV_SHOTS to a folder to render Dev home PNGs.")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        func project(_ name: String, branch: String?, ago: TimeInterval, count: Int) -> DevProject {
            DevProject(path: "/tmp/axolotl-fixture/\(name)", name: name, lastActivity: now - ago, harnesses: [.claudeCode],
                       sessionCount: count, isGitRepo: branch != nil, branch: branch, sources: [.claudeSessions])
        }
        func session(_ title: String, _ projectName: String, _ kind: AgentCLIKind, ago: TimeInterval, model: String) -> ExternalSession {
            let dir = URL(fileURLWithPath: "/tmp/axolotl-fixture/\(projectName)", isDirectory: true)
            return ExternalSession(harness: kind, id: UUID().uuidString, file: dir.appendingPathComponent("s.jsonl"),
                                   projectDir: dir, title: title, firstPrompt: title, updatedAt: now - ago, isLive: false,
                                   messageCount: 12, startedInAxolotl: true, model: model)
        }
        let workspace = DevWorkspace()
        workspace.seedForSnapshots(
            projects: [project("axolotl", branch: "main", ago: 600, count: 14), project("web-shop", branch: "dev", ago: 7_200, count: 3)],
            recent: [
                session("Fix resumed chat scrolling to the top", "axolotl", .claudeCode, ago: 240, model: "claude-opus-5-5"),
                session("Compact the Dev home start flow", "axolotl", .claudeCode, ago: 3_000, model: "claude-sonnet-5"),
                session("Add product sync", "web-shop", .codex, ago: 9_000, model: "gpt-6.1-sol"),
                session("Tune the training schedule", "ml-notes", .codex, ago: 90_000, model: "gpt-6.1-sol"),
                session("Fix the game clock", "game-proto", .claudeCode, ago: 200_000, model: "claude-haiku-5-5"),
                session("Should not show (sixth)", "axolotl", .claudeCode, ago: 400_000, model: "claude-haiku-5-5"),
            ])
        workspace.flow.choose(project: "/tmp/axolotl-fixture/axolotl")
        workspace.flow.choose(harness: .claudeCode)
        let listing = ModelListing(harness: .claudeCode, models: [
            HarnessModel(id: "opus", displayName: "Opus 5.5", isDefault: true),
            HarnessModel(id: "sonnet", displayName: "Sonnet 5", isDefault: false),
        ], source: .live, fetchedAt: now)
        for (name, appearance, palette) in [("light", NSAppearance.Name.aqua, DevPalette.of(.light)), ("dark", .darkAqua, DevPalette.of(.dark))] {
            let view = DevHomeView(workspace: workspace, palette: palette, harnesses: [], onOpenFolder: {}, onOpenSettings: {},
                                   initialListing: listing)
                .background(palette.background)
                .devDropdownHost()
            try render(view, appearance: appearance, to: "\(dir)/dev-home-\(name).png")
        }
    }

    private func render<V: View>(_ view: V, appearance: NSAppearance.Name, size: NSSize = NSSize(width: 520, height: 640),
                                 to path: String) throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
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

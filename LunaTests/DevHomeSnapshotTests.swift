import AppKit
import SwiftUI
import XCTest
#if LUNA_DEV
@testable import LunaDev
#else
@testable import Luna
#endif

/// Renders the Dev home view with fixture projects and sessions offscreen (a window that is never
/// shown), light and dark. Runs only when LUNA_DEV_SHOTS names an output folder.
@MainActor
final class DevHomeSnapshotTests: XCTestCase {
    func testRenderDevHome() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUNA_DEV_SHOTS"], !dir.isEmpty else {
            throw XCTSkip("Set LUNA_DEV_SHOTS to a folder to render Dev home PNGs.")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let now = Date()
        func project(_ name: String, branch: String?, ago: TimeInterval, count: Int) -> DevProject {
            DevProject(path: "/tmp/luna-fixture/\(name)", name: name, lastActivity: now - ago, harnesses: [.claudeCode],
                       sessionCount: count, isGitRepo: branch != nil, branch: branch, sources: [.claudeSessions])
        }
        func session(_ title: String, _ projectName: String, _ kind: AgentCLIKind, ago: TimeInterval, model: String) -> ExternalSession {
            let dir = URL(fileURLWithPath: "/tmp/luna-fixture/\(projectName)", isDirectory: true)
            return ExternalSession(harness: kind, id: UUID().uuidString, file: dir.appendingPathComponent("s.jsonl"),
                                   projectDir: dir, title: title, firstPrompt: title, updatedAt: now - ago, isLive: false,
                                   messageCount: 12, startedInLuna: true, model: model)
        }
        let workspace = DevWorkspace()
        workspace.seedForSnapshots(
            projects: [project("luna", branch: "main", ago: 600, count: 14), project("apex-vintage", branch: "dev", ago: 7_200, count: 3)],
            recent: [
                session("Fix resumed chat scrolling to the top", "luna", .claudeCode, ago: 240, model: "claude-opus-5-5"),
                session("Compact the Dev home start flow", "luna", .claudeCode, ago: 3_000, model: "claude-sonnet-5"),
                session("Add print-on-demand product sync", "apex-vintage", .codex, ago: 9_000, model: "gpt-6.1-sol"),
                session("Tune the ternary finetune schedule", "bonsai-research", .codex, ago: 90_000, model: "gpt-6.1-sol"),
                session("Kickoff return clock rules", "coach-football", .claudeCode, ago: 200_000, model: "claude-haiku-5-5"),
                session("Should not show (sixth)", "luna", .claudeCode, ago: 400_000, model: "claude-haiku-5-5"),
            ])
        workspace.flow.choose(project: "/tmp/luna-fixture/luna")
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

#if DEBUG
import AppKit
import SwiftUI
import WebKit

/// Debug-only visual check: when AXOLOTL_SNAPSHOT_PATH is set, writes a PNG of
/// each window's content after AXOLOTL_SNAPSHOT_DELAY seconds (default 4), then
/// keeps running. Web page pixels are out-of-process and may render blank.
/// AXOLOTL_SNAPSHOT_SETTINGS=<pane> also shows a Settings window on that pane.
enum DebugSnapshot {
    /// Hosts the AI panel alone over a sample page so its styling can be checked.
    /// Messages for `AXOLOTL_SNAPSHOT_PANEL=cards`: a finished and a running agent run, key grabs.
    static func cardSamples() -> [ChatMessage] {
        func decided(_ op: String, _ label: String, _ c: Double?) -> AgentEvent {
            .decided(AgentDecision(choice: "e1", operation: op, target: label.isEmpty ? nil : "1", confidence: c,
                                   probability: nil, latencyMs: 140, model: "jev"), label: label)
        }
        func executed(_ n: Int, _ text: String? = nil, changed: Bool = true) -> AgentEvent {
            .executed(AgentStepRecord(step: n, action: "e1", kind: "click", choice: "e1", operation: "CLICK", text: text,
                                      confidence: nil, latencyMs: 0, url: "https://example.com", pageChanged: changed))
        }
        var done = AgentRunCard(goal: "Search Wikipedia for the Moon and open the article", model: "jev-1.14")
        for e in [decided("CLICK", "Search Wikipedia", 0.97), executed(1),
                  decided("TYPE_TEXT", "Search Wikipedia", 0.94), executed(2, "Moon"),
                  decided("CLICK", "Moon — natural satellite", 0.88), executed(3),
                  .finished(.done, steps: 3, elapsedMs: 6200)] { done.apply(e) }
        var running = AgentRunCard(goal: "Find the opening hours", model: "jev-1.14")
        for e in [decided("SCROLL_DOWN", "", 0.71), executed(1, changed: false), decided("CLICK", "Hours & location", 0.83)] {
            running.apply(e)
        }
        let openai = KeyService.registry[0]
        var signIn = GrabCard(service: openai, keyName: "axolotl-20261015", model: "jev-1.14")
        signIn.finish(GrabResult(status: .waitingForSignIn, service: openai.name, keyName: "axolotl-20261015", message: ""))
        var saved = GrabCard(service: KeyService.registry[5], keyName: "axolotl-20261015", model: "jev-1.14")
        saved.finish(GrabResult(status: .saved, service: "Hugging Face", keyName: "axolotl-20261015",
                                saved: SecretVault.Saved(keychainItem: "Axolotl API Keys / huggingface/axolotl-20261015",
                                                         account: "huggingface/axolotl-20261015"), message: ""))
        let messages = [
            ChatMessage(role: .assistant, text: done.transcript, card: .agentRun(done)),
            ChatMessage(role: .assistant, text: saved.transcript, card: .grab(saved)),
            ChatMessage(role: .assistant, text: signIn.transcript, card: .grab(signIn)),
            ChatMessage(role: .assistant, text: running.transcript, card: .agentRun(running)),
        ]
        switch ProcessInfo.processInfo.environment["AXOLOTL_SNAPSHOT_CARDS"] {
        case "running": return [ChatMessage(role: .user, text: "Is this place open on Sundays?")] + Array(messages.suffix(2))
        default: return messages
        }
    }

    static func showPanelPreview(mode: String) {
        let empty = mode == "empty"
        let web = WebViewWrapper(profileId: UUID(), dataStore: .nonPersistent())
        let tabs = TabManager()
        web.tabManager = tabs
        let tab = tabs.newTab(url: URL(string: "https://example.com")!)
        web.setActiveTab(tab)
        web.load(url: URL(string: "https://example.com")!, in: tab)
        let sample: [ChatMessage] = mode == "cards" ? cardSamples() : empty ? [] : [
            ChatMessage(role: .user, text: "What is this page for?"),
            ChatMessage(role: .assistant, text: "**example.com** is a reserved domain for documentation.\n\n- Safe to use in examples\n- Not a real service\n\nYou can link to it without asking permission."),
        ]
        struct Host: View {
            @State var messages: [ChatMessage]
            @State var open = true
            let web: WebViewWrapper
            let tab: UUID
            var body: some View {
                CommandSurfaceView(isPresented: $open, messages: $messages, webViewWrapper: web,
                                   commandRouter: CommandRouter(), gemini: GeminiClient(apiKeyProvider: { nil }),
                                   ollama: OllamaClient(), historyManager: HistoryManager(profileId: UUID()),
                                   onActionProposed: { _ in }, tabId: tab)
                    .padding(10)
                    .frame(width: Double(ProcessInfo.processInfo.environment["AXOLOTL_SNAPSHOT_PANEL_WIDTH"] ?? "") ?? 400, height: 640)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: Host(messages: sample, web: web, tab: tab)))
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }

    /// `AXOLOTL_SNAPSHOT_SEED_USAGE`: fills the active profile's usage record and history with
    /// sample habits so Personalize has something to read (turns personalization on).
    static func seedUsage() {
        UserDefaults.standard.set(true, forKey: PersonalizationPrefs.enabledKey)
        let profile = Usage.profileId()
        let usage = UsageStore.forProfile(profile)
        let counts: [(UsageFeature, Int)] = [(.newTab, 30), (.addressBar, 22), (.splitView, 12), (.find, 8),
                                             (.aiChat, 6), (.history, 4), (.downloads, 3)]
        for (feature, n) in counts { for _ in 0..<n { usage.record(feature) } }
        for (shortcut, n) in [("⌘T", 25), ("⌘L", 14), ("⌘F", 8)] { for _ in 0..<n { usage.recordShortcut(shortcut) } }
        usage.noteOpenTabs(14)
        let history = ProfileStoreRegistry.stores(for: profile).history
        let sites = [("https://github.com/", "GitHub", 9), ("https://news.ycombinator.com/", "Hacker News", 6),
                     ("https://en.wikipedia.org/wiki/Moon", "Moon - Wikipedia", 4), ("https://developer.apple.com/documentation/", "Apple Developer", 3),
                     ("https://www.youtube.com/", "YouTube", 2)]
        for round in 0..<9 {
            for (url, title, n) in sites where round < n {
                history.recordPageVisit(url: URL(string: url + (round == 0 ? "" : "?r=\(round)"))!, title: title)
            }
        }
        history.flush()
    }

    static func scheduleIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["AXOLOTL_SNAPSHOT_PATH"] else { return }
        if env["AXOLOTL_SNAPSHOT_SEED_USAGE"] != nil { seedUsage() }
        let delay = Double(env["AXOLOTL_SNAPSHOT_DELAY"] ?? "") ?? 4
        if let mode = env["AXOLOTL_SNAPSHOT_PANEL"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + min(1.5, delay)) { showPanelPreview(mode: mode) }
            if env["AXOLOTL_SNAPSHOT_MCP"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 1.5)) {
                    Task { _ = await MCPApprovalCenter.shared.ask(client: "claude-code", tool: "navigate",
                                                                  detail: "https://en.wikipedia.org/wiki/Moon", timeout: 30) }
                }
            }
            #if AXOLOTL_DEV
            if let prompt = env["AXOLOTL_SNAPSHOT_DEV_PROMPT"], let dir = env["AXOLOTL_SNAPSHOT_DEV_DIR"] {
                Task {
                    var setup = DevSettings.shared.defaultSetup
                    setup.model = "haiku"
                    DevWorkspace.shared.startNew(harness: .claudeCode, projectDir: URL(fileURLWithPath: dir), setup: setup)
                    _ = DevWorkspace.shared.session?.send(prompt)
                }
            }
            #endif
        }
        if env["AXOLOTL_SNAPSHOT_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, delay - 1.5)) {
                let raw = env["AXOLOTL_SNAPSHOT_SETTINGS"] ?? ""
                if let tab = SettingsPane.passwordsTab(for: raw) { SettingsRouter.shared.passwordsTab = tab }
                let pane = SettingsPane.resolve(raw) ?? .appearance
                let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(initialPane: pane)))
                let height = env["AXOLOTL_SNAPSHOT_SETTINGS_HEIGHT"].flatMap(Double.init) ?? 600
                window.setContentSize(NSSize(width: 820, height: height))
                window.isReleasedWhenClosed = false
                window.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let url = URL(fileURLWithPath: base).deletingPathExtension()
                    .appendingPathExtension(i == 0 ? "png" : "\(i).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
        }
    }
}
#endif

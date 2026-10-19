import AppKit
import Darwin
import SwiftUI

/// Settings → Agents: Connect agents (both builds), Recent AI changes, then Dev mode's harness settings (Luna Dev only).
struct AgentsSettingsView: View {
    var body: some View {
        if DevMode.isDevBuild && DevMode.isAvailable {
            DevSettingsView()
        } else {
            ConnectAgentsSection()
            DeveloperToolsSection()
            RecentAIChangesSection()
        }
    }
}

/// "Enable Developer Tools": Web Inspector (Inspect Element in the page menu, and Safari's Develop menu).
struct DeveloperToolsSection: View {
    @AppStorage(WebViewWrapper.developerToolsKey) private var enabled = false

    var body: some View {
        SettingsCard("Developer") {
            SettingsToggleRow("Enable Developer Tools",
                              subtitle: "Adds Inspect Element to the page's context menu. Applies to tabs opened after you turn it on.",
                              isOn: $enabled)
            .onChange(of: enabled) { _, _ in
                NotificationCenter.default.post(name: WebViewWrapper.developerToolsChangedNotification, object: nil)
            }
        }
    }
}

/// Changes an AI agent made to Luna, newest first, each with Undo.
struct RecentAIChangesSection: View {
    @ObservedObject private var log = AIChangeLog.shared
    @State private var undoError: String?

    var body: some View {
        SettingsCard("Recent AI changes") {
            if log.entries.isEmpty {
                SettingsNoteRow("Changes your AI agent makes appear here, with Undo.")
            } else {
                ForEach(log.entries) { entry in
                    ChangeRow(entry: entry) {
                        do { _ = try Customizer.shared.undo(entry.id) } catch { undoError = error.localizedDescription }
                    }
                }
            }
        }
        .alert("Couldn't undo", isPresented: Binding(get: { undoError != nil }, set: { if !$0 { undoError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(undoError ?? "")
        }
    }
}

private struct ChangeRow: View {
    let entry: AIChange
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entry.lines.prefix(2), id: \.self) { line in
                    Text(line.text).font(.system(size: 13)).strikethrough(entry.undone).lineLimit(1)
                }
                if entry.lines.count > 2 {
                    Text("and \(entry.lines.count - 2) more").foregroundStyle(.secondary)
                }
                Text("\(entry.source) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if entry.undone {
                Text("Undone").foregroundStyle(.secondary)
            } else {
                Button("Undo", action: onUndo)
            }
        }
        .settingsRowPadding()
        .accessibilityElement(children: .combine)
    }
}

/// "Connect agents": Luna's loopback MCP server for Claude Code, Codex and other MCP clients.
struct ConnectAgentsSection: View {
    @AppStorage(LunaMCPBridge.enabledKey) private var enabled = false
    @AppStorage(LunaMCPBridge.trustedKey) private var trusted = false
    @AppStorage(LunaMCPBridge.portKey) private var port = LunaMCPBridge.defaultPort
    @ObservedObject private var bridge = LunaMCPBridge.shared
    @State private var choosingPort = false
    @State private var copied: String?
    @State private var confirmRegenerate = false

    var body: some View {
        SettingsCard("Connect agents", footer: "Outside agents get the same tools as /agent: tabs, navigate, snapshot, click, type, select, scroll, read, run_task and grab_api_key. Luna listens on 127.0.0.1 only and asks before an agent navigates, types, clicks or runs a task, once per agent session. For Codex, paste the config into ~/.codex/config.toml and set LUNA_MCP_TOKEN with the token export.") {
            SettingsToggleRow("Let agents drive Luna",
                              subtitle: "An MCP server for Claude Code, Codex and other agents, on this Mac only.", isOn: $enabled)
                .onChange(of: enabled) { _, _ in bridge.applySettings() }
            SettingsRow("Port", subtitle: String(port)) {
                HStack(spacing: 8) {
                    Button("Change…") { choosingPort = true }
                        .popover(isPresented: $choosingPort, arrowEdge: .bottom) {
                            MCPPortChooser(current: port) { chosen in
                                choosingPort = false
                                guard let chosen, chosen != port else { return }
                                port = chosen
                                if enabled { bridge.applySettings() }
                            }
                        }
                }
            }
            SettingsRow("Status") { Text(statusText).font(.system(size: 12)).foregroundStyle(statusIsError ? .red : .secondary) }
            SettingsToggleRow("Don't ask before agents act",
                              subtitle: "Trusted: agents navigate, type, click and run tasks without asking.", isOn: $trusted)
            SettingsRow("Connect an agent", subtitle: copied.map { "Copied \($0)." } ?? "Copy a command or config for your agent.") {
                Button("Claude Code") { copy(bridge.claudeCommand, "Claude Code command") }
                    .accessibilityLabel("Copy Claude Code command")
                Button("Codex config") { copy(bridge.codexConfig, "Codex config") }
                    .accessibilityLabel("Copy Codex config")
                Button("Token export") { copy(bridge.codexTokenExport, "token export") }
                    .accessibilityLabel("Copy token export")
            }
            SettingsRow("Token", subtitle: "Connected agents stop working until you give them a new one.") {
                Button("Regenerate token", role: .destructive) { confirmRegenerate = true }
            }
        }
        .confirmationDialog("Regenerate the token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) {
                bridge.regenerateToken()
                copied = nil
            }
        } message: {
            Text("Connected agents stop working until you give them the new token.")
        }
    }

    private var statusText: String {
        switch bridge.status {
        case .off: return "Off"
        case .starting: return "Starting…"
        case .running(let p): return "Listening on http://127.0.0.1:\(p)/mcp"
        case .failed(let message): return message
        }
    }

    private var statusIsError: Bool {
        if case .failed = bridge.status { return true }
        return false
    }

    private func copy(_ text: String, _ what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = what
    }
}


/// Popover for the MCP port: free ports near the default, or any port with the stepper.
struct MCPPortChooser: View {
    let current: Int
    let done: (Int?) -> Void
    @State private var draft: Int
    @State private var suggestions: [Int] = []

    init(current: Int, done: @escaping (Int?) -> Void) {
        self.current = current
        self.done = done
        _draft = State(initialValue: current)
    }

    private var draftIsFree: Bool { draft == current || LocalPort.isFree(draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Port").font(.system(size: 17, weight: .semibold)).accessibilityAddTraits(.isHeader)
            SettingsCard {
                SettingsRow("Free ports") {
                    SettingsDropdown(title: "Free ports", selection: $draft,
                                     options: (suggestions.contains(draft) ? suggestions : [draft] + suggestions)
                                         .map { .init($0, $0 == current ? "\($0) (current)" : String($0)) },
                                     minWidth: 110)
                }
                SettingsRow("Port \(String(draft))") {
                    Stepper("Port \(String(draft))", value: $draft, in: LocalPort.range).labelsHidden()
                }
            }
            if !draftIsFree {
                Text("Another app is using this port.").font(.system(size: 12)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Use Port") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.settingsProminent)
                    .disabled(!draftIsFree)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(SettingsStyle.page)
        .settingsControlStyles()
        .onAppear {
            suggestions = ([current] + LocalPort.freePorts(from: LunaMCPBridge.defaultPort, count: 6))
                .reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        }
    }
}

/// Loopback port checks for the MCP port chooser.
enum LocalPort {
    static let range = 1024...65535

    /// True when nothing listens on 127.0.0.1:`port`.
    static func isFree(_ port: Int) -> Bool {
        guard range.contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// Up to `count` free ports at or above `start`.
    static func freePorts(from start: Int, count: Int) -> [Int] {
        var found: [Int] = []
        var port = start
        while found.count < count, port <= range.upperBound, port < start + 200 {
            if isFree(port) { found.append(port) }
            port += 1
        }
        return found
    }
}

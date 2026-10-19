import AppKit
import Darwin
import SwiftUI

/// Settings → Developer: Connect agents (both builds), then Dev mode's harness settings (Luna Dev only).
struct DeveloperSettingsView: View {
    var body: some View {
        if DevMode.isDevBuild && DevMode.isAvailable {
            DevSettingsView()
        } else {
            Form { ConnectAgentsSection() }
                .formStyle(.grouped)
        }
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
        Section("Connect agents") {
            Toggle(isOn: $enabled) {
                Text("Let agents drive Luna")
                Text("An MCP server for Claude Code, Codex and other agents, on this Mac only.")
            }
                .onChange(of: enabled) { _, _ in bridge.applySettings() }
            LabeledContent("Port") {
                HStack(spacing: 8) {
                    Text(String(port)).monospacedDigit().foregroundStyle(.secondary)
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
            LabeledContent("Status") { Text(statusText).foregroundStyle(statusIsError ? .red : .secondary) }
            Toggle(isOn: $trusted) {
                Text("Don't ask before agents act")
                Text("Trusted: agents navigate, type, click and run tasks without asking.")
            }
            HStack {
                Button("Copy Claude Code command") { copy(bridge.claudeCommand, "Claude Code command") }
                Button("Copy Codex config") { copy(bridge.codexConfig, "Codex config") }
                Button("Copy token export") { copy(bridge.codexTokenExport, "token export") }
            }
            HStack {
                Button("Regenerate token", role: .destructive) { confirmRegenerate = true }
                if let copied { Text("Copied \(copied).").font(.callout).foregroundStyle(.secondary) }
            }
            Text("Outside agents get the same tools as /agent: tabs, navigate, snapshot, click, type, select, scroll, read, run_task and grab_api_key. Luna listens on 127.0.0.1 only and asks before an agent navigates, types, clicks or runs a task, once per agent session. For Codex, paste the config into ~/.codex/config.toml and set LUNA_MCP_TOKEN with the token export.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
private struct MCPPortChooser: View {
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
            Text("Port").font(.headline)
            LunaPicker("Free ports", selection: $draft,
                       options: (suggestions.contains(draft) ? suggestions : [draft] + suggestions)
                           .map { .init($0, $0 == current ? "\($0) (current)" : String($0)) })
            Stepper(value: $draft, in: LocalPort.range) {
                Text("Port \(String(draft))").monospacedDigit()
            }
            if !draftIsFree {
                Text("Another app is using this port.").font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Use Port") { done(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draftIsFree)
            }
        }
        .padding(16)
        .frame(width: 300)
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

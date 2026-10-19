import AppKit
import Combine
import Foundation
import Security
import WebKit

/// Luna's in-app MCP server ("Connect agents" in Settings): lets Claude Code, Codex and
/// other MCP clients drive Luna's tabs with the same tools as the `/agent` panel.
/// Off by default; loopback only; bearer token in the Keychain.
final class LunaMCPBridge: ObservableObject {
    static let shared = LunaMCPBridge()

    enum Status: Equatable {
        case off
        case starting
        case running(UInt16)
        case failed(String)
    }

    static let enabledKey = "lunaMCP.enabled"
    static let portKey = "lunaMCP.port"
    static let trustedKey = "lunaMCP.trusted"
    static let defaultPort = 47821
    static let tokenEnvVar = "LUNA_MCP_TOKEN"

    @Published private(set) var status: Status = .off

    private var server: MCPServer?
    private var boundPort: UInt16 = 0
    private var cachedToken: String?
    /// Tokens issued to Dev mode CLI sessions; valid until the session closes.
    private(set) var devSessionTokens: Set<String> = []
    /// Tokens for Full auto CLI sessions: the CLI asks nobody, so Luna's approvals stay on.
    private(set) var devPromptingTokens: Set<String> = []
    private let approvals = MCPApprovalPrompt()
    private lazy var toolbox = LunaToolbox { LunaBrowserHosts.shared.current }

    nonisolated deinit {}

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var isTrusted: Bool { UserDefaults.standard.bool(forKey: Self.trustedKey) }

    var port: Int {
        let value = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1024...65535).contains(value) ? value : Self.defaultPort
    }

    var url: String { "http://127.0.0.1:\(port)/mcp" }

    /// Starts or stops the server to match Settings (also used after a port change).
    func applySettings() {
        stop()
        guard isEnabled else { return }
        let token = ensureToken()
        let configured = UInt16(port)
        boundPort = configured
        let endpoint = MCPEndpoint(toolbox: toolbox, port: { [weak self] in self?.boundPort ?? configured }, token: { [weak self] in self?.cachedToken ?? token },
                                   isTrusted: { [weak self] in self?.isTrusted ?? false }, approver: approvals)
        endpoint.trustedTokens = { [weak self] in self?.devSessionTokens ?? [] }
        endpoint.promptingTokens = { [weak self] in self?.devPromptingTokens ?? [] }
        let server = MCPServer(endpoint: endpoint)
        self.server = server
        status = .starting
        Task {
            do {
                let bound = try await server.start(port: configured)
                guard self.server === server else { return }
                boundPort = bound
                status = .running(bound)
            } catch {
                guard self.server === server else { return }
                self.server = nil
                status = .failed("Port \(configured) is unavailable: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .off
    }

    // MARK: Token

    /// The bearer token, created (256 random bits) on first use.
    @discardableResult
    func ensureToken() -> String {
        if let cachedToken { return cachedToken }
        if let saved = KeychainManager.shared.string(for: .lunaMCPToken), !saved.isEmpty {
            cachedToken = saved
            return saved
        }
        return regenerateToken()
    }

    /// Replaces the token; connected agents must be updated with the new one.
    @discardableResult
    func regenerateToken() -> String {
        let token = Self.makeToken()
        try? KeychainManager.shared.store(token, for: .lunaMCPToken)
        cachedToken = token
        return token
    }

    static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Dev mode sessions

    /// Luna's tools for one Dev mode CLI session, or nil when the bridge is off. The session
    /// gets its own token, trusted so Luna does not prompt on top of the CLI's approvals,
    /// unless the CLI runs in Full auto and asks nobody: then Luna's approvals apply.
    func devAttachment(approval: DevApprovalBehavior) -> DevMCPAttachment? {
        guard isEnabled else { return nil }
        let token = Self.makeToken()
        let trusted = approval != .fullAuto
        if trusted { devSessionTokens.insert(token) } else { devPromptingTokens.insert(token) }
        return DevMCPAttachment(url: url, token: token) { [weak self] in
            Task { @MainActor in
                self?.devSessionTokens.remove(token)
                self?.devPromptingTokens.remove(token)
            }
        }
    }

    // MARK: Ready-made client configs

    var claudeCommand: String {
        "claude mcp add --transport http luna \(url) --header \"Authorization: Bearer \(ensureToken())\""
    }

    var codexConfig: String {
        """
        [mcp_servers.luna]
        url = "\(url)"
        bearer_token_env_var = "\(Self.tokenEnvVar)"
        """
    }

    var codexTokenExport: String { "export \(Self.tokenEnvVar)=\(ensureToken())" }
}

// MARK: - Browser windows

/// The browser windows tools can drive. The MCP bridge uses the front-most one.
final class LunaBrowserHosts {
    static let shared = LunaBrowserHosts()
    private init() {}

    private final class Entry {
        weak var window: NSWindow?
        let session: () -> ProfileSession
        init(window: NSWindow, session: @escaping () -> ProfileSession) {
            self.window = window
            self.session = session
        }
    }

    private var entries: [Entry] = []

    func register(window: NSWindow, session: @escaping () -> ProfileSession) {
        entries.removeAll { $0.window == nil || $0.window === window }
        entries.append(Entry(window: window, session: session))
    }

    var current: AgentBrowserHost? {
        entries.removeAll { $0.window == nil }
        let front = NSApp.orderedWindows.lazy.compactMap { w in self.entries.first { $0.window === w } }.first
        return (front ?? entries.last).map { ProfileSessionHost(session: $0.session()) }
    }

    /// A profile's stores, using an open window's workspace when one shows that profile.
    func personalization(for profileId: UUID) -> PersonalizationContext? {
        entries.removeAll { $0.window == nil }
        if let session = entries.lazy.map({ $0.session() }).first(where: { $0.profileId == profileId }) {
            return ProfileSessionHost(session: session).personalization
        }
        let history = ProfileStoreRegistry.stores(for: profileId).history
        return PersonalizationContext(profileId: profileId, usage: .forProfile(profileId), history: { history.historyEvents },
                                      bookmarks: .forProfile(profileId), workspace: nil)
    }
}

/// Adapts one window's profile session (workspace + web views) to the tools.
final class ProfileSessionHost: AgentBrowserHost {
    let session: ProfileSession

    nonisolated deinit {}

    init(session: ProfileSession) {
        self.session = session
    }

    var tabs: [AgentTabInfo] {
        let active = session.tabManager.currentTab
        return session.tabManager.tabOrder.compactMap { id in
            session.workspace.tab(id).map {
                AgentTabInfo(id: id, title: $0.customTitle ?? $0.title, url: $0.url?.absoluteString ?? "", active: id == active)
            }
        }
    }

    var activeTabId: UUID? { session.tabManager.currentTab }

    func webView(for tab: UUID) -> WKWebView? {
        session.ensureLoaded(tab)
        return session.webViewWrapper.webViewIfLoaded(for: tab)
    }

    func openTab(url: URL) -> UUID {
        let id = session.workspace.newTab(url: url, activate: true)
        session.webViewWrapper.load(url: url, in: id)
        session.webViewWrapper.setActiveTab(id)
        return id
    }

    func selectTab(_ id: UUID) {
        session.tabManager.switchToTab(id)
        session.webViewWrapper.setActiveTab(id)
        session.ensureLoaded(id)
    }

    func navigate(_ tab: UUID, to url: URL) {
        session.tabManager.navigate(tab: tab, to: url)
        session.webViewWrapper.load(url: url, in: tab)
    }

    var personalization: PersonalizationContext? {
        let history = session.historyManager
        return PersonalizationContext(profileId: session.profileId, usage: .forProfile(session.profileId),
                                      history: { history.historyEvents }, bookmarks: .forProfile(session.profileId),
                                      workspace: session.workspace)
    }
}

// MARK: - Approval

/// Asks before an outside agent navigates, types, clicks or runs a task, once per client session.
final class MCPApprovalPrompt: MCPApproving {
    static let timeout: TimeInterval = 120

    nonisolated deinit {}

    func approve(client: String, tool: String, detail: String) async -> MCPApproval {
        // An open AI panel shows the request inline; otherwise fall back to a sheet.
        if let decision = await MCPApprovalCenter.shared.ask(client: client, tool: tool, detail: detail,
                                                              timeout: Self.timeout) {
            return decision
        }
        let alert = NSAlert()
        let preview = PersonalizationTools.previewNames.contains(tool)
        if preview {
            // Customizations: the change itself, Apply or Cancel; never allowed for a whole session.
            alert.messageText = MCPApprovalCenter.Request(client: client, tool: tool, detail: detail).title
            alert.informativeText = detail
            alert.addButton(withTitle: "Apply")
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        } else {
            alert.messageText = "\(client) wants to use Luna: \(tool.replacingOccurrences(of: "_", with: " "))"
            alert.informativeText = (detail.isEmpty ? "" : detail + "\n\n") +
                "Allow for This Session lets this agent use \(tool.replacingOccurrences(of: "_", with: " ")) without asking until it disconnects."
            alert.addButton(withTitle: "Allow Once")
            alert.addButton(withTitle: "Allow for This Session")
            let deny = alert.addButton(withTitle: "Deny")
            deny.keyEquivalent = "\u{1b}"
        }
        NSApp.activate()

        let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.orderedWindows.first { $0.isVisible }
        let response: NSApplication.ModalResponse
        if let window {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak alert, weak window] in
                guard let sheet = alert?.window, sheet.isVisible else { return }
                window?.endSheet(sheet, returnCode: .abort)
            }
            response = await withCheckedContinuation { cont in
                alert.beginSheetModal(for: window) { cont.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .once
        case .alertSecondButtonReturn: return preview ? .deny : .session
        default: return .deny
        }
    }
}

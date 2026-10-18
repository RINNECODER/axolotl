import AppKit
import Foundation
import Observation

/// How much a Dev mode agent may do without asking, mapped to each harness's real modes.
nonisolated enum DevApprovalBehavior: String, CaseIterable, Codable, Sendable {
    /// Ask before edits and commands.
    case ask
    /// Edit files in the project freely; ask before commands that leave the sandbox.
    case allowEdits
    /// Never ask. Claude `bypassPermissions`; Codex `never` + `danger-full-access`.
    case fullAuto

    var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .allowEdits: return "Allow edits"
        case .fullAuto: return "Full auto"
        }
    }

    /// `claude --permission-mode` (choices in 2.1.302: acceptEdits, auto, bypassPermissions, manual, dontAsk, plan).
    var claudePermissionMode: String {
        switch self {
        case .ask: return "manual"
        case .allowEdits: return "acceptEdits"
        case .fullAuto: return "bypassPermissions"
        }
    }

    /// Codex `thread/start` `approvalPolicy` (untrusted | on-request | never).
    var codexApprovalPolicy: String {
        switch self {
        case .ask: return "untrusted"
        case .allowEdits: return "on-request"
        case .fullAuto: return "never"
        }
    }

    /// Codex `thread/start` `sandbox` (read-only | workspace-write | danger-full-access).
    var codexSandbox: String {
        self == .fullAuto ? "danger-full-access" : "workspace-write"
    }
}

/// Dev mode preferences, persisted in UserDefaults and observable from SwiftUI.
///
///     @State private var settings = DevSettings.shared
///     Picker("Approval", selection: $settings.approvalBehavior) { … }
///
/// The adapters read these when a session starts (`AgentCLISessions.make`); changes apply to
/// the next session. CLI path overrides are picked with `chooseCLIPath(for:)` (file panel),
/// never typed.
@MainActor
@Observable
final class DevSettings {
    static let shared = DevSettings()

    nonisolated enum Key {
        static let defaultHarness = "luna_dev.defaultHarness"
        static let defaultModels = "luna_dev.defaultModels"
        static let approval = "luna_dev.approvalBehavior"
        static let browserTools = "luna_dev.autoWireBrowserTools"
        static let liveSync = "luna_dev.liveSyncEnabled"
        static let terminal = "luna_dev.showTerminalByDefault"
        static let cliPaths = "luna_dev.cliPathOverrides"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Harness a new thread starts with.
    var defaultHarness: AgentCLIKind {
        didSet { defaults.set(defaultHarness.rawValue, forKey: Key.defaultHarness) }
    }

    /// Model id per harness (ids from `ModelCatalog`); missing = the harness's own default.
    var defaultModels: [HarnessID: String] {
        didSet { defaults.set(Self.encode(defaultModels), forKey: Key.defaultModels) }
    }

    var approvalBehavior: DevApprovalBehavior {
        didSet { defaults.set(approvalBehavior.rawValue, forKey: Key.approval) }
    }

    /// Attach Luna's browser tools (MCP bridge) to new sessions when the bridge is on.
    var autoWireBrowserTools: Bool {
        didSet { defaults.set(autoWireBrowserTools, forKey: Key.browserTools) }
    }

    /// Experimental: list and mirror Claude Code / Codex sessions started outside Luna
    /// (`SessionSync`). Off by default.
    var liveSyncEnabled: Bool {
        didSet { defaults.set(liveSyncEnabled, forKey: Key.liveSync) }
    }

    /// Open the raw terminal instead of the thread view for new Dev panels.
    var showTerminalByDefault: Bool {
        didSet { defaults.set(showTerminalByDefault, forKey: Key.terminal) }
    }

    /// Absolute executable per harness, used instead of PATH lookup.
    private(set) var cliPathOverrides: [HarnessID: String] {
        didSet { defaults.set(Self.encode(cliPathOverrides), forKey: Key.cliPaths) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultHarness = defaults.string(forKey: Key.defaultHarness).flatMap(AgentCLIKind.init(rawValue:)) ?? .claudeCode
        defaultModels = Self.decode(defaults.dictionary(forKey: Key.defaultModels))
        approvalBehavior = defaults.string(forKey: Key.approval).flatMap(DevApprovalBehavior.init(rawValue:)) ?? .ask
        autoWireBrowserTools = defaults.object(forKey: Key.browserTools) as? Bool ?? true
        liveSyncEnabled = defaults.object(forKey: Key.liveSync) as? Bool ?? false
        showTerminalByDefault = defaults.object(forKey: Key.terminal) as? Bool ?? false
        cliPathOverrides = Self.decode(defaults.dictionary(forKey: Key.cliPaths))
    }

    func defaultModel(for harness: HarnessID) -> String? { defaultModels[harness] }

    /// nil clears the default (use the harness's own).
    func setDefaultModel(_ model: String?, for harness: HarnessID) {
        defaultModels[harness] = (model?.isEmpty ?? true) ? nil : model
    }

    /// Sets or clears (nil) an executable override; rejects files that are not executable.
    @discardableResult
    func setCLIPathOverride(_ url: URL?, for harness: HarnessID) -> Bool {
        guard let url else { cliPathOverrides[harness] = nil; return true }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        cliPathOverrides[harness] = url.path
        return true
    }

    /// Shows an open panel for the harness's executable and stores the choice. Returns the
    /// chosen path, or nil when cancelled / not executable. Rescan with `HarnessCatalog.discover(refresh: true)`.
    @discardableResult
    func chooseCLIPath(for harness: HarnessID) async -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose the \(harness.displayName) executable"
        panel.prompt = "Use"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if let current = cliPathOverrides[harness] ?? LoginShellEnvironment.locate(harness.executableName) {
            panel.directoryURL = URL(fileURLWithPath: current).deletingLastPathComponent()
        }
        guard await panel.begin() == .OK, let url = panel.url, setCLIPathOverride(url, for: harness) else { return nil }
        return url.path
    }

    /// The executable to launch for `kind`: the override if still executable, else the bare name
    /// (resolved on the login PATH by the caller).
    nonisolated static func executable(for kind: AgentCLIKind, defaults: UserDefaults = .standard) -> String {
        if let path = storedCLIPathOverrides(defaults)[kind.harnessID], FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return kind.executableName
    }

    /// Overrides readable off the main actor (HarnessCatalog, adapters).
    nonisolated static func storedCLIPathOverrides(_ defaults: UserDefaults = .standard) -> [HarnessID: String] {
        decode(defaults.dictionary(forKey: Key.cliPaths))
    }

    nonisolated static func storedLiveSyncEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Key.liveSync) as? Bool ?? false
    }

    nonisolated private static func encode(_ map: [HarnessID: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map.map { ($0.key.rawValue, $0.value) })
    }

    nonisolated private static func decode(_ raw: [String: Any]?) -> [HarnessID: String] {
        var out: [HarnessID: String] = [:]
        for (key, value) in raw ?? [:] {
            if let id = HarnessID(rawValue: key), let path = value as? String, !path.isEmpty { out[id] = path }
        }
        return out
    }
}

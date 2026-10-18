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

/// What a new Dev session starts with (Dev home "Start" button, `.newSession` terminals).
nonisolated struct DevSessionSetup: Codable, Equatable, Hashable, Sendable {
    /// Which folder a new session opens in.
    enum ProjectChoice: Codable, Equatable, Hashable, Sendable {
        /// The project used last (`DevPrefs.projectKey`).
        case last
        case specific(String)
    }

    var harness: AgentCLIKind
    /// Model id (`ModelCatalog`); nil = the harness's default.
    var model: String?
    /// Reasoning effort (Claude `--effort`, Codex `model_reasoning_effort`); nil = default.
    var effort: String?
    var approvalBehavior: DevApprovalBehavior
    var project: ProjectChoice

    init(harness: AgentCLIKind = .claudeCode, model: String? = nil, effort: String? = nil,
         approvalBehavior: DevApprovalBehavior = .ask, project: ProjectChoice = .last) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.approvalBehavior = approvalBehavior
        self.project = project
    }

    /// The folder `project` points at (`.last` reads Luna's last Dev project), nil when unset.
    func projectPath(_ defaults: UserDefaults = .standard) -> String? {
        switch project {
        case .last: return defaults.string(forKey: DevPrefs.projectKey)
        case .specific(let path): return path
        }
    }
}

/// Named accent colors for Dev mode (the UI maps each to its palette).
nonisolated enum DevAccent: String, CaseIterable, Codable, Sendable {
    case blue, violet, green, orange, pink, graphite
    var displayName: String { rawValue.capitalized }
}

nonisolated enum DevDensity: String, CaseIterable, Codable, Sendable {
    case compact, comfortable
}

nonisolated enum DevFontScale: String, CaseIterable, Codable, Sendable {
    case small, medium, large
    /// Multiplier for the Dev type ramp.
    var factor: Double {
        switch self {
        case .small: return 0.9
        case .medium: return 1
        case .large: return 1.15
        }
    }
}

nonisolated enum DevTimelineStyle: String, CaseIterable, Codable, Sendable {
    /// User turns in bubbles, assistant as text.
    case bubbles
    /// Everything as flat rows, terminal-like.
    case plain
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
        static let skipHome = "luna_dev.skipHome"
        static let defaultSetup = "luna_dev.defaultSetup"
        static let hiddenProjects = "luna_dev.hiddenProjects"
        static let searchRoots = "luna_dev.projectSearchRoots"
        static let accent = "luna_dev.accent"
        static let density = "luna_dev.density"
        static let fontScale = "luna_dev.fontScale"
        static let toolDetails = "luna_dev.showToolDetails"
        static let timelineStyle = "luna_dev.timelineStyle"
    }

    /// Folders `ProjectFinder` scans (shallowly) for git repos when none are configured.
    nonisolated static var defaultProjectSearchRoots: [String] {
        let home = NSHomeDirectory()
        return [home] + ["Developer", "Documents", "Projects", "code"].map { home + "/" + $0 }
    }

    /// Open straight into the last session instead of the Dev home view.
    var skipHome: Bool {
        didSet { defaults.set(skipHome, forKey: Key.skipHome) }
    }

    /// What the Dev home view's "New session" starts with.
    var defaultSetup: DevSessionSetup {
        didSet { defaults.set(try? JSONEncoder().encode(defaultSetup), forKey: Key.defaultSetup) }
    }

    /// Project paths the user hid from `ProjectFinder` results.
    private(set) var hiddenProjects: Set<String> {
        didSet { defaults.set(hiddenProjects.sorted(), forKey: Key.hiddenProjects) }
    }

    /// Roots `ProjectFinder` scans for git repos (absolute paths). Empty = no scan.
    var projectSearchRoots: [String] {
        didSet { defaults.set(projectSearchRoots, forKey: Key.searchRoots) }
    }

    var accent: DevAccent {
        didSet { defaults.set(accent.rawValue, forKey: Key.accent) }
    }

    var density: DevDensity {
        didSet { defaults.set(density.rawValue, forKey: Key.density) }
    }

    var fontScale: DevFontScale {
        didSet { defaults.set(fontScale.rawValue, forKey: Key.fontScale) }
    }

    /// Show tool inputs / outputs expanded in the timeline.
    var showToolDetails: Bool {
        didSet { defaults.set(showToolDetails, forKey: Key.toolDetails) }
    }

    var timelineStyle: DevTimelineStyle {
        didSet { defaults.set(timelineStyle.rawValue, forKey: Key.timelineStyle) }
    }

    func hideProject(_ path: String) { hiddenProjects.insert(path) }
    func unhideProject(_ path: String) { hiddenProjects.remove(path) }
    func isHidden(_ path: String) -> Bool { hiddenProjects.contains(path) }

    nonisolated static func storedHiddenProjects(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: Key.hiddenProjects) ?? [])
    }

    nonisolated static func storedProjectSearchRoots(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: Key.searchRoots) ?? defaultProjectSearchRoots
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
        let harness = defaults.string(forKey: Key.defaultHarness).flatMap(AgentCLIKind.init(rawValue:)) ?? .claudeCode
        let models: [HarnessID: String] = Self.decode(defaults.dictionary(forKey: Key.defaultModels))
        let approval = defaults.string(forKey: Key.approval).flatMap(DevApprovalBehavior.init(rawValue:)) ?? .ask
        skipHome = defaults.object(forKey: Key.skipHome) as? Bool ?? false
        defaultSetup = defaults.data(forKey: Key.defaultSetup).flatMap { try? JSONDecoder().decode(DevSessionSetup.self, from: $0) }
            ?? DevSessionSetup(harness: harness, model: models[harness.harnessID], approvalBehavior: approval)
        hiddenProjects = Self.storedHiddenProjects(defaults)
        projectSearchRoots = Self.storedProjectSearchRoots(defaults)
        accent = defaults.string(forKey: Key.accent).flatMap(DevAccent.init(rawValue:)) ?? .blue
        density = defaults.string(forKey: Key.density).flatMap(DevDensity.init(rawValue:)) ?? .comfortable
        fontScale = defaults.string(forKey: Key.fontScale).flatMap(DevFontScale.init(rawValue:)) ?? .medium
        showToolDetails = defaults.object(forKey: Key.toolDetails) as? Bool ?? true
        timelineStyle = defaults.string(forKey: Key.timelineStyle).flatMap(DevTimelineStyle.init(rawValue:)) ?? .bubbles
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

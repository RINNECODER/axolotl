import Foundation

// MARK: - Harness ids

/// Every coding-agent CLI ("harness") Luna knows how to find. Only the ones with an
/// `agentKind` can be driven by Dev mode today; the rest are reported as installed-but-unsupported.
nonisolated enum HarnessID: String, CaseIterable, Codable, Sendable, Identifiable {
    case claudeCode
    case codex
    case gemini
    case opencode
    case cursorAgent
    case pi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini CLI"
        case .opencode: return "opencode"
        case .cursorAgent: return "Cursor Agent"
        case .pi: return "pi"
        }
    }

    /// The command looked up on the login PATH.
    var executableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .gemini: return "gemini"
        case .opencode: return "opencode"
        case .cursorAgent: return "cursor-agent"
        case .pi: return "pi"
        }
    }

    /// The Dev mode adapter for this harness, or nil when Luna cannot drive it yet.
    var agentKind: AgentCLIKind? {
        switch self {
        case .claudeCode: return .claudeCode
        case .codex: return .codex
        default: return nil
        }
    }

    var isSupported: Bool { agentKind != nil }

    /// Speaks the Agent Client Protocol (`opencode acp`, `gemini --experimental-acp`), so a
    /// generic ACP adapter could drive it later. Informational only.
    var speaksACP: Bool { self == .opencode || self == .gemini }
}

extension AgentCLIKind {
    nonisolated var harnessID: HarnessID { self == .claudeCode ? .claudeCode : .codex }
}

// MARK: - Discovery

/// One installed harness, as found on the login shell PATH (or a user override).
nonisolated struct HarnessInfo: Identifiable, Equatable, Sendable {
    let id: HarnessID
    var name: String { id.displayName }
    /// Parsed from `--version` (e.g. "2.1.302"), nil if it did not answer.
    let version: String?
    /// Absolute path that will be launched.
    let executable: String
    /// True when Dev mode has an adapter for it; false = "installed but unsupported".
    var supported: Bool { id.isSupported }
    /// From a cheap local check (`claude auth status`, `codex login status`); nil = unknown.
    let signedIn: Bool?
    /// The path came from `DevSettings.cliPathOverrides`, not PATH lookup.
    let isOverride: Bool
}

/// Runs a short command and returns its exit status and stdout; nil when it cannot start or times out.
typealias HarnessCommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ timeout: TimeInterval) async -> (status: Int32, stdout: String)?

/// Finds installed coding-agent CLIs. Results are cached; pass `refresh: true` to rescan.
///
///     let harnesses = await HarnessCatalog.shared.discover()
///     let usable = harnesses.filter(\.supported)
actor HarnessCatalog {
    static let shared = HarnessCatalog()

    private let path: @Sendable () -> String
    private let environment: @Sendable () -> [String: String]
    private let overrides: @Sendable () -> [HarnessID: String]
    private let run: HarnessCommandRunner
    private var cache: [HarnessInfo]?
    private var inFlight: Task<[HarnessInfo], Never>?

    init(path: @escaping @Sendable () -> String = { LoginShellEnvironment.path() },
         environment: @escaping @Sendable () -> [String: String] = { LoginShellEnvironment.environment() },
         overrides: @escaping @Sendable () -> [HarnessID: String] = { DevSettings.storedCLIPathOverrides() },
         run: @escaping HarnessCommandRunner = HarnessCatalog.runCommand) {
        self.path = path
        self.environment = environment
        self.overrides = overrides
        self.run = run
    }

    /// Installed harnesses in `HarnessID` order (supported ones first within that order).
    func discover(refresh: Bool = false) async -> [HarnessInfo] {
        if !refresh, let cache { return cache }
        if let inFlight { return await inFlight.value }
        let path = self.path, environment = self.environment, overrides = self.overrides, run = self.run
        let task = Task.detached(priority: .utility) { () -> [HarnessInfo] in
            await Self.scan(path: path(), environment: environment(), overrides: overrides(), run: run)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        cache = result
        return result
    }

    /// The cached result without scanning (nil before the first `discover`).
    var cached: [HarnessInfo]? { cache }

    /// Info for one harness (scans if needed).
    func info(_ id: HarnessID) async -> HarnessInfo? {
        await discover().first { $0.id == id }
    }

    static func scan(path: String, environment: [String: String], overrides: [HarnessID: String],
                     run: @escaping HarnessCommandRunner) async -> [HarnessInfo] {
        var env = environment
        env["PATH"] = path
        let childEnv = env
        return await withTaskGroup(of: HarnessInfo?.self) { group in
            for id in HarnessID.allCases {
                group.addTask {
                    var executable: String?
                    var isOverride = false
                    if let custom = overrides[id], FileManager.default.isExecutableFile(atPath: custom) {
                        executable = custom
                        isOverride = true
                    } else {
                        executable = LoginShellEnvironment.locate(id.executableName, path: path)
                    }
                    guard let executable else { return nil }
                    async let versionOut = run(executable, ["--version"], childEnv, 8)
                    async let signedIn = Self.signedIn(id, executable: executable, environment: childEnv, run: run)
                    let version = await versionOut.flatMap { $0.status == 0 ? Self.parseVersion($0.stdout) : nil }
                    return HarnessInfo(id: id, version: version, executable: executable,
                                       signedIn: await signedIn, isOverride: isOverride)
                }
            }
            var found: [HarnessInfo] = []
            for await info in group { if let info { found.append(info) } }
            let order = HarnessID.allCases
            return found.sorted { order.firstIndex(of: $0.id)! < order.firstIndex(of: $1.id)! }
        }
    }

    /// Cheap, offline auth checks. Never returns or logs account details.
    static func signedIn(_ id: HarnessID, executable: String, environment: [String: String],
                         run: HarnessCommandRunner) async -> Bool? {
        switch id {
        case .claudeCode:
            guard let out = await run(executable, ["auth", "status", "--json"], environment, 8) else { return nil }
            return parseClaudeAuthStatus(out.stdout)
        case .codex:
            guard let out = await run(executable, ["login", "status"], environment, 8) else { return nil }
            return parseCodexLoginStatus(status: out.status, output: out.stdout)
        default:
            return nil
        }
    }

    /// `claude auth status --json` → `loggedIn`.
    static func parseClaudeAuthStatus(_ output: String) -> Bool? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
              let loggedIn = json["loggedIn"] as? Bool else { return nil }
        return loggedIn
    }

    /// `codex login status`: exit 0 when signed in, non-zero otherwise. Codex prints
    /// "Logged in using …" to stderr, so stdout is usually empty; the exit status decides.
    static func parseCodexLoginStatus(status: Int32, output: String) -> Bool? {
        if status == 0 { return !output.localizedCaseInsensitiveContains("not logged in") }
        return output.localizedCaseInsensitiveContains("not logged in") ? false : nil
    }

    /// First dotted version number in `--version` output ("2.1.302 (Claude Code)" → "2.1.302",
    /// "codex-cli 0.163.0" → "0.163.0"); the trimmed first line when there is none.
    static func parseVersion(_ output: String) -> String? {
        let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return nil }
        if let range = firstLine.range(of: #"\d+\.\d+(\.\d+)?([-+.][0-9A-Za-z.]+)?"#, options: .regularExpression) {
            return String(firstLine[range])
        }
        return String(firstLine.prefix(40))
    }

    /// Default runner: `Process` with stdin closed, stdout captured, killed after `timeout`.
    static let runCommand: HarnessCommandRunner = { executable, arguments, environment, timeout in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: nil); return }
                let box = OutputBox()
                let readDone = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async {
                    box.data = out.fileHandleForReading.readDataToEndOfFile()
                    readDone.signal()
                }
                let exited = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); exited.signal() }
                if exited.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    kill(process.processIdentifier, SIGKILL)
                    continuation.resume(returning: nil)
                    return
                }
                _ = readDone.wait(timeout: .now() + 1)
                continuation.resume(returning: (process.terminationStatus, String(decoding: box.data, as: UTF8.self)))
            }
        }
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }
}

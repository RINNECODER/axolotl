import Foundation

/// The environment a Terminal window would have: apps launched from Finder get a bare PATH,
/// so `claude` / `codex` (Homebrew, npm, ~/.local/bin) would not be found without this.
nonisolated enum LoginShellEnvironment {
    static let fallbackDirectories = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "~/.local/bin", "~/.claude/local", "~/.npm-global/bin", "~/.bun/bin", "~/.cargo/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]
    private static let startMarker = "__LUNA_PATH_START__"
    private static let endMarker = "__LUNA_PATH_END__"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedPATH: String?

    /// PATH from the login shell's environment, resolved once and cached; the fallback list if the shell fails.
    static func path() -> String {
        lock.lock()
        if let cachedPATH { lock.unlock(); return cachedPATH }
        lock.unlock()
        // The shell runs outside the lock so other callers are not blocked behind it.
        let resolved = merged(shellPATH: shellEnvironment()?["PATH"], home: NSHomeDirectory())
        lock.lock(); defer { lock.unlock() }
        if let cachedPATH { return cachedPATH }
        cachedPATH = resolved
        return resolved
    }

    /// Both caches are filled, so `path()` / `environment()` return without spawning a shell.
    static var isWarm: Bool {
        lock.lock(); defer { lock.unlock() }
        if cachedPATH == nil { return false }
        if case .some = cachedShellEnvironment { return true }
        return false
    }

    /// Fills both caches (blocking; call off the main actor).
    static func prewarm() {
        _ = path()
        _ = baseEnvironment()
    }

    /// `prewarm()` on a background thread. Call when Dev mode starts; never blocks the caller.
    static func prewarmAsync() async {
        await Task.detached(priority: .userInitiated) { prewarm() }.value
    }

    /// The child environment for a CLI: what a fresh Terminal window would have (the login
    /// shell's own environment, captured from a clean slate), with the login PATH and `extra`.
    ///
    /// Luna Dev is often launched from a terminal that is itself running an agent (`open`,
    /// `xcodebuild`, a Claude Code or Codex session). Inheriting that process's env leaked
    /// `CLAUDECODE` / `CLAUDE_CODE_*` (Claude then believes it is a nested child session:
    /// transcript saving off, the parent's permission mode such as bypass), `CODEX_*` sandbox
    /// markers, and the parent terminal's `TERM_PROGRAM` / `TERMINFO` (escape sequences meant
    /// for Ghostty/iTerm sent to SwiftTerm). Those are dropped here.
    static func environment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = sanitized(baseEnvironment())
        env["PATH"] = path()
        if (env["LANG"] ?? "").isEmpty, (env["LC_ALL"] ?? "").isEmpty, (env["LC_CTYPE"] ?? "").isEmpty {
            env["LANG"] = "en_US.UTF-8"
        }
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Environment for an interactive TUI on Luna's pseudo-terminal (rendered by SwiftTerm).
    /// TERM is forced: an inherited `xterm-ghostty` / `xterm-kitty` with no matching terminfo
    /// makes Ink / ratatui TUIs draw garbage.
    static func terminalEnvironment(adding extra: [String: String] = [:]) -> [String: String] {
        var env = environment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Luna"
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Variables that describe the *launching* process or terminal, never the user's setup.
    static let droppedExact: Set<String> = [
        "CLAUDECODE", "CLAUDE_PID", "CLAUDE_EFFORT", "CLAUDE_AGENT_SDK_VERSION",
        "CODEX_THREAD_ID", "CODEX_SANDBOX", "CODEX_SANDBOX_NETWORK_DISABLED", "CODEX_CI", "CODEX_MANAGED_BY_NPM",
        "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "TERM_SESSION_ID", "TERMINFO", "TERMINFO_DIRS",
        "COLORTERM", "TMUX", "TMUX_PANE", "STY", "WINDOWID", "COLUMNS", "LINES",
        "XPC_SERVICE_NAME", "XPC_FLAGS", "__CFBundleIdentifier", "OLDPWD", "PWD", "SHLVL", "_",
        "APP_SANDBOX_CONTAINER_ID",
    ]
    static let droppedPrefixes = [
        "CLAUDE_CODE_", "ITERM_", "KITTY_", "GHOSTTY_", "WEZTERM_", "VSCODE_", "ALACRITTY_",
        "HERDR_", "WT_", "LC_TERMINAL", "__LUNA",
    ]

    /// `env` minus everything in `droppedExact` / `droppedPrefixes`.
    static func sanitized(_ env: [String: String]) -> [String: String] {
        env.filter { key, _ in
            !droppedExact.contains(key) && !droppedPrefixes.contains { key.hasPrefix($0) }
        }
    }

    nonisolated(unsafe) private static var cachedShellEnvironment: [String: String]??

    /// The login shell's environment, captured once (nil if the shell failed).
    private static func shellEnvironment() -> [String: String]? {
        lock.lock()
        if case .some(let cached) = cachedShellEnvironment { lock.unlock(); return cached }
        lock.unlock()
        let captured = runLoginShellEnvironment()
        lock.lock(); cachedShellEnvironment = .some(captured); lock.unlock()
        return captured
    }

    /// The login shell's environment (cached), else this process's.
    private static func baseEnvironment() -> [String: String] {
        shellEnvironment() ?? ProcessInfo.processInfo.environment
    }

    /// Minimal seed for the login shell: launchd-provided basics only, so nothing from the
    /// process that launched Luna reaches the rc files.
    static func cleanSeed(from env: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> [String: String] {
        var seed: [String: String] = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        for key in ["USER", "LOGNAME", "SHELL", "TMPDIR", "SSH_AUTH_SOCK", "__CF_USER_TEXT_ENCODING", "LANG", "LC_ALL", "LC_CTYPE"] {
            if let v = env[key] { seed[key] = v }
        }
        return seed
    }

    /// Parses `env -0` output framed by the markers.
    static func parseEnvironment(_ output: Data) -> [String: String]? {
        guard let start = output.range(of: Data(startMarker.utf8)),
              let end = output.range(of: Data(endMarker.utf8), in: start.upperBound..<output.endIndex) else { return nil }
        var env: [String: String] = [:]
        for entry in output[start.upperBound..<end.lowerBound].split(separator: 0) {
            let text = String(decoding: entry, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard let eq = text.firstIndex(of: "="), eq != text.startIndex else { continue }
            env[String(text[..<eq])] = String(text[text.index(after: eq)...])
        }
        return env.isEmpty ? nil : env
    }

    static func runLoginShellEnvironment(shell: String = "/bin/zsh", timeout: TimeInterval = 5) -> [String: String]? {
        guard let data = runShell(shell: shell, script: "printf '\(startMarker)'; env -0; printf '\(endMarker)'",
                                  environment: cleanSeed(), timeout: timeout) else { return nil }
        return parseEnvironment(data)
    }

    /// Full path of `name` on the login PATH, or nil.
    static func locate(_ name: String, path: String? = nil) -> String? {
        for dir in (path ?? self.path()).split(separator: ":") where !dir.isEmpty {
            let candidate = (String(dir) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Shell PATH first (user's order wins), then any fallback dirs it lacks; `~` expanded.
    static func merged(shellPATH: String?, home: String) -> String {
        var seen = Set<String>()
        var out: [String] = []
        let fallback = fallbackDirectories.map { $0.hasPrefix("~") ? home + $0.dropFirst() : $0 }
        for dir in (shellPATH?.split(separator: ":").map(String.init) ?? []) + fallback where !dir.isEmpty {
            if seen.insert(dir).inserted { out.append(dir) }
        }
        return out.joined(separator: ":")
    }

    /// Runs `script` in an interactive login shell; stdout, or nil on failure / timeout.
    static func runShell(shell: String, script: String, environment: [String: String]?, timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lic", script]
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); done.signal() }
        // Read concurrently so a chatty rc file cannot fill the pipe and block the shell.
        let box = DataBox()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue(label: "luna.loginshell.read").async { box.data = out.fileHandleForReading.readDataToEndOfFile(); readDone.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        _ = readDone.wait(timeout: .now() + 1)
        return box.data
    }

    private final class DataBox: @unchecked Sendable { var data = Data() }
}

import Foundation

/// Which AI panel the user is in: today's chat panel, or Dev mode driving coding-agent CLIs.
enum AIPanelMode: String, CaseIterable, Codable {
    case general
    case dev
}

/// Dev mode spawns `claude` / `codex` from the user's machine, which the App Sandbox forbids.
/// It is only offered by an unsandboxed build (the "Axolotl Dev" target, see README).
enum DevMode {
    /// True for the Axolotl Dev target (`AXOLOTL_DEV` compilation condition).
    static var isDevBuild: Bool {
        #if AXOLOTL_DEV
        return true
        #else
        return false
        #endif
    }

    /// The sandbox sets this for every process it contains.
    nonisolated static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    /// Whether Dev mode can work in this process: CLIs can only be launched when not sandboxed.
    static var isAvailable: Bool { !isSandboxed }
}

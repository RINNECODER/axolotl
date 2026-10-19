import Foundation

/// Which AI panel the user is in: today's chat panel, or Dev mode driving coding-agent CLIs.
enum AIPanelMode: String, CaseIterable, Codable {
    case general
    case dev
}

/// Dev mode drives the `claude` / `codex` CLIs as coding agents. It is only offered by the
/// "Axolotl Dev" target (see README).
enum DevMode {
    /// True for the Axolotl Dev target (`AXOLOTL_DEV` compilation condition).
    static var isDevBuild: Bool {
        #if AXOLOTL_DEV
        return true
        #else
        return false
        #endif
    }
}

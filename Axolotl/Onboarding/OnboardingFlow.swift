import Combine
import Foundation

/// One screen of the welcome flow.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome, importData, ai, look, privacy, developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome to Axolotl"
        case .importData: return "Bring your stuff"
        case .ai: return "Choose your AI"
        case .look: return "Make it yours"
        case .privacy: return "Your data, your call"
        case .developer: return "Dev mode"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome: return "A calm, fast browser with AI built in. Let's set up a few things — skip anything you like."
        case .importData: return "Import bookmarks and history in one click. Passwords come in from a CSV or 1Password export."
        case .ai: return "Sign in with ChatGPT, add an API key, or use a local Ollama model."
        case .look: return "Pick a layout, glass or solid surfaces, and a start page wallpaper."
        case .privacy: return "Everything here is off unless you turn it on."
        case .developer: return "Coding-agent CLIs Axolotl found on this Mac, and the MCP bridge that lets agents drive Axolotl."
        }
    }

    var symbol: String {
        switch self {
        case .welcome: return "moon.stars.fill"
        case .importData: return "square.and.arrow.down.on.square"
        case .ai: return "sparkles"
        case .look: return "paintbrush.pointed"
        case .privacy: return "hand.raised.fill"
        case .developer: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// The steps this build shows, in order. Dev mode only exists in Axolotl Dev.
    static func steps(isDevBuild: Bool) -> [OnboardingStep] {
        allCases.filter { $0 != .developer || isDevBuild }
    }
}

/// The welcome flow's state machine: which step is showing, moving between steps, and the
/// seen flag (set on finish or skip).
final class OnboardingFlow: ObservableObject {
    let steps: [OnboardingStep]
    @Published private(set) var index: Int
    @Published private(set) var isFinished = false

    private let defaults: UserDefaults

    nonisolated deinit {}

    init(isDevBuild: Bool = DevMode.isDevBuild, startAt: Int = 0, defaults: UserDefaults = .standard) {
        steps = OnboardingStep.steps(isDevBuild: isDevBuild)
        index = min(max(startAt, 0), steps.count - 1)
        self.defaults = defaults
    }

    var step: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }

    /// Next step, or finish on the last one.
    func next() {
        if isLast { finish() } else { index += 1 }
    }

    func back() {
        if index > 0 { index -= 1 }
    }

    /// Skips the current step (same as Next; every step is optional).
    func skip() { next() }

    /// Esc / "Skip setup": leave the flow now; it won't show again on launch.
    func skipAll() { finish() }

    func finish() {
        OnboardingState.markSeen(defaults)
        isFinished = true
    }
}

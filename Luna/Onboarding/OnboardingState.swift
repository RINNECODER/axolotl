import Foundation

extension Notification.Name {
    /// Posted when the welcome flow should show (Settings → General → Show Welcome Again).
    static let lunaShowOnboarding = Notification.Name("lunaShowOnboarding")
}

/// Whether the welcome flow has been seen. The onboarding UI sets `seenKey` when it finishes and
/// observes `.lunaShowOnboarding` to show itself again.
enum OnboardingState {
    static let seenKey = "luna_onboarding_seen"

    static func hasSeen(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: seenKey) }

    static func markSeen(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: seenKey) }

    /// Clears the seen flag and asks the onboarding UI to show.
    static func showAgain(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        defaults.removeObject(forKey: seenKey)
        center.post(name: .lunaShowOnboarding, object: nil)
    }
}

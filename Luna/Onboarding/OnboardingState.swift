import Foundation

extension Notification.Name {
    /// Posted when the welcome flow should show (Settings → General → Show Welcome Again, Help → Show Welcome…).
    static let lunaShowOnboarding = Notification.Name("lunaShowOnboarding")
}

/// Whether the welcome flow has been seen. The onboarding UI sets `seenKey` when it finishes and
/// observes `.lunaShowOnboarding` to show itself again.
enum OnboardingState {
    static let seenKey = "luna_onboarding_seen"
    /// Debug launch argument `-LUNA_ONBOARDING_STEP <n>`: show the flow at step n (1-based) even if seen.
    static let forcedStepKey = "LUNA_ONBOARDING_STEP"
    /// `LUNA_SKIP_ONBOARDING=1` keeps the flow from showing at launch (automation, snapshot runs).
    static let skipEnvKey = "LUNA_SKIP_ONBOARDING"

    static func hasSeen(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: seenKey) }

    static func markSeen(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: seenKey) }

    /// Clears the seen flag and asks the onboarding UI to show.
    static func showAgain(defaults: UserDefaults = .standard, center: NotificationCenter = .default) {
        defaults.removeObject(forKey: seenKey)
        center.post(name: .lunaShowOnboarding, object: nil)
    }

    /// The 1-based step forced by `-LUNA_ONBOARDING_STEP`, if any.
    static func forcedStep(_ defaults: UserDefaults = .standard) -> Int? {
        guard defaults.object(forKey: forcedStepKey) != nil else { return nil }
        let step = defaults.integer(forKey: forcedStepKey)
        return step >= 1 ? step : nil
    }

    /// What to do when the first browser window opens: nil = don't show, else the 0-based step index to open.
    /// A forced step always shows; otherwise the flow shows once, on first run, outside snapshot/automation runs.
    static func launchStep(defaults: UserDefaults = .standard,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        if let forced = forcedStep(defaults) { return forced - 1 }
        if hasSeen(defaults) { return nil }
        if environment[skipEnvKey] == "1" || environment["LUNA_SNAPSHOT_PATH"] != nil { return nil }
        return 0
    }
}

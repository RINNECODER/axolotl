import AppKit

/// Settings → Appearance → App icon. The options are the Icon Composer bundles in Axolotl/AppIcons
/// (alternates compiled into Assets.car). macOS has no alternate-icon API, so a non-default choice sets
/// the Dock icon while Axolotl runs; Finder and the app switcher keep the bundle icon.
enum AppIcon {
    static let defaultsKey = "axolotl_app_icon"
    static let defaultName = "Axolotl"
    /// Asset names, allowlisted through `CustomizationRegistry` ("appearance.appIcon").
    static let options: [(String, String)] = [("Axolotl", "Axolotl"), ("AxolotlPink", "Pink"), ("AxolotlCrescent", "Crescent")]

    static func image(_ name: String) -> NSImage? { NSImage(named: name) }

    private static var applied = defaultName
    private static var observer: NSObjectProtocol?

    /// Applies the saved choice now and whenever it changes (from Settings or an agent).
    static func start(defaults: UserDefaults = .standard) {
        apply(defaults)
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults,
                                                          queue: .main) { _ in MainActor.assumeIsolated { apply(defaults) } }
    }

    private static func apply(_ defaults: UserDefaults) {
        let name = defaults.string(forKey: defaultsKey).flatMap { n in options.first { $0.0 == n }?.0 } ?? defaultName
        guard name != applied else { return }
        applied = name
        // nil restores the bundle icon, so the default costs nothing.
        NSApp.applicationIconImage = name == defaultName ? nil : image(name)
    }
}

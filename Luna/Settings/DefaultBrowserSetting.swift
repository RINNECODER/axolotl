import AppKit
import Foundation

/// Whether Luna is the default web browser, and making it so (Settings → General).
@MainActor
protocol DefaultBrowserSetting: AnyObject {
    /// True when Luna opens both http and https links.
    var isDefault: Bool { get }
    /// Asks macOS to make Luna the default for http and https (macOS may ask the user to confirm).
    func makeDefault() async throws
}

/// The system calls behind `SystemDefaultBrowser`; tests pass a fake.
protocol DefaultBrowserAPI {
    /// The app that opens `scheme` links now.
    func handlerURL(forScheme scheme: String) -> URL?
    func setHandler(_ appURL: URL, forScheme scheme: String) async throws
}

struct WorkspaceDefaultBrowserAPI: DefaultBrowserAPI {
    func handlerURL(forScheme scheme: String) -> URL? {
        guard let probe = URL(string: "\(scheme)://example.com") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    func setHandler(_ appURL: URL, forScheme scheme: String) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
    }
}

/// The real setting, over `DefaultBrowserAPI`.
@MainActor
final class SystemDefaultBrowser: DefaultBrowserSetting {
    static let schemes = ["http", "https"]

    private let api: DefaultBrowserAPI
    private let appURL: URL

    init(api: DefaultBrowserAPI = WorkspaceDefaultBrowserAPI(), appURL: URL = Bundle.main.bundleURL) {
        self.api = api
        self.appURL = appURL
    }

    var isDefault: Bool {
        Self.schemes.allSatisfy { scheme in
            api.handlerURL(forScheme: scheme).map { $0.standardizedFileURL == appURL.standardizedFileURL } ?? false
        }
    }

    func makeDefault() async throws {
        for scheme in Self.schemes { try await api.setHandler(appURL, forScheme: scheme) }
    }
}

/// In-memory stand-in for tests and screenshot runs, so they never change the Mac's default browser.
@MainActor
final class StubDefaultBrowser: DefaultBrowserSetting {
    private(set) var isDefault: Bool
    init(isDefault: Bool = false) { self.isDefault = isDefault }
    func makeDefault() async throws { isDefault = true }
}

@MainActor
enum DefaultBrowser {
    /// `LUNA_STUB_DEFAULT_BROWSER=1` in the environment, or the launch argument
    /// `-LUNA_STUB_DEFAULT_BROWSER 1`, swaps in `StubDefaultBrowser`.
    static let stubKey = "LUNA_STUB_DEFAULT_BROWSER"

    static func isStubbed(environment: [String: String] = ProcessInfo.processInfo.environment,
                          defaults: UserDefaults = .standard) -> Bool {
        if let value = environment[stubKey] { return value == "1" || value.lowercased() == "true" }
        return defaults.bool(forKey: stubKey)
    }

    static let shared: DefaultBrowserSetting = isStubbed() ? StubDefaultBrowser() : SystemDefaultBrowser()
}

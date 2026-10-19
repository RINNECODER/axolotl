import Foundation

// MARK: - Import from other browsers: shared value types
//
// Parsers produce these plain values off the main actor; `BrowserImporter`
// merges them into an Axolotl profile (workspace folders + history).

/// A browser Axolotl knows how to import from.
nonisolated enum BrowserKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case chrome, brave, edge, vivaldi, arc, firefox, safari

    var id: String { rawValue }

    enum Engine { case chromium, firefox, safari }

    var engine: Engine {
        switch self {
        case .chrome, .brave, .edge, .vivaldi, .arc: return .chromium
        case .firefox: return .firefox
        case .safari: return .safari
        }
    }

    var displayName: String {
        switch self {
        case .chrome: return "Google Chrome"
        case .brave: return "Brave"
        case .edge: return "Microsoft Edge"
        case .vivaldi: return "Vivaldi"
        case .arc: return "Arc"
        case .firefox: return "Firefox"
        case .safari: return "Safari"
        }
    }

    /// Short name for folder titles ("Imported from Chrome").
    var shortName: String {
        switch self {
        case .chrome: return "Chrome"
        case .edge: return "Edge"
        default: return displayName
        }
    }

    var bundleIdentifiers: [String] {
        switch self {
        case .chrome: return ["com.google.Chrome"]
        case .brave: return ["com.brave.Browser"]
        case .edge: return ["com.microsoft.edgemac"]
        case .vivaldi: return ["com.vivaldi.Vivaldi"]
        case .arc: return ["company.thebrowser.Browser"]
        case .firefox: return ["org.mozilla.firefox"]
        case .safari: return ["com.apple.Safari"]
        }
    }

    /// The browser's data folder, relative to the user's home directory.
    var dataFolderPath: String {
        switch self {
        case .chrome: return "Library/Application Support/Google/Chrome"
        case .brave: return "Library/Application Support/BraveSoftware/Brave-Browser"
        case .edge: return "Library/Application Support/Microsoft Edge"
        case .vivaldi: return "Library/Application Support/Vivaldi"
        case .arc: return "Library/Application Support/Arc/User Data"
        case .firefox: return "Library/Application Support/Firefox"
        case .safari: return "Library/Safari"
        }
    }

    /// Guided steps for exporting saved passwords as CSV (Axolotl never reads
    /// another browser's password store directly).
    var passwordExportSteps: String {
        switch self {
        case .chrome, .brave, .edge, .vivaldi, .arc:
            let scheme: String
            switch self {
            case .brave: scheme = "brave://password-manager/settings"
            case .edge: scheme = "edge://settings/passwords"
            case .vivaldi: scheme = "vivaldi://password-manager/settings"
            case .arc: scheme = "arc://settings/passwords"
            default: scheme = "chrome://password-manager/settings"
            }
            return "In \(displayName), open \(scheme) (Settings → Passwords), choose Export passwords, then pick the CSV here."
        case .firefox:
            return "In Firefox, open about:logins, click ••• → Export Passwords, then pick the CSV here."
        case .safari:
            return "Open the Passwords app, choose File → Export All Passwords, then pick the CSV here."
        }
    }
}

/// One profile inside another browser ("Default", "Profile 1", a Firefox profile folder).
nonisolated struct SourceProfile: Identifiable, Hashable, Codable, Sendable {
    /// Folder path relative to the browser's data folder.
    var id: String
    var name: String
}

nonisolated struct DetectedBrowser: Identifiable, Equatable, Sendable {
    var kind: BrowserKind
    /// Where the browser keeps its data (may be unreadable until access is granted).
    var dataFolder: URL
    /// The installed .app, for its icon.
    var appURL: URL?
    /// Known profiles; empty when the data folder can't be read yet.
    var profiles: [SourceProfile]

    var id: String { kind.rawValue }
}

/// A bookmark tree node, independent of the source format.
nonisolated indirect enum ImportedBookmark: Equatable, Sendable {
    case link(title: String, url: URL)
    case folder(name: String, children: [ImportedBookmark])

    var linkCount: Int {
        switch self {
        case .link: return 1
        case .folder(_, let children): return children.reduce(0) { $0 + $1.linkCount }
        }
    }
}

nonisolated struct ImportedVisit: Equatable, Sendable {
    var url: String
    var title: String
    var date: Date
}

nonisolated enum ImportDataType: String, Codable, CaseIterable, Identifiable, Sendable {
    case bookmarks, history, passwords, cookies, extensions, autofill
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bookmarks: return "Bookmarks"
        case .history: return "History"
        case .passwords: return "Passwords"
        case .cookies: return "Sign-ins (cookies)"
        case .extensions: return "Extensions"
        case .autofill: return "Autofill addresses"
        }
    }

    /// "1,204 bookmarks", "1 history entry".
    func countText(_ n: Int) -> String {
        let (one, many): (String, String)
        switch self {
        case .bookmarks: (one, many) = ("bookmark", "bookmarks")
        case .history: (one, many) = ("history entry", "history entries")
        case .passwords: (one, many) = ("password", "passwords")
        case .cookies: (one, many) = ("cookie", "cookies")
        case .extensions: (one, many) = ("extension", "extensions")
        case .autofill: (one, many) = ("address", "addresses")
        }
        return "\(n.formatted()) \(n == 1 ? one : many)"
    }

    /// Everything a browser engine can bring over.
    static func supported(by engine: BrowserKind.Engine) -> Set<ImportDataType> {
        switch engine {
        case .chromium: return Set(allCases)
        case .firefox: return [.bookmarks, .history]
        case .safari: return [.bookmarks]
        }
    }
}

nonisolated enum ImportError: LocalizedError, Equatable {
    case missingFile(String)
    case unreadable(String)
    case needsFullDiskAccess

    var errorDescription: String? {
        switch self {
        case .missingFile(let name): return "\(name) wasn't found in that profile."
        case .unreadable(let name): return "Axolotl couldn't read \(name)."
        case .needsFullDiskAccess: return "macOS protects Safari's data. Export your bookmarks from Safari instead."
        }
    }
}

/// Only keep pages a browser can open again.
nonisolated func importableURL(_ string: String) -> URL? {
    guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host?.isEmpty == false else { return nil }
    return url
}

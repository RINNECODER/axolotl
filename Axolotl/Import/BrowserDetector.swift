import AppKit
import Foundation

/// Finds installed browsers and their profiles. Detection only checks whether
/// folders exist and reads profile *names* (Chromium `Local State`, Firefox
/// `profiles.ini`); it never opens bookmarks, history or passwords.
nonisolated struct BrowserDetector {
    var home: URL
    /// Maps a bundle id to its installed .app; injectable for tests.
    var appLocator: (String) -> URL?
    var fileManager: FileManager = .default

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         appLocator: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
        self.home = home
        self.appLocator = appLocator
    }

    /// The browser to offer first: the system default, else the most recently used, else the first found.
    static func preferred(_ browsers: [DetectedBrowser], defaultBundleID: String?,
                          lastUsed: (DetectedBrowser) -> Date?) -> BrowserKind? {
        if let id = defaultBundleID, let b = browsers.first(where: { $0.kind.bundleIdentifiers.contains(id) }) { return b.kind }
        return browsers.max { (lastUsed($0) ?? .distantPast) < (lastUsed($1) ?? .distantPast) }?.kind
    }

    /// The app that opens web links (may be Axolotl itself).
    static var defaultBrowserBundleID: String? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// When the browser last ran: Chromium rewrites `Local State` on every launch. Only file dates are read.
    static func lastUsed(_ b: DetectedBrowser) -> Date? {
        [b.dataFolder.appendingPathComponent("Local State"), b.dataFolder].lazy.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }.first
    }

    func dataFolder(for kind: BrowserKind) -> URL {
        home.appendingPathComponent(kind.dataFolderPath, isDirectory: true)
    }

    /// Browsers whose app is installed or whose data folder exists.
    func detect() -> [DetectedBrowser] {
        BrowserKind.allCases.compactMap { kind in
            let folder = dataFolder(for: kind)
            let app = kind.bundleIdentifiers.lazy.compactMap(appLocator).first
            let folderExists = fileManager.fileExists(atPath: folder.path)
            guard app != nil || folderExists else { return nil }
            return DetectedBrowser(kind: kind, dataFolder: folder, appURL: app,
                                   profiles: profiles(for: kind, in: folder))
        }
    }

    /// Profiles in a browser's data folder (empty when it can't be read).
    func profiles(for kind: BrowserKind, in folder: URL) -> [SourceProfile] {
        switch kind.engine {
        case .chromium: return Self.chromiumProfiles(in: folder, fileManager: fileManager)
        case .firefox: return Self.firefoxProfiles(in: folder)
        case .safari:
            return fileManager.fileExists(atPath: folder.path) ? [SourceProfile(id: "", name: "Safari")] : []
        }
    }

    // MARK: Chromium

    static func chromiumProfiles(in folder: URL, fileManager: FileManager = .default) -> [SourceProfile] {
        var result: [SourceProfile] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent("Local State")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (dir, value) in cache {
                let name = ((value as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? dir
                guard fileManager.fileExists(atPath: folder.appendingPathComponent(dir).path) else { continue }
                result.append(SourceProfile(id: dir, name: name))
            }
        }
        if result.isEmpty, fileManager.fileExists(atPath: folder.appendingPathComponent("Default").path) {
            result.append(SourceProfile(id: "Default", name: "Default"))
        }
        // Default first, then "Profile 1", "Profile 2"… in numeric order.
        return result.sorted { a, b in
            if (a.id == "Default") != (b.id == "Default") { return a.id == "Default" }
            return a.id.localizedStandardCompare(b.id) == .orderedAscending
        }
    }

    // MARK: Firefox

    static func firefoxProfiles(in folder: URL) -> [SourceProfile] {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("profiles.ini"), encoding: .utf8) else { return [] }
        var result: [SourceProfile] = []
        var defaultPath: String?
        for section in parseINI(text) {
            if section.name.hasPrefix("Install"), let d = section.values["Default"] { defaultPath = d }
            guard section.name.hasPrefix("Profile"), let path = section.values["Path"] else { continue }
            let relative = section.values["IsRelative"] != "0"
            // Absolute profile paths outside the data folder aren't supported (sandbox access is per folder).
            guard relative else { continue }
            if section.values["Default"] == "1", defaultPath == nil { defaultPath = path }
            result.append(SourceProfile(id: path, name: section.values["Name"] ?? path))
        }
        if let defaultPath, let i = result.firstIndex(where: { $0.id == defaultPath }) {
            result.insert(result.remove(at: i), at: 0)
        }
        return result
    }

    struct INISection { var name: String; var values: [String: String] }

    static func parseINI(_ text: String) -> [INISection] {
        var sections: [INISection] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                sections.append(INISection(name: String(line.dropFirst().dropLast()), values: [:]))
            } else if let eq = line.firstIndex(of: "="), !sections.isEmpty {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                sections[sections.count - 1].values[key] = value
            }
        }
        return sections
    }
}

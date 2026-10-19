import Foundation

/// Finds installed extensions in a Chromium profile and decides which Axolotl can
/// take. The actual load (WKWebExtension) happens through `ExtensionLibrary`.
nonisolated enum ChromiumExtensionImport {
    struct Candidate: Equatable, Sendable {
        var id: String
        var name: String
        /// The versioned folder holding manifest.json.
        var folder: URL
        var version = ""
        var icon: URL?
    }

    /// Component/default extensions that ship with Chrome/Brave; never user content.
    static let componentIDs: Set<String> = [
        "nmmhkkegccagdldgiimedpiccmgmieda", // Chrome web store payments
        "mhjfbmdgcfjbbpaeojofohoefgiehjai", // Chrome PDF viewer
        "cmpscnkmbkngkbmfeahkfkeknpjlmdod", // Brave Webtorrent
        "mnojpmjdmbbfmejpflffifhffcmidifd", // Brave rewards
        "oofiananboodjbbmdelgdommihjbkfag", // Brave ads notifier
        "bfdgpgibhagkpdlnjonhkabjvikgddem", // Brave crypto wallet
        "jidkidbbcafjabdphckchenhfomhnfma", // Brave sync (varies)
    ]

    /// A manifest Axolotl should import: not a theme, not a component, not a uBlock Origin Lite clone.
    static func shouldImport(manifest: [String: Any], id: String) -> Bool {
        !componentIDs.contains(id) && unsupportedReason(manifest: manifest) == nil
    }

    /// Why a user extension can't come over, shown in the import picker; nil if it can.
    static func unsupportedReason(manifest: [String: Any]) -> String? {
        if manifest["theme"] != nil { return "Themes aren't supported" } // themes aren't web extensions
        let name = (manifest["name"] as? String ?? "").lowercased()
        if name.contains("ublock origin lite") { return "Built into Axolotl" } // duplicates the built-in
        return nil
    }

    /// The newest version folder of each importable extension in the profile.
    static func candidates(profileFolder: URL) -> [Candidate] {
        scan(profileFolder: profileFolder).filter { $0.unsupported == nil }.map(\.candidate)
    }

    /// Every user extension in the profile (components left out), with why it can't be imported.
    static func scan(profileFolder: URL) -> [(candidate: Candidate, unsupported: String?)] {
        let fm = FileManager.default
        let root = profileFolder.appendingPathComponent("Extensions", isDirectory: true)
        guard let ids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(candidate: Candidate, unsupported: String?)] = []
        for idFolder in ids {
            let id = idFolder.lastPathComponent
            guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil, !componentIDs.contains(id) else { continue }
            let versions = (try? fm.contentsOfDirectory(at: idFolder, includingPropertiesForKeys: nil)) ?? []
            // Highest version folder wins.
            guard let version = versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }).last,
                  let data = try? Data(contentsOf: version.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let icons = manifest["icons"] as? [String: String] ?? [:]
            let icon = icons.max { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }.map { version.appendingPathComponent($0.value) }
            let c = Candidate(id: id, name: displayName(manifest, folder: version) ?? id, folder: version,
                              version: manifest["version"] as? String ?? "", icon: icon)
            out.append((c, unsupportedReason(manifest: manifest)))
        }
        return out.sorted { $0.candidate.name.localizedCaseInsensitiveCompare($1.candidate.name) == .orderedAscending }
    }

    /// The manifest name, resolving "__MSG_key__" from the default locale's messages.json.
    private static func displayName(_ manifest: [String: Any], folder: URL) -> String? {
        guard let name = manifest["name"] as? String else { return nil }
        guard name.hasPrefix("__MSG_"), name.hasSuffix("__"), let locale = manifest["default_locale"] as? String,
              let data = try? Data(contentsOf: folder.appendingPathComponent("_locales/\(locale)/messages.json")),
              let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return name }
        let key = String(name.dropFirst(6).dropLast(2))
        // Message keys are case-insensitive.
        let entry = messages.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value as? [String: Any]
        return entry?["message"] as? String ?? name
    }
}

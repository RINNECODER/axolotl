import Foundation

/// Finds installed extensions in a Chromium profile and decides which Axolotl can
/// take. The actual load (WKWebExtension) happens through `ExtensionLibrary`.
nonisolated enum ChromiumExtensionImport {
    struct Candidate: Equatable, Sendable {
        var id: String
        var name: String
        /// The versioned folder holding manifest.json.
        var folder: URL
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
        if componentIDs.contains(id) { return false }
        if manifest["theme"] != nil { return false } // themes aren't web extensions
        let name = (manifest["name"] as? String ?? "").lowercased()
        if name.contains("ublock origin lite") { return false } // duplicates the built-in
        // Chromium marks its own built-ins; skip anything claiming a signing key + policy install.
        return true
    }

    /// The newest version folder of each importable extension in the profile.
    static func candidates(profileFolder: URL) -> [Candidate] {
        let fm = FileManager.default
        let root = profileFolder.appendingPathComponent("Extensions", isDirectory: true)
        guard let ids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [Candidate] = []
        for idFolder in ids {
            let id = idFolder.lastPathComponent
            guard id.range(of: "^[a-p]{32}$", options: .regularExpression) != nil else { continue }
            let versions = (try? fm.contentsOfDirectory(at: idFolder, includingPropertiesForKeys: nil)) ?? []
            // Highest version folder wins.
            guard let version = versions.sorted(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }).last,
                  let data = try? Data(contentsOf: version.appendingPathComponent("manifest.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  shouldImport(manifest: manifest, id: id) else { continue }
            out.append(Candidate(id: id, name: manifest["name"] as? String ?? id, folder: version))
        }
        return out
    }
}

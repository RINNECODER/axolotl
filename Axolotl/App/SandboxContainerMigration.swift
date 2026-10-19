import Foundation

/// One-time copy of a sandboxed Axolotl install (0.1.4 and earlier) out of its container into
/// the unsandboxed locations: settings, `Application Support/Axolotl`, WebKit website data
/// (every profile's data store) and HTTP storage.
///
/// Like `LegacyLunaMigration` it only copies: the container is never changed or deleted, and
/// nothing Axolotl already has is overwritten. Runs first thing at launch, before any store or
/// WebKit data store opens, and only once (`doneKey`); the container is never read again.
nonisolated struct SandboxContainerMigration {
    static let doneKey = "axolotl_sandbox_container_migrated"

    let bundleID: String
    /// `~/Library/Containers/<bundle id>/Data/Library`.
    let container: URL
    /// `~/Library`.
    let library: URL
    let defaults: UserDefaults

    /// Container `Library` item → unsandboxed `Library` item (Caches are rebuilt, so skipped).
    /// Inside a container WebKit drops the bundle id folder (see `LegacyLunaMigration.libraryItems`).
    static func libraryItems(bundleID: String) -> [(old: String, new: String)] {
        [("Application Support/Axolotl", "Application Support/Axolotl"),
         ("WebKit", "WebKit/\(bundleID)"),
         ("HTTPStorages/\(bundleID)", "HTTPStorages/\(bundleID)"),
         ("HTTPStorages/\(bundleID).binarycookies", "HTTPStorages/\(bundleID).binarycookies")]
    }

    static func live() -> SandboxContainerMigration? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return SandboxContainerMigration(bundleID: id, container: library.appendingPathComponent("Containers/\(id)/Data/Library", isDirectory: true),
                                         library: library, defaults: .standard)
    }

    /// Call first thing at launch, before `LegacyLunaMigration.runAtLaunch()`. Never in unit tests.
    static func runAtLaunch() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        live()?.run()
    }

    func run() {
        guard !defaults.bool(forKey: Self.doneKey) else { return }
        if FileManager.default.fileExists(atPath: container.path) {
            importDefaults()
            for item in Self.libraryItems(bundleID: bundleID) {
                LegacyLunaMigration.copyMissing(container.appendingPathComponent(item.old), to: library.appendingPathComponent(item.new))
            }
            // The sandboxed app already copied any Luna install into its container, so that copy wins.
            defaults.set(true, forKey: LegacyLunaMigration.doneKey)
        }
        defaults.set(true, forKey: Self.doneKey)
    }

    /// The container's settings, without overwriting any key already set.
    func importDefaults() {
        let plist = container.appendingPathComponent("Preferences/\(bundleID).plist")
        guard let old = NSDictionary(contentsOf: plist) as? [String: Any] else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }
}

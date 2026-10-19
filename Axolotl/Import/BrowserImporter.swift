import Foundation

/// Runs imports: reads a source profile off the main thread, then merges the
/// result into an Axolotl profile. Remembers each source so re-imports (and
/// "Keep in sync" on launch) are incremental and never duplicate.
enum BrowserImporter {
    struct Summary: Equatable {
        /// nil = that data type wasn't imported.
        var bookmarks: Int?
        var history: Int?
        var errors: [String] = []

        var total: Int { (bookmarks ?? 0) + (history ?? 0) }

        var parts: [String] {
            [bookmarks.map(ImportDataType.bookmarks.countText), history.map(ImportDataType.history.countText)].compactMap { $0 }
        }

        var text: String {
            parts.isEmpty ? "Nothing new to import." : "Imported " + parts.joined(separator: ", ") + "."
        }
    }

    /// What one "Import everything" brought over per type, and a one-line reason
    /// for each requested type that didn't (never a raw error).
    struct Report: Equatable {
        var counts: [ImportDataType: Int] = [:]
        var skipped: [ImportDataType: String] = [:]

        var text: String {
            let parts = ImportDataType.allCases.compactMap { t in counts[t].flatMap { $0 > 0 ? t.countText($0) : nil } }
            return parts.isEmpty ? "Everything is already up to date." : "Imported " + parts.formatted(.list(type: .and)) + "."
        }

        mutating func add(_ s: Summary, requested: Set<ImportDataType>) {
            for (t, n) in [(ImportDataType.bookmarks, s.bookmarks), (.history, s.history)] where requested.contains(t) {
                if let n { counts[t] = n } else { skipped[t] = "Couldn't read them from this profile." }
            }
        }

        mutating func add(_ s: SecureSummary, requested: Set<ImportDataType>, browserName: String) {
            let found: [ImportDataType: Int?] = [.cookies: s.cookies, .passwords: s.passwords,
                                                 .extensions: s.extensionsImported, .autofill: s.addresses]
            for (t, n) in found where requested.contains(t) {
                if let n { counts[t] = n; continue }
                if s.keychainUnavailable, t == .cookies || t == .passwords {
                    skipped[t] = "Keychain access to \(browserName) Safe Storage wasn't allowed."
                } else if t == .passwords, s.vaultLocked {
                    skipped[t] = "The Axolotl password vault stayed locked."
                } else if t == .extensions, s.extensionsDeclined {
                    skipped[t] = "You chose not to add them."
                } else {
                    skipped[t] = "Couldn't read them from this profile."
                }
            }
            if requested.contains(.extensions), s.extensionsFailed > 0 {
                skipped[.extensions] = "\(s.extensionsFailed.formatted()) can't run in Axolotl yet."
            }
        }
    }

    /// One remembered source → Axolotl profile pairing.
    struct Source: Codable, Equatable {
        var kind: BrowserKind
        var profile: SourceProfile
        var axolotlProfileId: UUID
        /// The workspace folder an older import created; moved to the bookmark store on launch.
        var folderId: UUID?
        var lastVisit: Date?
        var keepInSync = false
        /// Bookmark keys imported from this source so far; sync skips them so deletions stick.
        var importedKeys: Set<String>?

        func matches(_ kind: BrowserKind, _ profileId: String, _ axolotl: UUID) -> Bool {
            self.kind == kind && profile.id == profileId && axolotlProfileId == axolotl
        }
    }

    static let sourcesKey = "browserImport.sources"

    static var sources: [Source] {
        get {
            guard let data = UserDefaults.standard.data(forKey: sourcesKey) else { return [] }
            return (try? JSONDecoder().decode([Source].self, from: data)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: sourcesKey) }
    }

    static func source(_ kind: BrowserKind, _ profile: SourceProfile, _ axolotl: UUID) -> Source {
        sources.first { $0.matches(kind, profile.id, axolotl) } ?? Source(kind: kind, profile: profile, axolotlProfileId: axolotl)
    }

    /// Forgets every source that imports into a deleted Axolotl profile.
    static func forgetSources(axolotlProfileId: UUID) { sources.removeAll { $0.axolotlProfileId == axolotlProfileId } }

    static func save(_ source: Source) {
        var all = sources
        if let i = all.firstIndex(where: { $0.matches(source.kind, source.profile.id, source.axolotlProfileId) }) {
            all[i] = source
        } else {
            all.append(source)
        }
        sources = all
    }

    // MARK: Reading (off the main actor)

    nonisolated struct ReadResult: Sendable {
        var bookmarks: [ImportedBookmark]?
        /// Visits handed to the history sink (nil when history wasn't read), and how many it added.
        var visitsRead: Int?
        var visitsAdded = 0
        var newestVisit: Date?
        var errors: [String] = []
    }

    /// - Parameter dataFolder: the browser's data folder (already accessible).
    nonisolated static func read(kind: BrowserKind, dataFolder: URL, profile: SourceProfile,
                                 types: Set<ImportDataType>, since: Date?,
                                 addVisits: ([ImportedVisit]) -> Int = { _ in 0 }) -> ReadResult {
        var result = ReadResult()
        let folder = profile.id.isEmpty ? dataFolder : dataFolder.appendingPathComponent(profile.id, isDirectory: true)
        if types.contains(.bookmarks) {
            do {
                switch kind.engine {
                case .chromium: result.bookmarks = try ChromiumImporter.bookmarks(profileFolder: folder)
                case .firefox: result.bookmarks = try FirefoxImporter.bookmarks(profileFolder: folder)
                case .safari: result.bookmarks = try SafariImporter.bookmarks(safariFolder: folder)
                }
            } catch {
                result.errors.append("Bookmarks: \(error.localizedDescription)")
            }
        }
        if types.contains(.history), kind.engine != .safari {
            result.visitsRead = 0
            // Each batch is stored as it's read, so a huge history never sits in memory at once.
            func sink(_ batch: [ImportedVisit]) {
                result.visitsRead! += batch.count
                result.visitsAdded += addVisits(batch)
                if let newest = batch.map(\.date).max() { result.newestVisit = max(newest, result.newestVisit ?? newest) }
            }
            do {
                switch kind.engine {
                case .chromium: try ChromiumImporter.history(profileFolder: folder, since: since, onBatch: sink)
                case .firefox: try FirefoxImporter.history(profileFolder: folder, since: since, onBatch: sink)
                case .safari: break
                }
            } catch {
                result.errors.append("History: \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: Applying (main actor)

    /// Adds bookmarks to the profile's bookmark store (bookmarks bar / axolotl://bookmarks),
    /// never to workspace tabs. Like Chrome's first import, they go straight onto an
    /// empty bar; otherwise into a "folderName" folder on the bar. Returns how many were added.
    static func applyBookmarks(_ bookmarks: [ImportedBookmark], folderName: String, axolotlProfileId: UUID,
                               store: BookmarkStore? = nil) -> Int {
        let store = store ?? BookmarkStore.forProfile(axolotlProfileId)
        let tree = store.children(of: nil).isEmpty ? bookmarks : [.folder(name: folderName, children: bookmarks)]
        return store.addImported(tree)
    }

    /// One-time cleanup: moves workspace folders that older imports created (pinned
    /// tabs) into the bookmark store, then removes them and their tabs.
    static func migrateLegacyImportFolders() {
        for var src in sources {
            guard let folderId = src.folderId else { continue }
            let name = folderName(src.kind, src.profile, profileCount: 1)
            var moved: [ImportedBookmark]?
            if let owner = WorkspaceOwnership.owner(for: src.axolotlProfileId) {
                owner.applyChange("Move Imported Bookmarks") { ws in moved = ws.takeImportedFolder(folderId) }
                owner.flush()
            } else {
                let persistence = WorkspacePersistence.forProfile(src.axolotlProfileId)
                if var ws = persistence.load() {
                    moved = ws.takeImportedFolder(folderId)
                    if moved != nil { persistence.save(ws); persistence.drain() }
                }
            }
            if let moved { BookmarkStore.forProfile(src.axolotlProfileId).addImported([.folder(name: name, children: moved)]) }
            src.folderId = nil
            save(src)
        }
    }

    static func folderName(_ kind: BrowserKind, _ profile: SourceProfile, profileCount: Int) -> String {
        let base = "Imported from \(kind.shortName)"
        return profileCount > 1 && !profile.name.isEmpty ? "\(base) (\(profile.name))" : base
    }

    /// Full import of one source profile. Access to `dataFolder` must already be active.
    static func run(kind: BrowserKind, dataFolder: URL, profile: SourceProfile, profileCount: Int,
                    types: Set<ImportDataType>, axolotlProfileId: UUID, keepInSync: Bool? = nil,
                    incremental: Bool = false) async -> Summary {
        migrateLegacyImportFolders()
        var source = source(kind, profile, axolotlProfileId)
        let since = incremental ? source.lastVisit : nil
        let history = ProfileStoreRegistry.stores(for: axolotlProfileId).history
        let read = await Task.detached(priority: .userInitiated) {
            BrowserImporter.read(kind: kind, dataFolder: dataFolder, profile: profile, types: types, since: since,
                                 addVisits: history.importVisits)
        }.value
        var summary = Summary(errors: read.errors)
        if let bookmarks = read.bookmarks {
            let fresh = incremental ? ImportedBookmark.removing(source.importedKeys ?? [], from: bookmarks) : bookmarks
            source.importedKeys = (source.importedKeys ?? []).union(ImportedBookmark.keys(bookmarks))
            summary.bookmarks = applyBookmarks(fresh, folderName: folderName(kind, profile, profileCount: profileCount),
                                               axolotlProfileId: axolotlProfileId)
        }
        if read.visitsRead != nil {
            summary.history = read.visitsAdded
            if let newest = read.newestVisit { source.lastVisit = max(newest, source.lastVisit ?? newest) }
        }
        if let keepInSync { source.keepInSync = keepInSync }
        save(source)
        return summary
    }

    // MARK: Keep in sync

    private static var launchSyncScheduled = false

    /// Re-imports bookmarks and new history for every source marked "Keep in sync",
    /// using the stored folder grants (no prompts). Runs once, shortly after launch.
    static func scheduleLaunchSync(after delay: TimeInterval = 5) {
        guard !launchSyncScheduled, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        launchSyncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            migrateLegacyImportFolders()
            Task { await syncAll() }
        }
    }

    static func syncAll() async {
        let detector = BrowserDetector()
        for src in sources where src.keepInSync {
            guard ProfileManager.shared.profiles.contains(where: { $0.id == src.axolotlProfileId }),
                  let folder = BrowserAccess.resolve(src.kind) else { continue }
            defer { folder.stopAccessingSecurityScopedResource() }
            let count = detector.profiles(for: src.kind, in: folder).count
            _ = await run(kind: src.kind, dataFolder: folder, profile: src.profile, profileCount: count,
                          types: [.bookmarks, .history], axolotlProfileId: src.axolotlProfileId, incremental: true)
        }
    }

    // MARK: Debug fixtures

    #if DEBUG
    /// AXOLOTL_IMPORT_FIXTURE_HOME=<folder inside Axolotl's container> makes detection
    /// look there instead of the real home folder, skips the access panel, and
    /// imports into a throwaway profile so the flow can be demoed on synthetic data.
    static var fixtureHome: URL? {
        ProcessInfo.processInfo.environment["AXOLOTL_IMPORT_FIXTURE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static let fixtureProfileId = UUID(uuidString: "00000000-0000-0000-0000-00000000F1F1")!
    #endif
}

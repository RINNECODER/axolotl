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

        var text: String {
            var parts: [String] = []
            if let b = bookmarks { parts.append("\(b.formatted()) bookmark\(b == 1 ? "" : "s")") }
            if let h = history { parts.append("\(h.formatted()) history entr\(h == 1 ? "y" : "ies")") }
            if parts.isEmpty { return "Nothing new to import." }
            return "Imported " + parts.joined(separator: ", ") + "."
        }
    }

    /// One remembered source → Axolotl profile pairing.
    struct Source: Codable, Equatable {
        var kind: BrowserKind
        var profile: SourceProfile
        var axolotlProfileId: UUID
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

    /// Merges into the profile's workspace: the open window's store when there
    /// is one (so it's undoable and saved normally), otherwise the file on disk.
    static func applyBookmarks(_ bookmarks: [ImportedBookmark], folderName: String, existingFolderId: UUID?,
                               axolotlProfileId: UUID) -> Workspace.BookmarkMergeResult {
        var result = Workspace.BookmarkMergeResult(folderId: nil, added: 0)
        if let store = WorkspaceOwnership.owner(for: axolotlProfileId) {
            store.applyChange("Import Bookmarks") { ws in
                result = ws.mergeImportedBookmarks(bookmarks, folderName: folderName, existingFolderId: existingFolderId)
            }
            store.flush()
        } else {
            let persistence = WorkspacePersistence.forProfile(axolotlProfileId)
            var ws = persistence.load() ?? Workspace()
            ws.repair()
            result = ws.mergeImportedBookmarks(bookmarks, folderName: folderName, existingFolderId: existingFolderId)
            if result.added > 0 {
                persistence.save(ws)
                persistence.drain()
            }
        }
        return result
    }

    static func folderName(_ kind: BrowserKind, _ profile: SourceProfile, profileCount: Int) -> String {
        let base = "Imported from \(kind.shortName)"
        return profileCount > 1 && !profile.name.isEmpty ? "\(base) (\(profile.name))" : base
    }

    /// Full import of one source profile. Access to `dataFolder` must already be active.
    static func run(kind: BrowserKind, dataFolder: URL, profile: SourceProfile, profileCount: Int,
                    types: Set<ImportDataType>, axolotlProfileId: UUID, keepInSync: Bool? = nil,
                    incremental: Bool = false) async -> Summary {
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
            let r = applyBookmarks(fresh, folderName: folderName(kind, profile, profileCount: profileCount),
                                   existingFolderId: source.folderId, axolotlProfileId: axolotlProfileId)
            summary.bookmarks = r.added
            if let id = r.folderId { source.folderId = id }
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

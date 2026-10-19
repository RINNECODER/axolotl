// Luma MVP - Download manager and hub
import Foundation
import SwiftUI
import AppKit
import Combine
import WebKit
import UniformTypeIdentifiers

/// A single recent download for the hub.
struct DownloadItem: Identifiable, Codable {
    enum State: Equatable, Codable {
        case downloading
        case paused
        case finished
        case failed(String)
        case cancelled
    }

    /// How Retry / Resume continues a stopped download.
    enum RetryPlan: Equatable {
        case resume(Data)
        case restart(URL)
    }

    let id: UUID
    let url: URL
    var fileURL: URL
    let suggestedFilename: String
    let date: Date
    var state: State = .finished
    /// 0…1 while downloading; nil when the server didn't send a size.
    var fraction: Double?
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0
    /// Set after Luna Max renamed the file; used for one-click undo.
    var originalFileURL: URL?
    var isTidying = false
    /// The profile that downloaded it; private-window items are never written to disk.
    var profileId: UUID?
    var isPrivate = false
    /// WebKit resume data from a pause or a failure that can continue.
    var resumeData: Data?

    /// Paused or failed downloads continue from resume data when WebKit gave some, else start over.
    var retryPlan: RetryPlan? {
        switch state {
        case .paused, .failed: return resumeData.map(RetryPlan.resume) ?? .restart(url)
        case .cancelled: return .restart(url)
        case .downloading, .finished: return nil
        }
    }

    var displayName: String { fileURL.lastPathComponent }
    var isActive: Bool { state == .downloading }

    /// Shown in that window: private windows see only private items, others only their profile's.
    func belongs(profileId: UUID?, isPrivate: Bool) -> Bool {
        self.isPrivate == isPrivate && (self.profileId == nil || self.profileId == profileId)
    }

    init(id: UUID = UUID(), url: URL, fileURL: URL, suggestedFilename: String, date: Date = Date(), state: State = .finished,
         profileId: UUID? = nil, isPrivate: Bool = false) {
        self.profileId = profileId
        self.isPrivate = isPrivate
        self.id = id
        self.url = url
        self.fileURL = fileURL
        self.suggestedFilename = suggestedFilename
        self.date = date
        self.state = state
    }
}

/// Restarts or resumes a download in some web view of the right profile (a WebViewWrapper).
protocol DownloadResuming: AnyObject {
    var profileId: UUID { get }
    var isPrivate: Bool { get }
    func resumeDownload(from data: Data, item: UUID)
    func restartDownload(from url: URL, item: UUID)
}

/// Each profile's download list as `Luna/Profiles/<id>/downloads.json` (private items left out).
struct DownloadListStore {
    let profilesDirectory: URL

    static var standard: DownloadListStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return DownloadListStore(profilesDirectory: base.appendingPathComponent("Luna/Profiles", isDirectory: true))
    }

    func fileURL(for profile: UUID) -> URL {
        profilesDirectory.appendingPathComponent("\(profile.uuidString)/downloads.json")
    }

    /// Every profile's saved list; a download that was running when Luna quit comes back as interrupted.
    func load() -> [DownloadItem] {
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: profilesDirectory.path)) ?? []
        return dirs.compactMap(UUID.init(uuidString:)).flatMap { id -> [DownloadItem] in
            guard let data = try? Data(contentsOf: fileURL(for: id)),
                  let items = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return [] }
            return items.map { item in
                var item = item
                if item.state == .downloading { item.state = .failed("Interrupted") }
                item.isTidying = false
                return item
            }
        }
        .sorted { $0.date > $1.date }
    }

    /// Writes each listed profile's non-private items (an empty list clears the file).
    func save(_ items: [DownloadItem], profiles: Set<UUID>) {
        for profile in profiles {
            let mine = items.filter { $0.profileId == profile && !$0.isPrivate }
            let url = fileURL(for: profile)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(mine).write(to: url, options: .atomic)
        }
    }
}

/// Manages recent downloads; files are saved to ~/Downloads.
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager(store: .standard)

    @Published private(set) var recentDownloads: [DownloadItem] = [] {
        didSet { scheduleSave() }
    }
    private let store: DownloadListStore?
    /// Profiles whose file must be rewritten (loaded ones too, so removing the last item clears it).
    private var savedProfiles: Set<UUID> = []
    private var saveWork: DispatchWorkItem?
    private struct WeakResumer { weak var value: DownloadResuming? }
    private var resumers: [WeakResumer] = []
    private var ownerByItem: [UUID: WeakResumer] = [:]
    /// Bumped when a download starts or the hub is requested; the Downloads
    /// button in the key window opens its popover in response.
    @Published private(set) var presentRequest = 0
    private let maxRecent = 200
    private let fileManager = FileManager.default
    private var active: [UUID: (download: WKDownload, observation: NSKeyValueObservation)] = [:]

    var downloadsDirectory: URL {
        fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    }

    init(store: DownloadListStore?) {
        self.store = store
        guard let store else { return }
        recentDownloads = store.load()
        savedProfiles = Set(recentDownloads.compactMap(\.profileId))
    }

    /// Web view wrappers that can resume downloads after the window that started one has closed.
    func register(_ resumer: DownloadResuming) {
        resumers.removeAll { $0.value == nil }
        resumers.append(WeakResumer(value: resumer))
    }

    private func scheduleSave() {
        guard store != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        guard let store else { return }
        savedProfiles.formUnion(recentDownloads.filter { !$0.isPrivate }.compactMap(\.profileId))
        store.save(recentDownloads, profiles: savedProfiles)
    }

    /// Active downloads' combined progress (0…1), or nil when sizes are unknown.
    var activeFraction: Double? {
        let items = recentDownloads.filter(\.isActive)
        let expected = items.reduce(Int64(0)) { $0 + $1.bytesExpected }
        guard !items.isEmpty, expected > 0, items.allSatisfy({ $0.bytesExpected > 0 }) else { return nil }
        return Double(items.reduce(Int64(0)) { $0 + $1.bytesReceived }) / Double(expected)
    }

    var hasActiveDownloads: Bool { recentDownloads.contains(where: \.isActive) }

    func presentHub() { presentRequest += 1 }

    /// Starts tracking a WKDownload that is about to write to `fileURL`.
    @discardableResult
    func begin(_ download: WKDownload, url: URL, fileURL: URL, suggestedFilename: String, owner: DownloadResuming? = nil) -> UUID {
        let item = DownloadItem(url: url, fileURL: fileURL, suggestedFilename: suggestedFilename, state: .downloading,
                                profileId: owner?.profileId, isPrivate: owner?.isPrivate ?? false)
        insert(item)
        attach(download, to: item.id, owner: owner)
        presentHub()
        return item.id
    }

    /// Tracks a resumed or restarted WKDownload under its existing list item.
    func attach(_ download: WKDownload, to id: UUID, fileURL: URL? = nil, owner: DownloadResuming?) {
        if let owner { ownerByItem[id] = WeakResumer(value: owner) }
        if let i = recentDownloads.firstIndex(where: { $0.id == id }) {
            recentDownloads[i].state = .downloading
            recentDownloads[i].resumeData = nil
            if let fileURL { recentDownloads[i].fileURL = fileURL }
        }
        let observation = download.progress.observe(\.completedUnitCount, options: [.initial, .new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let expected = progress.totalUnitCount
            DispatchQueue.main.async {
                guard let self, let i = self.recentDownloads.firstIndex(where: { $0.id == id }),
                      self.recentDownloads[i].isActive else { return }
                self.recentDownloads[i].bytesReceived = received
                self.recentDownloads[i].bytesExpected = max(0, expected)
                self.recentDownloads[i].fraction = expected > 0 ? min(1, Double(received) / Double(expected)) : nil
            }
        }
        active[id] = (download, observation)
    }

    func finish(_ id: UUID) {
        active.removeValue(forKey: id)
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }) else { return }
        recentDownloads[i].state = .finished
        recentDownloads[i].fraction = 1
        if LunaMaxPrefs.isOn(LunaMaxPrefs.tidyDownloads) { tidy(id) }
    }

    /// A paused item ignores the failure WebKit reports for its own cancel.
    func fail(_ id: UUID, error: Error, resumeData: Data? = nil) {
        active.removeValue(forKey: id)
        if recentDownloads.first(where: { $0.id == id })?.state == .paused { return didPause(id, resumeData: resumeData) }
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }), recentDownloads[i].isActive else { return }
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        recentDownloads[i].state = cancelled ? .cancelled : .failed(error.localizedDescription)
        recentDownloads[i].resumeData = cancelled ? nil : resumeData
    }

    func cancel(_ id: UUID) {
        active.removeValue(forKey: id)?.download.cancel { _ in }
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }),
              recentDownloads[i].isActive || recentDownloads[i].state == .paused else { return }
        recentDownloads[i].state = .cancelled
        recentDownloads[i].resumeData = nil
    }

    /// Chrome's Pause: stops the transfer and keeps WebKit's resume data (nil when the server can't resume).
    func pause(_ id: UUID) {
        guard let entry = active.removeValue(forKey: id) else { return }
        didPause(id, resumeData: nil)
        entry.download.cancel { [weak self] data in
            DispatchQueue.main.async { self?.didPause(id, resumeData: data) }
        }
    }

    func didPause(_ id: UUID, resumeData: Data?) {
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }),
              recentDownloads[i].isActive || recentDownloads[i].state == .paused else { return }
        recentDownloads[i].state = .paused
        if let resumeData { recentDownloads[i].resumeData = resumeData }
    }

    /// Resume (paused) or Retry (failed, cancelled), in the window that started it or another of the profile.
    func resume(_ id: UUID) {
        guard let item = recentDownloads.first(where: { $0.id == id }), let plan = item.retryPlan else { return }
        resumers.removeAll { $0.value == nil }
        guard let owner = ownerByItem[id]?.value
                ?? resumers.first(where: { $0.value?.profileId == item.profileId && $0.value?.isPrivate == item.isPrivate })?.value
                ?? resumers.first(where: { $0.value?.isPrivate == item.isPrivate })?.value else { return }
        switch plan {
        case .resume(let data): owner.resumeDownload(from: data, item: id)
        case .restart(let url): owner.restartDownload(from: url, item: id)
        }
    }

    /// Saves bytes the page already has (a `data:` image) straight to Downloads.
    func save(_ data: Data, mimeType: String?, sourceURL: URL, owner: DownloadResuming? = nil) {
        let ext = mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "bin"
        let base = mimeType?.hasPrefix("image/") == true ? "image" : "download"
        var dest = downloadsDirectory.appendingPathComponent("\(base).\(ext)")
        var n = 1
        while fileManager.fileExists(atPath: dest.path) {
            dest = downloadsDirectory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try data.write(to: dest)
        } catch {
            return
        }
        insert(DownloadItem(url: sourceURL, fileURL: dest, suggestedFilename: dest.lastPathComponent,
                            profileId: owner?.profileId, isPrivate: owner?.isPrivate ?? false))
        presentHub()
    }

    private func insert(_ item: DownloadItem) {
        recentDownloads.insert(item, at: 0)
        if recentDownloads.count > maxRecent, let last = recentDownloads.lastIndex(where: { !$0.isActive && $0.state != .paused }) {
            recentDownloads.remove(at: last)
        }
    }

    /// Clears finished, failed and cancelled downloads from the list.
    func clearInactive(where matches: (DownloadItem) -> Bool = { _ in true }) {
        recentDownloads.removeAll { !$0.isActive && $0.state != .paused && matches($0) }
    }

    /// The last private window closed: forget its downloads (cancelling any still running).
    func dropPrivate() {
        for item in recentDownloads where item.isPrivate && item.isActive { cancel(item.id) }
        recentDownloads.removeAll(where: \.isPrivate)
    }

    // MARK: - Luna Max: tidy downloads

    /// Asks the model for a clearer name and renames the file in place.
    func tidy(_ id: UUID) {
        guard let index = recentDownloads.firstIndex(where: { $0.id == id }), !recentDownloads[index].isTidying else { return }
        let item = recentDownloads[index]
        recentDownloads[index].isTidying = true
        Task {
            let newName = try? await LunaMax.tidyFilename(for: item.fileURL.lastPathComponent, sourceURL: item.url)
            guard let i = recentDownloads.firstIndex(where: { $0.id == id }) else { return }
            recentDownloads[i].isTidying = false
            guard let newName, newName != item.fileURL.lastPathComponent else { return }
            if let renamed = moveFile(recentDownloads[i].fileURL, toName: newName) {
                recentDownloads[i].originalFileURL = recentDownloads[i].originalFileURL ?? recentDownloads[i].fileURL
                recentDownloads[i].fileURL = renamed
            }
        }
    }

    /// Restores the name the file was downloaded with.
    func undoTidy(_ id: UUID) {
        guard let i = recentDownloads.firstIndex(where: { $0.id == id }),
              let original = recentDownloads[i].originalFileURL,
              let restored = moveFile(recentDownloads[i].fileURL, toName: original.lastPathComponent) else { return }
        recentDownloads[i].fileURL = restored
        recentDownloads[i].originalFileURL = nil
    }

    /// Renames within the same folder, adding " (n)" if the name is taken.
    private func moveFile(_ source: URL, toName name: String) -> URL? {
        guard fileManager.fileExists(atPath: source.path) else { return nil }
        let dir = source.deletingLastPathComponent()
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while fileManager.fileExists(atPath: dest.path), dest.standardizedFileURL != source.standardizedFileURL {
            dest = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do {
            try fileManager.moveItem(at: source, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    /// Open the file in its default application.
    /// If the file was moved or deleted since downloading, drop it from the list.
    func open(_ item: DownloadItem) {
        guard fileManager.fileExists(atPath: item.fileURL.path) else {
            removeItem(id: item.id)
            return
        }
        NSWorkspace.shared.open(item.fileURL)
    }

    /// Reveal the file in Finder.
    func revealInFinder(_ item: DownloadItem) {
        guard fileManager.fileExists(atPath: item.fileURL.path) else {
            removeItem(id: item.id)
            return
        }
        NSWorkspace.shared.selectFile(item.fileURL.path, inFileViewerRootedAtPath: item.fileURL.deletingLastPathComponent().path)
    }

    /// Remove an item from the recent downloads list (does not delete the file on disk).
    func removeItem(_ item: DownloadItem) {
        DispatchQueue.main.async { [weak self] in
            self?.recentDownloads.removeAll { $0.id == item.id }
        }
    }

    /// Remove an item by id.
    func removeItem(id: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.recentDownloads.removeAll { $0.id == id }
        }
    }
}

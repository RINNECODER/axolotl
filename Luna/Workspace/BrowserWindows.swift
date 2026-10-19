import AppKit
import Foundation
import SwiftUI

/// Extra browser windows (beyond the main one) and their saved workspaces.
///
/// Each extra window has an id and its own workspace file next to the
/// profile's main `workspace.json`, and is listed in `windows.json` so it
/// reopens at launch. Closing a window yourself forgets it; quitting keeps it.
enum BrowserWindows {
    struct Record: Codable, Equatable {
        let id: UUID
        let profileId: UUID
    }

    private static var listURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Luna", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("windows.json")
    }

    static func records() -> [Record] {
        guard let data = try? Data(contentsOf: listURL) else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    private static func save(_ records: [Record]) {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: listURL, options: .atomic) }
    }

    static func register(_ record: Record) {
        var all = records()
        guard !all.contains(record) else { return }
        all.append(record)
        save(all)
    }

    /// Forgets a window the user closed, and deletes its workspace file.
    static func forget(_ record: Record) {
        save(records().filter { $0 != record })
        try? FileManager.default.removeItem(at: WorkspacePersistence.forWindow(record.id, profileId: record.profileId).fileURL)
    }

    // MARK: Reopening (⌘⇧T)

    /// The extra window closed last: off the restore list, but its workspace file is kept until
    /// another window closes or Luna quits, so ⌘⇧T can bring back its tabs and groups.
    private(set) static var lastClosed: (record: Record, at: Date)?

    private static func keepForReopen(_ record: Record) {
        if let old = lastClosed { forget(old.record) }
        save(records().filter { $0 != record })
        lastClosed = (record, Date())
    }

    /// Reopens the last closed window if it closed after `date` (the newest closed tab, if any).
    static func reopenLastClosed(ifNewerThan date: Date?) -> Bool {
        guard let last = lastClosed, last.at > (date ?? .distantPast) else { return false }
        lastClosed = nil
        open(profileId: last.record.profileId, windowId: last.record.id)
        return true
    }

    // MARK: Opening

    /// Set while the app quits, so windows closing on the way out stay saved.
    private(set) static var isTerminating = false
    private static var restored = false
    private static var openWindows: Set<NSWindow> = []

    /// Reopens the extra windows saved at last quit (once per launch).
    static func restoreSaved() {
        guard !restored else { return }
        restored = true
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            isTerminating = true
            if let last = lastClosed { forget(last.record) }
        }
        let profiles = Set(ProfileManager.shared.profiles.map(\.id))
        for record in records() {
            if profiles.contains(record.profileId) {
                open(profileId: record.profileId, windowId: record.id)
            } else {
                forget(record)
            }
        }
    }

    /// Opens a browser window for a profile. A new `windowId` creates a new
    /// saved window; `adopting` moves a tab in; `at` centers it under a point.
    /// `isPrivate` opens a private window, which is never saved or restored.
    @discardableResult
    static func open(profileId: UUID, windowId: UUID = UUID(), adopting transfer: TabTransfer? = nil,
                     at screenPoint: CGPoint? = nil, size: CGSize = CGSize(width: 1200, height: 800),
                     isPrivate: Bool = false) -> NSWindow {
        let record = Record(id: windowId, profileId: profileId)
        if !isPrivate { register(record) }
        if transfer != nil && !isPrivate { Usage.record(.newWindow) }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Programmatic NSWindows default to isReleasedWhenClosed = true, which crashes
        // under ARC when the window closes. Keep a strong reference until it closes instead.
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.title = "Luna"
        window.contentView = NSHostingView(rootView: BrowserShellView(initialProfileId: profileId, windowId: windowId,
                                                                      adopting: transfer, isPrivate: isPrivate))
        if isPrivate {
            window.appearance = NSAppearance(named: .darkAqua)
            PrivateBrowsing.track(window)
        }
        if let p = screenPoint {
            // The grabbed tab sits near the top-left of the new window, under the pointer.
            window.setFrameTopLeftPoint(NSPoint(x: p.x - 120, y: p.y + 20))
        } else {
            window.center()
        }
        openWindows.insert(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            openWindows.remove(window)
            if !isTerminating && !isPrivate { keepForReopen(record) }
        }
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

/// A tab moving between windows: its saved state, including back/forward.
struct TabTransfer {
    var tab: Tab
    /// A whole tab group moving: its other tabs, and the group whose name and color wrap them all.
    var groupTabs: [Tab] = []
    var group: Folder? = nil
}

/// Live browser windows that can take a dropped tab.
final class TabDropTargets {
    static let shared = TabDropTargets()
    private init() {}

    final class Entry {
        weak var window: NSWindow?
        let profileId: () -> UUID
        /// Takes the tab, dropped at a screen point.
        let adopt: (TabTransfer, CGPoint) -> Void
        init(window: NSWindow, profileId: @escaping () -> UUID, adopt: @escaping (TabTransfer, CGPoint) -> Void) {
            self.window = window
            self.profileId = profileId
            self.adopt = adopt
        }
    }

    private var entries: [Entry] = []

    func register(_ entry: Entry) {
        entries.removeAll { $0.window == nil || $0.window === entry.window }
        entries.append(entry)
    }

    /// The Luna window a tab dragged out of `source` would drop into: the
    /// front-most window under the point, if it's another browser window on
    /// the same profile. Nil when the source window itself is in front there.
    func target(at screenPoint: CGPoint, from source: NSWindow?) -> Entry? {
        entries.removeAll { $0.window == nil }
        guard let front = NSApp.orderedWindows.first(where: {
            $0.isVisible && !$0.isMiniaturized && $0.frame.contains(screenPoint)
        }), front !== source, let entry = entries.first(where: { $0.window === front }) else { return nil }
        if let profile = entries.first(where: { $0.window === source })?.profileId(), profile != entry.profileId() {
            return nil
        }
        return entry
    }

    /// The tab strip of that window, if the point is over it.
    func zone(at screenPoint: CGPoint, from source: NSWindow?) -> TabStripDropZone? {
        guard let zone = TabStripDropZone.zone(for: target(at: screenPoint, from: source)?.window),
              zone.stripPoint(fromScreen: screenPoint) != nil else { return nil }
        return zone
    }
}

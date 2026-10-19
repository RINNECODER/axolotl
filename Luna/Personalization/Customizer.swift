import Combine
import Foundation

/// What the personalization tools read and change for one profile.
struct PersonalizationContext {
    let profileId: UUID
    let usage: UsageStore
    let history: () -> [HistoryEvent]
    let bookmarks: BookmarkStore
    /// Nil when the profile has no open window (tab tools then refuse).
    let workspace: WorkspaceStore?
}

extension PersonalizationContext {
    /// Fills a missing title from the page titles in history (opted-in profiles only);
    /// otherwise the bookmark store names it from the domain.
    func named(_ site: CustomizationPlan.Site) -> CustomizationPlan.Site {
        guard (site.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, usage.isEnabled,
              let name = PersonalizationReport.siteName(for: site.url, history: history()) else { return site }
        return CustomizationPlan.Site(url: site.url, title: name)
    }
}

struct SettingChange: Equatable {
    let key: String
    let value: JSONValue
}

/// One line of a preview or a recorded change, for people: "Toolbar: Off → On".
struct ChangeLine: Codable, Equatable, Hashable {
    var title: String
    var from: String?
    var to: String

    var text: String { from.map { "\(title): \($0) → \(to)" } ?? "\(title): \(to)" }
}

/// Where a tab sat, to put it back on undo.
struct TabPlace: Codable, Equatable {
    var tab: UUID
    var space: UUID
    var section: String
    var folder: UUID?
    var index: Int

    init(tab: UUID, _ loc: NodeLocation) {
        self.tab = tab
        space = loc.spaceId
        section = loc.section.rawValue
        folder = loc.parentFolderId
        index = loc.index
    }

    var location: NodeLocation {
        NodeLocation(spaceId: space, section: SidebarSection(rawValue: section) ?? .today, parentFolderId: folder, index: index)
    }
}

/// How to reverse a tab or bookmark change.
enum InverseOp: Codable, Equatable {
    case removeBookmark(UUID)
    case removeTab(UUID)
    /// Ungroup the folder, then put each tab back where it was.
    case ungroup(folder: UUID, places: [TabPlace])
    /// Rebuild a split view the change broke up, where it was (runs after `ungroup`).
    case resplit(group: SplitGroup, place: TabPlace)
    case reorder(space: UUID, section: String, order: [UUID])
    case unpin(tab: UUID, place: TabPlace?, savedURL: URL?)
    case repin(tab: UUID, place: TabPlace?, favoriteIndex: Int?, savedURL: URL?)
}

/// One applied AI change, kept (last 50) so Settings → Personalization can undo it.
struct AIChange: Codable, Identifiable, Equatable {
    let id: String
    let date: Date
    /// "Luna" or the MCP client's name.
    let source: String
    let lines: [ChangeLine]
    let profileId: UUID?
    /// Settings key → exact prior state, in the order applied.
    var settingSnapshots: [String: Data] = [:]
    var settingOrder: [String] = []
    var inverse: [InverseOp] = []
    var undone = false

    var title: String { lines.count == 1 ? lines[0].text : "\(lines.count) changes" }
}

/// The recent-changes list (newest first), persisted in UserDefaults.
final class AIChangeLog: ObservableObject {
    static let shared = AIChangeLog(defaults: .standard)
    static let key = "luna_ai_changes"
    static let limit = 50

    @Published private(set) var entries: [AIChange] = []
    private let defaults: UserDefaults

    nonisolated deinit {}

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([AIChange].self, from: data) {
            entries = saved
        }
    }

    func entry(_ id: String) -> AIChange? { entries.first { $0.id == id } }

    func add(_ change: AIChange) {
        entries.insert(change, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func markUndone(_ id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].undone = true
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

/// A batch the user approves at once: settings plus bookmarks / favorites to add.
struct CustomizationPlan: Equatable {
    struct Site: Equatable {
        var url: URL
        var title: String?
    }

    var settings: [SettingChange] = []
    var bookmarks: [Site] = []
    var favorites: [Site] = []

    var isEmpty: Bool { settings.isEmpty && bookmarks.isEmpty && favorites.isEmpty }
}

/// Validates, previews, applies and undoes AI customizations. Every change an agent makes
/// to Luna goes through here, so each is typed, previewed, recorded and reversible.
final class Customizer {
    /// Swappable so tests run against a throwaway defaults suite.
    static var shared = Customizer(env: .live, log: .shared)

    let env: CustomizationEnvironment
    let log: AIChangeLog
    /// Finds a profile's stores for undo (the open window's workspace, its bookmarks).
    var resolveContext: (UUID) -> PersonalizationContext? = { LunaBrowserHosts.shared.personalization(for: $0) }

    nonisolated deinit {}

    init(env: CustomizationEnvironment, log: AIChangeLog) {
        self.env = env
        self.log = log
    }

    // MARK: Settings

    /// `[{key, value}]` from a tool call or a model reply.
    static func parseChanges(_ json: JSONValue?) throws -> [SettingChange] {
        guard case .array(let items)? = json, !items.isEmpty else {
            throw LunaToolError.invalidArguments("settings_set: 'changes' must be a non-empty list of {key, value}.")
        }
        return try items.map { item in
            guard let key = item["key"]?.stringValue, let value = item["value"], value != .null else {
                throw LunaToolError.invalidArguments("settings_set: each change needs a 'key' and a 'value'.")
            }
            return SettingChange(key: key, value: value)
        }
    }

    /// Unknown keys, wrong types, out-of-range values and duplicate keys all throw.
    func validate(_ changes: [SettingChange]) throws {
        var seen: Set<String> = []
        for change in changes {
            guard let setting = CustomizationRegistry.setting(change.key) else {
                throw LunaToolError.invalidArguments("Unknown setting '\(change.key)'. Call settings_list for the supported keys.")
            }
            guard seen.insert(change.key).inserted else {
                throw LunaToolError.invalidArguments("'\(change.key)' appears twice.")
            }
            try setting.validate(change.value)
        }
    }

    func currentValue(_ key: String) -> JSONValue? { CustomizationRegistry.setting(key)?.read(env) }

    func preview(_ plan: CustomizationPlan, bookmarks: BookmarkStore? = nil) -> [ChangeLine] {
        var lines: [ChangeLine] = plan.settings.compactMap { change in
            guard let s = CustomizationRegistry.setting(change.key) else { return nil }
            return ChangeLine(title: s.title, from: s.display(s.read(env)), to: s.display(change.value))
        }
        lines += plan.bookmarks.map { ChangeLine(title: "Add bookmark", from: nil, to: Self.siteLabel($0)) }
        lines += plan.favorites.map { ChangeLine(title: "Add to Favorites", from: nil, to: Self.siteLabel($0)) }
        return lines
    }

    static func siteLabel(_ site: CustomizationPlan.Site) -> String {
        let host = site.url.host.map(SiteShortcut.normalizedHost) ?? site.url.absoluteString
        guard let title = site.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              title.lowercased() != host.lowercased() else { return host }
        return "\(title) (\(host))"
    }

    /// Applies the whole plan or nothing, records it, and returns the change (with its id for undo).
    @discardableResult
    func apply(_ plan: CustomizationPlan, context: PersonalizationContext?, source: String) throws -> AIChange {
        guard !plan.isEmpty else { throw LunaToolError.invalidArguments("Nothing to change.") }
        try validate(plan.settings)
        if !plan.favorites.isEmpty, context?.workspace == nil {
            throw LunaToolError.unavailable("Favorites can only be added while a Luna window is open.")
        }
        if !plan.bookmarks.isEmpty, context == nil {
            throw LunaToolError.unavailable("No Luna profile is open.")
        }
        let lines = preview(plan)
        var change = AIChange(id: Self.newId(), date: Date(), source: source, lines: lines, profileId: context?.profileId)
        // Snapshot everything first, then write; a write that doesn't stick rolls the whole batch back.
        for c in plan.settings {
            let setting = CustomizationRegistry.setting(c.key)!
            change.settingSnapshots[c.key] = setting.snapshot(env)
            change.settingOrder.append(c.key)
        }
        for c in plan.settings { CustomizationRegistry.setting(c.key)!.write(env, c.value) }
        if let failed = plan.settings.first(where: { CustomizationRegistry.setting($0.key)!.read(env) != Self.normalized($0) }) {
            restoreSettings(change)
            throw LunaToolError.unavailable("Couldn't apply \(failed.key); nothing was changed.")
        }
        if let context {
            for site in plan.bookmarks where !context.bookmarks.contains(site.url) {
                change.inverse.append(.removeBookmark(context.bookmarks.add(url: site.url, title: site.title)))
            }
            if let store = context.workspace, !plan.favorites.isEmpty {
                var added: [UUID] = []
                store.update("Add to Favorites") { ws in
                    for site in plan.favorites {
                        var tab = Tab(url: site.url, title: site.title ?? "")
                        tab.savedURL = site.url
                        added.append(ws.addTab(tab, placement: .favorites))
                    }
                }
                change.inverse += added.map(InverseOp.removeTab)
            }
        }
        log.add(change)
        return change
    }

    /// Records a tab change made by a tool, so it shows in Recent AI changes and can be undone.
    @discardableResult
    func record(lines: [ChangeLine], inverse: [InverseOp], profileId: UUID, source: String) -> AIChange {
        let change = AIChange(id: Self.newId(), date: Date(), source: source, lines: lines, profileId: profileId, inverse: inverse)
        log.add(change)
        return change
    }

    // MARK: Undo

    /// Restores the exact prior values of a change's settings and reverses its tab and bookmark edits.
    func undo(_ id: String) throws -> AIChange {
        guard let change = log.entry(id) else { throw LunaToolError.invalidArguments("No change with id \(id).") }
        guard !change.undone else { throw LunaToolError.invalidArguments("Change \(id) was already undone.") }
        if !change.inverse.isEmpty {
            guard let profile = change.profileId, let context = resolveContext(profile) else {
                throw LunaToolError.unavailable("Open a window on the profile this change was made in, then undo.")
            }
            if change.inverse.contains(where: { if case .removeBookmark = $0 { return false }; return true }), context.workspace == nil {
                throw LunaToolError.unavailable("Open a window on the profile this change was made in, then undo.")
            }
            Self.reverse(change.inverse, in: context)
        }
        restoreSettings(change)
        log.markUndone(id)
        return change
    }

    private func restoreSettings(_ change: AIChange) {
        for key in change.settingOrder.reversed() {
            guard let setting = CustomizationRegistry.setting(key), let data = change.settingSnapshots[key] else { continue }
            setting.restore(env, data)
        }
    }

    static func reverse(_ ops: [InverseOp], in context: PersonalizationContext) {
        for op in ops.reversed() {
            switch op {
            case .removeBookmark(let id):
                context.bookmarks.remove(id)
            case .removeTab(let tab):
                context.workspace?.update("Undo AI Change") { _ = $0.removeTab(tab) }
            case .ungroup(let folder, let places):
                context.workspace?.update("Undo AI Change") { ws in
                    ws.ungroupFolder(folder)
                    for place in places.sorted(by: { $0.index < $1.index }) { put(place, in: &ws) }
                }
            case .resplit(let group, let place):
                context.workspace?.update("Undo AI Change") { $0.restoreSplit(group, at: place.location) }
            case .reorder(let space, let section, let order):
                context.workspace?.update("Undo AI Change") { ws in
                    TabOrganizer.permute(&ws, space: space, section: SidebarSection(rawValue: section) ?? .today, to: order)
                }
            case .unpin(let tab, let place, let savedURL):
                context.workspace?.update("Undo AI Change") { ws in
                    guard ws.tabs[tab] != nil else { return }
                    ws.unpin(tab)
                    if let place { put(place, in: &ws) }
                    ws.tabs[tab]?.savedURL = savedURL
                }
            case .repin(let tab, let place, let favoriteIndex, let savedURL):
                context.workspace?.update("Undo AI Change") { ws in
                    guard ws.tabs[tab] != nil else { return }
                    if let favoriteIndex {
                        ws.addToFavorites(tab, at: favoriteIndex)
                    } else {
                        ws.pin(tab)
                        if let place { put(place, in: &ws) }
                    }
                    ws.tabs[tab]?.savedURL = savedURL
                }
            }
        }
    }

    /// Puts a tab back at its recorded index (the index it had, not a drop position).
    private static func put(_ place: TabPlace, in ws: inout Workspace) {
        guard ws.tabs[place.tab] != nil, let node = ws.detachNode(place.tab) else { return }
        ws.insertNode(node, at: place.location)
    }

    // MARK: Helpers

    static func newId() -> String { "c" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(7).lowercased() }

    /// What reading the setting back should give (URL lists come back normalized).
    private static func normalized(_ change: SettingChange) -> JSONValue {
        if CustomizationRegistry.setting(change.key)?.kind == .color, let v = change.value.stringValue.flatMap(ThemeHex.parse) {
            return .string(ThemeHex.format(v))
        }
        guard case .array(let items) = change.value, CustomizationRegistry.setting(change.key)?.kind.typeName == "url-list" else {
            return change.value
        }
        return .array(items.compactMap { $0.stringValue.flatMap(CustomizableSetting.parseURL).map { .string($0.absoluteString) } })
    }
}

/// Tab organization done by the tools, each with its exact inverse.
enum TabOrganizer {
    /// Puts `order` into the slots those tabs occupy in a section's root list.
    static func permute(_ ws: inout Workspace, space: UUID, section: SidebarSection, to order: [UUID]) {
        guard let si = ws.spaceIndex(space) else { return }
        var list = ws.spaces[si][section]
        let wanted = Set(order)
        let slots = list.indices.filter { if case .tab(let id) = list[$0] { return wanted.contains(id) }; return false }
        guard slots.count == order.count else { return }
        for (slot, id) in zip(slots, order) { list[slot] = .tab(id) }
        ws.spaces[si][section] = list
    }

    /// The tabs' current order in their shared root list, or an error naming the problem.
    static func rootList(of tabIds: [UUID], in ws: Workspace) throws -> (space: UUID, section: SidebarSection, order: [UUID]) {
        var list: (UUID, SidebarSection)?
        var positions: [(UUID, Int)] = []
        for id in tabIds {
            guard ws.tabs[id] != nil else { throw LunaToolError.invalidArguments("No tab with id \(id.uuidString). Call tabs_list.") }
            guard let loc = ws.location(ofNode: id), loc.parentFolderId == nil else {
                throw LunaToolError.invalidArguments("Tab \(id.uuidString) is in a folder, split or Favorites; only top-level sidebar tabs can be reordered.")
            }
            if let list, list.0 != loc.spaceId || list.1 != loc.section {
                throw LunaToolError.invalidArguments("All tabs must be in the same section (Pinned or Today) of one space.")
            }
            list = (loc.spaceId, loc.section)
            positions.append((id, loc.index))
        }
        guard let list else { throw LunaToolError.invalidArguments("No tabs given.") }
        return (list.0, list.1, positions.sorted { $0.1 < $1.1 }.map(\.0))
    }
}

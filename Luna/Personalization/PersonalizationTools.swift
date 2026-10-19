import Foundation

/// Read tools over the opt-in usage record and history, and the typed customization API.
/// Customizing Luna happens only through these tools: settings from `CustomizationRegistry`,
/// tab organization, favorites and bookmarks. Each change is previewed, recorded and undoable.
enum PersonalizationTools {
    static let guardrail = "This is the only supported way to customize Luna: never write code, edit Luna's files or run builds to change it."

    static let all: [LunaTool] = [
        usageSummary, topSites, historySearch, featureUsage,
        settingsList, settingsSet, tabsGroup, tabsReorder, tabPin, favoritesAdd, bookmarksAdd, undoChange,
    ]

    /// Tools whose approval card is a change preview with Apply / Cancel.
    static let previewNames: Set<String> = ["settings_set", "tabs_group", "tabs_reorder", "tab_pin", "favorites_add",
                                            "bookmarks_add", "undo_change"]

    static let daysParam = LunaToolParam(name: "days", kind: .integer, description: "Look back this many days (default 30)",
                                         required: false, range: 1...365)

    // MARK: Read (opt-in)

    static let usageSummary = LunaTool(
        name: "usage_summary",
        description: "The user's browsing habits from Luna's opt-in local record: most-used features and shortcuts, active hours, tab/window habits, top sites and the current setup. Read this before proposing customizations. Returns 'personalization is off' unless the user opted in.",
        params: [daysParam], mutates: false, targetsTab: false
    ) { call in
        let ctx = try optedIn(call)
        return PersonalizationReport.summary(ctx, days: call.int("days") ?? 30)
    }

    static let topSites = LunaTool(
        name: "top_sites",
        description: "Most-visited sites from history (opt-in): domain, visit count, last visit. Domains only, never full URLs.",
        params: [LunaToolParam(name: "limit", kind: .integer, description: "How many (default 10)", required: false, range: 1...50),
                 daysParam],
        mutates: false, targetsTab: false
    ) { call in
        let ctx = try optedIn(call)
        let sites = PersonalizationReport.topSites(ctx.history(), days: call.int("days") ?? 30, limit: call.int("limit") ?? 10)
        if sites.isEmpty { return "No visits in that period." }
        return "domain\tvisits\tlast visit\n" + sites.map { "\($0.domain)\t\($0.visits)\t\(PersonalizationReport.day($0.lastVisit))" }
            .joined(separator: "\n")
    }

    static let historySearch = LunaTool(
        name: "history_search",
        description: "Search browsing history titles and addresses (opt-in). Returns date, title and the address without query strings.",
        params: [LunaToolParam(name: "query", kind: .string, description: "Words to find in titles or addresses"),
                 daysParam,
                 LunaToolParam(name: "limit", kind: .integer, description: "How many (default 20)", required: false, range: 1...100)],
        mutates: false, targetsTab: false
    ) { call in
        let ctx = try optedIn(call)
        let hits = PersonalizationReport.searchHistory(ctx.history(), query: call.string("query") ?? "",
                                                       days: call.int("days") ?? 30, limit: call.int("limit") ?? 20)
        if hits.isEmpty { return "No matches." }
        return hits.map { "\(PersonalizationReport.day($0.date))\t\($0.title)\t\($0.address)" }.joined(separator: "\n")
    }

    static let featureUsage = LunaTool(
        name: "feature_usage",
        description: "How often each Luna feature and keyboard shortcut was used (opt-in), with the number of days it was used.",
        params: [daysParam], mutates: false, targetsTab: false
    ) { call in
        let ctx = try optedIn(call)
        return PersonalizationReport.featureTable(ctx.usage, days: call.int("days") ?? 30)
    }

    // MARK: Customization

    static let settingsList = LunaTool(
        name: "settings_list",
        description: "Every Luna setting an agent may change: key, type and allowed values, current value, description. " + guardrail,
        params: [], mutates: false, targetsTab: false
    ) { _ in
        let env = Customizer.shared.env
        return "key\ttype\tcurrent\tdescription\n" + CustomizationRegistry.all.map { s in
            "\(s.key)\t\(s.typeDescription)\t\(s.read(env).jsonString())\t\(s.title): \(s.summary)"
        }.joined(separator: "\n")
    }

    static let settingsSet = LunaTool(
        name: "settings_set",
        description: "Change Luna settings in one atomic batch: changes = [{key, value}] with keys and values from settings_list (unknown keys, wrong types and values outside the allowed set are rejected, and nothing is applied). The user sees a preview (old → new) and applies or cancels. Returns a change id for undo_change. " + guardrail,
        params: [LunaToolParam(name: "changes", kind: .array, description: "List of {key, value}",
                               items: .object(["type": "object",
                                               "properties": .object(["key": .object(["type": "string"]), "value": .object([:])]),
                                               "required": .array(["key", "value"])]))],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in
            guard let changes = try? Customizer.parseChanges(call.arguments["changes"]) else { return "" }
            return Customizer.shared.preview(CustomizationPlan(settings: changes)).map(\.text).joined(separator: "\n")
        }
    ) { call in
        let changes = try Customizer.parseChanges(call.arguments["changes"])
        let change = try Customizer.shared.apply(CustomizationPlan(settings: changes), context: call.host.personalization,
                                                 source: call.source)
        return applied(change)
    }

    static let tabsGroup = LunaTool(
        name: "tabs_group",
        description: "Put tabs into a new tab group (a sidebar folder; a colored group chip in the tab strip) named `name`, where the first tab is. Returns a change id for undo_change. " + guardrail,
        params: [LunaToolParam(name: "tab_ids", kind: .array, description: "Tab ids from tabs_list (2 or more)",
                               items: .object(["type": "string"])),
                 LunaToolParam(name: "name", kind: .string, description: "Group name"),
                 LunaToolParam(name: "color", kind: .string, description: "Group color (default: the next unused one)",
                               required: false, allowed: TabGroupColor.allCases.map(\.rawValue))],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in
            "New folder “\(call.string("name") ?? "")”: " + titles(call, ids(call, "tab_ids")).joined(separator: ", ")
        }
    ) { call in
        let (ctx, store) = try workspace(call)
        let tabIds = try uuids(call, "tab_ids")
        guard tabIds.count >= 2 else { throw LunaToolError.invalidArguments("tabs_group: give at least 2 tabs.") }
        let name = (call.string("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let color = call.string("color").flatMap(TabGroupColor.init(rawValue:))
        var places: [TabPlace] = []
        var splits: [TabPlace] = []
        var groups: [SplitGroup] = []
        var folder: UUID?
        var problem: LunaToolError?
        store.update("Group Tabs") { ws in
            for id in tabIds {
                // A split pane isn't a sidebar node itself: it sits where its split is.
                let split = ws.splitGroup(containing: id)
                guard ws.tabs[id] != nil, !ws.isFavorite(id), let loc = ws.location(ofNode: split?.id ?? id) else {
                    problem = .invalidArguments("Tab \(id.uuidString) can't be grouped (unknown, or in Favorites)."); return
                }
                if let split {
                    // Undo rebuilds the split at its old spot instead of placing the pane alone.
                    if !splits.contains(where: { $0.tab == split.id }) { splits.append(TabPlace(tab: split.id, loc)); groups.append(split) }
                } else {
                    places.append(TabPlace(tab: id, loc))
                }
            }
            tabIds.forEach { _ = ws.detachTabFromAnySplit($0) }
            guard let first = ws.location(ofNode: tabIds[0]) else { return }
            folder = ws.createFolder(name: name, containing: tabIds, at: first, color: color ?? ws.nextGroupColor())
        }
        if let problem { throw problem }
        guard let folder else { throw LunaToolError.unavailable("Couldn't create the folder.") }
        let change = Customizer.shared.record(
            lines: [ChangeLine(title: "New folder “\(name)”", from: nil, to: "\(tabIds.count) tabs")],
            inverse: zip(groups, splits).map { InverseOp.resplit(group: $0, place: $1) } + [.ungroup(folder: folder, places: places)],
            profileId: ctx.profileId, source: call.source)
        return applied(change)
    }

    static let tabsReorder = LunaTool(
        name: "tabs_reorder",
        description: "Reorder sidebar tabs: `order` lists tab ids (all top-level in the same Pinned or Today list) in their new order; they swap into the slots they occupy now. Returns a change id. " + guardrail,
        params: [LunaToolParam(name: "order", kind: .array, description: "Tab ids in the new order", items: .object(["type": "string"]))],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in "New order: " + titles(call, ids(call, "order")).joined(separator: " → ") }
    ) { call in
        let (ctx, store) = try workspace(call)
        let order = try uuids(call, "order")
        guard Set(order).count == order.count else { throw LunaToolError.invalidArguments("tabs_reorder: a tab appears twice.") }
        let (space, section, before) = try TabOrganizer.rootList(of: order, in: store.workspace)
        store.update("Reorder Tabs") { TabOrganizer.permute(&$0, space: space, section: section, to: order) }
        let change = Customizer.shared.record(
            lines: [ChangeLine(title: "Reorder \(section == .pinned ? "Pinned" : "Today") tabs", from: nil, to: "\(order.count) tabs")],
            inverse: [.reorder(space: space, section: section.rawValue, order: before)], profileId: ctx.profileId, source: call.source)
        return applied(change)
    }

    static let tabPin = LunaTool(
        name: "tab_pin",
        description: "Pin a tab to the sidebar's Pinned section (pinned = true, default) or unpin it back to Today. Returns a change id. " + guardrail,
        params: [LunaToolParam(name: "tab_id", kind: .string, description: "Tab id from tabs_list"),
                 LunaToolParam(name: "pinned", kind: .boolean, description: "true to pin (default), false to unpin", required: false)],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in
            "\(call.bool("pinned") == false ? "Unpin" : "Pin"): " + titles(call, ids(call, "tab_id")).joined()
        }
    ) { call in
        let (ctx, store) = try workspace(call)
        guard let id = try uuids(call, "tab_id").first, let tab = store.tab(id) else {
            throw LunaToolError.invalidArguments("No such tab. Call tabs_list.")
        }
        let pin = call.bool("pinned") ?? true
        let ws = store.workspace
        let place = ws.location(ofNode: id).map { TabPlace(tab: id, $0) }
        let wasPersistent = ws.isPersistent(id)
        if pin == wasPersistent { return "Already \(pin ? "pinned" : "unpinned")." }
        let inverse: InverseOp
        if pin {
            store.pin(id)
            inverse = .unpin(tab: id, place: place, savedURL: tab.savedURL)
        } else {
            store.unpin(id)
            inverse = .repin(tab: id, place: place, favoriteIndex: ws.favorites.firstIndex(of: id), savedURL: tab.savedURL)
        }
        let name = tab.customTitle ?? (tab.title.isEmpty ? (tab.url?.host ?? "Tab") : tab.title)
        let change = Customizer.shared.record(lines: [ChangeLine(title: pin ? "Pin tab" : "Unpin tab", from: nil, to: name)],
                                              inverse: [inverse], profileId: ctx.profileId, source: call.source)
        return applied(change)
    }

    static let favoritesAdd = LunaTool(
        name: "favorites_add",
        description: "Add a site to the sidebar's Favorites. Returns a change id. " + guardrail,
        params: [LunaToolParam(name: "url", kind: .string, description: "http or https URL"),
                 LunaToolParam(name: "title", kind: .string, description: "Name (optional)", required: false)],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in
            sitePreview(call).map { Customizer.shared.preview(CustomizationPlan(favorites: [$0])).map(\.text).joined() } ?? ""
        }
    ) { call in
        let site = try requestedSite(call)
        let change = try Customizer.shared.apply(CustomizationPlan(favorites: [site]), context: call.host.personalization,
                                                 source: call.source)
        return applied(change)
    }

    static let bookmarksAdd = LunaTool(
        name: "bookmarks_add",
        description: "Add a bookmark to the bookmarks bar (turn the bar on with settings_set bookmarksBar.visible). Returns a change id. " + guardrail,
        params: [LunaToolParam(name: "url", kind: .string, description: "http or https URL"),
                 LunaToolParam(name: "title", kind: .string, description: "Name (optional)", required: false)],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in
            sitePreview(call).map { Customizer.shared.preview(CustomizationPlan(bookmarks: [$0])).map(\.text).joined() } ?? ""
        }
    ) { call in
        let site = try requestedSite(call)
        guard let ctx = call.host.personalization else { throw LunaToolError.unavailable("No Luna profile is open.") }
        if ctx.bookmarks.contains(site.url) { return "Already bookmarked." }
        let change = try Customizer.shared.apply(CustomizationPlan(bookmarks: [site]), context: ctx, source: call.source)
        return applied(change)
    }

    static let undoChange = LunaTool(
        name: "undo_change",
        description: "Undo an earlier customization by its change id: restores the exact previous settings and reverses its tab and bookmark edits.",
        params: [LunaToolParam(name: "change_id", kind: .string, description: "Id returned by settings_set or a tab tool")],
        mutates: true, targetsTab: false, confirmsEveryCall: true,
        preview: { call in
            guard let change = Customizer.shared.log.entry(call.string("change_id") ?? "") else { return "Unknown change" }
            return "Undo: " + change.lines.map(\.text).joined(separator: "; ")
        }
    ) { call in
        let change = try Customizer.shared.undo(call.string("change_id") ?? "")
        return "Undid \(change.id): " + change.lines.map(\.text).joined(separator: "; ")
    }

    // MARK: Helpers

    static func optedIn(_ call: LunaToolCall) throws -> PersonalizationContext {
        guard let ctx = call.host.personalization else { throw LunaToolError.unavailable("No Luna profile is open.") }
        guard ctx.usage.isEnabled else { throw LunaToolError.unavailable(PersonalizationPrefs.offMessage) }
        return ctx
    }

    private static func workspace(_ call: LunaToolCall) throws -> (PersonalizationContext, WorkspaceStore) {
        guard let ctx = call.host.personalization, let store = ctx.workspace else {
            throw LunaToolError.unavailable("No Luna window is open.")
        }
        return (ctx, store)
    }

    private static func ids(_ call: LunaToolCall, _ key: String) -> [String] {
        switch call.arguments[key] {
        case .array(let items)?: return items.compactMap(\.stringValue)
        case .string(let s)?: return [s]
        default: return []
        }
    }

    private static func uuids(_ call: LunaToolCall, _ key: String) throws -> [UUID] {
        var seen = Set<UUID>()
        // A repeated id would be moved twice; keep the first occurrence.
        return try ids(call, key).compactMap { raw in
            guard let id = UUID(uuidString: raw) else { throw LunaToolError.invalidArguments("'\(raw)' is not a tab id. Call tabs_list.") }
            return seen.insert(id).inserted ? id : nil
        }
    }

    private static func titles(_ call: LunaToolCall, _ ids: [String]) -> [String] {
        let tabs = call.host.tabs
        return ids.map { raw in
            guard let tab = tabs.first(where: { $0.id.uuidString == raw }) else { return "unknown tab" }
            return tab.title.isEmpty ? (URL(string: tab.url)?.host ?? "Tab") : tab.title
        }
    }

    private static func sitePreview(_ call: LunaToolCall) -> CustomizationPlan.Site? {
        try? requestedSite(call)
    }

    /// The site to add, named from history when the caller gave no title.
    static let maxTitleLength = 200

    private static func requestedSite(_ call: LunaToolCall) throws -> CustomizationPlan.Site {
        let title = call.string("title").map { String($0.prefix(Self.maxTitleLength)) }
        let site = CustomizationPlan.Site(url: try call.url("url"), title: title)
        return call.host.personalization?.named(site) ?? site
    }

    private static func applied(_ change: AIChange) -> String {
        "Applied (change id \(change.id); undo with undo_change):\n" + change.lines.map { "- " + $0.text }.joined(separator: "\n")
    }
}

/// Aggregations the read tools and the Personalize proposal share. Pure functions over
/// the stores, so they're tested directly.
enum PersonalizationReport {
    struct Site: Equatable {
        let domain: String
        let visits: Int
        let lastVisit: Date
    }

    struct HistoryHit: Equatable {
        let date: Date
        let title: String
        let address: String
    }

    static func day(_ date: Date) -> String { UsageStore.dayKey(date) }

    static func visits(_ events: [HistoryEvent], days: Int, now: Date = Date()) -> [HistoryEvent] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return events.filter { $0.type == .pageVisit && $0.timestamp >= cutoff }
    }

    /// Visits per domain ("www." dropped), most visited first; http(s) only.
    static func topSites(_ events: [HistoryEvent], days: Int, limit: Int, now: Date = Date()) -> [Site] {
        var counts: [String: (Int, Date)] = [:]
        for e in visits(events, days: days, now: now) {
            guard let raw = e.url, let url = URL(string: raw), isSafeBrowserURL(url), let host = url.host?.lowercased() else { continue }
            let domain = SiteShortcut.normalizedHost(host)
            let current = counts[domain] ?? (0, .distantPast)
            counts[domain] = (current.0 + 1, max(current.1, e.timestamp))
        }
        return counts.map { Site(domain: $0.key, visits: $0.value.0, lastVisit: $0.value.1) }
            .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.domain < $1.domain }
            .prefix(limit).map { $0 }
    }

    /// A short name for a site from the titles its pages had in history ("Hacker News" for
    /// news.ycombinator.com). Home-page visits win; a deeper page counts only when its title
    /// carries a separated site name ("Story | The Verge"). Nil when nothing short fits.
    static func siteName(for url: URL, history: [HistoryEvent]) -> String? {
        guard let host = url.host.map({ SiteShortcut.normalizedHost($0.lowercased()) }) else { return nil }
        var deep: String?
        for e in history.reversed() where e.type == .pageVisit {
            guard let raw = e.url, let visited = URL(string: raw),
                  visited.host.map({ SiteShortcut.normalizedHost($0.lowercased()) }) == host,
                  let title = e.pageTitle else { continue }
            let isHome = visited.path.isEmpty || visited.path == "/"
            if isHome, let name = shortTitle(title, host: host, isHome: true) { return name }
            if deep == nil { deep = shortTitle(title, host: host, isHome: false) }
        }
        return deep
    }

    /// "Inbox (3) - someone@x.com - Gmail" → "Gmail"; "Hacker News" → "Hacker News".
    static func shortTitle(_ title: String, host: String, isHome: Bool, maxLength: Int = 24) -> String? {
        var parts = [title]
        for sep in [" - ", " – ", " — ", " | ", " · ", " • ", ": "] {
            parts = parts.flatMap { $0.components(separatedBy: sep) }
        }
        let segments = parts.map { $0.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("@") }
        guard !segments.isEmpty else { return nil }
        let labels = host.split(separator: ".").dropLast().map { String($0).lowercased() }.filter { $0.count >= 3 }
        func compact(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let match = segments.first { seg in
            let c = compact(seg)
            return c.count >= 3 && labels.contains { $0.contains(c) || c.hasPrefix($0) }
        }
        let pick: String?
        if let match { pick = match }
        else if parts.count == 1 { pick = isHome ? segments[0] : nil }
        else { pick = isHome ? segments.first : segments.last }
        guard let name = pick, name.count <= maxLength else { return nil }
        return name
    }

    /// Case-insensitive match on title or address; addresses lose their query string and fragment.
    static func searchHistory(_ events: [HistoryEvent], query: String, days: Int, limit: Int, now: Date = Date()) -> [HistoryHit] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        var hits: [HistoryHit] = []
        for e in visits(events, days: days, now: now) {
            guard let raw = e.url, let url = URL(string: raw), isSafeBrowserURL(url) else { continue }
            let address = strippedAddress(url)
            let title = e.pageTitle ?? ""
            let haystack = (title + " " + address).lowercased()
            guard words.allSatisfy(haystack.contains) else { continue }
            hits.append(HistoryHit(date: e.timestamp, title: title.isEmpty ? "(untitled)" : title, address: address))
            if hits.count >= limit { break }
        }
        return hits
    }

    /// host + path, no scheme, query or fragment (they often carry tokens and personal data).
    static func strippedAddress(_ url: URL) -> String {
        let host = url.host.map(SiteShortcut.normalizedHost) ?? ""
        let path = url.path == "/" ? "" : url.path
        return host + path
    }

    static func featureTable(_ usage: UsageStore, days: Int) -> String {
        let buckets = usage.buckets(days: days)
        let features = usage.featureTotals(days: days)
        let shortcuts = usage.shortcutTotals(days: days)
        if features.isEmpty && shortcuts.isEmpty { return "No feature use recorded in the last \(days) days." }
        var lines = ["feature\tuses\tdays used"]
        for (feature, count) in features {
            let daysUsed = buckets.filter { ($0.features[feature.rawValue] ?? 0) > 0 }.count
            lines.append("\(feature.title)\t\(count)\t\(daysUsed)")
        }
        if !shortcuts.isEmpty {
            lines += ["", "shortcut\tuses"] + shortcuts.map { "\($0.shortcut)\t\($0.count)" }
        }
        return lines.joined(separator: "\n")
    }

    static func summary(_ ctx: PersonalizationContext, days: Int, env: CustomizationEnvironment = Customizer.shared.env) -> String {
        let usage = ctx.usage
        let buckets = usage.buckets(days: days)
        var lines = ["Luna usage, last \(days) days (\(buckets.count) active days):"]
        let features = usage.featureTotals(days: days).prefix(8)
        lines.append("Top features: " + (features.isEmpty ? "none recorded" : features.map { "\($0.feature.title) \($0.count)" }.joined(separator: ", ")))
        let shortcuts = usage.shortcutTotals(days: days).prefix(6)
        if !shortcuts.isEmpty { lines.append("Shortcuts: " + shortcuts.map { "\($0.shortcut) \($0.count)" }.joined(separator: ", ")) }
        let hours = usage.activeHours(days: days)
        let topHours = hours.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(3).map(\.offset).sorted()
        if !topHours.isEmpty { lines.append("Most active hours: " + topHours.map { "\($0):00–\($0 + 1):00" }.joined(separator: ", ")) }
        let active = max(1, buckets.count)
        func total(_ f: UsageFeature) -> Int { buckets.reduce(0) { $0 + ($1.features[f.rawValue] ?? 0) } }
        lines.append("Tabs: \(total(.newTab) / active) opened and \(total(.closeTab) / active) closed per active day; most open at once \(buckets.map(\.maxOpenTabs).max() ?? 0); \(total(.newWindow)) new windows; \(total(.splitView)) split views.")
        let sites = topSites(ctx.history(), days: days, limit: 8)
        lines.append("Top sites: " + (sites.isEmpty ? "none" : sites.map { "\($0.domain) (\($0.visits))" }.joined(separator: ", ")))
        let current = ["tabs.layout", "toolbar.visible", "bookmarksBar.visible", "appearance.theme", "search.engine"].compactMap { key -> String? in
            CustomizationRegistry.setting(key).map { "\($0.title) \($0.display($0.read(env)))" }
        }
        lines.append("Current setup: " + current.joined(separator: ", ") + "; \(ctx.bookmarks.bookmarks.count) bookmarks" +
            (ctx.workspace.map { "; \($0.workspace.favorites.count) favorites" } ?? ""))
        return lines.joined(separator: "\n")
    }
}

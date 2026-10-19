import Foundation

/// The AI panel's Personalize card: a proposed batch of registry changes the user applies or cancels.
struct CustomizationCard: Codable, Equatable {
    enum Status: String, Codable { case thinking, ready, applied, cancelled, failed, undone }

    struct Item: Codable, Equatable, Identifiable {
        enum Action: Codable, Equatable {
            case setting(key: String, value: JSONValue)
            case bookmark(url: URL, title: String?)
            case favorite(url: URL, title: String?)
        }

        var id: String
        var action: Action
        var line: ChangeLine
        var include = true
    }

    var request: String
    var note = ""
    var items: [Item] = []
    /// Model suggestions that were dropped (unknown keys, bad values), for transparency.
    var rejected: [String] = []
    var status: Status = .thinking
    /// The model's name, or "your usage" for the built-in suggestions.
    var source = ""
    /// The usage record was off: the proposal used only the request.
    var usedUsage = true
    var changeId: String?
    var message: String?

    var plan: CustomizationPlan {
        var plan = CustomizationPlan()
        for item in items where item.include {
            switch item.action {
            case .setting(let key, let value): plan.settings.append(SettingChange(key: key, value: value))
            case .bookmark(let url, let title): plan.bookmarks.append(.init(url: url, title: title))
            case .favorite(let url, let title): plan.favorites.append(.init(url: url, title: title))
            }
        }
        return plan
    }

    var transcript: String {
        "Personalize: " + (items.isEmpty ? (message ?? note) : items.map(\.line.text).joined(separator: "; "))
    }
}

/// Builds Personalize proposals: the user's chosen model reads the usage summary and the
/// settings registry and answers with JSON restricted to registry keys, bookmarks and
/// favorites. Everything is validated; anything unknown is dropped. No code, no builds.
enum Personalize {
    static let maxBookmarks = 8
    static let maxFavorites = 6

    static var systemPrompt: String {
        """
        You personalize the Luna web browser for its user. You can ONLY propose changes from the typed settings registry \
        below, bookmarks for the bookmarks bar, and sites for the sidebar Favorites. Never suggest writing code, editing \
        files, running builds or any other way of changing Luna.
        Reply with JSON only, no prose, in this shape:
        {"note": "one short sentence on why", "settings": [{"key": "...", "value": ...}], \
        "bookmarks": [{"url": "https://...", "title": "..."}], "favorites": [{"url": "https://...", "title": "..."}]}
        Rules: use only keys listed in the registry, with values of the listed type and allowed values; propose only \
        changes grounded in the user's request or their usage; skip values that already match; at most \(maxBookmarks) \
        bookmarks and \(maxFavorites) favorites, picked from the user's top sites. If the user asks for a toolbar in the \
        sidebar layout, set toolbar.visible. If they want bookmarks, set bookmarksBar.visible and add their top sites.
        """
    }

    /// Usage summary (when opted in), top sites and the registry, as the model sees them.
    static func context(_ ctx: PersonalizationContext?, env: CustomizationEnvironment) -> String {
        var parts: [String] = []
        if let ctx, ctx.usage.isEnabled {
            parts.append(PersonalizationReport.summary(ctx, days: 30, env: env))
            let sites = PersonalizationReport.topSites(ctx.history(), days: 30, limit: 12)
            if !sites.isEmpty {
                parts.append("Top sites (domain, visits): " + sites.map { "\($0.domain) \($0.visits)" }.joined(separator: ", "))
            }
            if !ctx.bookmarks.bookmarks.isEmpty {
                parts.append("Already bookmarked: " + ctx.bookmarks.bookmarks.compactMap { $0.url.host }.joined(separator: ", "))
            }
        } else {
            parts.append("The user's usage record is off: base the proposal on their request only.")
        }
        parts.append("Settings registry (key, type, current value, description):\n" + CustomizationRegistry.all.map { s in
            "\(s.key)\t\(s.typeDescription(env))\t\(s.read(env).jsonString())\t\(s.title): \(s.summary)"
        }.joined(separator: "\n"))
        return AgentRedaction.redact(parts.joined(separator: "\n\n"))
    }

    static func request(for userRequest: String, ctx: PersonalizationContext?, env: CustomizationEnvironment) -> LLMRequest {
        let ask = userRequest.trimmingCharacters(in: .whitespacesAndNewlines)
        var req = LLMRequest(prompt: "User request: " + (ask.isEmpty ? "Set Luna up the way I use it." : ask),
                             context: context(ctx, env: env))
        req.systemPrompt = systemPrompt
        return req
    }

    /// Turns a model reply into a card. Unknown keys, invalid values and no-op changes are dropped.
    static func parse(_ reply: String, request: String, ctx: PersonalizationContext?, customizer: Customizer) -> CustomizationCard {
        var card = CustomizationCard(request: request)
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let json = try? JSONDecoder().decode(JSONValue.self, from: Data(reply[start...end].utf8)) else {
            card.status = .failed
            card.message = "The model didn't return a proposal."
            return card
        }
        card.note = json["note"]?.stringValue ?? ""
        if case .array(let settings)? = json["settings"] {
            for entry in settings {
                guard let key = entry["key"]?.stringValue, let value = entry["value"] else {
                    card.rejected.append("A setting without a key or value")
                    continue
                }
                addSetting(key, value, to: &card, customizer: customizer)
            }
        }
        for (field, isBookmark) in [("bookmarks", true), ("favorites", false)] {
            guard case .array(let sites)? = json[field] else { continue }
            for entry in sites {
                guard let raw = entry["url"]?.stringValue ?? entry.stringValue, let url = CustomizableSetting.parseURL(raw) else {
                    card.rejected.append("\(isBookmark ? "Bookmark" : "Favorite") with an invalid address")
                    continue
                }
                addSite(url, title: entry["title"]?.stringValue, bookmark: isBookmark, to: &card, ctx: ctx)
            }
        }
        card.status = .ready
        if card.items.isEmpty { card.message = "Everything already matches — nothing to change." }
        return card
    }

    /// Built-in suggestions when no model answers: the request's words and the top sites.
    static func suggestions(request: String, ctx: PersonalizationContext?, customizer: Customizer) -> CustomizationCard {
        var card = CustomizationCard(request: request)
        let ask = request.lowercased()
        let usage = ctx?.usage.isEnabled == true ? ctx : nil
        let sites = usage.map { PersonalizationReport.topSites($0.history(), days: 30, limit: 12) } ?? []
        let addressUses = usage?.usage.featureTotals(days: 30).first { $0.feature == .addressBar }?.count ?? 0
        let layout = customizer.currentValue("tabs.layout")?.stringValue
        if ask.contains("toolbar") || (layout == "sidebar" && addressUses >= 5 && ask.isEmpty) {
            addSetting("toolbar.visible", .bool(true), to: &card, customizer: customizer)
        }
        let wantsBookmarks = ask.contains("bookmark")
        if wantsBookmarks || (ask.isEmpty && sites.count >= 3) {
            addSetting("bookmarksBar.visible", .bool(true), to: &card, customizer: customizer)
            for site in sites.prefix(5) {
                if let url = URL(string: "https://\(site.domain)") {
                    addSite(url, title: nil, bookmark: true, to: &card, ctx: ctx)
                }
            }
        }
        if ask.contains("dark") { addSetting("appearance.theme", "dark", to: &card, customizer: customizer) }
        if ask.contains("light") { addSetting("appearance.theme", "light", to: &card, customizer: customizer) }
        card.note = usage == nil ? "Based on your request." : "Based on your request and the sites you visit most."
        card.status = .ready
        if card.items.isEmpty { card.message = "No changes to suggest yet. Try asking for something specific, like “show the toolbar”." }
        return card
    }

    // MARK: Building items

    private static func addSetting(_ key: String, _ value: JSONValue, to card: inout CustomizationCard, customizer: Customizer) {
        guard let setting = CustomizationRegistry.setting(key) else {
            card.rejected.append("Unknown setting “\(key)”")
            return
        }
        do { try setting.validate(value, env: customizer.env) } catch {
            card.rejected.append(error.localizedDescription)
            return
        }
        let current = setting.read(customizer.env)
        guard current != value, !card.items.contains(where: { $0.id == "setting:\(key)" }) else { return }
        card.items.append(.init(id: "setting:\(key)", action: .setting(key: key, value: value),
                                line: ChangeLine(title: setting.title, from: setting.display(current, env: customizer.env), to: setting.display(value, env: customizer.env))))
    }

    private static func addSite(_ url: URL, title: String?, bookmark: Bool, to card: inout CustomizationCard,
                                ctx: PersonalizationContext?) {
        let id = "\(bookmark ? "bookmark" : "favorite"):\(url.absoluteString)"
        guard !card.items.contains(where: { $0.id == id }) else { return }
        let count = card.items.filter { $0.id.hasPrefix(bookmark ? "bookmark:" : "favorite:") }.count
        guard count < (bookmark ? maxBookmarks : maxFavorites) else { return }
        if bookmark, ctx?.bookmarks.contains(url) == true { return }
        if !bookmark, let ws = ctx?.workspace?.workspace,
           ws.favorites.contains(where: { ws.tabs[$0]?.url?.host == url.host }) { return }
        let raw = CustomizationPlan.Site(url: url, title: title)
        let site = ctx?.named(raw) ?? raw
        card.items.append(.init(id: id, action: bookmark ? .bookmark(url: url, title: site.title) : .favorite(url: url, title: site.title),
                                line: ChangeLine(title: bookmark ? "Add bookmark" : "Add to Favorites", from: nil,
                                                 to: Customizer.siteLabel(site))))
    }

    /// Asks the chosen model; falls back to the built-in suggestions if it can't answer.
    static func propose(request userRequest: String, ctx: PersonalizationContext?,
                        customizer: Customizer? = nil, useModel: Bool = true) async -> CustomizationCard {
        let customizer = customizer ?? .shared
        var card: CustomizationCard
        if useModel, let reply = try? await LLMService.shared.complete(request(for: userRequest, ctx: ctx, env: customizer.env)) {
            card = parse(reply, request: userRequest, ctx: ctx, customizer: customizer)
            card.source = LLMService.shared.modelName
            if card.status == .failed {
                card = suggestions(request: userRequest, ctx: ctx, customizer: customizer)
                card.source = "your usage"
            }
        } else {
            card = suggestions(request: userRequest, ctx: ctx, customizer: customizer)
            card.source = "your usage"
        }
        card.usedUsage = ctx?.usage.isEnabled == true
        return card
    }
}

import WebKit
import XCTest
@testable import Axolotl

/// A host with one profile's stores (temp files, in-memory workspace) for the personalization tools.
@MainActor
private final class PersonalHost: AgentBrowserHost {
    let context: PersonalizationContext
    init(context: PersonalizationContext) { self.context = context }

    var tabs: [AgentTabInfo] {
        let store = context.workspace!
        return store.orderedTabIds.map { AgentTabInfo(id: $0, title: store.tab($0)?.title ?? "", url: store.tab($0)?.url?.absoluteString ?? "",
                                                     active: $0 == store.activeTabId) }
    }
    var activeTabId: UUID? { context.workspace?.activeTabId }
    func webView(for tab: UUID) -> WKWebView? { nil }
    func openTab(url: URL) -> UUID { context.workspace!.newTab(url: url) }
    func selectTab(_ id: UUID) { context.workspace?.activate(id) }
    func navigate(_ tab: UUID, to url: URL) {}
    var personalization: PersonalizationContext? { context }
}

@MainActor
final class PersonalizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var dir: URL!
    private var savedCustomizer: Customizer!
    private var history: [HistoryEvent] = []
    private var context: PersonalizationContext!
    private var toolbox: AxolotlToolbox!
    private let now = Date()

    override func setUp() async throws {
        suiteName = "PersonalizationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedCustomizer = Customizer.shared
        let customizer = Customizer(env: CustomizationEnvironment(defaults: defaults, shortcuts: ShortcutStore(defaults: defaults)),
                                    log: AIChangeLog(defaults: defaults))
        Customizer.shared = customizer
        history = []
        let profile = UUID()
        context = PersonalizationContext(profileId: profile, usage: UsageStore(fileURL: dir.appendingPathComponent("usage.json"), defaults: defaults),
                                         history: { [unowned self] in self.history },
                                         bookmarks: BookmarkStore(fileURL: dir.appendingPathComponent("bookmarks.json")),
                                         workspace: WorkspaceStore(persistence: nil))
        let ctx = context!
        customizer.resolveContext = { $0 == profile ? ctx : nil }
        let host = PersonalHost(context: ctx)
        toolbox = AxolotlToolbox { host }
    }

    override func tearDown() async throws {
        Customizer.shared = savedCustomizer
        UserDefaults().removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    private var customizer: Customizer { Customizer.shared }

    private func visit(_ url: String, daysAgo: Double = 0, title: String = "") {
        history.append(HistoryEvent(timestamp: now.addingTimeInterval(-daysAgo * 86_400), type: .pageVisit, url: url, pageTitle: title))
    }

    // MARK: Registry

    func testRegistryRejectsUnknownKeysWrongTypesAndValuesOutsideTheAllowedSet() {
        let bad: [(String, JSONValue, String)] = [
            ("toolbar.colour", .bool(true), "Unknown setting"),
            ("toolbar.visible", "yes", "true or false"),
            ("appearance.theme", "purple", "not allowed"),
            ("appearance.theme", .number(1), "expected one of"),
            ("aiPanel.fontSize", .number(99), "10–24"),
            ("aiPanel.fontSize", .number(12.5), "integer"),
            ("tabs.unloadAfterMinutes", .number(45), "not allowed"),
            ("startPage.shortcuts", .array(["javascript:alert(1)"]), "http(s) URL"),
        ]
        for (key, value, message) in bad {
            XCTAssertThrowsError(try customizer.validate([SettingChange(key: key, value: value)]), key) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), "\(key): \(error.localizedDescription)")
            }
        }
        XCTAssertThrowsError(try customizer.validate([SettingChange(key: "toolbar.visible", value: .bool(true)),
                                                      SettingChange(key: "toolbar.visible", value: .bool(false))]))
        XCTAssertNoThrow(try customizer.validate([SettingChange(key: "toolbar.visible", value: .bool(true)),
                                                  SettingChange(key: "tabs.layout", value: "classic")]))
    }

    func testSearchEngineAcceptsExistingCustomEnginesOnly() throws {
        let customizer = Customizer.shared
        let engine = CustomSearchEngine(name: "Kagi", keyword: "k", template: "https://kagi.com/search?q=%s")
        CustomSearchEngine.save([engine], defaults)
        XCTAssertNoThrow(try customizer.validate([SettingChange(key: "search.engine", value: .string(engine.selectionValue))]))
        XCTAssertThrowsError(try customizer.validate([SettingChange(key: "search.engine", value: .string("custom." + UUID().uuidString))]))
        let setting = try XCTUnwrap(CustomizationRegistry.setting("search.engine"))
        setting.write(customizer.env, .string(engine.selectionValue))
        XCTAssertEqual(setting.read(customizer.env), .string(engine.selectionValue))
        XCTAssertEqual(setting.display(.string(engine.selectionValue), env: customizer.env), "Kagi")
    }

    func testBatchWithOneBadChangeAppliesNothing() async throws {
        let result = try await toolbox.call("settings_set", arguments: [
            "changes": .array([.object(["key": "toolbar.visible", "value": .bool(true)]),
                               .object(["key": "appearance.theme", "value": "neon"])]),
        ])
        XCTAssertTrue(result.isError)
        XCTAssertNil(defaults.object(forKey: ChromePrefs.showToolbar), "the valid change must not be applied alone")
        XCTAssertTrue(customizer.log.entries.isEmpty)
    }

    func testApplyThenUndoRestoresExactPriorValues() throws {
        defaults.set("dark", forKey: "axolotl_appearance")
        let custom = SiteShortcut(title: "My Mail", url: URL(string: "https://mail.example.com/")!)
        customizer.env.shortcuts.replaceAll([custom])
        XCTAssertNil(defaults.object(forKey: ChromePrefs.showToolbar))

        let change = try customizer.apply(CustomizationPlan(settings: [
            SettingChange(key: "toolbar.visible", value: .bool(true)),
            SettingChange(key: "appearance.theme", value: "light"),
            SettingChange(key: "startPage.shortcuts", value: .array(["github.com", "https://mail.example.com/"])),
        ]), context: context, source: "test")
        XCTAssertEqual(defaults.bool(forKey: ChromePrefs.showToolbar), true)
        XCTAssertEqual(defaults.string(forKey: "axolotl_appearance"), "light")
        XCTAssertEqual(customizer.env.shortcuts.shortcuts.map(\.url.host), ["github.com", "mail.example.com"])
        XCTAssertEqual(customizer.env.shortcuts.shortcuts.last?.title, "My Mail", "kept tiles keep their titles")
        XCTAssertEqual(change.lines.first, ChangeLine(title: "Show toolbar", from: "Off", to: "On"))

        _ = try customizer.undo(change.id)
        XCTAssertNil(defaults.object(forKey: ChromePrefs.showToolbar), "a never-set key is unset again, not set to false")
        XCTAssertEqual(defaults.string(forKey: "axolotl_appearance"), "dark")
        XCTAssertEqual(customizer.env.shortcuts.shortcuts, [custom])
        XCTAssertEqual(customizer.log.entry(change.id)?.undone, true)
        XCTAssertThrowsError(try customizer.undo(change.id), "undo twice")
    }

    func testUndoOfAnOlderChangeIsRefusedWhileALaterOneTouchedTheSameSetting() throws {
        defaults.set("dark", forKey: "axolotl_appearance")
        let first = try customizer.apply(CustomizationPlan(settings: [SettingChange(key: "appearance.theme", value: "light")]),
                                         context: context, source: "test")
        let second = try customizer.apply(CustomizationPlan(settings: [SettingChange(key: "appearance.theme", value: "system")]),
                                          context: context, source: "test")
        XCTAssertThrowsError(try customizer.undo(first.id))
        XCTAssertEqual(defaults.string(forKey: "axolotl_appearance"), "system", "later change kept")
        _ = try customizer.undo(second.id)
        _ = try customizer.undo(first.id)
        XCTAssertEqual(defaults.string(forKey: "axolotl_appearance"), "dark")
    }

    func testChangeLogKeepsTheLatestFifty() throws {
        for i in 0..<55 {
            try customizer.apply(CustomizationPlan(settings: [SettingChange(key: "aiPanel.fontSize", value: .number(Double(10 + i % 10)))]),
                                 context: context, source: "test")
        }
        XCTAssertEqual(customizer.log.entries.count, AIChangeLog.limit)
        XCTAssertEqual(AIChangeLog(defaults: defaults).entries.count, AIChangeLog.limit, "persisted")
    }

    // MARK: Opt-in

    func testOffRecordsNothingAndReadToolsRefuse() async throws {
        let usage = context.usage
        usage.record(.splitView)
        usage.recordShortcut("⌘T")
        usage.noteOpenTabs(9)
        usage.flush()
        XCTAssertTrue(usage.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: usage.fileURL.path))
        visit("https://github.com/")
        for (tool, args) in [("usage_summary", [:]), ("top_sites", [:]), ("feature_usage", [:]),
                             ("history_search", ["query": JSONValue.string("git")])] as [(String, [String: JSONValue])] {
            let result = try await toolbox.call(tool, arguments: args)
            XCTAssertTrue(result.isError, tool)
            XCTAssertTrue(result.text.contains("Personalization is off"), "\(tool): \(result.text)")
        }

        defaults.set(true, forKey: PersonalizationPrefs.enabledKey)
        usage.record(.splitView)
        usage.record(.splitView)
        usage.recordShortcut("⌘T")
        XCTAssertEqual(usage.featureTotals(days: 1).first?.feature, .splitView)
        XCTAssertEqual(usage.featureTotals(days: 1).first?.count, 2)
        let summary = try await toolbox.call("usage_summary", arguments: [:])
        XCTAssertFalse(summary.isError, summary.text)
        XCTAssertTrue(summary.text.contains("Split view 2"), summary.text)
        XCTAssertTrue(summary.text.contains("github.com (1)"), summary.text)
    }

    func testRetentionDropsOldDays() throws {
        let file = dir.appendingPathComponent("old.json")
        func key(_ daysAgo: Int) -> String { UsageStore.dayKey(now.addingTimeInterval(-Double(daysAgo) * 86_400)) }
        let saved = [key(200): UsageDay(), key(60): UsageDay(), key(20): UsageDay(), key(0): UsageDay()]
        try JSONEncoder().encode(saved).write(to: file)
        defaults.set(true, forKey: PersonalizationPrefs.enabledKey)

        defaults.set(90, forKey: PersonalizationPrefs.retentionKey)
        XCTAssertEqual(Set(UsageStore(fileURL: file, defaults: defaults, now: { self.now }).days.keys), [key(60), key(20), key(0)])
        defaults.set(30, forKey: PersonalizationPrefs.retentionKey)
        let store = UsageStore(fileURL: file, defaults: defaults, now: { self.now })
        XCTAssertEqual(Set(store.days.keys), [key(20), key(0)])
        store.deleteAll()
        XCTAssertTrue(store.days.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: History

    func testTopSitesAggregatesByDomainWithinTheWindow() {
        visit("https://www.github.com/a", daysAgo: 1)
        visit("https://github.com/b", daysAgo: 0.5)
        visit("http://github.com/c?tab=1", daysAgo: 2)
        visit("https://news.ycombinator.com/", daysAgo: 3)
        visit("https://news.ycombinator.com/item?id=1", daysAgo: 4)
        visit("https://old.example.com/", daysAgo: 40)
        visit("file:///Users/me/notes.html")
        history.append(HistoryEvent(timestamp: now, type: .chatConversation))
        let sites = PersonalizationReport.topSites(history, days: 30, limit: 10, now: now)
        XCTAssertEqual(sites.map(\.domain), ["github.com", "news.ycombinator.com"])
        XCTAssertEqual(sites.map(\.visits), [3, 2])
        XCTAssertEqual(sites[0].lastVisit, now.addingTimeInterval(-0.5 * 86_400))
        XCTAssertEqual(PersonalizationReport.topSites(history, days: 30, limit: 1, now: now).count, 1)
    }

    func testToolOutputHasNoSecretsQueriesOrFullURLs() async throws {
        defaults.set(true, forKey: PersonalizationPrefs.enabledKey)
        let key = "sk-" + String(repeating: "a1B2", count: 8)
        visit("https://dashboard.example.com/keys?token=\(key)&session=abc123#frag", title: "Your key \(key)")
        let search = try await toolbox.call("history_search", arguments: ["query": "key"])
        XCTAssertFalse(search.isError, search.text)
        XCTAssertFalse(search.text.contains(key), search.text)
        XCTAssertFalse(search.text.contains("token="), search.text)
        XCTAssertFalse(search.text.contains("abc123"), search.text)
        XCTAssertTrue(search.text.contains("dashboard.example.com/keys"), search.text)
        let sites = try await toolbox.call("top_sites", arguments: [:])
        XCTAssertTrue(sites.text.contains("dashboard.example.com\t1"), sites.text)
        XCTAssertFalse(sites.text.contains("/keys"), sites.text)
    }

    // MARK: Tabs and bookmarks

    func testTabsGroupMakesAColoredTabGroup() async throws {
        let store = context.workspace!
        let ids = ["a", "b", "c"].map { store.newTab(url: URL(string: "https://\($0).example.com/")!) }
        let pair: JSONValue = .array([.string(ids[0].uuidString), .string(ids[1].uuidString)])
        let bad = try await toolbox.call("tabs_group", arguments: ["tab_ids": pair, "name": "X", "color": "chartreuse"])
        XCTAssertTrue(bad.isError, bad.text)
        let made = try await toolbox.call("tabs_group", arguments: ["tab_ids": pair, "name": "Work", "color": "green"])
        XCTAssertFalse(made.isError, made.text)
        let group = try XCTUnwrap(store.workspace.tabGroup(containing: ids[1]))
        XCTAssertEqual(group.name, "Work")
        XCTAssertEqual(group.groupColor, .green)
        XCTAssertEqual(group.tabIds, [ids[0], ids[1]])
        // No color given: the next unused one, like a group made from the tab menu.
        store.removeFromTabGroup(ids[1])
        let next = try await toolbox.call("tabs_group", arguments: ["tab_ids": .array([.string(ids[1].uuidString), .string(ids[2].uuidString)]),
                                                                    "name": "Read"])
        XCTAssertFalse(next.isError, next.text)
        XCTAssertEqual(store.workspace.tabGroup(containing: ids[2])?.groupColor, .grey)
    }

    func testGroupReorderAndBookmarkUndoExactly() async throws {
        let store = context.workspace!
        let ids = ["a", "b", "c", "d"].map { store.newTab(url: URL(string: "https://\($0).example.com/")!) }
        let before = store.activeSpace.today

        let grouped = try await toolbox.call("tabs_group", arguments: ["tab_ids": .array([.string(ids[1].uuidString), .string(ids[3].uuidString)]),
                                                                       "name": "Work"])
        XCTAssertFalse(grouped.isError, grouped.text)
        XCTAssertTrue(store.activeSpace.today.contains { if case .folder(let f) = $0 { return f.name == "Work" }; return false })
        _ = try customizer.undo(try XCTUnwrap(customizer.log.entries.first?.id))
        XCTAssertEqual(store.activeSpace.today, before)

        func order() -> [UUID] { store.activeSpace.today.compactMap { if case .tab(let id) = $0, ids.contains(id) { return id }; return nil } }
        let current = order()
        let reordered = try await toolbox.call("tabs_reorder", arguments: ["order": .array([current[2], current[0]].map { .string($0.uuidString) })])
        XCTAssertFalse(reordered.isError, reordered.text)
        XCTAssertEqual(order(), [current[2], current[1], current[0], current[3]])
        _ = try customizer.undo(try XCTUnwrap(customizer.log.entries.first?.id))
        XCTAssertEqual(store.activeSpace.today, before)

        // Grouping a split pane breaks the split; undo puts the pairing back.
        let split = try XCTUnwrap(store.split([ids[0], ids[1]]))
        let withSplit = store.activeSpace.today
        let fromSplit = try await toolbox.call("tabs_group", arguments: ["tab_ids": .array([.string(ids[1].uuidString), .string(ids[2].uuidString)]),
                                                                         "name": "Read"])
        XCTAssertFalse(fromSplit.isError, fromSplit.text)
        XCTAssertNil(store.workspace.splitGroup(containing: ids[0]))
        _ = try customizer.undo(try XCTUnwrap(customizer.log.entries.first?.id))
        XCTAssertEqual(store.activeSpace.today, withSplit)
        XCTAssertEqual(store.workspace.splitGroup(containing: ids[1])?.id, split)

        let bookmarked = try await toolbox.call("bookmarks_add", arguments: ["url": "github.com", "title": "GitHub"])
        XCTAssertFalse(bookmarked.isError, bookmarked.text)
        XCTAssertEqual(context.bookmarks.bookmarks.map(\.title), ["GitHub"])
        _ = try customizer.undo(try XCTUnwrap(customizer.log.entries.first?.id))
        XCTAssertTrue(context.bookmarks.bookmarks.isEmpty)
    }

    func testTitlesAreCappedAndRepeatedTabIdsCollapse() async throws {
        let store = context.workspace!
        let ids = ["a", "b"].map { store.newTab(url: URL(string: "https://\($0).example.com/")!) }
        let a = ids[0].uuidString
        let one = try await toolbox.call("tabs_group", arguments: ["tab_ids": .array([.string(a), .string(a)]), "name": "Dup"])
        XCTAssertTrue(one.isError, "the same tab twice is one tab: \(one.text)")
        let two = try await toolbox.call("tabs_group", arguments: ["tab_ids": .array([a, ids[1].uuidString, a].map { .string($0) }), "name": "Ok"])
        XCTAssertFalse(two.isError, two.text)

        let long = String(repeating: "t", count: 5000)
        let added = try await toolbox.call("bookmarks_add", arguments: ["url": "https://long.example.com", "title": .string(long)])
        XCTAssertFalse(added.isError, added.text)
        XCTAssertEqual(context.bookmarks.bookmarks.first?.title.count, PersonalizationTools.maxTitleLength)
    }

    func testBookmarksAreNamedFromHistoryTitles() async throws {
        defaults.set(true, forKey: PersonalizationPrefs.enabledKey)
        visit("https://news.ycombinator.com/item?id=1", daysAgo: 2, title: "Show HN: A thing")
        visit("https://news.ycombinator.com/", daysAgo: 1, title: "Hacker News")
        visit("https://mail.google.com/mail/u/0/", title: "Inbox (3) - someone@example.com - Gmail")
        visit("https://www.theverge.com/2026/10/1/story", title: "A long story headline | The Verge")
        visit("https://example.org/", title: "A home page title that is far too long to fit a bookmark bar")
        XCTAssertEqual(PersonalizationReport.siteName(for: URL(string: "https://news.ycombinator.com")!, history: history), "Hacker News")
        XCTAssertEqual(PersonalizationReport.siteName(for: URL(string: "https://mail.google.com")!, history: history), "Gmail")
        XCTAssertEqual(PersonalizationReport.siteName(for: URL(string: "https://theverge.com")!, history: history), "The Verge")
        XCTAssertNil(PersonalizationReport.siteName(for: URL(string: "https://example.org")!, history: history))

        let added = try await toolbox.call("bookmarks_add", arguments: ["url": "https://news.ycombinator.com"])
        XCTAssertFalse(added.isError, added.text)
        _ = try await toolbox.call("bookmarks_add", arguments: ["url": "https://example.org"])
        XCTAssertEqual(context.bookmarks.bookmarks.map(\.title), ["Hacker News", "Example"], "unknown titles fall back to the domain")

        visit("https://news.ycombinator.com/", title: "Hacker News")
        visit("https://news.ycombinator.com/", title: "Hacker News")
        let card = Personalize.suggestions(request: "bookmarks", ctx: context, customizer: customizer)
        XCTAssertTrue(card.items.contains { $0.line.to == "Hacker News (news.ycombinator.com)" } == false,
                      "already bookmarked sites are skipped")
        XCTAssertTrue(card.items.contains { $0.line.to == "Gmail (mail.google.com)" }, card.items.map(\.line.to).description)

        defaults.set(false, forKey: PersonalizationPrefs.enabledKey)
        XCTAssertNil(context.named(.init(url: URL(string: "https://mail.google.com")!, title: nil)).title,
                     "history isn't read when personalization is off")
    }

    // MARK: MCP

    func testMCPListsTheToolsAndAlwaysPreviewsCustomizations() async throws {
        let approver = StubApprover()
        let endpoint = MCPEndpoint(toolbox: toolbox, port: { 47821 }, token: { "t-0123456789abcdef0123" },
                                   isTrusted: { true }, approver: approver)
        func send(_ body: String, session: String? = nil) async throws -> (JSONValue, MCPHTTPResponse) {
            var headers = ["host": "127.0.0.1:47821", "authorization": "Bearer t-0123456789abcdef0123", "content-type": "application/json"]
            if let session { headers["mcp-session-id"] = session }
            let r = await endpoint.handle(MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data(body.utf8),
                                                         remoteIsLoopback: true))
            return (try JSONDecoder().decode(JSONValue.self, from: r.body), r)
        }
        let (_, initResponse) = try await send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex","version":"1"}}}"#)
        let session = try XCTUnwrap(initResponse.headers["Mcp-Session-Id"])
        let (list, _) = try await send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, session: session)
        guard case .array(let tools)? = list["result"]?["tools"] else { return XCTFail("no tools") }
        func tool(_ name: String) -> JSONValue? { tools.first { $0["name"]?.stringValue == name } }
        for name in PersonalizationTools.all.map(\.name) { XCTAssertNotNil(tool(name), name) }
        XCTAssertEqual(tool("settings_set")?["annotations"]?["readOnlyHint"], .bool(false))
        XCTAssertEqual(tool("top_sites")?["annotations"]?["readOnlyHint"], .bool(true))
        XCTAssertTrue(tool("settings_set")?["description"]?.stringValue?.contains("never write code") == true)

        let set = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"settings_set","arguments":{"changes":[{"key":"bookmarksBar.visible","value":true}]}}}"#
        approver.answer = .deny
        _ = try await send(set, session: session)
        XCTAssertEqual(approver.asked, ["settings_set"], "asked even though the agent is trusted")
        XCTAssertNil(defaults.object(forKey: ChromePrefs.showBookmarksBar), "declined: nothing applied")

        approver.answer = .session
        let (applied, _) = try await send(set, session: session)
        XCTAssertEqual(applied["result"]?["isError"], .bool(false))
        XCTAssertTrue(defaults.bool(forKey: ChromePrefs.showBookmarksBar))
        XCTAssertEqual(customizer.log.entries.first?.source, "codex")
        _ = try await send(set, session: session)
        XCTAssertEqual(approver.asked.count, 3, "Allow for Session doesn't skip the next preview")

        _ = try await send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"settings_list","arguments":{}}}"#, session: session)
        XCTAssertEqual(approver.asked.count, 3, "read tools don't ask")
    }

    // MARK: Personalize

    func testProposalKeepsOnlyValidRegistryChanges() {
        defaults.set(true, forKey: PersonalizationPrefs.enabledKey)
        let reply = """
        Sure! {"note": "You browse GitHub a lot.", "settings": [
          {"key": "toolbar.visible", "value": true}, {"key": "bookmarksBar.visible", "value": true},
          {"key": "tabs.layout", "value": "sidebar"}, {"key": "rm -rf", "value": true},
          {"key": "appearance.theme", "value": "neon"}],
          "bookmarks": [{"url": "https://github.com", "title": "GitHub"}, {"url": "javascript:alert(1)"}],
          "favorites": [{"url": "news.ycombinator.com"}]}
        """
        let card = Personalize.parse(reply, request: "", ctx: context, customizer: customizer)
        XCTAssertEqual(card.status, .ready)
        XCTAssertEqual(card.items.map(\.id), ["setting:toolbar.visible", "setting:bookmarksBar.visible",
                                              "bookmark:https://github.com", "favorite:https://news.ycombinator.com"],
                       "tabs.layout already matches, so it's dropped")
        XCTAssertEqual(card.rejected.count, 3)
        XCTAssertEqual(card.items[0].line, ChangeLine(title: "Show toolbar", from: "Off", to: "On"))
        XCTAssertEqual(card.plan.settings.count, 2)
        XCTAssertEqual(Personalize.parse("no json here", request: "", ctx: context, customizer: customizer).status, .failed)
    }
}

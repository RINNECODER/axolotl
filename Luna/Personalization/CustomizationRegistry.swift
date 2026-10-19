import Foundation

/// Every browser setting an AI agent may change, with its type, allowed values and the real
/// preference behind it. Agents change Luna only through this registry (settings_list /
/// settings_set): no code, no file edits, no builds.
struct CustomizableSetting {
    enum Kind: Equatable {
        case bool
        /// String values, each with a title for people.
        case choice([(value: String, title: String)])
        case int(ClosedRange<Int>)
        /// Integer values, each with a title.
        case intChoice([(value: Int, title: String)])
        /// http(s) URLs.
        case urlList(max: Int)

        static func == (a: Kind, b: Kind) -> Bool { a.typeName == b.typeName }

        var typeName: String {
            switch self {
            case .bool: return "bool"
            case .choice: return "enum"
            case .int: return "int"
            case .intChoice: return "int-enum"
            case .urlList: return "url-list"
            }
        }
    }

    let key: String
    /// The label people see, in Settings and in change previews ("Show bookmarks bar").
    let title: String
    /// What the setting does, for agents (settings_list).
    let summary: String
    let kind: Kind
    let read: (CustomizationEnvironment) -> JSONValue
    let write: (CustomizationEnvironment, JSONValue) -> Void
    /// Opaque exact state (including "never set"), for undo.
    let snapshot: (CustomizationEnvironment) -> Data
    let restore: (CustomizationEnvironment, Data) -> Void
    /// One line under the control in Settings; nil when the label says it all.
    var help: String? = nil
    /// The UserDefaults key behind a plain preference, so Settings can bind to it.
    var defaultsKey: String? = nil

    /// Throws unless `value` has this setting's type and is allowed.
    func validate(_ value: JSONValue) throws {
        func fail(_ why: String) -> LunaToolError { .invalidArguments("\(key): \(why)") }
        switch kind {
        case .bool:
            guard case .bool = value else { throw fail("expected true or false.") }
        case .choice(let options):
            guard let s = value.stringValue else { throw fail("expected one of \(options.map(\.value).joined(separator: ", ")).") }
            guard options.contains(where: { $0.value == s }) else {
                throw fail("'\(s)' is not allowed; use one of \(options.map(\.value).joined(separator: ", ")).")
            }
        case .int(let range):
            guard let n = value.intValue else { throw fail("expected an integer.") }
            guard range.contains(n) else { throw fail("must be \(range.lowerBound)–\(range.upperBound).") }
        case .intChoice(let options):
            guard let n = value.intValue else { throw fail("expected one of \(options.map { String($0.value) }.joined(separator: ", ")).") }
            guard options.contains(where: { $0.value == n }) else {
                throw fail("\(n) is not allowed; use one of \(options.map { String($0.value) }.joined(separator: ", ")).")
            }
        case .urlList(let max):
            guard case .array(let items) = value else { throw fail("expected a list of http(s) URLs.") }
            guard items.count <= max else { throw fail("at most \(max) URLs.") }
            for item in items {
                guard let s = item.stringValue, Self.parseURL(s) != nil else { throw fail("every item must be an http(s) URL.") }
            }
        }
    }

    /// Value for people: "On", "Dark", "30 minutes", "github.com, news.ycombinator.com".
    func display(_ value: JSONValue) -> String {
        switch kind {
        case .bool:
            if case .bool(let b) = value { return b ? "On" : "Off" }
        case .choice(let options):
            if let s = value.stringValue { return options.first { $0.value == s }?.title ?? s }
        case .int:
            if let n = value.intValue { return "\(n)" }
        case .intChoice(let options):
            if let n = value.intValue { return options.first { $0.value == n }?.title ?? "\(n)" }
        case .urlList:
            if case .array(let items) = value {
                let hosts = items.compactMap { $0.stringValue.flatMap(Self.parseURL)?.host }
                    .map(SiteShortcut.normalizedHost)
                return hosts.isEmpty ? "None" : hosts.joined(separator: ", ")
            }
        }
        return value.jsonString()
    }

    /// Schema line for settings_list.
    var typeDescription: String {
        switch kind {
        case .bool: return "bool"
        case .choice(let o): return "enum(" + o.map(\.value).joined(separator: "|") + ")"
        case .int(let r): return "int(\(r.lowerBound)...\(r.upperBound))"
        case .intChoice(let o): return "enum(" + o.map { String($0.value) }.joined(separator: "|") + ")"
        case .urlList(let max): return "list of up to \(max) http(s) URLs"
        }
    }

    nonisolated static func parseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: normalized), isSafeBrowserURL(url) else { return nil }
        return url
    }
}

/// Where settings live; tests pass a throwaway defaults suite.
struct CustomizationEnvironment {
    let defaults: UserDefaults
    let shortcuts: ShortcutStore

    static var live: CustomizationEnvironment { CustomizationEnvironment(defaults: .standard, shortcuts: .shared) }
}

extension JSONValue {
    /// An integral number.
    var intValue: Int? {
        guard let n = numberValue, n == n.rounded(), abs(n) < 1e9 else { return nil }
        return Int(n)
    }
}

enum CustomizationRegistry {
    static let all: [CustomizableSetting] = [
        choice("appearance.theme", "luma_appearance", "Color scheme", "Light, dark or follow the system.", default: "system",
               [("system", "System"), ("light", "Light"), ("dark", "Dark")]),
        bool("appearance.liquidGlass", LiquidGlass.defaultsKey, "Liquid Glass",
             "On: macOS Liquid Glass and translucent materials. Off: Luna's solid, opaque surfaces.",
             default: LiquidGlass.defaultValue,
             help: "Off draws Luna's own solid surfaces and menus instead of translucent glass."),
        choice("tabs.layout", BrowserLayout.defaultsKey, "Browser layout",
               "sidebar = vertical tabs; compact/dynamic/classic = tabs on top.", default: BrowserLayout.sidebar.rawValue,
               BrowserLayout.allCases.map { ($0.rawValue, $0.title) }),
        LayoutTemplate.setting,
        bool("toolbar.visible", ChromePrefs.showToolbar, "Show toolbar",
             "Sidebar layout: a toolbar row (back, forward, reload, address field, buttons) above the page.", default: false,
             help: "Back, forward, reload and the address field above the page."),
        bool("bookmarksBar.visible", ChromePrefs.showBookmarksBar, "Show bookmarks bar",
             "A row of bookmarks above the page (agents add them for you).", default: false,
             help: "Add pages with ⋯ → Bookmark This Page."),
        bool("sidebar.visible", "luna_sidebar_visible", "Show sidebar", "Sidebar layout: sidebar docked open.", default: true),
        bool("chrome.autoHide", ChromePrefs.frameless, "Auto-hide browser UI",
             "Hide the sidebar (or the top bar in top layouts) until the window edge is hovered.", default: false,
             help: "Hover the window edge to show the sidebar or top bar."),
        bool("chrome.alwaysShowTopBar", ChromePrefs.alwaysShowTopBar, "Always show the top bar",
             "Top layouts with auto-hide on: keep the top bar visible.", default: false,
             help: "Keeps the tabs on top visible while the rest hides."),
        bool("chrome.roundedFrame", ChromePrefs.roundedFrame, "Show rounded frame", "Rounded frame around web contents.", default: true,
             help: "A rounded border around web pages."),
        bool("chrome.homeButton", ChromePrefs.showHomeButton, "Show home button", "Home button next to reload (top bar and toolbar).",
             default: false),
        bool("chrome.hideWindowButtons", ChromePrefs.hideWindowButtons, "Hide window buttons with the bar",
             "Window buttons disappear while the bar or sidebar is hidden.", default: true,
             help: "Close, minimize and full-screen hide while the bar or sidebar is hidden."),
        bool("addressBar.centered", ChromePrefs.centeredAddressBar, "Center the address bar", "Center the address field.",
             default: false),
        bool("addressBar.minimalURL", ChromePrefs.minimalURL, "Show only the domain in the address bar",
             "Show just the domain in the address field.", default: true),
        bool("addressBar.loadingProgress", ChromePrefs.addressBarProgress, "Show loading progress in the address bar",
             "Show page loading progress in the address field.", default: true),
        bool("startPage.showShortcuts", StartPagePrefs.showShortcuts, "Show start page shortcuts",
             "Show site tiles under the search bar on the start page.", default: true,
             help: "Your site tiles under the search bar."),
        shortcutsList,
        choice("search.engine", SearchEngine.defaultsKey, "Search engine", "Engine for searches from the address bar and start page.",
               default: SearchEngine.google.rawValue, SearchEngine.allCases.map { ($0.rawValue, $0.title) }),
        bool("search.suggestions", "luma_search_suggestions_enabled", "Show search suggestions",
             "Send typed text to the search engine for suggestions.", default: false,
             help: "Sends what you type in the address bar to the search engine."),
        intChoice("tabs.unloadAfterMinutes", TabHibernator.timeoutDefaultsKey, "Unload inactive tabs",
                  "Free memory by unloading tabs left inactive this long (0 = never).", default: TabHibernator.defaultTimeoutMinutes,
                  [(0, "Never"), (15, "After 15 minutes"), (30, "After 30 minutes"), (60, "After 1 hour"), (120, "After 2 hours")],
                  help: "Frees memory. Tabs playing media or using the camera or microphone stay loaded."),
        int("aiPanel.fontSize", "luma_ai_panel_font_size", "AI panel text size", "Text size in the AI panel, in points.",
            default: 13, 10...24),
        bool("lunaMax.askOnPage", LunaMaxPrefs.askOnPage, "Ask on Page", "Hold ⌘F to ask about the page.", default: true,
             help: "Hold ⌘F, or press ⌘⇧F, to ask about the page you're on."),
        bool("lunaMax.linkPreviews", LunaMaxPrefs.linkPreviews, "Show link previews", "Shift over a link for a summary.", default: true,
             help: "Hover a link and press Shift for a short summary of the page."),
        bool("lunaMax.tidyTitles", LunaMaxPrefs.tidyTitles, "Tidy titles for pinned tabs",
             "Short names for pinned tabs (sends titles to the AI provider).", default: false,
             help: "Gives tabs a short name when you pin them or add them to Favorites."),
        bool("lunaMax.tidyDownloads", LunaMaxPrefs.tidyDownloads, "Tidy downloads",
             "Rename downloaded files (sends file names to the AI provider).", default: false,
             help: "Renames downloaded files so they're easier to find. Undo it in Downloads."),
    ]

    static func setting(_ key: String) -> CustomizableSetting? { all.first { $0.key == key } }

    // MARK: Builders over UserDefaults

    private static func pref(_ key: String, _ defaultsKey: String, _ title: String, _ summary: String,
                             kind: CustomizableSetting.Kind, help: String?, read: @escaping (UserDefaults) -> JSONValue,
                             write: @escaping (UserDefaults, JSONValue) -> Void) -> CustomizableSetting {
        CustomizableSetting(
            key: key, title: title, summary: summary, kind: kind,
            read: { read($0.defaults) },
            write: { write($0.defaults, $1) },
            snapshot: { env in
                let dict: [String: Any] = env.defaults.object(forKey: defaultsKey).map { ["v": $0] } ?? [:]
                return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
            },
            restore: { env, data in
                let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
                if let value = dict?["v"] { env.defaults.set(value, forKey: defaultsKey) } else { env.defaults.removeObject(forKey: defaultsKey) }
            },
            help: help,
            defaultsKey: defaultsKey
        )
    }

    private static func bool(_ key: String, _ defaultsKey: String, _ title: String, _ summary: String,
                             default def: Bool, help: String? = nil) -> CustomizableSetting {
        pref(key, defaultsKey, title, summary, kind: .bool, help: help,
             read: { .bool($0.object(forKey: defaultsKey) == nil ? def : $0.bool(forKey: defaultsKey)) },
             write: { d, v in if case .bool(let b) = v { d.set(b, forKey: defaultsKey) } })
    }

    private static func choice(_ key: String, _ defaultsKey: String, _ title: String, _ summary: String,
                               default def: String, _ options: [(String, String)], help: String? = nil) -> CustomizableSetting {
        pref(key, defaultsKey, title, summary, kind: .choice(options.map { (value: $0.0, title: $0.1) }), help: help,
             read: { d in
                 let raw = d.string(forKey: defaultsKey) ?? def
                 // Stored values the registry doesn't know (e.g. legacy "topTabs") read as their current meaning.
                 if key == "tabs.layout" { return .string(BrowserLayout(stored: raw).rawValue) }
                 return .string(options.contains { $0.0 == raw } ? raw : def)
             },
             write: { d, v in if let s = v.stringValue { d.set(s, forKey: defaultsKey) } })
    }

    private static func int(_ key: String, _ defaultsKey: String, _ title: String, _ summary: String,
                            default def: Int, _ range: ClosedRange<Int>, help: String? = nil) -> CustomizableSetting {
        pref(key, defaultsKey, title, summary, kind: .int(range), help: help,
             read: { .number(Double($0.object(forKey: defaultsKey) == nil ? def : $0.integer(forKey: defaultsKey))) },
             write: { d, v in if let n = v.intValue { d.set(n, forKey: defaultsKey) } })
    }

    private static func intChoice(_ key: String, _ defaultsKey: String, _ title: String, _ summary: String,
                                  default def: Int, _ options: [(Int, String)], help: String? = nil) -> CustomizableSetting {
        pref(key, defaultsKey, title, summary, kind: .intChoice(options.map { (value: $0.0, title: $0.1) }), help: help,
             read: { .number(Double($0.object(forKey: defaultsKey) == nil ? def : $0.integer(forKey: defaultsKey))) },
             write: { d, v in if let n = v.intValue { d.set(n, forKey: defaultsKey) } })
    }

    /// The start page tiles. Existing tiles keep their titles when their URL stays in the list.
    private static let shortcutsList = CustomizableSetting(
        key: "startPage.shortcuts", title: "Start page shortcut tiles",
        summary: "The site tiles on the start page, in order (replaces the list).", kind: .urlList(max: 12),
        read: { env in .array(env.shortcuts.shortcuts.map { .string($0.url.absoluteString) }) },
        write: { env, value in
            guard case .array(let items) = value else { return }
            let existing = env.shortcuts.shortcuts
            let list: [SiteShortcut] = items.compactMap { item in
                guard let url = item.stringValue.flatMap(CustomizableSetting.parseURL) else { return nil }
                if let kept = existing.first(where: { $0.url == url }) { return kept }
                return SiteShortcut(title: url.host.map(SiteShortcut.displayName(forHost:)) ?? url.absoluteString, url: url)
            }
            env.shortcuts.replaceAll(list)
        },
        snapshot: { env in (try? JSONEncoder().encode(env.shortcuts.shortcuts)) ?? Data() },
        restore: { env, data in env.shortcuts.replaceAll((try? JSONDecoder().decode([SiteShortcut].self, from: data)) ?? []) }
    )
}

import Foundation

/// Every browser setting an AI agent may change, with its type, allowed values and the real
/// preference behind it. Agents change Axolotl only through this registry (settings_list /
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
        /// A color as "#RRGGBB".
        case color

        static func == (a: Kind, b: Kind) -> Bool { a.typeName == b.typeName }

        var typeName: String {
            switch self {
            case .bool: return "bool"
            case .choice: return "enum"
            case .int: return "int"
            case .intChoice: return "int-enum"
            case .urlList: return "url-list"
            case .color: return "color"
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
    /// Choice values that come from the user's data (custom search engines), on top of the fixed ones.
    var extraChoices: ((UserDefaults) -> [(value: String, title: String)])? = nil

    /// A choice setting's allowed values in `env`.
    func choices(_ env: CustomizationEnvironment) -> [(value: String, title: String)] {
        guard case .choice(let fixed) = kind else { return [] }
        return fixed + (extraChoices?(env.defaults) ?? [])
    }

    /// Throws unless `value` has this setting's type and is allowed.
    func validate(_ value: JSONValue, env: CustomizationEnvironment = .live) throws {
        func fail(_ why: String) -> AxolotlToolError { .invalidArguments("\(key): \(why)") }
        switch kind {
        case .bool:
            guard case .bool = value else { throw fail("expected true or false.") }
        case .choice:
            let options = choices(env)
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
        case .color:
            guard let s = value.stringValue, ThemeHex.parse(s) != nil else { throw fail("expected a hex color like #3265CB.") }
        }
    }

    /// Value for people: "On", "Dark", "30 minutes", "github.com, news.ycombinator.com".
    func display(_ value: JSONValue, env: CustomizationEnvironment = .live) -> String {
        switch kind {
        case .bool:
            if case .bool(let b) = value { return b ? "On" : "Off" }
        case .choice:
            if let s = value.stringValue { return choices(env).first { $0.value == s }?.title ?? s }
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
        case .color:
            if let v = value.stringValue.flatMap(ThemeHex.parse) { return ThemeHex.format(v) }
        }
        return value.jsonString()
    }

    /// Schema line for settings_list.
    func typeDescription(_ env: CustomizationEnvironment) -> String {
        switch kind {
        case .bool: return "bool"
        case .choice: let o = choices(env); return "enum(" + o.map(\.value).joined(separator: "|") + ")"
        case .int(let r): return "int(\(r.lowerBound)...\(r.upperBound))"
        case .intChoice(let o): return "enum(" + o.map { String($0.value) }.joined(separator: "|") + ")"
        case .urlList(let max): return "list of up to \(max) http(s) URLs"
        case .color: return "color(#RRGGBB)"
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
        choice("appearance.theme", "axolotl_appearance", "Color scheme", "Light, dark or follow the system.", default: "system",
               [("system", "System"), ("light", "Light"), ("dark", "Dark")]),
        bool("appearance.liquidGlass", LiquidGlass.defaultsKey, "Liquid Glass",
             "On: macOS Liquid Glass and translucent materials. Off: Axolotl's solid, opaque surfaces.",
             default: LiquidGlass.defaultValue,
             help: "Off draws Axolotl's own solid surfaces and menus instead of translucent glass."),
        choice("tabs.layout", BrowserLayout.defaultsKey, "Browser layout",
               "sidebar = vertical tabs; compact/dynamic/classic = tabs on top.", default: BrowserLayout.sidebar.rawValue,
               BrowserLayout.allCases.map { ($0.rawValue, $0.title) }),
        LayoutTemplate.setting,
        bool("toolbar.visible", ChromePrefs.showToolbar, "Show toolbar",
             "Sidebar layout: a toolbar row (back, forward, reload, address field, buttons) above the page.", default: false,
             help: "Back, forward, reload and the address field above the page."),
        bool("bookmarksBar.visible", ChromePrefs.showBookmarksBar, "Show bookmarks bar",
             "A row of bookmarks above the page (agents add them for you).", default: false,
             help: "Add pages with ⌘D or Bookmarks → Bookmark This Page in the menu bar."),
        bool("sidebar.visible", "axolotl_sidebar_visible", "Show sidebar", "Sidebar layout: sidebar docked open.", default: true),
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
               default: SearchEngine.google.rawValue, SearchEngine.allCases.map { ($0.rawValue, $0.title) },
               more: { CustomSearchEngine.load($0).map { ($0.selectionValue, $0.name) } }),
        bool("search.suggestions", "axolotl_search_suggestions_enabled", "Show search suggestions",
             "Send typed text to the search engine for suggestions.", default: false,
             help: "Sends what you type in the address bar to the search engine."),
        intChoice("tabs.unloadAfterMinutes", TabHibernator.timeoutDefaultsKey, "Unload inactive tabs",
                  "Free memory by unloading tabs left inactive this long (0 = never).", default: TabHibernator.defaultTimeoutMinutes,
                  [(0, "Never"), (15, "After 15 minutes"), (30, "After 30 minutes"), (60, "After 1 hour"), (120, "After 2 hours")],
                  help: "Frees memory. Tabs playing media or using the camera or microphone stay loaded."),
        bool("privacy.globalPrivacyControl", PrivacyPrefs.globalPrivacyControl, "Send Global Privacy Control signal",
             "Tell sites not to sell or share your data (navigator.globalPrivacyControl, Sec-GPC). Applies to new tabs.",
             default: true, help: "Asks websites not to sell or share your data. Applies to tabs you open from now on."),
        bool("privacy.httpsFirst", PrivacyPrefs.httpsFirst, "Upgrade connections to HTTPS",
             "Try https:// first for typed and clicked http:// pages; offer http if that fails.", default: true,
             help: "Tries a secure connection first and asks before loading a page over http."),
        choice("shields.level", ShieldsPrefs.level, "Trackers & ads blocking",
               "Shields default for sites without their own setting (uBlock Origin Lite's filtering mode).",
               default: ShieldsLevel.standard.rawValue, ShieldsLevel.allCases.map { ($0.rawValue, $0.title) },
               help: "Standard blocks ads and trackers; Aggressive blocks more and may break some sites."),
        bool("shields.blockScripts", ShieldsPrefs.blockScripts, "Block scripts",
             "Turn off JavaScript on sites without their own Shields setting.", default: false,
             help: "Many sites won't work without scripts. Turn it back on for a site from the Shields button."),
        int("reader.fontSize", ReaderPrefs.fontSize, "Reader text size", "Reader view text size, in points.",
            default: 19, ReaderPrefs.fontSizes),
        choice("reader.font", ReaderPrefs.font, "Reader font", "Reader view typeface.",
               default: "serif", [("serif", "Serif"), ("sans", "Sans serif")]),
        choice("reader.theme", ReaderPrefs.theme, "Reader theme", "Reader view colors.",
               default: "light", [("light", "Light"), ("sepia", "Sepia"), ("dark", "Dark")]),
        intChoice("reader.width", ReaderPrefs.width, "Reader width", "Reader view column width, in points.",
                  default: 680, [(560, "Narrow"), (680, "Medium"), (820, "Wide")]),
        int("aiPanel.fontSize", "axolotl_ai_panel_font_size", "AI panel text size", "Text size in the AI panel, in points.",
            default: 13, 10...24),
        bool("axolotlMax.askOnPage", AxolotlMaxPrefs.askOnPage, "Ask on Page", "Hold ⌘F to ask about the page.", default: true,
             help: "Hold ⌘F, or press ⌘⇧F, to ask about the page you're on."),
        bool("axolotlMax.linkPreviews", AxolotlMaxPrefs.linkPreviews, "Show link previews", "Shift over a link for a summary.", default: true,
             help: "Hover a link and press Shift for a short summary of the page."),
        bool("axolotlMax.tidyTitles", AxolotlMaxPrefs.tidyTitles, "Tidy titles for pinned tabs",
             "Short names for pinned tabs (sends titles to the AI provider).", default: false,
             help: "Gives tabs a short name when you pin them or add them to Favorites."),
        bool("axolotlMax.tidyDownloads", AxolotlMaxPrefs.tidyDownloads, "Tidy downloads",
             "Rename downloaded files (sends file names to the AI provider).", default: false,
             help: "Renames downloaded files so they're easier to find. Undo it in Downloads."),
    ] + themeSettings + glassSettings + sitePermissionDefaults

    /// Site settings defaults (`sitePermissions.camera` …); per-site exceptions live in SitePermissionStore.
    private static var sitePermissionDefaults: [CustomizableSetting] {
        SitePermission.allCases.map { p in
            choice(p.registryKey, p.defaultsKey, p.title, "Default for sites without their own setting.",
                   default: p.builtInDefault.rawValue, p.defaultChoices.map { ($0.rawValue, $0.title(for: p)) })
        }
    }

    static func setting(_ key: String) -> CustomizableSetting? { all.first { $0.key == key } }

    // MARK: Theme and Liquid Glass breakdown

    private static var themeSettings: [CustomizableSetting] {
        var out = [themePreset]
        for token in ThemeColorToken.allCases {
            for dark in [false, true] {
                out.append(color(token.registryKey(dark: dark), token.defaultsKey(dark: dark),
                                 "\(token.title) (\(dark ? "dark" : "light"))", token.summary + " \(dark ? "Dark" : "Light") appearance.",
                                 default: ThemePreset.axolotl.color(token).hex(dark: dark)))
            }
        }
        out += [
            choice("appearance.contrast", Theme.contrastKey, "Text contrast", "high = stronger secondary text and borders.",
                   default: "standard", [("standard", "Standard"), ("high", "High")]),
            choice("appearance.density", Theme.densityKey, "Density", "compact = shorter sidebar rows and menus.",
                   default: "regular", [("regular", "Regular"), ("compact", "Compact")]),
            intChoice("appearance.cornerRadius", Theme.radiusKey, "Corner radius", "Roundness of tabs, menus and glass, in percent.",
                      default: 100, [(50, "Square"), (75, "Small"), (100, "Regular"), (125, "Large"), (150, "Extra large")]),
            intChoice("appearance.fontScale", Theme.fontScaleKey, "Interface text size", "Tab, sidebar and menu text, in percent.",
                      default: 100, [(90, "Small"), (100, "Regular"), (110, "Large"), (125, "Extra large")]),
        ]
        return out
    }

    private static var glassSettings: [CustomizableSetting] {
        GlassSurface.allCases.map { surface in
            bool(surface.registryKey, surface.defaultsKey, "Glass: \(surface.title)",
                 "With Liquid Glass on: \(surface.summary) Off = solid. Ignored while appearance.liquidGlass is off.", default: true)
        } + [
            bool("glass.blur", GlassSettings.blurKey, "Glass blur", "On = frosted glass; off = clear glass.", default: true),
            intChoice("glass.tint", GlassSettings.tintKey, "Glass tint", "How much of the theme color shows through glass, percent.",
                      default: 0, [(0, "None"), (15, "Subtle"), (30, "Medium"), (50, "Strong")]),
        ]
    }

    /// Color keys written by a theme preset.
    static var themeColorKeys: [String] {
        ThemeColorToken.allCases.flatMap { t in [t.defaultsKey(dark: false), t.defaultsKey(dark: true)] }
    }

    /// `appearance.themePreset`: reads the preset the colors match (else custom); writing one sets every color.
    /// Its snapshot covers all color keys, so undo (and leaving a layout template) restores them exactly.
    private static let themePreset = CustomizableSetting(
        key: "appearance.themePreset", title: "Theme",
        summary: "Color preset for the whole window (light and dark). Reads custom when the colors were edited one by one "
            + "(set theme.* colors for that).",
        kind: .choice(ThemePreset.allCases.map { (value: $0.rawValue, title: $0.title) }),
        read: { .string(Theme.load($0.defaults).preset?.rawValue ?? ThemePreset.customValue) },
        write: { env, value in
            guard let preset = value.stringValue.flatMap(ThemePreset.init(rawValue:)) else { return }
            for token in ThemeColorToken.allCases {
                for dark in [false, true] {
                    let key = token.defaultsKey(dark: dark)
                    // Axolotl is the default: leave its keys unset.
                    if preset == .axolotl { env.defaults.removeObject(forKey: key) }
                    else { env.defaults.set(ThemeHex.format(preset.color(token).hex(dark: dark)), forKey: key) }
                }
            }
        },
        snapshot: { env in
            let dict = Dictionary(uniqueKeysWithValues: themeColorKeys.compactMap { k in env.defaults.string(forKey: k).map { (k, $0) } })
            return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
        },
        restore: { env, data in
            let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String] ?? [:]
            for k in themeColorKeys { if let v = dict[k] { env.defaults.set(v, forKey: k) } else { env.defaults.removeObject(forKey: k) } }
        },
        help: "Light and dark colors for the window, sidebar, tabs and accent."
    )

    private static func color(_ key: String, _ defaultsKey: String, _ title: String, _ summary: String,
                              default def: UInt32) -> CustomizableSetting {
        pref(key, defaultsKey, title, summary, kind: .color, help: nil,
             read: { .string(ThemeHex.format($0.string(forKey: defaultsKey).flatMap(ThemeHex.parse) ?? def)) },
             write: { d, v in if let n = v.stringValue.flatMap(ThemeHex.parse) { d.set(ThemeHex.format(n), forKey: defaultsKey) } })
    }

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
                               default def: String, _ options: [(String, String)], help: String? = nil,
                               more: ((UserDefaults) -> [(String, String)])? = nil) -> CustomizableSetting {
        var setting = pref(key, defaultsKey, title, summary, kind: .choice(options.map { (value: $0.0, title: $0.1) }), help: help,
             read: { d in
                 let raw = d.string(forKey: defaultsKey) ?? def
                 // Stored values the registry doesn't know (e.g. legacy "topTabs") read as their current meaning.
                 if key == "tabs.layout" { return .string(BrowserLayout(stored: raw).rawValue) }
                 return .string((options + (more?(d) ?? [])).contains { $0.0 == raw } ? raw : def)
             },
             write: { d, v in if let s = v.stringValue { d.set(s, forKey: defaultsKey) } })
        if let more { setting.extraChoices = { more($0).map { (value: $0.0, title: $0.1) } } }
        return setting
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

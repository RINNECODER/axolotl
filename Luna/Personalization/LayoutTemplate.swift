import Foundation

/// A whole-window look applied as one bundle of registry settings (Settings → Appearance → Layout).
/// "Luna" is the user's own setup; any other template saves that setup first and switching back
/// to Luna restores it exactly. Add a case and its `bundle` to offer another template.
enum LayoutTemplate: String, CaseIterable, Identifiable {
    case luna
    case chrome

    static let defaultsKey = "luna_layout_template"
    /// The Luna setup saved when a template is applied: registry key → snapshot.
    static let savedKey = "luna_layout_template_saved"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .luna: return "Luna"
        case .chrome: return "Chrome"
        }
    }

    var summary: String {
        switch self {
        case .luna: return "Your own layout and settings."
        case .chrome: return "Google Chrome's layout: curved tabs on top, toolbar with a pill address bar, bookmarks bar."
        }
    }

    /// Registry settings the template sets, in order. Luna sets none; it restores the saved setup.
    var bundle: [(key: String, value: JSONValue)] {
        switch self {
        case .luna:
            return []
        case .chrome:
            return [
                ("tabs.layout", .string(BrowserLayout.classic.rawValue)),
                ("sidebar.visible", .bool(false)),
                ("toolbar.visible", .bool(true)),
                ("bookmarksBar.visible", .bool(true)),
                ("chrome.autoHide", .bool(false)),
                ("chrome.roundedFrame", .bool(false)),
                ("chrome.homeButton", .bool(true)),
                ("addressBar.centered", .bool(false)),
                ("addressBar.minimalURL", .bool(true)),
                // Chrome draws solid, opaque surfaces and menus.
                ("appearance.liquidGlass", .bool(false)),
            ]
        }
    }

    /// Every key some template sets: what applying one saves and switching back to Luna restores.
    static var managedKeys: [String] {
        var keys: [String] = []
        for template in allCases { for (key, _) in template.bundle where !keys.contains(key) { keys.append(key) } }
        return keys
    }

    static func current(_ defaults: UserDefaults) -> LayoutTemplate {
        defaults.string(forKey: defaultsKey).flatMap(LayoutTemplate.init(rawValue:)) ?? .luna
    }

    /// Applies a template. Leaving Luna saves the managed settings; returning restores them exactly.
    static func apply(_ template: LayoutTemplate, env: CustomizationEnvironment) {
        let defaults = env.defaults
        let current = current(defaults)
        if current == .luna, template != .luna {
            var saved: [String: Data] = [:]
            for key in managedKeys { if let s = CustomizationRegistry.setting(key) { saved[key] = s.snapshot(env) } }
            defaults.set(try? PropertyListSerialization.data(fromPropertyList: saved, format: .binary, options: 0), forKey: savedKey)
        }
        if template == .luna {
            if let data = defaults.data(forKey: savedKey),
               let saved = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Data] {
                for key in managedKeys { if let snap = saved[key] { CustomizationRegistry.setting(key)?.restore(env, snap) } }
            }
            defaults.removeObject(forKey: savedKey)
            defaults.removeObject(forKey: defaultsKey)
            return
        }
        for (key, value) in template.bundle { CustomizationRegistry.setting(key)?.write(env, value) }
        defaults.set(template.rawValue, forKey: defaultsKey)
    }

    /// The `layout.template` registry entry. Its snapshot covers the template, the saved Luna setup and every
    /// managed setting, so undoing a template change (Recent AI changes) restores all of them exactly.
    static let setting = CustomizableSetting(
        key: "layout.template", title: "Layout template",
        summary: "Whole-window look. chrome = Google Chrome's layout (tabs on top, toolbar, bookmarks bar); "
            + "luna = back to the user's own settings, restored exactly.",
        kind: .choice(allCases.map { (value: $0.rawValue, title: $0.title) }),
        read: { .string(current($0.defaults).rawValue) },
        write: { env, value in
            if let raw = value.stringValue, let template = LayoutTemplate(rawValue: raw) { apply(template, env: env) }
        },
        snapshot: { env in
            var dict: [String: Any] = [:]
            if let t = env.defaults.string(forKey: defaultsKey) { dict["template"] = t }
            if let saved = env.defaults.data(forKey: savedKey) { dict["saved"] = saved }
            var keys: [String: Data] = [:]
            for key in managedKeys { if let s = CustomizationRegistry.setting(key) { keys[key] = s.snapshot(env) } }
            dict["keys"] = keys
            return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)) ?? Data()
        },
        restore: { env, data in
            let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] ?? [:]
            for (key, snap) in dict["keys"] as? [String: Data] ?? [:] { CustomizationRegistry.setting(key)?.restore(env, snap) }
            if let t = dict["template"] as? String { env.defaults.set(t, forKey: defaultsKey) } else { env.defaults.removeObject(forKey: defaultsKey) }
            if let s = dict["saved"] as? Data { env.defaults.set(s, forKey: savedKey) } else { env.defaults.removeObject(forKey: savedKey) }
        }
    )
}

import Foundation

// "Customize" in the one-click import: a preview of what a profile holds (nothing
// decrypted) and the per-item choices that narrow one import run.

/// How far back "History" reaches.
nonisolated enum HistoryRange: Int, CaseIterable, Identifiable, Sendable {
    case week = 7, month = 30, quarter = 90, all = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .quarter: return "Last 90 days"
        case .all: return "All history"
        }
    }

    func cutoff(now: Date = Date()) -> Date? {
        self == .all ? nil : now.addingTimeInterval(-Double(rawValue) * 86_400)
    }
}

/// One checkbox row in a picker. `id` is the key a choice is stored under.
nonisolated struct ImportPickItem: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle = ""
    var icon: URL?
    /// Shown greyed out with this reason; never imported.
    var unsupported: String?
}

/// What a source profile holds, read from DB copies without the Safe Storage key.
nonisolated struct ImportPreview: Equatable, Sendable {
    var bookmarks: [ImportedBookmark] = []
    /// Passwords, cookies (by site), extensions and addresses.
    var items: [ImportDataType: [ImportPickItem]] = [:]
}

/// Keys that tie a picker row to the records an import reads.
nonisolated enum ImportPick {
    static func loginKey(_ origin: String, _ username: String) -> String { origin + "\n" + username }

    static func addressKey(_ a: ImportedAutofillAddress) -> String {
        [a.name, a.street, a.city, a.postalCode].joined(separator: "\n")
    }

    /// The registrable domain cookies are grouped by ("mail.google.com" → "google.com").
    /// shortcut: last two labels, three under a generic second level (co.uk, com.au); no public
    /// suffix list, so a few hosts group oddly. Upgrade if users report wrong grouping.
    static func site(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 2, labels.last.map({ Int($0) == nil }) == true else { return labels.joined(separator: ".") }
        let generic: Set<Substring> = ["co", "com", "net", "org", "gov", "edu", "ac"]
        let n = labels.last!.count == 2 && generic.contains(labels[labels.count - 2]) ? 3 : 2
        return labels.suffix(n).joined(separator: ".")
    }

    /// Unique by id, first one wins (the same login can be saved twice).
    static func unique(_ items: [ImportPickItem]) -> [ImportPickItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}

// MARK: Bookmark folders

nonisolated extension ImportedBookmark {
    /// The key for the links at the top level (Chromium's bookmarks bar, Firefox's toolbar).
    static let barKey = ""

    /// A folder is identified by its path of names.
    /// shortcut: same-named sibling folders share a key and are chosen together.
    static func folderKey(_ path: [String]) -> String { path.joined(separator: "\u{1F}") }

    /// True when `key` sits inside one of the `excluded` folders.
    static func isInside(_ key: String, _ excluded: Set<String>) -> Bool {
        excluded.contains { $0 != barKey && key.hasPrefix($0 + "\u{1F}") }
    }

    /// `items` without the excluded folders (and without top-level links when `barKey` is excluded).
    static func excluding(folders excluded: Set<String>, from items: [ImportedBookmark], path: [String] = []) -> [ImportedBookmark] {
        guard !excluded.isEmpty else { return items }
        return items.compactMap { item in
            switch item {
            case .link: return path.isEmpty && excluded.contains(barKey) ? nil : item
            case .folder(let name, let children):
                let p = path + [name]
                guard !excluded.contains(folderKey(p)) else { return nil }
                let kept = excluding(folders: excluded, from: children, path: p)
                return kept.isEmpty ? nil : .folder(name: name, children: kept)
            }
        }
    }

    struct FolderRow: Equatable, Sendable {
        var key: String
        var name: String
        var depth: Int
        var links: Int
    }

    /// Picker rows: the top-level links, then every folder in tree order.
    static func folderRows(_ items: [ImportedBookmark]) -> [FolderRow] {
        var rows: [FolderRow] = []
        let loose = items.filter { if case .link = $0 { return true } else { return false } }.count
        if loose > 0 { rows.append(FolderRow(key: barKey, name: "Links on the bookmarks bar", depth: 0, links: loose)) }
        func walk(_ items: [ImportedBookmark], _ path: [String]) {
            for item in items {
                guard case .folder(let name, let children) = item else { continue }
                rows.append(FolderRow(key: folderKey(path + [name]), name: name, depth: path.count, links: item.linkCount))
                walk(children, path + [name])
            }
        }
        walk(items, [])
        return rows
    }
}

// MARK: Reading and filtering

extension BrowserImporter {
    nonisolated static func preview(kind: BrowserKind, dataFolder: URL, profile: SourceProfile) -> ImportPreview {
        var p = ImportPreview()
        p.bookmarks = read(kind: kind, dataFolder: dataFolder, profile: profile, types: [.bookmarks], since: nil).bookmarks ?? []
        guard kind.engine == .chromium else { return p }
        let folder = profile.id.isEmpty ? dataFolder : dataFolder.appendingPathComponent(profile.id, isDirectory: true)
        let logins = (try? ChromiumSecureImport.loginSites(profileFolder: folder)) ?? []
        p.items[.passwords] = ImportPick.unique(logins.map {
            ImportPickItem(id: ImportPick.loginKey($0.origin, $0.username),
                           title: URL(string: $0.origin)?.host ?? $0.origin, subtitle: $0.username)
        })
        let sites = (try? ChromiumSecureImport.cookieSites(profileFolder: folder)) ?? [:]
        p.items[.cookies] = sites.sorted { $0.key < $1.key }.map {
            ImportPickItem(id: $0.key, title: $0.key, subtitle: ImportDataType.cookies.countText($0.value))
        }
        p.items[.extensions] = ChromiumExtensionImport.scan(profileFolder: folder).map {
            ImportPickItem(id: $0.candidate.id, title: $0.candidate.name, subtitle: $0.candidate.version,
                           icon: $0.candidate.icon, unsupported: $0.unsupported)
        }
        let addresses = (try? ChromiumSecureImport.addresses(profileFolder: folder)) ?? []
        p.items[.autofill] = ImportPick.unique(addresses.map {
            ImportPickItem(id: ImportPick.addressKey($0), title: $0.name.isEmpty ? $0.street : $0.name,
                           subtitle: [$0.city, $0.state].filter { !$0.isEmpty }.joined(separator: ", "))
        })
        return p
    }
}

nonisolated extension BrowserImporter.SecureRead {
    /// Drops what the user unticked in the pickers, keyed as in `ImportPick`.
    func excluding(_ excluded: [ImportDataType: Set<String>]) -> Self {
        var r = self
        if let x = excluded[.passwords], !x.isEmpty { r.logins = logins?.filter { !x.contains(ImportPick.loginKey($0.origin, $0.username)) } }
        if let x = excluded[.cookies], !x.isEmpty { r.cookies = cookies?.filter { !x.contains(ImportPick.site($0.host)) } }
        if let x = excluded[.extensions], !x.isEmpty { r.extensionCandidates = extensionCandidates?.filter { !x.contains($0.id) } }
        if let x = excluded[.autofill], !x.isEmpty { r.addresses = addresses?.filter { !x.contains(ImportPick.addressKey($0)) } }
        return r
    }
}

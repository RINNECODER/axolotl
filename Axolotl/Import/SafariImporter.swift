import Foundation

/// Safari's `~/Library/Safari/Bookmarks.plist`. macOS only lets apps with Full
/// Disk Access read it, so the usual path is Safari's File → Export Bookmarks
/// (an HTML file, parsed by `NetscapeBookmarks`).
nonisolated enum SafariImporter {
    static func bookmarks(safariFolder: URL) throws -> [ImportedBookmark] {
        let file = safariFolder.appendingPathComponent("Bookmarks.plist")
        guard FileManager.default.isReadableFile(atPath: file.path), let data = try? Data(contentsOf: file) else {
            throw ImportError.needsFullDiskAccess
        }
        return try parsePlist(data)
    }

    static func parsePlist(_ data: Data) throws -> [ImportedBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.unreadable("Bookmarks.plist")
        }
        var result: [ImportedBookmark] = []
        for child in root["Children"] as? [[String: Any]] ?? [] {
            let title = child["Title"] as? String ?? ""
            let items = convert(child["Children"] as? [[String: Any]] ?? [])
            if items.isEmpty { continue }
            switch title {
            case "BookmarksBar": result.append(contentsOf: items) // Safari's Favorites bar
            case "BookmarksMenu": result.append(.folder(name: "Bookmarks Menu", children: items))
            case "com.apple.ReadingList": result.append(.folder(name: "Reading List", children: items))
            default:
                if let node = convert([child]).first { result.append(node) }
            }
        }
        return result
    }

    private static func convert(_ nodes: [[String: Any]]) -> [ImportedBookmark] {
        nodes.compactMap { node in
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = importableURL(node["URLString"] as? String ?? "") else { return nil }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String ?? node["Title"] as? String ?? ""
                return .link(title: title, url: url)
            case "WebBookmarkTypeList":
                let kids = convert(node["Children"] as? [[String: Any]] ?? [])
                return kids.isEmpty ? nil : .folder(name: node["Title"] as? String ?? "Folder", children: kids)
            default:
                return nil
            }
        }
    }
}

/// The Netscape bookmark file format every browser exports
/// (`<DT><H3>Folder</H3><DL><p><DT><A HREF="…">Title</A>…</DL><p>`).
nonisolated enum NetscapeBookmarks {
    static func parse(_ html: String) -> [ImportedBookmark] {
        // Stack of open folders; index 0 is the document root.
        var stack: [(name: String, children: [ImportedBookmark])] = [("", [])]
        var pendingFolder: String?
        var openedRoot = false
        var i = html.startIndex

        func closeTop() {
            guard stack.count > 1 else { return }
            let done = stack.removeLast()
            if !done.children.isEmpty {
                stack[stack.count - 1].children.append(.folder(name: done.name.isEmpty ? "Folder" : done.name, children: done.children))
            }
        }

        while let lt = html[i...].firstIndex(of: "<") {
            guard let gt = html[lt...].firstIndex(of: ">") else { break }
            let tag = html[html.index(after: lt)..<gt]
            let lower = tag.lowercased()
            i = html.index(after: gt)

            if lower.hasPrefix("h3") || lower.hasPrefix("h1") {
                let end = html.range(of: "</h", options: .caseInsensitive, range: i..<html.endIndex)?.lowerBound ?? html.endIndex
                let name = decodeEntities(String(html[i..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
                // The <H1> is the document title, not a folder.
                pendingFolder = lower.hasPrefix("h3") ? name : nil
                i = end
            } else if lower.hasPrefix("dl") {
                if let name = pendingFolder {
                    stack.append((name, []))
                    pendingFolder = nil
                } else if openedRoot {
                    stack.append(("", []))
                } else {
                    openedRoot = true
                }
            } else if lower.hasPrefix("/dl") {
                closeTop()
            } else if lower.hasPrefix("a ") || lower == "a" {
                let end = html.range(of: "</a", options: .caseInsensitive, range: i..<html.endIndex)?.lowerBound ?? html.endIndex
                let title = decodeEntities(String(html[i..<end])).trimmingCharacters(in: .whitespacesAndNewlines)
                i = end
                if let href = attribute("href", in: String(tag)), let url = importableURL(decodeEntities(href)) {
                    stack[stack.count - 1].children.append(.link(title: title, url: url))
                }
            }
        }
        while stack.count > 1 { closeTop() }
        return stack[0].children
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\(name)=", options: .caseInsensitive) else { return nil }
        let rest = tag[r.upperBound...]
        guard let quote = rest.first else { return nil }
        if quote == "\"" || quote == "'" {
            let body = rest.dropFirst()
            return String(body.prefix { $0 != quote })
        }
        return String(rest.prefix { !$0.isWhitespace })
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, value) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        // Numeric entities (&#8217; / &#x2019;).
        while let r = out.range(of: "&#[xX]?[0-9a-fA-F]+;", options: .regularExpression) {
            var digits = out[r].dropFirst(2).dropLast()
            var radix = 10
            if digits.first == "x" || digits.first == "X" { digits = digits.dropFirst(); radix = 16 }
            let scalar = UInt32(digits, radix: radix).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ""
            out.replaceSubrange(r, with: scalar)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}

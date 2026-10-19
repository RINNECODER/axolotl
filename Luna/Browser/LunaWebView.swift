// Luna — WKWebView subclass that makes the context menu's download items work and
// adds Chrome's link/image/page items (new tab, real new window, copy image address, print).
import AppKit
import WebKit

/// WebKit's built-in "Download Image", "Download Linked File" and "Download
/// Video/Audio" menu items do nothing unless the app handles them, so Luna
/// retargets them: find what was right-clicked, then start a download for it.
final class LunaWebView: WKWebView {
    /// Called with the URL to download and the page it came from.
    var onDownloadRequest: ((URL) -> Void)?
    /// "Open Link/Image in New Tab" (background tab next to this one).
    var onOpenInNewTab: ((URL) -> Void)?
    /// "Open Link in New Window": a real new browser window.
    var onOpenInNewWindow: ((URL) -> Void)?
    var onPrint: (() -> Void)?

    private enum Target: String {
        case image, link, media
    }

    /// Right-click location in CSS pixels, captured when the menu opens.
    private var menuPoint: CGPoint = .zero

    private static let menuTargets: [String: Target] = [
        "WKMenuItemIdentifierDownloadImage": .image,
        "WKMenuItemIdentifierDownloadLinkedFile": .link,
        "WKMenuItemIdentifierDownloadMedia": .media,
    ]

    /// What Luna does to WebKit's default context menu, as pure data (unit-tested).
    enum MenuEdit: Equatable {
        /// Insert one of Luna's items before / after the WebKit item with this identifier.
        case insert(Command, before: String)
        case insertAfter(Command, after: String)
        /// Rename a WebKit item ("… in New Window" items that WebKit opens as tabs).
        case retitle(String, to: String)
    }

    enum Command: String {
        case openLinkInNewTab = "Open Link in New Tab"
        case openLinkInNewWindow = "Open Link in New Window"
        case copyImageAddress = "Copy Image Address"
        case openImageInNewTab = "Open Image in New Tab"
        case print = "Print…"
    }

    static let openLinkInNewWindowID = "WKMenuItemIdentifierOpenLinkInNewWindow"
    static let openImageInNewWindowID = "WKMenuItemIdentifierOpenImageInNewWindow"
    static let copyImageID = "WKMenuItemIdentifierCopyImage"
    static let reloadID = "WKMenuItemIdentifierReload"

    static func menuEdits(for identifiers: [String]) -> [MenuEdit] {
        var edits: [MenuEdit] = []
        if identifiers.contains(openLinkInNewWindowID) {
            edits.append(.insert(.openLinkInNewTab, before: openLinkInNewWindowID))
        }
        if identifiers.contains(openImageInNewWindowID) {
            edits.append(.retitle(openImageInNewWindowID, to: Command.openImageInNewTab.rawValue))
        }
        if identifiers.contains(copyImageID) {
            edits.append(.insertAfter(.copyImageAddress, after: copyImageID))
        }
        // WebKit opens frames and media "in New Window" as tabs: say so.
        for id in ["WKMenuItemIdentifierOpenFrameInNewWindow", "WKMenuItemIdentifierOpenMediaInNewWindow"] where identifiers.contains(id) {
            edits.append(.retitle(id, to: id.contains("Frame") ? "Open Frame in New Tab" : "Open Video in New Tab"))
        }
        // The page menu (Back, Forward, Reload): add Print.
        if identifiers.contains(reloadID) { edits.append(.insertAfter(.print, after: reloadID)) }
        return edits
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let p = convert(event.locationInWindow, from: nil)
        let scale = max(0.01, pageZoom * magnification)
        menuPoint = CGPoint(x: p.x / scale, y: (isFlipped ? p.y : bounds.height - p.y) / scale)
        for item in menu.items {
            guard let raw = item.identifier?.rawValue else { continue }
            if let target = Self.menuTargets[raw] {
                item.target = self
                item.action = #selector(downloadFromMenu(_:))
                item.representedObject = target.rawValue
            } else if raw == Self.openLinkInNewWindowID {
                item.target = self
                item.action = #selector(runCommand(_:))
                item.representedObject = Command.openLinkInNewWindow.rawValue
            } else if raw == Self.openImageInNewWindowID {
                item.target = self
                item.action = #selector(runCommand(_:))
                item.representedObject = Command.openImageInNewTab.rawValue
            }
        }
        let identifiers = menu.items.compactMap { $0.identifier?.rawValue }
        func index(of id: String) -> Int? { menu.items.firstIndex { $0.identifier?.rawValue == id } }
        for edit in Self.menuEdits(for: identifiers) {
            switch edit {
            case .insert(let command, let before):
                if let i = index(of: before) { menu.insertItem(menuItem(command), at: i) }
            case .insertAfter(let command, let after):
                if let i = index(of: after) { menu.insertItem(menuItem(command), at: i + 1) }
            case .retitle(let id, let title):
                if let i = index(of: id) { menu.items[i].title = title }
            }
        }
    }

    private func menuItem(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: command.rawValue, action: #selector(runCommand(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = command.rawValue
        return item
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = Command(rawValue: raw) else { return }
        switch command {
        case .print:
            onPrint?()
        case .openLinkInNewTab:
            resolve(.link) { [weak self] in self?.onOpenInNewTab?($0) }
        case .openLinkInNewWindow:
            resolve(.link) { [weak self] in self?.onOpenInNewWindow?($0) }
        case .openImageInNewTab:
            resolve(.image) { [weak self] in self?.onOpenInNewTab?($0) }
        case .copyImageAddress:
            resolve(.image) { url in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    @objc private func downloadFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let target = Target(rawValue: raw) else { return }
        resolve(target) { [weak self] in self?.onDownloadRequest?($0) }
    }

    /// Finds the URL of the link, image or media element that was right-clicked.
    private func resolve(_ target: Target, then use: @escaping (URL) -> Void) {
        let script = """
        const el = document.elementFromPoint(x, y);
        if (!el) return null;
        if (kind === "link") { const a = el.closest("a[href]"); return a ? a.href : null; }
        if (kind === "media") { const m = el.closest("video, audio"); return m ? (m.currentSrc || m.src) : null; }
        const img = el.closest("img") || (el.querySelector && el.querySelector("img"));
        if (img) return img.currentSrc || img.src;
        const bg = getComputedStyle(el).backgroundImage.match(/url\\(["']?(.*?)["']?\\)/);
        return bg ? new URL(bg[1], document.baseURI).href : null;
        """
        callAsyncJavaScript(script, arguments: ["x": menuPoint.x, "y": menuPoint.y, "kind": target.rawValue],
                            in: nil, in: .defaultClient) { result in
            guard case .success(let value) = result, let string = value as? String,
                  let url = URL(string: string) else { return }
            use(url)
        }
    }
}

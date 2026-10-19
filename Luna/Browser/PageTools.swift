import AppKit
import UniformTypeIdentifiers
import WebKit

/// Page scripts shared by the context menu and the menu bar.
enum PageScripts {
    /// Toggles Picture in Picture for the video under (`x`, `y`) in CSS pixels, or with `x` null the
    /// first playing video (else the first one). Returns false when there is no video.
    static let pictureInPicture = """
    const videos = [...document.querySelectorAll("video")];
    let v = null;
    if (x !== null) {
      const at = document.elementFromPoint(x, y);
      v = (at && at.closest("video")) || videos.find(e => {
        const r = e.getBoundingClientRect();
        return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
      });
    } else {
      v = videos.find(e => !e.paused) || videos[0];
    }
    if (!v) return false;
    if (document.pictureInPictureElement === v) { await document.exitPictureInPicture(); return true; }
    try { await v.requestPictureInPicture(); }
    catch (e) {
      if (!(v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode("picture-in-picture"))) return false;
      v.webkitSetPresentationMode(v.webkitPresentationMode === "picture-in-picture" ? "inline" : "picture-in-picture");
    }
    return true;
    """
}

/// HTML captured for luna://source tabs, by source tab id (a reopened tab re-requests the page).
/// Dropped when the tab closes; private windows' entries go when the last private window closes.
enum ViewSourceStore {
    static var html: [UUID: (source: String, isPrivate: Bool)] = [:]
}

extension WebViewWrapper {
    /// View → Picture in Picture: the tab's playing video.
    func pictureInPicture(in tabId: UUID) {
        webViewIfLoaded(for: tabId)?.callAsyncJavaScript(PageScripts.pictureInPicture, arguments: ["x": NSNull(), "y": NSNull()],
                                                         in: nil, in: .defaultClient, completionHandler: nil)
    }

    /// The main frame's current DOM as HTML, like Chrome's view-source of the loaded page.
    func pageSource(in tabId: UUID, completion: @escaping (URL, String) -> Void) {
        guard let wv = webViewIfLoaded(for: tabId), let url = wv.url else { return }
        wv.evaluateJavaScript("'<!DOCTYPE html>\\n' + document.documentElement.outerHTML", in: nil, in: .defaultClient) { result in
            if case .success(let html as String) = result { completion(url, html) }
        }
    }

    /// File → Save Page As…: a Web Archive (the default) or a PDF, chosen in the save panel.
    func savePageAs(in tabId: UUID) {
        guard let wv = webViewIfLoaded(for: tabId), wv.url != nil else { return }
        let title = wv.title.flatMap { $0.isEmpty ? nil : $0 } ?? wv.url?.host ?? "Page"
        let base = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = base
        panel.allowedContentTypes = [.webArchive]
        panel.directoryURL = DownloadManager.shared.downloadsDirectory
        let format = SavePanelFormat(panel: panel)
        panel.accessoryView = format.view
        panel.begin { response in
            _ = format  // kept alive while the panel is open
            guard response == .OK, let dest = panel.url else { return }
            let write: (Result<Data, any Error>) -> Void = { result in
                if case .success(let data) = result { try? data.write(to: dest, options: .atomic) }
            }
            if format.isPDF { wv.createPDF(completionHandler: write) } else { wv.createWebArchiveData(completionHandler: write) }
        }
    }
}

/// The save panel's Format pop-up (Web Archive / PDF).
private final class SavePanelFormat: NSObject {
    let view: NSView
    private let popup = NSPopUpButton()
    private weak var panel: NSSavePanel?
    var isPDF: Bool { popup.indexOfSelectedItem == 1 }

    init(panel: NSSavePanel) {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        popup.addItems(withTitles: ["Web Archive", "PDF"])
        let stack = NSStackView(views: [label, popup])
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view = stack
        super.init()
        popup.target = self
        popup.action = #selector(changed)
    }

    @objc private func changed() {
        panel?.allowedContentTypes = [isPDF ? .pdf : .webArchive]
    }
}

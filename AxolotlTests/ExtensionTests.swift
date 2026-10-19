import XCTest
import WebKit
@testable import Axolotl

@MainActor
final class ExtensionTests: XCTestCase {
    private var installed: [ExtensionLibrary.Record] = []

    override func tearDown() {
        installed.forEach { ExtensionLibrary.shared.remove($0) }
        ExtensionLibrary.shared.confirmInstall = ExtensionLibrary.confirmInstallAlert
    }

    func testStoreLinkParsing() {
        XCTAssertEqual(ExtensionLibrary.storeID(in: "https://chromewebstore.google.com/detail/ublock-origin-lite/ddkjiahejlhfcafbddmgiahcphecmpfh?hl=en"),
                       "ddkjiahejlhfcafbddmgiahcphecmpfh")
        XCTAssertNil(ExtensionLibrary.storeID(in: "https://example.com/not-an-extension"))
    }

    func testCRXHeaderIsStripped() {
        let zip = Data("PK\u{03}\u{04}payload".utf8)
        var crx3 = Data("Cr24".utf8)
        crx3.append(contentsOf: [3, 0, 0, 0])          // version 3
        crx3.append(contentsOf: [5, 0, 0, 0])          // header size
        crx3.append(contentsOf: [1, 2, 3, 4, 5])       // header bytes
        crx3.append(zip)
        XCTAssertEqual(ExtensionLibrary.zipPayload(crx3), zip)
        XCTAssertEqual(ExtensionLibrary.zipPayload(zip), zip)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(condition(), "timed out: \(what)")
    }

    func testInstalledContentScriptRunsInAxolotlTabs() async throws {
        // A minimal Manifest V3 extension that marks pages it runs on.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("axolotl-ext-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try """
        {"manifest_version": 3, "name": "Axolotl Test Marker", "version": "1.0",
         "content_scripts": [{"matches": ["https://ext.example.test/*"], "js": ["mark.js"], "run_at": "document_end"}]}
        """.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "document.documentElement.dataset.axolotlExt = 'ran';"
            .write(to: dir.appendingPathComponent("mark.js"), atomically: true, encoding: .utf8)

        ExtensionLibrary.shared.confirmInstall = { _ in true }
        let record = try await ExtensionLibrary.shared.install(from: dir)
        installed.append(record)
        XCTAssertEqual(record.name, "Axolotl Test Marker")

        let session = ProfileSession(profileId: UUID(), dataStore: .nonPersistent(), workspace: WorkspaceStore(persistence: nil))
        // Built-in extensions (uBlock Origin Lite) load too; watch just this one.
        let isLoaded = { session.extensions.loaded.contains { $0.record.id == record.id } }
        try await waitUntil("extension loaded") { isLoaded() }

        let tab = session.tabManager.newTab(url: URL(string: "https://ext.example.test/")!)
        let wv = session.webViewWrapper.ensureWebView(for: tab)
        wv.loadHTMLString("<p>hello</p>", baseURL: URL(string: "https://ext.example.test/")!)
        var marker: String?
        try await waitUntil("content script ran") {
            if !wv.isLoading {
                wv.evaluateJavaScript("document.documentElement.dataset.axolotlExt || ''") { value, _ in marker = value as? String }
            }
            return marker == "ran"
        }

        // Turning it off unloads it.
        ExtensionLibrary.shared.setEnabled(record, false)
        try await waitUntil("extension unloaded") { !isLoaded() }
    }
}

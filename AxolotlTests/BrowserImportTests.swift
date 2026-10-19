import Compression
import SQLite3
import XCTest
@testable import Axolotl

/// Importers run against synthetic fixtures built here in a fake home folder;
/// no real browser data is ever read.
@MainActor
final class BrowserImportTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("import-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: Fixture helpers

    private func dir(_ path: String) throws -> URL {
        let url = home.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func sqlite(_ url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            sqlite3_free(err)
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    /// Gathers an importer's history batches into one array.
    private func collect(_ read: (([ImportedVisit]) -> Void) throws -> Void) rethrows -> [ImportedVisit] {
        var all: [ImportedVisit] = []
        try read { all += $0 }
        return all
    }

    private func titles(_ items: [ImportedBookmark]) -> [String] {
        items.map {
            switch $0 {
            case .link(let t, _): return t
            case .folder(let n, _): return n + "/"
            }
        }
    }

    // MARK: Detection

    func testDetectorFindsBrowsersByFolderOrAppAndReadsProfileNames() throws {
        let chrome = try dir("Library/Application Support/Google/Chrome")
        _ = try dir("Library/Application Support/Google/Chrome/Default")
        _ = try dir("Library/Application Support/Google/Chrome/Profile 2")
        try write(#"{"profile":{"info_cache":{"Profile 2":{"name":"Work"},"Default":{"name":"Personal"},"Profile 9":{"name":"Deleted"}}}}"#,
                  to: chrome.appendingPathComponent("Local State"))
        let firefox = try dir("Library/Application Support/Firefox")
        try write("""
            [Install4F96D1932A9F858E]
            Default=Profiles/abc.default-release

            [Profile1]
            Name=default
            IsRelative=1
            Path=Profiles/xyz.default

            [Profile0]
            Name=default-release
            IsRelative=1
            Path=Profiles/abc.default-release
            """, to: firefox.appendingPathComponent("profiles.ini"))
        let fakeApp = URL(fileURLWithPath: "/Applications/Arc.app")
        let detector = BrowserDetector(home: home) { $0 == "company.thebrowser.Browser" ? fakeApp : nil }

        let found = detector.detect()
        XCTAssertEqual(found.map(\.kind), [.chrome, .arc, .firefox])
        XCTAssertEqual(found[0].profiles.map(\.name), ["Personal", "Work"], "Default first; missing profile folders dropped")
        XCTAssertEqual(found[1].appURL, fakeApp)
        XCTAssertEqual(found[1].profiles, [], "Arc app installed but no data folder")
        XCTAssertEqual(found[2].profiles.map(\.id), ["Profiles/abc.default-release", "Profiles/xyz.default"],
                       "Firefox's install default comes first")
    }

    // MARK: Chromium

    func testChromiumBookmarksAndHistory() throws {
        let profile = try dir("Chrome/Default")
        try write("""
            {"roots":{
              "bookmark_bar":{"type":"folder","name":"Bookmarks bar","children":[
                {"type":"url","name":"Example","url":"https://example.com/"},
                {"type":"folder","name":"Work","children":[
                  {"type":"url","name":"Docs","url":"https://docs.example.com/a"},
                  {"type":"url","name":"Script","url":"javascript:alert(1)"}]},
                {"type":"folder","name":"Empty","children":[]}]},
              "other":{"type":"folder","name":"Other bookmarks","children":[
                {"type":"url","name":"Swift","url":"https://swift.org"}]},
              "synced":{"type":"folder","name":"Mobile bookmarks","children":[]}}}
            """, to: profile.appendingPathComponent("Bookmarks"))

        let bookmarks = try ChromiumImporter.bookmarks(profileFolder: profile)
        XCTAssertEqual(titles(bookmarks), ["Example", "Work/", "Other Bookmarks/"])
        guard case .folder(_, let work) = bookmarks[1] else { return XCTFail() }
        XCTAssertEqual(titles(work), ["Docs"], "non-web URLs are skipped")
        XCTAssertEqual(bookmarks.reduce(0) { $0 + $1.linkCount }, 3)

        let t1 = ChromiumImporter.chromiumTime(from: Date(timeIntervalSince1970: 1_700_000_000))
        let t2 = ChromiumImporter.chromiumTime(from: Date(timeIntervalSince1970: 1_700_000_100))
        try sqlite(profile.appendingPathComponent("History"), """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1,'https://a.example.com/','A',2,\(t2)), (2,'chrome://settings','Settings',1,\(t2));
            INSERT INTO visits VALUES (1,1,\(t1)), (2,1,\(t2)), (3,2,\(t2));
            """)
        let visits = try collect { try ChromiumImporter.history(profileFolder: profile, onBatch: $0) }
        XCTAssertEqual(visits.map(\.date.timeIntervalSince1970), [1_700_000_100, 1_700_000_000])
        XCTAssertEqual(visits.first?.title, "A")

        let newer = try collect { try ChromiumImporter.history(profileFolder: profile, since: Date(timeIntervalSince1970: 1_700_000_050), onBatch: $0) }
        XCTAssertEqual(newer.count, 1, "incremental sync only reads newer visits")
    }

    // MARK: Firefox

    func testFirefoxPlacesBookmarksAndHistory() throws {
        let profile = try dir("Firefox/Profiles/abc.default")
        try sqlite(profile.appendingPathComponent("places.sqlite"), """
            CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
            CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER);
            INSERT INTO moz_places VALUES (1,'https://mozilla.org/','Mozilla'), (2,'https://news.example.com/','News'), (3,'place:sort=8','Recent');
            INSERT INTO moz_bookmarks VALUES
              (1,2,NULL,0,0,'','root________'),
              (2,2,NULL,1,0,'menu','menu________'),
              (3,2,NULL,1,1,'toolbar','toolbar_____'),
              (4,2,NULL,1,2,'tags','tags________'),
              (5,2,NULL,1,3,'unfiled','unfiled_____'),
              (10,1,1,3,0,'Mozilla','a1'),
              (11,2,NULL,3,1,'Reading','a2'),
              (12,1,2,11,0,'News','a3'),
              (13,1,3,2,0,'Recent','a4'),
              (14,1,2,5,0,'News again','a5');
            INSERT INTO moz_historyvisits VALUES (1,1,1700000000000000), (2,2,1700000500000000);
            """)
        let bookmarks = try FirefoxImporter.bookmarks(profileFolder: profile)
        XCTAssertEqual(titles(bookmarks), ["Mozilla", "Reading/", "Other Bookmarks/"],
                       "toolbar items top level; menu with only a place: query is dropped")
        let visits = try collect { try FirefoxImporter.history(profileFolder: profile, onBatch: $0) }
        XCTAssertEqual(visits.map(\.url), ["https://news.example.com/", "https://mozilla.org/"])
        XCTAssertEqual(visits.last?.date, Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Safari / HTML

    func testSafariBookmarksPlist() throws {
        let plist: [String: Any] = ["Children": [
            ["Title": "BookmarksBar", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.com", "URIDictionary": ["title": "Apple"]],
            ]],
            ["Title": "BookmarksMenu", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                ["Title": "Dev", "WebBookmarkType": "WebBookmarkTypeList", "Children": [
                    ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://developer.apple.com", "URIDictionary": ["title": "Developer"]],
                ]],
            ]],
            ["Title": "com.apple.ReadingList", "WebBookmarkType": "WebBookmarkTypeList", "Children": []],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        let bookmarks = try SafariImporter.parsePlist(data)
        XCTAssertEqual(titles(bookmarks), ["Apple", "Bookmarks Menu/"])
        guard case .folder(_, let menu) = bookmarks[1], case .folder(let dev, let items) = menu.first else { return XCTFail() }
        XCTAssertEqual(dev, "Dev")
        XCTAssertEqual(titles(items), ["Developer"])
        XCTAssertThrowsError(try SafariImporter.bookmarks(safariFolder: home)) {
            XCTAssertEqual($0 as? ImportError, .needsFullDiskAccess)
        }
    }

    func testNetscapeHTMLParser() {
        let html = """
            <!DOCTYPE NETSCAPE-Bookmark-file-1>
            <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
            <TITLE>Bookmarks</TITLE>
            <H1>Bookmarks</H1>
            <DL><p>
                <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Favorites</H3>
                <DL><p>
                    <DT><A HREF="https://example.com/?a=1&amp;b=2" ADD_DATE="1">Tom &amp; Jerry&#8217;s</A>
                    <DT><H3>Nested</H3>
                    <DL><p>
                        <DT><a href='https://nested.example.com'>Deep</a>
                    </DL><p>
                    <DT><H3>Empty</H3>
                    <DL><p>
                    </DL><p>
                </DL><p>
                <DT><A HREF="https://top.example.com">Top</A>
                <DT><A HREF="file:///etc/passwd">Local</A>
            </DL><p>
            """
        let items = NetscapeBookmarks.parse(html)
        XCTAssertEqual(titles(items), ["Favorites/", "Top"])
        guard case .folder(_, let fav) = items[0] else { return XCTFail() }
        XCTAssertEqual(fav.first, .link(title: "Tom & Jerry\u{2019}s", url: URL(string: "https://example.com/?a=1&b=2")!))
        XCTAssertEqual(titles(fav), ["Tom & Jerry\u{2019}s", "Nested/"])
    }

    // MARK: Merge + dedupe

    private func tempStore() -> BookmarkStore {
        BookmarkStore(fileURL: home.appendingPathComponent("bookmarks-\(UUID().uuidString).json"))
    }

    func testImportGoesToBookmarkStoreNotTabsAndReimportAddsOnlyNewOnes() {
        let store = tempStore(), profile = UUID()
        let first: [ImportedBookmark] = [
            .link(title: "A", url: URL(string: "https://a.com/")!),
            .folder(name: "Work", children: [.link(title: "B", url: URL(string: "https://b.com")!)]),
        ]
        XCTAssertEqual(BrowserImporter.applyBookmarks(first, folderName: "Imported from Brave", axolotlProfileId: profile, store: store), 2)
        XCTAssertEqual(store.children(of: nil).map(\.title), ["A", "Work"], "an empty bar takes the import directly")
        XCTAssertNil(WorkspacePersistence.forProfile(profile).load(), "no workspace (tabs) written")

        // Same data again (trailing slash / fragment differences), plus one new link in Work.
        let second: [ImportedBookmark] = [
            .link(title: "A", url: URL(string: "https://A.com#top")!),
            .folder(name: "Work", children: [
                .link(title: "B", url: URL(string: "https://b.com/")!),
                .link(title: "C", url: URL(string: "https://c.com")!),
            ]),
        ]
        XCTAssertEqual(BrowserImporter.applyBookmarks(second, folderName: "Imported from Brave", axolotlProfileId: profile, store: store), 1)
        guard let folder = store.children(of: nil).first(where: { $0.title == "Imported from Brave" }) else { return XCTFail() }
        XCTAssertEqual(store.children(of: store.children(of: folder.id).first { $0.title == "Work" }?.id).map(\.title), ["C"])
        XCTAssertEqual(store.bookmarks.count, 3)
        XCTAssertEqual(store.addImported(second), 0, "nothing new: no empty folders created")
        XCTAssertEqual(store.folders.count, 3)
    }

    func testLegacyImportFolderMovesToBookmarksAndLeavesNoTabs() {
        var ws = Workspace()
        let tabA = Tab(url: URL(string: "https://a.com")!, title: "A", savedURL: URL(string: "https://a.com")!)
        let tabB = Tab(url: URL(string: "https://b.com/page")!, title: "B", savedURL: URL(string: "https://b.com")!)
        ws.tabs[tabA.id] = tabA
        ws.tabs[tabB.id] = tabB
        let inner = Folder(name: "Work", isExpanded: false, children: [.tab(tabB.id)])
        let old = Folder(name: "Imported from Brave", isExpanded: false, children: [.tab(tabA.id), .folder(inner)])
        ws.insertNode(.folder(old), at: NodeLocation(spaceId: ws.activeSpaceId, section: .pinned, parentFolderId: nil, index: 0))
        let tabsBefore = ws.tabs.count

        let moved = ws.takeImportedFolder(old.id)
        XCTAssertEqual(moved, [.link(title: "A", url: URL(string: "https://a.com")!),
                               .folder(name: "Work", children: [.link(title: "B", url: URL(string: "https://b.com")!)])],
                       "saved bookmark URL wins over where the tab navigated")
        XCTAssertNil(ws.node(withId: old.id))
        XCTAssertEqual(ws.tabs.count, tabsBefore - 2)
        XCTAssertEqual(ws.integrityProblems(), [])
        XCTAssertNil(ws.takeImportedFolder(old.id), "runs once")

        let store = tempStore()
        store.addImported([.folder(name: "Imported from Brave", children: moved ?? [])])
        XCTAssertEqual(Set(store.bookmarks.map(\.title)), ["A", "B"])
    }

    func testPreferredBrowserIsDefaultThenMostRecent() {
        func b(_ k: BrowserKind) -> DetectedBrowser { DetectedBrowser(kind: k, dataFolder: home, appURL: nil, profiles: []) }
        let found = [b(.chrome), b(.brave), b(.firefox)]
        let dates: [BrowserKind: Date] = [.chrome: Date(timeIntervalSince1970: 1), .firefox: Date(timeIntervalSince1970: 5)]
        XCTAssertEqual(BrowserDetector.preferred(found, defaultBundleID: "com.brave.Browser", lastUsed: { dates[$0.kind] }), .brave)
        XCTAssertEqual(BrowserDetector.preferred(found, defaultBundleID: "app.axolotl", lastUsed: { dates[$0.kind] }), .firefox)
        XCTAssertEqual(BrowserDetector.preferred(found, defaultBundleID: nil, lastUsed: { _ in nil }), .chrome)
        XCTAssertNil(BrowserDetector.preferred([], defaultBundleID: nil, lastUsed: { _ in nil }))
    }

    func testImportReportTextAndSkippedReasons() {
        var r = BrowserImporter.Report()
        r.add(BrowserImporter.Summary(bookmarks: 1204, history: nil), requested: [.bookmarks, .history])
        var sec = BrowserImporter.SecureSummary(extensionsImported: 3, extensionsFailed: 1, addresses: 0, keychainUnavailable: true)
        sec.vaultLocked = true
        r.add(sec, requested: [.cookies, .passwords, .extensions, .autofill], browserName: "Brave")
        XCTAssertTrue(r.text.hasPrefix("Imported "), r.text)
        XCTAssertTrue(r.text.contains("1,204 bookmarks") && r.text.contains("3 extensions"), r.text)
        XCTAssertFalse(r.text.contains("address"), "zero counts stay out of the summary")
        XCTAssertEqual(r.skipped[.passwords], "Keychain access to Brave Safe Storage wasn't allowed.")
        XCTAssertEqual(r.skipped[.cookies], r.skipped[.passwords])
        XCTAssertEqual(r.skipped[.history], "Couldn't read them from this profile.")
        XCTAssertEqual(r.skipped[.extensions], "1 can't run in Axolotl yet.")
        XCTAssertEqual(r.counts[.autofill], 0)
        XCTAssertEqual(BrowserImporter.Report().text, "Everything is already up to date.")

        var declined = BrowserImporter.Report()
        var s2 = BrowserImporter.SecureSummary()
        s2.extensionsDeclined = true
        declined.add(s2, requested: [.extensions], browserName: "Brave")
        XCTAssertEqual(declined.skipped[.extensions], "You chose not to add them.")
    }

    func testImportedHistoryDedupesAndKeepsNewestFirst() {
        let profile = UUID()
        defer {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Axolotl/Profiles/\(profile.uuidString)")
            try? FileManager.default.removeItem(at: dir)
        }
        let history = HistoryManager(profileId: profile)
        let visits = [
            ImportedVisit(url: "https://a.com/", title: "A", date: Date(timeIntervalSince1970: 100)),
            ImportedVisit(url: "https://b.com/", title: "B", date: Date(timeIntervalSince1970: 300)),
            ImportedVisit(url: "https://a.com/", title: "A", date: Date(timeIntervalSince1970: 200)),
        ]
        XCTAssertEqual(history.importVisits(visits), 3)
        XCTAssertEqual(history.importVisits(visits + [ImportedVisit(url: "https://c.com/", title: "C", date: Date(timeIntervalSince1970: 250))]), 1)
        XCTAssertEqual(history.historyEvents.map(\.timestamp.timeIntervalSince1970), [300, 250, 200, 100])
    }

    func testReadUsesTheSelectedProfileFolder() throws {
        let data = try dir("Library/Application Support/BraveSoftware/Brave-Browser")
        let p1 = try dir("Library/Application Support/BraveSoftware/Brave-Browser/Profile 1")
        try write(#"{"roots":{"bookmark_bar":{"children":[{"type":"url","name":"P1","url":"https://p1.example"}]}}}"#,
                  to: p1.appendingPathComponent("Bookmarks"))
        let r = BrowserImporter.read(kind: .brave, dataFolder: data, profile: SourceProfile(id: "Profile 1", name: "Work"),
                                     types: [.bookmarks, .history], since: nil)
        XCTAssertEqual(r.bookmarks.map(titles), ["P1"])
        XCTAssertEqual(r.visitsRead, 0, "missing History file is just empty")
        XCTAssertEqual(r.errors, [])
        XCTAssertEqual(BrowserImporter.folderName(.brave, SourceProfile(id: "Profile 1", name: "Work"), profileCount: 2),
                       "Imported from Brave (Work)")
    }

    // MARK: 1Password

    /// A one-entry zip (stored or raw-deflate), like 1Password's .1pux.
    private func makeZip(_ name: String, _ payload: Data, deflate: Bool) -> Data {
        var body = payload
        if deflate {
            var out = [UInt8](repeating: 0, count: payload.count + 1024)
            let n = payload.withUnsafeBytes { src in
                compression_encode_buffer(&out, out.count, src.bindMemory(to: UInt8.self).baseAddress!, payload.count, nil, COMPRESSION_ZLIB)
            }
            body = Data(out.prefix(n))
        }
        var d = Data()
        func le(_ v: Int, _ bytes: Int) { for i in 0..<bytes { d.append(UInt8((v >> (8 * i)) & 0xff)) } }
        let nameBytes = Data(name.utf8), method = deflate ? 8 : 0
        // Local header
        le(0x04034b50, 4); le(20, 2); le(0, 2); le(method, 2); le(0, 4); le(0, 4)
        le(body.count, 4); le(payload.count, 4); le(nameBytes.count, 2); le(0, 2)
        d.append(nameBytes); d.append(body)
        let central = d.count
        le(0x02014b50, 4); le(20, 2); le(20, 2); le(0, 2); le(method, 2); le(0, 4); le(0, 4)
        le(body.count, 4); le(payload.count, 4); le(nameBytes.count, 2); le(0, 2); le(0, 2); le(0, 2); le(0, 2); le(0, 4); le(0, 4)
        d.append(nameBytes)
        let centralSize = d.count - central
        le(0x06054b50, 4); le(0, 2); le(0, 2); le(1, 2); le(1, 2); le(centralSize, 4); le(central, 4); le(0, 2)
        return d
    }

    private let exportData = """
        {"accounts":[{"attrs":{"name":"Fixture"},"vaults":[{"attrs":{"name":"Private"},"items":[
          {"uuid":"1","state":"active","categoryUuid":"001",
           "overview":{"title":"Example","url":"https://example.com/login","urls":[{"url":"https://example.com/login"}]},
           "details":{"loginFields":[{"designation":"username","value":"fixture-user"},{"designation":"password","value":"fixture-pass"}],
                      "notesPlain":"","sections":[{"fields":[{"title":"one-time password","value":{"totp":"otpauth://totp/x?secret=AAAA"}}]}]}},
          {"uuid":"2","state":"active","categoryUuid":"001",
           "overview":{"title":"Second","urls":[{"url":"second.example.org"}]},
           "details":{"loginFields":[{"designation":"password","value":"p2"}]}},
          {"uuid":"3","state":"archived","categoryUuid":"001","overview":{"url":"https://old.example"},"details":{"loginFields":[{"designation":"password","value":"x"}]}},
          {"uuid":"4","state":"active","categoryUuid":"002","overview":{"title":"Card"},"details":{}},
          {"uuid":"5","state":"active","categoryUuid":"001","overview":{"title":"No site"},"details":{"loginFields":[{"designation":"password","value":"x"}]}}
        ]}]}]}
        """

    func testOnePassword1PUXStoredAndDeflated() throws {
        for deflate in [false, true] {
            let file = home.appendingPathComponent("export-\(deflate).1pux")
            try makeZip("export.data", Data(exportData.utf8), deflate: deflate).write(to: file)
            let r = try OnePasswordImporter.parse1PUX(at: file)
            XCTAssertEqual(r.logins.map(\.url), ["https://example.com/login", "second.example.org"], "deflate=\(deflate)")
            XCTAssertEqual(r.logins.first?.username, "fixture-user")
            XCTAssertEqual(r.logins.first?.password, "fixture-pass")
            XCTAssertNotNil(r.logins.first?.totp)
            XCTAssertEqual(r.droppedExtras, 1)
            XCTAssertEqual(r.skippedOtherItems, 1)
            XCTAssertEqual(r.skippedIncomplete, 1)
        }
        let notZip = home.appendingPathComponent("bad.1pux")
        try Data("not a zip".utf8).write(to: notZip)
        XCTAssertThrowsError(try OnePasswordImporter.parse1PUX(at: notZip))
    }

    func testZipReaderRejectsHostileHeadersWithoutCrashing() throws {
        let zip = makeZip("export.data", Data(exportData.utf8), deflate: true)
        let central = zip.count - 22 - (46 + "export.data".utf8.count)
        func patched(_ offset: Int, _ value: UInt32) -> Data {
            var d = zip
            for i in 0..<4 { d[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xff) }
            return d
        }
        XCTAssertNotNil(try ZipReader.entry(named: "export.data", in: zip))
        XCTAssertThrowsError(try ZipReader.entry(named: "export.data", in: patched(central + 24, 0xFFFF_FFFF)), "4 GB claimed size")
        XCTAssertThrowsError(try ZipReader.entry(named: "export.data", in: patched(central + 20, 0)), "empty deflate body")
        XCTAssertThrowsError(try ZipReader.entry(named: "export.data", in: patched(central + 20, 0xFFFF_FFFF)), "body past the end")
        XCTAssertThrowsError(try ZipReader.entry(named: "export.data", in: patched(central + 42, 0xFFFF_FFF0)), "local header past the end")
        XCTAssertThrowsError(try ZipReader.entry(named: "export.data", in: patched(zip.count - 6, 0xFFFF_FFFF)), "central directory past the end")
        // Every truncation and every single-byte corruption either throws or returns; none may crash.
        for n in 0..<zip.count { _ = try? ZipReader.entry(named: "export.data", in: zip.prefix(n)) }
        for i in 0..<zip.count {
            var d = zip
            d[i] ^= 0xFF
            _ = try? ZipReader.entry(named: "export.data", in: d)
        }
    }

    func testSQLiteSnapshotRemovesItsTempCopy() throws {
        let tmp = FileManager.default.temporaryDirectory
        func snapshots() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: tmp.path))?.filter { $0.hasPrefix("axolotl-import-") } ?? [])
        }
        let before = snapshots()
        let db = home.appendingPathComponent("t.sqlite")
        try sqlite(db, "CREATE TABLE t(x INTEGER); INSERT INTO t VALUES (1);")
        do {
            let snap = try SQLiteSnapshot(copying: db)
            XCTAssertEqual(try snap.rows("SELECT x FROM t").first?.first?.int, 1)
            XCTAssertFalse(snapshots().subtracting(before).isEmpty, "reads a private copy")
        }
        XCTAssertEqual(snapshots().subtracting(before), [], "copy removed once the snapshot is released")

        try Data("not sqlite".utf8).write(to: db)
        _ = try? SQLiteSnapshot(copying: db).rows("SELECT 1 FROM t")
        XCTAssertEqual(snapshots().subtracting(before), [], "removed on failure too")
    }

    func testChromiumHistoryLimitCountsOnlyWebVisits() throws {
        let profile = try dir("Chrome/Default")
        let t1 = ChromiumImporter.chromiumTime(from: Date(timeIntervalSince1970: 1_700_000_000))
        let t2 = ChromiumImporter.chromiumTime(from: Date(timeIntervalSince1970: 1_700_000_100))
        try sqlite(profile.appendingPathComponent("History"), """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1,'https://a.example.com/','A'), (2,'chrome://settings','Settings');
            INSERT INTO visits VALUES (1,1,\(t1)), (2,2,\(t2));
            """)
        XCTAssertEqual(try collect { try ChromiumImporter.history(profileFolder: profile, limit: 1, onBatch: $0) }.map(\.url), ["https://a.example.com/"])
    }

    func testChromiumHistoryPagesInBatchesAcrossEqualTimestamps() throws {
        let profile = try dir("Chrome/Paged")
        let t = ChromiumImporter.chromiumTime(from: Date(timeIntervalSince1970: 1_700_000_000))
        // 7 visits, three sharing one timestamp, so the keyset cursor must break ties by id.
        let visits = (1...7).map { "(\($0),1,\(t + Int64($0 <= 3 ? 0 : $0)))" }.joined(separator: ",")
        try sqlite(profile.appendingPathComponent("History"), """
            CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);
            CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER);
            INSERT INTO urls VALUES (1,'https://a.example.com/','A');
            INSERT INTO visits VALUES \(visits);
            """)
        var sizes: [Int] = []
        try ChromiumImporter.history(profileFolder: profile, batchSize: 2) { sizes.append($0.count) }
        XCTAssertEqual(sizes, [2, 2, 2, 1])
        var capped: [Int] = []
        try ChromiumImporter.history(profileFolder: profile, limit: 5, batchSize: 2) { capped.append($0.count) }
        XCTAssertEqual(capped, [2, 2, 1])
    }

    func testKeepInSyncSkipsBookmarksAlreadyImportedOnce() {
        let a = URL(string: "https://a.example/")!, b = URL(string: "https://b.example")!, c = URL(string: "https://c.example")!
        let first: [ImportedBookmark] = [.link(title: "A", url: a), .folder(name: "F", children: [.link(title: "B", url: b)])]
        let imported = ImportedBookmark.keys(first)
        XCTAssertEqual(imported.count, 2)
        // The user deleted A and B in Axolotl; the source still has them plus a new C.
        let later = first + [.link(title: "C", url: c)]
        XCTAssertEqual(ImportedBookmark.removing(imported, from: later), [.link(title: "C", url: c)], "empty folders dropped too")

        let store = tempStore()
        XCTAssertEqual(store.addImported([.folder(name: "Imported", children: ImportedBookmark.removing(imported, from: first))]), 0)
        XCTAssertTrue(store.items.isEmpty, "a deleted import folder is not recreated empty")
    }

    func testOnePasswordCSVAndVaultCSVRoundTrip() {
        let csv = "Title,Url,Username,Password,OTPAuth,Favorite,Archived,Tags,Notes\n" +
            "Example,https://example.com,me,\"pa,ss\",,false,false,,note\n" +
            "Old,https://old.example,me,x,,false,true,,\n" +
            "Empty,,me,x,,false,false,,\n"
        let r = OnePasswordImporter.parseCSV(csv)
        XCTAssertEqual(r.logins.count, 1)
        XCTAssertEqual(r.skippedIncomplete, 1)
        XCTAssertEqual(r.droppedExtras, 1)
        let rows = PasswordVault.parseCSV(OnePasswordImporter.vaultCSV(r.logins))
        XCTAssertEqual(rows, [["url", "username", "password"], ["https://example.com", "me", "pa,ss"]])
    }

    // MARK: Chromium secure (cookies, passwords, extensions, autofill)

    private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testChromiumV10DecryptWithAndWithoutHostHashPrefix() throws {
        let key = ChromiumCrypto.deriveKey(password: "s3cret")
        // Round-trips through the real encrypt/decrypt path.
        let plain = Data("session-token-123".utf8)
        let noPrefix = ChromiumCrypto.encrypt(plain, key: key)
        XCTAssertEqual(try ChromiumCrypto.decrypt(noPrefix, key: key), plain)
        // Newer cookie DBs prepend a 32-byte SHA256(host); decrypt must strip it.
        let withHash = ChromiumCrypto.encrypt(plain, key: key, hostHashPrefix: Data(repeating: 7, count: 32))
        XCTAssertEqual(try ChromiumCrypto.decrypt(withHash, key: key, stripHostHash: true), plain)
        // Wrong prefix flag or non-v10 values don't crash.
        XCTAssertThrowsError(try ChromiumCrypto.decrypt(Data("plain".utf8), key: key))
    }

    func testChromiumTimeConversion() {
        // 13324608000000000 µs since 1601-01-01 == 2023-01-02 is not needed; verify a known epoch.
        let unix = Date(timeIntervalSince1970: 1_700_000_000)
        let chromium = ChromiumImporter.chromiumTime(from: unix)
        XCTAssertEqual(chromium, (1_700_000_000 + 11_644_473_600) * 1_000_000)
        XCTAssertEqual(ChromiumImporter.date(fromChromium: chromium).timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
    }

    func testChromiumCookiesSkipExpiredAndStripHashPrefix() throws {
        let profile = try dir("Brave/Default/Network")
        let key = ChromiumCrypto.deriveKey(password: "pw")
        func enc(_ s: String) -> String { hex(ChromiumCrypto.encrypt(Data(s.utf8), key: key, hostHashPrefix: Data(repeating: 0, count: 32))) }
        let future = ChromiumImporter.chromiumTime(from: Date().addingTimeInterval(86_400))
        let past = ChromiumImporter.chromiumTime(from: Date().addingTimeInterval(-86_400))
        try sqlite(profile.appendingPathComponent("Cookies"), """
            CREATE TABLE meta(key TEXT, value TEXT); INSERT INTO meta VALUES('version','24');
            CREATE TABLE cookies(host_key TEXT,name TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER,is_secure INTEGER,is_httponly INTEGER,samesite INTEGER);
            INSERT INTO cookies VALUES ('.example.com','sid',x'\(enc("good"))','/',\(future),1,1,1);
            INSERT INTO cookies VALUES ('example.com','old',x'\(enc("stale"))','/',\(past),0,0,0);
            INSERT INTO cookies VALUES ('example.com','sess',x'\(enc("temp"))','/',0,0,0,-1);
            """)
        let cookies = try ChromiumSecureImport.cookies(profileFolder: try dir("Brave/Default"), key: key)
        XCTAssertEqual(cookies.count, 1, "expired and session cookies are skipped")
        XCTAssertEqual(cookies.first?.name, "sid")
        XCTAssertEqual(cookies.first?.value, "good")
        XCTAssertTrue(cookies.first?.isSecure == true && cookies.first?.isHTTPOnly == true)
    }

    func testChromiumLoginsMappingAndCSV() throws {
        let profile = try dir("Chrome/Default")
        let key = ChromiumCrypto.deriveKey(password: "pw")
        func enc(_ s: String) -> String { hex(ChromiumCrypto.encrypt(Data(s.utf8), key: key)) }
        try sqlite(profile.appendingPathComponent("Login Data"), """
            CREATE TABLE logins(origin_url TEXT, username_value TEXT, password_value BLOB);
            INSERT INTO logins VALUES ('https://example.com/login','me',x'\(enc("hunter2"))');
            INSERT INTO logins VALUES ('https://example.com/login','me',x'\(enc("hunter2"))');
            INSERT INTO logins VALUES ('','x',x'\(enc("y"))');
            """)
        let logins = try ChromiumSecureImport.logins(profileFolder: profile, key: key)
        XCTAssertEqual(logins.count, 2, "rows with an empty origin are dropped")
        XCTAssertEqual(logins.first?.origin, "https://example.com/login")
        XCTAssertEqual(logins.first?.password, "hunter2")
        // The CSV feeds the vault's existing (origin, username) dedupe.
        let rows = PasswordVault.parseCSV(BrowserImporter.loginsCSV(logins))
        XCTAssertEqual(rows.first, ["url", "username", "password"])
        XCTAssertEqual(rows.dropFirst().map { $0[0] }, ["https://example.com/login", "https://example.com/login"])
    }

    func testChromiumExtensionFilterSkipsComponentThemeAndUBOL() {
        func m(_ name: String, theme: Bool = false) -> [String: Any] {
            theme ? ["name": name, "theme": ["colors": [:]]] : ["name": name]
        }
        XCTAssertTrue(ChromiumExtensionImport.shouldImport(manifest: m("Dark Reader"), id: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
        XCTAssertFalse(ChromiumExtensionImport.shouldImport(manifest: m("My Theme", theme: true), id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertFalse(ChromiumExtensionImport.shouldImport(manifest: m("Chrome PDF"), id: "mhjfbmdgcfjbbpaeojofohoefgiehjai"))
        XCTAssertFalse(ChromiumExtensionImport.shouldImport(manifest: m("uBlock Origin Lite"), id: "ddkjiahejlhfcafbddmgiahcphecmpfh"))
    }

    func testChromiumAutofillUnknownSchemaSkipped() throws {
        let profile = try dir("Chrome/Default")
        try sqlite(profile.appendingPathComponent("Web Data"), "CREATE TABLE something_else(x INTEGER);")
        XCTAssertEqual(try ChromiumSecureImport.addresses(profileFolder: profile), [])
    }

    func testChromiumAutofillLegacySchema() throws {
        let profile = try dir("Chrome/Default")
        try sqlite(profile.appendingPathComponent("Web Data"), """
            CREATE TABLE autofill_profiles(guid TEXT, company_name TEXT, street_address TEXT, city TEXT, state TEXT, zipcode TEXT, country_code TEXT);
            CREATE TABLE autofill_profile_names(guid TEXT, first_name TEXT, last_name TEXT);
            CREATE TABLE autofill_profile_emails(guid TEXT, email TEXT);
            CREATE TABLE autofill_profile_phones(guid TEXT, number TEXT);
            INSERT INTO autofill_profiles VALUES ('g1','Acme','1 Main St','Reno','NV','89501','US');
            INSERT INTO autofill_profile_names VALUES ('g1','Ada','Lovelace');
            INSERT INTO autofill_profile_emails VALUES ('g1','ada@example.com');
            INSERT INTO autofill_profile_phones VALUES ('g1','555-1212');
            """)
        let addrs = try ChromiumSecureImport.addresses(profileFolder: profile)
        XCTAssertEqual(addrs.count, 1)
        XCTAssertEqual(addrs.first?.name, "Ada Lovelace")
        XCTAssertEqual(addrs.first?.city, "Reno")
        XCTAssertEqual(addrs.first?.email, "ada@example.com")
        XCTAssertEqual(addrs.first?.phone, "555-1212")
    }

    func testReadSecureReportsKeychainUnavailable() {
        let read = BrowserImporter.readSecure(kind: .brave, dataFolder: home, profile: .init(id: "Default", name: "Default"),
                                              types: [.cookies, .passwords], keyProvider: { _ in nil })
        XCTAssertTrue(read.keychainUnavailable)
        XCTAssertNil(read.cookies)
    }
}

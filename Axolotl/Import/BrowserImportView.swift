import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// State for the import sheet / Settings → Import pane.
final class BrowserImportModel: ObservableObject {
    @Published var browsers: [DetectedBrowser] = []
    @Published var selectedKind: BrowserKind?
    @Published var profileId: String = ""
    /// Everything, unless the user narrows it under Customize.
    @Published var types: Set<ImportDataType> = Set(ImportDataType.allCases)
    /// The system default browser, when it's one of `browsers`.
    @Published var defaultKind: BrowserKind?
    /// Types the running/last import asked for, in display order, and what came of each.
    @Published var requested: [ImportDataType] = []
    @Published var report: BrowserImporter.Report?
    @Published var keepInSync = false
    @Published var running = false
    @Published var summary: String?
    @Published var error: String?
    @Published var accessChanged = 0
    @Published var onePasswordSelected = false
    /// What the selected profile holds (read under Customize) and what the user unticked, by `ImportPick` key.
    /// Both apply to the next run only.
    @Published var preview: ImportPreview?
    @Published var scanning = false
    @Published var excluded: [ImportDataType: Set<String>] = [:]
    @Published var historyRange = HistoryRange(rawValue: UserDefaults.standard.integer(forKey: BrowserImportModel.historyRangeKey)) ?? .all {
        didSet { UserDefaults.standard.set(historyRange.rawValue, forKey: Self.historyRangeKey) }
    }
    static let historyRangeKey = "browserImport.historyRange"

    nonisolated deinit {}

    var isFixtureMode: Bool {
        #if DEBUG
        return BrowserImporter.fixtureHome != nil
        #else
        return false
        #endif
    }

    private var detector: BrowserDetector {
        #if DEBUG
        if let home = BrowserImporter.fixtureHome { return BrowserDetector(home: home) }
        #endif
        return BrowserDetector()
    }

    var selected: DetectedBrowser? { browsers.first { $0.kind == selectedKind } }

    var selectedProfile: SourceProfile? {
        guard let b = selected else { return nil }
        return b.profiles.first { $0.id == profileId } ?? b.profiles.first
    }

    func detect() {
        var found = detector.detect()
        // Read profile names for browsers Axolotl already has access to.
        for i in found.indices where found[i].profiles.isEmpty {
            withAccess(found[i]) { folder in
                found[i].profiles = detector.profiles(for: found[i].kind, in: folder)
            }
        }
        browsers = found
        let defaultID = BrowserDetector.defaultBrowserBundleID
        defaultKind = found.first { b in defaultID.map(b.kind.bundleIdentifiers.contains) == true }?.kind
        if selectedKind == nil || !found.contains(where: { $0.kind == selectedKind }) {
            select(BrowserDetector.preferred(found, defaultBundleID: defaultID, lastUsed: BrowserDetector.lastUsed))
        }
    }

    func select(_ kind: BrowserKind?) {
        selectedKind = kind
        onePasswordSelected = false
        summary = nil
        error = nil
        report = nil
        requested = []
        resetChoices()
        profileId = selected?.profiles.first?.id ?? ""
        if let kind { types = ImportDataType.supported(by: kind.engine) }
    }

    func resetChoices() {
        preview = nil
        excluded = [:]
    }

    /// Reads what the selected profile holds for the pickers; without folder access it
    /// asks for it only when `askAccess` (a "Choose…" click, not opening Customize).
    func scan(askAccess: Bool = false) {
        guard let b = selected, let profile = selectedProfile, preview == nil, !scanning else { return }
        if !hasAccess(b) {
            guard askAccess else { return }
            requestAccess()
        }
        let folder: URL
        if isFixtureMode {
            folder = b.dataFolder
        } else {
            guard let url = BrowserAccess.resolve(b.kind) else { return }
            folder = url
        }
        scanning = true
        let kind = b.kind, fixture = isFixtureMode
        Task {
            let p = await Task.detached(priority: .userInitiated) {
                BrowserImporter.preview(kind: kind, dataFolder: folder, profile: profile)
            }.value
            if !fixture { folder.stopAccessingSecurityScopedResource() }
            scanning = false
            if selectedKind == kind, selectedProfile?.id == profile.id { preview = p }
        }
    }

    /// The row subtitle under Customize: "86 of 120 passwords", "3 folders · 180 of 240 bookmarks".
    func pickSummary(_ type: ImportDataType) -> String? {
        guard let preview else { return scanning && type != .history ? "Counting…" : nil }
        let off = excluded[type] ?? []
        switch type {
        case .history:
            return nil
        case .bookmarks:
            let total = preview.bookmarks.reduce(0) { $0 + $1.linkCount }
            guard total > 0 else { return "None found" }
            guard !off.isEmpty else { return "All " + type.countText(total) }
            let kept = ImportedBookmark.excluding(folders: off, from: preview.bookmarks).reduce(0) { $0 + $1.linkCount }
            let folders = ImportedBookmark.folderRows(preview.bookmarks).filter {
                $0.key != ImportedBookmark.barKey && !off.contains($0.key) && !ImportedBookmark.isInside($0.key, off)
            }.count
            return "\(folders) folder\(folders == 1 ? "" : "s") · \(kept.formatted()) of \(type.countText(total))"
        default:
            let items = (preview.items[type] ?? []).filter { $0.unsupported == nil }
            guard !items.isEmpty else { return "None found" }
            let kept = items.filter { !off.contains($0.id) }.count
            let unit = type == .cookies ? "\(items.count.formatted()) site\(items.count == 1 ? "" : "s")" : type.countText(items.count)
            return kept == items.count ? "All " + unit : "\(kept.formatted()) of \(unit)"
        }
    }

    func hasAccess(_ b: DetectedBrowser) -> Bool {
        _ = accessChanged
        return isFixtureMode || BrowserAccess.hasAccess(b.kind)
    }

    func requestAccess() {
        guard let b = selected else { return }
        if BrowserAccess.request(b) {
            accessChanged += 1
            error = nil
            detect()
        } else {
            error = "Axolotl needs the “\(b.dataFolder.lastPathComponent)” folder itself. Try again and click Allow Access without opening another folder."
        }
    }

    /// Runs `body` with the browser's data folder readable (security scope or fixture).
    @discardableResult
    func withAccess<T>(_ b: DetectedBrowser, _ body: (URL) -> T) -> T? {
        if isFixtureMode { return body(b.dataFolder) }
        guard let url = BrowserAccess.resolve(b.kind) else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        return body(url)
    }

    func targetProfile(_ chosen: UUID) -> UUID {
        #if DEBUG
        if isFixtureMode { return BrowserImporter.fixtureProfileId }
        #endif
        return chosen
    }

    /// The one button: asks for folder access the first time, then imports everything selected.
    func importEverything(into axolotlProfile: UUID) {
        guard let b = selected else { return }
        if !hasAccess(b) {
            requestAccess()
            guard let refreshed = selected, hasAccess(refreshed) else { return }
        }
        runImport(into: axolotlProfile)
    }

    func runImport(into axolotlProfile: UUID) {
        guard let b = selected, let profile = selectedProfile else { return }
        let target = targetProfile(axolotlProfile)
        let folder: URL
        if isFixtureMode {
            folder = b.dataFolder
        } else {
            guard let url = BrowserAccess.resolve(b.kind) else { error = "Allow access first."; return }
            folder = url
        }
        running = true
        summary = nil
        error = nil
        let types = types.intersection(ImportDataType.supported(by: b.kind.engine))
        requested = ImportDataType.allCases.filter(types.contains)
        report = BrowserImporter.Report()
        let basic = types.intersection([.bookmarks, .history])
        let secureTypes = types.intersection([.passwords, .cookies, .extensions, .autofill])
        let sync = keepInSync
        let excluded = excluded
        let historySince = historyRange.cutoff()
        let kind = b.kind
        let profileCount = b.profiles.count
        Task {
            if !basic.isEmpty {
                let result = await BrowserImporter.run(kind: kind, dataFolder: folder, profile: profile,
                                                       profileCount: profileCount, types: basic,
                                                       axolotlProfileId: target, keepInSync: sync,
                                                       excludedFolders: excluded[.bookmarks] ?? [], historySince: historySince)
                report?.add(result, requested: basic)
            }
            if !secureTypes.isEmpty {
                // One Keychain prompt (Safe Storage is read once) covers cookies and passwords.
                let read = await Task.detached(priority: .userInitiated) {
                    BrowserImporter.readSecure(kind: kind, dataFolder: folder, profile: profile, types: secureTypes)
                }.value
                let sec = await BrowserImporter.applySecure(read.excluding(excluded), into: target)
                report?.add(sec, requested: secureTypes, browserName: kind.displayName)
            }
            if !isFixtureMode { folder.stopAccessingSecurityScopedResource() }
            running = false
            summary = report?.text
        }
    }

    func importHTML(_ url: URL, into axolotlProfile: UUID) {
        let target = targetProfile(axolotlProfile)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            error = "Couldn't read that file."
            return
        }
        let bookmarks = NetscapeBookmarks.parse(html)
        guard !bookmarks.isEmpty else { error = "No bookmarks found in that file."; return }
        let name = selectedKind == .safari ? "Imported from Safari" : "Imported Bookmarks"
        let added = BrowserImporter.applyBookmarks(bookmarks, folderName: name, axolotlProfileId: target)
        error = nil
        summary = BrowserImporter.Summary(bookmarks: added).text
    }

    /// Saves the toggle right away for a source that was imported before.
    func setSync(_ on: Bool, _ axolotl: UUID) {
        guard let b = selected, let p = selectedProfile else { return }
        var src = BrowserImporter.source(b.kind, p, targetProfile(axolotl))
        guard src.importedKeys != nil || src.lastVisit != nil, src.keepInSync != on else { return }
        src.keepInSync = on
        BrowserImporter.save(src)
    }

    func syncEnabled(_ axolotl: UUID) -> Bool {
        guard let b = selected, let p = selectedProfile else { return false }
        return BrowserImporter.source(b.kind, p, targetProfile(axolotl)).keepInSync
    }
}

/// Import from Chrome, Brave, Edge, Vivaldi, Arc, Firefox or Safari.
/// Import from Chrome, Brave, Edge, Vivaldi, Arc, Firefox or Safari.
struct BrowserImportView: View {
    /// Shown as a sheet (adds a Done button) or embedded in Settings.
    var onDone: (() -> Void)?

    @ObservedObject private var profileManager = ProfileManager.shared
    @StateObject private var model = BrowserImportModel()
    @State private var axolotlProfileId: UUID
    @State private var pickingHTML = false

    init(profileId: UUID? = nil, onDone: (() -> Void)? = nil) {
        self.onDone = onDone
        _axolotlProfileId = State(initialValue: profileId ?? ProfileManager.shared.lastActiveProfileId)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onDone {
                // A sheet: its own scrolling page and a Done button.
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) { cards }
                        .padding(24)
                }
                .background(SettingsStyle.page)
                HStack {
                    Spacer()
                    Button("Done", action: onDone).keyboardShortcut(.cancelAction).buttonStyle(.settings)
                }
                .padding(12)
                .background(SettingsStyle.page)
            } else {
                // Embedded in a settings page, which scrolls.
                VStack(alignment: .leading, spacing: 22) { cards }
            }
        }
        .settingsControlStyles()
        .onAppear {
            model.detect()
            #if DEBUG
            // AXOLOTL_IMPORT_FIXTURE_AUTORUN=chrome|firefox|1password: demo an import without clicking.
            let autorun = ProcessInfo.processInfo.environment["AXOLOTL_IMPORT_FIXTURE_AUTORUN"]
            if model.isFixtureMode, autorun == "1password" {
                model.select(nil)
                model.onePasswordSelected = true
            } else if model.isFixtureMode, let kind = autorun.flatMap(BrowserKind.init(rawValue:)) {
                model.select(kind)
                model.keepInSync = true
                model.runImport(into: axolotlProfileId)
            }
            #endif
        }
        .fileImporter(isPresented: $pickingHTML, allowedContentTypes: [.html]) { result in
            if case .success(let url) = result { model.importHTML(url, into: axolotlProfileId) }
        }
    }

    @ViewBuilder
    private var cards: some View {
        OneClickImportCard(model: model, axolotlProfileId: axolotlProfileId)

        SettingsCard("Other ways to import", footer: model.isFixtureMode
                     ? "Debug: reading synthetic fixtures; importing into a throwaway profile." : nil) {
            SettingsRow("Bookmarks file", subtitle: "An HTML file exported from any browser (Safari: File → Export → Bookmarks…).") {
                Button("Choose File…") { pickingHTML = true }
            }
            if !model.isFixtureMode {
                SettingsMenuRow("Import into", selection: $axolotlProfileId, options: profileManager.profiles.map {
                    .init($0.id, $0.name, image: ProfileAvatar.image(for: $0, size: 16))
                })
            }
        }
    }

    /// Unlocks the vault and imports a browser's passwords CSV; returns the status line (nil if not unlocked).
    static func importPasswordsCSV(_ url: URL, into profile: UUID) async -> String? {
        guard await PasswordVault.shared.unlock(reason: "import passwords") else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let r = try PasswordVault.shared.importCSV(text, profile: profile)
            return r.summary
        } catch {
            return "Couldn't read that file. Export it again as CSV."
        }
    }
}

/// The one-click import, Chrome/Brave-style: the preselected browser as one card,
/// a single "Import everything" button, options behind Customize, and per-type
/// progress that ends in a one-line summary. Used by the import sheet and onboarding.
struct OneClickImportCard: View {
    @ObservedObject var model: BrowserImportModel
    let axolotlProfileId: UUID
    @State private var customizing = false
    @State private var choosing: ImportDataType?
    @State private var pickingCSV = false
    @State private var passwordStatus: String?

    private static let onePasswordApp: URL? = ["com.1password.1password", "com.agilebits.onepassword7"]
        .lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first

    var body: some View {
        if model.onePasswordSelected {
            SettingsCard { SettingsContentRow { header("1Password", app: Self.onePasswordApp, detail: "Import an export file") } }
            OnePasswordImportSection(axolotlProfileId: model.targetProfile(axolotlProfileId), isFixtureMode: model.isFixtureMode)
        } else if let browser = model.selected {
            browserCard(browser)
            if browser.kind.engine != .chromium { passwordsCSVCard(browser) }
        } else {
            SettingsCard {
                SettingsNoteRow("No other browsers found. You can still import a bookmarks file exported from any browser.")
                SettingsContentRow { HStack { Spacer(); changeMenu } }
            }
        }
    }

    @ViewBuilder
    private func browserCard(_ browser: DetectedBrowser) -> some View {
        let access = model.hasAccess(browser)
        SettingsCard {
            SettingsContentRow { header(browser.kind.displayName, app: browser.appURL, detail: detail(browser)) }
            if model.requested.isEmpty {
                SettingsNoteRow(comesOver(browser) + (access ? "" : browser.kind == .safari
                    ? "\nmacOS protects Safari's data. If access is refused, export bookmarks from Safari (File → Export → Bookmarks…) and choose that file below."
                    : "\nmacOS asks once to let Axolotl read \(browser.kind.shortName)'s data. Just click Allow Access."))
            } else {
                ForEach(model.requested) { progressRow($0) }
            }
            if let summary = model.summary, !model.running {
                SettingsContentRow {
                    Label { Text(summary) } icon: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        .font(.system(size: 13, weight: .medium))
                }
            }
            if let error = model.error { SettingsNoteRow(error, isError: true) }
            if customizing { options(browser) }
            SettingsContentRow {
                HStack(spacing: 10) {
                    Button(customizing ? "Hide Options" : "Customize") {
                        withAnimation(.snappy) { customizing.toggle() }
                        if customizing { model.scan() }
                    }
                        .buttonStyle(.link)
                    Spacer()
                    if model.running { ProgressView().controlSize(.small) }
                    Button(model.running ? "Importing…" : "Import Everything") { model.importEverything(into: axolotlProfileId) }
                        .buttonStyle(.settingsProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.running || model.types.isEmpty || (access && browser.profiles.isEmpty))
                }
            }
        }
        .onChange(of: model.selectedKind) { _, _ in model.keepInSync = model.syncEnabled(axolotlProfileId) }
        .onChange(of: model.keepInSync) { _, on in model.setSync(on, axolotlProfileId) }
        .onChange(of: model.profileId) { _, _ in
            model.resetChoices()
            if customizing { model.scan() }
        }
        .sheet(item: $choosing) { ImportPickSheet(model: model, type: $0) }
        .onAppear { model.keepInSync = model.syncEnabled(axolotlProfileId) }
    }

    private func header(_ name: String, app: URL?, detail: String) -> some View {
        HStack(spacing: 14) {
            (app.map { Image(nsImage: NSWorkspace.shared.icon(forFile: $0.path)) } ?? Image(systemName: "globe"))
                .resizable().aspectRatio(contentMode: .fit).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 15, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            changeMenu
        }
        .padding(.vertical, 6)
    }

    /// Other detected browsers and 1Password; hidden when there's nothing else to pick.
    @ViewBuilder
    private var changeMenu: some View {
        let others = model.browsers.filter { $0.kind != model.selectedKind || model.onePasswordSelected }
        Menu("Change") {
            ForEach(others) { b in Button(b.kind.displayName) { model.select(b.kind) } }
            if !model.onePasswordSelected {
                Divider()
                Button("1Password…") { model.select(nil); model.onePasswordSelected = true }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.running)
    }

    private func detail(_ b: DetectedBrowser) -> String {
        var parts: [String] = []
        if b.kind == model.defaultKind { parts.append("Your default browser") }
        if let p = model.selectedProfile, b.profiles.count > 1 || p.name != "Default" { parts.append(p.name) }
        return parts.isEmpty ? "Ready to import" : parts.joined(separator: " · ")
    }

    private func comesOver(_ b: DetectedBrowser) -> String {
        let names: [ImportDataType: String] = [.bookmarks: "bookmarks", .history: "history", .passwords: "passwords",
                                               .cookies: "sign-ins", .extensions: "extensions", .autofill: "addresses"]
        let list = ImportDataType.allCases.filter(model.types.contains).compactMap { names[$0] }
        guard !list.isEmpty else { return "Nothing selected. Use Customize to pick what comes over." }
        let text = list.formatted(.list(type: .and))
        return text.prefix(1).uppercased() + text.dropFirst() + " will come over."
    }

    private func progressRow(_ type: ImportDataType) -> some View {
        let count = model.report?.counts[type]
        let skipped = model.report?.skipped[type]
        return SettingsContentRow {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Group {
                    if count != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if skipped != nil { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                    else { ProgressView().controlSize(.mini) }
                }
                .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title).font(.system(size: 13))
                    if let skipped { Text(skipped).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                Spacer()
                if let count {
                    Text(count > 0 ? count.formatted() : "Up to date").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder
    private func options(_ browser: DetectedBrowser) -> some View {
        if browser.profiles.count > 1 {
            SettingsMenuRow("Profile", selection: $model.profileId, options: browser.profiles.map { .init($0.id, $0.name) })
        }
        ForEach(ImportDataType.allCases.filter(ImportDataType.supported(by: browser.kind.engine).contains)) { type in
            let isOn = Binding(get: { model.types.contains(type) },
                               set: { on in if on { model.types.insert(type) } else { model.types.remove(type) } })
            SettingsRow(type.title, subtitle: isOn.wrappedValue ? model.pickSummary(type) : nil) {
                HStack(spacing: 12) {
                    if type == .history {
                        SettingsDropdown(title: "History range", selection: $model.historyRange,
                                         options: HistoryRange.allCases.map { .init($0, $0.title) }, minWidth: 120)
                            .disabled(!isOn.wrappedValue)
                    } else {
                        Button("Choose…") { model.scan(askAccess: true); choosing = type }
                            .disabled(!isOn.wrappedValue || model.running)
                    }
                    Toggle(type.title, isOn: isOn).toggleStyle(SettingsSwitchToggleStyle()).labelsHidden()
                }
            }
        }
        SettingsToggleRow("Keep in sync", subtitle: "Bring over new bookmarks and history each time Axolotl starts.",
                          isOn: $model.keepInSync)
    }

    /// Firefox and Safari passwords can't be read directly; they come from an exported CSV.
    private func passwordsCSVCard(_ browser: DetectedBrowser) -> some View {
        SettingsCard("Passwords", footer: "Delete the CSV after importing; it isn't encrypted.") {
            SettingsRow("Passwords CSV", subtitle: browser.kind.passwordExportSteps) {
                Button("Choose CSV…") { pickingCSV = true }
            }
            if let passwordStatus { SettingsNoteRow(passwordStatus) }
        }
        .fileImporter(isPresented: $pickingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            guard case .success(let url) = result else { return }
            let target = model.targetProfile(axolotlProfileId)
            Task { if let status = await BrowserImportView.importPasswordsCSV(url, into: target) { passwordStatus = status } }
        }
    }
}

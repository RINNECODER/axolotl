import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// State for the import sheet / Settings → Import pane.
final class BrowserImportModel: ObservableObject {
    @Published var browsers: [DetectedBrowser] = []
    @Published var selectedKind: BrowserKind?
    @Published var profileId: String = ""
    @Published var types: Set<ImportDataType> = [.bookmarks, .history]
    @Published var keepInSync = false
    @Published var running = false
    @Published var summary: String?
    @Published var error: String?
    @Published var accessChanged = 0
    @Published var onePasswordSelected = false

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
        // Read profile names for browsers Luna already has access to.
        for i in found.indices where found[i].profiles.isEmpty {
            withAccess(found[i]) { folder in
                found[i].profiles = detector.profiles(for: found[i].kind, in: folder)
            }
        }
        browsers = found
        if selectedKind == nil || !found.contains(where: { $0.kind == selectedKind }) { select(found.first?.kind) }
    }

    func select(_ kind: BrowserKind?) {
        selectedKind = kind
        onePasswordSelected = false
        summary = nil
        error = nil
        profileId = selected?.profiles.first?.id ?? ""
        if kind == .safari { types.remove(.history) }
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
            error = "Luna needs the “\(b.dataFolder.lastPathComponent)” folder itself. Try again and click Allow Access without opening another folder."
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

    func runImport(into lunaProfile: UUID) {
        guard let b = selected, let profile = selectedProfile else { return }
        let target = targetProfile(lunaProfile)
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
        let wanted = types.subtracting([.passwords])
        let sync = keepInSync
        Task {
            let result = await BrowserImporter.run(kind: b.kind, dataFolder: folder, profile: profile,
                                                   profileCount: b.profiles.count, types: wanted,
                                                   lunaProfileId: target, keepInSync: sync)
            if !isFixtureMode { folder.stopAccessingSecurityScopedResource() }
            running = false
            if result.errors.isEmpty || result.total > 0 { summary = result.text }
            if !result.errors.isEmpty { error = result.errors.joined(separator: "\n") }
        }
    }

    func importHTML(_ url: URL, into lunaProfile: UUID) {
        let target = targetProfile(lunaProfile)
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
        let r = BrowserImporter.applyBookmarks(bookmarks, folderName: name, existingFolderId: nil, lunaProfileId: target)
        error = nil
        summary = BrowserImporter.Summary(bookmarks: r.added).text
    }

    /// Saves the toggle right away for a source that was imported before.
    func setSync(_ on: Bool, _ luna: UUID) {
        guard let b = selected, let p = selectedProfile else { return }
        var src = BrowserImporter.source(b.kind, p, targetProfile(luna))
        guard src.folderId != nil || src.lastVisit != nil, src.keepInSync != on else { return }
        src.keepInSync = on
        BrowserImporter.save(src)
    }

    func syncEnabled(_ luna: UUID) -> Bool {
        guard let b = selected, let p = selectedProfile else { return false }
        return BrowserImporter.source(b.kind, p, targetProfile(luna)).keepInSync
    }
}

/// Import from Chrome, Brave, Edge, Vivaldi, Arc, Firefox or Safari.
struct BrowserImportView: View {
    /// Shown as a sheet (adds a Done button) or embedded in Settings.
    var onDone: (() -> Void)?

    @ObservedObject private var profileManager = ProfileManager.shared
    @StateObject private var model = BrowserImportModel()
    @State private var lunaProfileId: UUID
    @State private var pickingCSV = false
    @State private var pickingHTML = false
    @State private var passwordStatus: String?

    init(profileId: UUID? = nil, onDone: (() -> Void)? = nil) {
        self.onDone = onDone
        _lunaProfileId = State(initialValue: profileId ?? ProfileManager.shared.lastActiveProfileId)
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
                    Button("Done", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(.settingsProminent)
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
            // LUNA_IMPORT_FIXTURE_AUTORUN=chrome|firefox|1password: demo an import without clicking.
            let autorun = ProcessInfo.processInfo.environment["LUNA_IMPORT_FIXTURE_AUTORUN"]
            if model.isFixtureMode, autorun == "1password" {
                model.select(nil)
                model.onePasswordSelected = true
            } else if model.isFixtureMode, let kind = autorun.flatMap(BrowserKind.init(rawValue:)) {
                model.select(kind)
                model.keepInSync = true
                model.runImport(into: lunaProfileId)
            }
            #endif
        }
        .fileImporter(isPresented: $pickingCSV, allowedContentTypes: [.commaSeparatedText, .plainText]) { importPasswords($0) }
        .fileImporter(isPresented: $pickingHTML, allowedContentTypes: [.html]) { result in
            if case .success(let url) = result { model.importHTML(url, into: lunaProfileId) }
        }
    }

    @ViewBuilder
    private var cards: some View {
        SettingsCard("Import from", footer: model.isFixtureMode
                     ? "Debug: reading synthetic fixtures; importing into a throwaway profile." : nil) {
            SettingsContentRow {
                BrowserCardGrid(browsers: model.browsers, selected: model.onePasswordSelected ? nil : model.selectedKind,
                                onePasswordSelected: model.onePasswordSelected,
                                onSelect: { model.select($0) },
                                onSelectOnePassword: { model.select(nil); model.onePasswordSelected = true })
            }
            if model.browsers.isEmpty {
                SettingsNoteRow("No other browsers found. You can still import a bookmarks file exported from any browser.")
            }
        }

        if model.onePasswordSelected {
            OnePasswordImportSection(lunaProfileId: model.targetProfile(lunaProfileId), isFixtureMode: model.isFixtureMode)
        } else if let browser = model.selected {
            selectedSection(browser)
        }

        SettingsCard("Bookmarks file") {
            SettingsRow("Bookmarks file", subtitle: "Any browser can export bookmarks as an HTML file (Safari: File → Export → Bookmarks…). Pick that file to import it.") {
                Button("Choose Bookmarks File…") { pickingHTML = true }
            }
        }

        if !model.isFixtureMode {
            SettingsCard(footer: "Bookmarks appear as a pinned folder in the sidebar. History shows up in History and address bar suggestions.") {
                SettingsMenuRow("Import into", selection: $lunaProfileId, options: profileManager.profiles.map {
                    .init($0.id, $0.name, image: ProfileAvatar.image(for: $0, size: 16))
                })
            }
        }
    }

    @ViewBuilder
    private func selectedSection(_ browser: DetectedBrowser) -> some View {
        let access = model.hasAccess(browser)
        SettingsCard(browser.kind.displayName) {
            if browser.kind == .safari && !access {
                SettingsRow("Safari's data is protected", subtitle: "macOS protects Safari's data, so Luna can only read it with Full Disk Access (System Settings → Privacy & Security). The easier way: in Safari choose File → Export → Bookmarks…, then use Choose Bookmarks File below.") {
                    Button("Try Safari Folder Access…") { model.requestAccess() }
                }
            } else if !access {
                SettingsRow("Allow access", subtitle: "Luna is sandboxed, so macOS asks you once to let it read \(browser.kind.displayName)'s data folder. The folder is preselected; just click Allow Access.") {
                    Button("Allow Access…") { model.requestAccess() }
                        .buttonStyle(.settingsProminent)
                }
            } else {
                if browser.profiles.count > 1 {
                    SettingsMenuRow("Profile", selection: $model.profileId,
                                    options: browser.profiles.map { .init($0.id, $0.name) })
                }
                SettingsToggleRow("Bookmarks", isOn: binding(.bookmarks))
                if browser.kind != .safari {
                    SettingsToggleRow("History", isOn: binding(.history))
                }
                SettingsToggleRow("Keep in sync", subtitle: "Re-import new bookmarks and history each time Luna starts.",
                                  isOn: $model.keepInSync)
                SettingsContentRow {
                    HStack {
                        Spacer()
                        if model.running { ProgressView().controlSize(.small).padding(.trailing, 6) }
                        Button("Import") { model.runImport(into: lunaProfileId) }
                            .buttonStyle(.settingsProminent)
                            .disabled(model.running || model.types.subtracting([.passwords]).isEmpty || browser.profiles.isEmpty)
                    }
                }
            }
            if let summary = model.summary {
                SettingsContentRow {
                    Label(summary, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                }
            }
            if let error = model.error {
                SettingsNoteRow(error, isError: true)
            }
        }
        .onChange(of: model.selectedKind) { _, _ in model.keepInSync = model.syncEnabled(lunaProfileId) }
        .onChange(of: model.keepInSync) { _, on in model.setSync(on, lunaProfileId) }
        .onAppear { model.keepInSync = model.syncEnabled(lunaProfileId) }

        SettingsCard("Passwords", footer: "Delete the CSV after importing; it isn't encrypted.") {
            SettingsRow("Passwords CSV", subtitle: browser.kind.passwordExportSteps) {
                Button("Choose Passwords CSV…") { pickingCSV = true }
            }
            if let passwordStatus { SettingsNoteRow(passwordStatus) }
        }
    }

    private func binding(_ type: ImportDataType) -> Binding<Bool> {
        Binding(get: { model.types.contains(type) },
                set: { on in if on { model.types.insert(type) } else { model.types.remove(type) } })
    }

    private func importPasswords(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let target = lunaProfileId
        Task {
            if let status = await Self.importPasswordsCSV(url, into: target) { passwordStatus = status }
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
            return "Imported \(r.imported) login\(r.imported == 1 ? "" : "s")" + (r.skipped > 0 ? ", skipped \(r.skipped)." : ".")
        } catch {
            return "Couldn't read that file. Export it again as CSV."
        }
    }
}

/// Detected browsers (plus 1Password) as selectable cards with their app icons.
struct BrowserCardGrid: View {
    let browsers: [DetectedBrowser]
    let selected: BrowserKind?
    let onePasswordSelected: Bool
    let onSelect: (BrowserKind) -> Void
    let onSelectOnePassword: () -> Void

    private static let onePasswordApp: URL? = ["com.1password.1password", "com.agilebits.onepassword7"]
        .lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(browsers) { b in
                card(b.kind.shortName, icon: b.appURL, isSelected: b.kind == selected) { onSelect(b.kind) }
                    .accessibilityLabel(b.kind.displayName)
            }
            card("1Password", icon: Self.onePasswordApp, symbol: "key.viewfinder", isSelected: onePasswordSelected, action: onSelectOnePassword)
        }
        .padding(.vertical, 4)
    }

    private func card(_ title: String, icon app: URL?, symbol: String = "globe", isSelected: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                (app.map { Image(nsImage: NSWorkspace.shared.icon(forFile: $0.path)) } ?? Image(systemName: symbol))
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 40, height: 40)
                Text(title).font(.callout).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

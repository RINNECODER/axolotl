import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Import sheet section for 1Password exports (.1pux or CSV) into Luna's passwords.
struct OnePasswordImportSection: View {
    let lunaProfileId: UUID
    var isFixtureMode = false

    @State private var picking = false
    @State private var status: String?
    @State private var failed = false
    /// The export just imported, offered for deletion (it holds plaintext secrets).
    @State private var exportFile: URL?

    private static let types: [UTType] = [UTType(filenameExtension: "1pux"), .zip, .commaSeparatedText]
        .compactMap { $0 }

    var body: some View {
        SettingsCard("1Password", footer: "Luna stores each login's website, username and password. Notes and one-time codes stay in 1Password. For live autofill, 1Password's Universal Autofill (⌘\\) also works in Luna.") {
            SettingsRow("1Password export",
                        subtitle: "In 1Password, choose File → Export, pick the account, then choose 1PUX (recommended) or CSV and save it. Pick that file here.") {
                Button("Choose 1Password Export…") { picking = true }
                    .buttonStyle(.settingsProminent)
            }
            if let status {
                SettingsContentRow {
                    Label(status, systemImage: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(failed ? .red : .green)
                }
            }
            if let exportFile {
                SettingsRow("The export contains your passwords unencrypted.") {
                    Button("Delete the Export File", role: .destructive) { trash(exportFile) }
                }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types) { result in
            if case .success(let url) = result { importFile(url) }
        }
        .onAppear {
            #if DEBUG
            if isFixtureMode, let path = ProcessInfo.processInfo.environment["LUNA_IMPORT_FIXTURE_1PUX"] {
                importFile(URL(fileURLWithPath: path))
            }
            #endif
        }
    }

    private func parse(_ url: URL) throws -> OnePasswordImporter.Result {
        if url.pathExtension.lowercased() == "csv" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ImportError.unreadable(url.lastPathComponent) }
            return OnePasswordImporter.parseCSV(text)
        }
        return try OnePasswordImporter.parse1PUX(at: url)
    }

    private func importFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        let parsed: OnePasswordImporter.Result
        do {
            parsed = try parse(url)
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            fail("Couldn't read that export. Export again from 1Password as 1PUX or CSV.")
            return
        }
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard !parsed.logins.isEmpty else { fail("No logins with a website and password were found."); return }

        var notes: [String] = []
        if parsed.droppedExtras > 0 { notes.append("\(parsed.droppedExtras) had notes or one-time codes that stay in 1Password") }
        if parsed.skippedOtherItems > 0 { notes.append("skipped \(parsed.skippedOtherItems) non-login item\(parsed.skippedOtherItems == 1 ? "" : "s")") }
        if parsed.skippedIncomplete > 0 { notes.append("skipped \(parsed.skippedIncomplete) without a website or password") }
        let suffix = notes.isEmpty ? "." : " (" + notes.joined(separator: "; ") + ")."

        if isFixtureMode {
            // Debug fixtures never touch the Keychain.
            succeed("Found \(parsed.logins.count) logins" + suffix + " Debug: not saved.", file: url)
            return
        }
        Task {
            guard await PasswordVault.shared.unlock(reason: "import passwords") else { return }
            do {
                let r = try PasswordVault.shared.importCSV(OnePasswordImporter.vaultCSV(parsed.logins), profile: lunaProfileId)
                succeed("Imported \(r.imported) login\(r.imported == 1 ? "" : "s")" + suffix, file: url)
            } catch {
                fail("Couldn't save the logins.")
            }
        }
    }

    private func succeed(_ message: String, file: URL) {
        failed = false
        status = message
        exportFile = file
    }

    private func fail(_ message: String) {
        failed = true
        status = message
        exportFile = nil
    }

    private func trash(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            exportFile = nil
            status = "Moved the export to the Trash. Empty the Trash to remove it for good."
        } catch {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            status = "Luna couldn't move it. It's selected in Finder; drag it to the Trash."
        }
    }
}

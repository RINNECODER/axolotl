import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Settings → Extensions: install (store link, file, folder), toggle, remove.
struct ExtensionsSettingsView: View {
    @ObservedObject private var library = ExtensionLibrary.shared
    @State private var storeLink = ""
    @State private var busy = false
    @State private var status: String?
    @State private var choosingFile = false
    @State private var pendingRemove: ExtensionLibrary.Record?

    var body: some View {
        Group {
            SettingsCard("Add", footer: "Axolotl runs Chrome, Firefox and Safari web extensions (Manifest V2 and V3) with WebKit. Some Chrome-only features may not work, and extensions that need a companion app, like iCloud Passwords, can't connect.") {
                SettingsContentRow {
                    HStack(spacing: 10) {
                        TextField("Chrome Web Store link", text: $storeLink,
                                  prompt: Text(verbatim: "https://chromewebstore.google.com/detail/…"))
                            .textFieldStyle(SettingsTextFieldStyle())
                            .onSubmit(installFromStore)
                        Button("Install", action: installFromStore)
                            .buttonStyle(.settingsProminent)
                            .disabled(busy || ExtensionLibrary.storeID(in: storeLink) == nil)
                    }
                }
                SettingsRow("Install from file or folder", subtitle: "A .crx, .xpi, .zip or an unpacked extension folder.") {
                    Button("Choose…") { choosingFile = true }
                        .disabled(busy)
                        .accessibilityLabel("Install from File or Folder…")
                }
                if busy {
                    SettingsContentRow {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
                    }
                }
                if let status { SettingsNoteRow(status) }
            }

            SettingsCard("Installed", footer: "uBlock Origin Lite by Raymond Hill blocks ads and trackers. It's bundled with Axolotl under the GPL-3.0 license (source: github.com/uBlockOrigin/uBOL-home).") {
                if library.records.isEmpty {
                    SettingsNoteRow("No extensions installed.")
                }
                ForEach(library.records) { record in
                    HStack(spacing: 12) {
                        ExtensionIcon(directory: library.directory(for: record))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.name).font(.system(size: 13))
                            Text(record.builtInID != nil ? "Version \(record.version) · Built into Axolotl" : "Version \(record.version)")
                                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { pendingRemove = record } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove extension")
                        Toggle("Enabled", isOn: Binding(get: { record.enabled }, set: { library.setEnabled(record, $0) }))
                            .labelsHidden()
                            .toggleStyle(SettingsSwitchToggleStyle())
                    }
                    .settingsRowPadding()
                }
                if !(UserDefaults.standard.stringArray(forKey: ExtensionLibrary.removedBuiltInsKey) ?? []).isEmpty {
                    SettingsRow("Built-in extensions", subtitle: "Bring back the extensions Axolotl ships with.") {
                        Button("Restore Built-in Extensions") {
                            UserDefaults.standard.removeObject(forKey: ExtensionLibrary.removedBuiltInsKey)
                            library.installBuiltIns()
                        }
                    }
                }
            }
        }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: [.folder, .zip, UTType(filenameExtension: "crx") ?? .data, UTType(filenameExtension: "xpi") ?? .data]) { result in
            guard case .success(let url) = result else { return }
            run { try await library.install(from: url) }
        }
        .confirmationDialog("Remove “\(pendingRemove?.name ?? "")”?",
                            isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
                            presenting: pendingRemove) { record in
            Button("Remove", role: .destructive) {
                library.remove(record)
                pendingRemove = nil
            }
        }
    }

    private func installFromStore() {
        let link = storeLink
        run {
            let record = try await library.install(storeLink: link)
            storeLink = ""
            return record
        }
    }

    private func run(_ work: @escaping () async throws -> ExtensionLibrary.Record) {
        busy = true
        status = nil
        Task {
            do {
                let record = try await work()
                status = "Added \(record.name)."
            } catch ExtensionLibrary.InstallError.cancelled {
                status = nil
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Loads an installed extension's icon from disk.
private struct ExtensionIcon: View {
    let directory: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable() } else { Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary) }
        }
        .frame(width: 24, height: 24)
        .task(id: directory) {
            image = (try? await WKWebExtension(resourceBaseURL: directory))?.icon(for: CGSize(width: 48, height: 48))
        }
    }
}

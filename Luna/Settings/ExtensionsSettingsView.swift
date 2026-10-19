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
        Form {
            Section {
                HStack {
                    TextField("Chrome Web Store link", text: $storeLink,
                              prompt: Text("https://chromewebstore.google.com/detail/…"))
                        .onSubmit(installFromStore)
                    Button("Install", action: installFromStore)
                        .disabled(busy || ExtensionLibrary.storeID(in: storeLink) == nil)
                }
                Button("Install from File or Folder…") { choosingFile = true }
                    .disabled(busy)
                if busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Installing…").foregroundStyle(.secondary) }
                }
                if let status { Text(status).font(.callout) }
                Text("Luna runs Chrome, Firefox and Safari web extensions (Manifest V2 and V3) with WebKit. Some Chrome-only features may not work, and extensions that need a companion app, like iCloud Passwords, can't connect.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Add")
            }

            Section {
                if library.records.isEmpty {
                    Text("No extensions installed.").foregroundStyle(.secondary)
                }
                ForEach(library.records) { record in
                    HStack(spacing: 10) {
                        ExtensionIcon(directory: library.directory(for: record))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(record.name)
                            Text(record.builtInID != nil ? "Version \(record.version) · Built into Luna" : "Version \(record.version)")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Enabled", isOn: Binding(get: { record.enabled }, set: { library.setEnabled(record, $0) }))
                            .labelsHidden()
                            .toggleStyle(.switch)
                        Button(role: .destructive) { pendingRemove = record } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove extension")
                    }
                }
                if !(UserDefaults.standard.stringArray(forKey: ExtensionLibrary.removedBuiltInsKey) ?? []).isEmpty {
                    Button("Restore Built-in Extensions") {
                        UserDefaults.standard.removeObject(forKey: ExtensionLibrary.removedBuiltInsKey)
                        library.installBuiltIns()
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("uBlock Origin Lite by Raymond Hill blocks ads and trackers. It's bundled with Luna under the GPL-3.0 license (source: github.com/uBlockOrigin/uBOL-home).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
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

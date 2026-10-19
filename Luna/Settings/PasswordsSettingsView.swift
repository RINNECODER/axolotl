import SwiftUI
import UniformTypeIdentifiers

/// Settings → Passwords: unlock with Touch ID, browse/copy/delete logins,
/// and import Apple Passwords' CSV export.
struct PasswordsSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var profileId: UUID = ProfileManager.shared.lastActiveProfileId
    @State private var unlocked = PasswordVault.shared.isUnlocked
    @State private var credentials: [PasswordVault.Credential] = []
    @State private var query = ""
    @State private var revealed: [String: String] = [:]
    @State private var importing = false
    @State private var status: String?
    @State private var pendingDelete: PasswordVault.Credential?

    private var filtered: [PasswordVault.Credential] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return credentials }
        return credentials.filter { $0.host.contains(q) || $0.username.lowercased().contains(q) }
    }

    var body: some View {
        Form {
            Section {
                LunaPicker("Profile", selection: $profileId, options: profileManager.profiles.map {
                    .init($0.id, $0.name, image: ProfileAvatar.image(for: $0, size: 16))
                })
                Text("Luna offers to save logins when you sign in and to fill them next time. They're stored in your Mac's Keychain, separately for each profile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if unlocked {
                Section {
                    TextField("Search", text: $query, prompt: Text("Search logins"))
                    if filtered.isEmpty {
                        Text(credentials.isEmpty ? "No saved logins yet." : "No matching logins.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filtered) { cred in
                        HStack(spacing: 10) {
                            FaviconView(url: URL(string: "https://\(cred.host)")!).scaleEffect(0.8).frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cred.host).lineLimit(1)
                                Text(cred.username.isEmpty ? "(no username)" : cred.username)
                                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(revealed[cred.id] ?? "••••••••")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                            Button { toggleReveal(cred) } label: {
                                Image(systemName: revealed[cred.id] == nil ? "eye" : "eye.slash")
                            }
                            .buttonStyle(.borderless)
                            .help(revealed[cred.id] == nil ? "Show password" : "Hide password")
                            Button { copy(cred) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy password")
                            Button(role: .destructive) { pendingDelete = cred } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .help("Delete")
                        }
                    }
                } header: {
                    HStack {
                        Text("\(credentials.count) saved login\(credentials.count == 1 ? "" : "s")")
                        Spacer()
                        Button("Lock") {
                            PasswordVault.shared.lock()
                            unlocked = false
                            revealed = [:]
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                Section {
                    Button("Unlock Passwords…") {
                        Task {
                            unlocked = await PasswordVault.shared.unlock(reason: "view your saved passwords")
                            reload()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Section {
                Button("Import from Apple Passwords…") { importing = true }
                Text("In the Passwords app, choose File → Export All Passwords, then pick that CSV here. Delete the CSV afterward; it isn't encrypted. Chrome's password export works too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let status {
                    Text(status).font(.callout)
                }
            } header: {
                Text("Import")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onChange(of: profileId) { _, _ in
            revealed = [:]
            reload()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            importCSV(result)
        }
        .confirmationDialog("Delete the login for \(pendingDelete?.host ?? "")?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { cred in
            Button("Delete", role: .destructive) {
                try? PasswordVault.shared.delete(cred, profile: profileId)
                pendingDelete = nil
                reload()
            }
        }
    }

    private func reload() {
        credentials = PasswordVault.shared.credentials(profile: profileId)
    }

    private func toggleReveal(_ cred: PasswordVault.Credential) {
        if revealed[cred.id] != nil { revealed[cred.id] = nil; return }
        revealed[cred.id] = (try? PasswordVault.shared.password(for: cred, profile: profileId)) ?? nil
    }

    private func copy(_ cred: PasswordVault.Credential) {
        guard let password = try? PasswordVault.shared.password(for: cred, profile: profileId) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
        status = "Copied the password for \(cred.host)."
    }

    private func importCSV(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        Task {
            guard await PasswordVault.shared.unlock(reason: "import passwords") else { return }
            unlocked = true
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let r = try PasswordVault.shared.importCSV(text, profile: profileId)
                status = "Imported \(r.imported) login\(r.imported == 1 ? "" : "s")" + (r.skipped > 0 ? ", skipped \(r.skipped)." : ".")
            } catch {
                status = "Couldn't read that file. Export it again from the Passwords app as CSV."
            }
            reload()
        }
    }
}

// Axolotl — axolotl://passwords: Chrome's Password Manager page. Lists the profile's saved logins
// by site; revealing or copying a password asks for Touch ID / the Mac password first.
// Passwords are never logged.
import AppKit
import Combine
import SwiftUI

@MainActor
final class PasswordManagerModel: ObservableObject {
    typealias Credential = PasswordVault.Credential

    let vault: PasswordVault
    let profileId: UUID
    private let authenticate: (String) async -> Bool

    @Published private(set) var credentials: [Credential] = []
    @Published var query = ""
    @Published var selection: Credential?
    /// The selected login's password, while shown.
    @Published private(set) var revealed: String?
    @Published var status: String?

    init(vault: PasswordVault = .shared, profileId: UUID, authenticate: ((String) async -> Bool)? = nil) {
        self.vault = vault
        self.profileId = profileId
        self.authenticate = authenticate ?? { [vault] in await vault.unlock(reason: $0) }
        reload()
    }

    func reload() { credentials = vault.credentials(profile: profileId) }

    /// Logins matching the search (site or username), grouped by site as Chrome does.
    var sites: [(host: String, logins: [Credential])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hits = q.isEmpty ? credentials
            : credentials.filter { $0.host.lowercased().contains(q) || $0.username.lowercased().contains(q) }
        return Dictionary(grouping: hits, by: \.host).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func select(_ credential: Credential?) {
        selection = credential
        revealed = nil
    }

    /// The selected password, after device authentication. Nil if declined or missing.
    func revealedPassword() async -> String? {
        if let revealed { return revealed }
        guard let selection, await authenticate("show the password for \(selection.host)") else { return nil }
        revealed = (try? vault.password(for: selection, profile: profileId)) ?? nil
        return revealed
    }

    func toggleReveal() async {
        if revealed != nil { revealed = nil } else { _ = await revealedPassword() }
    }

    func copyUsername() {
        guard let selection else { return }
        copy(selection.username)
        status = "Username copied"
    }

    func copyPassword() async {
        guard let password = await revealedPassword() else { return }
        copy(password)
        status = "Password copied"
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// "https://www.example.com/login" or "example.com" → "example.com".
    nonisolated static func host(from input: String) -> String? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let host = URL(string: raw.contains("://") ? raw : "https://\(raw)")?.host ?? ""
        return host.isEmpty ? nil : PasswordVault.normalize(host)
    }

    /// Adds a login, or edits `replacing`. Saves first and only then removes the old entry,
    /// so a failed save never loses the login. Returns an error message to show, or nil.
    @discardableResult
    func save(site: String, username: String, password: String, replacing old: Credential? = nil) -> String? {
        guard let host = Self.host(from: site) else { return "Enter a site, like example.com." }
        guard !password.isEmpty else { return "Enter a password." }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if old.map({ $0.host != host || $0.username != user }) ?? true,
           credentials.contains(where: { $0.host == host && $0.username == user }) {
            return "A password for \(user.isEmpty ? "this site" : user) on \(host) is already saved."
        }
        do {
            try vault.save(host: host, username: user, password: password, profile: profileId)
            if let old, old.host != host || old.username != user { try vault.delete(old, profile: profileId) }
        } catch {
            return error.localizedDescription
        }
        reload()
        selection = credentials.first { $0.host == host && $0.username == user }
        revealed = selection == nil ? nil : password
        status = old == nil ? "Password saved" : "Password updated"
        return nil
    }

    func delete(_ credential: Credential) {
        do {
            try vault.delete(credential, profile: profileId)
        } catch {
            status = error.localizedDescription
            return
        }
        if selection == credential { select(nil) }
        reload()
        status = "Password deleted"
    }
}

// MARK: - Page

struct PasswordManagerPageView: View {
    @StateObject private var model: PasswordManagerModel
    @State private var editing: Editor?
    @State private var pendingDelete: PasswordVault.Credential?

    /// The add/edit sheet: nil `original` adds.
    struct Editor: Identifiable {
        let id = UUID()
        var original: PasswordVault.Credential?
        var site = "", username = "", password = ""
    }

    init(profileId: UUID, vault: PasswordVault = .shared) {
        _model = StateObject(wrappedValue: PasswordManagerModel(vault: vault, profileId: profileId))
    }

    init(model: PasswordManagerModel) { _model = StateObject(wrappedValue: model) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let selected = model.selection {
                PasswordDetailView(model: model, credential: selected,
                                   onEdit: { password in
                                       editing = Editor(original: selected, site: selected.host,
                                                        username: selected.username, password: password)
                                   },
                                   onDelete: { pendingDelete = selected })
            } else {
                list
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.reload() }
        .sheet(item: $editing) { PasswordEditorSheet(model: model, editor: $0) }
        .alert("Delete password?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
               presenting: pendingDelete) { cred in
            Button("Delete", role: .destructive) { model.delete(cred) }
            Button("Cancel", role: .cancel) {}
        } message: { cred in
            Text("The password for \(cred.username.isEmpty ? cred.host : "\(cred.username) on \(cred.host)") will be deleted from Axolotl. You can't undo this.")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if model.selection != nil {
                Button { model.select(nil) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Back to passwords")
            }
            Text("Password Manager").font(.system(size: 20, weight: .semibold))
            Spacer()
            if let status = model.status {
                Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            if model.selection == nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search passwords", text: $model.query).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(width: 240, height: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.7)))
                Button("Add Password") { editing = Editor() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var list: some View {
        let sites = model.sites
        if sites.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "key").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "Passwords you save appear here" : "No passwords found")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.credentials.count) saved password\(model.credentials.count == 1 ? "" : "s")")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                    VStack(spacing: 0) {
                        ForEach(Array(sites.enumerated()), id: \.element.host) { index, site in
                            if index > 0 { Divider().padding(.leading, 52) }
                            ForEach(site.logins) { cred in
                                PasswordSiteRow(credential: cred, showsHost: cred == site.logins.first) {
                                    model.select(cred)
                                }
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
                }
                .frame(maxWidth: 680)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct SiteIcon: View {
    let host: String
    var body: some View {
        if let url = PasswordVault.siteURL(host: host), let image = FaviconCache.shared.cachedImage(for: url) {
            Image(nsImage: image).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 20, height: 20)
        }
    }
}

private struct PasswordSiteRow: View {
    let credential: PasswordVault.Credential
    let showsHost: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                SiteIcon(host: credential.host).opacity(showsHost ? 1 : 0)
                Text(showsHost ? credential.host : "").font(.system(size: 13)).lineLimit(1)
                    .frame(width: 240, alignment: .leading)
                Text(credential.username.isEmpty ? "No username" : credential.username)
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
            .contentShape(Rectangle())
            .background(hovered ? Color.primary.opacity(0.05) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(credential.host), \(credential.username.isEmpty ? "no username" : credential.username)")
    }
}

private struct PasswordDetailView: View {
    @ObservedObject var model: PasswordManagerModel
    let credential: PasswordVault.Credential
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    SiteIcon(host: credential.host)
                    Text(credential.host).font(.system(size: 16, weight: .semibold))
                }
                VStack(spacing: 0) {
                    field("Username", credential.username.isEmpty ? "No username" : credential.username) {
                        Button { model.copyUsername() } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy username").accessibilityLabel("Copy username")
                    }
                    Divider()
                    field("Password", model.revealed ?? String(repeating: "•", count: 10), monospaced: model.revealed != nil) {
                        Button { Task { await model.toggleReveal() } } label: {
                            Image(systemName: model.revealed == nil ? "eye" : "eye.slash")
                        }
                        .help(model.revealed == nil ? "Show password" : "Hide password")
                        .accessibilityLabel(model.revealed == nil ? "Show password" : "Hide password")
                        Button { Task { await model.copyPassword() } } label: { Image(systemName: "doc.on.doc") }
                            .help("Copy password").accessibilityLabel("Copy password")
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
                if let modified = credential.modified {
                    Text("Last changed \(modified.formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Edit") {
                        Task { if let password = await model.revealedPassword() { onEdit(password) } }
                    }
                    Button("Delete", role: .destructive, action: onDelete)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }

    private func field(_ label: String, _ value: String, monospaced: Bool = false,
                       @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, design: monospaced ? .monospaced : .default))
                    .textSelection(.enabled).lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) { actions() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }
}

private struct PasswordEditorSheet: View {
    @ObservedObject var model: PasswordManagerModel
    @State var editor: PasswordManagerPageView.Editor
    @State private var error: String?
    @State private var showsPassword = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(editor.original == nil ? "Add Password" : "Edit Password").font(.system(size: 15, weight: .semibold))
            Form {
                TextField("Site", text: $editor.site, prompt: Text("example.com"))
                TextField("Username", text: $editor.username)
                HStack {
                    if showsPassword {
                        TextField("Password", text: $editor.password)
                    } else {
                        SecureField("Password", text: $editor.password)
                    }
                    Button { showsPassword.toggle() } label: { Image(systemName: showsPassword ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showsPassword ? "Hide password" : "Show password")
                }
            }
            if let error {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    error = model.save(site: editor.site, username: editor.username, password: editor.password,
                                       replacing: editor.original)
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}

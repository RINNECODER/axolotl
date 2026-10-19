import SwiftUI

/// Settings → Profiles: rename, recolor, add and delete profiles.
struct ProfileSettingsView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var pendingDelete: BrowserProfile?

    var body: some View {
        Form {
            Section {
                ForEach(profileManager.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        canDelete: profileManager.profiles.count > 1,
                        onDelete: { pendingDelete = profile }
                    )
                }
            } footer: {
                Text("Each profile keeps its own cookies, logins, history, tabs and AI chats, like a separate browser.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Add Profile…") {
                    _ = ProfileActions.createProfile(manager: profileManager)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete “\(pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { profile in
            Button("Delete Profile and Data", role: .destructive) {
                profileManager.deleteProfile(profileId: profile.id) {}
                pendingDelete = nil
            }
        } message: { _ in
            Text("Its history, cookies, logins, tabs and chats are removed. This can't be undone.")
        }
    }
}

private struct ProfileRow: View {
    let profile: BrowserProfile
    let canDelete: Bool
    let onDelete: () -> Void

    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var name: String = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: ProfileAvatar.image(for: profile, size: 24))
            TextField("Name", text: $name, prompt: Text("Name"))
                .labelsHidden()
                .textFieldStyle(.plain)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onSubmit(commitName)
                .onAppear { name = profile.name }
                .onChange(of: profile.name) { _, new in name = new }
            ProfileIconPicker(profile: profile)
            LunaPicker("Color", selection: Binding(
                get: { profile.colorId },
                set: { profileManager.recolor(profileId: profile.id, colorId: $0) }
            ), options: ProfileColor.presets.map { .init($0.id, $0.id.capitalized, image: ProfileAvatar.swatch($0)) })
            .labelsHidden()
            .fixedSize()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(!canDelete)
            .help(canDelete ? "Delete Profile" : "Luna needs at least one profile")
        }
        .onDisappear(perform: commitName)
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = profile.name } else if trimmed != profile.name {
            profileManager.rename(profileId: profile.id, to: trimmed)
        }
    }
}

/// Avatar button that opens a grid of icons to choose from.
private struct ProfileIconPicker: View {
    let profile: BrowserProfile
    @ObservedObject private var profileManager = ProfileManager.shared
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: profile.iconName ?? "textformat")
                .frame(width: 18)
        }
        .help("Avatar icon")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                    ForEach(ProfileIcons.choices, id: \.self) { symbol in
                        Button {
                            profileManager.setIcon(profileId: profile.id, iconName: symbol)
                            open = false
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 13))
                                .frame(width: 30, height: 30)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(profile.iconName == symbol ? AnyShapeStyle(profile.profileColor.color.opacity(0.35)) : AnyShapeStyle(.quaternary.opacity(0.5))))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(symbol)
                    }
                }
                Button("Use Initial") {
                    profileManager.setIcon(profileId: profile.id, iconName: nil)
                    open = false
                }
                .disabled(profile.iconName == nil)
            }
            .padding(10)
        }
    }
}

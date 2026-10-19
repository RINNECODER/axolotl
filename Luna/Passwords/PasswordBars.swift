import SwiftUI

/// "Sign in as …" card shown when a page has a login form with saved logins.
struct PasswordFillCard: View {
    let offer: WebViewWrapper.PasswordFillOffer
    let onFill: (PasswordVault.Credential) -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            if offer.credentials.count == 1, let only = offer.credentials.first {
                Button { onFill(only) } label: {
                    Text("Sign in as \(only.username.isEmpty ? "saved login" : only.username)")
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Menu("Sign in with a saved login") {
                    ForEach(offer.credentials) { cred in
                        Button(cred.username.isEmpty ? "(no username)" : cred.username) { onFill(cred) }
                    }
                }
                .fixedSize()
                .controlSize(.small)
            }
            PanelIconButton(systemName: "xmark", help: "Not now", action: onDismiss)
        }
        .modifier(PasswordCardStyle())
    }
}

/// "Save password?" card after a sign-in that isn't saved yet.
struct PasswordSaveCard: View {
    let offer: WebViewWrapper.PasswordSaveOffer
    let onSave: (String) -> Void
    let onNever: () -> Void
    let onDismiss: () -> Void

    @State private var username: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                Text("Save password for \(offer.host)?")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                PanelIconButton(systemName: "xmark", help: "Not now", action: onDismiss)
            }
            HStack(spacing: 6) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Text(String(repeating: "•", count: min(offer.password.count, 12)))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Password hidden")
            }
            HStack {
                Button("Never for This Site", action: onNever)
                    .controlSize(.small)
                Spacer()
                Button("Save") { onSave(username) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            Text("Stored in your Mac's Keychain. Touch ID unlocks it.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 320)
        .modifier(PasswordCardStyle())
        .onAppear { username = offer.username }
    }
}

private struct PasswordCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(LunaMaterialFill(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 14, y: 5)
    }
}

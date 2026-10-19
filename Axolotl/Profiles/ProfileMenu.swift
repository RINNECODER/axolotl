import AppKit
import Combine
import SwiftUI

// MARK: - Avatar

enum ProfileAvatar {
    /// A filled circle with the profile's initial, for menus and toolbars.
    static func image(for profile: BrowserProfile, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            profile.profileColor.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            if let symbol = profile.iconName,
               let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size * 0.48, weight: .semibold).applying(.init(paletteColors: [.white]))) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2, width: g.width, height: g.height))
                return true
            }
            let initial = String(profile.name.prefix(1)).uppercased() as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = initial.size(withAttributes: attrs)
            initial.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attrs)
            return true
        }
        image.isTemplate = false
        return image
    }

    static func swatch(_ color: ProfileColor, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            color.nsColor.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

// MARK: - Icons

enum ProfileIcons {
    /// SF Symbols offered for profile avatars.
    static let choices: [String] = [
        "person.fill", "briefcase.fill", "house.fill", "graduationcap.fill", "book.fill", "laptopcomputer",
        "hammer.fill", "paintbrush.fill", "camera.fill", "music.note", "gamecontroller.fill", "film.fill",
        "cart.fill", "creditcard.fill", "airplane", "car.fill", "leaf.fill", "pawprint.fill",
        "heart.fill", "star.fill", "bolt.fill", "flame.fill", "moon.fill", "sun.max.fill",
        "globe.americas.fill", "sparkles", "lock.fill", "chart.bar.fill", "stethoscope", "dumbbell.fill",
    ]
}

// MARK: - Settings routing

/// Lets menus open Settings directly on a given pane.
final class SettingsRouter: ObservableObject {
    static let shared = SettingsRouter()
    @Published var requestedPane: SettingsPane?
    /// The tab Settings → Passwords & Import shows.
    @Published var passwordsTab: PasswordsPaneTab = .passwords
    nonisolated deinit {}

    /// Opens a pane by name, including old pane names ("import", "axolotlMax", …). Returns false for unknown names.
    @discardableResult
    func request(_ raw: String) -> Bool {
        guard let pane = SettingsPane.resolve(raw) else { return false }
        if let tab = SettingsPane.passwordsTab(for: raw) { passwordsTab = tab }
        requestedPane = pane
        return true
    }
}

/// Opens Settings on the General pane, where profiles live.
struct ManageProfilesButton: View {
    var body: some View {
        Button("Manage Profiles…") {
            SettingsOpener.open(.general)
        }
    }
}

// MARK: - Shared actions

enum ProfileActions {
    /// Prompts for a name and creates a profile with the next unused color.
    static func createProfile(manager: ProfileManager) -> BrowserProfile? {
        guard let name = TextPrompt.name(title: "New Profile", initial: "Profile \(manager.profiles.count + 1)", confirm: "Create") else { return nil }
        guard !manager.isNameTaken(name) else {
            let alert = NSAlert()
            alert.messageText = "A profile named “\(name)” already exists."
            alert.informativeText = "Profile names must be different so each profile's synced logins stay separate."
            alert.runModal()
            return nil
        }
        let used = Set(manager.profiles.map(\.colorId))
        let color = ProfileColor.presets.first { !used.contains($0.id) } ?? ProfileColor.presets[manager.profiles.count % ProfileColor.presets.count]
        return manager.addProfile(name: name, colorId: color.id)
    }
}

// MARK: - Toolbar / sidebar menu

/// The profile avatar button. Opens a native menu: switch profile, open one in
/// a new window, create one, or manage them in Settings.
struct ProfileMenu: View {
    @ObservedObject var profileManager: ProfileManager
    let activeProfileId: UUID
    let onSwitch: (BrowserProfile) -> Void
    let onOpenInNewWindow: (BrowserProfile) -> Void

    private var active: BrowserProfile { profileManager.profile(for: activeProfileId) }

    var body: some View {
        AxolotlMenuButton(alignment: .trailing, minWidth: 240, debugID: "profile", items: { entries }) { _ in
            Image(nsImage: ProfileAvatar.image(for: active, size: 20))
                .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Profile: \(active.name)")
        .accessibilityLabel("Profile \(active.name)")
    }
}

extension ProfileMenu {
    /// The avatar menu: profiles (checked = this window's), open one in a new window,
    /// then new / manage.
    @MainActor
    var entries: [AxolotlMenuEntry] {
        let manager = profileManager
        var entries: [AxolotlMenuEntry] = [.header("Profiles")]
        for profile in manager.profiles {
            entries.append(.item(AxolotlMenuItem(id: "profile.\(profile.id)", title: profile.name,
                                              icon: .image(ProfileAvatar.image(for: profile, size: 16)),
                                              isChecked: profile.id == activeProfileId,
                                              action: { onSwitch(profile) })))
        }
        if manager.profiles.count > 1 {
            entries.append(.submenu("Open in New Window", icon: "macwindow.badge.plus", manager.profiles.map { profile in
                .button(profile.name, image: ProfileAvatar.image(for: profile, size: 16), id: "window.\(profile.id)") {
                    onOpenInNewWindow(profile)
                }
            }))
        }
        let settings = AxolotlSettingsOpener()
        entries += [
            .divider("p1"),
            .button("Add Profile…", icon: "person.badge.plus") {
                if let profile = ProfileActions.createProfile(manager: manager) { onSwitch(profile) }
            },
            .button("Manage Profiles…", icon: "person.2") { settings(.general) },
        ]
        return entries
    }
}

/// Menu items for the menu bar's Profiles menu (the system menu bar stays native).
struct ProfileMenuItems: View {
    @ObservedObject var profileManager: ProfileManager
    let activeProfileId: UUID?
    let onSwitch: (BrowserProfile) -> Void
    let onOpenInNewWindow: (BrowserProfile) -> Void

    var body: some View {
        ForEach(profileManager.profiles) { profile in
            Toggle(isOn: Binding(
                get: { profile.id == activeProfileId },
                set: { if $0 { onSwitch(profile) } }
            )) {
                Label { Text(profile.name) } icon: { Image(nsImage: ProfileAvatar.image(for: profile, size: 16)) }
            }
        }
        if profileManager.profiles.count > 1 {
            Menu("Open in New Window") {
                ForEach(profileManager.profiles) { profile in
                    Button(profile.name) { onOpenInNewWindow(profile) }
                }
            }
        }
        Divider()
        Button("New Profile…") {
            if let profile = ProfileActions.createProfile(manager: profileManager) { onSwitch(profile) }
        }
        ManageProfilesButton()
    }
}

// MARK: - Menu bar

/// What the key browser window exposes to the menu bar's Profiles menu.
struct ProfileCommandContext {
    let activeProfileId: UUID
    let switchTo: (BrowserProfile) -> Void
    let openInNewWindow: (BrowserProfile) -> Void
}

extension FocusedValues {
    @Entry var profileCommands: ProfileCommandContext?
    /// Opens the Import from Browser sheet in the focused window.
    @Entry var showBrowserImport: (() -> Void)?
}

struct ProfileCommands: Commands {
    @FocusedValue(\.profileCommands) private var context
    @FocusedValue(\.showBrowserImport) private var showBrowserImport

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import from Browser…") { showBrowserImport?() }
                .disabled(showBrowserImport == nil)
        }
        CommandMenu("Profiles") {
            ProfileMenuItems(
                profileManager: ProfileManager.shared,
                activeProfileId: context?.activeProfileId,
                onSwitch: { context?.switchTo($0) },
                onOpenInNewWindow: { context?.openInNewWindow($0) }
            )
        }
    }
}

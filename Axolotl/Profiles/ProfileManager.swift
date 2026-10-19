// Axolotl — Profile Manager
// Manages browser profiles: isolated history, cookies, and identity.
// Each profile gets its own persistent WKWebsiteDataStore.
// The Default profile uses the system persistent store for backwards compatibility.
import Foundation
import SwiftUI
import WebKit
import Combine

// MARK: - Profile color presets

struct ProfileColor: Identifiable, Codable, Equatable {
    let id: String   // e.g. "indigo"
    let r: Double
    let g: Double
    let b: Double

    var color: Color { Color(red: r, green: g, blue: b) }
    var nsColor: NSColor { NSColor(red: r, green: g, blue: b, alpha: 1) }

    /// 10–15% lighter variant for inactive tabs
    var lightVariant: Color {
        Color(red: min(1, r + 0.12), green: min(1, g + 0.12), blue: min(1, b + 0.12))
    }

    /// Existing ids keep their values so saved profiles don't change color.
    static let presets: [ProfileColor] = [
        ProfileColor(id: "indigo",   r: 0.29, g: 0.33, b: 0.80),
        ProfileColor(id: "blue",     r: 0.04, g: 0.48, b: 0.96),
        ProfileColor(id: "sky",      r: 0.18, g: 0.60, b: 0.86),
        ProfileColor(id: "cyan",     r: 0.20, g: 0.72, b: 0.82),
        ProfileColor(id: "teal",     r: 0.10, g: 0.60, b: 0.60),
        ProfileColor(id: "mint",     r: 0.22, g: 0.76, b: 0.62),
        ProfileColor(id: "emerald",  r: 0.13, g: 0.65, b: 0.45),
        ProfileColor(id: "green",    r: 0.20, g: 0.70, b: 0.30),
        ProfileColor(id: "lime",     r: 0.55, g: 0.76, b: 0.18),
        ProfileColor(id: "yellow",   r: 0.95, g: 0.77, b: 0.12),
        ProfileColor(id: "amber",    r: 0.85, g: 0.55, b: 0.10),
        ProfileColor(id: "orange",   r: 0.96, g: 0.50, b: 0.12),
        ProfileColor(id: "coral",    r: 0.90, g: 0.40, b: 0.30),
        ProfileColor(id: "red",      r: 0.90, g: 0.24, b: 0.22),
        ProfileColor(id: "rose",     r: 0.85, g: 0.25, b: 0.42),
        ProfileColor(id: "pink",     r: 0.95, g: 0.38, b: 0.62),
        ProfileColor(id: "magenta",  r: 0.82, g: 0.26, b: 0.74),
        ProfileColor(id: "violet",   r: 0.55, g: 0.27, b: 0.85),
        ProfileColor(id: "purple",   r: 0.64, g: 0.38, b: 0.92),
        ProfileColor(id: "brown",    r: 0.58, g: 0.42, b: 0.28),
        ProfileColor(id: "sand",     r: 0.74, g: 0.64, b: 0.48),
        ProfileColor(id: "slate",    r: 0.30, g: 0.35, b: 0.42),
        ProfileColor(id: "graphite", r: 0.22, g: 0.22, b: 0.24),
    ]

    init(id: String, r: Double, g: Double, b: Double) {
        self.id = id; self.r = r; self.g = g; self.b = b
    }
}

// MARK: - BrowserProfile

struct BrowserProfile: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var colorId: String   // references ProfileColor.id
    /// SF Symbol shown in the avatar instead of the initial (nil = initial).
    var iconName: String?
    /// true = uses WKWebsiteDataStore.default() (legacy / Default profile)
    var isDefault: Bool

    var profileColor: ProfileColor {
        ProfileColor.presets.first { $0.id == colorId } ?? ProfileColor.presets[0]
    }

    // Convenience for the toolbar tint: a color slightly transparent over dark BG
    var toolbarTint: Color { profileColor.color.opacity(0.18) }
    var toolbarTintStrong: Color { profileColor.color.opacity(0.30) }
    var accentSolid: Color { profileColor.color }
}

// MARK: - ProfileTabState
// Stores which tabs were open per profile so switching preserves them.

struct ProfileTabSnapshot: Codable {
    struct TabEntry: Codable {
        let id: UUID
        let urlString: String?
        let title: String
    }
    var tabs: [TabEntry]
    var activeTabId: UUID?
}

// MARK: - ProfileManager

final class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published private(set) var profiles: [BrowserProfile] = []
    @Published private(set) var lastActiveProfileId: UUID = UUID()

    // Data store cache: profile UUID → WKWebsiteDataStore
    private var dataStores: [UUID: WKWebsiteDataStore] = [:]

    private let profilesKey = "axolotl_profiles_v1"
    private let activeProfileKey = "axolotl_active_profile_v1"

    private init() {
        let saved = Self.loadProfiles()
        if saved.isEmpty {
            let def = BrowserProfile(
                id: UUID(),
                name: "Personal",
                colorId: "indigo",
                isDefault: true
            )
            profiles = [def]
            lastActiveProfileId = def.id
            saveProfiles()
        } else {
            profiles = saved
            if let storedActive = UserDefaults.standard.string(forKey: "axolotl_active_profile_v1"),
               let uuid = UUID(uuidString: storedActive),
               saved.contains(where: { $0.id == uuid }) {
                lastActiveProfileId = uuid
            } else {
                lastActiveProfileId = saved[0].id
            }
        }
    }

    func profile(for profileId: UUID) -> BrowserProfile {
        profiles.first { $0.id == profileId }
            ?? profiles.first
            ?? BrowserProfile(id: profileId, name: "Personal", colorId: "indigo", isDefault: true)
    }

    func validProfileId(_ profileId: UUID) -> UUID {
        profiles.contains(where: { $0.id == profileId }) ? profileId : (profiles.first?.id ?? profileId)
    }

    // MARK: - Data store

    func dataStore(for profileId: UUID) -> WKWebsiteDataStore {
        if let cached = dataStores[profileId] { return cached }
        let profile = profiles.first { $0.id == profileId }
        let store: WKWebsiteDataStore
        if profile?.isDefault == true {
            store = .default()
        } else {
            // Persistent non-default store keyed by profile UUID
            if #available(macOS 14.0, *) {
                store = WKWebsiteDataStore(forIdentifier: profileId)
            } else {
                // Fallback for macOS 13: use non-persistent (no cookie persistence pre-14)
                store = .nonPersistent()
            }
        }
        dataStores[profileId] = store
        return store
    }

    /// Remembers the last profile used for the next newly-created window.
    func markLastActive(profileId: UUID) {
        guard profiles.contains(where: { $0.id == profileId }) else { return }
        lastActiveProfileId = profileId
        UserDefaults.standard.set(profileId.uuidString, forKey: activeProfileKey)
    }

    // MARK: - CRUD

    func addProfile(name: String, colorId: String) -> BrowserProfile {
        let p = BrowserProfile(id: UUID(), name: name, colorId: colorId, isDefault: false)
        profiles.append(p)
        saveProfiles()
        return p
    }

    /// Whether another profile already uses `name` (compared the way synced logins are keyed).
    func isNameTaken(_ name: String, excluding profileId: UUID? = nil) -> Bool {
        guard let key = PasswordVault.nameKey(name) else { return false }
        return profiles.contains { $0.id != profileId && PasswordVault.nameKey($0.name) == key }
    }

    /// Renames a profile and re-keys its synced logins. Returns false (and
    /// changes nothing) if the name is blank, taken, or the logins couldn't move.
    @discardableResult
    func rename(profileId: UUID, to name: String) -> Bool {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }),
              PasswordVault.nameKey(name) != nil, !isNameTaken(name, excluding: profileId) else { return false }
        do {
            try PasswordVault.shared.rekeyForRename(profile: profileId, from: profiles[idx].name, to: name)
        } catch {
            return false
        }
        profiles[idx].name = name
        saveProfiles()
        return true
    }

    func setIcon(profileId: UUID, iconName: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].iconName = iconName
        saveProfiles()
    }

    /// The profile `offset` steps away in the list, wrapping around (swipe switching).
    func neighbor(of profileId: UUID, offset: Int) -> BrowserProfile? {
        guard profiles.count > 1, let i = profiles.firstIndex(where: { $0.id == profileId }) else { return nil }
        return profiles[(i + offset % profiles.count + profiles.count) % profiles.count]
    }

    func recolor(profileId: UUID, colorId: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].colorId = colorId
        saveProfiles()
    }

    /// Deletes a profile and wipes all its website data and on-disk history/chats.
    /// Synced iCloud logins are kept for other Macs unless `deleteSyncedLogins`.
    func deleteProfile(profileId: UUID, deleteSyncedLogins: Bool = false, completion: @escaping () -> Void) {
        // Always keep at least one profile. Still invoke completion so callers can dismiss UI.
        guard profiles.count > 1, profiles.contains(where: { $0.id == profileId }) else {
            DispatchQueue.main.async { completion() }
            return
        }
        let store = dataStore(for: profileId)
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.removeData(ofTypes: types, modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Re-check: an overlapping delete may have already removed this or other profiles.
                guard self.profiles.count > 1, self.profiles.contains(where: { $0.id == profileId }) else {
                    completion()
                    return
                }
                // Logins first: their synced key depends on the profile list still holding this name.
                PasswordVault.shared.deleteAll(profile: profileId, includingSynced: deleteSyncedLogins)
                AutofillStore.deleteAll(profile: profileId)
                BrowserImporter.forgetSources(axolotlProfileId: profileId)
                UsageStore.forget(profileId)
                let wasDefault = self.profiles.first { $0.id == profileId }?.isDefault == true
                self.profiles.removeAll { $0.id == profileId }
                self.dataStores.removeValue(forKey: profileId)
                if !wasDefault { WKWebsiteDataStore.remove(forIdentifier: profileId) { _ in } }
                if self.lastActiveProfileId == profileId, let first = self.profiles.first {
                    self.lastActiveProfileId = first.id
                }
                self.saveProfiles()
                Self.removeProfileDataDirectory(profileId: profileId)
                completion()
            }
        }
    }

    /// Removes the profile's Application Support directory (history, chats, summaries)
    /// so "delete profile" actually deletes everything, not just website data.
    private static func removeProfileDataDirectory(profileId: UUID) {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("Axolotl/Profiles/\(profileId.uuidString)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Persistence

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: profilesKey)
        }
        UserDefaults.standard.set(lastActiveProfileId.uuidString, forKey: activeProfileKey)
    }

    private static func loadProfiles() -> [BrowserProfile] {
        guard let data = UserDefaults.standard.data(forKey: "axolotl_profiles_v1"),
              let decoded = try? JSONDecoder().decode([BrowserProfile].self, from: data) else {
            return []
        }
        return decoded
    }
}

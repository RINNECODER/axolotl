import Combine
import SwiftUI

/// Runs `KeychainMigrator` once after an update, behind a short explainer
/// so the last macOS access prompt doesn't come out of nowhere.
final class KeychainMigrationCoordinator: ObservableObject {
    static let shared = KeychainMigrationCoordinator()

    @Published private(set) var presenter: UUID?
    @Published private(set) var isMigrating = false
    @Published private(set) var failedCount = 0

    private var checked = false
    private let migrator = KeychainMigrator(store: .shared, defaults: .standard)

    nonisolated deinit {}

    /// Called by each window; the first one to ask presents the explainer.
    func checkAtLaunch(window: UUID) {
        guard !checked else { return }
        checked = true
        let migrator = migrator
        guard !migrator.isDone else { return }
        Task {
            // Keychain reads stay off the main thread; the vault migration runs before the check.
            let pending = await Task.detached {
                PasswordVault.shared.migrateToNameKeys()
                return migrator.legacyItemsExist()
            }.value
            if pending {
                presenter = window
            } else {
                UserDefaults.standard.set(true, forKey: migrator.doneKey)
            }
        }
    }

    func migrate() {
        var migrator = migrator
        let domains = PasswordVault.shared.syncDomainSnapshot()
        migrator.vaultDomain = { domains[$0] ?? $0 }
        isMigrating = true
        Task {
            let result = await Task.detached { migrator.run() }.value
            isMigrating = false
            failedCount = result.failed
            ChatGPTAuth.shared.reloadFromKeychain()
            if result.failed == 0 { presenter = nil }
        }
    }

    /// Asks again on the next launch.
    func later() { presenter = nil }
}

struct KeychainMigrationSheet: View {
    @ObservedObject var coordinator: KeychainMigrationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Moving your saved passwords", systemImage: "key.fill")
                .font(.headline)
            Text("Luna is moving your saved passwords and keys to a more secure store, so macOS stops asking for permission after updates.")
            Text("macOS may ask one last time. Enter your Mac password and choose **Always Allow**.")
            if coordinator.failedCount > 0 {
                Text("\(coordinator.failedCount) item\(coordinator.failedCount == 1 ? "" : "s") couldn't be moved yet. They stay where they are, and Luna will try again next launch.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(coordinator.failedCount > 0 ? "Close" : "Later") { coordinator.later() }
                    .disabled(coordinator.isMigrating)
                Button(coordinator.failedCount > 0 ? "Try Again" : "Continue") { coordinator.migrate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(coordinator.isMigrating)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

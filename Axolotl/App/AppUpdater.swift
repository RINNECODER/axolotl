// Chrome-style auto-update for the sandboxed Axolotl app (Sparkle 2).
// Axolotl Dev builds from source and never links Sparkle: everything that touches it is behind !AXOLOTL_DEV.
import SwiftUI
import Combine
#if !AXOLOTL_DEV
import Sparkle
#endif

enum UpdateStatus: Equatable {
    case idle, checking, upToDate
    /// Found but not downloaded (automatic updates are off): Sparkle's window installs it.
    case available
    /// Downloaded and staged: installs on quit, or now with "Relaunch to update".
    case ready
    case failed(String)
}

/// What the top chrome and the app menu show for an update.
enum UpdateChrome {
    static func showsPill(_ status: UpdateStatus, isDevBuild: Bool = DevMode.isDevBuild) -> Bool {
        !isDevBuild && (status == .ready || status == .available)
    }

    static func menuEntries(_ status: UpdateStatus, isDevBuild: Bool = DevMode.isDevBuild,
                            action: @escaping () -> Void) -> [AxolotlMenuEntry] {
        guard showsPill(status, isDevBuild: isDevBuild) else { return [] }
        return [.button(status == .ready ? "Relaunch to update" : "Update Axolotl…",
                        icon: "arrow.triangle.2.circlepath", action: action),
                .divider("update")]
    }

    /// Top of the app menu; empty in Axolotl Dev.
    static func appMenuEntries() -> [AxolotlMenuEntry] {
        #if AXOLOTL_DEV
        return []
        #else
        let updater = AppUpdater.shared
        return menuEntries(updater.status, action: updater.installNow)
        #endif
    }
}

/// Chrome's colored "Update" button, next to the ⋯ menu. Nothing in Axolotl Dev.
struct UpdatePill: View {
    var body: some View {
        #if AXOLOTL_DEV
        EmptyView()
        #else
        UpdatePillContent(updater: .shared)
        #endif
    }
}

#if !AXOLOTL_DEV
private struct UpdatePillContent: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        if UpdateChrome.showsPill(updater.status) {
            Button(action: updater.installNow) {
                Text("Update")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(Capsule().fill(AxolotlSurface.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help(updater.status == .ready ? "Relaunch to update Axolotl" : "Update Axolotl")
            .accessibilityLabel(updater.status == .ready ? "Relaunch to update Axolotl" : "Update Axolotl")
        }
    }
}

/// Owns Sparkle's updater. Checks on launch and every 24 h (Info.plist), downloads silently,
/// installs on quit; the pill / menu item installs now and relaunches.
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    @Published private(set) var status: UpdateStatus = .idle
    private var controller: SPUStandardUpdaterController!
    private var immediateInstall: (() -> Void)?
    private var started = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    /// Called once at launch (never in unit tests). Debug builds don't update themselves.
    func start() {
        #if !DEBUG
        controller.startUpdater()
        started = true
        #endif
    }

    /// "Automatically update Axolotl": download and stage updates without asking.
    var automaticallyUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { objectWillChange.send(); controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Settings → About's button: a quiet check whose result shows inline.
    func checkNow() {
        guard started else { status = .failed("Updates are off in debug builds"); return }
        guard status != .ready else { return }
        status = .checking
        controller.updater.checkForUpdatesInBackground()
    }

    func installNow() {
        if let immediateInstall { immediateInstall() } else { controller.checkForUpdates(nil) }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock: @escaping () -> Void) -> Bool {
        immediateInstall = immediateInstallationBlock
        status = .ready
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard status == .checking else { return }
        if let error = error as NSError?, !(error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)) {
            status = .failed(error.localizedDescription)
        } else {
            status = .upToDate
        }
    }

    // MARK: SPUStandardUserDriverDelegate (gentle reminders: no Sparkle window for background finds)

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        if !handleShowingUpdate, status != .ready { status = .available }
    }
}
#endif

// Debug builds only: drive Luna's UI from outside (screenshots without
// synthesizing clicks). Post a distributed notification named
// "com.luna.browser.debugUI" whose object is a command, e.g.
//   menu:chrome.app   submenu:Extensions   key:down   close
//   settings:appearance   glass:0   appearance:dark
#if DEBUG
import AppKit
import SwiftUI

extension Notification.Name {
    static let lunaDebugOpenMenu = Notification.Name("LunaDebugOpenMenu")
}

enum DebugUIDriver {
    private static var observer: NSObjectProtocol?

    static func install() {
        guard observer == nil, ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.luna.browser.debugUI"), object: nil, queue: .main
        ) { note in
            guard let command = note.object as? String else { return }
            MainActor.assumeIsolated { run(command) }
        }
    }

    @MainActor
    static func run(_ command: String) {
        let parts = command.split(separator: ":", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "menu": NotificationCenter.default.post(name: .lunaDebugOpenMenu, object: arg)
        case "submenu", "hover": LunaMenuController.current?.debugHover(title: arg)
        case "key": LunaMenuController.current?.debugKey(arg)
        case "close": LunaMenuController.current?.close()
        case "front":
            // Put browser / settings windows on the current Space, behind other apps' windows,
            // without activating Luna: they stay capturable without covering anything.
            for window in NSApp.windows where window.isVisible && window.frame.width > 300 && window.parent == nil {
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                let ours = Set(NSApp.windows.map(\.windowNumber))
                if let front = NSWindow.windowNumbers(options: .allApplications)?.map(\.intValue)
                    .first(where: { !ours.contains($0) }) {
                    window.order(.below, relativeTo: front)
                } else {
                    window.orderBack(nil)
                }
            }
        case "pin": LunaMenuController.debugPinned = arg == "1"
        case "settings":
            SettingsRouter.shared.requestedPane = SettingsPane(rawValue: arg)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case "glass": UserDefaults.standard.set(arg == "1", forKey: LiquidGlass.defaultsKey)
        case "appearance": UserDefaults.standard.set(arg, forKey: "luma_appearance")
        default: break
        }
    }
}
#endif

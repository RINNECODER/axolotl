// Extensions in the ⋯ menu, and the Manage Extensions shortcut (Luna menu rows).
import SwiftUI
import WebKit

/// Opens the Settings tab on a pane (passed to Luna menus that link to Settings).
struct LunaSettingsOpener {
    func callAsFunction(_ pane: SettingsPane? = nil) {
        SettingsOpener.open(pane)
    }
}

enum ExtensionMenuEntries {
    /// "Extensions ›" with each extension's action, then "Manage Extensions…";
    /// just "Manage Extensions…" when none are installed.
    @MainActor
    static func build(host: ExtensionHost, settings: LunaSettingsOpener, icon: String? = nil) -> [LunaMenuEntry] {
        let manage = LunaMenuEntry.button("Manage Extensions…", icon: host.loaded.isEmpty ? icon : nil) {
            settings(.extensions)
        }
        let loaded = host.loaded
        guard !loaded.isEmpty else { return [manage] }
        var children: [LunaMenuEntry] = loaded.map { item in
            let action = item.context.action(for: host.activeTabAdapter)
            let image = action?.icon(for: CGSize(width: 16, height: 16))
                ?? item.context.webExtension.icon(for: CGSize(width: 16, height: 16))
            return .button(item.record.name, image: image, id: "ext.\(item.record.id)") {
                host.performAction(item.context)
            }
        }
        children.append(.divider("ext.sep"))
        children.append(manage)
        return [.submenu("Extensions", icon: icon, children)]
    }
}

/// Hands the hosting NSView to the extension host so popups can anchor to it.
struct PopupAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { register(view) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

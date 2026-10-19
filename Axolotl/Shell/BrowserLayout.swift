import Foundation

/// Window layout. Sidebar is Arc-style; the rest mirror Helium's layouts.
enum BrowserLayout: String, CaseIterable, Identifiable {
    /// Vertical sidebar with spaces, pinned and today tabs.
    case sidebar
    /// One row: navigation, address field, tabs inline, toolbar icons.
    case compact
    /// Row 1: navigation, address field, icons. Row 2: tabs.
    case dynamic
    /// Row 1: tabs beside the window controls. Row 2: navigation, address field, icons.
    case classic

    static let defaultsKey = "axolotl_layout"

    var id: String { rawValue }

    /// Reads a stored value, mapping the pre-Helium "topTabs" layout to Classic.
    init(stored: String) {
        self = stored == "topTabs" ? .classic : (BrowserLayout(rawValue: stored) ?? .sidebar)
    }

    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .compact: return "Compact"
        case .dynamic: return "Dynamic"
        case .classic: return "Classic"
        }
    }

    var summary: String {
        switch self {
        case .sidebar: return "Vertical tabs, folders and spaces in a sidebar."
        case .compact: return "Address bar and tabs share a single row."
        case .dynamic: return "Address bar on top, tabs underneath."
        case .classic: return "Tabs on top, address bar underneath."
        }
    }
}

/// UserDefaults keys for window chrome options (Settings → Appearance).
enum ChromePrefs {
    static let centeredAddressBar = "axolotl_centered_address_bar"
    static let minimalURL = "axolotl_minimal_url"
    static let addressBarProgress = "axolotl_address_bar_progress"
    static let frameless = "axolotl_frameless"
    static let alwaysShowTopBar = "axolotl_frameless_always_show_top_bar"
    static let roundedFrame = "axolotl_rounded_frame"
    static let showHomeButton = "axolotl_show_home_button"
    static let hideWindowButtons = "axolotl_hide_window_buttons"
    /// Sidebar layout: a toolbar row (navigation, address field, buttons) above the page.
    static let showToolbar = "axolotl_show_toolbar"
    /// A row of the profile's bookmarks above the page.
    static let showBookmarksBar = "axolotl_show_bookmarks_bar"
}

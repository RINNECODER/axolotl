//
//  AxolotlApp.swift
//  Axolotl
//
//  Root app entry for the Axolotl browser.
//
import SwiftUI

@main
struct AxolotlApp: App {
    /// The main window's scene id, so ⌘⇧T can reopen it after it closed.
    static let mainWindowId = "main"

    init() {
        // Before anything opens a store or WebKit data store: copy a Luna install's data over once.
        LegacyLunaMigration.runAtLaunch()
        NSWindow.allowsAutomaticWindowTabbing = false
        // BrowserCommands owns View ▸ Enter Full Screen (⌃⌘F); drop AppKit's fn-F duplicate.
        UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")
        BrowserImporter.scheduleLaunchSync()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        DebugUIDriver.install()
        #endif
        // "Connect agents" MCP server, if turned on in Settings (never inside unit tests).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DispatchQueue.main.async { AxolotlMCPBridge.shared.applySettings() }
        }
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowId) {
            // Unit tests run inside the app; don't open a browser window that
            // would load (and save) the user's real profile.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                ContentView()
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        .commands {
            BrowserCommands()
            ProfileCommands()
            // Settings opens as a tab (axolotl://settings), like Chrome; there is no Settings window.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { SettingsOpener.open() }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .help) {
                Button("Show Welcome…") { OnboardingState.showAgain() }
            }
        }
    }
}

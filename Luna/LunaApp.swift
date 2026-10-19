//
//  LunaApp.swift
//  Luna
//
//  Root app entry for the Luna browser.
//
import SwiftUI

@main
struct LunaApp: App {
    init() {
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
            DispatchQueue.main.async { LunaMCPBridge.shared.applySettings() }
        }
    }

    var body: some Scene {
        WindowGroup {
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
            // Settings opens as a tab (luna://settings), like Chrome; there is no Settings window.
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

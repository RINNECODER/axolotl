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
        BrowserImporter.scheduleLaunchSync()
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        #endif
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
        .commands { ProfileCommands() }
        Settings {
            SettingsView()
        }
    }
}

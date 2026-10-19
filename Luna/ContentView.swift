//
//  ContentView.swift
//  Luna
//
//  Root view that hosts the main browser shell.
//
import SwiftUI
import AppKit

struct ContentView: View {
    @AppStorage("luma_appearance") private var appearance: String = "system"
    @ObservedObject private var keychainMigration = KeychainMigrationCoordinator.shared
    @State private var windowID = UUID()

    var body: some View {
        BrowserShellView()
            .onAppear { applyLunaAppearance(appearance) }
            .onChange(of: appearance) { _, new in applyLunaAppearance(new) }
            .task { keychainMigration.checkAtLaunch(window: windowID) }
            .sheet(isPresented: Binding(get: { keychainMigration.presenter == windowID },
                                        set: { if !$0 { keychainMigration.later() } })) {
                KeychainMigrationSheet(coordinator: keychainMigration)
            }
    }

    private func applyLunaAppearance(_ value: String) {
        switch value {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
}

#Preview {
    BrowserShellView()
}

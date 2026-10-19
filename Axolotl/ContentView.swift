//
//  ContentView.swift
//  Axolotl
//
//  Root view that hosts the main browser shell.
//
import SwiftUI
import AppKit

struct ContentView: View {
    @AppStorage("axolotl_appearance") private var appearance: String = "system"
    @ObservedObject private var keychainMigration = KeychainMigrationCoordinator.shared
    @ObservedObject private var onboarding = OnboardingCoordinator.shared
    @State private var windowID = UUID()
    @State private var window: NSWindow?

    var body: some View {
        BrowserShellView()
            .onAppear { applyAxolotlAppearance(appearance) }
            .onChange(of: appearance) { _, new in applyAxolotlAppearance(new) }
            .task { keychainMigration.checkAtLaunch(window: windowID) }
            .sheet(isPresented: Binding(get: { keychainMigration.presenter == windowID },
                                        set: { if !$0 { keychainMigration.later() } })) {
                KeychainMigrationSheet(coordinator: keychainMigration)
            }
            // Welcome flow: one window at a time, after the keychain explainer if both are due.
            .sheet(isPresented: Binding(get: { onboarding.presenter == windowID && keychainMigration.presenter == nil },
                                        set: { if !$0 { onboarding.dismiss() } })) {
                OnboardingView(startAt: onboarding.startStep) { onboarding.dismiss() }
            }
            .background(WindowReader { window = $0 })
            .onAppear { onboarding.register(window: windowID) }
            .onDisappear { onboarding.unregister(window: windowID) }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                if let window, note.object as? NSWindow === window { onboarding.windowBecameActive(windowID) }
            }
            .onChange(of: onboarding.presenter) { _, presenter in
                if presenter == windowID { window?.makeKeyAndOrderFront(nil) }
            }
    }

    private func applyAxolotlAppearance(_ value: String) {
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

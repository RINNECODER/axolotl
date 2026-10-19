import SwiftUI

/// Settings controls drawn from `CustomizationRegistry`, so a setting's label, helper text and allowed
/// values are written once and agents and people see the same names.
///
/// Changing a setting a layout template manages switches the template to Custom (see `LayoutTemplate.switchToCustom`).
enum RegistrySettings {
    static func setting(_ key: String) -> CustomizableSetting {
        guard let setting = CustomizationRegistry.setting(key), setting.defaultsKey != nil else {
            preconditionFailure("\(key) is not a plain registry preference")
        }
        return setting
    }

    /// Call before writing `key` from Settings.
    static func willChange(_ key: String, env: CustomizationEnvironment = .live) {
        if LayoutTemplate.managedKeys.contains(key) { LayoutTemplate.switchToCustom(env: env) }
    }
}

/// A toggle for a registry bool.
struct RegistryToggle: View {
    private let setting: CustomizableSetting
    @AppStorage private var value: Bool

    init(_ key: String) {
        setting = RegistrySettings.setting(key)
        var initial = false
        if case .bool(let b) = setting.read(.live) { initial = b }
        _value = AppStorage(wrappedValue: initial, setting.defaultsKey!)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { value }, set: { RegistrySettings.willChange(setting.key); value = $0 })) {
            Text(setting.title)
            if let help = setting.help { Text(help) }
        }
    }
}

/// A pop-up for a registry string choice.
struct RegistryPicker: View {
    private let setting: CustomizableSetting
    @AppStorage private var value: String

    init(_ key: String) {
        setting = RegistrySettings.setting(key)
        _value = AppStorage(wrappedValue: setting.read(.live).stringValue ?? "", setting.defaultsKey!)
    }

    var body: some View {
        if case .choice(let options) = setting.kind {
            LunaPicker(setting.title, subtitle: setting.help,
                       selection: Binding(get: { value }, set: { RegistrySettings.willChange(setting.key); value = $0 }),
                       options: options.map { .init($0.value, $0.title) })
        }
    }
}

/// A pop-up for a registry integer choice.
struct RegistryIntPicker: View {
    private let setting: CustomizableSetting
    @AppStorage private var value: Int

    init(_ key: String) {
        setting = RegistrySettings.setting(key)
        _value = AppStorage(wrappedValue: setting.read(.live).intValue ?? 0, setting.defaultsKey!)
    }

    var body: some View {
        if case .intChoice(let options) = setting.kind {
            LunaPicker(setting.title, subtitle: setting.help,
                       selection: Binding(get: { value }, set: { RegistrySettings.willChange(setting.key); value = $0 }),
                       options: options.map { .init($0.value, $0.title) })
        }
    }
}

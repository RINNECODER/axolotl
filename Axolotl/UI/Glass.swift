// Axolotl — surface foundation.
// Settings → Appearance → "Liquid Glass" picks between two looks:
//  • on  (default): native .glassEffect on macOS 26+ (material blur below), as before.
//  • off: Axolotl's own solid surfaces — opaque fills from `AxolotlSurface`, a
//    hairline border and a small shadow. No blur, materials or vibrancy.
// Every glass / material / vibrancy use in the app goes through this file so
// the switch is one place and updates live.
import SwiftUI
import AppKit

// MARK: - Setting

enum LiquidGlass {
    /// UserDefaults key (bool, default true). Registry key: `appearance.liquidGlass`.
    static let defaultsKey = "axolotl_liquid_glass"
    static let defaultValue = true

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil ? defaultValue : UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

// MARK: - Tokens (solid look)

extension Color {
    /// A color that follows the view's appearance (light / dark) on its own.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    init(axolotlHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: .axolotlHex(hex, alpha: alpha))
    }
}

extension NSColor {
    static func axolotlHex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Axolotl's surface colors. Window, sidebar, toolbar, active tab and accent come from the theme
/// (Settings → Appearance → Theme); reading them inside a view body re-renders it when the theme changes.
enum AxolotlSurface {
    private static var theme: Theme { ThemeStore.shared.theme }
    /// The window backdrop behind tabs and content (replaces sidebar / titlebar vibrancy).
    static var window: Color { theme.color(.window) }
    /// A floating sidebar sitting over the page.
    static var sidebar: Color { theme.color(.sidebar) }
    /// The tab strip / toolbar backdrop in top layouts.
    static var toolbar: Color { theme.color(.toolbar) }
    /// The selected tab.
    static var activeTab: Color { theme.color(.activeTab) }
    static var accent: Color { theme.color(.accent) }
    /// Cards, bars, capsules and popups.
    static let raised = Color(light: .white, dark: .axolotlHex(0x2A2A2D))
    /// Hairline border around raised surfaces (stronger with high contrast).
    static var stroke: Color {
        let a: CGFloat = theme.highContrast ? 0.24 : 0.10
        return Color(light: .black.withAlphaComponent(a), dark: .white.withAlphaComponent(a))
    }
    /// Secondary labels (inactive tab titles): the primary color with high contrast.
    static var secondaryText: Color { theme.highContrast ? .primary : .secondary }
    /// Hover and pressed fills for controls on any surface.
    static let hover = Color(light: .black.withAlphaComponent(0.06), dark: .white.withAlphaComponent(0.08))
    static let pressed = Color(light: .black.withAlphaComponent(0.11), dark: .white.withAlphaComponent(0.14))
    /// Shadow under raised surfaces.
    static let shadow = Color(light: .black.withAlphaComponent(0.12), dark: .black.withAlphaComponent(0.45))
}

// MARK: - Shared start page tint (dark grey)

let startPageGlassTint = Color(red: 0.09, green: 0.09, blue: 0.10)
let startPageGlassTintOpacity: Double = 0.88

// MARK: - VisualEffectView (NSVisualEffectView wrapper)

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

/// A window / sidebar backdrop: vibrancy with Liquid Glass on, a solid fill off.
struct AxolotlBackdrop: View {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var solid: Color = AxolotlSurface.window
    var surface: GlassSurface? = nil

    var body: some View {
        let glass = ThemeStore.shared.glass
        if glass.isOn(surface) {
            ZStack {
                VisualEffectView(material: material, blendingMode: blendingMode, state: state)
                if glass.tint > 0 { solid.opacity(Double(glass.tint) / 100) }
            }
        } else {
            solid
        }
    }
}

/// The start page / chat backdrop: under-window material with a near-opaque
/// dark wash (glass on), or the same dark grey, opaque (glass off).
struct StartPageBackdrop: View {
    var surface: GlassSurface = .startPage

    var body: some View {
        let glass = ThemeStore.shared.glass.isOn(surface)
        ZStack {
            if glass {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow, state: .active)
            }
            startPageGlassTint.opacity(glass ? startPageGlassTintOpacity : 1)
        }
    }
}

/// A shape filled with a material (glass on) or a solid token with a hairline
/// border (glass off). Drop-in for `shape.fill(.regularMaterial)`.
struct AxolotlMaterialFill<S: InsettableShape>: View {
    var shape: S
    var material: Material = .regularMaterial
    var solid: Color = AxolotlSurface.raised
    var strokesWhenSolid = true
    var surface: GlassSurface? = .popovers

    var body: some View {
        let glass = ThemeStore.shared.glass
        if glass.isOn(surface) {
            // Blur off: clear glass, a see-through wash of the solid color.
            if glass.blur { shape.fill(material) } else { shape.fill(solid.opacity(0.55)) }
        } else {
            shape.fill(solid).overlay(shape.strokeBorder(strokesWhenSolid ? AxolotlSurface.stroke : .clear, lineWidth: 1))
        }
    }
}

// MARK: - Glass surface modifier

/// Native Liquid Glass on macOS 26+ (material-blur fallback below) when the
/// setting is on; Axolotl's solid raised surface when it is off.
/// `interactive` enables the live-warp variant / a hover fill.
struct AxolotlGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive: Bool = false
    var tint: Color? = nil
    var surface: GlassSurface? = nil
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let settings = ThemeStore.shared.glass
        if !settings.isOn(surface) {
            content
                .background(shape.fill(AxolotlSurface.hover.opacity(interactive && isHovering ? 1 : 0)))
                .background(shape.fill(tint ?? AxolotlSurface.raised))
                .overlay(shape.stroke(AxolotlSurface.stroke, lineWidth: 1))
                .compositingGroup()
                .shadow(color: AxolotlSurface.shadow, radius: 6, y: 2)
                .onHover { if interactive { isHovering = $0 } }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass(settings), in: shape)
        } else {
            content
                .background(shape.fill(settings.blur ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.clear)))
                .background(shape.fill(themeTint(settings) ?? .clear))
                .background(shape.fill(Color.white.opacity(0.06)))
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    /// The caller's tint, else the accent at the chosen glass tint strength.
    private func themeTint(_ settings: GlassSettings) -> Color? {
        tint ?? (settings.tint > 0 ? AxolotlSurface.accent.opacity(Double(settings.tint) / 100) : nil)
    }

    @available(macOS 26.0, *)
    private func glass(_ settings: GlassSettings) -> Glass {
        var g: Glass = settings.blur ? .regular : .clear
        if let tint = themeTint(settings) { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups sibling glass shapes (macOS 26+, setting on); a no-op otherwise.
private struct AxolotlGlassContainer: ViewModifier {
    var spacing: CGFloat?

    func body(content: Content) -> some View {
        if ThemeStore.shared.glass.master, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Glass (or solid) capsule — the default shape across the app's controls.
    func axolotlGlassCapsule(interactive: Bool = false, tint: Color? = nil, surface: GlassSurface? = nil) -> some View {
        modifier(AxolotlGlass(shape: Capsule(style: .continuous), interactive: interactive, tint: tint, surface: surface))
    }

    /// Glass (or solid) rounded rectangle.
    func axolotlGlass(cornerRadius: CGFloat, interactive: Bool = false, tint: Color? = nil,
                   surface: GlassSurface? = nil) -> some View {
        modifier(AxolotlGlass(
            shape: RoundedRectangle(cornerRadius: ThemeStore.shared.theme.radius(cornerRadius), style: .continuous),
            interactive: interactive,
            tint: tint,
            surface: surface
        ))
    }

    /// Groups sibling glass shapes so they share one sampling region and can
    /// morph together (no-op below macOS 26 or with Liquid Glass off).
    func axolotlGlassContainer(spacing: CGFloat? = nil) -> some View {
        modifier(AxolotlGlassContainer(spacing: spacing))
    }
}

// MARK: - Focus shadow (input bars)

/// A small, soft drop shadow that deepens slightly while the field has focus.
/// No colored ring or glow.
struct FocusShadow: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        content
            .compositingGroup()
            .shadow(color: .black.opacity(isActive ? 0.22 : 0.10), radius: isActive ? 7 : 3, y: isActive ? 2.5 : 1)
            .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

extension View {
    func focusShadow(_ isActive: Bool) -> some View { modifier(FocusShadow(isActive: isActive)) }
}

// MARK: - Glass icon button (circular, toolbar-grade)

/// Circular icon button with a hover fill — the standard toolbar control shape.
struct GlassIconButton: View {
    let systemName: String
    var size: CGFloat = 28
    var iconSize: CGFloat = 12
    var isEnabled: Bool = true
    var accessibilityLabel: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(
            Circle()
                .fill(Color.primary.opacity(isHovering && isEnabled ? 0.12 : 0))
        )
        .onHover { isHovering = $0 }
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

// MARK: - HairlineDivider (1px, very low opacity)

struct HairlineDivider: View {
    var opacity: Double = 0.2

    var body: some View {
        Rectangle()
            .fill(.primary.opacity(opacity))
            .frame(height: 1)
    }
}

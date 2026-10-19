// Luna — surface foundation.
// Settings → Appearance → "Liquid Glass" picks between two looks:
//  • on  (default): native .glassEffect on macOS 26+ (material blur below), as before.
//  • off: Luna's own solid surfaces — opaque fills from `LunaSurface`, a
//    hairline border and a small shadow. No blur, materials or vibrancy.
// Every glass / material / vibrancy use in the app goes through this file so
// the switch is one place and updates live.
import SwiftUI
import AppKit

// MARK: - Setting

enum LiquidGlass {
    /// UserDefaults key (bool, default true). Registry key: `appearance.liquidGlass`.
    static let defaultsKey = "luna_liquid_glass"
    static let defaultValue = true

    static var isOn: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? defaultValue
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

    init(lunaHex hex: UInt32, alpha: CGFloat = 1) {
        self.init(nsColor: .lunaHex(hex, alpha: alpha))
    }
}

extension NSColor {
    static func lunaHex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Luna's solid surface colors (Liquid Glass off).
enum LunaSurface {
    /// The window backdrop behind tabs and content (replaces sidebar / titlebar vibrancy).
    static let window = Color(light: .lunaHex(0xECECEE), dark: .lunaHex(0x1C1C1E))
    /// A floating sidebar sitting over the page.
    static let sidebar = Color(light: .lunaHex(0xF5F5F7), dark: .lunaHex(0x242426))
    /// Cards, bars, capsules and popups.
    static let raised = Color(light: .white, dark: .lunaHex(0x2A2A2D))
    /// Hairline border around raised surfaces.
    static let stroke = Color(light: .black.withAlphaComponent(0.10), dark: .white.withAlphaComponent(0.10))
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
struct LunaBackdrop: View {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var solid: Color = LunaSurface.window
    @AppStorage(LiquidGlass.defaultsKey) private var glass = LiquidGlass.defaultValue

    var body: some View {
        if glass {
            VisualEffectView(material: material, blendingMode: blendingMode, state: state)
        } else {
            solid
        }
    }
}

/// The start page / chat backdrop: under-window material with a near-opaque
/// dark wash (glass on), or the same dark grey, opaque (glass off).
struct StartPageBackdrop: View {
    @AppStorage(LiquidGlass.defaultsKey) private var glass = LiquidGlass.defaultValue

    var body: some View {
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
struct LunaMaterialFill<S: InsettableShape>: View {
    var shape: S
    var material: Material = .regularMaterial
    var solid: Color = LunaSurface.raised
    var strokesWhenSolid = true
    @AppStorage(LiquidGlass.defaultsKey) private var glass = LiquidGlass.defaultValue

    var body: some View {
        if glass {
            shape.fill(material)
        } else {
            shape.fill(solid).overlay(shape.strokeBorder(strokesWhenSolid ? LunaSurface.stroke : .clear, lineWidth: 1))
        }
    }
}

// MARK: - Glass surface modifier

/// Native Liquid Glass on macOS 26+ (material-blur fallback below) when the
/// setting is on; Luna's solid raised surface when it is off.
/// `interactive` enables the live-warp variant / a hover fill.
struct LunaGlass<S: Shape>: ViewModifier {
    var shape: S
    var interactive: Bool = false
    var tint: Color? = nil
    @AppStorage(LiquidGlass.defaultsKey) private var glassOn = LiquidGlass.defaultValue
    @State private var isHovering = false

    func body(content: Content) -> some View {
        if !glassOn {
            content
                .background(shape.fill(LunaSurface.hover.opacity(interactive && isHovering ? 1 : 0)))
                .background(shape.fill(tint ?? LunaSurface.raised))
                .overlay(shape.stroke(LunaSurface.stroke, lineWidth: 1))
                .compositingGroup()
                .shadow(color: LunaSurface.shadow, radius: 6, y: 2)
                .onHover { if interactive { isHovering = $0 } }
        } else if #available(macOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            content
                .background(shape.fill(.ultraThinMaterial))
                .background(shape.fill(Color.white.opacity(0.06)))
                .overlay(shape.stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
    }

    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

/// Groups sibling glass shapes (macOS 26+, setting on); a no-op otherwise.
private struct LunaGlassContainer: ViewModifier {
    var spacing: CGFloat?
    @AppStorage(LiquidGlass.defaultsKey) private var glassOn = LiquidGlass.defaultValue

    func body(content: Content) -> some View {
        if glassOn, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Glass (or solid) capsule — the default shape across the app's controls.
    func lunaGlassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(LunaGlass(shape: Capsule(style: .continuous), interactive: interactive, tint: tint))
    }

    /// Glass (or solid) rounded rectangle.
    func lunaGlass(cornerRadius: CGFloat, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(LunaGlass(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            interactive: interactive,
            tint: tint
        ))
    }

    /// Groups sibling glass shapes so they share one sampling region and can
    /// morph together (no-op below macOS 26 or with Liquid Glass off).
    func lunaGlassContainer(spacing: CGFloat? = nil) -> some View {
        modifier(LunaGlassContainer(spacing: spacing))
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

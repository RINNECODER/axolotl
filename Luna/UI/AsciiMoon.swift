// Luna — ASCII crescent moon for the start page.
// A cratered sphere lit from behind-the-side so only a crescent shows. The
// crescent swells and thins (waxing/waning), its horns spin around the
// view axis, and the surface tumbles on all three axes underneath. Glyphs
// are pre-rendered bitmaps, so a frame is ~1k texture blits.
import SwiftUI
import AppKit

struct AsciiMoon: View {
    /// Sphere diameter in points; the view adds a little room for the halo.
    var diameter: CGFloat = 170
    /// Spins faster while the AI is working.
    var isBusy: Bool = false

    @State private var clock = MoonClock()
    @State private var onScreen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Runs while Luna is the active app and the window is on screen.
        // Inactive app, occluded, minimized or removed: the schedule pauses and
        // no frames are drawn; it resumes on NSApplication.didBecomeActive
        // (driven by notifications, not controlActiveState, which froze the
        // moon mid-frame). Reduce Motion: still.
        let animating = onScreen && !reduceMotion
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animating)) { tl in
            Canvas { ctx, size in
                let t = animating ? clock.advance(tl.date, busy: isBusy) : clock.hold()
                MoonRenderer.draw(&ctx, size: size, diameter: diameter, t: t)
            }
        }
        .frame(width: diameter * 1.3, height: diameter * 1.15)
        .background(WindowVisibilityReader(isVisible: $onScreen))
        .onDisappear { onScreen = false }
        .accessibilityHidden(true)
    }
}

/// Reports whether the hosting window is actually on screen (not occluded,
/// minimized or hidden) and the app is active, from AppKit notifications.
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        let binding = $isVisible
        view.onChange = { visible in
            if binding.wrappedValue != visible { binding.wrappedValue = visible }
        }
        view.report()
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    self?.report()
                })
            }
            if let window {
                let names: [Notification.Name] = [
                    NSWindow.didChangeOcclusionStateNotification,
                    NSWindow.didMiniaturizeNotification,
                    NSWindow.didDeminiaturizeNotification,
                ]
                observers += names.map {
                    NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                        self?.report()
                    }
                }
            }
            report()
        }

        override func viewDidHide() { super.viewDidHide(); report() }
        override func viewDidUnhide() { super.viewDidUnhide(); report() }

        func report() {
            let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
            let shown = visible && NSApp.isActive && !isHiddenOrHasHiddenAncestor
            // Deferred: this can run during a SwiftUI view update.
            DispatchQueue.main.async { [weak self] in self?.onChange?(shown) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}

/// Integrates time with a speed that eases between idle and busy.
private final class MoonClock {
    private var last: Date?
    private var phase: Double = 40
    private var speed: Double = 1

    func advance(_ date: Date, busy: Bool) -> Float {
        let dt = min(0.1, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date
        let target = busy ? 3.2 : 1
        speed += (target - speed) * min(1, dt * 2)
        phase += dt * speed
        return Float(phase)
    }

    /// Current frame without advancing; the next `advance` resumes from here
    /// instead of jumping over the time spent paused.
    func hold() -> Float {
        last = nil
        return Float(phase)
    }
}

private enum MoonRenderer {
    static let ramp = [".", ":", "-", "=", "+", "*", "o", "%", "#", "@"]
    static let colors: [NSColor] = [
        NSColor(red: 0.96, green: 0.95, blue: 0.90, alpha: 1), // moonlight
        NSColor(red: 0.70, green: 0.78, blue: 0.95, alpha: 1), // cool limb
    ]

    private static var cache: [String: NSImage] = [:]

    private static func glyph(_ s: String, size: CGFloat, color: Int) -> NSImage {
        let key = "\(s)|\(size)|\(color)"
        if let img = cache[key] { return img }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colors[color]])
        let b = str.size()
        let w = ceil(max(b.width, 1)), h = ceil(max(b.height, 1))
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            str.draw(at: .zero)
            return true
        }
        cache[key] = img
        return img
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, diameter: CGFloat, t: Float) {
        let fs = max(7, diameter / 17)
        let cw = fs * 0.62, ch = fs * 1.12
        let atlas = colors.indices.map { c in ramp.map { ctx.resolve(Image(nsImage: glyph($0, size: fs, color: c))) } }

        let cx = size.width / 2, cy = size.height / 2
        let R = Float(diameter / 2)
        let cols = Int(size.width / cw), rows = Int(size.height / ch)

        // Light: behind the moon (negative z) so only a crescent is lit.
        // θ spins the horns around the view axis; depth swings the crescent
        // between a thin sliver and a fat waxing/waning shape.
        let theta = t * 0.45
        let depth = -0.18 - 0.5 * (0.5 + 0.5 * sinf(t * 0.23))
        let side = sqrtf(max(0, 1 - depth * depth))
        let lx = cosf(theta) * side, ly = sinf(theta) * side, lz = depth

        // Surface tumble on three axes (rotation matrix applied to normals).
        let a = t * 0.31, b = t * 0.47, c = t * 0.19
        let ca = cosf(a), sa = sinf(a), cb = cosf(b), sb = sinf(b), cc = cosf(c), sc = sinf(c)

        for r in 0..<rows {
            let y = (CGFloat(r) + 0.5) * ch
            let ny = Float(y - cy) / R
            for col in 0..<cols {
                let x = (CGFloat(col) + 0.5) * cw
                let nx = Float(x - cx) / R
                let rr = nx * nx + ny * ny
                guard rr < 1 else { continue }
                let nz = sqrtf(1 - rr)

                let lam = nx * lx + ny * ly + nz * lz
                // Tumbling surface coordinates for craters / maria.
                var px = nx, py = ny * ca - nz * sa, pz = ny * sa + nz * ca
                (px, pz) = (px * cb + pz * sb, -px * sb + pz * cb)
                (px, py) = (px * cc - py * sc, px * sc + py * cc)
                let maria = 0.5 + 0.5 * sinf(px * 4.1 + sinf(py * 3.3) * 1.4) * cosf(pz * 3.7 - py * 1.9)
                let crater = powf(max(0, sinf(px * 11) * sinf(py * 11) * sinf(pz * 11)), 2)
                let albedo = 0.72 + 0.2 * maria - 0.35 * crater

                if lam > 0 {
                    // Soft terminator so the crescent edge reads as a curve.
                    let lit = min(1, powf(lam, 0.7) * 1.25) * albedo
                    let g = min(ramp.count - 1, Int(lit * Float(ramp.count)))
                    let limb = 1 - nz
                    ctx.opacity = Double(0.35 + 0.65 * lit)
                    ctx.draw(atlas[limb > 0.55 ? 1 : 0][g], at: CGPoint(x: x, y: y), anchor: .center)
                } else if rr > 0.86 || lam > -0.08 {
                    // Earthshine rim keeps the dark side's silhouette faintly visible.
                    ctx.opacity = 0.12
                    ctx.draw(atlas[1][0], at: CGPoint(x: x, y: y), anchor: .center)
                }
            }
        }
    }
}

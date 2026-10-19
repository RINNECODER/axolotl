// Axolotl — shared ASCII-art helpers for the start page axolotl (`AsciiAxolotl`).
import SwiftUI
import AppKit

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
final class AsciiClock {
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

enum AsciiGlyphs {
    static let ramp = [".", ":", "-", "=", "+", "*", "o", "%", "#", "@"]
    private static var cache: [String: NSImage] = [:]

    /// A pre-rendered glyph bitmap.
    static func glyph(_ s: String, size: CGFloat, color: NSColor) -> NSImage {
        let key = "\(s)|\(size)|\(color)"
        if let img = cache[key] { return img }
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        let str = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let b = str.size()
        let w = ceil(max(b.width, 1)), h = ceil(max(b.height, 1))
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            str.draw(at: .zero)
            return true
        }
        cache[key] = img
        return img
    }
}

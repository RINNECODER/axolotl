import SwiftUI
import AppKit

/// Split view: 2–4 tabs side by side (or stacked), each in its own rounded
/// pane with draggable dividers between them. The focused pane drives the
/// address bar and theme; clicking another pane focuses it (the shell
/// watches clicks against the frames reported in `paneFrames`).
struct SplitPanesView<Content: View>: View {
    let group: SplitGroup
    let focused: UUID
    /// Rounded frame on: panes are separate cards with a gap between them.
    let rounded: Bool
    let onRatios: ([Double]) -> Void
    let onRemove: (UUID) -> Void
    /// Each pane's window frame, for the shell's click-to-focus.
    @Binding var paneFrames: [UUID: CGRect]
    @ViewBuilder let content: (UUID) -> Content

    @State private var dragStart: [Double]?

    private var gap: CGFloat { rounded ? 6 : 1 }
    private var horizontal: Bool { group.axis == .horizontal }

    var body: some View {
        GeometryReader { geo in
            let total = (horizontal ? geo.size.width : geo.size.height) - gap * CGFloat(group.panes.count - 1)
            let sizes = group.ratios.map { max(80, CGFloat($0) * total) }
            if horizontal {
                HStack(spacing: 0) { panes(sizes: sizes, total: total) }
            } else {
                VStack(spacing: 0) { panes(sizes: sizes, total: total) }
            }
        }
    }

    @ViewBuilder
    private func panes(sizes: [CGFloat], total: CGFloat) -> some View {
        ForEach(Array(group.panes.enumerated()), id: \.element) { index, id in
            if index > 0 {
                divider(after: index - 1, total: total)
            }
            pane(id)
                .frame(width: horizontal ? sizes[index] : nil, height: horizontal ? nil : sizes[index])
        }
    }

    private func pane(_ id: UUID) -> some View {
        SplitPane(isFocused: id == focused, rounded: rounded, onRemove: { onRemove(id) }) {
            content(id)
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
            paneFrames[id] = frame
        }
    }

    /// Invisible drag handle in the gap; the cursor shows it's draggable.
    private func divider(after index: Int, total: CGFloat) -> some View {
        Color.clear
            .frame(width: horizontal ? gap : nil, height: horizontal ? nil : gap)
            .overlay {
                Color.clear
                    .frame(width: horizontal ? 10 : nil, height: horizontal ? nil : 10)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        let cursor: NSCursor = horizontal ? .resizeLeftRight : .resizeUpDown
                        if inside { cursor.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStart ?? group.ratios
                                dragStart = start
                                let delta = Double((horizontal ? value.translation.width : value.translation.height) / max(1, total))
                                // Move the boundary between this pane and the next; keep both usable.
                                let pair = start[index] + start[index + 1]
                                let minShare = min(pair / 2, Double(120 / max(1, total)))
                                let left = min(max(start[index] + delta, minShare), pair - minShare)
                                var ratios = start
                                ratios[index] = left
                                ratios[index + 1] = pair - left
                                onRatios(ratios)
                            }
                            .onEnded { _ in dragStart = nil }
                    )
            }
    }
}

/// One pane: rounded card, a focus outline, and a hover control to take the
/// tab out of the split.
private struct SplitPane<Content: View>: View {
    let isFocused: Bool
    let rounded: Bool
    let onRemove: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: rounded ? 10 : 0, style: .continuous)
        content()
            .clipShape(shape)
            .overlay {
                shape
                    .strokeBorder(AxolotlSurface.accent.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "rectangle.split.2x1.slash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 22)
                            .background(AxolotlMaterialFill(shape: Capsule(style: .continuous)))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Split View")
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

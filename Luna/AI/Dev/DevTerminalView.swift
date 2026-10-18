import AppKit
import SwiftTerm
import SwiftUI

/// The raw CLI (`claude` / `codex`) running interactively in the project folder, on a
/// pseudo-terminal rendered by SwiftTerm. The process lives as long as this view.
struct DevTerminalView: NSViewRepresentable {
    let kind: AgentCLIKind
    let projectDir: URL
    /// Follows the panel's appearance with T3 Code's terminal colors (MIT, apps/web/src/index.css).
    var isDark = true
    var onExit: (Int32?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onExit: onExit) }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.terminalDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        Self.applyColors(to: view, isDark: isDark)
        context.coordinator.start(kind: kind, projectDir: projectDir, in: view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        Self.applyColors(to: nsView, isDark: isDark)
    }

    private static func applyColors(to view: TerminalView, isDark: Bool) {
        let bg = isDark ? NSColor(srgbRed: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255, alpha: 1) : .white
        guard view.nativeBackgroundColor != bg else { return }
        view.nativeBackgroundColor = bg
        view.nativeForegroundColor = isDark ? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0x27 / 255, green: 0x27 / 255, blue: 0x2A / 255, alpha: 1)
        view.caretColor = isDark ? NSColor(srgbRed: 180 / 255, green: 203 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0x1B / 255, green: 0x4E / 255, blue: 0xD8 / 255, alpha: 1)
        view.selectedTextBackgroundColor = isDark ? NSColor(srgbRed: 180 / 255, green: 203 / 255, blue: 1, alpha: 0.25)
            : NSColor(srgbRed: 0x1B / 255, green: 0x4E / 255, blue: 0xD8 / 255, alpha: 0.18)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private var pty: PTYSession?
        private var reader: Task<Void, Never>?
        private let onExit: (Int32?) -> Void

        init(onExit: @escaping (Int32?) -> Void) { self.onExit = onExit }

        func start(kind: AgentCLIKind, projectDir: URL, in view: TerminalView) {
            let pty = PTYSession(executable: kind.executableName, workingDirectory: projectDir)
            let terminal = view.getTerminal()
            do {
                let onExit = self.onExit
                try pty.start(columns: UInt16(max(terminal.cols, 20)), rows: UInt16(max(terminal.rows, 5))) { status in
                    Task { @MainActor in onExit(PTYSession.exitCode(status)) }
                }
            } catch {
                let message = "\r\n\(error.localizedDescription)\r\n"
                view.feed(text: message)
                return
            }
            self.pty = pty
            reader = Task { @MainActor [weak view] in
                for await chunk in pty.output {
                    guard let view else { return }
                    view.feed(byteArray: ArraySlice([UInt8](chunk)))
                }
                view?.feed(text: "\r\n[process exited]\r\n")
            }
        }

        func stop() {
            reader?.cancel()
            reader = nil
            pty?.terminate()
            pty = nil
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty?.write(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            pty?.resize(columns: UInt16(max(newCols, 1)), rows: UInt16(max(newRows, 1)))
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

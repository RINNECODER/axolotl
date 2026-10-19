import Foundation

/// Calls `onChange` on the main thread, once per run-loop turn however many writes
/// landed, when any of `keys` changes. Writes to other keys cost nothing, unlike
/// `UserDefaults.didChangeNotification`, which fires on every write in the app.
final class DefaultsObserver: NSObject {
    private let keys: [String]
    private let defaults: UserDefaults
    private let onChange: () -> Void
    private var pending = false

    init(keys: [String], defaults: UserDefaults = .standard, onChange: @escaping () -> Void) {
        self.keys = keys
        self.defaults = defaults
        self.onChange = onChange
        super.init()
        for key in keys { defaults.addObserver(self, forKeyPath: key, options: [], context: nil) }
    }

    deinit {
        for key in keys { defaults.removeObserver(self, forKeyPath: key) }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // Writes can come from any thread; hop to main, then coalesce to the next turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.pending else { return }
            self.pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.onChange()
            }
        }
    }
}

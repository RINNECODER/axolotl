import XCTest
@testable import Luna

/// Optional features and background work cost nothing while idle or off.
@MainActor
final class IdleCostTests: XCTestCase {
    private func spin(_ seconds: TimeInterval = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testDefaultsObserverIgnoresOtherKeysAndCoalescesBursts() throws {
        let suite = "luna-idle-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var calls = 0
        let observer = DefaultsObserver(keys: ["luna_theme_contrast"], defaults: d) { calls += 1 }
        d.set("x", forKey: "unrelated_key")
        spin()
        XCTAssertEqual(calls, 0, "a write to another key must not reload the theme")
        for v in ["high", "normal", "high"] { d.set(v, forKey: "luna_theme_contrast") }
        spin()
        XCTAssertEqual(calls, 1, "a burst of writes is one reload")
        withExtendedLifetime(observer) {}
    }
}

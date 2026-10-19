import XCTest
@testable import Axolotl

@MainActor
final class OnboardingFlowTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suite = "OnboardingFlowTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
    }

    func testAxolotlDevShowsAllSixStepsInOrderAndAxolotlHidesDevMode() {
        XCTAssertEqual(OnboardingFlow(isDevBuild: true, defaults: defaults).steps,
                       [.welcome, .importData, .ai, .look, .privacy, .developer])
        XCTAssertEqual(OnboardingFlow(isDevBuild: false, defaults: defaults).steps,
                       [.welcome, .importData, .ai, .look, .privacy])
    }

    func testBackStopsAtFirstStepAndNextWalksToLastWithoutFinishing() {
        let flow = OnboardingFlow(isDevBuild: false, defaults: defaults)
        flow.back()
        XCTAssertEqual(flow.step, .welcome)

        for _ in 0..<4 { flow.next() }
        XCTAssertEqual(flow.step, .privacy)
        XCTAssertTrue(flow.isLast)
        XCTAssertFalse(flow.isFinished)
        XCTAssertFalse(OnboardingState.hasSeen(defaults))

        flow.back()
        XCTAssertEqual(flow.step, .look)
    }

    func testSkipMovesOnWithoutMarkingSeen() {
        let flow = OnboardingFlow(isDevBuild: true, defaults: defaults)
        flow.skip()
        XCTAssertEqual(flow.step, .importData)
        XCTAssertFalse(OnboardingState.hasSeen(defaults))
    }

    func testNextOnLastStepFinishesAndMarksSeen() {
        let flow = OnboardingFlow(isDevBuild: true, startAt: 5, defaults: defaults)
        XCTAssertEqual(flow.step, .developer)
        flow.next()
        XCTAssertTrue(flow.isFinished)
        XCTAssertTrue(OnboardingState.hasSeen(defaults))
    }

    func testSkipAllFromTheMiddleFinishesAndMarksSeen() {
        let flow = OnboardingFlow(isDevBuild: false, startAt: 2, defaults: defaults)
        flow.skipAll()
        XCTAssertTrue(flow.isFinished)
        XCTAssertTrue(OnboardingState.hasSeen(defaults))
    }

    func testStartStepIsClampedToTheStepsThisBuildHas() {
        XCTAssertEqual(OnboardingFlow(isDevBuild: false, startAt: 9, defaults: defaults).step, .privacy)
        XCTAssertEqual(OnboardingFlow(isDevBuild: false, startAt: -3, defaults: defaults).step, .welcome)
    }

    // MARK: First-run decision

    func testShowsAtLaunchOnlyUntilSeenAndAgainAfterShowAgain() {
        XCTAssertEqual(OnboardingState.launchStep(defaults: defaults, environment: [:]), 0)

        OnboardingFlow(isDevBuild: false, defaults: defaults).skipAll()
        XCTAssertNil(OnboardingState.launchStep(defaults: defaults, environment: [:]))

        OnboardingState.showAgain(defaults: defaults, center: NotificationCenter())
        XCTAssertEqual(OnboardingState.launchStep(defaults: defaults, environment: [:]), 0)
    }

    func testSnapshotAndAutomationRunsDontShowItAtLaunch() {
        XCTAssertNil(OnboardingState.launchStep(defaults: defaults, environment: ["AXOLOTL_SNAPSHOT_PATH": "/tmp/x"]))
        XCTAssertNil(OnboardingState.launchStep(defaults: defaults, environment: ["AXOLOTL_SKIP_ONBOARDING": "1"]))
    }

    func testForcedStepShowsThatStepEvenWhenSeen() {
        OnboardingState.markSeen(defaults)
        defaults.set(4, forKey: OnboardingState.forcedStepKey)
        XCTAssertEqual(OnboardingState.launchStep(defaults: defaults, environment: ["AXOLOTL_SNAPSHOT_PATH": "/tmp/x"]), 3)
    }
}

import XCTest
#if AXOLOTL_DEV
@testable import AxolotlDev
#else
@testable import Axolotl
#endif

/// Dev mode's dropdown model, picker reset rules and the resume offer.
final class DevPickerTests: XCTestCase {
    private func item(_ id: String, _ title: String? = nil, section: String? = nil, enabled: Bool = true,
                      subtitle: String? = nil, role: DevDropdownItem.Role = .option) -> DevDropdownItem {
        DevDropdownItem(id: id, title: title ?? id, subtitle: subtitle, section: section, isEnabled: enabled, role: role)
    }

    // MARK: Dropdown

    func testSearchAppearsOnlyAboveSixOptionsAndActionsDoNotCount() {
        let six = (1...6).map { item("m\($0)") } + [item("refresh", role: .action)]
        XCTAssertFalse(DevDropdownModel(items: six, selectedID: nil).showsSearch)
        XCTAssertTrue(DevDropdownModel(items: six + [item("m7")], selectedID: nil).showsSearch)
    }

    func testQueryMatchesEveryWordAcrossFieldsAndKeepsActions() {
        var model = DevDropdownModel(items: [
            item("opus", "Opus 4.8", subtitle: "Most capable"),
            item("haiku", "Haiku 4.5", subtitle: "Fastest"),
            item("sonnet", "Sonnet 4.6", subtitle: "Capable and fast"),
            item("refresh", "Refresh models", role: .action),
        ], selectedID: "haiku")
        model.query = "capable"
        XCTAssertEqual(model.visible.map(\.id), ["opus", "sonnet", "refresh"])
        model.query = "fast sonnet"
        XCTAssertEqual(model.visible.map(\.id), ["sonnet", "refresh"])
        XCTAssertEqual(model.highlightedID, "sonnet", "a new query highlights the first match")
        model.query = "nothing"
        XCTAssertTrue(model.hasNoMatches)
        XCTAssertEqual(model.commit()?.id, "refresh")
    }

    func testKeyboardStartsOnSelectionWrapsAndSkipsDisabled() {
        var model = DevDropdownModel(items: [
            item("claude"), item("codex"), item("pi", enabled: false), item("open", role: .action),
        ], selectedID: "codex")
        XCTAssertEqual(model.highlightedID, "codex")
        model.move(1)
        XCTAssertEqual(model.highlightedID, "open", "disabled pi is skipped")
        model.move(1)
        XCTAssertEqual(model.highlightedID, "claude", "wraps to the top")
        model.move(-1)
        XCTAssertEqual(model.highlightedID, "open", "wraps to the bottom")
        model.highlight("pi")
        XCTAssertEqual(model.highlightedID, "open", "hovering a disabled row does not highlight it")
        XCTAssertEqual(model.commit()?.id, "open")
    }

    func testSectionsKeepFirstAppearanceOrderWithActionsLast() {
        let model = DevDropdownModel(items: [
            item("open", role: .action), item("a", section: "Harnesses"), item("x", section: "Unsupported"),
            item("b", section: "Harnesses"),
        ], selectedID: nil)
        XCTAssertEqual(model.sections.map(\.title), ["Harnesses", "Unsupported", nil])
        XCTAssertEqual(model.sections.map { $0.items.map(\.id) }, [["a", "b"], ["x"], ["open"]])
    }

    // MARK: Picker state

    private let codexModels = [
        HarnessModel(id: "gpt-5.5", displayName: "GPT-5.5", isDefault: true, efforts: ["low", "medium", "high"], defaultEffort: "medium"),
        HarnessModel(id: "gpt-5.5-mini", displayName: "GPT-5.5 mini", isDefault: false, efforts: ["low", "medium"], defaultEffort: "low"),
    ]

    func testSwitchingHarnessResetsModelToThatHarnessDefault() {
        let start = DevComposerSelection(harness: .claudeCode, model: "haiku", effort: "")
        let toCodex = start.switching(to: .codex) { $0 == .codex ? "gpt-5.5-mini" : nil }
        XCTAssertEqual(toCodex, DevComposerSelection(harness: .codex, model: "gpt-5.5-mini", effort: ""))
        let noDefault = DevComposerSelection(harness: .codex, model: "gpt-5.5", effort: "high").switching(to: .claudeCode) { _ in nil }
        XCTAssertEqual(noDefault, DevComposerSelection(harness: .claudeCode, model: "", effort: ""))
        XCTAssertEqual(start.switching(to: .claudeCode) { _ in "opus" }, start, "same harness keeps the pick")
    }

    func testPickingModelDropsAnEffortItDoesNotAccept() {
        let high = DevComposerSelection(harness: .codex, model: "gpt-5.5", effort: "high")
        XCTAssertEqual(high.picking(model: "gpt-5.5-mini", in: codexModels).effort, "")
        let low = DevComposerSelection(harness: .codex, model: "gpt-5.5", effort: "low")
        XCTAssertEqual(low.picking(model: "gpt-5.5-mini", in: codexModels).effort, "low")
    }

    func testCurrentModelAndEffectiveEffort() {
        XCTAssertEqual(DevComposerSelection.current(model: "", in: codexModels)?.id, "gpt-5.5")
        XCTAssertEqual(DevComposerSelection.current(model: "gpt-5.5-mini", in: codexModels)?.id, "gpt-5.5-mini")
        XCTAssertNil(DevComposerSelection.current(model: "retired", in: codexModels))
        XCTAssertEqual(DevComposerSelection.effectiveEffort("", for: codexModels[0]), "medium")
        XCTAssertEqual(DevComposerSelection.effectiveEffort("high", for: codexModels[0]), "high")
        XCTAssertEqual(DevComposerSelection.effectiveEffort("high", for: codexModels[1]), "low")
        XCTAssertNil(DevComposerSelection.effectiveEffort("", for: HarnessModel(id: "opus", displayName: "Opus", isDefault: false)))
    }

    // MARK: Resume offer

    private func resumable(live: Bool, axolotl: Bool, id: String = "s1") -> ResumableSession {
        ResumableSession(harness: .claudeCode, id: id, title: "Fix the build", updatedAt: Date(), startedInAxolotl: axolotl, isLive: live)
    }

    func testResumeOfferPicksTheRightAction() {
        XCTAssertEqual(DevResumeOffer.make(resumable(live: false, axolotl: true), liveSync: false, activeSessionID: nil)?.action, .resume)
        XCTAssertNil(DevResumeOffer.make(resumable(live: false, axolotl: false), liveSync: false, activeSessionID: nil),
                     "terminal sessions need live sync")
        XCTAssertEqual(DevResumeOffer.make(resumable(live: false, axolotl: false), liveSync: true, activeSessionID: nil)?.action, .resume)
        XCTAssertEqual(DevResumeOffer.make(resumable(live: true, axolotl: false), liveSync: true, activeSessionID: nil)?.action, .follow)
        XCTAssertEqual(DevResumeOffer.make(resumable(live: true, axolotl: true), liveSync: false, activeSessionID: nil)?.action, .unavailable)
        XCTAssertNil(DevResumeOffer.make(resumable(live: false, axolotl: true), liveSync: true, activeSessionID: "s1"),
                     "the session already on screen is not offered")
        XCTAssertNil(DevResumeOffer.make(nil, liveSync: true, activeSessionID: nil))
    }

    func testResumeCaptionAndListFilter() {
        let now = Date()
        XCTAssertEqual(DevResumeOffer.caption(harness: .codex, updatedAt: now, startedInAxolotl: false, isLive: true, now: now),
                       "Codex · Live in terminal")
        XCTAssertEqual(DevResumeOffer.caption(harness: .claudeCode, updatedAt: now.addingTimeInterval(-20), startedInAxolotl: true,
                                              isLive: false, now: now),
                       "Claude Code · just now · from Axolotl")
        let dir = URL(fileURLWithPath: "/tmp/p")
        func external(_ id: String, axolotl: Bool) -> ExternalSession {
            ExternalSession(harness: .claudeCode, id: id, file: dir, projectDir: dir, title: id, firstPrompt: "", updatedAt: now,
                            isLive: false, messageCount: 2, startedInAxolotl: axolotl)
        }
        let all = [external("t", axolotl: false), external("l", axolotl: true)]
        XCTAssertEqual(DevResumeOffer.listed(all, liveSync: false).map(\.id), ["l"])
        XCTAssertEqual(DevResumeOffer.listed(all, liveSync: true).map(\.id), ["t", "l"])
    }
}

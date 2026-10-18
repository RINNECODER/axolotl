import Foundation

/// What the composer's harness / model / effort pickers hold, and how a change to one resets the
/// others. Pure, so the rules are tested without the view.
struct DevComposerSelection: Equatable {
    var harness: AgentCLIKind
    /// A `HarnessModel.id`, or "" for the harness's own default.
    var model: String
    /// A reasoning effort, or "" for the model's default.
    var effort: String

    /// Switching harness picks that harness's default model from Settings (or its own default)
    /// and clears the effort. Picking the same harness changes nothing.
    func switching(to harness: AgentCLIKind, defaultModel: (HarnessID) -> String?) -> DevComposerSelection {
        guard harness != self.harness else { return self }
        return DevComposerSelection(harness: harness, model: defaultModel(harness.harnessID) ?? "", effort: "")
    }

    /// Picking a model clears an effort the new model does not accept.
    func picking(model id: String, in models: [HarnessModel]) -> DevComposerSelection {
        var next = self
        next.model = id
        let efforts = models.first { $0.id == id }?.efforts ?? []
        if !efforts.contains(effort) { next.effort = "" }
        return next
    }

    /// The model the pickers show as selected: the stored id when the list has it, else the default.
    static func current(model id: String, in models: [HarnessModel]) -> HarnessModel? {
        if !id.isEmpty, let match = models.first(where: { $0.id == id }) { return match }
        if id.isEmpty { return models.first(where: \.isDefault) ?? models.first }
        return nil
    }

    /// The effort shown for `model`: the stored one if the model accepts it, else its default.
    static func effectiveEffort(_ effort: String, for model: HarnessModel?) -> String? {
        guard let model, let efforts = model.efforts, !efforts.isEmpty else { return nil }
        if efforts.contains(effort) { return effort }
        return model.defaultEffort ?? efforts.first
    }
}

/// The "Continue" row at the top of an empty Dev thread.
struct DevResumeOffer: Equatable {
    enum Action: Equatable {
        /// Resume it in Luna (`--resume` / `thread/resume`).
        case resume
        /// It is live in a terminal: mirror it read-only (live sync on).
        case follow
        /// Live in a terminal and live sync is off: nothing safe to do from here.
        case unavailable
    }

    let session: ResumableSession
    let action: Action

    /// Nil when there is nothing to offer, when Luna is already showing that session, or when it
    /// was started in a terminal and live sync is off (terminal sessions are experimental).
    static func make(_ session: ResumableSession?, liveSync: Bool, activeSessionID: String?) -> DevResumeOffer? {
        guard let session, session.id != activeSessionID, liveSync || session.startedInLuna else { return nil }
        if session.isLive { return DevResumeOffer(session: session, action: liveSync ? .follow : .unavailable) }
        return DevResumeOffer(session: session, action: .resume)
    }

    /// "Claude Code · 12 min ago · from Terminal", or "Codex · Live in terminal".
    static func caption(harness: AgentCLIKind, updatedAt: Date, startedInLuna: Bool, isLive: Bool, now: Date = Date()) -> String {
        // "Live in terminal" already says where it runs.
        if isLive { return harness.displayName + " · Live in terminal" }
        return [harness.displayName, relative(updatedAt, now: now), startedInLuna ? "from Luna" : "from Terminal"]
            .joined(separator: " · ")
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    /// Sessions the list shows: everything with live sync on, else only sessions Luna started.
    static func listed(_ sessions: [ExternalSession], liveSync: Bool) -> [ExternalSession] {
        liveSync ? sessions : sessions.filter(\.startedInLuna)
    }
}

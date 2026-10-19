import Foundation
import WebKit

/// Every tool Axolotl exposes to its own agent panel and, over MCP, to outside agents.
/// To add a tool, append a `AxolotlTool` here: the MCP `tools/list`, argument validation,
/// redaction and approval (set `mutates`) all follow from the entry.
enum AxolotlTools {
    static let all: [AxolotlTool] = [
        tabsList, tabOpen, tabSelect, navigate, snapshot, click, type, select, scroll, read, runTask, grabApiKey,
    ] + PersonalizationTools.all

    static let tabsList = AxolotlTool(
        name: "tabs_list", description: "List open Axolotl tabs: id, title, URL, and which is active.",
        params: [], mutates: false, targetsTab: false
    ) { call in
        let tabs = call.host.tabs
        if tabs.isEmpty { return "No tabs." }
        return tabs.map { "\($0.active ? "*" : " ") \($0.id.uuidString)\t\($0.title.isEmpty ? "(untitled)" : $0.title)\t\(AgentRedaction.redactURL($0.url))" }
            .joined(separator: "\n")
    }

    static let tabOpen = AxolotlTool(
        name: "tab_open", description: "Open an http(s) URL in a new tab, make it active, and return its id and a snapshot.",
        params: [AxolotlToolParam(name: "url", kind: .string, description: "http or https URL")],
        mutates: true, targetsTab: false
    ) { call in
        let url = try call.url("url")
        let id = call.host.openTab(url: url)
        guard let webView = call.host.webView(for: id) else { return "Opened tab \(id.uuidString)." }
        await AxolotlToolbox.waitForNavigationStart(webView, from: nil)
        let snap = try await AxolotlToolbox.driver(for: webView).snapshot()
        return "Opened tab \(id.uuidString).\n\n" + AxolotlToolbox.describe(snap)
    }

    static let tabSelect = AxolotlTool(
        name: "tab_select", description: "Bring a tab to the front.",
        params: [AxolotlToolParam(name: "id", kind: .string, description: "Tab id from tabs_list")],
        mutates: false, targetsTab: false
    ) { call in
        let raw = call.string("id") ?? ""
        guard let id = UUID(uuidString: raw), call.host.tabs.contains(where: { $0.id == id }) else {
            throw AxolotlToolError.invalidArguments("No tab with id \(raw). Call tabs_list.")
        }
        call.host.selectTab(id)
        return "Selected tab \(id.uuidString)."
    }

    static let navigate = AxolotlTool(
        name: "navigate", description: "Load an http(s) URL in the tab and return a snapshot of the new page.",
        params: [AxolotlToolParam(name: "url", kind: .string, description: "http or https URL")],
        mutates: true
    ) { call in
        let url = try call.url("url")
        let tab = try call.tab()
        let oldURL = call.host.webView(for: tab)?.url
        call.host.navigate(tab, to: url)
        guard let webView = call.host.webView(for: tab) else { throw AxolotlToolError.unavailable("The tab could not load.") }
        await AxolotlToolbox.waitForNavigationStart(webView, from: oldURL)
        return AxolotlToolbox.describe(try await AxolotlToolbox.driver(for: webView).snapshot())
    }

    static let snapshot = AxolotlTool(
        name: "snapshot",
        description: "Observe the page: a table of actionable elements (ids like e3 for click/type/select) and the visible text. Take one before acting; ids expire when the page changes.",
        params: [], mutates: false
    ) { call in
        AxolotlToolbox.describe(try await call.driver().snapshot())
    }

    static let click = AxolotlTool(
        name: "click", description: "Click an element by id from the latest snapshot. Returns a fresh snapshot.",
        params: [AxolotlToolParam(name: "id", kind: .string, description: "Action id, e.g. e3")],
        mutates: true, preview: { elementPreview("Click", $0) }
    ) { call in
        AxolotlToolbox.describe(try await call.driver().click(call.string("id") ?? ""))
    }

    static let type = AxolotlTool(
        name: "type", description: "Replace the text of a field (a 'fill' id from the latest snapshot). Returns a fresh snapshot.",
        params: [AxolotlToolParam(name: "id", kind: .string, description: "Fill action id, e.g. e2"),
                 AxolotlToolParam(name: "text", kind: .string, description: "Text to enter", allowsEmpty: true)],
        mutates: true, preview: { elementPreview("Type “\(($0.string("text") ?? "").prefix(80))” into", $0) }
    ) { call in
        AxolotlToolbox.describe(try await call.driver().type(call.string("id") ?? "", text: call.string("text") ?? ""))
    }

    static let select = AxolotlTool(
        name: "select",
        description: "Choose a dropdown option. Pass the option's own select id, or any option id of that dropdown plus the option's label or value.",
        params: [AxolotlToolParam(name: "id", kind: .string, description: "Select action id from the latest snapshot"),
                 AxolotlToolParam(name: "option", kind: .string, description: "Option label or value", required: false)],
        mutates: true, preview: { elementPreview($0.string("option").map { "Choose “\($0.prefix(80))” in" } ?? "Choose", $0) }
    ) { call in
        let driver = try call.driver()
        let id = call.string("id") ?? ""
        var target = id
        if let option = call.string("option")?.trimmingCharacters(in: .whitespaces), !option.isEmpty {
            guard let snap = driver.lastSnapshot, let base = snap.action(id: id), base.kind == "select" else {
                throw AgentError.stalePage("No select action \(id) in the last snapshot. Take a snapshot first.")
            }
            let wanted = option.lowercased()
            let match = snap.actions.first { a in
                a.kind == "select" && a.node == base.node &&
                    (a.value?.lowercased() == wanted || a.label.lowercased().hasSuffix("→ " + wanted))
            }
            if let match {
                target = match.id
            } else if base.currentValue?.lowercased() == wanted {
                return "'\(option)' is already selected."
            } else {
                throw AxolotlToolError.invalidArguments("No option '\(option)' in that dropdown.")
            }
        }
        return AxolotlToolbox.describe(try await driver.select(target))
    }

    static let scroll = AxolotlTool(
        name: "scroll", description: "Scroll the page one screen up or down. Returns a fresh snapshot.",
        params: [AxolotlToolParam(name: "direction", kind: .string, description: "up or down", allowed: ["up", "down"])],
        mutates: false
    ) { call in
        AxolotlToolbox.describe(try await call.driver().scroll(down: call.string("direction") == "down"))
    }

    static let read = AxolotlTool(
        name: "read", description: "Return the page's visible text (secrets masked).",
        params: [], mutates: false
    ) { call in
        try await call.driver().read()
    }

    static let runTask = AxolotlTool(
        name: "run_task",
        description: "Let Axolotl's own computer-use agent (Jev, or the chat model set in Axolotl) carry out a goal on the tab. Returns the step log and the outcome.",
        params: [AxolotlToolParam(name: "goal", kind: .string, description: "What to accomplish on this page"),
                 AxolotlToolParam(name: "max_steps", kind: .integer, description: "Action budget (default 60)",
                               required: false, range: 1...AgentPrompts.maxSteps)],
        mutates: true, preview: { "Run a task on \(pageHost($0) ?? "the current page"): \(($0.string("goal") ?? "").prefix(200))" }
    ) { call in
        let tab = try call.tab()
        guard let webView = call.host.webView(for: tab) else {
            throw AxolotlToolError.unavailable("This tab has no page yet. Use navigate first.")
        }
        let agent = AxolotlToolbox.agent(for: webView, maxSteps: call.int("max_steps") ?? AgentPrompts.maxSteps)
        var lines: [String] = []
        var outcome: AgentOutcome = .cancelled
        for await event in agent.run(goal: call.string("goal") ?? "") {
            if let line = event.panelLine { lines.append(line) }
            if case .finished(let o, _, _) = event { outcome = o }
        }
        let log = lines.joined(separator: "\n")
        if case .failed(let why) = outcome { throw AxolotlToolError.unavailable("\(log)\n\nFailed: \(why)") }
        return log
    }

    static let grabApiKey = AxolotlTool(
        name: "grab_api_key",
        description: "Create an API key on a service's dashboard with Axolotl's agent and save it to the user's macOS Keychain and clipboard. " +
            "The key value is never returned or shown to any model: the result is a status and the Keychain item name. " +
            "If the user must sign in first, the status is waiting_for_user_sign_in; ask them to sign in in Axolotl, then call again with the returned tab_id. " +
            "Known services: " + KeyService.registry.map(\.name).joined(separator: ", ") + "; others start at the site's home page.",
        params: [AxolotlToolParam(name: "service", kind: .string, description: "Service name (e.g. OpenAI, GitHub) or domain"),
                 AxolotlToolParam(name: "key_name", kind: .string, description: "Name for the new key (default axolotl-<date>)", required: false),
                 AxolotlToolParam(name: "url", kind: .string, description: "Key page URL, to override or for services not in the list", required: false),
                 AxolotlToolParam(name: "max_steps", kind: .integer, description: "Action budget (default 30)",
                               required: false, range: 1...AgentPrompts.maxSteps)],
        mutates: true
    ) { call in
        guard var service = KeyService.resolve(call.string("service") ?? "") else {
            throw AxolotlToolError.invalidArguments("grab_api_key: unknown service.")
        }
        if call.string("url") != nil {
            service = KeyService(id: service.id, name: service.name, url: try call.url("url"), known: true)
        }
        let keyName = call.string("key_name")?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? KeyGrabber.defaultKeyName()
        let tab: UUID
        let navigate: (URL) -> Void
        if call.string("tab_id") != nil {
            tab = try call.tab()
            navigate = { call.host.navigate(tab, to: $0) }
        } else {
            tab = call.host.openTab(url: service.url)
            navigate = { _ in }
        }
        guard let webView = call.host.webView(for: tab) else { throw AxolotlToolError.unavailable("The tab could not load.") }
        var result = await KeyGrabber.shared.grab(service: service, keyName: keyName, webView: webView, navigate: navigate,
                                                  maxSteps: call.int("max_steps") ?? 30)
        result.tabId = tab.uuidString
        return result.json
    }
}

// MARK: Approval previews

extension AxolotlTools {
    /// The target tab's page, without bringing it to the front (previews run before approval).
    private static func targetWebView(_ call: AxolotlToolCall) -> WKWebView? {
        guard let tab = call.string("tab_id").flatMap(UUID.init(uuidString:)) ?? call.host.activeTabId else { return nil }
        return call.host.webView(for: tab)
    }

    static func pageHost(_ call: AxolotlToolCall) -> String? { targetWebView(call)?.url?.host }

    /// What an element action will touch: the element's label from the last snapshot and the page host.
    static func elementPreview(_ verb: String, _ call: AxolotlToolCall) -> String {
        let id = call.string("id") ?? ""
        let webView = targetWebView(call)
        let label = webView.flatMap { AxolotlToolbox.driver(for: $0).lastSnapshot?.action(id: id)?.label }
        return elementPreview(verb, id: id, label: label, pageHost: webView?.url?.host)
    }

    static func elementPreview(_ verb: String, id: String, label: String?, pageHost: String?) -> String {
        let target = label.map { "“\($0.prefix(80))” (\(id))" } ?? id
        return "\(verb) \(target) on \(pageHost ?? "the current page")"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

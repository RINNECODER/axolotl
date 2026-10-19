import AppKit
import Foundation
import WebKit

/// One tab as the tools see it.
struct AgentTabInfo: Equatable {
    let id: UUID
    let title: String
    let url: String
    let active: Bool
}

/// The tabs a toolbox drives: a browser window (`ProfileSessionHost`) or a test stub.
protocol AgentBrowserHost: AnyObject {
    var tabs: [AgentTabInfo] { get }
    var activeTabId: UUID? { get }
    /// The tab's page, creating and loading its web view if needed. Nil for an empty tab.
    func webView(for tab: UUID) -> WKWebView?
    /// Opens and activates a tab loading `url`.
    func openTab(url: URL) -> UUID
    func selectTab(_ id: UUID)
    func navigate(_ tab: UUID, to url: URL)
    /// The profile's usage record, history, bookmarks and workspace, for the personalization tools.
    var personalization: PersonalizationContext? { get }
}

extension AgentBrowserHost {
    var personalization: PersonalizationContext? { nil }
}

enum AxolotlToolError: LocalizedError, Equatable {
    case unknownTool(String)
    case invalidArguments(String)
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool: \(name)"
        case .invalidArguments(let m), .unavailable(let m): return m
        }
    }
}

/// What a tool returns. `text` has already been through `AgentRedaction`.
struct AxolotlToolResult: Equatable {
    var text: String
    var isError: Bool
}

/// One parameter of a tool. The JSON Schema and argument validation both come from these.
struct AxolotlToolParam {
    enum Kind: String { case string, integer, boolean, array }
    let name: String
    let kind: Kind
    let description: String
    var required = true
    /// Lets a required string be empty (e.g. clearing a field).
    var allowsEmpty = false
    var allowed: [String]? = nil
    var range: ClosedRange<Int>? = nil
    /// JSON Schema of an array's items.
    var items: JSONValue? = nil
}

/// A tool callable by Axolotl's own agent panel and, over MCP, by outside agents.
struct AxolotlTool {
    let name: String
    let description: String
    let params: [AxolotlToolParam]
    /// Mutating tools ask the user before an outside agent may call them.
    let mutates: Bool
    /// Adds an optional `tab_id` parameter; `AxolotlToolCall.tab()` resolves it.
    var targetsTab = true
    /// Asks every time, even for trusted agents and "Allow for Session": the user sees a
    /// preview of the change with Apply / Cancel (customization tools).
    var confirmsEveryCall = false
    /// What the approval card shows instead of the raw arguments (e.g. "Toolbar: Off → On").
    var preview: ((AxolotlToolCall) -> String)? = nil
    let run: (AxolotlToolCall) async throws -> String

    static let tabParam = AxolotlToolParam(name: "tab_id", kind: .string,
                                        description: "Tab id from tabs_list. Defaults to the active tab; another tab is brought to the front.",
                                        required: false)

    var allParams: [AxolotlToolParam] { targetsTab ? params + [Self.tabParam] : params }

    var inputSchema: JSONValue {
        var properties: [String: JSONValue] = [:]
        for p in allParams {
            var prop: [String: JSONValue] = ["type": .string(p.kind.rawValue), "description": .string(p.description)]
            if let allowed = p.allowed { prop["enum"] = .array(allowed.map(JSONValue.string)) }
            if let items = p.items { prop["items"] = items }
            if let range = p.range {
                prop["minimum"] = .number(Double(range.lowerBound))
                prop["maximum"] = .number(Double(range.upperBound))
            }
            properties[p.name] = .object(prop)
        }
        return .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(allParams.filter(\.required).map { .string($0.name) }),
            "additionalProperties": .bool(false),
        ])
    }

    /// Checks names, presence, types, enums and ranges against `params`.
    func validate(_ arguments: [String: JSONValue]) throws {
        let byName = Dictionary(uniqueKeysWithValues: allParams.map { ($0.name, $0) })
        if let unknown = arguments.keys.sorted().first(where: { byName[$0] == nil }) {
            throw AxolotlToolError.invalidArguments("\(name): unknown argument '\(unknown)'.")
        }
        for p in allParams {
            guard let value = arguments[p.name], value != .null else {
                if p.required { throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' is required.") }
                continue
            }
            switch p.kind {
            case .string:
                guard let s = value.stringValue else {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must be a string.")
                }
                if p.required, !p.allowsEmpty, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must not be empty.")
                }
                if let allowed = p.allowed, !allowed.contains(s) {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must be one of \(allowed.joined(separator: ", ")).")
                }
            case .integer:
                guard let n = value.numberValue, n == n.rounded(), abs(n) < 1e9 else {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must be an integer.")
                }
                if let range = p.range, !range.contains(Int(n)) {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must be \(range.lowerBound)–\(range.upperBound).")
                }
            case .boolean:
                guard case .bool = value else {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must be true or false.")
                }
            case .array:
                guard case .array(let items) = value else {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must be a list.")
                }
                if p.required, items.isEmpty {
                    throw AxolotlToolError.invalidArguments("\(name): '\(p.name)' must not be empty.")
                }
            }
        }
    }
}

/// The arguments of one call plus access to the browser, for a tool's `run`.
struct AxolotlToolCall {
    let arguments: [String: JSONValue]
    let host: AgentBrowserHost
    /// Who is calling: "Axolotl" or the MCP client's name (shown in Recent AI changes).
    var source = "Axolotl"

    func string(_ key: String) -> String? { arguments[key]?.stringValue }
    func bool(_ key: String) -> Bool? { if case .bool(let b)? = arguments[key] { return b }; return nil }
    func int(_ key: String) -> Int? { arguments[key]?.numberValue.map { Int($0) } }

    /// The `tab_id` tab (brought to the front) or the active tab.
    func tab() throws -> UUID {
        if let raw = string("tab_id") {
            guard let id = UUID(uuidString: raw), host.tabs.contains(where: { $0.id == id }) else {
                throw AxolotlToolError.invalidArguments("No tab with id \(raw). Call tabs_list.")
            }
            if host.activeTabId != id { host.selectTab(id) }
            return id
        }
        guard let id = host.activeTabId else { throw AxolotlToolError.unavailable("No tab is open.") }
        return id
    }

    /// The page driver for the target tab; shared with the agent loop so action ids carry over.
    func driver() throws -> PageDriver {
        guard let webView = host.webView(for: try tab()) else {
            throw AxolotlToolError.unavailable("This tab has no page yet. Use navigate first.")
        }
        return AxolotlToolbox.driver(for: webView)
    }

    /// An http(s) URL with a host; same rule as the AI panel's browser actions.
    func url(_ key: String) throws -> URL {
        let raw = (string(key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = raw.contains("://") ? raw : "https://" + raw
        guard let url = URL(string: normalized), isSafeBrowserURL(url) else {
            throw AxolotlToolError.invalidArguments("Only http and https URLs can be opened.")
        }
        return url
    }
}

/// The one tool layer: Axolotl's `/agent` panel and the MCP bridge both go through it.
/// Tools are listed in `AxolotlTools.all` (AxolotlTools.swift); adding a tool is a change there only.
final class AxolotlToolbox {
    let tools: [AxolotlTool]
    private let hostProvider: () -> AgentBrowserHost?

    nonisolated deinit {}

    init(tools: [AxolotlTool] = AxolotlTools.all, host: @escaping () -> AgentBrowserHost?) {
        self.tools = tools
        self.hostProvider = host
    }

    func tool(named name: String) -> AxolotlTool? { tools.first { $0.name == name } }

    /// The approval card's text for a call: the tool's own preview, when it has one.
    /// Pass the `host` from `currentHost()` so the preview and the later `call` use the same window.
    func preview(_ name: String, arguments: [String: JSONValue], host resolved: AgentBrowserHost? = nil) -> String? {
        guard let tool = tool(named: name), let preview = tool.preview, let host = resolved ?? hostProvider() else { return nil }
        return AgentRedaction.redact(preview(AxolotlToolCall(arguments: arguments, host: host)))
    }

    /// The window tool calls act on right now; resolve it once before asking for approval.
    func currentHost() -> AgentBrowserHost? { hostProvider() }

    /// Runs a tool. Unknown names throw; bad arguments and tool failures come back as
    /// `isError` results so a model can correct itself. All output is redacted here.
    func call(_ name: String, arguments: [String: JSONValue], source: String = "Axolotl",
              host resolved: AgentBrowserHost? = nil) async throws -> AxolotlToolResult {
        guard let tool = tool(named: name) else { throw AxolotlToolError.unknownTool(name) }
        do {
            try tool.validate(arguments)
            guard let host = resolved ?? hostProvider() else { throw AxolotlToolError.unavailable("No Axolotl browser window is open.") }
            let text = try await tool.run(AxolotlToolCall(arguments: arguments, host: host, source: source))
            return AxolotlToolResult(text: AgentRedaction.redact(text), isError: false)
        } catch {
            return AxolotlToolResult(text: AgentRedaction.redact(error.localizedDescription), isError: true)
        }
    }

    // MARK: Shared page drivers

    /// One driver per web view, so ids from a snapshot taken by one caller stay valid for the next.
    private static let drivers = NSMapTable<WKWebView, PageDriver>.weakToStrongObjects()

    static func driver(for webView: WKWebView) -> PageDriver {
        if let driver = drivers.object(forKey: webView) { return driver }
        let driver = PageDriver(webView: webView)
        drivers.setObject(driver, forKey: webView)
        return driver
    }

    /// The computer-use agent on a tab, for the AI panel's `/agent` and the `run_task` tool.
    static func agent(for webView: WKWebView, maxSteps: Int = AgentPrompts.maxSteps) -> ComputerUseAgent {
        ComputerUseAgent.make(driver: driver(for: webView), maxSteps: maxSteps)
    }

    // MARK: Formatting

    /// Element table plus page text, as tools return it.
    static func describe(_ snap: PageSnapshot) -> String {
        var lines = ["Title: \(snap.title)", "URL: \(snap.url)",
                     "Scroll: \(Int(snap.scroll.y)) of \(Int(snap.scroll.height))", "",
                     "Actions (\(snap.actions.count)\(snap.omittedActions > 0 ? ", \(snap.omittedActions) more not shown" : "")):"]
        for a in snap.actions {
            var row = "\(a.id)\t\(a.kind)\t\(a.label)"
            if let role = a.role { row += "\t[\(role)]" }
            if a.kind == "fill", let v = a.value, !v.isEmpty { row += "\tvalue=\"\(v)\"" }
            if a.kind == "select", let v = a.currentValue, !v.isEmpty { row += "\tcurrent=\"\(v)\"" }
            if let c = a.checked { row += "\tchecked=\(c)" }
            lines.append(row)
        }
        lines += ["", "Text:", snap.text]
        return AgentRedaction.redact(lines.joined(separator: "\n"))
    }

    /// Waits (bounded) for a navigation started on `webView` to begin, so the next
    /// snapshot sees the new page rather than the old one.
    static func waitForNavigationStart(_ webView: WKWebView, from oldURL: URL?, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !webView.isLoading, webView.url == oldURL, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Same rule as `CommandRouter`'s browser actions: http(s) with a host.
nonisolated func isSafeBrowserURL(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
    return url.host != nil
}

import Foundation

/// One model a harness offers, as the harness itself reports it.
nonisolated struct HarnessModel: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// What to pass as `model` to `AgentCLISession.start` (`--model` / `thread/start.model`).
    /// For Claude this may be an alias such as "opus" or "default".
    let id: String
    let displayName: String
    var description: String?
    /// The harness's own default pick (Claude: the "default" alias; Codex: `isDefault`).
    let isDefault: Bool
    /// Reasoning effort levels the model accepts ("low" … "max"), nil when not exposed.
    var efforts: [String]?
    /// Codex's per-model default effort.
    var defaultEffort: String?
    /// The concrete model id an alias resolves to (Claude), when reported.
    var resolvedModel: String?
}

/// Where a model list came from.
nonisolated enum ModelListSource: Equatable, Sendable {
    /// Asked the harness just now (Codex `model/list`, Claude `initialize`).
    case live
    /// Discovery failed; this is the last list that worked, saved at that date.
    case lastKnown(Date)
}

nonisolated struct ModelListing: Equatable, Sendable {
    let harness: HarnessID
    let models: [HarnessModel]
    let source: ModelListSource
    let fetchedAt: Date
    var defaultModel: HarnessModel? { models.first(where: \.isDefault) ?? models.first }
}

nonisolated enum ModelCatalogError: LocalizedError, Equatable {
    case unsupported(HarnessID)
    case notInstalled(HarnessID)
    case discoveryFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let id): return "\(id.displayName) is installed but Luna cannot drive it yet."
        case .notInstalled(let id): return "\(id.displayName) is not installed."
        case .discoveryFailed(let why): return "Could not list models: \(why)"
        }
    }
}

/// Asks each harness which models it offers, instead of a hard-coded list.
///
/// - Codex: `codex app-server` → `initialize` → `model/list` (paged, hidden models excluded).
/// - Claude Code: `claude -p --input-format stream-json` → control `initialize`; the response's
///   `models` is what the SDK's `supportedModels()` returns. No turn is sent, so it costs nothing;
///   `--no-session-persistence` keeps it out of `~/.claude/projects`.
///
/// Results are cached per harness in memory and the last good list is kept in UserDefaults:
/// when discovery fails, that list is returned with `source == .lastKnown`.
///
///     let models = try await HarnessModelCatalog.shared.models(for: .codex)
///     let listing = try await HarnessModelCatalog.shared.listing(for: .claudeCode, refresh: true)
actor HarnessModelCatalog {
    static let shared = HarnessModelCatalog()

    typealias Prober = @Sendable (HarnessID, String) async throws -> [HarnessModel]

    private let defaults: UserDefaults
    private let executable: @Sendable (HarnessID) async -> String?
    private let probe: Prober
    private var cache: [HarnessID: ModelListing] = [:]

    init(defaults: UserDefaults = .standard,
         executable: @escaping @Sendable (HarnessID) async -> String? = { await HarnessCatalog.shared.info($0)?.executable },
         probe: @escaping Prober = HarnessModelCatalog.liveProbe) {
        self.defaults = defaults
        self.executable = executable
        self.probe = probe
    }

    func models(for harness: HarnessID, refresh: Bool = false) async throws -> [HarnessModel] {
        try await listing(for: harness, refresh: refresh).models
    }

    func listing(for harness: HarnessID, refresh: Bool = false) async throws -> ModelListing {
        guard harness.isSupported else { throw ModelCatalogError.unsupported(harness) }
        if !refresh, let cached = cache[harness] { return cached }
        do {
            guard let path = await executable(harness) else { throw ModelCatalogError.notInstalled(harness) }
            let models = try await probe(harness, path)
            guard !models.isEmpty else { throw ModelCatalogError.discoveryFailed("empty list") }
            let listing = ModelListing(harness: harness, models: models, source: .live, fetchedAt: Date())
            cache[harness] = listing
            saveLastKnown(listing)
            return listing
        } catch {
            if let saved = lastKnown(harness) {
                cache[harness] = saved
                return saved
            }
            throw error
        }
    }

    /// Drops the in-memory cache (the last-known fallback stays).
    func invalidate(_ harness: HarnessID? = nil) {
        if let harness { cache[harness] = nil } else { cache.removeAll() }
    }

    // MARK: Last-known persistence

    private struct Saved: Codable { let models: [HarnessModel]; let savedAt: Date }

    static func lastKnownKey(_ harness: HarnessID) -> String { "luna_dev.models.lastKnown.\(harness.rawValue)" }

    private func saveLastKnown(_ listing: ModelListing) {
        if let data = try? JSONEncoder().encode(Saved(models: listing.models, savedAt: listing.fetchedAt)) {
            defaults.set(data, forKey: Self.lastKnownKey(listing.harness))
        }
    }

    private func lastKnown(_ harness: HarnessID) -> ModelListing? {
        guard let data = defaults.data(forKey: Self.lastKnownKey(harness)),
              let saved = try? JSONDecoder().decode(Saved.self, from: data), !saved.models.isEmpty else { return nil }
        return ModelListing(harness: harness, models: saved.models, source: .lastKnown(saved.savedAt), fetchedAt: saved.savedAt)
    }

    // MARK: Parsing (pure, fixture-tested)

    /// Codex `model/list` result (`{"data":[Model], "nextCursor": …}`); hidden models dropped.
    static func parseCodexModelList(_ result: [String: Any]) -> (models: [HarnessModel], nextCursor: String?) {
        let data = result["data"] as? [[String: Any]] ?? []
        let models: [HarnessModel] = data.compactMap { m in
            guard let id = (m["id"] as? String) ?? (m["model"] as? String), !id.isEmpty else { return nil }
            if m["hidden"] as? Bool == true { return nil }
            let efforts = (m["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap { $0["reasoningEffort"] as? String }
            return HarnessModel(id: id, displayName: (m["displayName"] as? String) ?? id,
                                description: m["description"] as? String,
                                isDefault: m["isDefault"] as? Bool ?? false,
                                efforts: (efforts?.isEmpty ?? true) ? nil : efforts,
                                defaultEffort: m["defaultReasoningEffort"] as? String,
                                resolvedModel: m["model"] as? String)
        }
        return (models, result["nextCursor"] as? String)
    }

    /// Claude Code `initialize` control response payload (`response.response`): its `models`.
    /// The entry whose value is "default" is the default; if none, the first.
    static func parseClaudeInitialize(_ response: [String: Any]) -> [HarnessModel] {
        let raw = response["models"] as? [[String: Any]] ?? []
        var models: [HarnessModel] = raw.compactMap { m in
            guard let value = m["value"] as? String, !value.isEmpty else { return nil }
            let efforts = m["supportedEffortLevels"] as? [String]
            return HarnessModel(id: value, displayName: (m["displayName"] as? String) ?? value,
                                description: m["description"] as? String,
                                isDefault: value == "default",
                                efforts: (m["supportsEffort"] as? Bool == true && !(efforts?.isEmpty ?? true)) ? efforts : nil,
                                defaultEffort: nil,
                                resolvedModel: m["resolvedModel"] as? String)
        }
        if !models.isEmpty, !models.contains(where: \.isDefault) {
            let first = models[0]
            models[0] = HarnessModel(id: first.id, displayName: first.displayName, description: first.description, isDefault: true,
                                     efforts: first.efforts, defaultEffort: first.defaultEffort, resolvedModel: first.resolvedModel)
        }
        return models
    }

    // MARK: Live probes

    static let liveProbe: Prober = { harness, path in
        switch harness {
        case .codex: return try await probeCodex(path: path)
        case .claudeCode: return try await probeClaude(path: path)
        default: throw ModelCatalogError.unsupported(harness)
        }
    }

    /// Runs `codex app-server` just long enough for `model/list` (all pages).
    static func probeCodex(path: String, timeout: TimeInterval = 20) async throws -> [HarnessModel] {
        let session = try ProbeProcess(executable: path, arguments: ["app-server"])
        defer { session.stop() }
        session.send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                      "params": ["clientInfo": ["name": "luna", "title": "Luna", "version": "1.0"]]])
        session.send(["jsonrpc": "2.0", "method": "initialized"])
        var all: [HarnessModel] = []
        var cursor: String?
        var requestID = 2
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let id = requestID
            session.send(["jsonrpc": "2.0", "id": id, "method": "model/list", "params": params])
            let reply = try await session.waitFor(timeout: timeout) { ($0["id"] as? Int) == id }
            if let error = reply["error"] as? [String: Any] {
                throw ModelCatalogError.discoveryFailed(error["message"] as? String ?? "model/list failed")
            }
            let page = parseCodexModelList(reply["result"] as? [String: Any] ?? [:])
            all += page.models
            cursor = page.nextCursor
            requestID += 1
        } while cursor != nil && requestID < 12
        return all
    }

    /// Runs `claude -p` in stream-json mode and reads the models from the `initialize` reply.
    static func probeClaude(path: String, timeout: TimeInterval = 30) async throws -> [HarnessModel] {
        let session = try ProbeProcess(executable: path, arguments: [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--no-session-persistence", "--permission-mode", "plan",
        ])
        defer { session.stop() }
        session.send(["type": "control_request", "request_id": "luna-models", "request": ["subtype": "initialize"]])
        let reply = try await session.waitFor(timeout: timeout) {
            ($0["type"] as? String) == "control_response"
                && (($0["response"] as? [String: Any])?["request_id"] as? String) == "luna-models"
        }
        let response = reply["response"] as? [String: Any] ?? [:]
        if response["subtype"] as? String == "error" {
            throw ModelCatalogError.discoveryFailed(response["error"] as? String ?? "initialize failed")
        }
        return parseClaudeInitialize(response["response"] as? [String: Any] ?? [:])
    }
}

/// A short-lived NDJSON child for discovery probes, run in the home folder with the clean
/// login environment. Lines are parsed with JSONSerialization (no MainActor types).
nonisolated final class ProbeProcess: @unchecked Sendable {
    private let process: CLIProcess
    private var iterator: AsyncStream<Data>.AsyncIterator

    init(executable: String, arguments: [String]) throws {
        process = CLIProcess(executable: URL(fileURLWithPath: executable), arguments: arguments,
                             workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
                             environment: LoginShellEnvironment.environment())
        iterator = process.lines.makeAsyncIterator()
        try process.start { _ in }
    }

    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        _ = process.write(data)
    }

    /// The first stdout record matching `predicate`; throws on timeout or when the child exits.
    func waitFor(timeout: TimeInterval, _ predicate: @escaping @Sendable ([String: Any]) -> Bool) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        let process = self.process
        let watchdog = Task.detached {
            while Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
            process.terminate(grace: 0.5)
        }
        defer { watchdog.cancel() }
        while let line = await iterator.next() {
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if predicate(object) { return object }
        }
        throw ModelCatalogError.discoveryFailed(Date() >= deadline ? "timed out" : "the CLI exited early")
    }

    func stop() { process.terminate(grace: 1) }
}

/// Harness models next to the cloud-provider catalog (`ModelCatalog` in AI/Panel).
extension ModelCatalog {
    /// Models `harness` offers, discovered from the CLI itself (see `HarnessModelCatalog`).
    static func models(for harness: HarnessID, refresh: Bool = false) async throws -> [HarnessModel] {
        try await HarnessModelCatalog.shared.models(for: harness, refresh: refresh)
    }

    /// Models plus where they came from (`.live` or `.lastKnown`).
    static func listing(for harness: HarnessID, refresh: Bool = false) async throws -> ModelListing {
        try await HarnessModelCatalog.shared.listing(for: harness, refresh: refresh)
    }
}

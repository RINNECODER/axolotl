import Foundation

/// What a mapper produced for one CLI line: events for the UI and records to write back.
struct CLIMapResult: Equatable {
    var events: [CLIEvent] = []
    var replies: [JSONValue] = []
}

/// Process plumbing shared by the Claude Code and Codex adapters.
@MainActor
class CLIAdapterBase {
    let kind: AgentCLIKind
    let events: AsyncStream<CLIEvent>
    private let continuation: AsyncStream<CLIEvent>.Continuation
    let mcp: DevMCPAttachment?
    let resumeStore: AgentCLIResumeStore
    /// Overrides PATH lookup (tests); nil resolves `kind.executableName` on the login PATH.
    var executableOverride: URL?

    private(set) var process: CLIProcess?
    private(set) var projectDir: URL?
    private(set) var sessionID: String?
    private var readTask: Task<Void, Never>?
    private var finished = false

    init(kind: AgentCLIKind, mcp: DevMCPAttachment?, resumeStore: AgentCLIResumeStore = AgentCLIResumeStore()) {
        self.kind = kind
        self.mcp = mcp
        self.resumeStore = resumeStore
        (events, continuation) = AsyncStream.makeStream(of: CLIEvent.self, bufferingPolicy: .unbounded)
    }

    var isRunning: Bool { process?.isRunning == true && !finished }

    func resolveExecutable() throws -> URL {
        if let executableOverride { return executableOverride }
        guard DevMode.isAvailable else {
            throw AgentCLIError.unavailable("Dev mode needs the unsandboxed Luna Dev build.")
        }
        let name = DevSettings.executable(for: kind)
        if name.contains("/") { return URL(fileURLWithPath: name) }
        guard let path = LoginShellEnvironment.locate(name) else {
            throw AgentCLIError.notFound(name)
        }
        return URL(fileURLWithPath: path)
    }

    func launch(arguments: [String], projectDir: URL, extraEnvironment: [String: String] = [:]) throws {
        guard process == nil else { throw AgentCLIError.alreadyStarted }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw AgentCLIError.launchFailed("\(projectDir.path) is not a folder")
        }
        let executable = try resolveExecutable()
        let process = CLIProcess(executable: executable, arguments: arguments, workingDirectory: projectDir,
                                 environment: LoginShellEnvironment.environment(adding: extraEnvironment))
        self.projectDir = projectDir
        self.process = process
        try process.start { [weak self] termination in
            let owner = self
            Task { @MainActor in owner?.processEnded(termination) }
        }
        readTask = Task { @MainActor [weak self] in
            for await line in process.lines {
                guard let self else { return }
                guard let json = CLIText.parse(line) else {
                    self.emit(.error("Unreadable output from \(self.kind.displayName): \(CLIText.clip(String(decoding: line, as: UTF8.self), 200))"))
                    continue
                }
                self.handle(json)
            }
        }
    }

    /// Subclasses map one parsed stdout record.
    func handle(_ message: JSONValue) {}

    /// Subclasses clean up after the process is gone (temp files, tokens).
    func didEnd() {}

    func emit(_ event: CLIEvent) {
        guard !finished else { return }
        if case .sessionStarted(let id) = event {
            sessionID = id
            if let projectDir { resumeStore.save(id, kind: kind, projectDir: projectDir) }
        }
        continuation.yield(event)
    }

    func apply(_ result: CLIMapResult) {
        for reply in result.replies { write(reply) }
        for event in result.events { emit(event) }
    }

    @discardableResult
    func write(_ value: JSONValue) -> Bool {
        process?.write(CLIText.line(value)) ?? false
    }

    func requireRunning() throws {
        guard let process, process.isRunning, !finished else { throw AgentCLIError.notStarted }
    }

    func close() {
        guard let process else { finishStream(nil); return }
        process.terminate()
    }

    private func processEnded(_ termination: CLIProcess.Termination) {
        Task { @MainActor [weak self] in
            // Let the reader drain lines already queued before reporting the exit.
            await self?.readTask?.value
            guard let self else { return }
            let exit = CLIExit(status: termination.status, signaled: termination.signaled,
                               expected: termination.requested, stderrTail: termination.stderrTail)
            if !exit.expected {
                var message = "\(self.kind.displayName) exited unexpectedly (\(exit.signaled ? "signal" : "status") \(exit.status))."
                if !exit.stderrTail.isEmpty { message += "\n" + exit.stderrTail }
                self.emit(.error(message))
            }
            self.finishStream(exit)
        }
    }

    private func finishStream(_ exit: CLIExit?) {
        guard !finished else { return }
        if let exit { continuation.yield(.exited(exit)) }
        finished = true
        continuation.finish()
        didEnd()
    }
}

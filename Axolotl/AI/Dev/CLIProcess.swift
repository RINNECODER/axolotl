import Darwin
import Foundation

/// Splits a byte stream into newline-delimited records (NDJSON). Chunks may end mid-line or
/// hold many lines; a trailing `\r` is dropped and blank lines are skipped.
nonisolated struct NDJSONFramer {
    private var pending = Data()
    /// A single line longer than this is dropped rather than buffered forever.
    let maxLineBytes: Int
    private var discarding = false

    init(maxLineBytes: Int = 32 * 1024 * 1024) { self.maxLineBytes = maxLineBytes }

    mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var rest = chunk[...]
        while let nl = rest.firstIndex(of: 0x0A) {
            if discarding {
                discarding = false
                pending.removeAll()
            } else {
                pending.append(contentsOf: rest[rest.startIndex..<nl])
                if let line = Self.clean(pending) { lines.append(line) }
                pending.removeAll(keepingCapacity: true)
            }
            rest = rest[rest.index(after: nl)...]
        }
        if !discarding {
            pending.append(contentsOf: rest)
            if pending.count > maxLineBytes { pending.removeAll(); discarding = true }
        }
        return lines
    }

    /// Whatever is left when the stream ends (a last line without a newline).
    mutating func finish() -> Data? {
        defer { pending.removeAll(); discarding = false }
        return discarding ? nil : Self.clean(pending)
    }

    private static func clean(_ line: Data) -> Data? {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return nil }
        return Data(line)
    }
}

/// Keeps only the last `capacity` bytes written (stderr for crash reports).
nonisolated struct BoundedBuffer {
    let capacity: Int
    private(set) var data = Data()
    private(set) var droppedBytes = 0

    init(capacity: Int = 64 * 1024) { self.capacity = capacity }

    mutating func append(_ chunk: Data) {
        data.append(chunk)
        if data.count > capacity {
            let extra = data.count - capacity
            droppedBytes += extra
            data.removeFirst(extra)
        }
    }

    var text: String { String(decoding: data, as: UTF8.self) }
}

/// One CLI child process with NDJSON over stdin/stdout and a bounded stderr buffer.
nonisolated final class CLIProcess: @unchecked Sendable {
    struct Termination: Sendable, Equatable {
        let status: Int32
        let signaled: Bool
        let requested: Bool
        let stderrTail: String
    }

    let executable: URL
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]

    /// One element per NDJSON line from stdout; finishes when stdout closes.
    let lines: AsyncStream<Data>
    private let linesContinuation: AsyncStream<Data>.Continuation

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    /// Separate from `lock` so a blocked stdin write never stalls stdout draining.
    private let writeLock = NSLock()
    /// Serial queue for the blocking stdin write, so a full pipe never stalls the caller (the MainActor).
    private let writeQueue = DispatchQueue(label: "axolotl.cli.stdin")
    private var framer = NDJSONFramer()
    private var stderr = BoundedBuffer()
    private var terminationRequested = false
    private var stdinClosed = false
    private var onExit: (@Sendable (Termination) -> Void)?
    private var stdoutDone = false
    private var exitStatus: (Int32, Bool)?

    init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        // Unbounded on purpose: these are JSON-RPC/stream-json protocol lines (replies, approval requests,
        // turn ends); dropping one desyncs the session. The framer already caps each line's size.
        (lines, linesContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    /// `onExit` fires once, after stdout has drained, with the stderr tail.
    func start(onExit: @escaping @Sendable (Termination) -> Void) throws {
        self.onExit = onExit
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment
        process.standardInput = stdinPipe
        // A write after the child died must fail with EPIPE, not kill Axolotl with SIGPIPE.
        _ = fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                self.lock.lock()
                let last = self.framer.finish()
                self.lock.unlock()
                if let last { self.linesContinuation.yield(last) }
                self.linesContinuation.finish()
                self.markStdoutDone()
                return
            }
            self.lock.lock()
            let lines = self.framer.append(chunk)
            self.lock.unlock()
            for line in lines { self.linesContinuation.yield(line) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty { handle.readabilityHandler = nil; return }
            self.lock.lock(); self.stderr.append(chunk); self.lock.unlock()
        }
        process.terminationHandler = { [weak self] p in
            self?.markExited(status: p.terminationStatus, signaled: p.terminationReason == .uncaughtSignal)
        }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            linesContinuation.finish()
            throw AgentCLIError.launchFailed(error.localizedDescription)
        }
    }

    /// Queues one record; a newline is appended if missing. False once stdin is closed.
    /// The write itself runs on a background queue; a failure surfaces as the process exiting.
    @discardableResult
    func write(_ line: Data) -> Bool {
        writeLock.lock()
        let open = !stdinClosed && process.isRunning
        writeLock.unlock()
        guard open else { return false }
        var data = line
        if data.last != 0x0A { data.append(0x0A) }
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.async { [weak self] in
            guard let self else { return }
            self.writeLock.lock(); let closed = self.stdinClosed; self.writeLock.unlock()
            if !closed { try? handle.write(contentsOf: data) }
        }
        return true
    }

    func closeStdin() {
        writeLock.lock()
        guard !stdinClosed else { writeLock.unlock(); return }
        stdinClosed = true
        writeLock.unlock()
        let handle = stdinPipe.fileHandleForWriting
        // Behind any queued writes, which were accepted before the close.
        writeQueue.async { try? handle.close() }
    }

    /// SIGINT, like Ctrl-C.
    func interrupt() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
    }

    /// Closes stdin, sends SIGTERM to the process and its descendants, then SIGKILL after `grace`
    /// if any are still alive. `Process` cannot start a new process group, so the tree is walked
    /// instead of `kill(-pgid)`. The fallback holds the `Process`, not `self`.
    func terminate(grace: TimeInterval = 3) {
        lock.lock(); terminationRequested = true; lock.unlock()
        closeStdin()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let process = self.process
        let tree = Self.descendants(of: pid)
        process.terminate()
        for child in tree { kill(child, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            let late = Self.descendants(of: pid)
            if process.isRunning { kill(pid, SIGKILL) }
            for child in Set(tree + late) where kill(child, 0) == 0 { kill(child, SIGKILL) }
        }
    }

    /// All live descendants of `pid` (libproc), children first.
    static func descendants(of pid: Int32) -> [Int32] {
        var found: [Int32] = []
        var queue: [Int32] = [pid]
        while let next = queue.popLast(), found.count < 512 {
            var buffer = [Int32](repeating: 0, count: 256)
            // Takes the buffer size in bytes but returns a pid count.
            let count = proc_listchildpids(next, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
            guard count > 0 else { continue }
            let kids = buffer.prefix(Int(count)).filter { $0 > 0 }
            found += kids
            queue += kids
        }
        return found
    }

    var stderrTail: String { lock.lock(); defer { lock.unlock() }; return stderr.text }

    private func markStdoutDone() {
        lock.lock(); stdoutDone = true; lock.unlock()
        fireExitIfReady()
    }

    private func markExited(status: Int32, signaled: Bool) {
        lock.lock(); exitStatus = (status, signaled); lock.unlock()
        // A grandchild holding stdout open must not stall the exit report forever.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let pending = !self.stdoutDone; self.lock.unlock()
            if pending {
                self.stdoutPipe.fileHandleForReading.readabilityHandler = nil
                self.linesContinuation.finish()
                self.markStdoutDone()
            }
        }
        fireExitIfReady()
    }

    private func fireExitIfReady() {
        lock.lock()
        guard stdoutDone, let (status, signaled) = exitStatus, let handler = onExit else { lock.unlock(); return }
        onExit = nil
        let termination = Termination(status: status, signaled: signaled, requested: terminationRequested, stderrTail: Self.tail(stderr.text))
        lock.unlock()
        handler(termination)
    }

    static func tail(_ text: String, maxCharacters: Int = 4000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > maxCharacters ? "…" + String(trimmed.suffix(maxCharacters)) : trimmed
    }
}

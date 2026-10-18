import Darwin
import Foundation

/// A CLI on a pseudo-terminal, for the raw-terminal view of Dev mode (render it with a
/// terminal emulator such as SwiftTerm: feed `output` in, send keystrokes with `write`).
nonisolated final class PTYSession: @unchecked Sendable {
    let executable: String
    let arguments: [String]
    let workingDirectory: URL
    let environment: [String: String]

    /// Raw bytes from the terminal; finishes when the child closes it.
    let output: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    private(set) var pid: pid_t = 0
    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private let lock = NSLock()
    private var onExit: (@Sendable (Int32) -> Void)?

    /// Set once the child has been reaped. Shared with the exit handler and the SIGKILL fallback,
    /// which both outlive this object, so a signal is never sent to a recycled pid.
    private final class ReapState: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var reaped: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func markReaped() { lock.lock(); done = true; lock.unlock() }
    }
    private let reapState = ReapState()

    /// `executable` may be a bare name; it is looked up on the login PATH.
    init(executable: String, arguments: [String] = [], workingDirectory: URL, environment: [String: String]? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        // Always a clean login environment with TERM forced to what SwiftTerm emulates; see
        // `LoginShellEnvironment.environment` for what inheriting Luna's own env broke.
        var env = environment.map { LoginShellEnvironment.sanitized($0) } ?? LoginShellEnvironment.terminalEnvironment()
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if (env["LANG"] ?? "").isEmpty, (env["LC_ALL"] ?? "").isEmpty { env["LANG"] = "en_US.UTF-8" }
        self.environment = env
        (output, outputContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
    }

    /// Spawns the child as a session leader with the PTY as its controlling terminal.
    /// `onExit` gets the raw wait status (use `WIFEXITED`-style checks or `exitCode(_:)`).
    func start(columns: UInt16 = 120, rows: UInt16 = 40, onExit: (@Sendable (Int32) -> Void)? = nil) throws {
        let path = executable.contains("/") ? executable : (LoginShellEnvironment.locate(executable, path: environment["PATH"]) ?? executable)
        guard FileManager.default.isExecutableFile(atPath: path) else { throw AgentCLIError.notFound(executable) }
        self.onExit = onExit

        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, &size) == 0 else { throw AgentCLIError.launchFailed("openpty failed (errno \(errno))") }
        let slaveName = String(cString: ptsname(masterFD))
        defer { close(slaveFD) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // Opening the tty as a new session leader makes it the controlling terminal (XNU),
        // so Ctrl-C and job control work like in Terminal.
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, masterFD)
        posix_spawn_file_actions_addclose(&actions, slaveFD)
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        var defaults = sigset_t(), empty = sigset_t()
        sigfillset(&defaults)
        sigemptyset(&empty)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &empty)

        let argv = ([path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var child: pid_t = 0
        let rc = posix_spawn(&child, path, &actions, &attr, argv, envp)
        guard rc == 0 else {
            close(masterFD)
            throw AgentCLIError.launchFailed(String(cString: strerror(rc)))
        }
        pid = child
        master = masterFD
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(masterFD, F_SETNOSIGPIPE, 1)

        let queue = DispatchQueue(label: "luna.pty.\(child)")
        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = Darwin.read(masterFD, &buffer, buffer.count)
            if n > 0 {
                self.outputContinuation.yield(Data(buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // EIO once the last slave fd closes: the child is gone.
                read.cancel()
            }
        }
        read.setCancelHandler { [weak self] in
            self?.lock.lock()
            self?.master = -1
            self?.lock.unlock()
            close(masterFD)
            self?.outputContinuation.finish()
        }
        readSource = read
        read.resume()

        let reapState = self.reapState
        let exit = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            reapState.markReaped()
            exit.cancel()
            guard let self else { return }
            self.lock.lock(); let handler = self.onExit; self.onExit = nil; self.lock.unlock()
            handler?(status)
            // Give the reader a moment to drain, then stop it.
            queue.asyncAfter(deadline: .now() + 0.2) { self.readSource?.cancel() }
        }
        exitSource = exit
        exit.resume()
    }

    /// Keystrokes / pasted text, raw (e.g. "\u{3}" for Ctrl-C).
    func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard master >= 0 else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(master, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if errno == EAGAIN || errno == EINTR { usleep(1000) } else { break }
            }
        }
    }

    func write(_ text: String) { write(Data(text.utf8)) }

    func resize(columns: UInt16, rows: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard master >= 0 else { return }
        var size = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    /// SIGHUP to the child's process group (like closing a Terminal tab), SIGKILL after `grace`.
    /// The exit source (which deliberately outlives this object) reaps the child, so it never
    /// lingers as a zombie; the fallback does not touch `self`.
    func terminate(grace: TimeInterval = 2) {
        guard pid > 0 else { return }
        let target = pid
        let state = reapState
        guard !state.reaped else { return }
        kill(-target, SIGHUP)
        kill(target, SIGHUP)
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) {
            if !state.reaped { kill(-target, SIGKILL); kill(target, SIGKILL) }
        }
    }

    static func exitCode(_ status: Int32) -> Int32? {
        (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
    }

    deinit {
        // The exit source is left running on purpose: cancelling it here would leave an
        // unreaped zombie if the child exits later. Its handler cancels it after reaping.
        readSource?.cancel()
    }
}

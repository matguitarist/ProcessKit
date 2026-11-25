import Darwin
import Foundation

/// One run of a command: posix_spawn, then one loop on the calling thread that reads stdout and
/// stderr, writes stdin, and watches for the end, the timeout and a stop, all through poll().
struct Execution {
    let tool: String
    let arguments: [String]
    let options: Shell.Options
    /// Set when the task is cancelled or the stream ends.
    let stop: Shell.CancelFlag
    /// False for `lines`: stdout goes to `onLine` only.
    var keepsStdout = true

    /// How long the pipes may stay open once the command has ended: a program it left running in the
    /// background (ssh -f, a daemon) can hold them open forever.
    static let drainTime: Duration = .milliseconds(500)
    /// The most stderr kept when stdout isn't (`lines`), enough for an error message.
    static let stderrTail = 64 * 1024

    private enum Stop { case cancelled, timedOut, outputLimit }

    func run() throws -> Shell.Output {
        let environment = makeEnvironment()
        guard let url = Shell.locate(tool, path: environment["PATH"]) else { throw ShellError.notFound(tool) }
        let path = url.path
        if stop.isCancelled || options.cancel?.isCancelled == true { throw CancellationError() }

        // MARK: Pipes and file actions

        var fds = Descriptors()
        defer { fds.closeAll() }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        var pendingInput = Data()
        switch options.input {
        case .none:
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        case .file(let file):
            posix_spawn_file_actions_addopen(&actions, 0, file.path, O_RDONLY, 0)
        case .data(let data):
            let pipe = try fds.pipe(tool: path)
            fds.input = pipe.write
            fds.childEnds.append(pipe.read)
            posix_spawn_file_actions_adddup2(&actions, pipe.read, 0)
            pendingInput = data
        case .open:
            let pipe = try fds.pipe(tool: path)
            fds.input = pipe.write
            fds.childEnds.append(pipe.read)
            posix_spawn_file_actions_adddup2(&actions, pipe.read, 0)
        }

        switch options.stdout {
        case .capture, .merged:
            let pipe = try fds.pipe(tool: path)
            fds.stdout = pipe.read
            fds.childEnds.append(pipe.write)
            posix_spawn_file_actions_adddup2(&actions, pipe.write, 1)
        case .discard:
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        case .file(let file):
            posix_spawn_file_actions_addopen(&actions, 1, file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        switch options.stderr {
        case .capture:
            let pipe = try fds.pipe(tool: path)
            fds.stderr = pipe.read
            fds.childEnds.append(pipe.write)
            posix_spawn_file_actions_adddup2(&actions, pipe.write, 2)
        case .merged:
            posix_spawn_file_actions_adddup2(&actions, 1, 2)
        case .discard:
            posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        case .file(let file):
            posix_spawn_file_actions_addopen(&actions, 2, file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        }
        if let directory = options.directory {
            posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        }

        // MARK: Attributes

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the descriptors set up above reach the child; it leads a process group of its own, so a stop
        // reaches what it started too; signals the app ignores or blocks (SIGPIPE) are back to normal.
        let flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults: sigset_t = 0
        for signal in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGCHLD, SIGALRM, SIGUSR1, SIGUSR2, SIGTTIN, SIGTTOU] {
            defaults |= 1 << sigset_t(signal - 1)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &mask)
        if options.disclaimsResponsibility { _ = Responsibility.disclaim?(&attributes, 1) }

        // MARK: Spawn

        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + arguments).map { strdup($0) } + [nil]
        defer { for pointer in argv { free(pointer) } }
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for pointer in envp { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv, envp)
        // The child has its own copies; ours must close, or reads never see end of file.
        fds.closeChildEnds()
        guard result == 0 else { throw ShellError.couldNotStart(path, code: result) }

        return try watch(pid: pid, path: path, fds: &fds, pendingInput: pendingInput)
    }

    // MARK: The loop

    private func watch(pid: pid_t, path: String, fds: inout Descriptors, pendingInput: Data) throws -> Shell.Output {
        let clock = ContinuousClock()
        let deadline = options.timeout.map { clock.now + $0 }
        var input = pendingInput
        var inputOffset = 0
        if case .data = options.input, input.isEmpty { fds.closeInput() }

        var stdout = Data()
        var stderr = Data()
        var truncated = false
        var splitter = LineSplitter()
        var status: Int32?
        var exitedAt: ContinuousClock.Instant?
        var stopReason: Stop?
        var killAt: ContinuousClock.Instant?
        var napMilliseconds: Int32 = 1
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func handleStdout(_ chunk: Data) {
            if let onLine = options.onLine {
                for line in splitter.feed(chunk) { onLine(line) }
            }
            guard keepsStdout else { return }
            if let limit = options.outputLimit, stdout.count + chunk.count > limit {
                stdout.append(chunk.prefix(max(0, limit - stdout.count)))
                truncated = true
            } else {
                stdout.append(chunk)
            }
        }

        func handleStderr(_ chunk: Data) {
            stderr.append(chunk)
            if !keepsStdout, stderr.count > Self.stderrTail { stderr = stderr.suffix(Self.stderrTail) }
        }

        /// Reads what's there now, a few chunks at most so a fast writer can't keep the loop here;
        /// true at end of file.
        func drain(_ fd: Int32, _ handle: (Data) -> Void) -> Bool {
            for _ in 0..<16 {
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    handle(Data(buffer[0..<count]))
                    continue
                }
                if count == 0 { return true }
                if errno == EINTR { continue }
                return errno != EAGAIN
            }
            return false
        }

        func beginStop(_ reason: Stop) {
            guard stopReason == nil else { return }
            stopReason = reason
            // End of file first, so ssh's remote side ends even if the signal races.
            fds.closeInput()
            if status == nil {
                kill(-pid, SIGTERM)
                kill(pid, SIGTERM)
            }
            killAt = clock.now + options.gracePeriod
        }

        while true {
            // Reap without blocking.
            if status == nil {
                var raw: Int32 = 0
                let reaped = waitpid(pid, &raw, WNOHANG)
                if reaped == pid {
                    status = raw
                    exitedAt = clock.now
                    // Whatever a stopped command left running goes with it.
                    if stopReason != nil { kill(-pid, SIGKILL) }
                } else if reaped == -1, errno != EINTR {
                    status = 0
                    exitedAt = clock.now
                }
            }
            if status != nil, !fds.hasOutput { break }
            if let exitedAt, clock.now - exitedAt > Self.drainTime {
                fds.closeOutputs()
                break
            }

            // Stops.
            if stop.isCancelled || options.cancel?.isCancelled == true { beginStop(.cancelled) }
            if let deadline, clock.now >= deadline { beginStop(.timedOut) }
            if truncated { beginStop(.outputLimit) }
            if let killAt, status == nil, clock.now >= killAt {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }

            // Wait for something to read or write, or a short while.
            var polled: [pollfd] = []
            if let fd = fds.stdout { polled.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0)) }
            if let fd = fds.stderr { polled.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0)) }
            if let fd = fds.input, inputOffset < input.count { polled.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)) }
            if polled.isEmpty {
                // Nothing to read: only the end to wait for. Short naps first, for quick commands.
                usleep(useconds_t(napMilliseconds) * 1000)
                napMilliseconds = min(napMilliseconds * 2, 50)
                continue
            }
            let ready = poll(&polled, nfds_t(polled.count), status == nil ? 50 : 10)
            if ready < 0, errno != EINTR { break }
            for entry in polled where entry.revents != 0 {
                if entry.fd == fds.stdout {
                    if drain(entry.fd, handleStdout) { fds.closeStdout() }
                } else if entry.fd == fds.stderr {
                    if drain(entry.fd, handleStderr) { fds.closeStderr() }
                } else if entry.fd == fds.input {
                    let written = input.withUnsafeBytes { bytes in
                        write(entry.fd, bytes.baseAddress! + inputOffset, bytes.count - inputOffset)
                    }
                    if written > 0 {
                        inputOffset += written
                        if inputOffset >= input.count {
                            fds.closeInput()
                            input = Data()
                            inputOffset = 0
                        }
                    } else if written < 0, errno != EAGAIN, errno != EINTR {
                        // The command closed its stdin (EPIPE): the rest isn't wanted.
                        fds.closeInput()
                        input = Data()
                        inputOffset = 0
                    }
                }
            }
        }

        // The pipes were given up on: still wait for the command itself.
        while status == nil {
            if stop.isCancelled || options.cancel?.isCancelled == true { beginStop(.cancelled) }
            if let deadline, clock.now >= deadline { beginStop(.timedOut) }
            if let killAt, clock.now >= killAt {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
            var raw: Int32 = 0
            let reaped = waitpid(pid, &raw, WNOHANG)
            if reaped == pid || (reaped == -1 && errno != EINTR) {
                status = reaped == pid ? raw : 0
                break
            }
            usleep(useconds_t(napMilliseconds) * 1000)
            napMilliseconds = min(napMilliseconds * 2, 50)
        }
        if let onLine = options.onLine, let last = splitter.finish() { onLine(last) }

        let raw = status ?? 0
        let signal = raw & 0x7F
        let output = Shell.Output(
            tool: path, arguments: arguments,
            status: signal == 0 ? (raw >> 8) & 0xFF : 128 + signal,
            signal: signal == 0 ? nil : signal,
            stdout: stdout, stderr: stderr, truncated: truncated
        )
        switch stopReason {
        case .cancelled: throw CancellationError()
        case .timedOut: throw ShellError.timedOut(output)
        case .outputLimit, nil: return output
        }
    }

    // MARK: Environment

    private func makeEnvironment() -> [String: String] {
        var environment = options.inheritsEnvironment ? ProcessInfo.processInfo.environment : [:]
        environment.merge(options.environment) { _, new in new }
        return environment
    }
}

/// The parent's ends of the pipes, closed once each.
private struct Descriptors {
    var input: Int32?
    var stdout: Int32?
    var stderr: Int32?
    var childEnds: [Int32] = []

    var hasOutput: Bool { stdout != nil || stderr != nil }

    /// A pipe whose ends don't leak into other programs the app starts, with the parent's end
    /// non-blocking, and no SIGPIPE when writing to a command that closed its stdin.
    mutating func pipe(tool: String) throws -> (read: Int32, write: Int32) {
        var ends: [Int32] = [0, 0]
        guard Darwin.pipe(&ends) == 0 else { throw ShellError.couldNotStart(tool, code: errno) }
        for fd in ends {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }
        return (ends[0], ends[1])
    }

    /// Makes the parent's ends non-blocking, once the child has its own.
    mutating func closeChildEnds() {
        for fd in childEnds { close(fd) }
        childEnds = []
        for fd in [input, stdout, stderr].compactMap({ $0 }) {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }

    mutating func closeInput() { if let fd = input { close(fd); input = nil } }
    mutating func closeStdout() { if let fd = stdout { close(fd); stdout = nil } }
    mutating func closeStderr() { if let fd = stderr { close(fd); stderr = nil } }
    mutating func closeOutputs() { closeStdout(); closeStderr() }

    mutating func closeAll() {
        closeInput()
        closeOutputs()
        for fd in childEnds { close(fd) }
        childEnds = []
    }
}

/// responsibility_spawnattrs_setdisclaim, a private call Terminal uses; nil if macOS ever drops it.
private enum Responsibility {
    typealias Disclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    static let disclaim: Disclaim? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim") else { return nil }
        return unsafeBitCast(symbol, to: Disclaim.self)
    }()
}

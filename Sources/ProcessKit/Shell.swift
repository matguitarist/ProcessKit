import Foundation

/// One safe way to run a command: stdout and stderr read together so a big output never blocks,
/// stdin from /dev/null unless given, a timeout, and a stop that reaches the whole process group
/// (SIGTERM, then SIGKILL after a grace period) when the task is cancelled.
///
/// `run` returns whatever the exit status; call `check()` on the output to throw on failure:
///
///     let listing = try await Shell.run("/usr/bin/zipinfo", ["-1", zip.path]).check().text
public enum Shell {
    /// Where Homebrew (Apple silicon, then Intel) and MacPorts put programs. An app started from the
    /// Dock has none of them in its PATH, so a bare name is also looked for here.
    public static let standardFolders: [URL] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    /// A PATH with Homebrew's and MacPorts' folders, for a command that starts other tools by name:
    /// `environment: ["PATH": Shell.standardPATH]`.
    public static let standardPATH = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    // MARK: Running

    /// Runs `tool` (a full path, or a bare name looked up in PATH and `standardFolders`) and waits for it
    /// without blocking a thread of Swift's. Returns whatever the exit status; `check()` throws on failure.
    /// Cancelling the task stops the command and throws `CancellationError` (or returns its output with
    /// `returnsOutputWhenCancelled`).
    /// - Parameters:
    ///   - directory: the folder it starts in.
    ///   - environment: variables added to the app's environment.
    ///   - input: bytes for its stdin; nil gives it /dev/null.
    ///   - timeout: past it, the command is stopped and this throws `ShellError.timedOut`.
    public static func run(
        _ tool: String, _ arguments: [String] = [],
        in directory: URL? = nil, environment: [String: String] = [:],
        input: Data? = nil, timeout: Duration? = nil
    ) async throws -> Output {
        try await run(tool, arguments, options: Options(directory: directory, environment: environment,
                                                        input: input.map { .data($0) } ?? .none, timeout: timeout))
    }

    /// `run` with every option.
    public static func run(_ tool: String, _ arguments: [String] = [], options: Options) async throws -> Output {
        try Task.checkCancellation()
        let stop = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Output, any Error>) in
                // A thread of its own: the command may run for minutes, and Swift's threads are few.
                Thread.detachNewThread {
                    continuation.resume(with: Result {
                        try Execution(tool: tool, arguments: arguments, options: options, stop: stop).run()
                    })
                }
            }
        } onCancel: {
            stop.cancel()
        }
    }

    /// Runs the command on the calling thread and waits for it. For code that isn't async; never on the
    /// main thread for anything slow. `options.cancel` stops it from another thread (it then throws
    /// `CancellationError`).
    public static func runSync(
        _ tool: String, _ arguments: [String] = [],
        in directory: URL? = nil, environment: [String: String] = [:],
        input: Data? = nil, timeout: Duration? = nil
    ) throws -> Output {
        try runSync(tool, arguments, options: Options(directory: directory, environment: environment,
                                                      input: input.map { .data($0) } ?? .none, timeout: timeout))
    }

    /// `runSync` with every option.
    public static func runSync(_ tool: String, _ arguments: [String] = [], options: Options) throws -> Output {
        try Execution(tool: tool, arguments: arguments, options: options, stop: CancelFlag()).run()
    }

    /// The command's stdout, line by line as it comes, for a long-running command (a log that follows,
    /// a progress). Ending the loop early or cancelling its task stops the command. The stream finishes
    /// when the command ends well, and throws `ShellError.failed` when it ends with another status
    /// (the error carries the end of stderr, unless stderr is `.merged`). stdout isn't kept in memory.
    public static func lines(_ tool: String, _ arguments: [String] = [], options: Options = Options()) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let stop = CancelFlag()
            continuation.onTermination = { _ in stop.cancel() }
            var streaming = options
            // A stop ends the stream; it never fails it.
            streaming.returnsOutputWhenCancelled = false
            let caller = options.onLine
            streaming.onLine = { line in
                caller?(line)
                continuation.yield(line)
            }
            let final = streaming
            Thread.detachNewThread {
                do {
                    let output = try Execution(tool: tool, arguments: arguments, options: final, stop: stop, keepsStdout: false).run()
                    if output.succeeded || stop.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: ShellError.failed(output))
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Finding a tool

    /// The executable `tool` names: a path as it is when it's an executable file; a bare name looked up in
    /// `path` (the app's PATH by default), then in `standardFolders`. Nil when there is none.
    public static func locate(_ tool: String, path: String? = nil) -> URL? {
        if tool.contains("/") {
            let url = URL(fileURLWithPath: (tool as NSString).expandingTildeInPath)
            return isExecutableFile(url) ? url : nil
        }
        guard !tool.isEmpty else { return nil }
        let searchPath = path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let folders = searchPath.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) } + standardFolders
        return folders.lazy.map { $0.appending(path: tool) }.first(where: isExecutableFile)
    }

    private static func isExecutableFile(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && !isFolder.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }
}

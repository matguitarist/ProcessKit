import Foundation
import os

extension Shell {
    /// Everything about how a command runs besides its tool and arguments.
    public struct Options: Sendable {
        /// The folder the command starts in. Nil: the app's current folder.
        public var directory: URL?
        /// Variables added to the environment, replacing those with the same name.
        public var environment: [String: String]
        /// False starts the command with `environment` alone.
        public var inheritsEnvironment: Bool
        public var input: Input
        public var stdout: Destination
        /// `.merged` sends it into stdout's pipe or file.
        public var stderr: Destination
        /// Past it, the command is stopped and `run` throws `ShellError.timedOut`.
        public var timeout: Duration?
        /// How long a stopped command gets to end after SIGTERM before SIGKILL.
        public var gracePeriod: Duration
        /// The most stdout bytes kept. Past it, the command is stopped and the output is marked `truncated`.
        public var outputLimit: Int?
        /// Keeps only the last this many bytes of stdout and of stderr, without stopping the command: for a
        /// program that runs for hours (a game, an emulator, a server) whose output is read with `onLine`
        /// and only the end of which is wanted in a report.
        public var keepsLast: Int?
        /// A way to stop the command from code that has no task to cancel (`runSync`).
        public var cancel: CancelFlag?
        /// Starts the command as its own responsible process, the way Terminal does: macOS then judges its
        /// network access (Local Network privacy) on its own instead of the app's, so a rebuild of the app
        /// doesn't need permission again. For ssh and the like.
        public var disclaimsResponsibility: Bool
        /// Called with each line of stdout as it comes (and of stderr when it is `.merged`), on a thread of
        /// the command's own. Lines end at \n, \r\n or a lone \r (progress lines); the ending is left out.
        public var onLine: (@Sendable (String) -> Void)?
        /// Where `onLine` and `Shell.lines` end a line: `.any` (\n, \r\n or a lone \r) or `.newline`
        /// (\n or \r\n only, for output whose \r belongs inside a line, like Docker's or brew's progress).
        public var lineBreaks: LineBreaks
        /// Cancelling the task (or `cancel`) still stops the command, but `run` and `runSync` return its
        /// output, with `cancelled` set and the signal that ended it, instead of throwing `CancellationError`.
        public var returnsOutputWhenCancelled: Bool
        /// With stderr `.file(url)`: once the command ends, the end of that file (64 KB at most) is read back
        /// into `Output.stderr`, so `message` and `ShellError.failed` carry it. For `ssh -f`, whose
        /// background master keeps a pipe open.
        public var readsBackStderr: Bool

        public init(
            directory: URL? = nil,
            environment: [String: String] = [:],
            inheritsEnvironment: Bool = true,
            input: Input = .none,
            stdout: Destination = .capture,
            stderr: Destination = .capture,
            timeout: Duration? = nil,
            gracePeriod: Duration = .seconds(3),
            outputLimit: Int? = nil,
            keepsLast: Int? = nil,
            cancel: CancelFlag? = nil,
            disclaimsResponsibility: Bool = false,
            onLine: (@Sendable (String) -> Void)? = nil,
            lineBreaks: LineBreaks = .any,
            returnsOutputWhenCancelled: Bool = false,
            readsBackStderr: Bool = false
        ) {
            self.directory = directory
            self.environment = environment
            self.inheritsEnvironment = inheritsEnvironment
            self.input = input
            self.stdout = stdout
            self.stderr = stderr
            self.timeout = timeout
            self.gracePeriod = gracePeriod
            self.outputLimit = outputLimit
            self.keepsLast = keepsLast
            self.cancel = cancel
            self.disclaimsResponsibility = disclaimsResponsibility
            self.onLine = onLine
            self.lineBreaks = lineBreaks
            self.returnsOutputWhenCancelled = returnsOutputWhenCancelled
            self.readsBackStderr = readsBackStderr
        }
    }

    /// Where a line of output ends.
    public enum LineBreaks: Sendable, Equatable {
        /// \n, \r\n or a lone \r (FFmpeg's and curl's progress lines each become a line).
        case any
        /// \n or \r\n only: a lone \r stays in the line's text.
        case newline
    }

    /// What the command reads.
    public enum Input: Sendable, Equatable {
        /// /dev/null: a command that asks a question gets end of file instead of waiting forever.
        case none
        /// These bytes, then end of file. Written while the output is read, so neither side can block.
        case data(Data)
        case file(URL)
        /// A pipe held open until the command ends or is stopped, when it is closed first. For ssh: the
        /// remote side sees its channel close and ends too.
        case open
    }

    /// Where stdout or stderr goes.
    public enum Destination: Sendable, Equatable {
        /// Kept in `Output.stdout` or `Output.stderr`.
        case capture
        /// /dev/null.
        case discard
        /// Written to a file, created or emptied first. Nothing is held in memory.
        case file(URL)
        /// stderr only: the same pipe or file as stdout.
        case merged
    }

    /// Stops a command from any thread. One flag can stop several commands.
    public final class CancelFlag: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: false)
        public init() {}
        public func cancel() { state.withLock { $0 = true } }
        public var isCancelled: Bool { state.withLock { $0 } }
    }
}

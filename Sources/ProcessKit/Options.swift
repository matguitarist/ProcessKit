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
        /// A way to stop the command from code that has no task to cancel (`runSync`).
        public var cancel: CancelFlag?
        /// Starts the command as its own responsible process, the way Terminal does: macOS then judges its
        /// network access (Local Network privacy) on its own instead of the app's, so a rebuild of the app
        /// doesn't need permission again. For ssh and the like.
        public var disclaimsResponsibility: Bool
        /// Called with each line of stdout as it comes (and of stderr when it is `.merged`), on a thread of
        /// the command's own. Lines end at \n, \r\n or a lone \r (progress lines); the ending is left out.
        public var onLine: (@Sendable (String) -> Void)?

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
            cancel: CancelFlag? = nil,
            disclaimsResponsibility: Bool = false,
            onLine: (@Sendable (String) -> Void)? = nil
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
            self.cancel = cancel
            self.disclaimsResponsibility = disclaimsResponsibility
            self.onLine = onLine
        }
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

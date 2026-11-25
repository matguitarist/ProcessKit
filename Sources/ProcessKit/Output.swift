import Foundation

extension Shell {
    /// What a command did: its exit status and what it wrote.
    public struct Output: Sendable, Equatable {
        /// The program that ran, as a full path.
        public let tool: String
        public let arguments: [String]
        /// The exit code, or 128 + the signal that ended it (143 for SIGTERM), like a shell's `$?`.
        public let status: Int32
        /// The signal that ended the command, if one did.
        public let signal: Int32?
        /// Empty unless stdout was `.capture`.
        public let stdout: Data
        /// Empty unless stderr was `.capture`.
        public let stderr: Data
        /// True when stdout passed `outputLimit` and the command was stopped: `stdout` holds the first bytes.
        public let truncated: Bool
        /// True when the command was stopped by a cancel (`returnsOutputWhenCancelled`, or
        /// `RunningCommand.stop()`): `signal` says how it ended.
        public let cancelled: Bool
        /// True when the command ran past its timeout and was stopped.
        public let timedOut: Bool

        public init(tool: String, arguments: [String], status: Int32, signal: Int32?, stdout: Data, stderr: Data, truncated: Bool,
                    cancelled: Bool = false, timedOut: Bool = false) {
            self.tool = tool
            self.arguments = arguments
            self.status = status
            self.signal = signal
            self.stdout = stdout
            self.stderr = stderr
            self.truncated = truncated
            self.cancelled = cancelled
            self.timedOut = timedOut
        }

        /// stdout as UTF-8 text (bytes that aren't UTF-8 become U+FFFD).
        public var text: String { String(decoding: stdout, as: UTF8.self) }
        /// stderr as UTF-8 text.
        public var errorText: String { String(decoding: stderr, as: UTF8.self) }
        /// stdout split into lines, without their endings or a last empty line.
        public var lines: [String] { lines(breaks: .any) }
        /// stdout split into lines at the given breaks.
        public func lines(breaks: LineBreaks) -> [String] {
            var splitter = LineSplitter(breaks: breaks)
            return splitter.feed(stdout) + (splitter.finish().map { [$0] } ?? [])
        }
        /// Exit status 0.
        public var succeeded: Bool { status == 0 }

        /// Itself when the command succeeded; otherwise throws `ShellError.failed` with this output.
        @discardableResult
        public func check() throws(ShellError) -> Output {
            guard succeeded else { throw .failed(self) }
            return self
        }

        /// The tool's own last words: the end of stderr, or of stdout when stderr is empty.
        public var message: String {
            for text in [errorText, self.text] {
                let lines = text.split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !lines.isEmpty { return lines.suffix(20).joined(separator: "\n") }
            }
            return ""
        }

        /// The tool's file name, for messages ("ditto").
        public var name: String { (tool as NSString).lastPathComponent }
    }
}

/// Why a command didn't run or didn't succeed. Stopping a command by cancelling its task throws
/// `CancellationError` instead.
public enum ShellError: Error, LocalizedError, Sendable, Equatable {
    /// A bare name not found in PATH or the standard folders, or a path that isn't an executable file.
    case notFound(String)
    /// posix_spawn refused it: `code` is the POSIX error (ENOENT for a missing folder, EACCES…).
    case couldNotStart(String, code: Int32)
    /// It ran past its timeout and was stopped. The output holds what it wrote until then.
    case timedOut(Shell.Output)
    /// It ended with a status other than 0 (thrown by `check()` and by `lines`).
    case failed(Shell.Output)

    public var errorDescription: String? {
        switch self {
        case .notFound(let tool):
            "\(tool) isn't installed on this Mac."
        case .couldNotStart(let tool, let code):
            "Couldn't start \((tool as NSString).lastPathComponent): \(String(cString: strerror(code)))."
        case .timedOut(let output):
            "\(output.name) took too long and was stopped."
        case .failed(let output):
            if !output.message.isEmpty { output.message }
            else if let signal = output.signal { "\(output.name) was stopped (signal \(signal))." }
            else { "\(output.name) failed (exit status \(output.status))." }
        }
    }

    /// The output, for `.timedOut` and `.failed`.
    public var output: Shell.Output? {
        switch self {
        case .timedOut(let output), .failed(let output): output
        case .notFound, .couldNotStart: nil
        }
    }
}

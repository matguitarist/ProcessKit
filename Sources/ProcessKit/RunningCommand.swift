import Darwin
import Foundation
import os

extension Shell {
    /// Starts a command that runs on its own, a game or an emulator, and returns at once with a handle:
    /// its pid, whether it's still running, a stop, its stdin to close, and its output once it ends.
    /// Nothing waits for it unless you ask: `onEnd` is called with its output when it ends, on a thread
    /// of the command's own; `wait()` returns that output too.
    ///
    /// The command leads a process group of its own, so `stop()` reaches what it started. A timeout
    /// stops it as `run` does; the output then has `timedOut` set instead of a throw.
    /// - Throws: `ShellError.notFound` or `.couldNotStart` when it can't start, `CancellationError` when
    ///   `options.cancel` is already set. Nothing runs then and `onEnd` isn't called.
    public static func start(
        _ tool: String, _ arguments: [String] = [], options: Options = Options(),
        onEnd: (@Sendable (Output) -> Void)? = nil
    ) throws -> RunningCommand {
        let monitor = Monitor(onEnd: onEnd)
        var execution = Execution(tool: tool, arguments: arguments, options: options, stop: monitor.stop)
        execution.monitor = monitor
        let spawned = try execution.spawn()
        let command = RunningCommand(pid: spawned.pid, tool: spawned.path, arguments: arguments, monitor: monitor)
        let watcher = execution
        // A thread of its own: a game may run for hours.
        Thread.detachNewThread {
            monitor.finish(watcher.watch(spawned).0)
        }
        return command
    }

    /// A command started with `Shell.start`. Safe from any thread. Letting go of it doesn't stop the
    /// command: it is still watched to its end, and `onEnd` still called.
    public final class RunningCommand: Sendable {
        /// Its process id, which also names its process group.
        public let pid: pid_t
        /// The program, as a full path.
        public let tool: String
        public let arguments: [String]
        private let monitor: Monitor

        init(pid: pid_t, tool: String, arguments: [String], monitor: Monitor) {
            self.pid = pid
            self.tool = tool
            self.arguments = arguments
            self.monitor = monitor
        }

        /// False once the command has ended (it may still be finishing its output for a moment).
        public var isRunning: Bool { !monitor.hasExited }

        /// What it did, once it has ended and its output is read; nil before.
        public var output: Output? { monitor.output }

        /// Stops it and everything it started: stdin closes first, then SIGTERM to its process group, and
        /// SIGKILL after `options.gracePeriod`. Its output then has `cancelled` set. Does nothing once it ended.
        public func stop() { monitor.stop.cancel() }

        /// Closes an `.open` stdin, so the command reads end of file, without stopping it.
        public func closeInput() { monitor.requestInputClose() }

        /// Waits until it has ended and returns its output. Cancelling the waiting task doesn't stop the
        /// command: call `stop()`.
        public func wait() async -> Output {
            await withCheckedContinuation { continuation in monitor.whenDone { continuation.resume(returning: $0) } }
        }

        /// Blocks the calling thread until it has ended. Never on the main thread.
        public func waitSync() -> Output {
            let done = DispatchSemaphore(value: 0)
            let result = OSAllocatedUnfairLock<Output?>(initialState: nil)
            monitor.whenDone { output in
                result.withLock { $0 = output }
                done.signal()
            }
            done.wait()
            return result.withLock { $0! }
        }
    }

    /// What a started command's thread and its handle share.
    final class Monitor: Sendable {
        private struct State {
            var exited = false
            var closeInput = false
            var output: Output?
            var waiters: [@Sendable (Output) -> Void] = []
        }
        let stop = CancelFlag()
        private let onEnd: (@Sendable (Output) -> Void)?
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(onEnd: (@Sendable (Output) -> Void)?) { self.onEnd = onEnd }

        var hasExited: Bool { state.withLock { $0.exited } }
        var output: Output? { state.withLock { $0.output } }

        func markExited() { state.withLock { $0.exited = true } }

        func requestInputClose() { state.withLock { $0.closeInput = true } }

        /// True once after `requestInputClose`.
        func takeInputCloseRequest() -> Bool {
            state.withLock { state in
                defer { state.closeInput = false }
                return state.closeInput
            }
        }

        /// Calls `waiter` with the output: now if the command has ended, else when it does.
        func whenDone(_ waiter: @escaping @Sendable (Output) -> Void) {
            let ready: Output? = state.withLock { state in
                if let output = state.output { return output }
                state.waiters.append(waiter)
                return nil
            }
            if let ready { waiter(ready) }
        }

        func finish(_ output: Output) {
            let waiters = state.withLock { state in
                state.exited = true
                state.output = output
                defer { state.waiters = [] }
                return state.waiters
            }
            onEnd?(output)
            for waiter in waiters { waiter(output) }
        }
    }
}

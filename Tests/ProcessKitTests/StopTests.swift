import Foundation
import Testing
@testable import ProcessKit

@Suite struct StopTests {
    @Test func aTimeoutStopsTheCommand() async throws {
        let start = Date()
        do {
            _ = try await Shell.run("/bin/sh", ["-c", "echo begun; sleep 30"], timeout: .milliseconds(300))
            Issue.record("expected a timeout")
        } catch let ShellError.timedOut(output) {
            #expect(output.text == "begun\n")
            #expect(output.signal == SIGTERM)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func cancellingTheTaskStopsTheProcessAndItsChildren() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pids = folder.appending(path: "pids")
        // The shell writes its own id and its child's, then waits.
        let script = "sleep 60 & echo $$ $! > '\(pids.path)'; wait"
        let task = Task { try await Shell.run("/bin/sh", ["-c", script]) }
        #expect(await eventually { ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").hasSuffix("\n") })
        let ids = try String(contentsOf: pids, encoding: .utf8).split(separator: " ")
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        #expect(ids.count == 2)
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
        for pid in ids { #expect(await eventually { !isAlive(pid) }) }
    }

    @Test func aCommandThatIgnoresSIGTERMIsKilledAfterTheGracePeriod() async throws {
        let options = Shell.Options(gracePeriod: .milliseconds(300))
        let start = Date()
        let task = Task { try await Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 1; done"], options: options) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func anAlreadyCancelledTaskStartsNothing() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Shell.run("/bin/echo", ["no"])
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aCancelFlagStopsRunSync() async throws {
        let flag = Shell.CancelFlag()
        let start = Date()
        let finished = Task.detached {
            do {
                _ = try Shell.runSync("/bin/sleep", ["30"], options: Shell.Options(cancel: flag))
                return "ended"
            } catch is CancellationError {
                return "cancelled"
            } catch {
                return "\(error)"
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        flag.cancel()
        #expect(await finished.value == "cancelled")
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func openStdinClosesFirstOnStop() async throws {
        // cat ends on end of file alone: with .open, a stop closes stdin before any signal.
        let task = Task { try await Shell.run("/bin/cat", options: Shell.Options(input: .open)) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

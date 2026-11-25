import Foundation
import Testing
@testable import ProcessKit

@Suite struct StartTests {
    @Test func startReturnsAtOnceAndWaitGivesTheOutput() async throws {
        let command = try Shell.start("/bin/sh", ["-c", "sleep 0.3; echo done; exit 3"])
        #expect(command.pid > 0)
        #expect(command.isRunning)
        #expect(command.output == nil)
        let output = await command.wait()
        #expect(output.status == 3)
        #expect(output.text == "done\n")
        #expect(!output.cancelled)
        #expect(!command.isRunning)
        #expect(command.output == output)
        // Waiting again after the end returns at once.
        #expect(await command.wait() == output)
    }

    @Test func onEndIsCalledWithTheOutput() async throws {
        let ended = OSAllocatedUnfairLockBox<Shell.Output?>(nil)
        _ = try Shell.start("/bin/echo", ["hi"]) { ended.set($0) }
        #expect(await eventually { ended.get() != nil })
        #expect(ended.get()?.text == "hi\n")
    }

    @Test func stopEndsTheCommandAndItsChildren() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pids = folder.appending(path: "pids")
        let command = try Shell.start("/bin/sh", ["-c", "sleep 60 & echo $! > '\(pids.path)'; wait"])
        #expect(await eventually { ((try? String(contentsOf: pids, encoding: .utf8)) ?? "").hasSuffix("\n") })
        let child = try #require(pid_t(String(contentsOf: pids, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let start = Date()
        command.stop()
        let output = await command.wait()
        #expect(output.cancelled)
        #expect(output.signal == SIGTERM)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(await eventually { !isAlive(child) })
        #expect(await eventually { !isAlive(command.pid) })
    }

    @Test func aTimeoutEndsItWithTimedOut() async throws {
        let command = try Shell.start("/bin/sleep", ["30"], options: Shell.Options(timeout: .milliseconds(200)))
        let output = await command.wait()
        #expect(output.timedOut)
        #expect(!output.cancelled)
    }

    @Test func outputToAFileLikeAGameLog() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appending(path: "run.log")
        let options = Shell.Options(directory: folder, stdout: .file(log), stderr: .merged)
        let command = try Shell.start("/bin/sh", ["-c", "pwd -P; echo oops >&2"], options: options)
        let output = command.waitSync()
        #expect(output.succeeded)
        #expect(try String(contentsOf: log, encoding: .utf8) == folder.path + "\noops\n")
    }

    @Test func onLineComesAsItRuns() async throws {
        let lines = OSAllocatedUnfairLockBox<[String]>([])
        let options = Shell.Options(stderr: .merged, onLine: { line in lines.update { $0.append(line) } })
        let command = try Shell.start("/bin/sh", ["-c", "echo one; echo two >&2; sleep 30"], options: options)
        #expect(await eventually { lines.get().count == 2 })
        #expect(lines.get() == ["one", "two"])
        command.stop()
        _ = await command.wait()
    }

    @Test func closeInputLeavesTheCommandRunningToItsEnd() async throws {
        // cat ends on end of file alone, with its own status: no signal.
        let command = try Shell.start("/bin/sh", ["-c", "cat; exit 4"], options: Shell.Options(input: .open))
        try await Task.sleep(for: .milliseconds(200))
        #expect(command.isRunning)
        command.closeInput()
        let output = await command.wait()
        #expect(output.status == 4)
        #expect(output.signal == nil)
        #expect(!output.cancelled)
    }

    @Test func aMissingToolThrowsAtStart() throws {
        #expect(throws: ShellError.notFound("no-such-tool-processkit")) {
            _ = try Shell.start("no-such-tool-processkit")
        }
    }

    @Test func letGoOfTheHandleTheCommandIsStillReaped() async throws {
        let ended = OSAllocatedUnfairLockBox<Bool>(false)
        var pid: pid_t = 0
        do {
            let command = try Shell.start("/bin/sh", ["-c", "sleep 0.2"]) { _ in ended.set(true) }
            pid = command.pid
        }
        #expect(await eventually { ended.get() })
        // Reaped: no zombie left with that id.
        #expect(await eventually { !isAlive(pid) })
    }
}

import Foundation
import Testing
@testable import ProcessKit

@Suite struct RunTests {
    @Test func runsAToolAndReadsItsOutput() async throws {
        let output = try await Shell.run("/bin/echo", ["hello", "world"])
        #expect(output.status == 0)
        #expect(output.succeeded)
        #expect(output.text == "hello world\n")
        #expect(output.lines == ["hello world"])
        #expect(output.tool == "/bin/echo")
        #expect(output.signal == nil)
    }

    @Test func findsABareNameInPATH() async throws {
        let output = try await Shell.run("sh", ["-c", "echo ok"])
        #expect(output.text == "ok\n")
        #expect(Shell.locate("sh")?.path == "/bin/sh")
        #expect(Shell.locate("/bin/sh")?.path == "/bin/sh")
        #expect(Shell.locate("/bin") == nil)
    }

    @Test func aMissingToolThrowsNotFound() async throws {
        await #expect(throws: ShellError.notFound("no-such-tool-processkit")) {
            try await Shell.run("no-such-tool-processkit")
        }
        #expect(throws: ShellError.notFound("/nowhere/tool")) { try Shell.runSync("/nowhere/tool") }
        #expect(ShellError.notFound("magick").localizedDescription == "magick isn't installed on this Mac.")
    }

    @Test func aFailureReturnsUntilChecked() async throws {
        let output = try await Shell.run("/bin/sh", ["-c", "echo partial; echo 'zip error: Nothing to do' >&2; exit 3"])
        #expect(output.status == 3)
        #expect(!output.succeeded)
        #expect(output.text == "partial\n")
        #expect(output.errorText == "zip error: Nothing to do\n")
        #expect(throws: ShellError.failed(output)) { try output.check() }
        do {
            try output.check()
        } catch {
            #expect(error.localizedDescription == "zip error: Nothing to do")
            #expect(error.output?.status == 3)
        }
    }

    @Test func aFailureWithoutWordsSaysItsStatus() async throws {
        let output = try await Shell.run("/usr/bin/false")
        #expect(output.status == 1)
        #expect(ShellError.failed(output).localizedDescription == "false failed (exit status 1).")
    }

    @Test func checkChainsOnSuccess() async throws {
        let text = try await Shell.run("/bin/echo", ["x"]).check().text
        #expect(text == "x\n")
    }

    @Test func aSignalEndsWith128PlusIt() async throws {
        let output = try await Shell.run("/bin/sh", ["-c", "kill -TERM $$"])
        #expect(output.status == 143)
        #expect(output.signal == SIGTERM)
        #expect(ShellError.failed(output).localizedDescription == "sh was stopped (signal 15).")
    }

    @Test func runsInAFolderWithAddedVariables() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = try await Shell.run("/bin/sh", ["-c", "pwd -P; echo \"$KIT_TEST\"; echo \"$HOME\""],
                                         in: folder, environment: ["KIT_TEST": "a b"])
        let lines = output.lines
        #expect(lines[0] == folder.path)
        #expect(lines[1] == "a b")
        #expect(lines[2] == ProcessInfo.processInfo.environment["HOME"])
    }

    @Test func aCleanEnvironmentHasOnlyWhatIsGiven() async throws {
        let options = Shell.Options(environment: ["ONLY": "1"], inheritsEnvironment: false)
        let output = try await Shell.run("/usr/bin/env", options: options)
        #expect(output.lines == ["ONLY=1"])
    }

    @Test func aMissingFolderCantStart() async throws {
        await #expect(throws: ShellError.couldNotStart("/bin/echo", code: ENOENT)) {
            try await Shell.run("/bin/echo", in: URL(fileURLWithPath: "/nowhere-processkit"))
        }
    }

    @Test func stdinIsEmptyByDefault() async throws {
        // cat would wait forever on a terminal; with /dev/null it ends at once.
        let output = try await Shell.run("/bin/cat", timeout: .seconds(5))
        #expect(output.stdout.isEmpty)
    }

    @Test func megabytesOnBothStreamsNeverBlock() async throws {
        // A naive reader that drains stdout first blocks once stderr's pipe (64 KB) is full.
        let size = 8 * 1024 * 1024
        let script = "head -c \(size) /dev/zero >&2; head -c \(size) /dev/zero; head -c \(size) /dev/zero >&2"
        let output = try await Shell.run("/bin/sh", ["-c", script], timeout: .seconds(60))
        #expect(output.stdout.count == size)
        #expect(output.stderr.count == 2 * size)
    }

    @Test func megabytesInAndOutNeverBlock() async throws {
        // cat writes back while it reads: stdin and stdout must move together.
        let input = Data((0..<(6 * 1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let output = try await Shell.run("/bin/cat", input: input, timeout: .seconds(60))
        #expect(output.stdout == input)
    }

    @Test func inputACommandDoesntReadIsDropped() async throws {
        let input = Data(count: 4 * 1024 * 1024)
        let output = try await Shell.run("/bin/echo", ["done"], input: input, timeout: .seconds(10))
        #expect(output.text == "done\n")
    }

    @Test func inputFromAFile() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "in.txt")
        try Data("from a file\n".utf8).write(to: file)
        let output = try await Shell.run("/bin/cat", options: Shell.Options(input: .file(file)))
        #expect(output.text == "from a file\n")
    }

    @Test func outputToAFileAndMergedErrors() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "out.txt")
        let options = Shell.Options(stdout: .file(file), stderr: .merged)
        let output = try await Shell.run("/bin/sh", ["-c", "echo one; echo two >&2"], options: options)
        #expect(output.stdout.isEmpty && output.stderr.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\ntwo\n")
    }

    @Test func mergedErrorsArriveInStdout() async throws {
        let output = try await Shell.run("/bin/sh", ["-c", "echo one; echo two >&2"], options: Shell.Options(stderr: .merged))
        #expect(output.text == "one\ntwo\n")
        #expect(output.stderr.isEmpty)
    }

    @Test func discardedOutputIsNotKept() async throws {
        let output = try await Shell.run("/bin/sh", ["-c", "echo one; echo two >&2; exit 4"],
                                         options: Shell.Options(stdout: .discard, stderr: .discard))
        #expect(output.status == 4)
        #expect(output.stdout.isEmpty && output.stderr.isEmpty)
    }

    @Test func anOutputLimitStopsTheCommand() async throws {
        let start = Date()
        let output = try await Shell.run("/usr/bin/yes", options: Shell.Options(outputLimit: 1000))
        #expect(output.truncated)
        #expect(output.stdout.count == 1000)
        #expect(Date().timeIntervalSince(start) < 5)
        // Under the limit: whole and not truncated.
        let small = try await Shell.run("/bin/echo", ["hi"], options: Shell.Options(outputLimit: 1000))
        #expect(!small.truncated && small.text == "hi\n")
    }

    @Test func linesAsTheyCome() async throws {
        let collected = Collected()
        let options = Shell.Options(onLine: { collected.add($0) })
        let output = try await Shell.run("/usr/bin/printf", ["a\\nb\\r\\nprogress 1\\rprogress 2\\rend"], options: options)
        #expect(collected.lines == ["a", "b", "progress 1", "progress 2", "end"])
        #expect(output.text == "a\nb\r\nprogress 1\rprogress 2\rend")
    }

    @Test func aProgramLeftRunningDoesntHoldTheResult() async throws {
        // The background sleep keeps stdout's pipe open; ssh -f and daemons do the same.
        let start = Date()
        let output = try await Shell.run("/bin/sh", ["-c", "sleep 20 & echo started"], timeout: .seconds(15))
        #expect(output.text == "started\n")
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func runsSideBySide() async throws {
        let texts = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<24 {
                group.addTask { try await Shell.run("/bin/echo", ["\(index)"]).check().text }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(texts == Set((0..<24).map { "\($0)\n" }))
    }

    @Test func disclaimedCommandsRun() async throws {
        let output = try await Shell.run("/bin/echo", ["free"], options: Shell.Options(disclaimsResponsibility: true))
        #expect(output.text == "free\n")
    }

    @Test func runSyncBlocksAndReturns() throws {
        let output = try Shell.runSync("/bin/sh", ["-c", "echo sync; exit 2"])
        #expect(output.text == "sync\n")
        #expect(output.status == 2)
    }
}

final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.withLock { stored.append(line) } }
    var lines: [String] { lock.withLock { stored } }
}

import Foundation
import Testing
@testable import ProcessKit

@Suite struct OptionTests {
    // MARK: Line breaks

    @Test func newlineBreaksKeepALoneCarriageReturnInTheLine() {
        var splitter = LineSplitter(breaks: .newline)
        #expect(splitter.feed(Data("pull 10%\rpull 50%\npush\r".utf8)) == ["pull 10%\rpull 50%"])
        #expect(splitter.feed(Data("\nlast\r".utf8)) == ["push"])
        #expect(splitter.finish() == "last")
    }

    @Test func anyBreaksStillSplitAtALoneCarriageReturn() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("a\rb\r\nc\n".utf8)) == ["a", "b", "c"])
    }

    @Test func linesFollowTheOption() async throws {
        var lines: [String] = []
        let options = Shell.Options(lineBreaks: .newline)
        for try await line in Shell.lines("/usr/bin/printf", ["a\\rb\\r\\nc\\n"], options: options) { lines.append(line) }
        #expect(lines == ["a\rb", "c"])
        let output = try await Shell.run("/usr/bin/printf", ["a\\rb\\nc"])
        #expect(output.lines(breaks: .newline) == ["a\rb", "c"])
        #expect(output.lines == ["a", "b", "c"])
    }

    // MARK: Output of a cancelled run

    @Test func aCancelledRunCanReturnItsOutput() async throws {
        let options = Shell.Options(returnsOutputWhenCancelled: true)
        let task = Task { try await Shell.run("/bin/sh", ["-c", "echo begun; sleep 30"], options: options) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let output = try await task.value
        #expect(output.cancelled)
        #expect(output.signal == SIGTERM)
        #expect(output.status == 128 + SIGTERM)
        #expect(output.text == "begun\n")
    }

    @Test func aCancelFlagRunSyncCanReturnItsOutput() async throws {
        let flag = Shell.CancelFlag()
        let finished = Task.detached {
            try Shell.runSync("/bin/sleep", ["30"], options: Shell.Options(cancel: flag, returnsOutputWhenCancelled: true))
        }
        try await Task.sleep(for: .milliseconds(200))
        flag.cancel()
        let output = try await finished.value
        #expect(output.cancelled)
        #expect(output.signal == SIGTERM)
    }

    @Test func withoutTheOptionCancellingStillThrows() async throws {
        let task = Task { try await Shell.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func aTimeoutMarksTheOutput() async throws {
        do {
            _ = try await Shell.run("/bin/sleep", ["30"], timeout: .milliseconds(200))
            Issue.record("expected a timeout")
        } catch let ShellError.timedOut(output) {
            #expect(output.timedOut)
            #expect(!output.cancelled)
        }
    }

    // MARK: stderr read back from a file

    @Test func aStderrFileIsReadBackIntoTheOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let errors = folder.appending(path: "errors.txt")
        let options = Shell.Options(stdout: .discard, stderr: .file(errors), readsBackStderr: true)
        let output = try await Shell.run("/bin/sh", ["-c", "echo 'ssh: Could not resolve hostname' >&2; exit 255"], options: options)
        #expect(output.status == 255)
        #expect(output.message == "ssh: Could not resolve hostname")
        #expect(ShellError.failed(output).localizedDescription == "ssh: Could not resolve hostname")
    }

    @Test func aBigStderrFileKeepsItsEnd() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let errors = folder.appending(path: "errors.txt")
        let options = Shell.Options(stderr: .file(errors), readsBackStderr: true)
        let output = try await Shell.run("/bin/sh", ["-c", "head -c 200000 /dev/zero | tr '\\0' x >&2; echo; echo last words >&2"], options: options)
        #expect(output.stderr.count == Execution.stderrTail)
        #expect(output.errorText.hasSuffix("last words\n"))
    }

    @Test func withoutTheOptionAStderrFileStaysOutOfTheOutput() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let errors = folder.appending(path: "errors.txt")
        let output = try await Shell.run("/bin/sh", ["-c", "echo no >&2"], options: Shell.Options(stderr: .file(errors)))
        #expect(output.stderr.isEmpty)
    }
}

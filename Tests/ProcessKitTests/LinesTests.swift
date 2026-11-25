import Foundation
import Testing
@testable import ProcessKit

@Suite struct LinesTests {
    @Test func streamsLinesAndFinishes() async throws {
        var lines: [String] = []
        for try await line in Shell.lines("/usr/bin/printf", ["one\\ntwo\\r\\nthree"]) { lines.append(line) }
        #expect(lines == ["one", "two", "three"])
    }

    @Test func aFailureThrowsAfterTheLines() async throws {
        var lines: [String] = []
        do {
            for try await line in Shell.lines("/bin/sh", ["-c", "echo first; echo 'it broke' >&2; exit 2"]) { lines.append(line) }
            Issue.record("expected a failure")
        } catch let ShellError.failed(output) {
            #expect(output.status == 2)
            #expect(output.message == "it broke")
            #expect(output.stdout.isEmpty)
        }
        #expect(lines == ["first"])
    }

    @Test func mergedErrorsAreLinesToo() async throws {
        var lines: [String] = []
        for try await line in Shell.lines("/bin/sh", ["-c", "echo out; echo err >&2"], options: Shell.Options(stderr: .merged)) {
            lines.append(line)
        }
        #expect(lines == ["out", "err"])
    }

    @Test func leavingTheLoopStopsTheCommand() async throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appending(path: "pid")
        var count = 0
        for try await _ in Shell.lines("/bin/sh", ["-c", "echo $$ > '\(pidFile.path)'; exec yes"]) {
            count += 1
            if count == 3 { break }
        }
        #expect(count == 3)
        let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await eventually { !isAlive(pid) })
    }

    @Test func cancellingTheTaskEndsTheStream() async throws {
        let task = Task {
            var count = 0
            for try await _ in Shell.lines("/bin/sh", ["-c", "while :; do echo tick; sleep 0.05; done"]) { count += 1 }
            return count
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let count = try await task.value
        #expect(count > 0)
    }

    @Test func aMissingToolThrows() async throws {
        await #expect(throws: ShellError.notFound("no-such-tool-processkit")) {
            for try await _ in Shell.lines("no-such-tool-processkit") {}
        }
    }
}

@Suite struct LineSplitterTests {
    @Test func splitsEveryKindOfEnding() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("a\nb\r\nc\rd".utf8)) == ["a", "b", "c"])
        #expect(splitter.finish() == "d")
    }

    @Test func aCRLFSplitAcrossReadsCountsOnce() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("one\r".utf8)) == [])
        #expect(splitter.feed(Data("\ntwo\n".utf8)) == ["one", "two"])
        #expect(splitter.finish() == nil)
    }

    @Test func emptyLinesStay() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("\n\nx\n".utf8)) == ["", "", "x"])
    }

    @Test func aCharacterSplitAcrossReadsIsWhole() {
        var splitter = LineSplitter()
        let bytes = Array("é\n".utf8)
        #expect(splitter.feed(Data(bytes[0..<1])) == [])
        #expect(splitter.feed(Data(bytes[1...])) == ["é"])
    }
}

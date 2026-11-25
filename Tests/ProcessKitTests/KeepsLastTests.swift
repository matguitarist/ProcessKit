import Foundation
import Testing
import ProcessKit

@Suite struct KeepsLastTests {
    @Test func aLongRunningCommandKeepsOnlyTheEndOfItsOutputAndIsNotStopped() async throws {
        let lines = OSAllocatedUnfairLockBox(0)
        var options = Shell.Options(keepsLast: 1000, onLine: { _ in lines.update { $0 += 1 } })
        options.stderr = .capture
        // About 2 MB on stdout and 200 KB on stderr, then a last line.
        let output = try await Shell.run("/bin/sh", ["-c", "i=0; while [ $i -lt 20000 ]; do echo \"line $i of some length to fill up the output\"; i=$((i+1)); done; yes err | head -c 200000 >&2; echo last"], options: options)
        #expect(output.succeeded)
        #expect(!output.truncated)
        #expect(output.stdout.count <= 1000 && output.stderr.count <= 1000)
        #expect(output.text.hasSuffix("last\n"))
        #expect(lines.get() == 20001)
    }
}

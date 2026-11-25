import Foundation
import os

/// A value tests share with a callback on another thread.
final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let lock: OSAllocatedUnfairLock<Value>
    init(_ value: Value) { lock = OSAllocatedUnfairLock(initialState: value) }
    func get() -> Value { lock.withLock { $0 } }
    func set(_ value: Value) { lock.withLock { $0 = value } }
    func update(_ change: @Sendable (inout Value) -> Void) { lock.withLock { change(&$0) } }
}

/// A new empty folder under the temporary directory, removed by the caller's `defer`.
func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "ProcessKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    // The real path (/private/var/…), as `pwd -P` gives it.
    guard let real = realpath(url.path, nil) else { return url }
    let path = String(cString: real)
    free(real)
    return URL(fileURLWithPath: path, isDirectory: true)
}

/// Whether a process with this id is still there.
func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// Waits up to `seconds` for `condition`.
func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

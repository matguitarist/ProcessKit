# ProcessKit

How my Mac apps run a command: stdout and stderr read together, stdin closed unless given, a timeout, and a stop
that reaches the whole process group. Shared by the apps that start tools (RenChan, Kamiro, Starseed, the
launchers, Tadpole, Attic, SiliconScope, Porthole, Outpost) and by ArchiveKit. A change here reaches every app at
its next package update, so keep the API stable and additive.

Shared rules for how every project is laid out and named:
@~/.claude/project-layout.md

## Layout

- `Sources/ProcessKit/` Foundation and Darwin only, macOS only:
  - `Shell.swift`: `run`, `runSync`, `lines`, `locate`, `standardFolders`, `standardPATH`.
  - `RunningCommand.swift`: `start` and its handle (`pid`, `isRunning`, `stop`, `closeInput`, `wait`, `onEnd`).
  - `Options.swift`: `Shell.Options`, `Input`, `Destination`, `LineBreaks`, `CancelFlag`.
  - `Output.swift`: `Shell.Output` and `ShellError`.
  - `Execution.swift`: posix_spawn and the one poll() loop that reads, writes, and watches the end, the
    timeout and a stop.
  - `LineSplitter.swift`: lines at \n, \r\n and a lone \r (or \n and \r\n only).
- `Tests/ProcessKitTests/` Swift Testing, with real commands (/bin/sh, cat, yes, head).

## Rules

- Everything is safe from any thread and does no I/O on the main thread by itself. `run` and `lines` wait on a
  thread of their own; `runSync` blocks its caller.
- Never read one pipe to its end before the other: everything goes through the poll() loop.
- Every descriptor ProcessKit opens is close-on-exec and has no SIGPIPE; the child gets only fds 0, 1 and 2.
- Temp files in tests only under `FileManager.default.temporaryDirectory`.
- Add a test for every change. `swift build && swift test` pass with no warnings, then CI on macOS.
- Release: tag `x.y.z` and push the tag; apps use `from:`.

## Git

Commit after each working change, with a message that says what an app can now do.

# ProcessKit

One safe way for my Mac apps to run a command. It gathers what each app wrote on its own: RenChan's `Command`,
Kamiro's tool runs with a stop button, Starseed's and the launchers' `Process` calls, SiliconScope's line-by-line
installer output, and Porthole's and Outpost's `posix_spawn` for ssh.

- stdout and stderr are read together, and stdin is written while they are: a command that writes megabytes to
  both never blocks.
- stdin is /dev/null unless you give bytes, a file or an open pipe: a tool that asks a question gets end of file.
- Cancelling the task stops the command and everything it started (its process group): SIGTERM, then SIGKILL after
  a grace period.
- A timeout, an output limit, output to a file, stderr merged into stdout.
- A bare name is found in PATH, then in Homebrew's and MacPorts' folders, which an app started from the Dock lacks.
- A program the command leaves running in the background (`ssh -f`, a daemon) can't hold the result.
- `disclaimsResponsibility` starts a command the way Terminal does, so macOS judges ssh's network access on its own.

macOS 14 or later. Mac only: iOS doesn't let apps start programs.

## Add it to an app

SwiftPM (`Package.swift`):

```swift
.package(url: "https://github.com/matguitarist/ProcessKit", from: "0.1.0"),
// in the target that runs commands:
.product(name: "ProcessKit", package: "ProcessKit"),
```

XcodeGen (`project.yml`):

```yaml
packages:
  ProcessKit:
    url: https://github.com/matguitarist/ProcessKit
    from: 0.1.0
targets:
  App:
    dependencies:
      - package: ProcessKit
```

## Run a command

```swift
import ProcessKit

// Whatever its exit status: look at it yourself.
let output = try await Shell.run("/usr/bin/zipinfo", ["-1", zip.path])
if output.succeeded { names = output.lines }

// Or throw ShellError.failed, whose message is the tool's last words on stderr.
let listing = try await Shell.run("/usr/bin/zipinfo", ["-1", zip.path]).check().text

// A folder, added variables, bytes for stdin, a timeout (throws ShellError.timedOut).
try await Shell.run("/usr/bin/zip", ["-qr", backup.path, "Saves"], in: root).check()
let version = try? await Shell.run("ffmpeg", ["-version"], timeout: .seconds(5)).check().text
let echoed = try await Shell.run("/bin/cat", input: Data("hello".utf8)).text
```

`run` waits on a thread of its own, never one of Swift's. Cancel its task to stop the command: it throws
`CancellationError` once the command is gone.

Errors: `ShellError.notFound` (no such tool), `.couldNotStart` (posix_spawn refused, a missing folder),
`.timedOut(output)`, `.failed(output)` (from `check()` and `lines`). Every case has a sentence in
`localizedDescription`; `error.output` holds what the command wrote.

The output: `status` (the exit code, or 128 + the signal, like `$?`), `signal`, `stdout` and `stderr` as
`Data`, `text`, `errorText`, `lines`, `message` (the end of stderr, else stdout), `succeeded`, `truncated`.

## Every option

```swift
var options = Shell.Options()
options.directory = folder
options.environment = ["PATH": Shell.standardPATH]  // added to the app's; inheritsEnvironment = false for only these
options.input = .data(bytes)          // .none (/dev/null), .file(url), .open (closed first when stopped)
options.stdout = .file(target)        // .capture, .discard, .file(url)
options.stderr = .merged              // .capture, .discard, .file(url), .merged into stdout
options.timeout = .seconds(30)
options.gracePeriod = .seconds(3)     // between SIGTERM and SIGKILL
options.outputLimit = 8 << 20         // stdout past it: stopped, output.truncated, the first bytes kept
options.cancel = flag                 // a Shell.CancelFlag, for code without a task to cancel
options.disclaimsResponsibility = true
options.onLine = { line in progress.read(line) }  // stdout lines as they come, on the command's thread
let output = try await Shell.run("/usr/local/bin/ffmpeg", arguments, options: options)
```

Lines end at `\n`, `\r\n` or a lone `\r` (FFmpeg's and curl's progress lines), without the ending.

## Follow a long command

```swift
for try await line in Shell.lines("/usr/bin/ssh", arguments, options: Shell.Options(input: .open, stderr: .merged)) {
    show(line)
}
```

Leaving the loop or cancelling the task stops the command (with `.open`, stdin closes first, so ssh's remote side
ends too). The stream finishes when the command ends well and throws `ShellError.failed` otherwise. stdout isn't
kept in memory.

## From code that isn't async

```swift
let output = try Shell.runSync("/usr/bin/ditto", ["-x", "-k", zip.path, folder.path])
let flag = Shell.CancelFlag()       // flag.cancel() from another thread stops it
try Shell.runSync("/usr/bin/tar", ["-xf", archive.path], options: Shell.Options(cancel: flag))
```

It blocks the calling thread: never the main thread for anything slow.

## Find a tool

```swift
Shell.locate("cwebp")       // /opt/homebrew/bin/cwebp, or nil
Shell.standardFolders       // Homebrew (Apple silicon, Intel) and MacPorts
```

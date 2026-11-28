# Processes

`std.process` starts programs, writes their input, reads what they write and waits for them to exit. Every failure the
program can meet is a `ProcessError` in a `Result`: a program that is not there, a working directory that is missing, a
child that stopped reading its input, a wait that ran out of time.

```haxe
import std.process.Command;

function branch(repository:String):Result<String, std.process.ProcessError> {
	var output = try new Command("git").args(["branch", "--show-current"]).directory(repository).output();
	return Ok(StringTools.trim(output.stdoutText()));
}
```

The program is found as the system finds it: a path, or a name looked up on the `PATH`. Its arguments reach it exactly
as given, each as one argument, with no shell in between, so they need no quoting. `Command.shell(line)` runs a command
line through the system's shell instead (`/bin/sh -c`, or `cmd.exe /d /s /c` on Windows), for pipes and redirections.
`std.process` is not available on the Wasm targets: importing it there is a compile error.

## Commands

A `Command` is set up before it runs, and can be run any number of times:

| Method | Sets |
| --- | --- |
| `arg(value)`, `args(values)` | the next arguments |
| `directory(path)` | the working directory; `DirectoryNotFound` when it is not one |
| `env(name, value)`, `removeEnv(name)`, `clearEnv()` | the environment, over what the program inherits |
| `stdin(stdio)`, `stdout(stdio)`, `stderr(stdio)` | each stream: `Pipe`, `Inherit` (this program's) or `Discard` |
| `detached()` | lets the program outlive its `Child` and this process |
| `group()` | a process group of its own on POSIX, so stopping it stops what it started too |

Three ways to run it:

| Method | Runs | Streams not set otherwise |
| --- | --- | --- |
| `spawn()` | starts it and answers the `Child` | inherited |
| `output(timeout)` | to its end, answering a `ProcessOutput`: the exit status and all it wrote | output and error piped, input empty |
| `status(timeout)` | to its end, answering the `ExitStatus` | inherited |

An `ExitStatus` is `Exited(code)` or, on POSIX, `Signaled(signal)`; `succeeded()` is `Exited(0)`.

## Children

A `Child` has its piped streams as `stdin` (a `ChildInput`), `stdout` and `stderr` (`ChildOutput`s), each null when the
stream is inherited or discarded.

- `stdout` and `stderr` are `Reader`s ([Streams](IO.md)): `read(buffer, offset, length)` answers how many bytes it
  read, waiting as long as it takes, and 0 at the stream's end; `readAll()` and `readText()` read to the end.
  `readWithin(timeout, buffer, offset, length)` gives up with `TimedOut` instead; a timeout of 0 reads only what is
  there. `stdin` is a `Writer`.
- `stdin.write(buffer)` gives the child every byte, waiting while the pipe is full; `InputClosed` when the child no
  longer reads. `close()` lets the child read its end.
- `wait(timeout)` closes the child's input and waits for it to exit; `exitStatus()` asks without waiting.
  `waitForOutput(timeout)` reads both piped outputs as they come, so a child filling one never stalls on the other.
- `terminate()` asks the child to stop (SIGTERM, which it may handle); `kill()` ends it at once. On Windows both end the
  child and what it started.

A child belongs to its `Child`: `close()`, a `scoped` binding or the collector ends it if it still runs, with its
group, and reaps it, so no process outlives its owner by accident. A `detached` child is left running.

## This process

`Environment` answers for the program itself: `arguments()`, `variable(name)`, `variables()`, `setVariable` and
`removeVariable` (which the children it starts afterwards inherit), `executablePath()`, `programPath()`, `id()` and
`exit(code)`. The working directory is `std.fs.Files.workingDirectory()`, set with `Files.setWorkingDirectory(path)`.

## Haxe's API

`sys.io.Process` is Haxe's interface over `std.process`. It differs from Haxe's in two places: `close()` ends a child
that still runs, as a `Child` does, and arguments on Windows are quoted for the program's C runtime, not escaped for
`cmd.exe`.

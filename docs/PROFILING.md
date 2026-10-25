# Profiling

Profiling workflows for compiler and host applications. `PROFILER.md` covers the
design: the record format, the buffers, the protocol and the capture format.
This document covers how to use the profiler.

## Sources

A session combines sources. `--profile` takes a comma-separated list:

| Source | What it records |
| --- | --- |
| `sampling` | Stack samples at a fixed rate (`--rate`). |
| `alloc` | Allocation samples, one per N allocations on each thread. |
| `instrument` | Enter and exit of every instrumented function. Needs the instrumented build, which `haxeon run` makes (see Instrumentation). |

Without a list, `haxeon run --profile` records `instrument`. `hlprof-live`
records `sampling` unless told otherwise. Spans, counters, frame marks, GC
statistics, thread names and module loads are always recorded while a session
runs, whatever the sources.

## Host applications

`haxeon run --profile[=LIST]` builds the project, launches it with
`--diagnostics-wait`, attaches `hlprof-live`, writes an HLPC capture (default
`build/host/profile/profile-<timestamp>/profile.hlpc`), exports it as a native
Perfetto trace (`profile.pftrace` next to the capture), and prints a
top-functions report after the process exits. The export writes its output to
`export.log` in the capture directory and is stopped after 20 minutes, so a
stuck export cannot hold the run. Open the `.pftrace` at
https://ui.perfetto.dev. Pass `--profile-output PATH` to choose the capture
location, and runtime arguments after `--`:

```sh
haxeon run --profile=sampling --profile-output build/host/profile/editor.hlpc
```

`--profile` also works with `--watch` and `--watch --live`. Each launch of the
watched app gets its own capture directory under the profile root (or under
`--profile-output`, which is then a directory), finished when that launch exits
or is relaunched after an edit. Live patches stay inside one capture: the trace
shows a `live.patch` (or `live.reload`) slice at the patch, a "module loaded" or
"module revision" instant, and JIT frames named `[hashlink-jit m<module> r<revision>]`,
so samples before and after a patch are attributed to the code that actually ran.
A live module calls each function through a small entry stub; a sample that
stops in one shows as `<function> [entry]` in `[hashlink-jit-entries m<module>]`.
In exosuit, `python scripts/run.py [--watch|--live] --profile` forwards the flag.

## What a trace contains

- **Frames.** A "Frames" track with one slice per frame, named `Frame N`, from
  the `haxeon.ProfileFrame` marks (see below). A trace without marks has no
  such track. When recording starts with the program (`--diagnostics-wait`,
  which `haxeon run --profile` uses), a `Startup` slice covers everything
  before the first frame.
- **Startup.** A session that starts before the program's entry point also
  records the runtime's own startup, from `main` on: initializing the
  runtime, loading the bytecode, compiling and linking the module (the JIT
  and the native libraries it loads), starting diagnostics and waiting for
  the profiler. The phases are slices on the main thread under `Startup`,
  followed by the program's entry point, so the Perfetto trace starts at
  HashLink's `main` rather than at the entry point.
- **Thread order.** The main thread comes first, shown as `main (thread N)`
  (Perfetto puts a process's main thread first only when its tid is the
  process id, so the trace gives it that tid and keeps the real one in the
  name). The other threads follow by tid.
- **Spans.** Slices from `haxeon.ProfileSpan`, nested on the thread that
  emitted them.
- **Counters.** HashLink GC counters (heap, allocated bytes, collections, mark
  time and allocation rate), "Short calls dropped per frame" when short calls
  are dropped (see below), app counters from
  `haxeon.ProfileCounter.set(name, value)`, and, with `alloc`, an estimate of
  the bytes allocated.
- **Samples.** Stack samples (`--rate`, default 1000 Hz) with Haxe frames named
  `Class.method` with file and line. A sample taken while the world was
  stopped for a GC also gets a "GC stop sample" instant.
- **Frames as flame graphs.** "Main thread frames", under the main thread
  with "Frames", shows the main thread one frame at a time: each frame (from one
  `ProfileFrame.mark()` to the next) is a root slice named `Frame N`, and each
  stretch between `ProfileFrame.idle()` and the next mark is an `Idle` root.
  Under each root is that frame's call stack over time, Haxe and native mixed.
  The stack is cut at every frame boundary, so no slice spans two frames.
- **Call stacks over time.** Every other thread has a call-stack track,
  named after the thread, under its thread track with the same layout,
  without frame roots. Threads show by name (see Thread names below); a
  thread nothing named, in a session that began before the program (as
  `run --profile` does), is named after its entry function
  (`WorkerPool::worker_loop`), and the C++ runtime's thread-start wrapper
  (`std::thread::_Invoke<...>`) is left out, so the entry function is the
  track's root. A
  function that stays on the stack across consecutive samples is one slice.
  Boundaries are as
  precise as the sampling interval, calls shorter than it appear only when a
  sample lands in them, and a thread not sampled for three intervals ends its
  slices. Perfetto's aggregate flame graph of a selected area still uses the
  samples themselves.
- **Mixed-mode stacks** on Windows x64: samples walk through native code with
  the unwind data of each module and of the JIT, so a stack shows Haxe calling
  into a native library and back into Haxe callbacks. A native frame belongs to
  its module's mapping and is named by its function, with file and line when
  the module has a PDB. Without a PDB it is named after the nearest export,
  `module!export+0x...`, and an address outside every known module is named
  `[unknown 0x...]`. Other platforms record Haxe frames and stop at the first
  native frame.
- **Profiler stalls.** A "profiler stall" slice on a thread that had to wait
  for the recorder to free a buffer. The profiler drops nothing the program
  records, so a stall delays the program instead. Raise `--pool` if stalls
  appear. A stalled thread counts as blocked for the GC, so a program that
  keeps the pool full runs slower but finishes. (The runtime's own threads
  that must not wait, such as the consumer and a collection holding the GC
  lock, record no calls; if their other records find no buffer, the recorder
  warns that records were lost.)
- **Instants** for module loads and live module revisions.
- **Instrumented calls.** A slice per call with its exact enter and exit
  times, Haxe and native mixed, on "Main thread frames" for the main thread
  and on the call-stack track of every other thread, where they replace the
  stack built from samples.

MSVC Release builds of HashLink and the Haxeon runtime write PDBs next to the
binaries so the profiler and debuggers can name their functions.

### Frames

`haxeon.ProfileFrame.mark()` starts a frame and ends the one before it.
`haxeon.ProfileFrame.idle()` ends the current frame without starting another,
so time spent waiting for work is not counted as a frame. Both take a frame
set (default 0); the trace shows set 0 as the "Frames" track. Sets 1 to 15 get
tracks of their own, and sets above 15 are ignored. The desktop UI host marks
a frame when it starts rendering one and marks idle when no event or frame is
pending, so a UI app has the track without any code. Other programs call `mark()` once per iteration of
their main loop. Like spans, the calls skip their work when nothing is
recording.

The desktop UI host also marks each pump step's event wait and dispatch with
`ui.events`, which contains the `ui.frame` of any frame the events trigger.
`ui.frame` contains `ui.prepare`, `ui.submit`, `ui.render` and `ui.frame.gc`.
The exosuit editor also records the `ui.frame.allocated_bytes` counter.
`ProfileSpan` and `ProfileCounter` skip their work when nothing is recording,
so they can stay in shipped code.

### Thread names

A trace shows each thread by name, so every thread a program starts should
have one that says what it does. Start Haxe threads with
`haxeon.Threads.create(name, call)` (or call `haxeon.Threads.nameCurrent(name)`
first thing in the thread), and name native threads with the system call
(`SetThreadDescription`, `pthread_setname_np`); NativeKit names its own
(`nk.render`, `nk.task.N`, `nk.worker.N`, `nk.local <pipe>`, `nk.pty.N.read`,
`nk.net.request`, ...). Debuggers and crash dumps show the same names. Linux
keeps a name's first 15 bytes, so put what tells threads apart first.

The recorder takes a thread's name from the runtime (a Haxe thread's name is
recorded the moment it is set, so it holds even if the thread exits soon
after) or else from the system, which it reads every half second while
recording. A thread that has no name by the end is named after its entry
function, when the session began before the program and recorded the thread's
first call (see [What a trace contains](#what-a-trace-contains)); otherwise it
keeps its tid. A Windows thread description longer than 127 bytes is cut at a
whole character, and on macOS a thread that names itself also gets the system
name.

To check a trace without opening the UI, `scripts/check-pftrace.py` runs
queries through Perfetto's `trace_processor_shell` (download it from the
Perfetto releases):

```sh
python3 scripts/check-pftrace.py --tp trace_processor_shell \
  --expect-process Main --expect-thread main --expect-slice ui.frame \
  --expect-counter ui.frame.allocated_bytes --min-samples 1000 \
  build/host/profile/profile-<timestamp>/profile.pftrace
```

On Windows x64, add `--expect-mixed` to require stacks that pass from Haxe
through native code and back into Haxe; other platforms do not record them.

## Instrumentation

With `instrument` among the sources, `haxeon run --profile` builds the
instrumented flavor into its own directory (`build-instrument` beside `build`),
so ordinary builds and their compiler worker are untouched. It probes:

- **Haxe.** Every function that remains a call after inlining gets an enter
  probe and an exit probe before each return. A throw closes the calls it
  skips when a catch takes it, also when the function that catches is left
  out of the scope. While nothing records, a probe costs about
  0.5 ns on HashLink x64.
- **Native code we compile** (Windows x64, MSVC). Every source of a package's
  `native.sources` or `native.cmake` project is compiled with `/Gh /GH` and
  every module gets a PDB, which names its functions. Code we do not compile,
  such as system libraries, appears only through the calls into it. Linux
  and macOS do not instrument native code yet; `PROFILER-POSIX.md` is the
  design.

`haxeon.json` narrows what is probed:

```json
"instrument": {
  "haxe": { "include": ["*"], "exclude": ["Math", "haxe.ds.*"] },
  "native": { "include": ["**"], "exclude": ["vendor/harfbuzz/**"] }
}
```

Haxe patterns match qualified function names; `*` matches any run of
characters, and a pattern also covers every member of the class or package it
names, so `Math` covers `Math.sin`. A closure is matched by the function that
declares it. Native patterns match a source's path relative to its package (or
to the top of its CMake project), or its absolute path, with forward slashes:
`*` stays within one path component, `**` crosses components and `?` is one
character. Excluding small, hot functions keeps captures smaller and their
cost lower; an excluded function's time is counted in its caller.

Live patches keep their probes: a patched function is instrumented like the
build it patches, and its calls are named after the revision that ran.

### Short calls

Most calls an instrumented program makes are tiny: bounds checks, getters and
allocator internals that finish in well under a microsecond. Recording each
one costs more than the call itself and makes captures enormous (an editor
frame can make 400,000 of them). So the recorder drops calls shorter than
1 µs as they exit, unless a call inside them was kept. A dropped call's time
stays in its caller's, and the capture counts dropped calls per function. The
trace's "Short calls dropped per frame" counter holds each main-thread frame's
total, set where the frame starts; the report after the run lists the most
frequent functions:

```
dropped 10012 short calls to 2 functions; most often:
         10000  Main.tiny
```

`--profile-min-call=US` sets the threshold for one run, and `haxeon.json` sets
the project's:

```json
"instrument": { "minCallMicros": 1 }
```

`0` keeps every call. Fractions work (`0.5`).

### Boundary calls

Calls from the process's own modules into code nobody compiles with
instrumentation are recorded at the boundary (Windows x64), as slices named
after the function called:

- **Blocking and system calls**: waits and sleeps, file, pipe and network I/O,
  message waits, process creation, the C runtime's file streams and the C++
  standard library's waits (`kernel32!Sleep`, `ucrtbase!fread`,
  `ws2_32!recv`, `msvcp140!_Cnd_wait`, ...).
- **Direct3D 11 and DXGI**: draws, dispatches, copies, maps and flushes on the
  immediate context (`ID3D11DeviceContext::Draw`), and `Present` on every swap
  chain (`IDXGISwapChain::Present`).
- **Vulkan**: queue submits and presents, image acquisition and the fence,
  semaphore, queue and device waits.

`haxeon.json` chooses them:

```json
"instrument": {
  "boundary": { "imports": "blocking", "extra": ["kernel32.dll!SetEvent"], "dxgi": true, "d3d11": true, "vulkan": true }
}
```

`imports` is `blocking` (the curated set) or `none`; `extra` adds functions as
`module!function`. Only import-table calls are seen: a function the program
looks up with `GetProcAddress` is not, except Vulkan's, whose lookups are
hooked. Device and swap-chain hooks apply to objects created after the program
starts.

## Recording controls

A capture of an instrumented run grows quickly, so `haxeon run` can record
just part of a run:

| Option | Meaning |
| --- | --- |
| `--profile-start=launch\|manual` | Record from launch (default), or open the session paused. |
| `--profile-duration=SEC` | Stop after SEC seconds of recording; paused time does not count. |
| `--profile-max-size=MIB` | Stop when the capture reaches MIB (default 4096; 0 for no limit). |
| `--profile-window=START:END` | Export only that part of the capture to Perfetto, in seconds since the recorder connected; either side may be left out. The capture keeps everything. Frames keep their numbers from the whole capture; the `Startup` slice and names taken from entry functions need a window that starts at 0. |
| `--profile-min-call=US` | Drop calls shorter than US microseconds (default `instrument.minCallMicros`, else 1; 0 keeps every call). See [Short calls](#short-calls). |

Each option implies `--profile`. A paused session records nothing until the
program starts it:

```haxe
haxeon.ProfileRecording.start();   // or pause(), toggle(), recording()
```

so a program can record from a hotkey, a menu command or the moment a problem
appears. In the exosuit editor, the **Profiler: Toggle Recording** command
does this. Calls that span a pause end at the pause in the trace, and frames
end there too; the trace marks each pause and resume with an instant. If the
editor fails to start a recording, it stops the runtime's session, closes the
capture as partial and tries again at the next toggle; a malformed frame from
the runtime is counted and skipped rather than ending the session.

Example exclude lists, for a smaller capture of an editor-sized program:

```json
"instrument": {
  "haxe": { "exclude": ["Math", "Std", "StringTools", "haxe.ds", "haxe.io.Bytes", "haxe.Int64"] },
  "native": { "exclude": ["**/harfbuzz/**", "**/sheenbidi/**", "**/libunibreak/**", "**/onig*/**", "**/libwebsockets/**"] }
}
```

The first keeps the Haxe standard library's small, hot functions out; the
second leaves the text-shaping, bidi, line-breaking, regex and websocket
libraries to the boundary.

## Spans and counters

Applications can mark a measured operation with `haxeon.ProfileSpan.begin(name)`
and `haxeon.ProfileSpan.end(name)`. Markers use the same clock and thread IDs as
the stack samples. Names may be UTF-8 text. A span records its name at `begin`;
`end` closes the innermost open span on the thread, so keep begin and end
calls properly nested. After exporting the capture, `scripts/hlprof-spans.py`
lists the slowest spans and the sampled leaf functions inside each one:

```sh
.tools/hashlink/hlprof-live export --format perfetto \
  --output out/editor.perfetto.json out/editor.hlpc
python3 scripts/hlprof-spans.py --min-ms 20 --top 20 \
  --output out/span-spikes.json out/editor.perfetto.json
```

`hlprof-spans.py` matches each span end to its begin by name. A span's end
record carries no name, so the script currently stops with a "mismatched span"
error on exports of these captures.

The report includes sample counts and incomplete span counts when capture ends
before the final marker is drained. A span with few samples needs further
investigation; sampling alone cannot prove whether its thread was descheduled
or blocked.

## hlprof-live

`hlprof-live` records a session to an HLPC capture, and reports on and exports
captures. It records, against a program started with `hl --diagnostics PORT`:

```sh
hlprof-live [--host HOST] [--sources LIST] [--rate HZ] [--alloc-interval N] \
  [--pool MIB] [--interval MS] [--duration SEC] [--max-size MIB] [--paused] \
  [--min-call-us US] [--connect-timeout SEC] [--output FILE] PORT
```

| Flag | Meaning | Default |
| --- | --- | --- |
| `--host HOST` | Address of the diagnostics endpoint. | `127.0.0.1` |
| `--sources LIST` | Comma list of `instrument`, `sampling`, `alloc`. | `sampling` |
| `--rate HZ` | Sampling rate, 1 to 100000. | 1000 |
| `--alloc-interval N` | One allocation sample per N allocations on each thread. Setting it adds `alloc`. | 65536 with `alloc` |
| `--pool MIB` | Size of the runtime's buffer pool. The pool is allocated once per process, so a later, larger value replaces it. | 64 |
| `--interval MS` | Progress line period; 0 prints none. | 2000 |
| `--duration SEC` | Stop after this long of recording (paused time does not count). | until Ctrl-C or the program ends |
| `--max-size MIB` | Stop when the capture reaches MIB; data pushed before the runtime stops is dropped, so the capture ends at the limit. | no limit |
| `--paused` | Open the session paused. At a console, Enter pauses and resumes recording; the program can too (`haxeon.ProfileRecording`). | records from the start |
| `--min-call-us US` | Drop instrumented calls shorter than US microseconds (up to 4000000). See [Short calls](#short-calls). | keeps every call |
| `--connect-timeout SEC` | Keep retrying the connection this long. | one attempt |
| `--output FILE` | Write the HLPC capture. Without it, nothing is saved. | none |

A progress line shows the recorded size and rate, the frames received, and the
buffer chunks in use and stalls from the runtime's latest statistics frame
(`chunks 0/0` until the first one arrives, about a second in). The recorder stops when the program ends
its session, on Ctrl-C or `--duration`, and finalizes the capture. An HLPC v2
capture ends with a completion record; one without it is partial, and readers
use the records it has. If `HL_DIAGNOSTICS_TOKEN` is set in the program's
environment, set it in the recorder's too.

`--top`, `--lines` and `--raw-leaf` are not accepted while recording; they
belong to `report`. The `report` and `export` subcommands are unchanged, and
read both HLPC v1 and v2 captures:

```sh
hlprof-live report [--top N] [--lines] [--start-ms N] [--end-ms N] CAPTURE
hlprof-live export --format folded [--lines] [--start-ms N] [--end-ms N] CAPTURE
hlprof-live export --format perfetto [--lines] [--start-ms N] [--end-ms N] --output FILE CAPTURE
hlprof-live export --format pftrace [--process-name NAME] [--start-ms N] [--end-ms N] --output FILE CAPTURE
```

`--start-ms` and `--end-ms` select the part of the capture received in that
window, in milliseconds since the recorder started. `pftrace` is the native
Perfetto trace; `perfetto` is Chrome trace JSON, which has samples, spans,
calls, counters and instants but no frame tracks or `Startup` layout. The
exporter checks every size it reads, so a damaged capture fails with an error
instead of crashing it, and it caps a record at 256 MiB.

## Raw two-terminal workflow

For short-lived compiler profiling runs, start the HashLink process with
`--diagnostics-wait`. It opens the diagnostics socket, holds the program before
its entrypoint, and resumes after `hlprof-live` starts a session. Run the
first command in one terminal and the second in another:

```sh
LD_LIBRARY_PATH="$PWD/out:$PWD/.tools/hashlink" \
  .tools/hashlink/hl --diagnostics 24020 --diagnostics-wait out/compiler.hl
.tools/hashlink/hlprof-live --connect-timeout 10 --sources sampling,alloc \
  --rate 500 --output out/compiler.hlpc 24020
```

Then turn the capture into a trace:

```sh
.tools/hashlink/hlprof-live export --format pftrace --output out/compiler.pftrace \
  out/compiler.hlpc
```

## Recorder cost

`hlprof-bench` measures what the recorder costs a program: an enter/exit pair
and a span with recording off and on, on one and four threads, and the rate at
which a consumer drains the records. Run it after changing `vendor/hashlink/src/prof.c`.
It takes an optional iteration count (default 20000000):

```sh
out/cmake/windows-msvc/hashlink/bin/hlprof-bench.exe [ITERATIONS]
```

The program loads `libhl.dll`, so put `.tools/hashlink` on `PATH` first. Results
are nanoseconds per operation; `PROFILER.md` lists the reference figures. The
last line reports the consumer's drain rate and any stalls.

## Known issues

- **Export memory grows with the call rate.** The exporter holds about two
  seconds of records to put them in order, so a capture of an instrumented
  run that keeps every call needs memory in proportion. Drop short calls or
  export a window.
- **A forked child keeps recording.** The runtime has no `fork` handler, so a
  child that keeps running instrumented code after `fork`, without `exec`,
  records with no consumer and hangs once its pool fills.
- **Native instrumentation, boundary calls and mixed-mode samples are Windows
  x64 only.** See `PROFILER-POSIX.md` for the Linux and macOS design.
- **`hlprof-spans.py`** stops with a "mismatched span" error on these captures
  (see [Spans and counters](#spans-and-counters)).

## Captures and heap dumps

Profile captures include `capture.json` and a copy of the bytecode the run
was launched with, taken before launch. A live run also keeps each build it
patched or reloaded into, as `profile.r2.hl`, `profile.r3.hl` and so on, listed
under `liveRevisions` in the manifest. A capture directory holds one capture:
the trace and bytecode are named after the `.hlpc` file, and recording into a
directory that holds a different capture is refused. A HashLink heap dump captured by the application can be placed in
the same directory and added as the `heap` artifact in the manifest. Inspect
it with `haxeon heap inspect --capture DIR`, or pass the bytecode and dump paths
directly with `haxeon heap inspect BYTECODE DUMP`.

## Compiler profiling

To profile incremental compiler edits, pass `--profile-output` to the project
benchmark. It starts a dedicated worker with a diagnostics port, warms that
worker before attaching, and captures the edit loop. The normal worker launch
is unchanged. Sampling adds overhead, so use an unprofiled run for latency
comparisons. HashLink's allocation samples currently identify the native
allocator rather than Haxe allocation call sites; the compiler's per-phase
allocation counters remain the better source for allocation totals.

```sh
python3 scripts/benchmark-incremental-project.py \
  --project /path/to/haxeon.json --source /path/to/Main.hx \
  --token-a 'before' --token-b 'after' --output /tmp/edit.hl \
  --profile-output /tmp/compiler-edits.hlpc
.tools/hashlink/hlprof-live export --format perfetto \
  --output /tmp/compiler-edits.json /tmp/compiler-edits.hlpc
```

Incremental benchmark output also reports `alloc-<phase>-bytes`, `-count`,
`-gcs`, and `-gc-ms` from HashLink's cumulative GC counters. These are
phase deltas; `gc-ms` measures stop-the-world marking. The `driver-alloc-*`
values cover request preparation, compilation, artifact encoding, and writing.
Use the unprofiled benchmark for latency comparisons, since live sampling adds
CPU overhead.

To see why an incremental edit recompiled what it did, run the build with `HAXEON_EXPLAIN_INVALIDATION=1`. The compiler worker
then writes, for each compile, how many artifacts each kind of invalidation selected (`source-revision`, `body-changed`,
`signature-changed`, `dependency-signature`, `purity-dependency`, ...), a sample of the artifacts with their causes, and how many
functions were retyped and regenerated, to its log under the session directory (`HAXEON_COMPILER_SESSION_DIR`, default
`~/.cache/haxeon/compiler`). A comment-only edit should retype nothing; if it reports a long list, the kind with the large count
names the dependency that is invalidating too much.

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
| `instrument` | Enter and exit of every instrumented function. Not available yet: it needs instrumented builds, which do not exist. |

Without a list, `haxeon run --profile` records `sampling,alloc`. `hlprof-live`
records `sampling` unless told otherwise. Spans, counters, frame marks, GC
statistics, thread names and module loads are always recorded while a session
runs, whatever the sources.

## Host applications

`haxeon run --profile[=LIST]` builds the project, launches it with
`--diagnostics-wait`, attaches `hlprof-live`, writes an HLPC capture (default
`build/host/profile/profile-<timestamp>/profile.hlpc`), exports it as a native
Perfetto trace (`profile.pftrace` next to the capture), and prints a
top-functions report after the process exits. Open the `.pftrace` at
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
  such track.
- **Spans.** Slices from `haxeon.ProfileSpan`, nested on the thread that
  emitted them.
- **Counters.** HashLink GC counters (heap, allocated bytes, collections, mark
  time and allocation rate), app counters from
  `haxeon.ProfileCounter.set(name, value)`, and, with `alloc`, an estimate of
  the bytes allocated.
- **Samples.** Stack samples (`--rate`, default 1000 Hz) with Haxe frames named
  `Class.method` with file and line. A sample taken while the world was
  stopped for a GC also gets a "GC stop sample" instant.
- **Call stacks over time.** Each thread has a "Call stacks" track under its
  thread track that lays its samples out as nested slices: a function that
  stays on the stack across consecutive samples is one slice, so a frame reads
  as a flame graph over time below its `ui.frame` span. Boundaries are as
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
  for the recorder to free a buffer. The profiler drops nothing, so a stall
  delays the program instead. Raise `--pool` if stalls appear.
- **Instants** for module loads and live module revisions.
- **Instrumented calls**, once `instrument` exists: a slice per call, nested
  with the spans on the thread's track.

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
  [--pool MIB] [--interval MS] [--duration SEC] [--connect-timeout SEC] \
  [--output FILE] PORT
```

| Flag | Meaning | Default |
| --- | --- | --- |
| `--host HOST` | Address of the diagnostics endpoint. | `127.0.0.1` |
| `--sources LIST` | Comma list of `instrument`, `sampling`, `alloc`. | `sampling` |
| `--rate HZ` | Sampling rate, 1 to 100000. | 1000 |
| `--alloc-interval N` | One allocation sample per N allocations on each thread. Setting it adds `alloc`. | 65536 with `alloc` |
| `--pool MIB` | Size of the runtime's buffer pool. The pool is allocated once per process, so a later, larger value replaces it. | 64 |
| `--interval MS` | Progress line period; 0 prints none. | 2000 |
| `--duration SEC` | Stop after this long. | until Ctrl-C or the program ends |
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
Perfetto trace; `perfetto` is Chrome trace JSON.

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

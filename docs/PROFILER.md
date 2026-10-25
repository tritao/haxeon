# Profiler design

This is the design of Haxeon's profiler: an instrumenting profiler that
records every function call in Haxe and in the native code we compile, with
the sampling profiler kept as a second source. `PROFILING.md` covers how to use
it; this document covers how it works and why. Decisions that shaped it are
recorded in `adr/0001-instrumenting-profiler.md`.

## Goals

- **A complete timeline.** Every instrumented call is a slice with its enter
  and exit time, so a single slow frame can be read call by call. Per-function
  totals are derived from the timeline, not recorded separately.
- **Low overhead.** An enter/exit pair costs about 10 ns while recording and the
  recording check about 1 ns. Producers never take a lock; the only atomic
  read-modify-write is once per 256 KiB chunk.
- **Everything by default, scoped by configuration.** All Haxe functions and all
  native code we compile are instrumented in an instrumented build; `haxeon.json`
  narrows the scope.
- **Live assembly.** The application only records and streams. A client (the
  recorder today, Tracy later) assembles the timeline.

## Sources

A profiling session combines sources. `--profile` takes a comma-separated list:

| Source | What it records |
| --- | --- |
| `instrument` | Enter/exit of every instrumented Haxe and native function. Requires the instrumented build flavor. |
| `sampling` | Mixed-mode stack samples at a fixed rate (the original profiler). |
| `alloc` | Allocation samples, one per N allocated bytes. |

Spans (`haxeon.ProfileSpan`), counters (`haxeon.ProfileCounter`), frame marks
(`haxeon.ProfileFrame`), GC statistics, thread names and module loads are
always recorded while a session runs.

## Recording

### Clock

All records carry **ticks** from one clock per process:

- x86-64 with an invariant TSC: raw `rdtsc` (not the serializing `rdtscp`).
- x86-64 without one: `QueryPerformanceCounter` on Windows,
  `CLOCK_MONOTONIC_RAW` (ns) elsewhere.
- arm64: `CNTVCT_EL0`.
- Anything else: the platform monotonic clock in nanoseconds.

Records store ticks relative to the session's base tick in 56 bits, which
lasts 166 days at 5 GHz. The application never converts ticks: the consumer
periodically pairs a tick reading with the monotonic clock in nanoseconds and
the wall clock, and readers convert by interpolating between those pairs.

### Records

Each thread writes records to its own buffer. Records are little-endian,
8-byte aligned and never cross a chunk. Word 0 of every record is
`kind << 56 | ticks`.

| Kind | Name | Words after word 0 |
| ---: | --- | --- |
| 0x01 | `ENTER` | function key (u64): the function's code address |
| 0x02 | `EXIT` | none |
| 0x03 | `UNWIND` | count (u64): close this many of the innermost open calls |
| 0x10 | `SPAN_BEGIN` | `units:u32, encoding:u32` (0 UTF-16, 1 UTF-8), then the name padded to 8 bytes |
| 0x11 | `SPAN_END` | none |
| 0x12 | `FRAME_MARK` | frame set (u64; 0 is the main frame set) |
| 0x13 | `FRAME_IDLE` | frame set (u64) |
| 0x20 | `EVENT` | `id:u32, length:u32`, then the payload padded to 8 bytes |
| 0x21 | `COUNTER` | value (f64 bits), `units:u32, encoding:u32`, then the name padded to 8 bytes |
| 0x22 | `SAMPLE` | `tid:u32, frames:u16, flags:u8, 0:u8`, then `frames` u64 pcs, leaf first |
| 0x30 | `STALL` | end ticks (u64): the producer waited for a free chunk |

`EVENT` carries the existing profiler events (`profile_events.h`): thread
names, GC statistics, native symbols and locations, allocation samples and
module loads, with the payloads they always had. It also carries
`PROFILE_EVENT_DROPPED_CALLS`: the calls a thread dropped for being short
since its last such event, as entries of `key:u64, count:u32, 0:u32`, and
`PROFILE_EVENT_STARTUP`: the runtime's startup phases before the program's
entry point, as `thread:u32, count:u32`, then per phase `begin:u64, end:u64`
(ticks), `length:u32, 0:u32` and the name padded to 8 bytes. `main` marks the
phases with `hl_prof_startup_phase` when diagnostics are on; the first session
started before the entry point writes them once and puts its base tick at the
first phase, so the session's ticks start with the process.

A frame set's frames run from one `FRAME_MARK` to the next. `FRAME_IDLE` ends
the current frame without starting another, so time a UI spends waiting for
input is not counted as a frame.

### Buffers

- **Chunks.** Records go into 256 KiB chunks taken from a pool allocated when
  the session starts (64 MiB by default, configurable per session). The free
  list is a lock-free stack indexed by chunk number with a tag against ABA.
- **Thread state.** Each thread has a state, created on its first record, that
  holds its current chunk and write position. Creating and retiring states
  takes the registry lock; recording never does. A thread retires its state
  when it exits: through `hl_unregister_thread`, or, for a native thread the
  runtime does not know, through a fiber-local (Windows) or pthread-key
  destructor. Its last records are drained before the state is freed, also
  while recording is paused and after a stop until the final drain.
- **Publishing.** After each record the producer stores its write position with
  release semantics. When a chunk fills, the producer records the chunk's final
  size and its successor, then publishes the position in the new chunk.
- **Draining.** The consumer reads each thread's position with acquire
  semantics. A position inside the chunk it is reading means "read up to here";
  a position elsewhere means the chunk is finished, so it reads to the final
  size and moves to the successor. Drained chunks return to the pool.
- **Back-pressure.** When the pool is empty the producer waits for the
  consumer and then writes a `STALL` record covering the wait. Program
  threads never drop records: a missing exit would corrupt the timeline that
  follows it. The consumer thread itself, and writes made holding a lock the
  consumer takes (native symbol names, a retiring thread's last counts), must
  not wait for it (`hl_prof_no_wait`): with the pool empty those records are
  lost, counted in the `stats` frame's `lostRecords`, and the recorder warns.
  A collection holding the GC lock, and its mark threads, must not wait
  either. Such
  sections record no calls, instrumented or hooked, so no call loses half of
  its pair.

  A stalled thread blocks for the GC while it waits (`hl_blocking`): it
  touches only the pool until it has a chunk, and the consumer may be waiting
  for a collection before it can free one, so a collection must not wait for
  the stalled thread. `tests/integration/test-profiler-pool-stall.sh` keeps a
  1 MiB pool empty from four allocating threads; before this, it hung in about
  two runs of five.
- **Short calls.** With a minimum call duration (1 µs from `haxeon run`, 0
  for none), the producer holds back the run of `ENTER` records at the end of
  its buffer: its published position stays at the start of the run. An exit
  whose `ENTER` is still the last record, and came less than the minimum ago,
  takes that record back instead of writing an `EXIT`, and counts the call
  for a `PROFILE_EVENT_DROPPED_CALLS` event. Any record that is kept
  publishes the run. A dropped call therefore never reaches the consumer,
  short calls nested in each other go together, and a short call that called
  something long stays. A boundary call (a hooked call that may block, such
  as a wait) is never held or dropped: its `ENTER` publishes the run before
  it, so a thread blocked there shows its open calls while it waits. Counts are written at each frame mark, when a
  thread's table fills, at thread exit and when the session stops, which also
  publishes every run still held. A pause in the middle of a held run keeps
  it.

The recording check is a load of one global flag.

### Cost

`hlprof-bench` (built with HashLink) measures the recorder. On a 3 GHz x86-64
with an invariant TSC, through the C entry points:

| Operation | ns |
| --- | ---: |
| enter/exit pair, recording off | 2.7 |
| two TSC reads | 11.8 |
| enter/exit pair, recording, drained concurrently (1 or 4 threads) | 16 |
| span begin/end, recording | 18.6 |

The TSC reads are the floor. Through the Haxe probes, `fib(32)` (7 million
calls) runs at 1.51 ns per call uninstrumented, 1.98 instrumented and not
recording, and 18.6 recording. The consumer drains over 2 GB/s of records
before compression.

### Consumer

The diagnostics thread is the consumer. While a session streams it drains every
thread's new records about once a millisecond (polling positions continuously
would pull each producer's position across cores on every record), compresses each thread's segment with LZ4
and pushes it to the client, with no request needed. It also pushes symbol
metadata when modules load or are patched, thread names when they change, a
clock pair every 100 ms and statistics every second.

## Diagnostics protocol (HLDI v2)

The handshake and 16-byte frame header are those of HLDI v1 (see
`vendor/hashlink/docs/diagnostics-protocol.md`), with protocol version 2. A
frame pushed by the runtime has flag bit 2 set and request ID 0.

Requests on service 2 (profiler):

| Type | Name | Payload |
| ---: | --- | --- |
| 1 | status | none; the response is `active:u32, sources:u32, chunks:u32, chunksInUse:u32, dataFrames:u64, rawBytes:u64` |
| 4 | metadata | none; the response is the metadata snapshot |
| 16 | start | `sources:u32, sampleRate:u32, allocInterval:u32, poolMiB:u32`, optionally `flags:u32` (bit 0: start paused), then optionally `minCallNs:u32` (calls shorter than this are dropped; 0 or absent keeps every call) |
| 17 | stop | none |
| 18 | pause | none |
| 19 | resume | none |

`start` releases a program held by `--diagnostics-wait`. After its response,
the runtime pushes:

| Type | Name | Payload |
| ---: | --- | --- |
| 4 | metadata | the metadata snapshot (schema 4) |
| 16 | session | `version:u32, sources:u32, tickKind:u32, 0:u32, baseTicks:u64, nominalHz:u64` |
| 17 | data | `tid:u32, flags:u32, rawLength:u32, 0:u32`, then the records (LZ4 block when flag bit 0 is set) |
| 18 | clock | `ticks:u64, monotonicNs:u64, unixNs:u64` |
| 19 | threads | `count:u32`, then per thread `tid:u32, length:u32, UTF-8 name` |
| 20 | end | `dataFrames:u64, rawBytes:u64`; the last frame of a session |
| 21 | stats | `chunksInUse:u32, chunkCount:u32, stalls:u64, stallTicks:u64, rawBytes:u64, sentBytes:u64`, then `lostRecords:u64` |
| 22 | recording | `recording:u32`, pushed when the client or the program pauses or resumes recording |

`tickKind` is 1 for TSC, 2 for QPC, 3 for nanoseconds and 4 for `CNTVCT_EL0`.
`stop`, or the program exiting, drains every buffer before `end` is pushed.

## Capture files (HLPC v2)

The recorder writes the pushed frames as they arrive, without decoding them.

- Header (24 bytes): `HLPC`, version 2 (u16), header size 24 (u16), flags
  (u32), process ID (u32), sample rate (u32), sources (u32).
- Records: `type:u32, length:u32, recorderNs:u64`, then the frame payload. The
  type is the pushed frame type. The recorder ends a complete capture with type
  3, `frames:u64, bytes:u64`.

Version 1 captures (pull-based chunks) remain readable.

## Export

`hlprof-live export` decodes a capture into Perfetto (`pftrace`), Chrome JSON
(`perfetto`) or folded stacks. It reads metadata and clock pairs first, then
merges the threads' records in time order. In Perfetto, spans are nested slices
on their thread's track, instrumented calls are nested slices on the thread's
call-stack track (a flame graph over time), frames are slices on a "Frames" track, and samples, counters and GC
statistics keep their existing tracks. "Frames" and "Main thread frames" are
tracks under the main thread, which the trace lists first by giving it the
process id as its tid. The startup phases and the program's code before the
first frame mark go under a `Startup` frame (Perfetto only). A
thread's name comes from the runtime (`hl_thread_set_name`, which also writes a
`PROFILE_EVENT_THREAD_NAME` record on a recording thread that names itself),
or from the system name of a recorded thread, which the session's thread list
includes (`GetThreadDescription`, `/proc/self/task/<tid>/comm`). The export
merges every thread list of the session, so a thread that exited keeps its
name. A thread with no name at all takes its entry function's when the
session began before the program (it recorded the runtime's startup) and no
pause came before the thread's first record, so that first call is the entry
function; a C++ thread-start wrapper around the entry function is left out of
its stack. A thread that instrumentation does not cover has its samples laid
out as nested slices on its call-stack track, named after the thread, so it
still reads as a flame graph over time, at the sampling interval's resolution.
The startup phases are laid out on the main thread's track without hiding its
samples.

The export reads the capture twice. Pass 1 collects what pass 2 needs before
it writes anything: the recording pauses, the frames marked before an export
window (so a windowed export keeps the capture's frame numbers), the frame
thread, and each frame's dropped short calls, which pass 2 writes as one
"Short calls dropped per frame" value where the frame starts (the runtime
writes a frame's counts after its boundary, possibly later than the reorder
window). Pass 2 decodes each data frame and holds records in a 2-second
window to put the threads' records in time order, so its memory grows with
the record rate. An export window leaves out the `Startup` frame and naming
threads after entry functions, which need the capture's start. Every size
read from a capture is computed in 64 bits and checked against the data
before use; a record or decompressed frame larger than 256 MiB, the most the
runtime pushes, is malformed, and the table of open stacks holds 65536
threads. The Chrome JSON form has no frame tracks, startup layout or
call-stack tracks: the export-only events behind them are skipped, and
recording pauses are named instants.

## Instrumentation

### Haxe

A compiler pass over the SSA IR (`IrInstrumentation`, run after inlining)
adds an enter probe to every function that is not inlined and an exit probe
before every return. The probes are libhl natives (`std.prof_call_enter`,
`prof_call_exit`). An enter's key is the probe's return address, which lies in
the calling function's code: the exporter names it from the symbol metadata
like any native pc. Each live revision has its own code, and the metadata keeps
retired regions, so revisions stay apart.

On HashLink x64 the JIT tests the recording flag inline and branches over the
probe call, so an instrumented build that is not recording costs about 0.5 ns
per call over an ordinary one. While recording, the native writes the record
(about 16 ns per enter/exit pair, two TSC reads of it). arm64 calls the native
unconditionally. wasm drops the probes until it records.

Each thread keeps its instrumentation depth (enters minus exits). The pass
saves the depth before every try (`prof_call_depth`) and passes it to
`prof_call_unwind` at the start of the catch; the C trap macro does the same
for traps set in C. When the depth is above the saved one, the runtime writes
one `UNWIND` record closing the calls the throw skipped. A function the scope
leaves out gets no probes but still saves and unwinds the depth around its
tries, so a catch there closes the probed calls its throw skipped.

### Native code (Windows x64)

Native code is instrumented in two ways. Code we compile gets compiler hooks
on every function. Calls from it into code we do not compile, such as the
system and graphics libraries, are hooked at the boundary at run time. Other
platforms have neither yet: the instrumented flavor builds their native code
as usual, and only Haxe calls are probed. `PROFILER-POSIX.md` is the design
for Linux and macOS, and lists what else they need for parity.

**Compiler hooks.** MSVC's `/Gh` and `/GH` make the compiler call `_penter`
at the start of every function and `_pexit` at its end. The instrumented
flavor adds both flags to every source in the native scope
(`instrument.native` in `haxeon.json`) and links every module with `/DEBUG`,
so each one has a PDB:

- `native.sources`: `NativeToolchain` adds the flags per source when it
  compiles, and links the hooks library and `/DEBUG /OPT:REF /OPT:ICF
  /INCREMENTAL:NO` into each module.
- `native.cmake`: Haxeon configures the project with
  `CMAKE_PROJECT_INCLUDE=cmake/haxeon-instrument.cmake` and passes the hooks
  library and the include and exclude patterns as cache variables. The file
  compiles everything with `/Z7`, adds the link options and the hooks
  library, and, once the whole project is read (`cmake_language(DEFER)`),
  walks every target in every directory and adds `/Gh /GH` to each C or C++
  source that matches the patterns. Imported targets and generator
  expressions are skipped.

`_penter` and `_pexit` come from `hlprof_penter.lib`, a static library
HashLink builds (`prof_penter_x64.asm`, `prof_penter.c`). They are MASM and
run before the function's prolog or epilog, so they keep every register the
function still needs. While nothing records, each one is a load of a flag
pointer, a test and a return. While a session records, it saves the volatile
registers (rax, rcx, rdx, r8 to r11, xmm0 to xmm5) in an aligned frame and
calls into C with its return address. The library uses no C runtime, so it
links into modules built with either CRT. It does not import libhl: tools a
build runs link it but never load libhl, so until libhl is loaded the flag
pointer points at a nonzero placeholder, and the hooks look for `libhl.dll`
(`GetModuleHandle`, `GetProcAddress` of `hl_prof_on`, `hl_prof_enter_native`
and `hl_prof_exit`) at most once a millisecond until they find it.

An enter's key is the hook's return address, a pc inside the function.
`hl_prof_enter_native` puts each key into a lock-free set the first time a
session records it and queues it; the consumer names queued keys through
DbgHelp, with the same symbol events as sampled native frames. Naming never
runs inside the hooked call, which may hold locks DbgHelp takes. The exporter
collects every symbol event before it decodes any call. Native calls are
held back and dropped when short like Haxe calls (see Buffers). The
profiler's own code (libhl, the hooks) is never instrumented. A C++
exception that unwinds through instrumented frames skips their exit hooks;
the next Haxe catch restores the depth.

**Boundary hooks** (`prof_boundary.c`, `prof_boundary_x64.asm`). Haxeon sets
`HL_PROF_BOUNDARY` when it runs an instrumented build, from
`instrument.boundary`:
`imports=blocking|none;extra=a.dll!F,b.dll!G;dxgi=1;d3d11=1;vulkan=1`. The
runtime installs the hooks at startup when the variable is set, and not
otherwise.

- **Import tables.** The hooks patch the import address tables of the
  process's own modules, meaning every module not under the Windows
  directory. An entry is matched by the address it holds, not by name, which
  catches a function imported by name or ordinal, through an API set or
  forwarded from another module. A `kernel32` function is also looked up in
  `kernelbase`, which API-set imports bind to. The table is made writable
  for the store with `VirtualProtect`. The curated `blocking` set is waits,
  sleeps, file, pipe and socket I/O, message waits, process creation, the C
  runtime's file streams and the C++ standard library's waits in `msvcp140`
  (`_Cnd_wait`, `_Cnd_timedwait`, `_Thrd_join`, `_Thrd_sleep`);
  `PROFILING.md` lists examples.
- **Module loads.** `LoadLibraryA/W` and `LoadLibraryExA/W` are hooked the
  same way. After each successful load the hooks resolve targets in modules
  loaded since and patch every own module's imports again, under one lock.
- **Direct3D 11 and DXGI.** `D3D11CreateDevice` and
  `D3D11CreateDeviceAndSwapChain` are hooked. On a new device, the
  immediate context's vtable entries for draws, dispatches, copies, maps and
  flushes are replaced, and so are the swap-chain creation methods of the
  device's DXGI factory, so each new swap chain gets its `Present` (and
  `Present1`) entry replaced. A class shares one vtable, so patching it
  covers every object of the class.
- **Vulkan.** `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr` are wrapped,
  so the queue submits, presents, image acquisition and fence, semaphore,
  queue and device waits they hand out are hooked stubs. Calls the program
  imports from `vulkan-1.dll` directly are patched in its import table.

Every hooked function gets a 32-byte stub in an executable block (up to 1024
hooks). The stub loads its descriptor and jumps to `hl_prof_boundary_thunk`.
The thunk saves the four register arguments (integer and floating point),
records an `ENTER` with the stub's address as the key, copies up to twelve
stack arguments into its own frame, calls the real function, records an
`EXIT` and returns the real result. The consumer names a key from its
descriptor (`kernel32!Sleep`, `IDXGISwapChain::Present`). A boundary `ENTER`
is never held back and publishes the thread's held run, so a thread blocked
in the call shows its open calls while it waits. The thunk does not record a
call made while the thread is already inside a boundary call (the recorder
waiting for the consumer through a hooked wait, say), nor a call on a thread
that must not wait for the recorder (see Buffers), nor any call on the
diagnostics and sampling threads. The stub table has its own lock, never held
across a loader call: a Vulkan lookup, which may run under the loader lock,
takes only that one. A stub's name is copied once, when the stub is made.

Limits:

- Only import-table calls are seen. A function the program looks up with
  `GetProcAddress` is not, except Vulkan's.
- Device and swap-chain hooks apply only to objects created after the
  hooks are installed.
- A hooked function may take at most four register arguments and twelve
  stack arguments, which covers every function in the curated sets.

### Build flavor and scope

Instrumentation is a separate build flavor with its own output directory, so
ordinary builds contain no probes. `haxeon.json` scopes it:

```json
"instrument": {
  "haxe": { "include": ["*"], "exclude": ["Math", "haxe.ds.*"] },
  "native": { "include": ["**"], "exclude": ["vendor/harfbuzz/**"] },
  "boundary": { "imports": "blocking", "dxgi": true, "d3d11": true, "vulkan": true },
  "minCallMicros": 1
}
```

`minCallMicros` is the session's minimum call duration (see Buffers); it is
sent when the session starts, so changing it needs no rebuild.

## Milestones

1. **Infrastructure:** the recorder core, push stream, HLPC v2, export,
   `--profile` sources, spans and counters on the new path, frame marks and the
   overhead benchmark.
2. **Haxe instrumentation:** the compiler pass, the build flavor, the JIT
   intrinsic, `UNWIND` on throws and live patches.
3. **Native instrumentation:** `/Gh /GH` stubs, PDBs, native scope and
   symbolization in the exporter.
4. **Boundary hooks.**
5. **Recording controls:** manual start and stop, duration and size limits,
   and the example exclude lists.
6. **Other viewers:** Tracy and others.

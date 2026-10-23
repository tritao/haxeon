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
module loads, with the payloads they always had.

A frame set's frames run from one `FRAME_MARK` to the next. `FRAME_IDLE` ends
the current frame without starting another, so time a UI spends waiting for
input is not counted as a frame.

### Buffers

- **Chunks.** Records go into 256 KiB chunks taken from a pool allocated when
  the session starts (64 MiB by default, configurable per session). The free
  list is a lock-free stack indexed by chunk number with a tag against ABA.
- **Thread state.** Each thread has a state, created on its first record, that
  holds its current chunk and write position. Creating and retiring states
  takes the registry lock; recording never does.
- **Publishing.** After each record the producer stores its write position with
  release semantics. When a chunk fills, the producer records the chunk's final
  size and its successor, then publishes the position in the new chunk.
- **Draining.** The consumer reads each thread's position with acquire
  semantics. A position inside the chunk it is reading means "read up to here";
  a position elsewhere means the chunk is finished, so it reads to the final
  size and moves to the successor. Drained chunks return to the pool.
- **Back-pressure.** When the pool is empty the producer waits for the
  consumer and then writes a `STALL` record covering the wait. Nothing is
  dropped: a missing exit would corrupt the timeline that follows it.

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
| 16 | start | `sources:u32, sampleRate:u32, allocInterval:u32, poolMiB:u32` |
| 17 | stop | none |

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
| 21 | stats | `chunksInUse:u32, chunkCount:u32, stalls:u64, stallTicks:u64, rawBytes:u64, sentBytes:u64` |

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
merges the threads' records in time order. In Perfetto, instrumented calls and
spans are nested slices on their thread's track (a flame graph over time),
frames are slices on a "Frames" track, and samples, counters and GC
statistics keep their existing tracks. Each thread's samples are also laid out
as nested slices on a "Call stacks" track under the thread, so code the
instrumentation does not cover still reads as a flame graph over time, at the
sampling interval's resolution.

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
one `UNWIND` record closing the calls the throw skipped.

### Native code (Windows x64)

Modules we compile are built with `/Gh /GH`. The `_penter`/`_pexit` hooks are
MASM stubs that save the volatile registers and write `ENTER`/`EXIT` records
with the function's address as its key; the exporter names it from the
module's PDB. Every module we compile has a PDB. The profiler's own code is
never instrumented.

Calls from our modules into code we do not compile are hooked at the boundary:
import-table hooks for blocking and system calls, vtable hooks for the DXGI
swap chain and D3D11 device context, and wrappers for Vulkan submit, present
and fence waits.

### Build flavor and scope

Instrumentation is a separate build flavor with its own output directory, so
ordinary builds contain no probes. `haxeon.json` scopes it:

```json
"instrument": {
  "haxe": { "include": ["*"], "exclude": ["Math", "haxe.ds.*"], "skipSmallLeaves": false },
  "native": { "include": ["**"], "exclude": ["vendor/harfbuzz/**"] },
  "boundary": { "imports": "blocking", "dxgi": true, "d3d11": true, "vulkan": true }
}
```

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

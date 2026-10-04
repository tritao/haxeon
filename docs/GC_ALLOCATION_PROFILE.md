# Allocation fast-path follow-up

The previous mark-prefetch, page-order and sweep experiments failed their 5% gates. This follow-up measures
fixed-size allocation in binarytrees (18) and merkletrees (16). It retains the same acceptance rule: at least 5%
on a tree benchmark, no regression beyond noise elsewhere, and peak RSS growth no greater than 5%.

## Measurement method

All analysis uses the release fork at `9b3ea1c1`. A separate library rebuilds only gc.c with the original -O3 flags
plus debug information. Four runs per benchmark sample cpu_core cycles at 1999 Hz with DWARF inline frames.
TLABs remain enabled; GC_PROFILE is not used. Output matches the ordinary runtime exactly. These are diagnostic
profiles, not acceptance timing samples. Kernel/JIT frames are partly unresolved.

A second temporary diagnostic build counts allocations and refills using main-thread TLS counters. It preserves
TLAB sizes and accounting, but instrumentation adds overhead, so none of its timing is used. The benchmarks
allocate on the main thread. Raw scripts, copied diagnostic source, profiles and hashes are under
`out/allocation-fastpath/`; no diagnostic instrumentation is added to the shipped VM.

| Main-thread counter | binarytrees | merkletrees |
|---|---:|---:|
| Small TLAB allocations | 68332287 | 29971889 |
| Refills | 804661 | 411422 |
| Refill fraction | 1.178% | 1.373% |
| Bytes explicitly zeroed | 1639974192 | 839211688 |
| General-path allocations | 31 | 29 |
| Object allocations | 68332255 | 14985948 |
| Bound-method initializations | 0 | 0 |

Binarytrees principally allocates 24-byte nodes. Merkletrees uses 40-byte nodes and 16-byte boxed nullable values.
More than 98% of small allocations use an existing run rather than refilling it.

## Sampled costs

Categories are exclusive, with actual collection and sweep frames taking precedence. Dispatch includes the
generic allocator's entry/eligibility checks and common return sequence. TLAB-hit work covers slot lookup and
cursor updates; zeroing includes resolved memset calls. Allocation-other includes unresolved/system work under
an allocator stack and must not be interpreted as measured slow-path execution: exact counters show only about
30 general allocations. Object metadata covers hl_alloc_obj's native work; constructor/JIT field stores remain
in other/unresolved. Sample periods weight percentages; sample counts are given for scale, not as exact durations.

| Sampled category | binarytrees | merkletrees |
|---|---:|---:|
| Dispatch / common return | 13.45% | 15.05% |
| TLAB hit | 16.40% | 31.04% |
| Named zeroing | 1.83% | 4.06% |
| TLAB refill | 2.20% | 2.80% |
| Object metadata | 9.48% | 4.63% |
| Other allocation/system work | 18.41% | 13.21% |
| Mark | 10.94% | 4.96% |
| Sweep / free-list rebuilding | 1.83% | 4.32% |
| Other / unresolved | 25.46% | 19.93% |
| Total core samples | 10065 | 4064 |

## Candidate

The current hl_gc_alloc_gen_owner makes even TLAB hits establish a frame with five saved registers, 184 bytes
of local stack and a stack-canary check. Cold census stack capture and error/refill handling cause this frame.
The zeroing loop described as plain stores is compiled into a memset call. Removing zeroing is not justified:
objects must be initialized and stale pointer padding erased before publication or a collection.

The accepted change is a thin ready-slot entry plus bounded clearing of the five small size classes. Empty
buffers and special modes fall through to the full allocator. Both paths share eligibility and initialization
helpers, so ownership, finalizers, profiling, census, tracking and forced-collection policy have one definition.
Zeroing remains mandatory: up to five explicit word stores replace the compiler-generated memset call for
MEM_ZERO; pointer padding is still cleared when MEM_ZERO is absent. There is no JIT or object-layout change.

This fast entry is compiled only for x86-64 builds that already support TLABs. GC_DEBUG, memory-checking,
external-GC, non-threaded and other-architecture builds retain the original public allocator body. On supported
builds the default is enabled; `HL_GC_ALLOC_FAST=0` restores the full entry and original zeroing loop. The switch
is read once during GC initialization. AArch64, 32-bit and MSVC execution are untested.

The generated ready-slot MEM_ZERO path has one saved general register, no stack canary and no memset call.
The cold full path remains noinline; x86-64 assembly confirms fallthrough to it is a tail jump. Padding clearing
can still call memset. Refill accounting, collection triggers and run reservation are unchanged.

## Experiments and gate

Acceptance uses frozen runtime snapshots and identical bytecode on core 0, nine alternating pairs, and checks
one-minute load <=4 before and after each sample. The baseline is the unmodified library, rather than the new
entry in disabled mode, so a slow fallback wrapper cannot inflate the speedup. Outputs must match.

| Intermediate candidate | binarytrees improvement | merkletrees improvement | Decision |
|---|---:|---:|---|
| Thin entry, duplicated eligibility | 3.58% | 5.26% | Refactor policy before accepting |
| Thin entry, shared policy | 3.30% | 4.73% | Fails 5% gate on its own |
| Shared policy plus bounded clearing | 9.82% | 9.98% | Proceed to final six-workload validation |

These intermediate results are diagnostic. The final architecture-guarded build passed its own comparison
and full validation below. Peak RSS was unchanged in the intermediate runs.

## Correctness checks

The new `gc-allocation-paths` runtime test runs the native API probe with the switch disabled and enabled. It
checks reused blocks in all five small classes, RAW and NOPTR initialization, pointer padding, zero-size
allocation, callbacks, ownership, forced collection and exact census counts. The original unmodified library
passes the same probe. Six isolated mutation libraries deliberately break zeroing, padding, callback bypass,
owner bypass, force-major bypass or census bypass; every mutation makes the probe fail. No mutated source
is installed in the repository or ordinary runtime.

The final release build passes the following checks:

| Suite | Result |
|---|---|
| HashLink fixture manifest, defaults | 324 passed |
| HashLink fixture manifest, allocator/IR optimizations disabled | 324 passed |
| gc-controls, gc-collection-pacing, thread-gc-stress | Each x20 at default and 65536 trigger, in both modes: 240 passed |
| Compiler/runtime driver, defaults | 472 passed |
| Compiler/runtime driver, HL_GC_ALLOC_FAST=0 and HAXEON_INLINE/LOADSTORE/STRENGTH=0 | 472 passed |
| Stock-Haxe differential | Passed |
| Compiler self-hosting | Fixed point passed |
| Wasm backend | Passed |
| Wasm32 / Wasm GC / HashLink parity | 321 fixtures passed; 14 existing skips |
| Workspace, compiler embedding, Git package lock integrations | Passed |
| Live DAP manifest-inline configuration | Passed |
| Native allocation guard mutations | All six rejected |
| GC_DEBUG and GC_MEMCHK compile configurations | Syntax checks passed |

The first driver attempt had a registration error: the probe was entered as a bytecode-producing executable
case rather than a named runtime test. The probe passed, but the driver then looked for a nonexistent bytecode
file. Registration was corrected; both complete driver runs above are clean.

No AArch64, 32-bit, MSVC or full debug/memcheck runtime execution was performed. Other DAP suites and a new
cross-language toolchain comparison were not run. This change modifies neither the JIT nor generated bytecode.

## Final acceptance

| Benchmark | Original (s) | Fast entry + clearing (s) | Improvement | Peak RSS change |
|---|---:|---:|---:|---:|
| binarytrees | 1.210434 | 1.097347 | +9.34% | +0.00% |
| merkletrees | 0.499628 | 0.451617 | +9.61% | +0.00% |
| nbody | 0.215978 | 0.216932 | -0.44% | +0.00% |
| fasta | 0.455936 | 0.451276 | +1.02% | +0.00% |
| spectral-norm | 0.181919 | 0.181254 | +0.37% | +0.00% |
| lru | 0.090623 | 0.089936 | +0.76% | +0.00% |

Both tree benchmarks clear 5%, and every one of their nine pairs is faster. Nbody's 0.44% difference is within
noise; no other workload regresses. Median peak RSS changes by at most 0.0042%, well below the 5% gate. One
binarytrees pair crossed the load limit and was discarded before collecting its replacement.

Single supporting perf-stat runs report cpu_core instructions of 19.025 -> 16.953 billion for binarytrees
(-10.89%) and 7.067 -> 6.183 billion for merkletrees (-12.51%). On this hybrid host the cpu_atom counters do not
represent the pinned workload and are ignored. Counter runs are diagnostics, not acceptance timings.

The combined change is retained and enabled by default on the supported builds. The thin-entry-only variant
is not shipped as a separate option. No collector traversal, sweep, run ordering or collection threshold changes
are retained. The compiler and generated bytecode are unchanged.

`out/allocation-fastpath/measure.json` records all accepted times, loads, RSS observations and VM/library hashes.
`final-manifest.json` hashes the source, frozen original/new libraries, native runtime and all six bytecode inputs;
the unmodified library matches `baseline-build.json`. Raw logs and intermediate variants remain in that ignored
scratch directory. The committed reports and guard tests are the permanent artifacts.

Runtime commit: `2f49c4d4` in the fork. Submodule bump and guard tests: `2fc9cdde` in Haxeon. Both repositories
remain on their existing branches; no push was performed.

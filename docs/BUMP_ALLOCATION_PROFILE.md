# Inline allocation: Stage 0

Decision: proceed to a guarded x86-64 fixed-object prototype (Stage 1). Allocation and object setup still occupy
about 47% of binarytrees sampled cycles after allocation-volume page retention. A plausible 8% whole-program
saving has enough headroom to test, but no inline allocation implementation or measured speedup is claimed here.
Stage 1 must independently clear its 5% paired timing gate; store elimination, arrays and boxes remain deferred.

## Frozen baseline and method

Main baseline `2e12af60`, current fork/library with allocation-volume empty-page retention. Set
`HL_GC_KEEP_EMPTY=1`, `HL_GC_EMPTY_BUDGET=67108864`; the existing collection trigger remains at its default.
The frozen VM, libhl and native HDLL are under `out/bump-allocation/baseline`, with SHA-256 in `manifest.json`.
Tree bytecode is the existing `out/optimization-next/{binarytrees,merkletrees}/app.hl`. No runtime source was changed.

Nine runs per workload, core 0, one warmup, reversed language order on alternate rounds, one-minute load <=4 before
and after every accepted sample; crossing samples are repeated. Builds and profiling finished before timing.
This is a baseline census, not on/off acceptance of a new feature. Whole-process times include startup and collection.

## Results

| Workload | Median seconds |
|---|---:|
| binarytrees, depth 18 | 0.796906 |
| merkletrees, depth 16 | 0.285979 |

The microbenchmark creates five million objects with one, two or four doubles, retaining a rotating 256-entry
ring and producing a checksum. Size labels are HashLink layout sizes; Dart and C# allocate different layouts.
Numbers include constructor stores, ring operations, loop work, GC and startup, not just allocation latency.

| HashLink size | Haxeon ns/iteration | Dart ns/iteration | C# ns/iteration | Haxeon instructions/iteration | Dart instructions/iteration | C# instructions/iteration |
|---|---:|---:|---:|---:|---:|---:|
| 16 | 12.56 | 5.26 | 10.51 | 246.72 | 86.24 | 161.90 |
| 24 | 13.03 | 5.25 | 10.82 | 262.80 | 85.54 | 165.47 |
| 40 | 13.59 | 5.25 | 11.50 | 283.75 | 85.59 | 171.05 |

Instruction counts come from separate single `perf stat` runs (`cpu_core` PMU); they are diagnostic, not repeated
counter confidence intervals. The 1000-iteration checks for all sizes and languages agree with the stock Haxe
interpreter (722604). GDB confirms the Node24 runtime layout is 24 bytes and the loop calls `hl_alloc_obj`.
C# disassembly contains `CORINFO_HELP_NEWSFAST` inside the loops. A symbol-bearing Dart AOT diagnostic build
contains a call to `new Node24`, which tail-jumps to `stub AllocateObject`; its cursor bump, limit check, header and
null initialization remain present. Thus the source allocations survive, but Dart does not inline this allocation
in this microbenchmark. The claim that avoiding calls alone explains its advantage is unsupported.

A separate zero-iteration startup diagnostic gave medians of 4.04 ms (Haxeon), 2.59 ms (Dart) and 26.21 ms (C#).
External load was above the <=4 acceptance limit, so these are context only, not values to subtract from the table.
A qualified startup run was deferred after sustained high load; the raw observations and loads are in
`startup-diagnostic.json`. C# startup is material at five million iterations, so its whole-process ns/iteration
must not be interpreted as a steady-state allocation comparison. Construction and collection attribution comes
from the separate tree profiles below; no claim of isolated per-allocation latency is made.

## Updated profiles

Four runs per tree, release optimization with debug information added only to gc.c, `perf record -F 1999 -g
--call-graph dwarf`, core 0. Outputs match the frozen runtime. Exclusive cycle-weighted categories, with collection
frames taking precedence over allocation frames; unresolved/JIT samples remain. This is approximate attribution,
not precise phase timing or removable-cost accounting.

| Category | binarytrees | merkletrees |
|---|---:|---:|
| Allocation excluding object setup | 35.93% | 43.39% |
| Object setup | 11.40% | 7.78% |
| Mark | 16.60% | 8.16% |
| Sweep/finalizers | 7.92% | 9.83% |
| Other/unresolved | 28.15% | 30.85% |

Core-cycle samples: 6299 / 2261. Leaf attribution includes `hl_gc_alloc_gen_owner` 13.94% / 14.81%,
`gc_tlab_thread` 8.59% / 7.86%, `hl_gc_alloc_gen` 4.06% / 5.14%, and `gc_tlab_clear` 4.95% / 6.99%.
These are overlapping evidence with the table, not additional costs to add to it. Zeroing must remain in Stage 1.

## Fast-path estimate and gate

The assembled scratch shape in `out/bump-allocation/estimate.s` has 22 hit-path instructions before its synthetic
return for a 24-byte object: TLS-offset descriptor and TLS load, registered-thread check, a runtime eligibility
check, runtime/prototype readiness checks, slot lookup, cursor/limit operations, two zero stores and the type header.
The offsets and registers are placeholders. This is instruction-shape evidence, not runnable allocation code.
16-byte and 40-byte variants change the zero-store count; a real implementation also needs temporary-register
allocation, pending-collection handling and slow-edge save/restore. An inline expansion would omit the synthetic
return. If the policy handshake requires further guards, count them before finalizing the emitter.

The historical ten-instruction estimate was too optimistic. Nevertheless, the microbenchmarks retire about
247–284 instructions per iteration, and the current native path repeats general eligibility/layout work and
allocation-call/frame handling. As a screening assumption, reducing the combined allocation/object-setup cost by
20% gives roughly 9.5% of binarytrees time (47.33% × 20%). That clears the plan's plausible 8% headroom threshold;
it is a hypothesis supported by the sampled share and code shape, not an empirically established saving.
The much leaner Dart stub suggests a cheaper allocation path is possible without removing every call. A thin
helper alone already failed earlier gates, so do not revive it without new evidence.

Proceed only with Stage 1's full-zeroing, lazy-prototype, runtime-policy and explicit JIT allocation operation.
If TLS/register pressure, handshake checks or stub integration consume the estimated benefit, drop the prototype.

## Coverage and artifacts

Completed: all three micro sizes in three languages, stock interpreter checksum checks, nine-run tree and micro
baselines, four profiles per tree, separate instructions/cycles/page-fault counters, Haxeon/Dart/C# code inspection,
and assembled fast-path shape. Low-load startup timing was not completed; the busy-machine diagnostic is marked
separately. Local scripts, outputs, profiles, disassemblies and manifests are in
`out/bump-allocation/`; permanent micro sources are in `tests/bench/bump-allocation/`.

There is no VM/compiler change, so the full fixture, driver, Wasm, differential, self-hosting, GC stress, integration,
DAP and mutation gates were not repeated in Stage 0. They are required for Stage 1. AArch64, Windows and 32-bit
remain untested. No Stage 1 switch or default was added and nothing was pushed.

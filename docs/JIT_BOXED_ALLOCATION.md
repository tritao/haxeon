# Stage 3: integer-box allocation experiment

Stage 3 of [the bump allocation plan](BUMP_ALLOCATION_PLAN.md) was tested and dropped. Guarded inline integer
boxing improved merkletrees by about 20%, but repeated LRU comparisons showed a small regression against the
accepted runtime, including with the new switch disabled. The no-regression gate failed. The accepted Stage 1
implementation remains unchanged; `HL_JIT_ALLOC_BOX` is not a committed feature.

## Opportunity and implementation

The [allocation census](ALLOCATION_CENSUS.md) covered all six benchmarks and the compiler's own 461 sources.
Merkletrees allocated 14,985,902 16-byte integer boxes: half its allocation count and 28.57% of allocated bytes.
Four uninstrumented profiles attributed 708 of 1977 VM samples to stacks through `hl_alloc_dynamic` (35.81%).
This justified testing integer boxing, but not extending allocation to variable-size arrays.

The scratch Linux x86-64 SysV prototype used `HL_JIT_ALLOC_BOX=1`, independently of Stage 1's object switch.
It expanded eligible `OToDyn` operations through the existing guarded TLAB machinery. Eligibility required an
unowned `HI32` type and a 16-byte dynamic representation; debug mode and unsupported configurations retained
ordinary calls. The fast path initialized the type header and all padding before storing the integer payload.
The cold refill path preserved live registers and performed a safepoint. Allocation callbacks, census, tracking,
collection policy and pending collection requests forced the ordinary path. No public bytecode, compiler IR or
cache identity changed.

The first implementation refactored descriptor preparation and inserted helpers among existing allocator functions.
A second layout grouped the new cold helpers after the existing GC functions, sharing the existing policy list and
machine-code emitter while preserving the locations of the hot GC allocation functions. Both layouts passed their
validation runs. This cleanup did not remove the LRU regression. No benchmark-specific eligibility or arbitrary
alignment workaround was added.

## Final six-benchmark comparison

Nine alternating pairs, pinned to core 0, identical bytecode, one-minute load <=4 before and after accepted samples.
The accepted Stage 1 VM/library was compared with the final grouped-helper prototype. Both sides enabled Stage 1
object allocation and bounded empty-page retention with a 64 MiB cap. Outputs matched. No builds or validation from
this task overlapped timing. Negative improvement denotes a slowdown; these are medians, not a new cross-language table.

| Benchmark | Accepted Stage 1 (s) | Prototype (s) | Improvement | Median peak RSS off / on (KiB) |
|---|---:|---:|---:|---:|
| binarytrees | 0.568538 | 0.569638 | -0.19% | 97112 / 97112 |
| merkletrees | 0.247260 | 0.198725 | +19.63% | 81744 / 81760 |
| nbody | 0.221619 | 0.220269 | +0.61% | 6240 / 6240 |
| fasta | 0.427895 | 0.430610 | -0.63% | 81120 / 81120 |
| spectral-norm | 0.183051 | 0.183775 | -0.40% | 7520 / 7520 |
| lru | 0.092902 | 0.093563 | -0.71% | 7840 / 7840 |

Merkletrees improved in all nine final pairs and cleared its 3% gate. RSS was essentially level. LRU was slower in
seven of nine final pairs. Other sub-1% differences alone do not establish regressions.

The LRU result warrants rejection because the slowdown repeated in independent nine-pair runs:

| LRU comparison | Baseline (s) | Candidate (s) | Improvement |
|---|---:|---:|---:|
| Initial implementation, first six-benchmark run | 0.092444 | 0.094484 | -2.21% |
| Initial implementation, focused repeat | 0.090952 | 0.092086 | -1.25% |
| Initial runtime change, boxing disabled on both sides | 0.091000 | 0.092708 | -1.88% |
| Final layout, focused repeat | 0.090701 | 0.092113 | -1.56% |
| Final runtime change, boxing disabled on both sides | 0.090845 | 0.092699 | -2.04% |
| Final runtime, boxing off versus on | 0.092461 | 0.092297 | +0.18% |

Toggling boxing within the same runtime was approximately neutral on LRU. Identical LRU JIT instruction counts and
code size with boxing disabled, plus single diagnostic VM/library substitution runs, implicate the runtime/library
change rather than the boxing expansion itself. Code layout is a possible explanation, not a proven cause. The
regression still counts against acceptance; comparing only the switch within one changed runtime would hide it.

## Code size and compiler scope

The initial prototype's merkletrees JIT code grew from 4336 to 5312 bytes (+22.51%). For a trivial compilation
through the stock-Haxe-built compiler, emitted JIT code grew from 5,856,464 to 6,191,840 bytes (+5.73%). These are
code-size counters, not JIT compilation-time measurements. The final layout used the identical VM executable.

The compiler compiled its own sources with both frozen runtimes and produced identical output hashes. Its paired
nine-run timing was not completed: repeated load-gate waits prevented the earlier run, and the final run was stopped
after the six-benchmark results confirmed rejection. Isolated startup/JIT-only and hot-patch latency were not measured.
No compiler performance acceptance claim is made.

## Validation completed

The final grouped-helper layout repeated and passed:

- All 327 non-Wasm program fixtures in both modes. The enabled mode used default compiler optimizations; the
  disabled mode used boxing off and `HAXEON_INLINE=0 HAXEON_LOADSTORE=0 HAXEON_STRENGTH=0`.
- Compiler/runtime driver: 479/479 in each of those modes, including the new boxed-allocation runtime test.
- GC controls, collection pacing and thread stress: each x20 in each mode, both at the default trigger and
  `HL_GC_MIN_TRIGGER=65536` (240 stress executions).
- Differential suites with boxing enabled/default compiler options and boxing disabled/inlining/load-store off.
- Self-hosting to a fixed point in both modes.
- Wasm backend, and Wasm GC parity: 324 fixtures agreed across HL/Wasm32/Wasm GC, 14 existing skips.
- Workspace, compiler embedding with incremental execution, Git package-lock and DAP inline-configuration integration.

The new behavioral fixture used stock Haxe's interpreter as its independent reference. A stock-Haxe-bytecode native
probe checked integer limits, null, live integer/float/pointer values across refill, exception handlers, dirty padding
reuse, type ownership, and callback/census/tracking changes after JIT compilation. Both switch modes passed.

The initial implementation also passed the full suites. Isolated mutations of census, tracking, callback, padding,
bounds, type header and register reload made tests fail; separate owner/type eligibility mutations failed too.
Mutations were restored. The final helper layout separately passed the native probe in both modes before its full
validation repeat. Mutation builds were not repeated for the source-placement-only cleanup.

Additional DAP stepping and scope comparisons of the initial prototype failed identically with boxing off and on
(stepping exit 5, scope exit 1 with missing loop variables), consistent with the existing failures. These were not
repeated for the final helper layout. Other DAP tests, AArch64, Windows, 32-bit and GC_DEBUG/memcheck were not tested.

## Disposition and evidence

All prototype source and test registrations were removed after rejection; the fork is unchanged and needs no commit
or submodule bump. The rebuilt VM and library match the frozen accepted Stage 1 binaries byte-for-byte, and the existing native
allocation probe passed again in both modes. Local evidence remains under `out/boxed-allocation/`:
`final-six.json`, `layout-lru.json`, `six.json`, `lru-repeat.json`, both validation logs and suite logs, mutation logs,
GDB disassembly, JIT counters, `frozen-hashes.json`, `layout-hashes.json`, `rejected-final.patch`, and `rejected-tests/`.
The final prototype VM hash was `de6d0ff23543079c99d5a3074d7911d755d0377fcfe8530ab49b2a01e2954b91`;
its library hash was `d76c1b66980c41a6f214e179f3ea60f27be173969fa23c48bcc198e3e79830af`.

The census remains useful: any follow-up should first isolate the runtime/library regression, then test integer
boxing again. Arrays require a separate representation-specific opportunity measurement and design.

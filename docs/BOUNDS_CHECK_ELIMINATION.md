# Counted-loop bounds-check elimination: rejected experiment

The corrected census identified nbody's four typed array reads (weight 144) and fasta's counted-loop read
(weight 8). The experiment passed correctness checks, but failed the required 3% performance gate. Its compiler
pass, IR flags, native helpers and JIT switch were removed. There is no `HAXEON_BOUNDS` or `HL_JIT_BOUNDS` feature
in the resulting tree. `IrLoopBounds` remains as read-only analysis for the census, along with its proof tests and
the portable `counted-array-loops` behavior fixture.

## Measurement

Core 0, nine alternating pairs, identical bytecode and frozen VM/runtime libraries. Every pair's recorded
one-minute load stayed at or below 4; pairs crossing that threshold were discarded. Positive improvement means
faster. RSS changes compare medians of the nine peak-RSS observations in each mode.

| Benchmark | Off (s) | On (s) | Improvement | Peak RSS change |
|---|---:|---:|---:|---:|
| nbody | 0.2149 | 0.2148 | +0.07% | -0.32% |
| fasta | 0.4503 | 0.4793 | -6.44% | +0.00% |
| spectral-norm | 0.1814 | 0.1800 | +0.78% | -0.11% |
| lru | 0.0926 | 0.0925 | +0.02% | +0.00% |
| binarytrees | 1.2046 | 1.2027 | +0.15% | +0.00% |
| merkletrees | 0.4918 | 0.4899 | +0.37% | +0.00% |

No benchmark reached 3%; fasta regressed 6.44%, with all nine pairs slower when enabled. The experiment is rejected without attributing the regression
to an unproven cause. The benchmark README retains its accepted results. Raw pairs, load observations and
build hashes are in `out/optimization-next/bounds-measure.json`.

## What was tested

The experimental pass ran after load/store forwarding and strength reduction, including with inlining disabled.
It stored sorted proven ArrayGet output IDs on immutable function copies and included those flags in serialized
IR comparison. Native ABI metadata participated in memo invalidation. Typed Int, Float and ordinary object reads
were supported; erased arrays and inline value-class elements were excluded. Wasm retained its own checks.

`IrLoopBounds` recognizes the frontend's pre-increment induction form and conventional unit-step phi form.
A dominating true edge checks the same index against the same array's length, and the false edge leaves the loop.
Captured lengths must survive every path from definition to guard, including the preheader. Unknown calls,
raw writes, aliasing array writes, storage-retyping casts and handlers reject the proof. Scalar math natives are
recognized by actual library, symbol and signature. Runtime array-cast checks enforce concrete storage types.

HashLink emitted generated raw-access helpers. A JIT toggle made the same bytecode emit checked or unchecked
scaled loads on x86-64; other architectures used a native fallback. The pointer helper used an erased-array ABI
and moved the pointer to its typed result. No bytecode opcode or debugger schema changed. AArch64 was not tested.

GDB confirmed that App.advance lost exactly two array-size comparisons and two `jae` failure branches, while
loop termination comparisons remained. An exploratory core-0 perf sample counted 4,522,375,727 instructions off
and 4,370,592,826 on (3.36% fewer), with 1,657,745,636 versus 1,354,425,807 cycles. These busy-machine samples
confirmed the intended instruction reduction but did not predict a measurable median speedup.

Tests covered immutable inputs, no-op identity, serialization, incremental memo invalidation, changed native
bindings, erased/value-class exclusions and the inliner-off path. Weakening alias/call barriers, dropping the
preheader check or omitting native ABI metadata made a unit fail. Those pass-specific tests were removed with
the rejected pass; the census proof tests remain. The behavior fixture covers empty, Int, Float and object arrays,
aliasing, growth, shrinkage, exceptions and nested loops. Stock Haxe independently supplies its checksum 42,
and it passed Wasm parity. Full validation evidence is listed in `OPTIMIZATION_NEXT_RESULTS.md`.

The rejected tracked patches and pass-specific test sources are archived locally under
`out/optimization-next/rejected-*.patch`, `IrBoundsCheckElimination.hx` and `BoundsCheckEliminationMain.hx`.

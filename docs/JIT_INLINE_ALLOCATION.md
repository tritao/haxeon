# Guarded JIT object allocation

Stage 1 of [the bump allocation plan](BUMP_ALLOCATION_PLAN.md) passed its performance and correctness gates.
The implementation remains opt-in: `HL_JIT_ALLOC_INLINE=1` enables it at JIT initialization; unset or `0` uses ordinary
allocation calls. It applies only to Linux x86-64 SysV, ordinary non-debug modules, fixed HOBJ layouts of at most
40 bytes without bindings. Other objects and platforms retain the existing path. Nothing was pushed.

## Implementation and safety

A private `ALLOC_OBJECT` JIT operation expands into a guarded thread-local cursor bump and a cold allocator call.
There is no public bytecode opcode, compiler lowering change, object-layout change or cache-fingerprint change.
The allocator supplies the size-class stride, GC kind, TLS-relative offset and policy guards. TLS addresses are
resolved relative to the executing thread, rather than embedding the compiling thread's address.

The ordinary allocator and the JIT descriptor use one policy list: GC profiling/forced collection, census,
allocation callbacks and allocation tracking disable the fast path. A pending stop-the-world request also forces
the slow path. Runtime changes on the allocating thread take effect at its next allocation; concurrent changes
retain the existing allocator synchronization contract. There is no cached global eligibility bit.

JIT preparation computes layout only. An explicit prototype-completion flag is release-published after lazy
initialization finishes; zero-method types cannot use a non-null methods pointer as a readiness test. First
allocation therefore takes the normal allocator. The fast path clears the entire payload and size-class padding,
then writes the type header. It does not publish a blocking/safepoint state between reservation and initialization.
The collector waits for registered running threads to reach such a state before scanning them.

The cold stub clears its undefined result so a failed cursor bump cannot become a conservative GC root. It saves
allocatable caller-saved general registers and all scalar floating-point registers on the scanned stack, calls a
helper that services the GC safepoint and invokes ordinary allocation, then restores them. Callee-saved pointer
roots remain covered by the normal register-context scan. One JIT operation owns both result paths, preserving
try-block register bookkeeping. Modules using debugger mode keep ordinary calls and existing variable locations.

The conservative per-site cold stub increases code size. Sharing stubs or saving only live registers is deferred;
those changes need their own correctness and performance evidence. No field initialization is omitted in Stage 1.

## Paired performance gate

Identical bytecode, core 0, nine alternating baseline/candidate pairs per benchmark; one-minute load was at most
4 before and after each accepted sample. The baseline is the frozen pre-change VM/library, and the candidate uses
`HL_JIT_ALLOC_INLINE=1`. Benchmark output matched before timing. Builds and validation did not overlap timing.

| Benchmark | Baseline median (s) | Candidate median (s) | Improvement | Peak RSS baseline / candidate (KiB) |
|---|---:|---:|---:|---:|
| binarytrees | 0.810601 | 0.574274 | 29.15% | 97092 / 97112 |
| merkletrees | 0.293442 | 0.248573 | 15.29% | 81760 / 81760 |
| nbody | 0.220407 | 0.218459 | 0.88% | 6240 / 6240 |
| fasta | 0.421655 | 0.419958 | 0.40% | 81120 / 81120 |
| spectral-norm | 0.186937 | 0.183152 | 2.03% | 7520 / 7520 |
| lru | 0.094819 | 0.092216 | 2.74% | 7840 / 7840 |

Both trees comfortably clear the 5% gate. No benchmark regressed, and peak RSS was essentially unchanged.
Small differences in the other benchmarks do not establish a benefit. The cross-language table was not regenerated.

Separate diagnostic `perf stat` runs retired 16.610 G → 11.916 G instructions for binarytrees and 5.864 G → 4.833 G
for merkletrees. Page faults remained level (24122 → 24121 and 19957 → 19961); this change reduces allocator work,
rather than recovering the earlier page-retention benefit again. These are single counter runs, not paired medians.

The 24-byte allocation microbenchmark, five million iterations, improved from 0.067205 s to 0.042205 s (37.20%),
using nine alternating load-qualified pairs. A 1000-iteration diagnostic reduced ordinary object allocator calls
from 1004 to 16. Generated code grew from 2704 to 3792 bytes for binarytrees (+40.24%), and from 3280 to 4912 bytes
for the microbenchmark (+49.76%). JIT instruction/value/phi counters otherwise remained close.

With zero microbenchmark iterations, whole-process startup measured 3.657 ms → 3.845 ms (+0.188 ms, 5.15%).
This includes process startup and JIT compilation; it is noisy and does not isolate JIT latency. Separate JIT-only
latency, hot-patch latency and compiler build-time A/B measurements were not completed. The flag remains opt-in.

## Validation and mutation coverage

The final runtime passed:

- HashLink fixture sweeps: 326 fixtures in each mode.
- Compiler/runtime driver: 477 tests in each mode. The disabled mode also sets `HAXEON_INLINE=0`,
  `HAXEON_LOADSTORE=0` and `HAXEON_STRENGTH=0`.
- GC controls, collection pacing and thread stress: each run 20 times per mode, both normally and with
  `HL_GC_MIN_TRIGGER=65536` (240 executions total).
- Differential stock-Haxe bytecode suite and compiler self-hosting fixed point, with the feature enabled.
- Wasm backend and Wasm GC parity: 323 fixtures agreed, with 14 existing skips. The new allocation fixture
  was included. These suites ran once; the JIT switch does not affect Wasm.
- Workspace, compiler embedding, Git package-lock and DAP inline-configuration integration tests.
- Native allocation probe in both modes: dirty reuse and pointer padding, floating-point and pointer values
  across refill, type identity, and callback/census/tracking changes after compilation.

The new behavior fixture's independent stock Haxe interpreter reference returns 42. The native probe uses stock
Haxe bytecode. Mutation checks separately removed zeroing, padding clearing, the bounds guard, the correct type,
floating-point restoration, and callback/census/tracking guards; every mutation failed its test. Hook tests warm a
ready run before activating each hook, so an empty run cannot conceal a missing guard.

DAP stepping and scope checks were additionally compared with the switch off/on. Both retain the same existing
failures: stepping exits 5; scopes exits 1 on missing loop variables. They are not passes. The checks used the local
haxelib repository to avoid stale global package configuration. Other DAP scripts were not run. AArch64, Windows,
32-bit and GC_DEBUG/memcheck builds were not exercised; they retain the ordinary allocation path.

The enabled-only suites above were not repeated in disabled mode. There is no claim that every suite passed twice.

## Reproducibility

Local scripts, logs, counter runs, mutation builds and paired samples are under `out/inline-allocation/`.
`final-six.json`, `micro-timing.json`, `validation.log`, `mutations.log` and `frozen-hashes.json` contain the evidence.
The fixed benchmark bytecode comes from `out/optimization-next/` and the existing fasta profile build. Baseline main
repository revision was `58de932e`.

Frozen SHA-256 values:

| Artifact | Baseline | Candidate |
|---|---|---|
| VM | `005e7e20dc7a38c59ea2af6e016cc6b9154ed46a8188f4194d584cb92cde461a` | `86ba2be25f5256b1027ccf6916da093f2ba23b56de780165dcf66a5d952e9400` |
| libhl | `0825d0979866f9f5b8bbe8a9968f762148329f074db6e8b6e9801c607390c2f4` | `5f170fabb20238cd39ca986778ce4ecd841879f3ed4bcf64151f96b4e2b00618` |
| native runtime, both | `aaa3e4576dd17bc0d7b491161a0937cb4969227b5d322115e70e19766ad3240f` | same |

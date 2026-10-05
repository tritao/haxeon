# Compiler GC marking and refill experiments

The current candidate is opt-in **serial bitmap marking**, `HL_GC_MARK_SERIAL=1`, effective only with
`HL_GC_THREADS=1`. It reuses the existing non-atomic update that unthreaded HashLink builds already use.
The bitmap update stays atomic for multi-worker marking, and unsupported platforms keep their old path. The switch defaults off.
Final load-qualified performance acceptance is pending; diagnostic results below are not acceptance timings.
The opt-in candidate is fork commit `76f4f7cf`; `16a42e3e` bumps the submodule and registers the tests.

## Baseline and profiling

The [array profile](ARRAY_ALLOCATION_PROFILE.md) put `gc_flush_mark` at 44.91% of compiler CPU samples.
The compiler is stock-Haxe-built `HaxeonCompiler`, compiling 461 of its own source files from the self-hosting list.
Baseline: main `60125e2c`, fork `d7f0620a`, guarded object and integer-box allocation enabled, bounded empty-page
retention enabled with a 64 MiB cap. No `HL_GC_PROFILE` was used for timing; it disables TLABs and adds overhead.

`perf annotate` on the production profile attributed 16.59% and 4.68% of mark-function samples to its two locked
compare/exchange sites. Sampling skid limits interpreting individual instructions: this suggests a target, rather
than proving that 21% of mark time can be removed. The header load had 25.67% of mark samples; page lookup and
block identification remain substantial work regardless of how the bitmap is updated.

A separate scratch collector counted successful block-ID checks, already-marked observations, words visited,
metadata skips and objects scanned. Counts aggregate once per flush, with local counters during scanning;
observations read the bitmap atomically. A racing claim after that read is not counted as already marked.
Instrumentation overhead and potentially different collection scheduling make these descriptive counts rather than
a timing or a precise count of redundant atomic operations in an uninstrumented run.

| Counter | Compiler run |
|---|---:|
| Valid block-ID checks | 592,445,996 |
| Already-marked observations | 207,112,001 |
| Words visited | 1,209,842,311 |
| Words skipped by precise metadata | 218,596,139 |
| Objects scanned | 318,488,925 |

Already-marked observations were 34.96% of valid checks.

The refill profile separately identifies bitmap/free-list reconstruction. A scratch census found 367,267,305
free-list loop visits and 13,330,672 eligible fully live bitmap bytes. Skipping each such byte would avoid seven
additional slot visits (about 25.4% of those visits). Existing free ranges and variable-size allocation boundaries
must still be preserved; bitmap contents alone cannot override an old free range.

## Experiments

All variants were built as scratch libraries from copied collector/allocator sources and existing release objects.
No rejected variant was installed or committed. Three alternating compiler pairs per variant, core 0, collected
whole-process wall/user time, instructions/cycles and RSS. Output bytecode matched the baseline SHA-256 on every
run. Load was above the acceptance limit, ranging roughly from 7 to 38; wall/cycle differences are not reliable
speedup claims. Hardware instruction counts provide supporting diagnostics, not a substitute for quiet timing.

| Experiment | Comparator | Instructions off / on (billions) | Instruction reduction | Diagnostic user CPU off / on (s) |
|---|---|---:|---:|---:|
| Read-before-atomic check | Same scratch library, switch off/on | 196.989 / 196.464 | 0.27% | 18.46 / 18.34 |
| CAS loop with per-claim switch | Same scratch library, switch off/on | 199.863 / 196.838 | 1.51% | 18.09 / 17.67 |
| CAS loop without hot switch | Unchanged runtime / scratch | 195.241 / 194.855 | 0.20% | 22.62 / 23.88 |
| Skip full live bitmap bytes | Same scratch library, switch off/on | 194.639 / 193.415 | 0.63% | 17.88 / 18.43 |
| Non-atomic single-worker marking | Unchanged runtime / scratch; one worker both | 195.056 / 193.105 | 1.00% | 17.74 / 17.04 |

The read-before-atomic check did not establish worthwhile compiler benefit. The switched CAS loop looked better
against its own disabled mode, but that disabled mode itself added instructions; comparison against the unchanged
runtime reduced instructions by only 0.20%. The sweep-byte experiment reduced instructions by 0.63% but did not
establish a repeatable timing gain. None of these three variants is retained. This is a diagnostic selection decision,
not a claim that they failed a completed nine-pair acceptance gate.

The single-worker prototype reduced instructions by 1.00%. Its loaded compiler medians were 18.63 -> 17.62 s wall
(5.42%) and 17.74 -> 17.04 s user CPU (3.95%), with unchanged median peak RSS (1,096,080 KiB). It warrants
correctness validation and quiet measurement. The production candidate adds the independent switch/guard, so the
prototype figures must not be presented as validated production-candidate performance.

## Sharing microbenchmark

A stock-Haxe bytecode program builds 400,000 cells, each with two aliases to its predecessor and a shared third
reference, then forces twelve major collections and verifies the entire graph. Its expected count, checksum and
value were obtained with the stock Haxe interpreter, omitting only the unavailable HL collection calls there.
The bytecode actually invokes those calls on the VM. Five alternating diagnostic pairs per mode used one or four
mark workers; load remained high. This is an isolated sharing pattern, not an acceptance workload.

| Kernel change | Workers | Instructions off / on (billions) | Cycles off / on (millions) |
|---|---:|---:|---:|
| CAS loop | 1 | 1.516 / 1.467 | 612.3 / 475.4 |
| CAS loop | 4 | 1.515 / 1.458 | 599.0 / 441.0 |
| Serial update | 1 | 1.517 / 1.472 | 559.0 / 377.0 |
| Serial update | 4 | 1.513 / 1.522 | 554.1 / 574.7 |

CAS helps the synthetic heavily shared graph much more than the compiler. The serial update's four-worker path
remains atomic, so that row measures collateral code/layout/guard effects rather than a serial optimization.
This reinforces the need for the broad workload and default-mode gates.

## Candidate design and safety

`HL_GC_MARK_SERIAL=1` accepts exactly `1`; its enablement is compiled only for Linux x86-64 GCC-compatible builds.
Other configurations retain their existing path. `atomic_bit_set` uses the existing plain read/test/OR/store only
when the flag is enabled **and the configured mark-worker count is exactly one**. The built-in unthreaded case is
unchanged. With multiple workers, the existing atomic claim remains, even with the flag set.

The collector stops mutators before tracing. With one worker, no other marker writes the bitmap. `gc_mark_threads`
is initialized once, and the runtime exposes no setter that changes it during collection. Dispatch is used only for
multiple workers, so its active-thread bitmask never takes the new serial path. `atomic_bit_unset` is unchanged.
No object layout, roots, register scanning, mark metadata, collection threshold, allocation accounting, bytecode or
compiler fingerprint changed. Neither automatic affinity-based worker selection nor multi-worker CAS was added.
`HL_GC_THREADS=1` remains an explicit setting; the serial switch does not reduce the worker count itself.

The shared-graph behavior fixture includes duplicate edges, a shared self-cycle, sixteen forced collections and
allocation churn. Its independent stock-Haxe-interpreter result is 42. It is registered in the fixture manifest.
The native bitmap test exports the actual private helper only from a scratch copied collector, adding no production
API. One-worker tests check sequential unique/repeated claims. Four-worker tests use eight simultaneous native
threads claiming unique and shared bits for 2,000 barrier-controlled rounds, checking the final byte and winner count.
This test is registered in the runtime catalog and has a standalone integration runner.

Mutation: removing the one-worker guard caused the concurrent test to fail (191 bad rounds in the first probe;
exit 1). Removing the bitmap store caused the sequential probe to fail with exit 1. Both mutations were confined
to scratch libraries; the production source was never weakened.

## Validation and remaining gate

Correctness validation passed:

- Four non-Wasm fixture sweeps: 328/328 each, both flag values and default/disabled inliner, one mark worker.
- Four compiler/runtime driver runs: 480/480 for the first two flag-enabled runs, 481/481 for the later two
  flag-disabled runs after registering the native runtime test; default and disabled compiler modes both passed.
- The new native runtime wrapper was then compiled/executed separately in all four compiler/flag combinations.
- 1,280 GC stress executions, as detailed below.
- Differential suites and self-hosting fixed point, enabled/default and disabled compiler/feature modes.
- Wasm backend and Wasm GC parity: 325 fixtures agreed across HL/Wasm32/Wasm GC, 14 existing skips.
- Workspace, compiler embedding/incremental execution, Git package lock and DAP inline-configuration integration.
- Native bitmap probes and both isolated mutations described above.

Disabled compiler modes set `HAXEON_INLINE=0 HAXEON_LOADSTORE=0 HAXEON_STRENGTH=0`. Guarded object/box
allocation stayed enabled. The global test configuration used one marker; stress and native probes additionally
covered four markers. No additional DAP stepping/scope comparison was run.

The stress matrix covers both compiler modes, both flag values, one/four mark workers, default/65,536-byte trigger,
and four fixtures x20: controls, pacing, mutator-thread stress and the new shared graph. The concurrency probe also
passed all four flag/worker configurations. The new runtime catalog entry was added after the first two driver runs;
those were 480/480, and later runs include it at 481/481. It was already exercised separately in all four configurations.

Final performance acceptance remains pending (the first quiet-window compiler pairs crossed the load limit and
were discarded): nine alternating pairs for all six benchmarks and compiler
self-compilation, fixed bytecode, core 0, one-minute load <=4 before and after accepted samples. Both sides use
`HL_GC_THREADS=1`. A default-worker/flag-disabled LRU library-placement control is also queued. No build or
validation work may overlap these acceptance samples. Startup/JIT CPU/wall latency pairs are queued after the full-workload pairs, using the scratch initial-JIT timer
from the boxing study; no hot-patch latency measurement has been made. The runtime stays opt-in until these gates establish benefit without regressions.

AArch64, Windows, 32-bit, Clang, GC_DEBUG/memcheck and additional DAP stepping/scope tests are untested. The
source gates unsupported platforms to the old behavior. The older integer-box acceptance timing jobs remain
queued separately; these loaded diagnostics do not finish that earlier gate.

## Evidence

Raw counters, copied-source build runners, profiles/annotations, three-pair diagnostic samples, sharing micro,
mutation probes, full-suite logs, final frozen artifacts and hashes are under `out/compiler-gc-profile/`.
Compiler input bytecode SHA-256 is `6315b26a92a7ff700650c021357c9acbdc8ec4010509655453b5856a57f7a3a2`;
all diagnostic compiler outputs matched `975ea9291b0e380cd92620fb1ded6bfc91ca4b7251c247c00da5693ade6f2454`.
`final-hashes.json` identifies the production candidate used by the queued gate. Nothing has been pushed.

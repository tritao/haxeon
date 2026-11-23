# Benchmarks and profiling Haxeon

Measuring Haxeon itself, from a checkout: the edit-to-runtime benchmark, the experiments it rejected, and profiling the
compiler and the recorder. Profiling a program or an app is in [PROFILING.md](../reference/PROFILING.md).

Run the repeatable edit-to-runtime benchmark from the checkout's root (`haxeon dev run` builds `benchmarks/BenchmarkMain.hx`
with the compiler's sources through the tool cache and runs it on the checkout's VM):

```sh
scripts/haxeon dev run --cp benchmarks BenchmarkMain
```

It reports median, p95, and p99 latency for cold compilation, no-op rebuilds,
body patches, signature reloads, and structural reloads. It also runs a patch
soak test and writes machine-readable results to `out/benchmark.json`.

Attribute soak-test memory growth with isolated compiler and runtime passes:

```sh
scripts/haxeon dev run --cp benchmarks BenchmarkMain --only-soak --soak-mode compiler \
  --json out/benchmark-compiler.json
scripts/haxeon dev run --cp benchmarks BenchmarkMain --only-soak --soak-mode runtime \
  --json out/benchmark-runtime.json
```

Generate scaling results and compare two runs:

```sh
scripts/haxeon dev run --cp benchmarks BenchmarkMain --only-scale --json out/benchmark-scale.json
python3 benchmarks/compare.py baseline.json out/benchmark-scale.json
```

Use `--iterations`, `--warmup`, `--soak`, `--scales`, and
`--scale-iterations` to tune a run. Benchmark comparisons are informational and
do not enforce thresholds.

## Tried and rejected

Runtime experiments that failed their gate and were removed, measured in October 2026 on the six benchmarks
(binarytrees, merkletrees, nbody, fasta, spectral-norm, lru). Retry one only with new evidence, such as a hot site in real
code. The reports in git history (`docs/reports/2026-10-*`) have the method and the raw numbers.

| Experiment | Gate | Result |
|---|---|---|
| Counted-loop bounds-check elimination | 3% | best 0.78%, fasta 6.44% slower; `IrLoopBounds` stays as analysis for the census |
| Fused array writes | a hot target | no material `ArraySet` in fasta or nbody; not built |
| Inlining fasta's branching search function | 3% on fasta | 0.85% slower: the larger frame cost more than the call |
| Ordered float comparisons in the x86-64 JIT (no parity branch) | 3% on fasta | 0.17% |
| A checked `Bytes.set` fast path in the JIT | 3% on fasta | 1.91% |
| GC locality: mark prefetch, address-ordered runs, sweep order | 5% on a tree benchmark | within ±0.3% |
| Thin native object-allocation entry | 5% on a tree benchmark | 1.13% slower on binarytrees |
| JIT-prepared object-allocation helper | 5% on a tree benchmark | 2.29% on binarytrees |
| Skipping redundant field clearing after inline allocation | 2% on binarytrees | 1.67% slower |
| A JIT fast path for small arrays | headroom first | under 1% of compiler CPU removable; not built |

Accepted results are in [the bump allocation plan](../reports/2026-10-bump-allocation-plan.md), the JIT register allocation
[results](../reports/2026-10-jit-register-allocation-results.md), [empty GC page retention](../reports/2026-10-gc-empty-page-retention.md)
and [the allocation fast path](../reports/2026-10-gc-allocation-profile.md).


## Compiler profiling

To profile incremental compiler edits, pass `--profile-output` to the project
benchmark. It starts a dedicated worker with a diagnostics port, warms that
worker before attaching, and captures the edit loop. The normal worker launch
is unchanged. Sampling adds overhead, so use an unprofiled run for latency
comparisons. For where the compiler allocates, record with
`--sources alloc` and read it with `report --alloc`; the compiler's per-phase
allocation counters (`HL_GC_PROFILE=1`) give exact totals.

```sh
python3 benchmarks/incremental-project.py \
  --project /path/to/haxeon.toml --source /path/to/Main.hx \
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

### What sets the compiler's peak memory

A one-shot compile collects after every gigabyte allocated (`ProcessMemory`), so just before a collection the heap holds
what the last collection kept plus a gigabyte since. The peak is that, at the collection where it is largest, plus pages the
phases after it could not reuse. `scripts/peak-timeline.py` shows which collection it is and what the heap holds there:

```sh
H=out/sdk/bin/hl
ARGS="compiler.hl --entry=compiler.tools.HaxeonCompiler --root=src --root=lib/haxeon-io --root=stdlib --sources-file=srcs.txt --output=/tmp/out.hl"
scripts/peak-timeline.py -- $H $ARGS                          # resident memory at each phase mark and collection, and the peak
scripts/peak-timeline.py HL_GC_CENSUS_AT=0 -- $H $ARGS        # census inside every collection: what each one keeps
scripts/peak-timeline.py HAXEON_PEAK_CENSUS=ir-done -- $H $ARGS   # census at a phase mark (collects first)
scripts/peak-timeline.py HAXEON_PEAK_CENSUS=all HL_GC_CENSUS_NOGC=1 -- $H $ARGS   # pages per size class at every mark
```

The phase marks (`compiler.core.PeakProbe`) and the census (`hl_gc_census` in the fork's `gc_census.c`) cost nothing unless
those variables are set. A census prints, as `census` lines in the log, live bytes by type, by nearest owner (arrays,
maps and strings are charged to the object holding them) and by path from the roots with field names, and per size class
the pages mapped, resident and live. Live data at a collection raises every later peak by its size; data that dies between
two collections still counts at the second one, so releasing it earlier only helps if a collection runs in between.


### Raw two-terminal workflow

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

## Bytecode size

`haxeon dev hl-stat MODULE` reads a HashLink module (with `compiler.hl.HlModuleReader`, which follows the VM's loader and
reads stock Haxe's modules too) and reports what it is made of: the bytes of each part (strings, types, globals and natives,
function instructions, debug lines, debug sections), function, instruction and register counts, and on request the most
frequent opcodes (`--ops`), the largest functions (`--top N`), one function's instructions (`--dump NAME`), the opcodes
around one (`--around OSwitch`) and the debug sections (`--sections`). HashLink compiles every instruction of a module when
it loads it, so instruction counts are start-up time; `HL_JIT_REGSTATS=1 hl MODULE` reports what the JIT made of them.
Comparing a module the stock-Haxe-built compiler wrote with one the Haxeon-built compiler wrote shows where ours is bigger:

```sh
scripts/haxeon dev hl-stat out/server-stock.hl --ops 20 --top 10
scripts/haxeon dev hl-stat out/server-haxeon.hl --ops 20 --top 10
```

## Recorder cost

`hlprof-bench` measures what the recorder costs a program: an enter/exit pair
and a span with recording off and on, on one and four threads, and the rate at
which a consumer drains the records. Run it after changing `vendor/hashlink/src/prof.c`.
It takes an optional iteration count (default 20000000):

```sh
out/cmake/windows-msvc/hashlink/bin/hlprof-bench.exe [ITERATIONS]
```

The program has libhl compiled in. Results
are nanoseconds per operation; `../design/PROFILER_DESIGN.md` lists the reference figures. The
last line reports the consumer's drain rate and any stalls.

# Benchmarks

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


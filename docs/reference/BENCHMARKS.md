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


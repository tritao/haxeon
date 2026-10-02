# Benchmarks

Run the repeatable edit-to-runtime benchmark:

```sh
./scripts/benchmark.sh
```

It reports median, p95, and p99 latency for cold compilation, no-op rebuilds,
body patches, signature reloads, and structural reloads. It also runs a patch
soak test and writes machine-readable results to `out/benchmark.json`.

Attribute soak-test memory growth with isolated compiler and runtime passes:

```sh
./scripts/benchmark.sh --only-soak --soak-mode compiler \
  --json out/benchmark-compiler.json
./scripts/benchmark.sh --only-soak --soak-mode runtime \
  --json out/benchmark-runtime.json
```

Generate scaling results and compare two runs:

```sh
./scripts/benchmark.sh --only-scale --json out/benchmark-scale.json
./scripts/benchmark-compare.sh baseline.json out/benchmark-scale.json
```

Use `--iterations`, `--warmup`, `--soak`, `--scales`, and
`--scale-iterations` to tune a run. Benchmark comparisons are informational and
do not enforce thresholds.


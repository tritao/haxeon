# Haxeon workspace benchmark

`benchmarks/editor-benchmark.hxml` measures the compiler/editor against
workload shapes rather than a particular downstream consumer.

The report contains a `scenarios` object. The current profiles are:

- `small-project`: the checked-in `tests/fixtures/workspace-small` corpus with
  packages, imports, interfaces, callbacks, maps, a malformed member query,
  definition, repair, and analysis.
- `generated-N-fanout`: independent modules imported by one entry module.
- `generated-N-chain`: a dependency chain ending at the entry module.
- `generated-N-diamond`: two branches joined by a shared downstream module.

Each profile records edit and completion percentiles plus:

- modules invalidated;
- signature-edit invalidation closure size;
- modules analyzed;
- unchanged typed classes reused;
- functions retyped;
- recovered snapshots rebuilt;
- process-memory growth for the endurance workload.

Each generated profile also contains an `editMatrix` with independent
body-only, public-signature, field-type, import, base-class, interface,
add-declaration, remove-declaration, malformed-intermediate, and repair edits.
Every edit records update/follow-up latency and work-scope metrics, including
unchanged typed classes reused, and the runner asserts the expected
invalidation set for the generated topology.

By default the budgeted runner executes the generated size matrix `8,64` across
fan-out, chain, and diamond topologies. Select one topology with the compatible
`--scale-topology=fanout|chain|diamond` option, or provide a comma-separated
sweep with `--scale-topologies=fanout,chain,diamond`. Select a larger size
matrix with `--scale-sizes=8,64,256`; the older `--scale-modules=64` option
remains as a compatibility shortcut for one size. Use `--endurance-modules`
and `--endurance-topology` to choose the workload receiving the long-lived edit
loop. The generic benchmark has no consumer-specific paths or report fields. A
real consumer such as Pragtical belongs in an optional integration workload and
can reuse these scenario and probe conventions without changing the core
report.

Generated scenarios assert the invalidation closure as well as recording its
size: body-only edits must invalidate only the entry module, while declaration,
field, base-class, and interface edits follow the topology-specific transitive
closure among modules reachable from the entry point. Each edit class starts
from a fresh baseline so the result is independent of matrix ordering.

Example:

```sh
./.tools/haxe/haxe benchmarks/editor-benchmark.hxml
LD_LIBRARY_PATH=.tools/hashlink:out ./.tools/hashlink/hl out/editor-benchmark.hl \
  --check-budgets --scale-modules=64 --scale-topology=diamond
```

To include the 256-module scale probe with a shorter endurance pass:

```sh
LD_LIBRARY_PATH=.tools/hashlink:out ./.tools/hashlink/hl out/editor-benchmark.hl \
  --scale-sizes=8,64,256 --scale-topologies=fanout,chain,diamond \
  --endurance-modules=64 --endurance-topology=diamond
```

The 256-module fan-out currently exceeds the 500 ms generated-workspace
budget, so adding `--check-budgets` to this larger probe intentionally exposes
the next scaling target rather than masking it.

Compare two reports and fail when the candidate does unnecessary work:

```sh
./scripts/benchmark-compare.sh baseline.json out/editor-benchmark.json
```

The comparator checks p95/p99 and scalar measurements for latency, memory
growth, invalidated/analyzed modules, retyped functions, recovered snapshots,
and reused classes. Work-scope changes are strict by default; tune noisy
measurements with `--latency-tolerance-pct`, `--memory-tolerance-pct`, and
`--reuse-tolerance-pct`. Use `--work-tolerance` for an explicitly accepted
increase in work, `--report-only` to suppress the failing exit status, or
`--format=json` for CI artifacts.

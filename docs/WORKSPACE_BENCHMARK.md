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
- modules analyzed;
- functions retyped;
- recovered snapshots rebuilt;
- process-memory growth for the endurance workload.

The generated topology is selected with `--scale-topology=fanout|chain|diamond`.
By default the budgeted runner executes the generated size matrix `8,64`; select
a larger matrix with `--scale-sizes=8,64,256`. The older
`--scale-modules=64` option remains as a compatibility shortcut for one size.
Use `--endurance-modules` to choose which matrix size receives the long-lived
edit loop. The generic benchmark has no consumer-specific paths or report
fields. A real consumer such as Pragtical belongs in an optional integration
workload and can reuse these scenario and probe conventions without changing
the core report.

Example:

```sh
./.tools/haxe/haxe benchmarks/editor-benchmark.hxml
LD_LIBRARY_PATH=.tools/hashlink:out ./.tools/hashlink/hl out/editor-benchmark.hl \
  --check-budgets --scale-modules=64 --scale-topology=diamond
```

To include the 256-module scale probe with a shorter endurance pass:

```sh
LD_LIBRARY_PATH=.tools/hashlink:out ./.tools/hashlink/hl out/editor-benchmark.hl \
  --scale-sizes=8,64,256 --endurance-modules=64
```

The 256-module fan-out currently exceeds the 500 ms generated-workspace
budget, so adding `--check-budgets` to this larger probe intentionally exposes
the next scaling target rather than masking it.

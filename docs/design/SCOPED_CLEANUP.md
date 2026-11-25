# Scoped cleanup: porting and measurements (design note)

Contributor notes on [scoped cleanup](../reference/SCOPED_CLEANUP.md) that are not part of the user reference: where the
compiler's own sources still use the older forms, and what the feature measured when it was merged.

## Port when the compiler is built only by Haxeon

The pinned stock-Haxe bootstrap must still parse compiler sources. Its cleanup sites therefore keep their existing
forms until the compiler is built only by Haxeon: `HlWriter.writeFile` closes its Haxe output, the stock-Haxe branches
of `ProcessOutputCapture` close processes and signal readers, `CompilerServer` closes its files and sockets and signals
its worker, and `CancellationToken` releases its mutex. The existing Haxeon-only subprocess capture path can use
`defer` now without changing the bootstrap.

## Editor measurement at integration

On the same machine, nine alternating pre-merge/merged runs measured these median allocations and frame times. Both
builds used the new HashLink runtime. Times are observations, not new budgets.

| Action | KiB before → after | ms before → after |
| --- | ---: | ---: |
| console → telemetry | 72.5 → 74.5 | 1.11 → 1.15 |
| hierarchy → sensors | 112.6 → 112.6 | 1.61 → 1.64 |
| sensors → hierarchy | 80.1 → 80.1 | 1.22 → 1.25 |
| telemetry → console | 92.9 → 92.9 | 1.16 → 1.18 |
| hover away | 13.6 → 13.6 | 0.45 → 0.46 |
| hover enter / inside | 0.5 → 0.5 | 0 → 0 |
| hover field | 12.4 → 12.4 | 0.46 → 0.46 |
| hover other | 10.0 → 10.0 | 0.45 → 0.45 |
| idle / idle focused | 0.2 → 0.2 | 0.01 → 0.01 |
| scroll inspector | 21.2 → 21.2 | 0.74 → 0.75 |
| type backspace | 16.2 → 16.2 | 0.44 → 0.44 |
| type character | 16.1 → 16.1 | 0.45 → 0.45 |
| selection | not reported | 3.07 → 3.07 |

The console action's 2 KiB median increase is a finding in that run. An instrumented exact-window diagnostic of 29 warm
console-to-telemetry actions per tree recorded identical distributions (28 at 75,800 bytes, one at 80,312 bytes),
33,522 allocations and 2,204,568 bytes on each tree, with identical allocation types and sampled call-site groups.
That diagnostic points away from a persistent cleanup allocation but does not replace the original measurement.
The selection census differed only in variable byte buffers, by -1, 0 and +1 allocations in three pairs. Three paired
500-cycle RSS runs passed; their fourth-window median changed from 4.84 to 5.00 MiB. Wasm GC Showcase object counts
were unchanged: 4,440 for full, static and text-heavy scenes and 8,724 for editing. Both Wasm Showcase smoke tests,
the compiler and UI suites, editor retention and performance budgets, and the headless memory gate passed.

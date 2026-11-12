# Structs: November 2026 measurement history

## Widening trial measurements

The preliminary widening candidate still allocated one 24-byte `TextEditIntent` for `type-char`: three paired control/candidate runs
had 835 objects each and median totals of 60,064 / 60,056 bytes. It does not regress, but does not unlock the enum.
Its remaining trace includes checked casts and runtime descriptors for virtual contracts, for example
`$checked-dynamic-cast:Virtual(haxeon.ui.core.View)`. These uses also appear in generic-erased interface code; resolving
them needs the deferred E3 virtual-call/type-check and E7 descriptor work, rather than one local escape adapter.
Control/candidate editor builds took 148,925 / 141,789 ms; self-hosting stage-1 `BodyTyped` took 51.53 / 41.22 ms.
The candidate's corresponding editor `BodyTyped` phase was 1,249 / 1,207 ms. Record the enum as still blocked and
continue with the measured UI allocation site rather than widening E3/E7 in this session. E4 nullable closures and E8
generic transport do not block this measured finite enum. Next, investigate why one tab switch constructs 54 `DockNode`
values and reuse unchanged persistent dock-tree branches in the UI rather than changing their compiler representation.
`DockNode.Split` contains `DockNode` directly
by value; its cost cannot justify bypassing the permanent recursive-enum classification. Then perform the UI value
enum conversions, with measured deltas for allocating forms and the required type-honesty ports for the others.
Byte-identical editor/Web output skips paired measurements under Tier 3. Do not count a setup control or a renamed
allocation as an enum win.

## UI sizing trial records

The complete trial patch, path manifest, reproduction source, exact census summary and eligibility trace are preserved
under `haxeon-enum-work/layout-sizing-payload-trial-2026-11-09/` in the session's disk scratch directory. The source
conversion was restored, so this record changes no shipped representation. The sizing conversion remains unfinished.

Records: `haxeon-flat-work/enum-impact/{editor,showcase-gc,showcase-w32}-eligibility.json`,
`diagnostic-artifacts.json`, `action-inventory.jsonl` and `action-census-harness.patch`. The existing aggregate records
are in `typed-interface-tables-gates/paired-exact-tabs.jsonl`,
`interface-value-gates/paired-exact-interaction-v2.jsonl` and `enum-first-batch-gates/paired-census.jsonl`.

### Enum equality checkpoint measurements (candidate)

On the same machine, the starting baseline was Haxeon `ca255ae6` and outer `045d3585c`. The candidate keeps the
existing boxed enum layout while adding declared equality and specialized generic enum descriptors. Allocation medians
are KiB per action:

| Action | Starting baseline | Candidate |
| --- | ---: | ---: |
| hierarchy → sensors | 114.6 | 112.6 |
| sensors → hierarchy | 80.1 | 78.1 |
| console → telemetry | 74.5 | 74.5 |
| telemetry → console | 92.9 | 92.9 |
| hover enter / inside | 0.5 / 0.5 | 0.5 / 0.5 |
| hover other / field / away | 10.0 / 12.4 / 13.6 | 10.0 / 12.4 / 13.6 |
| scroll inspector | 21.2 | 21.2 |
| idle / idle focused | 0.2 / 0.2 | 0.2 / 0.2 |
| type character / backspace | 16.1 / 16.6 | 16.1 / 16.2 |

The 30-cycle selection-stress census measured 342,877 allocations at the starting baseline and 342,100 in the candidate;
five alternating pairs against the previous semantic checkpoint had a median of 342,098 on each side. Wasm GC Showcase
object counts were 5,896 / 5,896 / 5,896 / 12,835 at baseline and 5,896 / 5,896 / 5,896 / 12,622 in the candidate
(full, static, text-heavy, editing; the baseline editing repeats were 12,835 / 12,833 / 12,835).

The nine starting-baseline headless RSS window medians were [30.47, 4.06, 0.94, 4.69] MiB. In 27 alternating pairs
against the previous semantic checkpoint, control medians were [30.00, 3.59, 0.78, 4.84] and candidate medians were
[29.84, 3.75, 0.78, 5.00] MiB; median paired differences were [-0.16, 0.16, 0.00, 0.00] MiB. A separate 27-pair
calibration using identical control bytecode on both sides produced medians [30.00, 3.75, 0.78, 5.00] and
[30.00, 3.75, 0.78, 4.84] MiB, with a -0.15 MiB median paired difference in the fourth window. The second-window
candidate difference is not explained by that calibration and remains an open measurement. A matched 500-cycle census
recorded 1,825,372 versus 1,825,376 allocations; the four extra allocations were 1,424 bytes of byte buffers. A
30-cycle every-allocation stack census attributed differences to `JsonPrinter` and headless profile output, but does not
prove the cause of the RSS difference. No ceiling was raised. Inline enum lowering and its allocation measurements remain
pending.

After adding native-signature descriptor discovery, the same action medians were unchanged and the selection census was
342,098. The Wasm GC Showcase counts were 5,894 / 5,896 / 5,896 / 12,620. In 27 alternating pairs against the same
previous semantic checkpoint, both control and candidate had RSS window medians [29.84, 3.75, 0.78, 5.00] MiB; the
median paired differences were [0.15, 0.00, 0.00, 0.00] MiB. A matched 500-cycle allocation census recorded 1,825,380
versus 1,825,371 allocations and 151,717,696 versus 151,715,344 bytes; all of the difference was in byte buffers.
The `+0.15` MiB paired first-window difference remains visible even though the window medians match; it is not claimed
as a measured improvement.

After removing the extra Dynamic enum wrapper and rejecting enum ordering in `Reflect.compare`, the Wasm GC Showcase
counts were 5,896 / 5,896 / 5,896 / 12,622 (full, static, text-heavy, editing). The same-machine starting baseline
was 5,896 / 5,896 / 5,896 / 12,835. The interaction allocation medians in the table above were unchanged in five alternating
interaction pairs against the previous semantic checkpoint; one separate candidate capture measured hover-away at
12.1 KiB, but four of five paired captures measured 13.6 KiB, so its ceiling was not lowered. Selection stress counted
342,098 allocations. Its `@haxeon.ui.TextStyle` and `@haxeon.ui.ParagraphStyle` counts were 140 each; the starting
baseline had 161 and 140 respectively, plus 240 `@haxeon.ui.widgets.docking.DockTextWidthKey` allocations, now zero.

For the same revision, 27 alternating RSS pairs against the previous semantic checkpoint gave control window medians
[30.00, 3.91, 0.78, 4.84] MiB and candidate medians [30.00, 3.59, 0.78, 4.84] MiB, with median paired differences
[+0.16, -0.15, 0.00, 0.00] MiB. A separate 27-pair calibration using identical control bytecode on both sides gave
paired differences [-0.15, +0.15, 0.00, 0.00] MiB. Three alternating allocation-census pairs around the affected
window gave 100-cycle control/candidate medians of 399,162 / 399,161 allocations and 32,784,344 / 32,784,600 bytes,
and 200-cycle medians of 755,678 / 755,673 allocations and 62,475,528 / 62,474,784 bytes. These results show
page-scale variation and no material increase in counted allocations, but the positive paired first-window difference
remains visible; it is not reported as a measured improvement.

The candidate now removes reflective enum helpers that no `Type.enumEq` operation can reach, while preserving the
concrete descriptors used by Dynamic equality. Nested typed reflection and adding reflection during an incremental
compile have dedicated tests. In the editor profile this removed 201 helpers and reduced bytecode from 102,820,303 to
102,226,757 bytes. A fresh 27-pair RSS comparison against the same control had window medians [30.00, 3.59, 0.78, 4.84]
MiB for control and [30.16, 3.59, 0.78, 4.84] MiB for the reduced candidate; median paired differences were
[-0.31, 0.00, 0.00, 0.00] MiB. The starting-baseline fourth-window median was 4.69 MiB; both current group medians are
0.15 MiB higher, within the page-scale variation shown by the identical-bytecode calibrations above. The measured
numbers are retained here rather than presenting the first-window paired result as a general RSS improvement.

The reduced candidate's first interaction capture reported hover-field at 12.6 KiB versus the starting 12.4 KiB. In a
fixed nine-pair comparison, the median was 12.4 KiB on both sides and one capture on each side reported 12.6 KiB; all
other interaction allocation medians matched. The 30-cycle selection census was 342,099 allocations, with 140
`@haxeon.ui.TextStyle` and 140 `@haxeon.ui.ParagraphStyle` allocations. No budget ceiling was raised or lowered on the
basis of the variable hover measurements.


After the struct-array iterator and verifier fixes, the semantic-equality candidate was measured again against the
previous lane-safe editor build. Nine alternating interaction pairs had identical per-action allocation medians; a
single candidate backspace sample was 16.6 KiB while the paired median was 16.2 KiB on both sides. Nine alternating
selection-stress censuses had medians of 342,097 allocations on both sides and a paired median difference of +1. The
original selection baseline was 342,877. Nine alternating 500-cycle headless RSS captures had control window medians
[30.00, 3.91, 0.78, 5.00] MiB and candidate medians [30.31, 3.59, 0.78, 4.84] MiB, with paired median differences
[+0.62, 0.00, 0.00, 0.00] MiB. The first-window difference remains an open measurement; prior identical-bytecode
calibration showed page-level variation, but does not establish the cause of this result. Five alternating Wasm GC
Showcase pairs had equal full and text-heavy medians of 5,896 objects; one control text-heavy sample had 5,894.
Static and editing counts were 5,896 and 12,622 respectively. No performance ceiling was raised.


After porting the application and libraries from reflective enum comparison to declared conformance and case
patterns, nine alternating pairs against the preceding enum checkpoint had the same allocation median for every
action in the table above. The selection-stress census medians were 342,097 on both sides (paired median delta zero);
its candidate had 140 `@haxeon.ui.TextStyle`, 140 `@haxeon.ui.ParagraphStyle`, and no
`@haxeon.ui.widgets.docking.DockTextWidthKey` allocations. The two tab allocation ceilings were lowered to retain the
measured reduction from the starting baseline.

In nine paired 500-cycle headless captures, control and candidate RSS window medians were
[29.84, 3.75, 0.78, 4.84] and [30.16, 3.75, 0.78, 5.00] MiB, with paired median differences
[+0.31, +0.16, 0.00, +0.16] MiB. A separate nine-pair identical-bytecode calibration had window medians
[30.16, 3.59, 0.78, 5.00] and [29.84, 3.91, 0.78, 5.00] MiB, with paired differences
[-0.31, +0.47, 0.00, 0.00] MiB. The fourth-window candidate difference remains visible; these measurements do not
prove an RSS improvement. Five paired allocation censuses of the same workload had control/candidate medians of
1,825,370 / 1,825,374 allocations and a paired median difference of +6. Three further type comparisons found only
byte-buffer differences, of -6, -4, and +3 allocations; their source is not established. The 30-cycle selection
census type comparison found only 176 additional byte-buffer bytes and no allocation-count difference.

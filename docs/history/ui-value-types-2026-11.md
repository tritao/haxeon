# UI value types: November 2026 checkpoint history

## Initial value-conversion measurements

The item 2 same-machine per-action comparison uses the pre-conversion baseline and a 30-cycle measured run. Values are
allocated KiB per action, rounded to one decimal:

| Action | Baseline | After conversion |
| --- | ---: | ---: |
| console → telemetry | 77.5 | 75.4 |
| hierarchy → sensors | 118.3 | 118.2 |
| sensors → hierarchy | 82.4 | 82.2 |
| telemetry → console | 95.4 | 95.3 |
| hover away | 14.8 | 15.0 |
| hover enter | 0.5 | 0.5 |
| hover field | 13.9 | 13.5 |
| hover inside | 0.5 | 0.5 |
| hover other | 9.9 | 10.0 |
| idle | 0.2 | 0.2 |
| idle focused | 0.2 | 0.2 |
| scroll inspector | 21.3 | 21.3 |
| type backspace | 16.1 | 16.3 |
| type character | 18.1 | 16.2 |

The three rounded increases are thread-local allocation-buffer refill noise. A 100-cycle interaction run in direct
census mode measured exact per-action bytes before and after conversion:

| Action | Baseline bytes | After conversion bytes |
| --- | ---: | ---: |
| hover away | 14,112 | 14,112 |
| hover other | 10,400 | 10,400 |
| type backspace | 17,104 | 17,104 |

Each action dirtied all 100 frames in both runs. HashLink's per-action `Gc.totalAllocated` counter charges whole
thread-local allocation-buffer refills (up to 2,048 bytes) to whichever action triggers them. Its KiB medians are
therefore quantized by refill boundaries, even when the action's exact object and byte counts do not increase. The
census disables that fast path and counts the actual allocations; no action allocated more bytes after conversion.
Editor budgets currently use the refill-based counter and can move to exact per-action byte counts when an exact counter
is available without changing normal allocation behavior.

The HashLink selection-stress census fell from 408,765 allocations across 830 types to 403,157 across 832 types.
`LayoutStyle` stayed at 10,165 objects and 3,496,760 bytes. `TextStyle` and `ParagraphStyle` class allocations
(3,882/124,224 and 3,897/124,704) became 675 and 360 struct boxes (16,200 and 8,640 bytes) at actual escape
boundaries; 956 `LayoutTextStyles` holders accounted for 53,536 bytes. `LayoutNode` fell from 755,968 bytes to
708,720 bytes.

The committed opt-in Wasm GC allocation counter reports no increase over the class baseline. Across three runs of 120
measured frames after 120 warmup frames, baseline full, static and text-heavy each allocated 5,896 objects, and editing
allocated 12,833. Generated fingerprints had median counts of 5,896 full, 5,894 static, 5,896 text-heavy and 12,833
editing objects (49.13, 49.12, 49.13 and 106.94 per frame); individual runs varied by at most two objects. Median frame
times were 1.3 ms full, 1.3 ms static, 1.4 ms text-heavy and 1.6 ms editing.

The 2026-11-03 conformance-spelling port was measured against the immediately preceding compiler and app on the same
machine. Nine alternating pairs produced these per-action allocation medians (KiB); an initial unpaired
sensors-to-hierarchy sample was 78.6 KiB, while the paired median on both sides was 78.1 KiB.

| Action | Before | After |
| --- | ---: | ---: |
| hierarchy → sensors | 112.6 | 112.6 |
| sensors → hierarchy | 78.1 | 78.1 |
| console → telemetry | 74.5 | 74.5 |
| telemetry → console | 92.9 | 92.9 |
| hover enter / inside | 0.5 / 0.5 | 0.5 / 0.5 |
| hover other / field / away | 10.0 / 12.4 / 13.6 | 10.0 / 12.4 / 13.6 |
| scroll inspector | 21.2 | 21.2 |
| idle / idle focused | 0.2 / 0.2 | 0.2 / 0.2 |
| type character / backspace | 16.1 / 16.2 | 16.1 / 16.2 |

Nine selection-stress pairs had control/candidate medians of 342,096 / 342,098 allocations and a paired median
difference of +1; one type comparison found only one fewer byte buffer in the candidate. Its `TextStyle` and
`ParagraphStyle` counts were 140 each and `DockTextWidthKey` was zero. Nine 500-cycle RSS pairs had window medians
[29.84, 3.59, 0.78, 4.84] / [30.00, 3.75, 0.78, 4.84] MiB and zero paired median differences. Both Wasm guest
binaries were byte-for-byte identical. The earlier claimed paired Showcase counts were invalid for the reason above.

The Float hash correction was compared on the same machine with nine alternating control/candidate pairs. Every
per-action allocation median was unchanged from the table above, with zero paired median deltas. The selection-stress
census medians were 342,098 / 342,097 allocations, with a paired median delta of zero. The 500-cycle RSS windows were
29.84 / 4.06 / 0.78 / 4.84 MiB before and 30.00 / 3.75 / 0.78 / 4.84 MiB after; paired median deltas were
0 / -0.31 / 0 / 0 MiB. These are measurements of the hash correction, not evidence of an RSS improvement.

Independent allocation fixtures measured zero allocations for 8 and 1,024 Float hashes on HashLink, Wasm32 and Wasm GC, with inlining on and off.

The scalar-map correction was measured against the immediately preceding compiler with nine alternating pairs. Every
per-action allocation median remained as in the table above, with zero paired median deltas. One unpaired
sensors-to-hierarchy sample was 80.1 KiB; the paired control and candidate medians were both 78.1 KiB. The
selection-stress census median was 342,097 allocations on both sides, with a zero paired median delta. The 500-cycle
RSS window medians were 30.00 / 3.59 / 0.94 / 4.84 MiB before and 30.00 / 3.75 / 0.78 / 4.84 MiB after; the paired
median deltas were 0 / 0 / -0.16 / 0 MiB. These paired measurements do not establish an RSS improvement.

The Wasm GC guest binaries were byte-identical.

The scalar-closure identity correction was compared on the same machine with nine alternating control/candidate pairs.
All per-action allocation medians matched the table above, with zero paired median differences. The selection-stress
census medians were 342,096 / 342,097 allocations with a paired median difference of +1. Three further per-type pairs
showed differences only in byte buffers: 0 / +2 / -3 objects; the `TextStyle` and `ParagraphStyle` counts remained
140 each and `DockTextWidthKey` remained zero. The 500-cycle RSS window medians were 30.00 / 3.75 / 0.78 / 5.00 MiB
before and 30.16 / 3.59 / 0.94 / 4.84 MiB after, with paired median differences of 0 / -0.31 / 0 / 0 MiB. These
measurements do not establish an RSS improvement or an exact match to the original baseline.

Once an adapter exists, unwrapping it allocates zero objects for 8 and 1,024 operations on HashLink, Wasm32 and Wasm GC, with inlining on and off.

The HashLink Dynamic-callback fix was measured with nine alternating runs of the saved control runtime and the
candidate runtime using identical editor bytecode. All per-action allocation medians remained as in the table above,
with zero paired median differences. Selection-stress medians were 342,097 allocations for both runtimes, with zero
paired median difference; differences by type were confined to byte buffers. The 500-cycle RSS window medians were
29.84 / 3.91 / 0.78 / 5.00 MiB before and 29.69 / 3.75 / 0.78 / 4.84 MiB after; paired median differences were
0 / +0.16 / 0 / 0 MiB. The second-window difference is within the earlier same-binary control variation, so it does not
establish a runtime regression or an exact memory match.

The Wasm GC guest was byte-identical before and after the HashLink fork change.

The exact numeric erased-write check was measured with nine alternating control/candidate pairs on the same machine.
The editor bytecode was byte-identical. All action allocation medians matched the preceding table except
sensors-to-hierarchy, whose observed control/candidate medians were 78.1 / 78.4 KiB (paired median difference
+0.3 KiB). Individual samples of the identical binary ranged from 78.1 to 80.1 KiB, so this difference does not
establish a compiler-induced allocation regression. The selection-stress census medians were 342,097 / 342,098
allocations (paired median +1); three per-type pairs differed only in byte buffers, by +1 / 0 / -2 objects. The
500-cycle RSS window medians were 29.84 / 3.91 / 0.78 / 4.84 MiB before and 30.00 / 3.75 / 0.78 / 5.00 MiB after,
with paired median differences of -0.15 / -0.47 / 0 / 0 MiB. These figures include the previously observed
same-binary noise and do not establish an RSS improvement or an exact match to the original baseline.

The Wasm GC Showcase guest was byte-identical to its control.

The reference-shaped erased-write checks produced a Wasm GC guest byte-identical to the preceding compiler.

On HashLink, the editor bytecode was byte-identical to the control. Nine alternating pairs had matching per-action
allocation medians and zero paired median differences. Selection-stress medians were 342,097 / 342,097 allocations,
with a zero paired median difference. The 500-cycle RSS window medians were 30.31 / 3.59 / 0.78 / 4.84 MiB before
and 30.16 / 3.75 / 0.78 / 5.00 MiB after, with paired median differences of -0.15 / 0 / 0 / 0 MiB. These values
include the previously observed same-binary variation and do not establish an RSS improvement.

Array and closure erased-boundary checks were measured on the same machine against the preceding compiler. The
corrected Wasm GC comparison below replaces the invalid earlier paired figures. A scalar struct closure stored through
an erased generic owner then called in typed code allocated zero objects for 8 and 1,024 calls on HashLink, Wasm32
and Wasm GC, with inlining on and off.

The HashLink comparison alternated the previous and candidate native runtimes with identical editor bytecode. Across
nine pairs, every action had a zero paired median allocation difference. Separate control/candidate medians were
78.1 / 78.4 KiB for sensors-to-hierarchy and 12.1 / 13.6 KiB for hover-away; all other action medians matched the
preceding table. Selection-stress medians were 342,096 / 342,097 allocations, with a zero paired median difference;
all nine per-type differences were confined to byte buffers. The 500-cycle RSS window medians were 30.16 / 3.59 /
0.78 / 4.84 MiB before and 30.16 / 3.59 / 0.78 / 5.00 MiB after, with paired median differences of 0 / 0 / 0 /
+0.16 MiB. That last difference is within the previously observed same-binary RSS variation, so these measurements do
not establish an RSS regression or an exact match to the original baseline.

The corrected browser-loaded guest comparison for the erased-boundary change used nine alternating full runs and
three pairs for each other scenario. Its control/candidate median object counts were 5,896 / 5,896 for full, static
and text-heavy, and 12,622 / 12,622 for editing; every paired median difference was zero.

The Wasm GC literal-cache correction was compared by alternating the actual browser-loaded guests on the same machine:

| Showcase scenario | Before objects | After objects | Pairs |
| --- | ---: | ---: | ---: |
| full | 5,896 | 4,440 | 9 |
| static | 5,896 | 4,440 | 3 |
| text-heavy | 5,896 | 4,440 | 3 |
| editing | 12,622 | 8,724 | 3 |

The paired median differences were -1,456 objects for full, static and text-heavy and -3,898 for editing. A struct with
an Int and a managed String field passed through a specialized generic closure allocated zero objects for 8 and 1,024
calls after setup on HashLink, Wasm32 and Wasm GC, with inlining off and on. The original unprepared Wasm GC fixture
fell from 16 / 2,048 allocations to 2 / 0: the remaining two objects initialize the immutable literal once.

On HashLink, the saved control and candidate editor bytecode were identical. Nine alternating runs of the saved
control and candidate runtimes had equal per-action allocation medians and zero paired median differences. The
selection-stress census medians were 342,097 / 342,097 allocations, with a paired median difference of +1; the
per-type differences were confined to byte buffers. The 500-cycle RSS window medians were 30.00 / 3.44 / 0.78 /
4.84 MiB before and 29.84 / 3.91 / 0.78 / 5.00 MiB after, with paired median differences of -0.31 / -0.15 / 0 /
0 MiB. These figures include the observed same-binary variation and do not establish an RSS improvement.

The raw-pointer Dynamic boundary was measured against the preceding browser-loaded Wasm GC guest. Nine full pairs
and three pairs each of static, text-heavy and editing all had zero paired median object-count difference: respectively
4,440 / 4,440 / 4,440 / 8,724 objects before and after. After typed interface dispatch and pruning unused scalar
receiver clones, the same alternating measurement again found 4,440 / 4,440 / 4,440 / 8,724 objects on both sides.
The checked pointer boundary and interface allocation tests are specified in `docs/GENERIC_SPECIALIZATION.md`.

Giving native callback and runtime type handles distinct Dynamic representations was measured against the preceding
compiler with the browser-loaded Wasm GC Showcase. Nine full pairs and three pairs each of static, text-heavy and
editing again measured 4,440 / 4,440 / 4,440 / 8,724 objects on both sides, with zero paired median differences.
The final Wasm GC guest was byte-identical to the measured candidate. Typed callback operations allocate zero times
for 8 and 1,024 calls on HashLink, Wasm32 and Wasm GC, with inlining enabled and disabled.

## Earlier paired runtime and UI measurements

On outer revision `a653ff227`, nine alternating HashLink control/candidate runs used identical source manifests and
byte-identical editor bytecode, with the pre-change and candidate native runtimes. Per-action allocation medians in
KiB and paired median differences were:

| Action | Control | Candidate | Paired difference |
| --- | ---: | ---: | ---: |
| hierarchy → sensors / sensors → hierarchy | 112.6 / 80.1 | 112.6 / 80.1 | 0 / 0 |
| console → telemetry / telemetry → console | 74.5 / 93.1 | 72.5 / 93.1 | -2.0 / 0 |
| hover enter / inside | 0.5 / 0.5 | 0.5 / 0.5 | 0 / 0 |
| hover other / field / away | 10.0 / 12.6 / 13.6 | 10.0 / 12.4 / 13.6 | 0 / 0 / 0 |
| scroll inspector | 21.2 | 21.2 | 0 |
| idle / idle focused | 0.2 / 0.2 | 0.2 / 0.2 | 0 / 0 |
| type / backspace | 16.1 / 16.2 | 16.1 / 16.2 | 0 / 0 |

The console difference falls within observed same-binary variation, and the hover-field paired difference was zero;
these samples do not establish a permanent reduction. Selection-stress census medians were 342,098 / 342,097 allocations, with a paired difference of -1;
individual differences were confined to byte buffers. Nine 500-cycle RSS pairs had control window medians
[30.16, 3.75, 0.78, 5.00] MiB and candidate medians [30.16, 3.44, 0.78, 4.84] MiB, with paired median differences
[-0.16, -0.15, 0, 0] MiB. The samples vary and do not establish an exact memory match.

Treating boxed Wasm32 callback and type handles as GC leaves does not change the Wasm GC Showcase guest: the control
and candidate binaries are byte-identical. Nine full browser pairs and three each of static, text-heavy and editing
again measured 4,440 / 4,440 / 4,440 / 8,724 objects on both sides. The Wasm32 typed-callback census remained at zero
allocations for 8 and 1,024 calls before and after, with inlining on and off.

On outer revision `6b05a8376`, the HashLink control and candidate again had identical source manifests and bytecode,
and used the same native runtime. Nine alternating pairs had matching per-action medians: 112.6 / 80.1 / 72.5 / 93.1
KiB for the four tab switches; 0.5 / 0.5 / 10.0 / 12.4 / 13.6 KiB for hover enter / inside / other / field / away;
21.2 KiB for scroll; 0.2 / 0.2 KiB for idle / idle-focused; and 16.1 / 16.2 KiB for type / backspace. Paired median
differences were zero except telemetry → console (+0.2 KiB), demonstrating capture variation with identical binaries.
Selection-stress medians were 342,097 / 342,098 allocations, with a zero paired median difference; individual
differences were byte buffers. The 500-cycle RSS window medians were [30.31, 3.59, 0.78, 4.84] MiB for control and
[29.84, 3.91, 0.78, 5.00] MiB for candidate, with paired median differences [0, +0.16, 0, 0] MiB. These figures
measure variation rather than a change in the identical HashLink artifacts.

The pointer-boundary change was also measured on the current outer `HEAD` against a control built with compiler
`38db19f0` from the same source tree. Nine alternating HashLink pairs had equal per-action medians: 112.6, 80.1,
72.5 and 93.1 KiB for the four tab switches, and 0.5, 0.5, 10.0, 12.4, 13.6, 21.2, 0.2, 0.2, 16.1 and 16.2 KiB
for hover-enter, hover-inside, hover-other, hover-field, hover-away, scroll, idle, idle-focused, type and backspace.
The paired median differences were zero except telemetry-to-console (+0.2 KiB). In nine control-versus-control
pairs the same action varied from 92.9 to 94.9 KiB, including 0.2 KiB differences between captures. The selection
census medians were 342,097 / 342,097 allocations, paired difference zero; per-type differences were confined to byte
buffers. The budget measurement reports frame time but no per-action allocation for selection.

The nine 500-cycle RSS window medians were 29.84 / 3.75 / 0.78 / 5.00 MiB for the control and 30.47 / 3.59 / 0.78 /
5.00 MiB for the candidate; paired median differences were +0.47 / -0.31 / 0 / 0 MiB. In nine control-versus-control
pairs the first window differed by as much as +1.25 MiB in individual pairs, with a paired median of +0.16 MiB. These
measurements do not establish an RSS increase or an exact match. A decoded comparison of the 31,340 HashLink functions
found identical opcodes and register types, identical integer, float, string, global, constant and native tables, and
identical type descriptors; the function-name manifest differs only in the checked-cast helper prefix.

The typed-interface ABI and receiver-clone pruning were measured against compiler `e4eeca63` on the same outer
revision (`4b5983a0f`), using identical source manifests and byte-identical HashLink runtimes. Nine alternating pairs
gave these per-action allocation medians in KiB:

| Action | Control | Candidate | Paired median difference |
| --- | ---: | ---: | ---: |
| hierarchy → sensors | 112.6 | 112.6 | 0 |
| sensors → hierarchy | 80.1 | 80.1 | 0 |
| console → telemetry | 72.5 | 74.5 | 0 |
| telemetry → console | 93.1 | 93.1 | 0 |
| hover enter / inside | 0.5 / 0.5 | 0.5 / 0.5 | 0 / 0 |
| hover other / field / away | 10.0 / 12.4 / 13.6 | 10.0 / 12.4 / 13.6 | 0 / 0 / 0 |
| scroll inspector | 21.2 | 21.2 | 0 |
| idle / idle focused | 0.2 / 0.2 | 0.2 / 0.2 | 0 / 0 |
| type / backspace | 16.1 / 16.2 | 16.1 / 16.2 | 0 / 0 |

The selection census medians were 342,097 / 342,097 allocations, with a paired median difference of +1; the
individual differences were byte buffers. Nine paired 500-cycle RSS captures gave control window medians
[30.31, 3.75, 0.78, 4.84] MiB and candidate medians [30.00, 3.59, 0.78, 5.00] MiB, with paired median differences
[-0.31, -0.16, 0, 0] MiB. The editor module gained eight receiver-preserving functions; unused generated clones are
not emitted. In nine same-binary pairs on this revision, console → telemetry varied from 72.5 to 74.5 KiB, with
paired differences from -2 to +2 KiB. Selection counts varied from 342,094 to 342,099, with paired differences from
-4 to +2, all in byte buffers. Same-binary RSS paired differences ranged from -1.40 to +1.25 MiB in the first window
and from -0.94 to +0.78 MiB in the second. These variations do not establish an exact memory match.

The Wasm32 managed-bytes and iterator descriptor change was compared with compiler `e5ede6af` using the same
Wasm GC Showcase host and alternating guests. Nine full-scene pairs and three pairs each for static, text-heavy and
editing all matched: control and candidate medians were 4,440 / 4,440 / 4,440 / 8,724 objects, respectively, with
zero paired differences. The guests were byte-identical (SHA-256
`63b0ae6fa9cf52abb699071ca45eb9986067a9658128f01fc63aab8d8337ede6`).

On HashLink, nine alternating pairs used byte-identical control and candidate editor modules on outer revision
`6f90b6294`. Per-action allocation medians (KiB) were 112.6 / 80.1 / 74.5 / 93.1 for the four tab switches;
0.5 / 0.5 / 10.0 / 12.4 / 13.6 for the hover actions; 21.2 for scroll; 0.2 / 0.2 for idle and focused idle;
and 16.1 / 16.2 for type and backspace. Both sides matched for each action with zero paired median difference.
The 30-cycle selection census medians were 342,097 / 342,098 allocations, with zero paired median difference.
One type comparison found 342,098 allocations on each side and only a 112-byte difference in byte buffers.
The 500-cycle RSS window medians were 30.62 / 3.44 / 0.78 / 5.00 MiB before and 29.69 / 4.06 / 0.78 / 5.00 MiB
after; paired median differences were -0.47 / +0.31 / 0 / 0 MiB. As the modules are identical, those differences
reflect run-to-run variation rather than an effect of the Wasm32 changes.

The interpreter closure-view correction was compared on outer revision `9020c754c` with nine alternating pairs.
Both editor modules were byte-identical. Per-action allocation medians (KiB) matched at 112.6 / 80.1 / 74.5 / 93.1
for tab switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and focused idle,
and 16.1 / 16.2 for type and backspace; every paired median difference was zero. The 30-cycle selection census
medians were 342,097 / 342,096 allocations with zero paired median difference; one type comparison differed by one
byte buffer. The 500-cycle RSS window medians were 29.84 / 4.06 / 0.78 / 4.84 MiB and 30.00 / 3.59 / 0.78 / 4.84
MiB, with paired median differences +0.46 / -0.47 / 0 / +0.15 MiB. These are same-binary variations. Nine full-scene
and three pairs per other Wasm GC Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects; the guests
were byte-identical.

The Wasm32 semantic closure-signature change was compared on outer revision `d9087f6a3` with nine alternating
HashLink pairs. The editor modules were byte-identical. Per-action allocation medians (KiB) matched at
112.6 / 80.1 / 74.5 / 93.1 for tab switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll,
0.2 / 0.2 for idle and focused idle, and 16.1 / 16.2 for type and backspace; all paired median differences
were zero. The 30-cycle selection census medians were 342,098 / 342,098 allocations with zero paired median
difference; one type comparison differed by one byte buffer. The 500-cycle RSS window medians were
30.00 / 3.75 / 0.78 / 4.84 MiB and 30.16 / 3.59 / 0.94 / 5.00 MiB, with paired median differences
0 / 0 / +0.16 / +0.16 MiB. These are variations between identical binaries. Nine full-scene and three pairs per
other Wasm GC Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects; the guests were byte-identical.

The reactive equal-write correction and owner-thread simulation preparation were measured on outer revision
`11cc0cd10` with the two preparation files changed. Nine alternating HashLink pairs had matching per-action allocation
medians (KiB): 112.6 / 80.1 / 74.5 / 93.1 for tab switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for
scroll, 0.2 / 0.2 for idle and focused idle, and 16.1 / 16.2 for type and backspace. Selection census medians were
342,097 / 342,098 allocations, with zero paired median difference. The 500-cycle RSS window medians were
29.84 / 3.75 / 0.78 / 5.00 MiB and 30.16 / 3.59 / 0.78 / 4.84 MiB; paired median differences were
+0.16 / 0 / 0 / 0 MiB, within the same-binary variation documented above, so they do not establish an RSS change.
Nine full-scene and three pairs per other Wasm GC Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects.

The inherited conformance correction was compared on outer revision `598ff0c4c` with nine alternating pairs. The
HashLink editor modules were byte-identical, and all action allocation medians (KiB) matched: 112.6 / 80.1 / 74.5 /
93.1 for tab switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and focused
idle, and 16.1 / 16.2 for type and backspace. Selection census medians were 342,097 / 342,098, with a paired median
difference of +1; a separate per-type comparison differed only in byte buffers. The 500-cycle RSS window medians were
29.84 / 4.06 / 0.78 / 4.84 MiB and 30.16 / 3.75 / 0.78 / 4.84 MiB; paired median differences were
+0.62 / -0.15 / +0.16 / +0.16 MiB. These are variations between identical binaries. Nine full-scene and three pairs per
other Wasm GC Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects; the guests were also byte-identical.

The effect-recovery and per-edge Observable invalidation change was compared on outer revision `38be5e2e3` in nine
alternating HashLink pairs. Per-action allocation medians (KiB) matched at 112.6 / 80.1 / 74.5 / 93.1 for tab
switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and focused idle, and
16.1 / 16.2 for type and backspace. Selection census medians fell from 342,098 to 342,091 allocations, with a paired
median difference of -7. A per-type pair showed six fewer arrays and 104 fewer bytes across 13 Observable sources;
the remaining three-allocation difference was in byte buffers. The 500-cycle RSS window medians were
30.47 / 3.44 / 0.78 / 4.84 MiB and 30.00 / 3.75 / 0.78 / 5.00 MiB, with paired median differences
-0.15 / +0.16 / 0 / 0 MiB; those small changes are within the same-binary variation recorded above. Nine full-scene
and three pairs per other Wasm GC Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects. An observed
write followed by an effect flush allocates zero times on HashLink for 1,024 updates and on Wasm32 and Wasm GC for
8 and 1,024 updates, with inlining enabled and disabled.

The dependency-triggered effect retry policy was compared on outer revision `1205257d4` in nine alternating
HashLink pairs. Per-action allocation medians (KiB) matched at 112.6 / 80.1 / 74.5 / 93.1 for tab switches,
0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and focused idle, and 16.1 / 16.2
for type and backspace. Selection census medians were 342,092 / 342,091 allocations, with zero paired median
difference; a separate per-type pair differed only in byte buffers. The 500-cycle RSS window medians were
30.16 / 3.75 / 0.78 / 5.00 MiB on both sides, with paired median differences +0.31 / 0 / 0 / 0 MiB, within the
same-binary variation recorded above. Nine full-scene and three pairs per other Wasm GC Showcase scenario matched at
4,440 / 4,440 / 4,440 / 8,724 objects. The successful observed write-and-flush census remained at zero allocations
on HashLink for 1,024 updates and on both Wasm targets for 8 and 1,024 updates, with inlining enabled and disabled.

The Observable struct-place restriction and editor telemetry port were compared on outer revision `e67b4bdc4` with
nine alternating HashLink pairs. All action allocation medians (KiB) matched: 112.6 / 80.1 / 74.5 / 93.1 for tab
switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and focused idle, and
16.1 / 16.2 for type and backspace. Selection census medians were 342,091 / 342,091, with zero paired difference;
a separate per-type pair differed only by one byte buffer. The 500-cycle RSS window medians were
30.16 / 3.44 / 0.78 / 4.84 MiB and 30.00 / 3.91 / 0.78 / 4.84 MiB, with paired median differences
-0.15 / +0.31 / 0 / 0 MiB, within the same-binary variation recorded above. Nine full-scene and three pairs per other
Wasm GC Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects; the guests were byte-identical.
An observed scalar-and-reference struct copy, update, assignment and effect flush allocated zero times on HashLink for
1,024 updates and on both Wasm targets for 8 and 1,024 updates, with inlining enabled and disabled.

Atomic, nonwrapping reactive dependency-ID reservation was compared on outer revision `40c855d6d` in nine
alternating HashLink pairs. Per-action allocation medians (KiB) were 112.6 / 80.1 / 74.5 / 93.1 for the control and
112.6 / 80.1 / 74.5 / 93.2 for the candidate's tab switches; the paired median difference was zero for every action.
The remaining medians matched at 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and
focused idle, and 16.1 / 16.2 for type and backspace. Selection census medians were 342,091 / 342,091 with zero paired
difference; a separate per-type pair differed only by one byte buffer. The 500-cycle RSS window medians were
29.69 / 3.91 / 0.78 / 5.00 MiB and 29.84 / 3.59 / 0.78 / 4.84 MiB, with paired median differences
0 / 0 / 0 / -0.16 MiB. Nine full-scene and three pairs per other Wasm GC Showcase scenario matched at
4,440 / 4,440 / 4,440 / 8,724 objects.

The 64-bit dependency-ID change was compared with outer revision `f1a9e9516` in nine alternating HashLink pairs,
swapping the matching native runtime with each module. Per-action allocation medians (KiB) were 112.6 / 80.1 / 74.5 /
93.2 for control and 112.6 / 80.1 / 74.5 / 92.9 for the candidate's tab switches; paired median differences were
0 / 0 / 0 / -0.3. The remaining medians matched at 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll,
0.2 / 0.2 for idle and focused idle, and 16.1 / 16.2 for type and backspace. Selection census medians were
342,091 / 342,090 with a paired difference of -1; a per-type pair had equal object counts and differed only by 48 bytes
in byte buffers. The 500-cycle RSS window medians were 30.31 / 3.59 / 0.78 / 5.00 MiB and 29.84 / 3.59 / 0.78 /
5.00 MiB, with paired median differences -0.15 / -0.15 / 0 / 0 MiB. Nine full-scene and three pairs per other Wasm GC
Showcase scenario matched at 4,440 / 4,440 / 4,440 / 8,724 objects. Repeated captured reads and effect flushes allocate
zero times on HashLink for 1,024 updates and on both Wasm targets for 8 and 1,024 updates, with inlining on and off.

An identity-based follow-up replaced the 64-bit dependency IDs and subscriber index. On Haxeon `9c1750fb`, three
selection-stress census pairs fell from 342,089–342,091 to 340,909–340,910 allocations. Nine refill-based editor
pairs reported hierarchy-to-sensors at 112.6 → 114.6 KiB and console-to-telemetry at 72.5 → 74.5 KiB. Exact censuses
restricted to each action found identical object and byte counts in every one of 29 warm actions on both trees:
1,661 / 115,200 for hierarchy-to-sensors and 1,154 / 75,864 for console-to-telemetry on 28 actions, with matching
larger actions of 1,705 / 118,456 and 1,210 / 80,376 respectively. A fast-path trace identified the KiB steps as
shifted thread-local allocation-buffer refills;
see [ADR 0002](../adr/0002-reactive-ui-model.md) for the measured sites and totals. The editor budget
implementation and ceilings were not changed.

Retained updater ownership was compared on outer revision `3dcdddb4d` in nine alternating HashLink pairs, building both
modules from that same outer revision. All per-action allocation medians (KiB) matched: 112.6 / 80.1 / 74.5 / 92.9 for
tab switches, 0.5 / 0.5 / 10.0 / 12.4 / 13.6 for hover, 21.2 for scroll, 0.2 / 0.2 for idle and focused idle, and
16.1 / 16.2 for type and backspace. Selection census medians were 342,091 / 342,091, with zero paired difference; a
per-type pair differed only in byte buffers. The 500-cycle RSS window medians were 30.00 / 3.75 / 0.94 / 5.00 MiB and
30.16 / 3.75 / 0.78 / 4.84 MiB, with paired median differences +0.16 / +0.15 / 0 / 0 MiB, within the same-binary
variation recorded above. Nine full-scene and three pairs per other Wasm GC Showcase scenario matched at
4,440 / 4,440 / 4,440 / 8,724 objects. The first ownership prototype added 879 captured cells and eight bytes per updater
in a 30-cycle selection census; moving exception handling into a helper and packing the existing flags with the ownership
count removed those costs.

The Wasm runtime type-identity fix was compared with Haxeon `9e235865` on outer
revision `f0c2e9d32`. The editor profiling modules and the UI framework modules
were byte-identical between control and candidate; the instrumented Wasm GC
Showcase guests were also byte-identical. Runtime IDs still occupy one 32-bit
word, with no change to object or array header sizes.

Nine alternating HashLink pairs produced these per-action allocation medians
(KiB). Selection stress is measured separately by the exact allocation census.

| Action | Control | Candidate |
| --- | ---: | ---: |
| console → telemetry | 74.5 | 74.5 |
| hierarchy → sensors | 114.6 | 114.6 |
| sensors → hierarchy | 80.1 | 80.1 |
| telemetry → console | 92.9 | 92.9 |
| hover away | 13.6 | 13.6 |
| hover enter | 0.5 | 0.5 |
| hover field | 12.4 | 12.4 |
| hover inside | 0.5 | 0.5 |
| hover other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| focused idle | 0.2 | 0.2 |
| scroll inspector | 21.2 | 21.2 |
| backspace | 16.2 | 16.2 |
| type character | 16.1 | 16.1 |

Three 30-cycle selection-stress census pairs counted 340,907 / 340,911 /
340,910 allocations in control and 340,908 / 340,908 / 340,909 in candidate.
Differences were confined to byte buffers; all other per-type object and byte
counts matched within each pair. Total census bytes ranged from 24,009,904 to
24,010,984 in control and 24,010,160 to 24,010,512 in candidate.

All six 500-cycle headless memory gates passed. RSS growth in the four windows
(MiB), preserving the paired order, was:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.31 / 3.44 / 0.78 / 5.00 | 30.00 / 3.75 / 0.62 / 4.84 |
| 2 | 30.31 / 3.59 / 0.78 / 4.84 | 30.00 / 4.06 / 0.78 / 4.84 |
| 3 | 29.69 / 4.06 / 0.78 / 4.84 | 29.69 / 4.38 / 0.78 / 5.16 |

The median paired differences were −0.31 / +0.32 / 0 / 0 MiB. These runs load
identical modules; the small window differences are within the same-binary
variation recorded above. The allocation and memory ceilings were unchanged.

For Wasm GC allocation comparisons, use the existing fixed-step core mode:
`NATIVEKIT_WEB_BENCHMARK_MODE=core`, with 120 warmup and 120 measured frames.
Nine full-scene pairs and three pairs per other scene matched exactly:

| Scene | Control objects | Candidate objects |
| --- | ---: | ---: |
| full | 5,896 | 5,896 |
| static | 5,896 | 5,896 |
| text-heavy | 5,896 | 5,896 |
| editing | 12,622 | 12,622 |

Normal browser mode advances animation with wall-clock frame times. In the
same comparison, full-scene counts ranged from 5,896–5,914 in control and
5,898–5,912 in candidate, with both medians at 5,902; the static medians were
5,898 and 5,900 despite identical guest bytes. Fixed-step mode removes this
clock-phase variation from the allocation comparison. These counts describe
this build and mode; earlier browser-mode scene totals are not interchangeable
with them. Browser smoke and the editor budgets and retention gates also passed.

### Closed source enum batch: final product comparison

This closes the product validation for `5b916e9c` through `7a3b0126`, including the fail-closed enum verifier,
typed callback ABI and the app-gate correctness fixes described above. Control is `530bda5a`, candidate source is
`7a3b0126`; both use the frozen outer source `8195b397f04e2d527430607e8e3624a38df8d950` on the same machine.
All product captures use three alternating control/candidate pairs, with no concurrent session builds. Every scheduled
capture completed; no gate was accepted by retrying. The app failures above were reproduced on the control and fixed
at their causes before starting the final captures.

The native VM also changes, from HashLink `4a33fa08` to `bfddf398`. Each capture runs its own version's actual VM and
profiler, with its matching `libhl.so` and runtime preloaded. The control VM was rebuilt from the pinned archived
source in Release with frame pointers, then paired with the original saved control libraries. Candidate VM size is
550,704 → 558,896 bytes; `libhl.so` stays 892,432 bytes, but changes SHA-256 from
`97abb73a9557c77a0042f4f62819790975009447fd18d330253146d5393aebba` to
`2766508657eab6e7702b5e6850a321d5507ca92e934fdac1925aea3cb9af7f98`.
The isolated gate checkout adds measurement-only runtime/profiler environment overrides to its profile helper; the
shared outer checkout and budget tooling are unchanged. VM, profiler, library and module hashes are in the compact
measurement manifest. These are batch comparisons, not isolated attribution to enum storage or one correctness fix.

Artifacts differ, so Tier 3 was run rather than skipped:

| Development module | Control bytes | Candidate bytes | Candidate SHA-256 |
|---|---:|---:|---|
| Editor profile / HashLink | 100,301,360 | 100,487,012 | `4a31ad6757be4b87455a9d43d7400348d4ec8770d547a663456efa88151a33d0` |
| Showcase / Wasm GC | 5,808,484 | 5,809,798 | `c53fad9b5a0e86d9698268b5fa1efa112f46bb42132e858d47022286abb958c6` |
| Showcase / Wasm32 | 11,810,665 | 11,813,835 | `714594fdb78ee67f891082d5bc738abbd0504c415e7b24b6eaf177a5f6f97a1d` |

Per-action medians follow. KiB is the existing refill-quantized counter; timing is median frame ms. All six paired
budget captures pass, as does the separate final candidate budget/retention gate. A single hierarchy-to-sensors pair
reads 112.5 → 112.8 KiB; the other two tie at 112.5 and the three-pair median ties. No ceiling changed.

| Scenario / action | Control KiB | Candidate KiB | Delta KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|---:|
| tab-matrix / console->telemetry | 74.500 | 74.500 | +0.000 | 1.110 | 1.010 |
| tab-matrix / hierarchy->sensors | 112.500 | 112.500 | +0.000 | 1.570 | 1.490 |
| tab-matrix / sensors->hierarchy | 77.800 | 77.800 | +0.000 | 1.210 | 1.120 |
| tab-matrix / telemetry->console | 91.200 | 91.200 | +0.000 | 1.170 | 1.070 |
| interaction / hover-away | 13.600 | 13.600 | +0.000 | 0.430 | 0.420 |
| interaction / hover-enter | 0.500 | 0.500 | +0.000 | 0.000 | 0.000 |
| interaction / hover-field | 12.400 | 12.400 | +0.000 | 0.440 | 0.430 |
| interaction / hover-inside | 0.500 | 0.500 | +0.000 | 0.000 | 0.000 |
| interaction / hover-other | 10.000 | 10.000 | +0.000 | 0.420 | 0.410 |
| interaction / idle | 0.200 | 0.200 | +0.000 | 0.010 | 0.010 |
| interaction / idle-focused | 0.200 | 0.200 | +0.000 | 0.010 | 0.010 |
| interaction / scroll-inspector | 21.200 | 21.200 | +0.000 | 0.720 | 0.710 |
| interaction / type-backspace | 16.200 | 16.200 | +0.000 | 0.420 | 0.410 |
| interaction / type-char | 16.100 | 16.100 | +0.000 | 0.420 | 0.410 |

The selection action has no per-action KiB sample in this harness; its three-pair frame median is 2.92 → 2.78 ms.
The separate 30-cycle selection census gives total object counts 332,497 / 332,498 / 332,498 for control and
332,497 / 332,497 / 332,496 for candidate. Median recorded bytes are 23,592,240 → 23,591,936. Every named type's
object and byte totals equal its paired control in all three pairs; only the generic `bytes` category varies.
This small raw-buffer difference is not evidence of an inline-enum allocation win. E9's real-app enum allocation
decrease remains open and will be measured while widening the admitted subset.

All headless memory captures pass. RSS window growth in MiB, preserving each alternating pair:

| Pair | Control windows | Candidate windows |
|---|---|---|
| 1 | 30.00 / 3.59 / 0.78 / 5.00 | 29.69 / 3.59 / 0.78 / 5.00 |
| 2 | 29.84 / 4.38 / 0.78 / 5.00 | 29.53 / 3.91 / 0.78 / 5.00 |
| 3 | 30.62 / 3.59 / 0.78 / 5.00 | 30.16 / 3.59 / 0.78 / 5.00 |

The Wasm GC opt-in counter matches in every scene and every pair. Timing/load medians are recorded alongside the
counts; the small Wasm32 frame and static/text-heavy startup increases are observations, not allocation wins or
reasons to retry a capture.

| Target / scene | Objects control → candidate (each of three pairs) | First-frame ms control → candidate | Frame median ms control → candidate |
|---|---:|---:|---:|
| Wasm GC / full | 4,440 → 4,440 | 169.6 → 158.2 | 2.4 → 2.2 |
| Wasm GC / static | 4,440 → 4,440 | 166.3 → 175.1 | 2.1 → 2.1 |
| Wasm GC / text-heavy | 4,440 → 4,440 | 176.3 → 177.2 | 2.5 → 2.4 |
| Wasm GC / editing | 8,724 → 8,724 | 173.6 → 154.4 | 2.8 → 2.5 |
| Wasm32 / full | Counter unavailable | 173.5 → 148.0 | 2.2 → 2.3 |

Tier 1 on the final compiler source: 813 tests, zero failures and a self-hosting fixed point. Tier 2 passes all ten
UI scripts, 516 cross-target parity fixtures (14 skipped), all six UI value snapshots, the complete app suite,
all nine retention scenarios, editor budgets and the paired headless memory checks. Browser UI smoke passes on
both Web targets. The source enum micro-fixture still shows HashLink 384 / 49,152 bytes → zero and both Wasm
targets 16 / 2,048 objects → zero at 8 / 1,024 calls, with inlining off/on. These fixture wins do not replace E9's
pending real-app decrease.

Records: `haxeon-flat-work/enum-first-batch-gates/{artifact-comparison,paired-vm-manifest,final-tier2-progress}.json`,
`paired-{actions,census,rss,web-core,web32-load}.jsonl` and the final gate logs. Raw captures and completed parity
guests were deleted after recording their results.

### Final batch validation after the 614024b2 rebase

Control is Haxeon `614024b2`; candidate is `acdb8b7c`; the frozen outer app source is
`2de94628c`. The outer source includes the local CAD collision-thickness fix and the read-only scene appearance
change. The HashLink editor module hashes differ (`3946280685dbdb7e5646dc95683b3b9714a6ad7e17f1855488f2d7e60f407403`
control, `ce3c52a1403c9b20a555cb64f005b28717f0c347bdb510fa6995de96b82bdb43` candidate; each about 97 MiB), so
paired measurements were run. The table is one alternating control/candidate pair; allocation is the existing
HashLink KiB counter, quantized by allocator buffer refills, and time is median frame time in milliseconds.

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|
| console → telemetry | 74.5 | 74.4 | 1.00 | 1.01 |
| hierarchy → sensors | 112.5 | 110.3 | 1.45 | 1.46 |
| sensors → hierarchy | 77.8 | 79.6 | 1.11 | 1.12 |
| telemetry → console | 92.9 | 88.8 | 1.07 | 1.07 |
| hover away | 13.6 | 13.6 | 0.43 | 0.42 |
| hover enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover field | 10.9 | 12.4 | 0.43 | 0.43 |
| hover inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover other | 10.0 | 10.0 | 0.42 | 0.41 |
| idle | 0.2 | 0.3 | 0.01 | 0.01 |
| idle focused | 0.2 | 0.3 | 0.01 | 0.01 |
| scroll inspector | 21.7 | 21.7 | 0.72 | 0.71 |
| type backspace | 16.2 | 16.2 | 0.41 | 0.41 |
| type character | 16.1 | 16.1 | 0.41 | 0.41 |

The refill counter's `sensors → hierarchy` increase does not represent more allocated bytes in the selected action
window: an exact census measured 1,806 objects / 138,136 bytes on control and 1,778 / 137,008 on candidate
(-28 objects, -1,128 bytes). The same check for `hover field` measured 689 / 59,800 and 689 / 59,664
(-136 bytes), despite the displayed 1.5 KiB increase. These two KiB readings crossed refill boundaries at different
points. `idle` and `idle focused` each display +0.1 KiB; those windows did not receive an exact census, so the
quantized readings alone do not establish a byte regression.

Selection stress measured 2.79 → 2.41 ms per frame. Its 30-cycle exact census fell from 343,622 objects /
24,092,200 bytes to 298,806 / 20,782,656 (-44,816 objects, -3,309,544 bytes). Largest byte reductions were arrays
(-964,560), `LayoutStyle` (-815,280), `RenderNode` (-435,120), and `LayoutNode` (-172,800).

Three paired headless runs (500 cycles) passed the memory gate. Median RSS growth windows in MiB were control
`[30.62, 2.81, 0.94, 5.16]`, candidate `[30.16, 3.28, 0.94, 5.47]`; later windows are slightly higher on
candidate. RSS after warmup was 8.91 → 9.84 MiB and frame p95 was 1.45 → 1.46 ms. The paired increases are recorded
as findings; no run was retried.

The Showcase Wasm GC guest changed from 5,820,369 bytes (SHA-256
`e1278bce01b44055ba663184c2372fbe68214728ec202c7c2bffc8e60410024b`) to 5,855,816 bytes (`f79f290013151cda95e043e07b56c9dbcfd90e2634ccd3df26f34743c833ad8a`), +35,447 bytes. Its host Wasm
(2,259,510 bytes) and JavaScript (177,128 bytes) are byte-identical. The opt-in Wasm GC object count tied in all
four 120-frame scenes: full 4,440, static 4,440, text-heavy 4,440, editing 8,724. Each used 120 warmup frames;
all had zero frames over budget. Guest frame median/p95 milliseconds were full 1.5/2.1 → 1.5/1.9, static
1.3/1.8 → 1.3/1.8, text-heavy 1.4/2.0 → 1.4/2.2, and editing 1.6/2.3 → 1.5/2.3. The four runs are a single
paired capture, not timing medians across repeated captures.

The one-build compiler phase observations recorded BodyTyped (`bodies`) at 451.88 ms control and 120.38 ms
candidate. Tier 2 passed: compiler suite (837 tests, zero failures), self-hosting fixed point, all ten UI scripts,
Wasm backend parity, 521 cross-target fixtures (14 skipped), six UI snapshots, app suite, nine retention scenarios,
editor budgets, and the headless memory gate. The Wasm GC UI snapshot is included in the parity gate.

The app `MainWeb` Wasm GC guest initially failed on both control and candidate with
`Duplicate IR function "$enum-equals:278a341efefc3146f489368a235f5603"`. A small incremental fixture reproduced the
same class of failure: a cached struct equality helper retained its enum helper while a newly typed module requested
that globally named helper under a different owner. The duplicate was at the final assembly boundary, where the same
canonical function name cached in multiple modules was appended once per module. Sorting and uniquing the cached
function names before resolving each body through the canonical owner fixes the duplicate; origin is `b2725626`
(`Anchor shared equality helpers at their type declarations`), which added cross-module enum helper retention.

The regression fixture passes on HashLink, Wasm32 and Wasm GC with inlining off/on, executes the updated program, and
checks that exactly one enum equality helper reaches the backend. The `MainWeb` guest then compiled 3,353 sources to
184,559,568 bytes (SHA-256
`1ca68251980fa9f0d362cddb508f33a02272fafc6d509c58aabf435fb8882838`). This uses a temporary portable-ABI32 copy
of the existing `machinekit-pendant.hxi` because the outer app does not package that interface for Wasm32; that
packaging issue is outside Haxeon and does not block the compiler push. Guest compile and encode took 93,532 ms and
167,079 ms respectively. The paired control still reproduces the duplicate-function failure.

### Nullary enum cache and closed-tag batch: final measurements (2026-11-09)

Control is `1fae06c3` (the following sizing-blocker commit is docs-only); candidate is `a3064590`, including the
Wasm nullary-case cache and lifecycle/style-tag ports. Both use the same frozen outer app `2de94628c`, native
libraries and checkout-built VM. Three paired captures alternate control/candidate order and use the same CPU
set. The editor and Web modules differ, so no Tier 3 measurement was skipped. Captures and heavy builds live on
DATA1; raw captures are deleted after their results are recorded.

HashLink action medians below are the medians of three per-capture medians. KiB readings use the existing
refill-quantized counter; the exact diagnostic windows below decide apparent increases.

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|
| console->telemetry | 72.4 | 72.4 | 1.02 | 1.02 |
| hierarchy->sensors | 110.3 | 112.3 | 1.48 | 1.48 |
| sensors->hierarchy | 77.6 | 77.6 | 1.13 | 1.12 |
| telemetry->console | 88.8 | 90.7 | 1.09 | 1.08 |
| hover-away | 13.6 | 13.6 | 0.43 | 0.42 |
| hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-field | 12.4 | 12.4 | 0.44 | 0.43 |
| hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-other | 10.0 | 10.0 | 0.42 | 0.42 |
| idle | 0.3 | 0.3 | 0.01 | 0.01 |
| idle-focused | 0.3 | 0.3 | 0.01 | 0.01 |
| scroll-inspector | 21.7 | 21.7 | 0.72 | 0.71 |
| type-backspace | 16.2 | 16.2 | 0.42 | 0.42 |
| type-char | 16.1 | 16.1 | 0.42 | 0.42 |
| selection (exact window) | 571.03 | 571.03 | 2.47 | 2.44 |

The selection row's KiB is one exact steady-state frame, not a refill-counter median. A measurement-only harness
starts an exact one-byte-interval census on the second matching action and stops it immediately after the frame,
before timeline serialization. It changes only the detached outer checkout. Control and candidate are rebuilt
from their respective compiler/UI sources with the same instrumentation. All four tab windows and selection tie:

| Exact action window | Objects, each side | Bytes, each side |
|---|---:|---:|
| hierarchy->sensors | 1,680 | 118,008 |
| sensors->hierarchy | 1,152 | 80,376 |
| console->telemetry | 1,181 | 79,376 |
| telemetry->console | 1,716 | 93,952 |
| selection | 8,624 | 584,736 |

The displayed +2.0 KiB on hierarchy-to-sensors and +1.9 KiB on telemetry-to-console are buffer-refill granularity,
not additional objects or requested bytes in those windows. No budget ceiling changes. Whole selection-stress
captures (30 cycles) include timeline serialization; their only varying type is byte buffers. All other per-type
counts and byte totals match. The UI-only selection window above ties exactly.

| Pair | Control selection objects / bytes | Candidate selection objects / bytes |
|---:|---:|---:|
| 1 | 298,804 / 20,782,032 | 298,805 / 20,781,992 |
| 2 | 298,802 / 20,781,400 | 298,804 / 20,781,680 |
| 3 | 298,802 / 20,781,416 | 298,804 / 20,781,824 |

Three paired 500-cycle headless captures pass the memory gate. Growth windows are MiB; RSS-after-warmup and p95
are reported by the same gate:

| Pair / version | RSS after warmup MiB | Growth windows MiB | Frame p95 ms |
|---|---:|---|---:|
| 1 / control | 9.69 | [30.16, 3.44, 0.78, 5.47] | 1.46 |
| 1 / candidate | 10.00 | [29.22, 3.75, 0.78, 5.47] | 1.46 |
| 2 / control | 13.75 | [29.84, 4.06, 0.78, 8.91] | 1.47 |
| 2 / candidate | 10.00 | [30.0, 3.91, 0.62, 5.47] | 1.47 |
| 3 / control | 10.47 | [29.53, 3.91, 0.94, 5.62] | 1.50 |
| 3 / candidate | 9.69 | [30.16, 3.28, 0.94, 5.47] | 1.46 |

Median growth windows are `[29.84, 3.91, 0.78, 5.62]` → `[30.00, 3.75, 0.78, 5.47]` MiB. The first window is
+0.16 MiB, a recorded finding; the later windows tie or decrease. Median RSS after warmup is 10.47 → 10.00 MiB.
There was no retry to accept a memory result.

Wasm GC uses 120 warmup and 120 measured frames. Every pair has the same object counts:

| Scene | Control objects | Candidate objects | Control median / p95 ms | Candidate median / p95 ms |
|---|---:|---:|---:|---:|
| full | 4440 | 4320 | 1.40 / 2.70 | 1.40 / 2.50 |
| static | 4440 | 4320 | 1.20 / 2.20 | 1.40 / 2.10 |
| text-heavy | 4440 | 4320 | 1.40 / 2.50 | 1.40 / 2.20 |
| editing | 8724 | 8604 | 1.50 / 3.50 | 1.50 / 2.70 |

All scenes drop 120 objects, one per frame. The static scene's frame median rises 0.2 ms; its p95 falls 0.1 ms.
These are the measured timings, not evidence of a general speedup. Wasm32 also builds and runs in three paired
full-scene browser checks; its build does not enable an object counter, so no Wasm32 scene allocation count is claimed.

| Module | Control bytes | Candidate bytes | Delta bytes |
|---|---:|---:|---:|
| HashLink editor | 102,185,950 | 102,216,099 | +30,149 |
| Showcase Wasm32 | 11,850,962 | 11,868,822 | +17,860 |
| Showcase Wasm GC | 5,855,815 | 5,861,190 | +5,375 |

Editor SHA-256 is `2b627314132a2dae6580e6b5cf27c6ae7d50590d6e5d76888c43b7cd03f3cb13` →
`57fa4883ec951d5d0a9d565fd43995085c99e51b8e9f874f1fb3fea8ff270b2d`. Showcase Wasm32 is
`bfd12f3824d1bcca6de492b23b21f3d3da4c5d051391835f85ef5f558de8b654` →
`66a442f51b4295425faf20bfffdbea91acb7721afbe11543bec930204b5d12c5`; Wasm GC is
`bfe1db39c8dd4b91ac7f4e1700a0da89dec4933e15a220c3e27bf3599d4e295b` →
`74888d82d5a58431a640557f886bd9753f1b6cc2bfe305904b4ac7b3a6832b01`.
Serial exact-window builds report BodyTyped (`bodies`) at 111.90 → 111.51 ms, with no measurable increase.

Tier 2 passes all ten UI scripts, full backend parity (521 fixtures; 14 skips), the 42 UI value checks, the app
suite including CAD plate workflow, all nine retention scenarios, all three paired budget captures and all three
paired memory captures. The compiler cache fix separately passed 839 compiler tests and self-hosting fixed point.
Two detached-setup problems initially blocked the app gates: absent root `build/` for a generated test artifact,
and materialized `.so` version aliases loading the simulation handle registry twice (also reproduced on control).
The setup now creates that directory and preserves private version aliases with identical library bytes. A stale
copied CAD library also lacked `cad_cut_many`; the replacement completed native build has source/ABI inputs identical
to the frozen checkout. These setup fixes change no product source or assertions; their failures remain recorded.

### Closed raw/flags conversions: pre-rebase batch checkpoint (2026-11-10)

The frozen outer app is `2de94628c`; the candidate includes the explicit Flags ports, with other outer code held constant. Control is `a3064590`; candidate is `a01cf81a` (the code before this measurement note). Both use the checkout-built HashLink VM at `3ea38fcf`. Three fixed alternating pairs were run, without selecting a best run. All ten UI scripts, full three-target parity including UI value snapshots, the app suite, all nine retention scenarios, budgets and six 500-cycle headless captures pass. These results precede rebasing onto the newer origin/main; they do not certify that integration.

Per-action medians across the three pairs (KiB counter and frame ms):

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|
| console->telemetry | 74.40 | 73.00 | 1.01 | 1.01 |
| hierarchy->sensors | 110.80 | 111.00 | 1.46 | 1.47 |
| sensors->hierarchy | 77.60 | 78.30 | 1.12 | 1.12 |
| telemetry->console | 88.80 | 89.40 | 1.08 | 1.07 |
| hover-away | 13.60 | 13.60 | 0.42 | 0.42 |
| hover-enter | 0.50 | 0.50 | 0.00 | 0.00 |
| hover-field | 12.40 | 12.30 | 0.42 | 0.43 |
| hover-inside | 0.50 | 0.50 | 0.00 | 0.00 |
| hover-other | 10.00 | 9.90 | 0.41 | 0.41 |
| idle | 0.30 | 0.30 | 0.01 | 0.01 |
| idle-focused | 0.30 | 0.30 | 0.01 | 0.01 |
| scroll-inspector | 21.70 | 21.70 | 0.71 | 0.71 |
| type-backspace | 16.20 | 16.10 | 0.41 | 0.41 |
| type-char | 16.10 | 16.10 | 0.41 | 0.42 |
| selection | — | — | 2.44 | 2.43 |

The KiB counter crosses different shared-buffer refill boundaries. Exact censuses of the second warm action window stop before timeline serialization. Every tab action and selection allocates fewer objects and bytes, including the actions whose KiB counter rises:

| Action | Control objects / bytes | Candidate objects / bytes |
|---|---:|---:|
| hierarchy->sensors | 1,680 / 118,008 | 1,677 / 117,240 |
| telemetry->console | 1,716 / 93,952 | 1,713 / 93,208 |
| console->telemetry | 1,181 / 79,376 | 1,178 / 78,584 |
| sensors->hierarchy | 1,152 / 80,376 | 1,149 / 79,656 |
| selection | 8,624 / 584,736 | 8,621 / 580,816 |

Raw paired memory results (MiB; no retry):

| Pair / version | RSS after warmup | Growth windows | Frame p95 ms |
|---|---:|---|---:|
| 1 / control | 10.31 | [29.53, 4.06, 0.78, 5.47] | 1.45 |
| 1 / candidate | 10.62 | [28.91, 4.06, 0.94, 5.62] | 1.45 |
| 2 / candidate | 9.69 | [30.16, 3.28, 0.78, 5.62] | 1.44 |
| 2 / control | 9.69 | [29.84, 3.44, 0.78, 5.47] | 1.44 |
| 3 / control | 10.00 | [29.53, 3.59, 0.78, 5.62] | 1.44 |
| 3 / candidate | 10.47 | [29.22, 3.91, 0.78, 5.78] | 1.45 |

Median growth windows are `[29.53, 3.59, 0.78, 5.47]` → `[29.22, 3.91, 0.78, 5.62]` MiB; warmup RSS is 10.00 → 10.47 MiB. The +0.32 and +0.15 MiB windows and +0.47 MiB warmup are recorded findings within the previously recorded page/allocator variation, not a claimed memory reduction. Exact program allocation totals decrease.

Wasm GC has 120 warmup and 120 measured frames. Each of the three pairs has identical control/candidate object totals:

| Scene | Control objects | Candidate objects | Control median / p95 ms | Candidate median / p95 ms |
|---|---:|---:|---:|---:|
| full | 4320 | 4320 | 1.70 / 2.20 | 1.70 / 2.20 |
| static | 4320 | 4320 | 1.50 / 2.00 | 1.50 / 2.10 |
| text-heavy | 4320 | 4320 | 1.40 / 2.00 | 1.50 / 2.10 |
| editing | 8604 | 8604 | 1.60 / 2.30 | 1.70 / 2.30 |

Wasm32 also passes three fixed full-scene browser pairs; its memory-stat build does not provide a GC object count. Both Web modules differ, so browser measurements were required.

| Module | Control bytes | Candidate bytes |
|---|---:|---:|
| HashLink headless editor | 102,205,475 | 105,954,981 |
| Wasm32 Showcase | 11,868,822 | 12,041,570 |
| Wasm GC Showcase | 5,861,190 | 5,903,055 |

The development editor module is 105,148,935 bytes (SHA-256 `7d878d1a97b857fa64fc42932c38392c8621bd11669b5b66a3da1ea2da650711`); the prior recorded `a3064590` module was 102,216,099 bytes. The fresh control module has SHA-256 `0affd3510c6710cad2ae69be6ffc1bb93b03ec249f84eec376741b12db419533`; absolute checkout/debug paths differ from its earlier build. Size growth includes synthesized raw/flags methods and nominal tag metadata, not additional action allocations.

Two setup failures produced no guest measurements: the Web GC configure initially enabled the Wasm32-only memory-stat option, and the detached control initially lacked the HashLink source needed by the profiling harness’s CMake step. Both configurations were corrected before these fixed pairs. Captures were deleted after their numbers were extracted; measurement-only action hooks stay in detached checkouts.

### Restoring self-hosting after origin/main 090589e5

Integration brought in compiler sources that stock Haxe accepted but the Haxeon seed could not compile. The source
ports retain final fields and checks; they do not add language features, scalar specialization, Dynamic casts or
verifier exceptions.

| Originating commit | Failure / source dependency | Correction |
|---|---|---|
| e9250493, 1d8b480a, 38cecb6e, 555583f0, 941bda3b | `final class` is unsupported | Ordinary internal classes; their final fields stay final |
| 69ee0334 | Cannot infer `TargetProfile.portable` | Explicit types on the three shared profiles |
| 444fe6c8, 1651826d | Nullable cache / pipeline accessed through a correlated Boolean | Check the actual local before dereferencing it |
| 1d8b480a | Nullable debug payload producer called as a field | Check the local callback; reject a section with neither payload nor producer |
| aabb57b6 | `Type.getEnum` / reflective opcode comparison | Exhaustive typed comparison of all 68 instructions, register arrays and label bijections |
| a3cee201 | Nullable native-storage index, invariant replay arrays, nullable object view | Check both indices; compare replay arrays through a generic helper; guard object lookup |
| 555583f0 | Nullable verifier-table reads and unsupported `Type.typeof` | Explicit checked reads and supported object/String tests; same identity-print cache |
| 6d9515ec | Nullable values read inside fact-rendering callbacks | Typed nullable parameters with explicit presence checks |
| 555583f0 | Generic `Map<String,V>` wrapper reinterprets a Boolean map as a reference map | Typed read/membership callbacks preserve each concrete map representation |

The last failure was reproduced separately: `ReadView<V>` storing `Map<String,V>`, instantiated with `Bool`, throws
`Can't cast map_string_bool to map_string_ref` at construction. The opaque-map/scalar specialization limitation is
recorded under a2 in GENERIC_SPECIALIZATION.md. The verifier's table is now a storage-independent read view with no
unchecked map conversion. Missing, false and true results remain distinct.

Validation on the frozen source: **854 passed, 0 failed** with eight workers; compiler self-hosting reaches a
byte-identical stage-1/stage-2 fixed point; the read-view fixture passes HashLink, Wasm32 and Wasm GC with inlining
off/on. Typed opcode tests check copied arrays, changed operands, different constructors and consistent injective
label renaming. The existing enum-tag IR fixture was ported to the new explicit target-profile argument.

Full parity also found an independent integration issue in f5fe8b0a: frontend verification runs before Wasm constructs
its closure escape adapters, so `inline-enum-callback-escape` is rejected prematurely. This is the next correctness
fix; this checkpoint does not claim a Tier 2 pass or authorize publication.

### Closed raw/flags conversions: rebased integration checkpoint (2026-11-10)

Frozen compiler control: `093617bb`; candidate: `19843cdd`, rebased onto `090589e5`. The frozen outer app remains `2de94628c` with the same explicit Flags ports and the already committed NativeIdentity API port from outer `e0b912540`. Both sides use current stdlib/UI sources and the checkout VM at `3ea38fcf`. Compiler source is selected explicitly with `HAXEON_COMPILER_SOURCE`; setting `HAXEON_COMPILER_HL` alone does not select the project compiler. Earlier same-worker attempts were discarded and are excluded here.

All ten UI scripts, full three-target parity including UI snapshots, the freshly compiled app suite (including CAD), and all nine retention scenarios pass. The compiler suite passes **856/856** and self-hosting reaches a fixed point. The String pending-resource smoke test is restored and its original runtime behavior is preserved on all three targets, in both inlining modes. The Wasm closure-verification ordering fixture also checks cold/edit/restore builds, fresh recomputation and rejection of unadapted payloads.

All four production modules differ, so paired measurements were required. Three fixed alternating pairs use one capture per side, without retries or best-run selection. Per-action medians:

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|
| console->telemetry | 73.00 | 73.00 | 1.23 | 1.01 |
| hierarchy->sensors | 109.30 | 111.00 | 1.78 | 1.46 |
| sensors->hierarchy | 78.30 | 78.30 | 1.38 | 1.12 |
| telemetry->console | 89.40 | 89.40 | 1.30 | 1.07 |
| hover-away | 13.60 | 13.60 | 0.43 | 0.42 |
| hover-enter | 0.50 | 0.50 | 0.00 | 0.00 |
| hover-field | 12.30 | 12.30 | 0.44 | 0.43 |
| hover-inside | 0.50 | 0.50 | 0.00 | 0.00 |
| hover-other | 9.90 | 9.90 | 0.42 | 0.42 |
| idle | 0.30 | 0.30 | 0.01 | 0.01 |
| idle-focused | 0.30 | 0.30 | 0.01 | 0.01 |
| scroll-inspector | 21.70 | 21.70 | 0.72 | 0.71 |
| type-backspace | 16.10 | 16.10 | 0.42 | 0.41 |
| type-char | 16.10 | 16.10 | 0.42 | 0.42 |
| selection | — | — | 2.45 | 3.28 |

The hierarchy KiB increase is shared-buffer refill granularity, not additional program allocation: the exact warm second-action window ties in objects and bytes. The same exact comparison includes every tab transition and selection, stopping before timeline serialization. Selection-stress frame time rose 2.45 → 3.28 ms despite identical allocation; this timing finding is retained for follow-up rather than hidden by rerunning.

| Action | Control objects / bytes | Candidate objects / bytes |
|---|---:|---:|
| hierarchy->sensors | 1,677 / 117,240 | 1,677 / 117,240 |
| telemetry->console | 1,713 / 93,208 | 1,713 / 93,208 |
| console->telemetry | 1,178 / 78,584 | 1,178 / 78,584 |
| sensors->hierarchy | 1,149 / 79,656 | 1,149 / 79,656 |
| selection | 8,621 / 580,816 | 8,621 / 580,816 |

All six 500-cycle memory captures pass the unchanged gate. Raw paired results (MiB):

| Pair / version | RSS after warmup | Growth windows | Frame p95 ms |
|---|---:|---|---:|
| 1 / control | 10.16 | [30.0, 3.75, 0.78, 5.62] | 3.67 |
| 1 / candidate | 10.00 | [29.69, 3.59, 0.62, 5.78] | 3.21 |
| 2 / candidate | 10.47 | [29.84, 3.75, 0.78, 5.94] | 3.03 |
| 2 / control | 10.00 | [29.84, 3.44, 0.94, 5.62] | 3.78 |
| 3 / control | 10.00 | [30.47, 3.59, 0.78, 5.62] | 1.84 |
| 3 / candidate | 10.16 | [29.84, 3.75, 0.78, 5.62] | 2.17 |

RSS-growth medians from cycles 200–500 are 10.00 → 10.16 MiB; growth-window medians are `[30.00, 3.59, 0.78, 5.62]` → `[29.84, 3.75, 0.78, 5.78]` MiB. The +0.16 MiB shifts remain recorded within the established paired-window bounds; no ceiling changed.

Browser comparisons use 120 warmup and 120 measured frames. Each Wasm GC pair has identical object counts; all thirty browser runs pass:

| Target / scene | Control objects | Candidate objects | Control median / p95 ms | Candidate median / p95 ms |
|---|---:|---:|---:|---:|
| Wasm GC / full | 4320 | 4320 | 2.30 / 3.00 | 2.30 / 2.80 |
| Wasm GC / static | 4320 | 4320 | 2.30 / 2.80 | 2.20 / 2.70 |
| Wasm GC / text-heavy | 4320 | 4320 | 2.30 / 2.80 | 2.30 / 3.10 |
| Wasm GC / editing | 8604 | 8604 | 2.70 / 3.50 | 2.50 / 3.10 |
| Wasm32 / full | — | — | 2.20 / 2.90 | 2.40 / 3.20 |

Wasm32 also ties exactly in every pair: 3,840 measured allocation calls, 132,480 allocated bytes, 572,144-byte heap high-water, 10,528-byte measured heap growth and one collection. Its full-scene median/p95 and Wasm GC text-heavy p95 increases above are recorded timing findings. Wasm32 does not expose a Wasm GC object count.

| Module | Control bytes | Candidate bytes |
|---|---:|---:|
| HashLink editor | 105,173,529 | 105,172,608 |
| HashLink headless editor | 105,979,410 | 105,978,489 |
| Wasm32 Showcase | 12,041,570 | 12,041,570 |
| Wasm GC Showcase | 5,903,055 | 5,903,055 |

Loaded module SHA-256 identities:

| Module | Control SHA-256 | Candidate SHA-256 |
|---|---|---|
| editor.hl | `5a90c9e1af23e8793c17a60e10a49de902a43bcaaaea72a361a4fc3b6fda7377` | `a6604dd7624cde41c94253029328efd7a506a38cad23d47b78946bb4ff46a475` |
| headless.hl | `29c93655ad9ff97823b5c0468be8aaa199217229a0f7bbcfb3e97e533f1eec87` | `280640a5b33e5ce3fddccc1ccb282860a1bd7a9dbb244c308428a77be183218f` |
| web32.wasm | `cb14fbd18e3786cb1746a497b21a4e10a71ce53095a64a12f9a40a122df6a09e` | `3116b56dbab77881a844aafb3642694fbc1ed42f2a96e9ae5502ab519e4b1136` |
| webgc.wasm | `ea8f61e73e8434cacf7afff98b47933417587bb27f8769eb440453bd6a75acfc` | `f663371e9dac47c9bc3c15456b5cad9657b6e5728c7114775a49c5fc92e76721` |

The control editor worker lost its connection before producing a module; the existing one-shot path compiled the explicitly selected control source successfully. This was not a guest measurement retry. Captures were deleted after extraction; the exact-action harness was restored and remains measurement-only in the detached checkout. New build and capture outputs are on root; recorded superseded DATA1 outputs were removed.

### Quiet-machine selection and Wasm32 timing check (2026-11-10)

The timing findings in the preceding checkpoint were investigated before starting the next enum conversion group. Five fixed alternating pairs repeat **selection-stress only**, using the original `093617bb` control and `19843cdd` candidate modules and the unchanged 60-cycle budget scenario. A further five pairs repeat the Wasm32 full scene with the same guests and 120 warmup / 120 measured frames. No capture was selected or retried.

An unrelated eight-worker compiler suite and its subsequent Wasm parity run were allowed to finish first; no other session’s process was stopped. Live sampling before the repeat showed about 93% idle CPU and no active compiler work. The pre-existing background Node process remained unchanged. Only the benchmark’s own browser workers were active during the Web comparisons.

| Pair | Selection control ms | Selection candidate ms | Wasm32 control median / p95 ms | Wasm32 candidate median / p95 ms |
|---|---:|---:|---:|---:|
| 1 | 2.44 | 2.42 | 1.50 / 2.00 | 1.50 / 2.00 |
| 2 | 2.43 | 2.41 | 1.60 / 2.10 | 1.80 / 2.30 |
| 3 | 2.41 | 2.46 | 1.40 / 2.10 | 1.50 / 2.00 |
| 4 | 2.43 | 2.43 | 1.50 / 2.00 | 1.50 / 2.10 |
| 5 | 2.45 | 2.43 | 1.40 / 2.10 | 1.50 / 2.10 |

**Selection medians tie at 2.43 ms; Wasm32 median/p95 tie at 1.50 / 2.10 ms.** Neither earlier timing shift reproduces in the quiet window. This supports host contention rather than a persistent compiler regression; the individual interfering process was not isolated experimentally. Per the investigation’s stopping rule, no bisect or code change is justified by these results. Source and loaded-module hashes are unchanged from the preceding checkpoint.

Every Wasm32 run again records 3,840 allocation calls / 132,480 bytes, one collection and a 262,160-byte largest allocation. Heap medians tie at 572,144-byte high-water and 10,528-byte measured growth; individual readings are retained below rather than described as identical:

| Pair | Control heap high-water / growth bytes | Candidate heap high-water / growth bytes |
|---|---:|---:|
| 1 | 572,864 / 10,752 | 572,144 / 10,528 |
| 2 | 572,144 / 10,528 | 572,176 / 10,752 |
| 3 | 572,144 / 10,528 | 572,144 / 10,528 |
| 4 | 572,144 / 10,528 | 572,144 / 10,528 |
| 5 | 572,144 / 10,528 | 572,144 / 10,528 |

All ten selection captures and ten Web captures pass. Successful captures were removed after extracting these measurements. Aggregate records retain every pair, module hash and result; budget ceilings and measurement rules are unchanged.

### Gated layout and text enum batch (2026-11-10)

This comparison freezes source at `8897ddd1` against published `9180b6d8` (the same compiler/UI code as
`19843cdd`, before this batch). Both use outer app `2de94628c` with the same required Flags and NativeIdentity
ports, checkout VM `3ea38fcf`, and this machine. The compiler sources are unchanged. No own compiler jobs ran
during the paired measurements. Each measure uses three alternating control/candidate pairs; every sample is
included, with no retries or selected fastest run.

All ten final-source UI scripts, full parity including UI snapshots (**42 positive / 198 negative**, three
targets with inlining off/on), app/CAD, retention, editor budgets and headless memory gates pass. The compiler
suite passes **856/856**. All production modules differ, so no Tier 3 comparison was skipped.

| Development module | Control bytes | Candidate bytes |
|---|---:|---:|
| editor.hl | 105,172,608 | 105,419,778 |
| headless.hl | 105,978,489 | 106,223,172 |
| webgc.wasm | 5,903,055 | 6,010,873 |
| web32.wasm | 12,041,570 | 12,500,276 |

Module SHA-256 pairs (control → candidate):

- `editor.hl`: `a6604dd7624cde41c94253029328efd7a506a38cad23d47b78946bb4ff46a475` → `2c5e92b5f8d1a9b1c16a08f7535c388f823019be0399c6ed4f314987ad339f7f`.
- `headless.hl`: `280640a5b33e5ce3fddccc1ccb282860a1bd7a9dbb244c308428a77be183218f` → `c38e087832eb1da313f504c8f205ac2c0f0e4bba8bffcc23ee1fb6986cdbde35`.
- `webgc.wasm`: `f663371e9dac47c9bc3c15456b5cad9657b6e5728c7114775a49c5fc92e76721` → `c1cbfa6c2689805237bbe01002d078b42543a3ac458e75ea62cdfc6155e32c09`.
- `web32.wasm`: `3116b56dbab77881a844aafb3642694fbc1ed42f2a96e9ae5502ab519e4b1136` → `2769d31b4b32bce1dfe011e44dbe8ffa4eead136822fddc0e79f4f366efd01c1`.

The added policy declarations and typed helpers increase metadata/code size; the action measurements below
show no allocation increase. Allocation medians use the existing refill-quantized KiB counter for fourteen
actions. Selection has no allocation field in this harness output: its allocation column uses the exact
second-action window census below instead. Times are medians of the three per-run frame medians.

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|
| hover-away | 13.6 | 13.6 | 0.43 | 0.43 |
| hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-field | 12.3 | 12.3 | 0.44 | 0.43 |
| hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-other | 9.9 | 9.9 | 0.43 | 0.42 |
| idle | 0.3 | 0.3 | 0.01 | 0.01 |
| idle-focused | 0.3 | 0.3 | 0.01 | 0.01 |
| scroll-inspector | 21.7 | 21.7 | 0.72 | 0.72 |
| type-backspace | 16.1 | 16.1 | 0.42 | 0.42 |
| type-char | 16.1 | 16.1 | 0.42 | 0.42 |
| selection | 567.203125 (exact) | 567.203125 (exact) | 2.45 | 2.49 |
| console->telemetry | 73.0 | 73.0 | 1.01 | 1.03 |
| hierarchy->sensors | 111.0 | 109.5 | 1.48 | 1.49 |
| sensors->hierarchy | 78.3 | 78.3 | 1.12 | 1.13 |
| telemetry->console | 89.4 | 89.4 | 1.07 | 1.09 |

Selection frame samples are control **2.40 / 2.69 / 2.45 ms**, candidate **2.49 / 2.67 / 2.44 ms**.
The +0.04 ms median difference lies inside the paired spread; the earlier 34% timing finding is not reproduced.

The exact HashLink census starts before the second input action and stops after its frame/GC work, before
timeline serialization. Its instrumentation exists only in the detached gate checkout. Both programs are built
with the same compiler and VM; the control UI sources are frozen at `9180b6d8`. The seven new policy value
classes are absent from the control module and present in the candidate, confirming the intended source variants.

| Exact action window | Control objects | Candidate objects | Control bytes | Candidate bytes |
|---|---:|---:|---:|---:|
| hierarchy->sensors | 1,677 | 1,677 | 117,240 | 117,240 |
| selection | 8,621 | 8,621 | 580,816 | 580,816 |

Per-type histograms also match after summing entries with the same printed type name (the native census
keys entries by type pointer, so printed labels can repeat). Hierarchy-to-sensors moves between refill
boundaries; its lower KiB counter is not a reduction in allocated object bytes. No budget ceiling changes.

All six 500-cycle headless memory runs pass. Values below are MiB: cumulative RSS growth from cycles
200–500, followed by growth in windows 100–200, 200–300, 300–400 and 400–500.

| Pair | Build | 200–500 growth | Window 1 | Window 2 | Window 3 | Window 4 |
|---|---|---:|---:|---:|---:|---:|
| 1 | control | 10.47 | 29.22 | 3.59 | 1.09 | 5.78 |
| 1 | candidate | 10.16 | 30.00 | 3.75 | 0.78 | 5.62 |
| 2 | candidate | 10.16 | 30.00 | 3.75 | 0.78 | 5.62 |
| 2 | control | 10.00 | 30.16 | 3.59 | 0.78 | 5.62 |
| 3 | control | 12.03 | 29.69 | 3.75 | 0.78 | 7.50 |
| 3 | candidate | 9.84 | 29.84 | 3.28 | 0.78 | 5.78 |

The cumulative growth medians from cycles 200–500 are **10.47 → 10.16 MiB**. Window-growth
medians are **29.69 / 3.59 / 0.78 / 5.78** → **30.00 / 3.75 / 0.78 / 5.62 MiB**.
Correction: `rssAfterWarmupMiB` is growth from cycle 200 to 500, not an absolute RSS baseline.
The previous endpoint estimates added it to windows that it already includes and double-counted
that growth. Those endpoint estimates are withdrawn; the raw window rows above are unchanged.
No run is discarded or repeated.

Browser pairs use the same host, explicit guest hashes above, 120 warmup frames and 120 measured frames.
Numbers below are medians across all three pairs.

| Target / scene | Control median / p95 ms | Candidate median / p95 ms | Control objects | Candidate objects |
|---|---:|---:|---:|---:|
| Wasm GC / full | 1.80 / 2.20 | 1.80 / 2.30 | 4320 | 4320 |
| Wasm GC / static | 1.60 / 2.20 | 1.70 / 2.10 | 4320 | 4320 |
| Wasm GC / text-heavy | 1.70 / 2.20 | 1.70 / 2.20 | 4320 | 4320 |
| Wasm GC / editing | 1.80 / 2.30 | 1.70 / 2.40 | 8604 | 8604 |
| Wasm 32 / full | 1.70 / 2.20 | 1.70 / 2.20 | — | — |

Every Wasm GC pair has the same allocation histogram: full/static/text-heavy are 120 frames at 36 objects;
editing is 93 frames at 79, 24 at 47, and 3 at 43 (8,604 total). Editing phase indices differ between runs;
the histograms and totals match, rather than every indexed frame.

Wasm32 records **3,840 allocation calls / 132,480 bytes**, one collection and a largest allocation of
262,160 bytes in every run. Heap high-water samples are control **572,144 / 572,864 / 572,864 bytes**,
candidate **572,536 / 571,816 / 572,536**; growth samples are **10,528 / 10,752 / 10,752** and
**10,592 / 10,368 / 10,592** respectively. Medians decrease by 328 and 160 bytes; measured allocation bytes
and calls are unchanged.

Raw aggregate reports, guest hashes, exact type tables and build scripts are retained in the session’s disk
measurement archive; individual captures are deleted after extracting their numbers. The final FFI enum group
uses this batch as its next control.

## Release code size after enum conversions (2026-11-11)

The pre-enum control is `9180b6d8`, the source behind the previously recorded 12,041,570-byte development Wasm32 module. The first release candidate is `1d286898` (same compiler/UI source as `bb4072f8`). Both use the same frozen outer application source and required mechanical API ports. `--build-mode release` omits development metadata; allocation counters are disabled in these size modules.

| Release module | Pre-enum control bytes | Initial enum candidate bytes | Growth |
|---|---:|---:|---:|
| web32 | 6,728,120 | 6,947,390 | +219,270 (3.26%) |
| webgc | 3,922,261 | 4,008,481 | +86,220 (2.20%) |
| editor | 28,562,565 | 28,899,137 | +336,572 (1.18%) |

This growth is a regression to fix, not an accepted cost of nominal tags. The measured closure-adapter and checked-closure-dispatch families are identical on both Web targets. Wasm32 emits two copies of the finalized dynamic stringifier and regenerates its numeric formatting helpers; enum additions amplify that duplicate. Typed nullary-enum equality also emits per-case bodies despite having only an integer tag to compare.

| Release section | Wasm32 delta bytes | Wasm GC delta bytes | HashLink delta bytes |
|---|---:|---:|---:|
| code | +177,639 | +66,134 | 0 |
| constants | 0 | 0 | +2,438 |
| custom: name | +12,972 | +5,930 | 0 |
| data | +27,882 | +7,853 | 0 |
| debugFiles | 0 | 0 | -8 |
| debugSections | 0 | 0 | +100,179 |
| function signatures | +217 | +232 | 0 |
| functionDebug | 0 | 0 | +13,140 |
| functions | 0 | 0 | +196,783 |
| globals | +140 | +2,080 | +572 |
| natives | 0 | 0 | +84 |
| reflectionMembers | 0 | 0 | +1,149 |
| scalarConstants | 0 | 0 | +52 |
| strings | 0 | 0 | +13,891 |
| table elements | +434 | +232 | 0 |
| types | -14 | +3,759 | +8,292 |

The first correction makes synthesized payload-free equality constant-size before
source inlining, then lowers typed calls and extracted-index comparisons to one
nominal-tag `Equal`. The 32-case fixture checks nullable tags and struct fields,
inspects the scalar IR and executes on HashLink, Wasm32 and Wasm GC with inlining
off/on. Tier 1: **858 passed, 0 failed**; self-hosting reaches identical stage-1
and stage-2 modules. Module-size checkpoints below track the cumulative fixes;
the final requirement is zero unexplained growth and zero tag representation overhead.


| Release checkpoint | web32 bytes | webgc bytes | editor bytes |
|---|---:|---:|---:|
| Pre-enum `9180b6d8` | 6,728,120 | 3,922,261 | 28,562,565 |
| Initial enum candidate `1d286898` | 6,947,390 | 4,008,481 | 28,899,137 |
| Constant-size tag equality (`127db7b2`, rebased as `bd18d35a`) | 6,932,990 | 3,994,431 | 28,897,242 |
| Shared stringifier, reflection and closed-tag ABI (`d2ca28aa`) | 6,631,066 | 3,983,236 | 28,303,948 |

After rebasing onto `9baf8a31`, equality recognition uses the declared `Equality`
function role, including in the IR fixture. It does not infer the role from a
helper's name.

The next correction replaces the Wasm32 dynamic stringifier in its registered
slot. Previously finalization appended a complete replacement, installed that
body in the original slot, and left the appended function in the module. It also
created the integer formatters again. The control reproduces the regression-test
error, “String finalization appended a duplicate function or moved its slot”.
Registration now creates each numeric formatter once, and finalization only
replaces the existing stringifier body. The slot test finalizes twice and checks
that the function count and indices stay fixed. Executed fixtures cover numbers,
enums, class `toString`, booleans and null on all three targets, with inlining off
and on. This preserves early numeric-helper registration for Wasm32 GC wrapping.

The next reflection checkpoint shares HashLink's presence, deletion and copy
operations for tag-only layouts. Get/set still project nominal values at an
actual reflective boundary, and field listings retain their constant names: the
native listing helpers allocate temporary field arrays. The new fixture checks
the helper set and get/set/list/copy/delete semantics, including a tag-typed
closure field, on all three targets with inlining off/on. Tier 1: 862 passed,
0 failed; self-hosting fixed point `8044e4d7f1608c185a8e51f0def6b9768788a2747116de8ec5ece3c725df663f`.
Release size attribution follows after the remaining representation fixes; no
new paired timing series is used for this closeout.


The closed-tag release ABI checkpoint removes descriptors for enums with no boxed or reflective carrier,
uses ordinary integer arrays when the nominal element descriptor cannot be observed, removes the now-unused
array factory declaration and equality definitions, and deletes index extraction instructions made dead by
tag equality lowering. The Wasm GC root planner no longer treats a constant tag constructor as allocating.
The paired fixture uses the same fields, calls, closure and array operations in both versions:

| Target | Inlining | Int abstract release bytes | Plain enum release bytes | Enum overhead |
|---|---|---:|---:|---:|
| HashLink | off | 5,450 | 5,423 | -27 |
| HashLink | on | 5,443 | 5,419 | -24 |
| Wasm32 | off | 234,916 | 234,916 | 0 |
| Wasm32 | on | 234,811 | 234,811 | 0 |
| Wasm GC | off | 1,904 | 1,904 | 0 |
| Wasm GC | on | 1,839 | 1,839 | 0 |

Every module executes the same result. Separate release executions cover nested reflective field get/set,
field names and an erased array round trip, keeping checked nominal escapes intact. This is one small paired
fixture; no new size-analysis framework or paired timing series is introduced.

Tier 1 for the closed-tag release ABI: **863 passed, 0 failed**; self-hosting fixed point
`3ac9d78bf737e77c3bfb7d1e1096f01a0b9a7022253646c73a5b08f0ade57c31`.


The structural follow-up to `d2ca28aa` shares `IrEnumEscapeReach` between payload
eligibility, closed-tag ABI selection and reflected Dynamic descriptor
registration. Both storage decisions reject the same class/interface/container
and closure escape graph; registered layouts include anonymous records. Map
writes and bound receiver environments are indexed once, and native opaque
handles remain ABI leaves. The array factory carries `Array(element)` directly
until storage selection and emits I32 allocation for a closed tag without an
allocation/cast sequence matcher.

The strengthened paired release fixture includes an unrelated Dynamic comparison
alongside fields, calls, closures and arrays. Nested declared classes and anonymous
records retain reflection get/set/listing and erased-array round trips. Results
with inlining off/on:

| Target | Int abstract bytes, off/on | Enum bytes, off/on | Representation growth |
|---|---:|---:|---:|
| HashLink | 5,509 / 5,502 | 5,483 / 5,478 | -26 / -24 |
| Wasm32 | 235,164 / 235,039 | 235,164 / 235,039 | 0 / 0 |
| Wasm GC | 2,514 / 2,449 | 2,514 / 2,449 | 0 / 0 |

Reflective equality now has a declared function role. Requesting an unused helper
cannot register its enum for Dynamic equality; reflected layouts and native
signatures still register genuinely exposed values, including incremental
compilations. The all-target fixtures retain custom declared equality through
reflected fields and arrays. Tag-only fields use the native runtime projection,
including field listing, rather than generated per-layout adapters.

The shared reach query memoizes each value/reference shape and indexes static
fields by owner. Its regression fixture includes a 32-level diamond of enum
payloads, along with interface inheritance, derived class fields, static fields,
erased map contents and bound closure receivers. Unknown array-native names
fail closed, including a forged array-prefixed native with a Dynamic argument;
a forged invalid typed factory is rejected by the IR verifier.

Tier 1 for the structural follow-up: **864 passed, 0 failed** with eight workers.
Self-hosting stages are identical at **36,695,628 bytes**, SHA-256
`58b21dd4b1446a6a4c90b29ea58ff2a00058f4d6d0875126a4e83f86bdbf4e2d`.
The focused release-size, transitive Dynamic/reflection, tag-field projection,
array-place and incremental equality fixtures pass on all three targets with
inlining off/on. No paired timing series is added for these size corrections.

Release checkpoint after the shared reach/factory correction, against frozen
pre-enum control `9180b6d8` (same app and Showcase inputs, counters off):

| Module | Control bytes | Checkpoint bytes | Delta |
|---|---:|---:|---:|
| Showcase Wasm32 | 6,728,120 | 6,630,713 | -97,407 |
| Showcase Wasm GC | 3,922,261 | 3,982,976 | +60,715 |
| HashLink editor | 28,562,565 | 27,402,978 | -1,159,587 |

This is an intermediate size receipt, not acceptance of the remaining growth.
Attribution found a redundant Wasm32 native closure-receiver probe: its identical
217-byte physical body is emitted 122 times, once per semantic native alias,
versus 42 copies in the control. The semantic signatures must remain distinct
for checked Dynamic closure restoration; their physical native implementation
can be shared. That correction and the complete release ledger precede publication.


### Final release attribution and physical closure probes

The final receiver-probe correction shares one physical Wasm32 implementation
for the exact `__closure_receiver_if_match` native operation. Semantic function
signatures and checked Dynamic restoration remain distinct. The 32-signature IR
fixture fails on the preceding source and passes after the correction; executed
fixtures reject the wrong nominal signature on HashLink, Wasm32 and Wasm GC,
with inlining off/on. No generated function name or signature-prefix heuristic
selects the operation.

Final release inputs are frozen at pre-enum compiler `9180b6d8` and the same
outer application/Showcase sources used throughout the size comparison. Release
mode disables development metadata and allocation counters. The small paired
fixture includes fields, arrays, calls and closures plus an unrelated Dynamic
comparison; the two Wasm targets have exactly equal byte counts and HashLink
is 24–26 bytes smaller for the plain enum. This is the test of representation
overhead; actual printed/reflected/native enum behavior is itemized separately.

The final exact 15-action census uses the same calibrated isolated action
windows as ALLOCATION_CENSUS.md. Its frozen table remains the published
`bb4072f8` checkpoint, rather than silently rewriting its source version. The
closeout has 16,251 objects / 1,048,304 bytes across one instance of every action,
versus 16,252 / 1,048,328 at that checkpoint. `type-char` is 417 / 16,360 versus
418 / 16,384: the 24-byte TextEditIntent object disappears, and its 32-byte
closure changes signature but not size. Every other action is identical.


| Release module | Pre-enum `9180b6d8` bytes | Final bytes | Delta |
|---|---:|---:|---:|
| Showcase Wasm32 | 6,728,120 | 6,595,956 | -132,164 |
| Showcase Wasm GC | 3,922,261 | 3,982,976 | +60,715 |
| HashLink editor | 28,562,565 | 27,402,978 | -1,159,587 |

The function-body ledger below is a disjoint partition of the emitted-function
census, including duplicate physical bodies in the control. The names denote
actual retained behavior, not all declared enums. Checked tag carriers and
Dynamic varargs/type dispatch survive only for reachable Dynamic/reflection
signatures and registered field layouts. In particular, discrete style values
have a public `inspect():Dynamic` API, and the native/inspector enum names are
actually printed or reflected. Their nominal cases are not unobserved tags.

| Function-body family, delta bytes | Wasm32 | Wasm GC | HashLink editor |
|---|---:|---:|---:|
| Ordinary source methods and existing runtime bodies (net) | -1,886 | -4,308 | -829,626 |
| Case stringification | -22,361 | +9,546 | +0 |
| Checked Dynamic tag box/unbox | +8,544 | +6,436 | +11,800 |
| Checked native reads and decoders | +2,629 | +2,934 | +11,257 |
| Dynamic varargs adapters | +11,235 | +10,376 | +0 |
| Dynamic/reflected type and equality dispatch | +13,574 | +16,097 | +4,498 |
| Exhaustive UI/native mappings (including moved functions) | +6,591 | +6,751 | +4,631 |
| Initializers | -7,949 | -5,054 | -2,112 |
| Reflective discrete style inspection | +5,355 | +3,059 | +2,310 |
| Retained enum equality bodies | -3,312 | -3,312 | -26,062 |
| Typed closure adapters and casts | +0 | +0 | +0 |

The positive families are deliberate checked native reads/decoders, exhaustive
UI/native mappings, and the actual printed/reflected inspection API. The
inspector exposes the seven typed discrete style values; retaining their
nominal checked casts and case stringification is required behavior. The
Wasm32 ordinary/runtime row includes +17,216 bytes in boxed/reflected
`__dynamic_equal`, array type tests/names, enum/object classification and GC
tracing, +1,302 in casts for inspected style classes, +1,300 in Hashable case
implementations used by the new enum fingerprints, +1,263 in typed style-property
construction and +282 in scalar/native bridges. Those Hashable implementations
belong to the eight layout enums that are also exposed through reflection and
inspection; they are not helpers for closed, unobserved tags. Offsetting entries
are -8,897 for the physical receiver probe versus the control's 42 copies,
-7,593 in source closure adapters, -1,838 in closure bodies, -626 in invoke
helpers, -393 in the shared numeric formatters, and -3,902 in the other source
methods. These entries sum to -1,886. No unmatched positive code-growth bucket
is accepted as tag representation cost.

The typed closure-adapter/cast families are exactly unchanged on both Wasm
targets (Wasm32 1,061,378 bytes; Wasm GC 25,303). They do not multiply for tags.
The receiver query is a separate native operation and now has one 217-byte
body, rather than 122. The Wasm32 stringifier count falls from two physical
bodies to one, 80,789 -> 58,428 combined bytes; GC's one body grows by 9,546
for reachable printed/reflected cases. Numeric formatters are registered once.
None of these counts treats a second copy as required stringification.

The section ledger accounts for every byte of each complete module, including
function-body framing, signatures, table elements and LEB/name widths. Zero
entries are omitted. It is not valid to compare code alone and ignore these
bytes, or to present name-table savings as evidence that tag transport is free;
that property is established separately by the paired fixture above.

| Complete module section delta bytes | Wasm32 | Wasm GC | HashLink editor |
|---|---:|---:|---:|
| code | +12,498 | +42,657 | +0 |
| constants | +0 | +0 | -8,589 |
| custom: name | -172,842 | +4,058 | +0 |
| data | +27,882 | +7,853 | +0 |
| debugFiles | +0 | +0 | -2,693 |
| debugSections | +0 | +0 | -314,866 |
| function signatures | +54 | +154 | +0 |
| functionDebug | +0 | +0 | -10,573 |
| functions | +0 | +0 | -823,304 |
| globals | +140 | +2,080 | -659 |
| natives | +0 | +0 | +56 |
| reflectionMembers | +0 | +0 | +961 |
| scalarConstants | +0 | +0 | +52 |
| strings | +0 | +0 | +9,333 |
| table elements | +118 | +154 | +0 |
| types | -14 | +3,759 | -9,305 |

Wasm code framing contributes +78 / +132 bytes beyond the function-body
ledger. GC data growth is +7,397 bytes of strings (printed/reflected case/type
names and native decode/validation errors) and +456 of reflection records;
ordinary static data is unchanged. Wasm32 data has +27,426 string bytes and
+456 reflection bytes, with **zero** growth in its 2,125-byte semantic closure
descriptor segment. The GC type/global/table/signature/name changes describe
these reachable nominal boxes, cached case objects and checked inspection/native
entry points. Closed tag-only fields and arrays do not receive those roots,
descriptors, adapters or case objects, as the paired release fixture checks.
HashLink's positive string/member/scalar/native entries carry the same real
case names, field inspection and checked boundary behavior; its other sections
shrink. Every section sum equals the complete module delta above.

Tier 1 for physical receiver sharing: **865 passed, 0 failed**, eight workers;
self-hosting stages are identical at **36,697,154 bytes**, SHA-256
`b97c81b8f5b201b734a613a94f7c98aabb40630b22c7074dde76a10fb62e0a84`.
The all-target fixtures preserve nominal closure checks with inlining off/on.
No paired timing series was added for the size closeout.

Development-mode checkpoint sizes use the committed counter settings (Wasm32
memory statistics on, Wasm GC allocation counter on) from the normal Web gates.
The pre-enum column is the recorded `9180b6d8` development receipt; it is not a
release module relabeled as development. The final values are the freshly built
Tier 2 modules. These totals include integrated a1 naming/metadata work, so the
whole reduction is not attributed to the enum fix alone. The isolated paired
fixture above establishes the enum representation result independently.

| Development module | Pre-enum bytes | Initial enum checkpoint bytes | Final bytes | Final vs pre-enum |
|---|---:|---:|---:|---:|
| Showcase Wasm32 | 12,041,570 | 12,525,154 | 11,581,890 | -459,680 |
| Showcase Wasm GC | 5,903,055 | 6,071,457 | 6,038,119 | +135,064 |
| HashLink editor | 105,148,935 | 106,223,320 | 101,643,349 | -3,505,586 |

The remaining GC development difference also carries debugger-visible nominal
enum declarations, cases and types. Release selection can omit unobserved enum
descriptors; development keeps the logical types for inspection. The release
section/body ledger, not this development total, is the attribution of runtime
representation cost. Physical receiver sharing saves 43,741 bytes in the
counter-enabled development Wasm32 guest versus the immediately preceding
shared-reach checkpoint; GC's guest is byte-identical and HL module lengths
are unchanged. HL hashes differ, so the closeout repeated the normal budget,
memory and retention gates plus every exact action window rather than claiming
Tier 3's byte-identical shortcut. No extra paired timing series was run.


Final closeout validation (2026-11-11): **865 compiler tests, zero failures**, eight
workers; self-hosting stage 1 and 2 are identical at 36,697,154 bytes,
SHA-256 `b97c81b8f5b201b734a613a94f7c98aabb40630b22c7074dde76a10fb62e0a84`.
The receiver-sharing fixture passes HL/Wasm32/Wasm GC with inlining off/on.
All ten UI scripts pass; full parity passes 527 runtime fixtures (14 documented
skips), plus 60 positive/702 negative UI checks including the snapshots. The
app suite exits zero, all nine retention scenarios pass, and budget and headless
memory gates pass. No ceiling changed. The normal final memory run records
10.31 MiB after warmup and RSS growth windows [29.69, 4.06, 0.78, 5.47] MiB;
these are a single gate run, not a new paired timing claim.

The 15 exact action censuses repeat the structural checkpoint exactly:
16,251 objects / 1,048,304 bytes. The changed Wasm32 guest repeats 3,840
allocation calls / 132,480 bytes per 120 frames, zero collections and zero
measured heap growth. GC's final guest is byte-identical to the successfully
measured structural checkpoint (4,320 full/static/text-heavy; 8,604 editing).
The wrapper's identity-only shortcut correctly declined the changed HL hashes;
the complete independent budget/memory/retention/census runs above cover that
change instead. An earlier browser launch failed before guest load because its
Unix socket path under the long TMPDIR was too long; using a short DATA1 TMPDIR
fixed that harness cause before the accepted browser measurements.

## Struct equality through Dynamic array views — measurements

The paired HashLink editor images use outer `55902fe53`, control compiler
`efd3a87d` and this equality candidate. Each image runs with its matching native
runtime: the control still imports the deleted native search declarations.
The profile module SHA-256 hashes are
`008e0f09041ef487695f60087481dd3bf90eae94b20b29bb2bba9f5c2d4ab6b9`
(control) and `70cb273159447921d8409fda43fb546533846e4d6df628836d62f60151dc3d42`
(candidate). Nine alternating pairs gave these per-action median allocations
(KiB):

| Action | Control | Candidate |
| --- | ---: | ---: |
| console → telemetry | 74.5 | 74.5 |
| hierarchy → sensors | 114.6 | 114.6 |
| sensors → hierarchy | 80.1 | 80.1 |
| telemetry → console | 92.9 | 92.9 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

One candidate hierarchy → sensors capture reported 112.6 instead of 114.6 KiB;
all other per-action values matched their controls. The 2 KiB step is the
buffer-refill counter granularity described above.
Two of the 18 captures flagged selection timing: control pair 3 reported
`frameMs 6.08 is over the budget 6.0`, and candidate pair 8 reported
`frameMs 6.24 is over the budget 6.0`. These captures ran alongside compiler
and background work. Both findings are retained; no capture was discarded or
repeated. The separately planned final editor budget run passed, including
retention. Neither timing outlier increased its allocation counters.

Three 30-cycle selection-stress census pairs were:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,944 | 340,911 / 24,010,928 |
| 2 | 340,909 / 24,010,416 | 340,909 / 24,010,472 |
| 3 | 340,910 / 24,010,656 | 340,912 / 24,011,144 |

Only byte buffers differed; every other per-type object and byte count matched
within each pair. A full-site census of both images attributed all ten differing
sites to benchmark JSON/timing serialization and timeline output (`submit`,
`runSelectionStressScenario` and `run`); application allocation sites matched.
The full-site captures counted 340,907 / 340,909 objects. Stack sample weights
in that capture represent bytes, not object counts.

All six 500-cycle headless memory gates passed. RSS growth in the four windows
(MiB), preserving paired order, was:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.00 / 3.91 / 0.94 / 5.78 | 28.91 / 4.22 / 0.62 / 5.47 |
| 2 | 29.38 / 4.22 / 0.62 / 4.69 | 29.69 / 4.06 / 0.78 / 5.00 |
| 3 | 30.00 / 4.22 / 0.62 / 4.84 | 30.31 / 3.75 / 0.78 / 4.84 |

Median paired differences were +0.31 / −0.16 / +0.16 / 0 MiB, within the
same-binary variability documented in the preceding comparison. All ten UI
scripts, the app suite and all nine retention scenarios passed. No allocation,
memory or timing ceiling changed.

## Generated callback dependencies and the UI snapshot gate (2026-11-05) — measurements

Paired measurements use outer `556304e1a`, control compiler `a7894caf` and
this candidate. The two HashLink profile guests are byte-identical (SHA-256
`361b2cd2d52a213c82e8f9dbd197126a9745a145adfd737f7ce1510421becebf`).
Nine alternating pairs gave these per-action median allocations (KiB):

| Action | Control | Candidate |
| --- | ---: | ---: |
| console → telemetry | 74.5 | 74.5 |
| hierarchy → sensors | 114.6 | 114.6 |
| sensors → hierarchy | 80.1 | 80.1 |
| telemetry → console | 92.9 | 92.9 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

One control backspace capture reported 16.1 rather than 16.2 KiB; the other
17 captures reported 16.2. These identical-image runs retain the counter and
capture-format variation rather than retrying it away. Every action capture
passed its budgets; no ceiling changed.

Three 30-cycle selection-stress census pairs were:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,928 | 340,909 / 24,010,392 |
| 2 | 340,909 / 24,010,408 | 340,911 / 24,010,960 |
| 3 | 340,910 / 24,010,736 | 340,906 / 24,009,688 |

Only byte buffers varied; all other per-type object and byte counts matched
within each pair. The four RSS growth windows (MiB), preserving pair order, were:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 29.69 / 3.75 / 0.78 / 5.00 | 30.16 / 3.75 / 0.78 / 5.00 |
| 2 | 30.16 / 4.06 / 0.94 / 4.84 | 29.84 / 4.06 / 0.78 / 5.16 |
| 3 | 29.53 / 3.91 / 0.94 / 5.00 | 30.31 / 3.59 / 0.78 / 5.00 |

Median paired differences were +0.47 / 0 / −0.16 / 0 MiB. The first-window range
across these identical guests was 29.53–30.31 MiB, inside the preceding recorded
same-binary range. Every memory run passed without changing a ceiling.

The Wasm GC Showcase uses fixed-step core mode, 120 warmup and 120 measured
frames, allocation counting on and linear-memory statistics off. Nine full-scene
pairs and three pairs per other scene matched:

| Scene | Control objects | Candidate objects |
| --- | ---: | ---: |
| full | 4,440 | 4,440 |
| static | 4,440 | 4,440 |
| text-heavy | 4,440 | 4,440 |
| editing | 8,724 | 8,724 |

Control/candidate guest SHA-256 hashes are
`b4edcd901070a2cbed5f8289cb63f6c28a1d8e3ddd7fc1727160b09cbe2b51a7` /
`03b20c16d31e8e394427b1b3248097af31c95c9e893d38c465308ac24234cadd`.
All captures were deleted after recording their numbers.

## Key-path merge and field-mask port (2026-11-05) — measurements

Control is `2af90631`, including its original string-based `Diff.bit` UI;
candidate merges `10bd69dc` and ports both RenderNode and StyleResolver to typed
key paths. Both use outer `031bc40f4`, the same native runtime and machine.
No budget or HashLink pin changed. Compiler tests: 759 passed, zero failed;
self-hosting fixed point passed. Wasm parity: 495 fixtures, 14 existing skips,
plus the UI value snapshot on all three targets with inlining off/on. All ten
UI suites, app tests, retention, final performance budgets, all six headless
memory runs and the Wasm32 WebGL2 smoke passed.

Nine alternating action pairs gave these median KiB (control / candidate):

| Action | Control | Candidate |
| --- | ---: | ---: |
| console→telemetry | 74.5 | 74.5 |
| hierarchy→sensors | 114.6 | 114.6 |
| sensors→hierarchy | 80.1 | 80.1 |
| telemetry→console | 92.9 | 92.9 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

The ninth candidate telemetry→console sample was 93.1 KiB. Preserve this
counter variation rather than retrying it. Two timing findings occurred in the
predeclared pairs: control selection frame 8.84 ms against 6 ms, and candidate
hierarchy→sensors 4.07 ms against 4 ms. The separately planned final budget gate
passed; neither failed capture was retried or discarded.

Selection-stress census pairs (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,904 | 340,911 / 24,010,912 |
| 2 | 340,908 / 24,010,128 | 340,910 / 24,010,536 |
| 3 | 340,910 / 24,010,712 | 340,910 / 24,010,688 |

A separate allocation-site census pair found 340,910 / 340,905 objects.
All ten differing sites were byte buffers in benchmark JSON serialization,
timeline construction or capture-file output; UI allocation sites matched.
The four RSS growth windows in MiB were:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 29.84 / 4.06 / 0.94 / 4.84 | 30.00 / 4.06 / 0.78 / 5.00 |
| 2 | 30.31 / 3.75 / 0.78 / 5.00 | 29.84 / 3.91 / 0.94 / 5.00 |
| 3 | 30.00 / 4.38 / 0.78 / 4.84 | 30.31 / 3.75 / 0.78 / 4.84 |

These remain within the preceding paired-run variation. Profile SHA-256:
control `1aaa9d1f692f3a39a3a2b44094ed33891b85c21137768f5838046aa1640acb57`,
candidate `b70186e7b9cb35211f162fec85a03df4e83962448e0311b3a08df7c736dc303b`.

Wasm GC fixed-step core, 120 warmup / 120 measured frames: nine full-scene
pairs and three pairs each of static, text-heavy and editing all matched.
Full/static/text-heavy were 4,440 / 4,440 objects; editing 8,724 / 8,724.
Guest SHA-256: control
`03b20c16d31e8e394427b1b3248097af31c95c9e893d38c465308ac24234cadd`, candidate
`6a20abc1629823155f89b76dab9b67a533b8cdd30db94cd537406ba91892a3b7`.
Captures were deleted immediately after their summaries were recorded.

## Negative array insertion indices on Wasm (2026-11-05) — measurements

Control is `0bb683b2` (code identical to `eafc907f`; the intervening commits plan
native placement and borrowing). Both builds use outer `21700a1eb` on this machine.
Compiler tests: 760 passed, zero failed; self-hosting fixed point passed. Parity:
496 fixtures, 14 existing skips, plus six UI value snapshots. All ten UI suites,
app tests, retention, Wasm32 WebGL2 smoke, final editor budgets and all six paired
headless memory runs passed. The inline parity harness now shares one fixture
list between compilation and execution, including previously compiled inline
cases missing from the execution list.

Both HashLink editor profiles are byte-identical, SHA-256
`6e98ac0e96126ea6f4fa0a37e4516357d65a750a0afa416d3b06f07dfd197eec`.
Nine alternating action pairs yielded these median KiB:

| Action | Control | Candidate |
| --- | ---: | ---: |
| console->telemetry | 74.5 | 74.5 |
| hierarchy->sensors | 114.6 | 114.6 |
| sensors->hierarchy | 80.1 | 80.1 |
| telemetry->console | 92.9 | 92.9 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

The planned pairs retained these timing findings (ms):

| Capture | Action | Measured | Budget |
| --- | --- | ---: | ---: |
| control, pair 1 | selection | 8.06 | 6.00 |
| candidate, pair 2 | selection | 6.90 | 6.00 |
| control, pair 2 | selection | 6.72 | 6.00 |
| control, pair 3 | hierarchy→sensors | 4.33 | 4.00 |
| control, pair 3 | selection | 7.48 | 6.00 |
| candidate, pair 3 | hierarchy→sensors | 4.61 | 4.00 |
| candidate, pair 3 | selection | 7.20 | 6.00 |
| control, pair 4 | selection | 6.36 | 6.00 |
| control, pair 8 | selection | 7.42 | 6.00 |

No failed capture was retried or discarded. These are identical-image captures;
the separately planned final budget gate passed without changing a ceiling.
Selection census pairs (objects / bytes) were:

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,928 | 340,908 / 24,010,232 |
| 2 | 340,910 / 24,010,688 | 340,910 / 24,010,744 |
| 3 | 340,910 / 24,010,640 | 340,909 / 24,010,416 |

Only the bytes type differed in each pair, as in prior same-image capture-buffer
measurements. Four RSS growth windows (MiB) were:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.00 / 4.06 / 0.78 / 4.84 | 29.84 / 3.91 / 0.94 / 4.84 |
| 2 | 30.16 / 3.44 / 0.78 / 5.00 | 30.16 / 3.91 / 0.78 / 5.16 |
| 3 | 29.06 / 4.22 / 0.78 / 4.84 | 30.00 / 3.91 / 0.94 / 4.84 |

All windows passed. The paired median differences were 0 / −0.15 / +0.16 / 0 MiB;
the 0.78/0.94 MiB third-window variation also occurs in preceding identical-image
runs. Wasm GC fixed-step core (120 warmup / 120 measured frames), nine full-scene
pairs and three pairs each for static/text-heavy/editing, matched in every pair:
4,440 / 4,440 objects for full/static/text-heavy, 8,724 / 8,724 for editing.
Guest SHA-256: control
`6a20abc1629823155f89b76dab9b67a533b8cdd30db94cd537406ba91892a3b7`, candidate
`6221ae673935fd1d280f7b371c1dcffb0c172a070e8e6162b82c131ffe00bf06`.

Setup failures remain findings: the first private gate lacked the bootstrap
`haxeon_runtime.hdll`; it was supplied from the saved runtime before rebuilding.
Initial parity reported missing inline artifacts for the new test because its
compilation and execution lists differed. Unifying the lists fixed the harness;
the corrected gate compiled and ran every listed inline fixture. A pre-correction
relaunch was stopped without using its results. After app retention completed,
its private compiler worker retained 7.7 GiB; normal authenticated worker shutdown
released it before captures. Profile builds ran one at a time. No unrelated
process was touched. All captures were deleted after recording their summaries.

## One structural runtime for lane arrays (2026-11-05) — measurements

Control is `d630357d`; both use the outer `21700a1eb` app sources (the detached
gate checkout is `fde067ce3`, which only adds the submodule bumps).

The initial compiler gate reported 760 passed and two failed: a storage-only
unit still requested the deleted Wasm-specific clear implementation, and another
expected a raw Wasm trap from linked validation. Clear coverage now runs through
the production policy and checks every affected lane. Linked validation is checked
against the exported Haxe exception tag and exact null payload; raw primitive
tests retain their trap checks. The subsequent 762-test gate passed. Self-hosting
then exposed an ambiguous lambda/object-literal parse; an explicit return makes
the new declaration parse identically in both compilers. These failures are
recorded rather than counted as passes.

Both HashLink editor profiles are byte-identical, SHA-256
`6e98ac0e96126ea6f4fa0a37e4516357d65a750a0afa416d3b06f07dfd197eec`.
The native libraries differ and each capture preloads its matching library. Nine
alternating pairs yielded these median allocation KiB:

| Action | Control | Candidate |
| --- | ---: | ---: |
| console->telemetry | 74.5 | 74.5 |
| hierarchy->sensors | 114.6 | 114.6 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| sensors->hierarchy | 80.1 | 80.1 |
| telemetry->console | 92.9 | 92.9 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

Candidate pair 1 retained two timing findings: hierarchy→sensors 4.12 ms
against 4.00 ms and selection 7.41 ms against 6.00 ms. No capture was retried
or discarded. Individual allocation readings included hover-field 12.4–12.9 KiB
and sensors→hierarchy 78.1–80.1 KiB; their medians matched.

Selection census pairs (objects / bytes) were:

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,910 / 24,010,552 | 340,911 / 24,010,880 |
| 2 | 340,908 / 24,009,952 | 340,911 / 24,010,960 |
| 3 | 340,910 / 24,010,536 | 340,911 / 24,010,912 |

Only the `bytes` type differed: +1 / +3 / +1 allocations and +328 / +1,008 /
+376 bytes for candidate. All other types matched exactly in every capture:
305,725 objects / 21,593,528 bytes. These small byte-buffer variations also occur
in the preceding identical-profile baselines; no application object type grew.
Four headless RSS growth windows (MiB) were:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.16 / 4.22 / 0.62 / 5.00 | 29.84 / 4.06 / 0.78 / 4.84 |
| 2 | 30.62 / 3.59 / 0.78 / 4.84 | 30.00 / 4.06 / 0.78 / 5.16 |
| 3 | 29.84 / 3.75 / 0.62 / 5.00 | 29.53 / 4.06 / 0.78 / 4.69 |

All six memory runs passed. The 0.62/0.78 MiB third-window variation has
the same 0.16 MiB step seen in the preceding identical-image paired runs.

Final gates: 762 compiler tests, zero failed; self-hosting fixed point; 497 Wasm
parity fixtures with 14 existing skips and all six UI value snapshots; all ten UI
suites; app tests; every retention scenario; Wasm32 WebGL2 smoke; editor budgets
and all six paired headless memory runs passed. The separately planned final
budget gate passed without changing any ceiling. Captures were deleted after
recording their summaries. The app gate’s private idle compiler worker was shut
down normally before captures; no unrelated process was touched.

## Minimum-first-capacity growth trial (not accepted) — measurements

Control was `e44e8637` with the committed capacity policy, after the separately gated launcher and word-access work;
its per-action allocation medians and program-type selection census match the earlier growth control. Both runs
used outer `55c362a7c` source on the same machine. Profile SHA-256 starts `6cbf9e02c12e` (control), `edc30349fb38`
(candidate). Nine alternating pairs produced these medians in KiB:

| Action | Control | Minimum first |
| --- | ---: | ---: |
| console->telemetry | 74.5 | 72.0 |
| hierarchy->sensors | 114.6 | 110.4 |
| sensors->hierarchy | 80.1 | 77.6 |
| telemetry->console | 92.9 | 90.4 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.3 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 7.9 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 19.2 |
| type-backspace | 16.2 | 16.1 |
| type-char | 16.1 | 16.1 |

All action captures passed the absolute budgets. Three selection-stress census pairs, 30 cycles each (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,910 / 24,010,584 | 336,255 / 23,358,488 |
| 2 | 340,908 / 24,010,184 | 336,254 / 23,358,304 |
| 3 | 340,910 / 24,010,744 | 336,252 / 23,357,776 |

Arrays fell from 96,333 / 5,971,976 bytes to 91,677 / 5,319,568 bytes: 4,656 fewer arrays and 652,408 fewer bytes. Every other program type matched; raw `bytes` buffers account for the small total-census variation.

Paired headless RSS window growth in MiB:

| Pair | Control | Candidate | Sum delta |
| --- | --- | --- | ---: |
| 1 | 30.31 / 3.59 / 0.62 / 5.00 | 28.12 / 7.66 / 0.47 / 5.94 | +2.67 |
| 2 | 31.09 / 3.44 / 0.62 / 4.69 | 28.12 / 7.19 / 0.31 / 5.94 | +1.72 |
| 3 | 30.16 / 3.44 / 0.94 / 4.84 | 28.75 / 7.34 / 0.47 / 5.94 | +3.12 |

Every run passed the absolute memory gate, but the second and final windows consistently increased, and total growth
increased in every pair. This exceeds the earlier same-image variation. Lower object counts and allocated bytes do
not establish no regression in retained RSS. The trial is rejected; the committed target-specific policy remains.
No ceiling or memory threshold changed, and no failing memory sample was retried. The final budget run and all nine
retention scenarios passed and do not override this baseline comparison.

The Wasm GC scene runs did not replace the browser-loaded guest, so their original claim of equal control/candidate
counts is withdrawn. No Wasm scene comparison is claimed for this rejected trial. A compiler unit independently
exposed unnecessary eager-empty startup allocations; making those backings lazy preserved the capacity formula and
passed the original allocation assertions unchanged. The valid HashLink RSS regression above already rejects the trial;
it was not repeated after the harness correction.

A compiler checkpoint passed 764 tests and self-hosted to a fixed point. An audit then found the HashLink struct-array
constructor still used implicit reserve for known lengths; the final correction uses exact capacity. Its existing
native probe directly checks known lengths 0..17, exact resize, retained shrink capacity and subsequent geometric
growth for ordinary and lane arrays. It passed, as did all six target/inlining fixture runs and the array-place unit.
On both Wasm targets, with both inlining settings, the first push after exact two-element construction allocated one
ordinary backing or two mixed scalar/reference backings, without an element box. Small HashLink allocations cannot
be proved by a positive `totalAllocated()` delta because that counter is quantized by buffer refills; the native probe
checks capacities directly instead. No final full UI/parity gate pass is claimed for this rejected implementation.

One attempted editor capture exited before recording any actions because the fresh detached gate lacked its native
libraries (`Could not open ordinary C library: libnativekit_ui.so`). The normal app build published them before the
planned pairs began; no performance sample was replaced. The compiler fixture was also registered in
`expected-exits.tsv` after the first driver stopped on the missing registration. Implementation patches and source
are preserved under `materia-cache/claude-scratch/haxeon-min-first-growth-rejected-2026-11-05/`. Completed builds,
logs and raw captures are removed after recording these numbers. The next item is the equality model, not another
growth experiment.

## Nullable argument/result ABI checkpoint (2026-11-06) — measurements

Control is `051387b3`; candidate is `98465674`. Both editor modules are built on the same pinned outer
source, `155d98937`, excluding the shared checkout's unrelated uncommitted changes. A compiler-selection audit during
the binary-size merge found that the original control rebuild selected current compiler source: ordinary project
builds use `HAXEON_COMPILER_SOURCE`; `HAXEON_MAIN_HL` and `HAXEON_COMPILER_HL` do not select that path.
The original HashLink pairs are withdrawn. The replacement fixed schedule below uses explicit source archives of
both revisions and the old CLI, with identical optimized native libraries and VM/runtime binaries.

The actual control is SHA-256 `58c0caa868503b5defb827a0fbed2af9a03dfd79fdf74544d304cd65ccf41b6d`; candidate is
`33f74708a70d81045dc13ee1d95d6b56893b54fd2b39b7b3ed7881165f43817a`. Both are 104,057,908 bytes.
Their only 425 differing bytes are 17 generated helper-name prefixes; replacing the old prefix with the corrected
prefix makes the complete files byte-identical. The earlier claim of literal byte identity was incorrect.
The original stale control also used `212462122` source, mislabeled with a later submodule-bump revision; 89 intervening
outer changes exposed that separate error. Controls now record both the actual outer source revision and explicit
compiler-source selection. The already-passed candidate app, retention and standalone budget gates are retained;
no source files or budget ceilings were changed to repair the comparisons.

Nine alternating pairs, affinity `0,2,4,6`, replacement action medians:

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
| --- | ---: | ---: | ---: | ---: |
| console->telemetry | 74.5 | 74.5 | 1.08 | 1.08 |
| hierarchy->sensors | 114.6 | 114.6 | 1.53 | 1.53 |
| sensors->hierarchy | 80.1 | 80.1 | 1.20 | 1.20 |
| telemetry->console | 92.9 | 92.9 | 1.14 | 1.14 |
| hover-away | 13.6 | 13.6 | 0.42 | 0.42 |
| hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-field | 12.4 | 12.4 | 0.43 | 0.42 |
| hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-other | 10.0 | 10.0 | 0.41 | 0.41 |
| idle | 0.2 | 0.2 | 0.01 | 0.01 |
| idle-focused | 0.2 | 0.2 | 0.01 | 0.01 |
| scroll-inspector | 21.2 | 21.2 | 0.70 | 0.71 |
| type-backspace | 16.2 | 16.2 | 0.41 | 0.41 |
| type-char | 16.1 | 16.1 | 0.41 | 0.41 |
| selection | — | — | 2.93 | 2.92 |

Selection-stress does not report an action KiB median. Exact 30-cycle census pairs, objects / bytes:

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,910 / 24,010,960 | 340,911 / 24,011,240 |
| 2 | 340,908 / 24,010,488 | 340,910 / 24,010,920 |
| 3 | 340,911 / 24,011,256 | 340,911 / 24,011,256 |

Every type other than raw `bytes` matches in every pair: 305,725 objects / 21,593,528 bytes.
The remaining small variation is recorded as raw-byte variation, without a new site-attribution claim.

Headless memory windows, MiB, control → candidate; all six replacement runs pass:

| Pair | First window | Retained window | Primitives window | Tab-inspector window |
| --- | ---: | ---: | ---: | ---: |
| 1 | 30.47 → 29.38 | 3.59 → 4.38 | 0.78 → 0.78 | 5.00 → 5.00 |
| 2 | 30.16 → 30.16 | 3.91 → 4.22 | 0.78 → 0.78 | 5.62 → 5.16 |
| 3 | 30.31 → 30.31 | 3.59 → 3.91 | 0.78 → 0.78 | 5.16 → 5.00 |

Median paired differences are +0.00 / +0.32 / +0.00 / -0.16 MiB. Separate-version medians are
30.31 / 3.59 / 0.78 / 5.16 → 30.16 / 4.22 / 0.78 / 5.00 MiB. The second-window increase lies within the
previously recorded identical-executable variation; the full vectors are retained rather than accepting a retry.
All action allocation medians match. The compiler's targeted allocation fixtures remain zero on all targets.

Wasm32 and Wasm GC package builds and WebGL2 browser smokes pass. Wasm GC fixed-step core uses 120 warmup and
120 measured frames: all nine full-scene pairs and three each for static, text-heavy and editing match at
4,440 / 4,440 / 4,440 / 8,724 objects. Each browser-loaded guest was hash-checked against its selected version;
control is `e81a925cba8fccafc6430f95fbe1cd6a27feb3f77e34a3b9bd080c3a5ea306a1`, candidate is
`ff3dc27e5acfde09528c2b1ac52b10d7a2bd739086be1d2b719a67ab061d91c9`. These counts close this comparison without
assuming that name/debug sections produce identical Wasm bytes.

Gates pass: 775 compiler tests, self-hosting fixed point, all ten UI scripts, 502 parity fixtures (14 existing skips),
all six UI value snapshots, the app suite, all nine retention scenarios, the first scheduled standalone budget check,
and paired headless memory. After strengthening the managed-reference fixture, the complete compiler suite was rerun
and again reported 775 passed / 0 failed; compiler source and editor input/tool bytes did not change. Captures are
deleted after extraction, and the idle editor gate checkout is removed.

## Enum storage association in the live-patch ABI — measurements

Control is `2cd94d24`, with the same frozen outer input `595e13687` and the same checkout-built VM/runtime on both sides.
The regression changes only an enum storage association while retaining its cases and private object layouts: the old
planner returned `Patch`; the fix returns `ReloadDomain([EnumChanged(...)])` in either direction. An unchanged association
with a body edit stays patchable. The fixture covers all three target layout plans and canonical IR round trips.
Boxed enum ABI keys retain their previous spelling. Source enum activation remains unfinished.

Nine alternating action pairs; KiB is the existing refill-quantized counter, and timing is median frame ms:

| Action | KiB control → candidate | ms control → candidate |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 74.5 → 74.5 | 1.24 → 1.21 |
| tab-matrix/hierarchy->sensors | 112.8 → 112.6 | 1.79 → 1.73 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.38 → 1.34 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.29 → 1.27 |
| interaction/hover-away | 13.6 → 13.6 | 0.44 → 0.44 |
| interaction/hover-enter | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-field | 12.4 → 12.4 | 0.44 → 0.45 |
| interaction/hover-inside | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-other | 10 → 10 | 0.43 → 0.44 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.73 → 0.74 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.43 |
| interaction/type-char | 16.1 → 16.1 | 0.43 → 0.43 |
| selection-stress/selection | census below | 3.23 → 3.27 |

The editor images are byte-identical; these timing and counter movements are not attributed to an ABI runtime
improvement. Every action capture and the final budget gate passed. No ceiling changed.

Three 30-cycle selection census pairs (objects / allocated bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,910 / 24,012,200 | 340,909 / 24,011,936 |
| 2 | 340,910 / 24,012,248 | 340,910 / 24,012,240 |
| 3 | 340,910 / 24,012,296 | 340,912 / 24,012,832 |

Every census has exactly 305,725 non-byte objects / 21,594,968 non-byte bytes on each side. The remaining variation
is in raw byte buffers; it is not claimed as an allocation reduction.

RSS window growth in MiB, for cycles 100–200 / 200–300 / 300–400 / 400–500:

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 30.16 / 3.91 / 0.78 / 5.00 | 30.00 / 3.44 / 0.78 / 4.84 |
| 2 | 30.47 / 3.75 / 0.78 / 4.84 | 29.22 / 4.06 / 0.94 / 4.84 |
| 3 | 29.84 / 4.06 / 0.78 / 5.00 | 29.38 / 4.06 / 0.78 / 5.00 |

Median paired candidate-minus-control deltas are −0.46 / 0.00 / 0.00 / 0.00 MiB. All six leak/RSS captures passed.
The raw windows include the positive individual movements; no retry was used to select a passing result.

Showcase: 18 Wasm GC pairs (9 full, 3 each static/text-heavy/editing) and 3 Wasm32 full-scene pairs; no timeout.

| Target / scene | GC objects control → candidate | Frame median / p95 ms control → candidate |
| --- | ---: | ---: |
| wasm-gc / editing | 8,724 → 8,724 | 3.0 / 6.3 → 2.9 / 6.2 |
| wasm-gc / full | 4,440 → 4,440 | 2.6 / 5.1 → 2.6 / 5.3 |
| wasm-gc / static | 4,440 → 4,440 | 2.5 / 4.6 → 2.6 / 5.0 |
| wasm-gc / text-heavy | 4,440 → 4,440 | 3.1 / 6.1 → 2.6 / 6.1 |
| wasm32 / full | not reported | 2.7 / 5.1 → 2.7 / 5.8 |

Development binary sizes are unchanged: editor 99,871,693 bytes, Wasm GC Showcase 5,810,217 bytes and Wasm32 Showcase
11,876,090 bytes. Each control/candidate module pair has an identical SHA-256. Both browser smoke tests passed.

Validation: 790 compiler tests, 0 failures; self-hosting fixed point; all ten UI gates; 506 parity fixtures (14 existing
skips); all six UI snapshots; app suite; all nine retention scenarios; budgets; headless memory; the browser pairs above.
Public enum closure/field/reflection adapters and source activation remain pending.

## Scalar closures forward reference leaves through verified private calls — measurements

Paired measurements use control `b4751a62` and frozen outer `46044a2712525a635588feb4572fa0f2053dc06c` on the same machine.
Nine alternating pairs give the following medians. KiB use the existing refill-quantized counter.

| Action | Control → candidate KiB | Control → candidate ms |
|---|---:|---:|
| tab-matrix/console->telemetry | 72.5 → 74.5 | 1.41 → 1.54 |
| tab-matrix/hierarchy->sensors | 112.8 → 112.8 | 1.98 → 2.31 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.56 → 1.70 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.48 → 1.69 |
| interaction/hover-away | 13.6 → 13.6 | 0.49 → 0.52 |
| interaction/hover-enter | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-field | 10.9 → 10.9 | 0.50 → 0.53 |
| interaction/hover-inside | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-other | 10 → 10 | 0.50 → 0.53 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.77 → 0.84 |
| interaction/type-backspace | 16.2 → 16.2 | 0.44 → 0.46 |
| interaction/type-char | 16.1 → 16.1 | 0.44 → 0.47 |
| selection-stress/selection | not reported | 3.49 → 3.67 |

Console→telemetry moves +2.0 KiB in the quantized counter. Three additional alternating pairs with the census enabled
give the following exact rounded-byte medians in **every** run (100 tab cycles; 99 steady frames per action).

| Action | Control exact bytes | Candidate exact bytes |
|---|---:|---:|
| hierarchy->sensors | 115,136 | 115,136 |
| sensors->hierarchy | 81,384 | 81,384 |
| console->telemetry | 75,800 | 75,800 |
| telemetry->console | 94,520 | 94,520 |

Each full tab census has exactly 968,681 objects, including 755,734 non-byte-buffer objects / 54,315,768 corresponding
bytes. Total raw-buffer bytes vary between captures. Exact action-window bytes tie, so the +2 KiB counter movement
does not represent additional program allocation. Census-mode timings are not mixed with ordinary timings.

Selection-stress census (30 cycles), objects / bytes:

| Pair | Control | Candidate |
|---|---:|---:|
| 1 | 340,910 / 24,012,400 | 340,910 / 24,012,264 |
| 2 | 340,910 / 24,012,288 | 340,909 / 24,012,064 |
| 3 | 340,909 / 24,012,144 | 340,911 / 24,012,552 |

All six selection captures have exactly 305,725 non-byte-buffer objects / 21,594,968 corresponding bytes.
The differences in total counts and bytes are raw byte buffers, retained here without a site attribution.

Three paired headless memory captures, 500-cycle RSS windows in MiB:

| Pair | Control | Candidate |
|---|---|---|
| 1 | 29.22 / 3.75 / 0.94 / 5 | 29.22 / 4.38 / 0.78 / 4.84 |
| 2 | 29.06 / 4.38 / 0.78 / 5 | 30 / 4.06 / 0.78 / 4.69 |
| 3 | 29.84 / 4.06 / 0.78 / 5 | 30 / 4.06 / 0.62 / 4.69 |

Paired median RSS deltas are +0.16 / 0.00 / −0.16 / −0.31 MiB. All six memory gates pass. The positive first-window
observation is retained; the byte-identical module, VM and runtime provide no changed memory path to attribute it to.

All 36 Wasm GC full/static/text-heavy/editing scene captures and six Wasm32 full-scene captures completed. Wasm GC
objects are exactly 4,440 in full/static/text-heavy and 8,724 in editing in every control and candidate capture.
Frame median / p95 observations (ms):

| Target / scene | Control → candidate median / p95 |
|---|---:|
| wasm-gc/editing | 2.7 / 5.0 → 2.7 / 4.8 |
| wasm-gc/full | 2.8 / 5.6 → 3.0 / 5.8 |
| wasm-gc/static | 2.3 / 4.4 → 2.4 / 5.0 |
| wasm-gc/text-heavy | 2.9 / 5.6 → 2.8 / 5.5 |
| wasm32/full | 2.7 / 4.5 → 2.3 / 4.4 |

Both sides have byte-identical artifacts and equal binary sizes:

| Artifact | Control = candidate bytes | SHA-256 |
|---|---:|---|
| profile-candidate.hl | 99,957,149 | `89c9d7b7cf31ee776b6f70177a10e7bcde3f6b24b60f54e7e76bd1eeb1830c6b` |
| candidate-webgc.wasm | 5,808,484 | `24f2a3a31d18d28769165a80e35336155ef2b317b36b29b187e95aa70877b8ea` |
| candidate-web32.wasm | 11,810,665 | `3b1e48cc20dc72fa5724d2e727d4d2f2f51500d4048f95a0ddb84e62113c667b` |
| candidate-libhl.so | 892,080 | `d1893528f97c678299f81273974f2d33d8384eaca01acf28d1ba9e942fcc8900` |
| candidate-runtime.hdll | 562,576 | `9e07bd7d74e0a743fd94f15098b91f8d18a4524c1f2450738391bfc87ef30dbb` |

One scheduled candidate action capture reported the exact error
`selection-stress selection: frameMs 6.17 is over the budget 6.0`. It remains in the nine pairs; no capture was
replaced. Selection timing medians are 3.49 → 3.67 ms. The separately pre-scheduled final budget gate passed on its
first run. These identical-image timing observations, including slower tab and full/static scene observations, are
recorded without a change-specific speed claim. No ceiling was raised.

Self-hosting BodyTyped observations (ms), control → candidate: seed 230.22 → 228.15; stage 1 49.19 → 50.65; stage 2
48.99 → 48.72. Single observations move in both directions and do not establish a typing regression. Framework compile
observations were 592.04 → 492.04 seconds; no speed claim follows from that single pair.

Validation: 797 compiler tests, 0 failures; self-hosting fixed point; ten UI scripts; 510 parity fixtures with 14 existing
skips; six UI snapshots; app suite; nine retention scenarios; final budget gate; six headless memory gates; all browser
pairs above. The paired timing overrun remains a reported finding, rather than being labeled a passing capture.

A scratch-runner error occurred after the successful Wasm GC browser smoke: editing a running Bash script to correct
a status label shifted its read offset (`unexpected EOF while looking for matching` a double quote). The saved script
passes `bash -n`; a new immutable runner resumed at Wasm32 before any paired browser capture had started. The original
error log is retained. This was harness recovery, with no product change or repeated completed measurement.

Records and hashes are retained under `haxeon-flat-work/carrier-closure-gates`; raw captures are removed after extraction.
Source inline-enum lowering and UI enum conversions remain unfinished.

## Nongeneric interface calls preserve value carriers — measurements

Paired measurements use control `6f816201` and frozen outer `46044a2712525a635588feb4572fa0f2053dc06c` on the same machine.
Nine alternating pairs give the following medians (KiB use the refill-quantized counter). Every scheduled action capture
and the separately scheduled final budget gate pass; no capture was replaced and no ceiling was raised.

| Action | Control → candidate KiB | Control → candidate ms |
|---|---:|---:|
| tab-matrix/console->telemetry | 74.5 → 74.5 | 1.10 → 1.10 |
| tab-matrix/hierarchy->sensors | 113 → 112.8 | 1.55 → 1.57 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.20 → 1.21 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.15 → 1.15 |
| interaction/hover-away | 13.6 → 13.6 | 0.43 → 0.42 |
| interaction/hover-enter | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-field | 10.9 → 12.4 | 0.43 → 0.43 |
| interaction/hover-inside | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-other | 10 → 10 | 0.42 → 0.41 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.72 → 0.71 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.41 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | not reported | 2.96 → 2.92 |

Hover-field moves +1.5 KiB and hierarchy→sensors moves −0.2 KiB in the ordinary counter despite byte-identical program
images. Three additional alternating census-enabled pairs per scenario give these exact rounded-byte medians in
**every** run. Tab medians use 99 steady frames per action from 100 cycles; interaction uses the harness’s last 75
samples from 100 cycles. Census timing is not mixed with ordinary timing.

| Scenario / action | Control exact bytes | Candidate exact bytes |
|---|---:|---:|
| tab-matrix/hierarchy->sensors | 115,136 | 115,136 |
| tab-matrix/sensors->hierarchy | 81,384 | 81,384 |
| tab-matrix/console->telemetry | 75,800 | 75,800 |
| tab-matrix/telemetry->console | 94,520 | 94,520 |
| interaction/hover-enter | 1,288 | 1,288 |
| interaction/hover-inside | 1,288 | 1,288 |
| interaction/hover-other | 9,816 | 9,816 |
| interaction/hover-field | 11,248 | 11,248 |
| interaction/hover-away | 12,664 | 12,664 |
| interaction/scroll-inspector | 21,744 | 21,744 |
| interaction/idle | 840 | 840 |
| interaction/type-char | 16,440 | 16,440 |
| interaction/type-backspace | 16,696 | 16,696 |
| interaction/idle-focused | 840 | 840 |

All six tab censuses have exactly 968,681 objects, including 755,734 non-byte-buffer objects / 54,315,768 corresponding
bytes. All six corrected interaction censuses have exactly 782,489 objects, including 552,783 non-byte-buffer objects /
37,722,320 corresponding bytes. Raw byte-buffer totals vary between captures. Exact action-window bytes tie; neither
ordinary-counter movement is treated as a changed program allocation or a permanent improvement to budget against.

Selection-stress census (30 cycles), objects / bytes:

| Pair | Control | Candidate |
|---|---:|---:|
| 1 | 340,911 / 24,012,592 | 340,911 / 24,012,704 |
| 2 | 340,910 / 24,012,376 | 340,912 / 24,012,808 |
| 3 | 340,910 / 24,012,368 | 340,911 / 24,012,600 |

All six selection captures have exactly 305,725 non-byte-buffer objects / 21,594,968 corresponding bytes. Differences
in total objects/bytes are raw byte buffers, retained without a site attribution.

Three paired 500-cycle headless RSS windows, MiB:

| Pair | Control | Candidate |
|---|---|---|
| 1 | 30 / 4.06 / 0.62 / 5 | 30 / 3.59 / 0.78 / 4.84 |
| 2 | 30 / 3.59 / 0.78 / 5 | 30.16 / 3.44 / 0.62 / 5 |
| 3 | 30 / 3.91 / 1.09 / 4.84 | 30.16 / 4.22 / 0.78 / 5 |

Paired median deltas are +0.16 / −0.15 / −0.16 / 0.00 MiB. All six memory gates pass. The positive first-window
observation is retained; byte-identical program, VM and runtime artifacts provide no changed memory path to attribute
it to.

All 36 Wasm GC scene captures and six Wasm32 full-scene captures complete. Object counts tie in every Wasm GC capture:
4,440 in full/static/text-heavy and 8,724 in editing. Frame median / p95 observations (ms):

| Target / scene | Control → candidate median / p95 |
|---|---:|
| wasm-gc/editing | 2.3 / 4.1 → 2.2 / 3.9 |
| wasm-gc/full | 2.2 / 4.2 → 2.1 / 3.9 |
| wasm-gc/static | 1.8 / 3.0 → 1.8 / 2.9 |
| wasm-gc/text-heavy | 2.0 / 3.8 → 2.0 / 3.6 |
| wasm32/full | 2.1 / 3.7 → 2.1 / 3.5 |

All five artifacts are byte-identical to control and retain the previous checkpoint’s SHA-256 hashes:

| Artifact | Control = candidate bytes |
|---|---:|
| profile-candidate.hl | 99,957,149 |
| candidate-webgc.wasm | 5,808,484 |
| candidate-web32.wasm | 11,810,665 |
| candidate-libhl.so | 892,080 |
| candidate-runtime.hdll | 562,576 |

Self-hosting BodyTyped observations (ms), control → candidate: seed 228.15 → 226.58; stage 1 50.65 → 50.64; stage 2
48.72 → 47.84. Framework compile observations are 492.04 → 525.28 seconds; this slower single observation is retained.
These are single observations, without a change-specific timing attribution.

The first interaction diagnostic reused the tab timeline extractor, but interaction stores its byte summaries in
`interaction.json`; its timeline allocation fields are null. Six original diagnostic records retain whole-scenario
object counts with empty action maps. The corrected parser reads `interaction.json`, requires all ten actions, and
then deletes each raw capture after recording the numbers. Three fresh diagnostic pairs supply the interaction byte
table above; the original ordinary action measurements were neither overwritten nor rerun. The parser error and its
original records are retained on disk.

Final-source validation: self-hosting fixed point; 799 compiler tests, 0 failures; all ten UI scripts; 511 parity
fixtures with 14 existing skips; six UI snapshots; app suite; nine retention scenarios; all eighteen action captures and
the final budget gate; six memory gates; 42 browser captures; three exact-byte pairs each for tabs and interaction.
The two corrected self-hosting errors above remain documented. All final-source gates pass. Source enum activation
and UI enum conversions remain unfinished.

Records and hashes are retained under `haxeon-flat-work/interface-value-gates`; raw captures are removed after extraction.

## Constant-time typed interface dispatch (November 2026) — measurements

Control is `ccf4a141`, with the editor frozen at `46044a2712525a635588feb4572fa0f2053dc06c`.
The source audit and 1/8/32-implementation benchmark are in `GENERIC_SPECIALIZATION.md`. Only
`ViewportContent.paint(Canvas, Rect)` currently selects this ABI in the UI package (one implementer); no editor-only
contract does. The editor profile module remains byte-identical at 99,957,149 bytes, SHA-256
`89c9d7b7cf31ee776b6f70177a10e7bcde3f6b24b60f54e7e76bd1eeb1830c6b`.

HashLink fork `4a33fa08` changes the checkout VM's `libhl.so`: 892,080 → 892,432 bytes. Control SHA-256 is
`d1893528f97c678299f81273974f2d33d8384eaca01acf28d1ba9e942fcc8900`; candidate is
`97abb73a9557c77a0042f4f62819790975009447fd18d330253146d5393aebba`. Paired captures preload the matching library
and runtime while using the same checkout-built launcher. Class tables live in module metadata, without enlarging
instances. They add no per-call allocations.

Nine alternating action pairs give the following medians; timing is median frame ms and KiB uses the refill-quantized
counter. All scheduled captures pass their budgets.

| Action | KiB control → candidate | ms control → candidate |
|---|---:|---:|
| tab-matrix/console->telemetry | 72.5 → 74.5 | 1.09 → 1.09 |
| tab-matrix/hierarchy->sensors | 113 → 112.8 | 1.53 → 1.53 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.2 → 1.2 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.15 → 1.15 |
| interaction/hover-away | 13.6 → 13.6 | 0.43 → 0.42 |
| interaction/hover-enter | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-field | 12.4 → 12.4 | 0.43 → 0.43 |
| interaction/hover-inside | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-other | 10 → 10 | 0.42 → 0.42 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.71 → 0.71 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | Census below | 2.91 → 2.91 |

Three additional alternating tab-matrix pairs restrict the exact byte counter to each action's window. All three
pairs tie on every action: console→telemetry 115,136 bytes; hierarchy→sensors 81,384; sensors→hierarchy 75,800;
telemetry→console 94,520. Each capture has 968,681 objects; excluding raw byte buffers, all six have 755,734 objects /
54,315,768 bytes. The ordinary +2.0 KiB for console→telemetry is a refill boundary, not an increased program allocation.
Neither that movement nor the −0.2 KiB on hierarchy→sensors changes a budget ceiling.

Selection-stress census (30 cycles), objects / bytes:

| Pair | Control | Candidate |
|---|---:|---:|
| 1 | 340,912 / 24,013,008 | 340,910 / 24,012,504 |
| 2 | 340,910 / 24,012,496 | 340,909 / 24,012,440 |
| 3 | 340,911 / 24,012,760 | 340,911 / 24,012,752 |

All six have exactly 305,725 non-byte-buffer objects / 21,594,968 corresponding bytes. Total variation is confined
to raw byte buffers.

Three paired 500-cycle headless RSS windows, MiB:

| Pair | Control | Candidate |
|---|---|---|
| 1 | 30 / 4.06 / 0.78 / 5 | 30.16 / 3.75 / 0.94 / 4.69 |
| 2 | 30.16 / 3.75 / 0.78 / 5 | 30.16 / 4.22 / 0.78 / 6.25 |
| 3 | 30.16 / 3.75 / 0.78 / 4.84 | 29.69 / 3.75 / 0.78 / 4.84 |

Median windows are 30.16 / 3.75 / 0.78 / 5 → 30.16 / 3.75 / 0.78 / 4.84 MiB. All six memory gates pass.
The 6.25 MiB fourth window is retained, with no retry.

All 36 Wasm GC scene captures and six Wasm32 full-scene captures complete without a timeout. Every GC capture ties:
4,440 objects in full/static/text-heavy; 8,724 in editing. Frame median / p95 observations (ms):

| Target / scene | Control → candidate median / p95 |
|---|---:|
| wasm-gc/editing | 2.8 / 4.8 → 2.8 / 5.1 |
| wasm-gc/full | 2.2 / 3.9 → 2.3 / 4.4 |
| wasm-gc/static | 2.2 / 3.9 → 2.2 / 3.9 |
| wasm-gc/text-heavy | 2.2 / 4.6 → 2.3 / 4.2 |
| wasm32/full | 2.3 / 4.4 → 2.4 / 4.5 |

Both final web modules are byte-identical to control. Wasm GC is 5,808,484 bytes, SHA-256
`24f2a3a31d18d28769165a80e35336155ef2b317b36b29b187e95aa70877b8ea`; Wasm32 is 11,810,665 bytes,
`3b1e48cc20dc72fa5724d2e727d4d2f2f51500d4048f95a0ddb84e62113c667b`. The runtime HDLL is also identical:
562,576 bytes, `9e07bd7d74e0a743fd94f15098b91f8d18a4524c1f2450738391bfc87ef30dbb`. Positive browser timing
observations are retained without a code-change attribution: each target uses the same guest bytes, host and loader.

Final fixed-point BodyTyped observations (ms), control → candidate: seed 226.58 → 222.26; stage 1 50.64 → 45.84;
stage 2 47.84 → 46.58. Three additional quiet alternating native-hosted compiler builds have median BodyTyped
63.87 → 62.15 ms (control 63.13 / 63.87 / 64.34; candidate 62.15 / 62.21 / 61.81). These supplementary builds
explicitly list compiler sources, with stdlib dependencies discovered from the stdlib root; the official fixed-point
gate lists both source trees. There is no observed typing-time increase requiring generator cursor work in this item.
Framework compile observations are 525.28 → 389.24 seconds, retained as single observations rather than an attributed gain.

The first compiler-suite attempt omitted the external `TMPDIR`. `LspProtocolMain` consequently created its workspace
folders below the compiler checkout, discovered that ancestor project and spent over 21 minutes indexing it. A sampled
stack resolved to `LspProtocol.changeWorkspaceFolders → LanguageService.analyze → recoverCurrentSyntax → SemanticIndex`;
this was not a GC deadlock. That invalid harness run was terminated, its temporary folders removed, and the external
`TMPDIR` restored. Corrected runs pass; the final-source run reports 802 tests, zero failures. The first exact-tabs
launcher invocation also omitted its required phase argument and raised `IndexError` before any capture; the corrected
invocation records all three pairs. Neither harness error discards or retries a completed measurement.

Final-source validation: 802 compiler tests, zero failures; self-hosting fixed point; all ten UI scripts; 512 parity
fixtures with 14 existing skips; six UI snapshots; app suite; all nine retention scenarios; all eighteen action captures
and the final budget gate; six memory gates; 42 browser captures; three exact-byte tab pairs. The final compiler's
editor rebuild reproduces the measured module byte for byte, so the completed allocation/RSS pairs apply to this source.
All final-source gates pass. Source inline enum activation and UI enum conversions remain unfinished.

Records and hashes are retained under `haxeon-flat-work/typed-interface-tables-gates`; raw captures are deleted after
recording their numbers. The finished isolated editor gate worktree has been removed. This item finishes under the
previous full-gate policy; subsequent commits use the user-approved tiered gates.

## First closed source inline enum subset (Tier 1 checkpoint) — measurements

Paired focused census, export-root checkpoint `962367ad` → activation candidate, same source and machine, both inlining
modes:

| Target / measure | 8 iterations | 1,024 iterations |
|---|---:|---:|
| HashLink allocated bytes | 384 → 0 | 49,152 → 0 |
| Wasm32 allocated objects | 16 → 0 | 2,048 → 0 |
| Wasm GC allocated objects | 16 → 0 | 2,048 → 0 |

The window constructs two payload enums per iteration and exercises null joins, copies, field/static stores and a typed
closure result. Reference payloads and the closure are prepared before the window. A first diagnostic had created the
closure inside the loop: its one Wasm GC object per iteration was closure creation, not enum boxing. Separately, the
production phi pass initially retained three Wasm32 / four Wasm GC packets per iteration because it discarded an enum
join split when the merged value escaped to a return. Enum tag-zero packets always exist, so their joins now snapshot
leaves even on branch edges without requiring the merged packet to disappear in that same pass. The final focused
fixture also checks float/bool/nested payloads, typed array construction, explicit iterators, nullable elements and
reference roots across collection.

The initial full Tier 1 run recorded 805 passes and one failure: `EnumTypedefConstructorMain` supplied target-specific
HashLink IR to both Wasm backends and failed with `Wasm call to unsupported native or missing function
"$hl:scalar-address"`. The test now compiles independently for each target and executes both Wasm targets with
inlining off/on, including cold and typedef-retargeted sources. Final-source Tier 1 passes: 806 compiler tests, zero failures, the six target/inlining modes, negative verifier/native-layout checks, and the self-hosting fixed point. Tier 2/3 validation remains pending on the batch head. Production probes also caught generated reflection exposing private packets (including a Showcase
`Reflect.reflectObjectCopy.$inline-enum:haxeon.platform.async.Outcome` helper). Private packets now stay outside the
public reflection registry; eligibility includes enum-bearing registered reflection layouts before helpers are generated.
Native field offsets computed for boxed enums are also excluded until E2 supplies recalculated physical layouts. Editor/Web artifact comparison and any required Tier 3 measurements are pending; this table is a compiler
fixture result, not the required real-app allocation decrease.

The first editor-control launcher only set prebuilt-compiler environment variables, which the project build provider
does not use for its interpreted compiler path; it therefore read candidate sources and stopped at the reflection
verifier before producing a control. The corrected launcher points `HAXEON_COMPILER_SOURCE` at an archive of
`530bda5a` and uses an absolute output path. No allocation/RSS result was collected from that invalid control launch.

BodyTyped single-run observations (ms), export-root checkpoint → activation: seed 229.68 → 235.50;
stage 1 46.72 → 45.65; stage 2 49.42 → 45.78. These are observations while other builds ran, not a typing-time
regression attribution; both native-hosted stages decreased. Generator cursor work is not indicated by these data.

Tier 3 preflight on outer `8195b397f04e2d527430607e8e3624a38df8d950` (editor controls use archived compiler
`530bda5a`; Showcase controls use the unchanged UI source at that checkpoint):

| Development module | Control bytes | Candidate bytes | Identical? |
|---|---:|---:|---|
| editor | 100,301,360 | 100,471,118 | no |
| webgc | 5,808,484 | 5,809,044 | no |
| web32 | 11,810,665 | 11,812,644 | no |

The outputs differ, so Tier 3 requires the paired allocation/RSS/browser runs. No real-app allocation decrease is claimed
before those runs. Records are under `haxeon-flat-work/enum-first-batch-gates`; controls and candidates share the pinned
outer source, native runtime and build conditions.

## Typed callback method transport (Tier 1 checkpoint) — measurements

Paired micro census, `79d4abb7` → candidate, same machine, both inlining modes. Each path calls two relays per iteration;
closures and reference payloads are prepared before the window:

| Path | HashLink bytes (8 / 1,024) | Wasm32 objects (8 / 1,024) | Wasm GC objects (8 / 1,024) |
|---|---|---|---|
| Enum callback through interface methods | 0 / 0 → 0 / 0 | 16 / 2,048 → 0 / 0 | 16 / 2,048 → 0 / 0 |
| Struct callback through interface methods | 0 / 0 → 0 / 0 | 16 / 2,048 → 0 / 0 | 16 / 2,048 → 0 / 0 |
| Enum callback through concrete methods | 0 / 0 → 0 / 0 | 16 / 2,048 → 0 / 0 | 16 / 2,048 → 0 / 0 |

The allocation comparison omits the unrelated function-cast call so the failing control can compile. The permanent
regression fixture includes that cast, reproducing the RPC adapter-planning shape as well as checking zero allocations.
It covers inheritance/overrides, verifies that the enum stays inline and forges an incompatible override that must be
excluded. The actual RPC lifecycle passes on HashLink, Wasm32 and Wasm GC with inlining off/on. One standalone Node
probe initially omitted the fixture's `__math_is_finite` host import; using the same `Number.isFinite` import as the
committed parity harness runs it successfully. No guest result or performance measurement was discarded.

Tier 1 passes: 809 compiler tests, zero failures; affected six-mode fixtures and self-hosting fixed point. The repaired
batch's Tier 2/3 validation remains pending. Records are under
`haxeon-flat-work/enum-method-closures`; product comparisons still use the batch's `530bda5a` compiler control on the
pinned outer revision, rather than treating the new micro result as a real-editor decrease.

BodyTyped observations (ms), verifier → callback transport: seed 214.87 → 216.86; stage 1 44.76 → 44.83;
stage 2 46.74 → 46.08. These are single-run observations without timing attribution.

## Nested scalar callbacks at HashLink Dynamic boundaries (2026-11-05) — measurements

Control `ae3c0dd7` and candidate use outer `9e953ecf2` on the same machine.
The expanded `scalar-closure-nested-callback` fixture reproduces a HashLink cast
failure for a boxed outer function receiving a scalar struct callback. The fix
bridges nested function arguments/results independently of the outer scalar ABI.
Both inline settings pass on all three targets. Existing managed-reference,
signal and closure-identity fixtures retain their zero-allocation assertions.
All 759 compiler tests, fixed-point self-hosting, 495 parity fixtures (14 existing
skips), six UI value snapshots, ten UI suites, app tests, retention, final editor
budgets, six headless memory runs and Wasm32 WebGL2 smoke passed.

The HashLink editor profiles are byte-identical (SHA-256
`b70186e7b9cb35211f162fec85a03df4e83962448e0311b3a08df7c736dc303b`).
Nine alternating pairs gave the following median action KiB:

| Action | Control | Candidate |
| --- | ---: | ---: |
| console->telemetry | 74.5 | 74.5 |
| hierarchy->sensors | 114.6 | 114.6 |
| sensors->hierarchy | 80.1 | 80.1 |
| telemetry->console | 92.9 | 92.9 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

Timing findings retained from the planned pairs: control hierarchy→sensors
4.28, 4.20 and 4.14 ms against 4 ms; control selection 6.16 and 6.71 ms against
6 ms; candidate selection 6.30 ms against 6 ms. These are identical-bytecode
captures. No sample was retried; the separately planned final budget gate passed.

Selection census (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,908 / 24,010,208 | 340,912 / 24,011,184 |
| 2 | 340,911 / 24,010,896 | 340,911 / 24,010,960 |
| 3 | 340,910 / 24,010,680 | 340,911 / 24,010,904 |

Only the bytes type differed within each pair. These capture buffers also vary
between the identical-image controls recorded above. Four RSS growth windows
(MiB), in pair order:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.62 / 3.44 / 0.94 / 4.84 | 30.47 / 3.75 / 0.78 / 4.84 |
| 2 | 29.69 / 3.91 / 0.94 / 4.84 | 30.16 / 3.75 / 0.78 / 5.00 |
| 3 | 29.53 / 4.06 / 0.78 / 4.84 | 30.31 / 4.06 / 0.78 / 4.84 |

All windows passed without changing a ceiling; variation remains within the
preceding same-image paired runs. Wasm GC guests are also byte-identical, SHA-256
`6a20abc1629823155f89b76dab9b67a533b8cdd30db94cd537406ba91892a3b7`.
Nine full-scene pairs and three each of static/text-heavy/editing matched:
4,440 / 4,440 objects for full/static/text-heavy and 8,724 / 8,724 for editing,
with 120 warmup / 120 measured fixed-step core frames.

Setup/resource failures are recorded rather than counted as passes. A reused
CMake cache required recreating the detached gate checkout; the first Wasm build
selected the CLI instead of the compiler; a copied browser wrapper lacked its
executable bit and caused DevTools startup failure; and the fresh app checkout
needed its top-level build directory for MissionJobsTests. Each setup error was
corrected before the successful gate. Two candidate profile builds were killed
with status 1073741839. Signal tracing identified host PID 2181160,
`/usr/bin/earlyoom -m 10,5 -s 100,100 -r 3600`, sending SIGTERM under memory
pressure. Reducing concurrent large builds resolved it; the traced build then
completed normally. Neither killed build produced measurement samples. Captures
were deleted after recording summaries.

## Uniform array growth: factor-2 trial (not accepted) — measurements

On the same machine and outer source at `8b6506f34`, implicit growth was changed
from the old target-specific policies to `max(required, capacity * 2)`; explicit
resize allocations used exactly the requested length and retained capacity when
shrinking. The first trial passed the gates but increased selection-stress array
allocations from 96,333 / 5,971,976 bytes to 131,705 / 5,162,328 bytes. Its paired
RSS windows were:

| Pair | Control MiB | Factor 2 MiB |
| --- | --- | --- |
| 1 | 28.91 / 4.38 / 0.94 / 5.00 | 28.44 / 6.41 / 0.62 / 5.31 |
| 2 | 31.09 / 3.44 / 0.78 / 4.84 | 27.97 / 6.56 / 0.62 / 5.47 |
| 3 | 30.00 / 4.22 / 0.78 / 5.00 | 28.28 / 6.09 / 0.62 / 5.31 |

Sharing immutable empty backing storage for arrays without a metadata owner
removed exactly 25,926 eight-byte allocations from the selection census. Owned
empty storage still pins its metadata. A subsequent allocation-site census found
that `ComputedStyle.setDeclaration` explicitly resized for every new property;
those allocations increased from 113,696 to 395,808 bytes in the four-cycle
capture. Its indexed writes now use implicit growth directly. With both fixes,
selection-stress arrays were 103,803 / 4,640,584 bytes: 7,470 more objects and
1,331,392 fewer bytes than control. Total paired census results were:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | ---: | ---: |
| 1 | 340,906 / 24,009,648 | 348,380 / 22,679,376 |
| 2 | 340,911 / 24,010,912 | 348,382 / 22,679,808 |
| 3 | 340,912 / 24,011,136 | 348,378 / 22,678,824 |

The next memory pair measured control windows 30.00 / 4.06 / 0.78 / 5.00 MiB
and candidate 27.66 / 8.12 / 0.31 / 5.62 MiB. The candidate failed with
`RSS grew more than 8 MiB per 100 cycles in consecutive windows`. This result
was retained, not retried for acceptance. A uniform factor-1.5 trial follows;
no budget ceiling or memory threshold was raised.

The permitted factor-1.5 alternative used `max(required, capacity + capacity / 2)`
on all three targets, with the same exact explicit sizing and the two fixes above.
Its three paired headless runs passed the absolute memory gate, but retained a
consistent second-window regression and increased total growth in every pair:

| Pair | Control MiB | Factor 1.5 MiB | Sum delta MiB |
| --- | --- | --- | ---: |
| 1 | 30.94 / 3.59 / 0.78 / 4.69 | 28.75 / 7.34 / 0.31 / 5.47 | +1.87 |
| 2 | 29.06 / 4.38 / 0.62 / 5.00 | 28.28 / 7.66 / 0.31 / 5.62 | +2.81 |
| 3 | 30.16 / 4.06 / 0.94 / 4.84 | 28.12 / 7.50 / 0.31 / 6.09 | +2.02 |

These passing gate verdicts do not establish no regression against control.
Neither tested growth factor is accepted on this evidence. The implementation
is preserved on disk pending a solution to the small-array allocation/memory
cost. The alternative is to keep the committed policy until that cost is resolved;
adding a minimum starting capacity would violate the decided uniform formula,
and changing a gate threshold would not fix the allocation pattern.

Factor-1.5 selection-stress census (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,904 | 356,980 / 23,405,752 |
| 2 | 340,911 / 24,010,912 | 356,983 / 23,406,552 |
| 3 | 340,909 / 24,010,336 | 356,981 / 23,406,040 |

Nine alternating per-action HashLink allocation pairs gave these medians (KiB):

| Action | Control | Factor 1.5 |
| --- | ---: | ---: |
| hover-away | 13.6 | 11.8 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.3 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 9.9 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.1 |
| type-char | 16.1 | 16.1 |
| console->telemetry | 74.5 | 72.0 |
| hierarchy->sensors | 114.6 | 110.1 |
| sensors->hierarchy | 80.1 | 75.7 |
| telemetry->console | 92.9 | 90.4 |

All eighteen action captures passed their budget verdicts.

The earlier factor-2 compiler checkpoint passed 763 tests with zero failures,
self-hosting, 498 Wasm parity fixtures (14 existing skips), all six UI value
snapshots, all ten UI suites, app tests, retention and the Wasm32 WebGL2 smoke.
Its full-scene Wasm GC allocation pairs were equal: 4,440 objects for full,
static and text-heavy scenes; 8,724 for editing. Those results precede the
ComputedStyle change and the factor-1.5 experiment; they are not a claim that
the rejected final candidate passed all targets. Factor 1.5 was measured first
on HashLink and was not advanced to a new Wasm guest after its memory regression.
The new capacity fixture passed on all three targets with inlining both enabled
and disabled under factor 2, including sparse jumps and shrink/regrow reuse.
A native ASan/UBSan probe passed 20,000 deterministic mixed lane operations.

One factor-1.5 harness invocation encountered a leftover failed factor-2 capture
directory (`File exists: .../capture-rss-0-candidate`) before starting that guest.
The recorded directory was deleted, the already completed control sample was
retained, and the missing candidate and remaining pairs were run once. No failed
memory sample was replaced. All measurements and implementation patches are
preserved under `materia-cache/claude-scratch/haxeon-growth-policy-blocked-2026-11-05/`.
The requested `hl-exit-crash` merge remains queued after the growth-policy commit;
no merge was started during these measurements.

The separately planned final factor-1.5 budget run and all nine retention scenarios passed.
The implementation was then parked and only its own source changes were removed;
the committed runtime policy is retained. No new full-suite pass is claimed for
the factor-1.5 trial, and no implementation or submodule pin was published.

## Checkout VM launcher integration — measurements

The HashLink fork pin stays `d1eb6136`, and the rejected growth policy stays
parked. This is a VM/library launch comparison against the same `e80c1a60`
control and outer `8b6506f34` source used for the growth trial, on the same machine.
The outer ports also replace joined VM paths in project generation and UI
extensions; project fingerprints stamp the actual checkout VM, rather than the
launcher script. The profile program hashes are `69dc45510e74` (control) and
`6cbf9e02c12e` (candidate).

Nine alternating action pairs gave these allocation medians in KiB:

| Action | Control | Checkout launchers |
| --- | ---: | ---: |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |
| console->telemetry | 74.5 | 74.5 |
| hierarchy->sensors | 114.6 | 114.6 |
| sensors->hierarchy | 80.1 | 80.1 |
| telemetry->console | 92.9 | 92.9 |

Every action capture passed its budget verdict.

Selection-stress census pairs (objects / bytes):

| Pair | Control | Checkout launchers |
| --- | ---: | ---: |
| 1 | 340,909 / 24,010,456 | 340,908 / 24,010,232 |
| 2 | 340,910 / 24,010,712 | 340,910 / 24,010,680 |
| 3 | 340,911 / 24,010,944 | 340,912 / 24,011,200 |

Only `bytes` differed: −1 / 0 / +1 objects and −224 / −32 / +256 bytes.
All other types matched exactly: 305,725 objects / 21,593,528 bytes in every run.
No application object type increased. The small byte-buffer variations also
occur in the preceding control captures.

Four headless RSS growth windows (MiB):

| Pair | Control | Checkout launchers |
| --- | --- | --- |
| 1 | 29.38 / 4.06 / 0.78 / 4.84 | 30.78 / 3.44 / 0.78 / 5.00 |
| 2 | 30.31 / 3.91 / 0.62 / 5.00 | 30.16 / 3.75 / 0.78 / 5.00 |
| 3 | 30.16 / 3.44 / 0.94 / 5.00 | 30.47 / 3.59 / 0.62 / 5.00 |

All six memory runs passed. The first pair's +1.40 MiB first-window difference
is retained. Median paired window differences were +0.31 / −0.16 / 0.00 /
0.00 MiB, and the median paired sum difference was +0.14 MiB. These are within
the previously recorded same-image median window differences of up to 0.31 MiB; the numbers
do not establish exact RSS equality. The checkout VM location and its rebuilt
libraries are part of this baseline change; no memory ceiling was raised.

The newly built Wasm GC Showcase guest was byte-for-byte identical to control
(SHA-256 `edd093e31f00ed8bd9123b79441a24a4c7281139c51b19d363ac88c60f335b3d`).
All 18 scene pairs completed: nine full-scene pairs and three each for static,
text-heavy and editing. Every full/static/text-heavy sample counted 4,440 objects;
every editing sample counted 8,724. No timeout remained open. Wasm32's browser
smoke passed with WebGL2 enabled.

The functional gates passed: 762 compiler tests with zero failures, self-hosting
fixed point, all ten UI suites, 497 Wasm parity fixtures with 14 existing skips,
all six UI value snapshots, app tests and all nine retention scenarios. The
checkout-selection, VM/profiler launcher and loaded-runtime isolation regressions
passed. Changed outer Python and shell files parsed, and the existing hobber
budget-resume regression passed using the new launcher path.

The self-hosted Showcase build exposed a missing library search path when it
invoked the checkout VM directly. It now invokes `scripts/hl`; a fresh Wasm GC
build without an inherited runtime library path and the Wasm32 smoke cover the
fix. The first detached app run failed `Mission jobs failed: Could not open
output file`: the fresh gate snapshot lacked its top-level `build/` directory.
Creating that directory fixed the harness; the fresh app rerun also includes the
additional joined-path ports. Neither failure was discarded as a measurement.

Outer `machinekit/examples/flexspline-hobber/PLAN.md` was skipped because it had
another session's uncommitted changes. The ignored generated
`app/build/performance/launch-existing.sh` was updated locally; generated build
output was not added to source control. All other launcher ports are committed
by their explicit paths. Captures are deleted as soon as their numbers are
recorded, and no budget ceiling changed.

The separately planned final editor budget run and its nine retention scenarios also passed.

## Wasm GC scalar words and range operations — measurements

The paired microbenchmark uses Node v22.21.1 on an Intel i5-13600K, 4,096 elements, eight rounds, three warmup calls and nine alternating pairs. Each of the 216 observations allocated zero objects and matched the control result. Times are medians in milliseconds:

| Inline | Operation | Control | Candidate | Speedup |
| --- | --- | ---: | ---: | ---: |
| 0 | readRects | 4.998 | 0.405 | 12.35× |
| 0 | writeRects | 5.557 | 1.374 | 4.05× |
| 0 | reverseRects | 8.822 | 0.568 | 15.53× |
| 0 | readTiny | 1.059 | 0.332 | 3.19× |
| 0 | writeTiny | 1.399 | 1.011 | 1.38× |
| 0 | reverseTiny | 1.280 | 0.694 | 1.84× |
| 1 | readRects | 4.980 | 0.434 | 11.47× |
| 1 | writeRects | 5.559 | 1.359 | 4.09× |
| 1 | reverseRects | 8.831 | 0.555 | 15.90× |
| 1 | readTiny | 1.059 | 0.413 | 2.56× |
| 1 | writeTiny | 1.398 | 1.007 | 1.39× |
| 1 | reverseTiny | 1.285 | 0.702 | 1.83× |

The source null guards found by self-hosting were corrected before acceptance. Both microbenchmark guests and the complete Showcase guest were rebuilt with the corrected compiler and were byte-identical to the measured versions; no timing capture was repeated.

The HashLink editor program was byte-identical between control and candidate (SHA-256 `6cbf9e02c12e`). Nine alternating pairs gave the following per-action medians in KiB:

| Action | Control | Word accessors |
| --- | ---: | ---: |
| console->telemetry | 74.5 | 74.5 |
| hierarchy->sensors | 114.6 | 114.6 |
| sensors->hierarchy | 80.1 | 80.1 |
| telemetry->console | 92.9 | 92.9 |
| hover-away | 13.6 | 13.6 |
| hover-enter | 0.5 | 0.5 |
| hover-field | 12.4 | 12.4 |
| hover-inside | 0.5 | 0.5 |
| hover-other | 10.0 | 10.0 |
| idle | 0.2 | 0.2 |
| idle-focused | 0.2 | 0.2 |
| scroll-inspector | 21.2 | 21.2 |
| type-backspace | 16.2 | 16.2 |
| type-char | 16.1 | 16.1 |

Selection-stress, 30 cycles, three alternating census pairs. Each program type matched exactly at 305,725 objects / 21,593,528 bytes; the only varying type was runtime `bytes`. Raw census totals, including those buffers:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,976 | 340,911 / 24,010,880 |
| 2 | 340,911 / 24,010,984 | 340,912 / 24,011,296 |
| 3 | 340,910 / 24,010,680 | 340,910 / 24,010,776 |

Paired headless RSS window growth in MiB (four successive windows per run); every run passed:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.94 / 3.44 / 0.78 / 5.00 | 30.31 / 3.75 / 0.94 / 5.00 |
| 2 | 30.16 / 4.06 / 0.94 / 4.84 | 29.84 / 3.44 / 0.94 / 4.69 |
| 3 | 29.84 / 3.91 / 0.62 / 5.16 | 31.09 / 3.44 / 0.78 / 4.69 |

The paired median differences were -0.32 / -0.47 / +0.16 / -0.15 MiB, within the earlier same-image calibration. No action allocation median increased, and no budget ceiling changed.

The corrected 2026-11-05 Wasm GC Showcase comparison completed all 18 alternating pairs: nine full-scene pairs and
three each for static, text-heavy and editing. Fixed-step core mode used 120 warmup and 120 measured frames. Every
full/static/text-heavy sample counted 4,440 objects; every editing sample counted 8,724, equal between control and
candidate. There was no browser timeout. Each result records the SHA-256 of `nativekit_ui_haxeon_guest.wasm`, checked
before and after capture: control starts `edd093e31f00`, candidate `960b1eee5ee3`. The rebuilt control exactly matches
the original pre-word-access artifact. These results replace the original invalid source-file swaps; their identical
counts alone were not evidence of a valid pair.

All gates passed: 763 compiler tests, self-hosting fixed point, ten UI suites, 498 parity fixtures (14 existing skips),
six UI value snapshots, app suite, nine retention scenarios, editor budgets and paired headless memory gates. Wasm32's
WebGL2 browser smoke passed. The native build also passed with the pinned Haxe tool directory hidden, proving it
consumes the checked-in header without requiring the generator.

The detached app harness needed both `build/` and `app/build/` directories: the first app run reported
`CAD plate workflow tests failed: Could not open output file` because `app/build/` was missing. A subsequent compiler
process received SIGTERM (status 1073741839); its sender was not established. After compiler artifacts were frozen,
the traced run completed the app suite and retention without an unexpected compiler signal. These failed setup runs
preceded all performance captures. No measurement was rerun to obtain a pass. Raw captures were deleted immediately
after their numbers were extracted.

## Values have equality; objects have identity (2026-11-05) — measurements

Comparison: the same outer `0d3ca41a8` editor snapshot, checkout-built HashLink VM `d1eb6136`, frozen compiler and
profile artifacts, nine alternating control/candidate action pairs, three selection censuses and three RSS pairs.
HashLink action allocation medians (KiB) and frame medians (ms) are below. The selection action has no frame allocation
metric; its exact census follows. Timings include the concurrent external workload described below.

| Scenario/action | Control KiB | Candidate KiB | Control ms | Candidate ms |
| --- | ---: | ---: | ---: | ---: |
| tab-matrix: console->telemetry | 74.5 | 74.5 | 1.20 | 1.15 |
| tab-matrix: hierarchy->sensors | 114.6 | 114.6 | 1.74 | 1.65 |
| tab-matrix: sensors->hierarchy | 80.1 | 80.1 | 1.33 | 1.27 |
| tab-matrix: telemetry->console | 92.9 | 92.9 | 1.30 | 1.18 |
| interaction: hover-away | 13.6 | 13.6 | 0.46 | 0.61 |
| interaction: hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| interaction: hover-field | 12.4 | 12.4 | 0.46 | 0.62 |
| interaction: hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| interaction: hover-other | 10.0 | 10.0 | 0.45 | 0.60 |
| interaction: idle | 0.2 | 0.2 | 0.01 | 0.01 |
| interaction: idle-focused | 0.2 | 0.2 | 0.01 | 0.01 |
| interaction: scroll-inspector | 21.2 | 21.2 | 0.75 | 1.04 |
| interaction: type-backspace | 16.2 | 16.2 | 0.45 | 0.60 |
| interaction: type-char | 16.1 | 16.1 | 0.45 | 0.60 |
| selection-stress: selection | — | — | 4.40 | 4.22 |

No action allocation median increased; no ceiling changed. Every named census type matched exactly in every pair:
305,725 objects / 21,593,528 bytes. The only differences were in the runtime `bytes` bucket (16, 88 and 424 bytes;
the last pair also differed by one raw buffer). Raw totals, including that bucket:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | --- | --- |
| 1 | 340,910 / 24,010,728 | 340,910 / 24,010,744 |
| 2 | 340,909 / 24,010,352 | 340,909 / 24,010,440 |
| 3 | 340,910 / 24,010,624 | 340,911 / 24,011,048 |

Headless RSS window growth, MiB (four consecutive windows):

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.47 / 3.59 / 0.78 / 5.00 | 30.16 / 3.91 / 0.78 / 4.84 |
| 2 | 29.69 / 3.75 / 0.62 / 5.00 | 30.16 / 3.91 / 0.62 / 4.84 |
| 3 | 30.00 / 3.59 / 0.62 / 5.00 | 30.00 / 3.59 / 0.94 / 4.84 |

Paired median deltas were 0.00 / +0.16 / 0.00 / -0.16 MiB, within the earlier same-image calibration; all six
headless memory runs passed. These small mixed window changes do not show the consistent retained-growth increase
that rejected the growth trials.

The unrestricted timing captures retained every sample: selection exceeded 6 ms on candidate pairs 5–7
(11.20, 9.62, 6.61 ms) and control pair 6 (8.01 ms), coinciding with concurrent external ngspice work. The single
planned final budget run also failed: `selection-stress selection: frameMs 8.67 is over the budget 6.0`. No samples
were discarded and no budget was raised. One additional control/candidate comparison used the same fixed affinity
on four distinct performance cores (CPUs 0, 2, 4, 6), selected once before either run. Both passed every unchanged
budget on their first run, with selection at 4.62 / 4.52 ms. There were no further attempts. Retention had already
passed independently on all nine scenarios; the affinity comparison did not change verify mode or the executable.

The Wasm GC comparison swapped the actual browser-loaded guest and checked its SHA-256 before and after every
capture. Control starts `960b1eee5ee3`, candidate `4f892cc3b546`. All 18 pairs completed (nine full, three each
static/text-heavy/editing), with 120 warmup and 120 measured frames. Both images allocated 4,440 objects in each
full/static/text-heavy sample and 8,724 in each editing sample.

All functional gates passed: 763 compiler tests, self-hosting fixed point, ten UI suites, 497 parity fixtures
(14 existing skips) and all six UI value snapshots, the app suite, all nine retention scenarios, and Wasm32/Wasm GC
WebGL2 browser smoke tests. The identity fixture passes on all three targets with inlining on and off, including
interface views, nulls, Dynamic escapes and an ignored class comparison hook; prepared 8/1,024-call Wasm censuses
allocate zero. Compiler tests cover rejected direct/transitive class conformance and value bounds, and the interpreter
uses the same identity rule. No performance increase is attributed to this change from the loaded timing samples.

Two setup failures preceded these captures: a compiler-suite invocation omitted `TMPDIR`, so its LSP temporary
workspace inherited the compiler checkout and indexed it; that test was terminated and the complete suite passed
with an external temporary directory. A copied browser wrapper initially lacked its execute bit, producing
`Permission denied`; correcting the wrapper made both browser smoke tests pass. The earlier framework run
confirmed the missed style-cache content comparison before its fix. None was an allocation/memory retry. Raw captures
were deleted once their numbers were recorded.

## Inline enum layout and word-access checkpoint (2026-11-06) — measurements

This checkpoint compares `44ce670a` with `bf962e0f` on the same outer source snapshot (`212462122`). It adds the
portable enum layout planner and executable packed-word access helpers; source enum lowering and the UI enum port are
still pending. `4ef16d5e` fixes full-width IR interpreter arithmetic, `a7cb8e80` plans the overlapping lanes,
`0c05dfc6` tests packed integer/Float/Boolean access, and `bf962e0f` fixes source Int64 constructors in the interpreter.
The word helper currently handles I32, I64, F64 and Boolean leaves; F32, pointer/handle leaves and reference-field
storage still need integration before source enum lowering can be enabled.

The freshly built control and candidate editor bytecode are **identical**, SHA-256
`96004bf29a29702ad7a609b4339f07d8ce46a8aa9bf1e3029b598fb479da6383` (103,141,814 bytes).
The VM library and runtime are also byte-for-byte identical. Rebuilding both compiler entrypoints from current source
produces the same binaries used by the app and retention gates. The helpers do not yet change emitted editor code;
timing differences in this checkpoint are measurement variation, not an optimization result.

Nine fixed alternating action pairs use the preceding affinity (`0,2,4,6`), with one capture per scenario in each half.
Every instrumented per-action allocation median ties. Selection has no per-action KiB metric in this harness; its
allocation census is recorded separately below. Medians:

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
|---|---:|---:|---:|---:|
| tab-matrix/console->telemetry | 74.5 | 74.5 | 1.94 | 1.97 |
| tab-matrix/hierarchy->sensors | 114.6 | 114.6 | 2.98 | 2.89 |
| tab-matrix/sensors->hierarchy | 80.1 | 80.1 | 2.16 | 2.19 |
| tab-matrix/telemetry->console | 92.9 | 92.9 | 2.08 | 2.08 |
| interaction/hover-away | 13.6 | 13.6 | 0.90 | 0.80 |
| interaction/hover-enter | 0.5 | 0.5 | 0.01 | 0.01 |
| interaction/hover-field | 12.4 | 12.4 | 0.91 | 0.86 |
| interaction/hover-inside | 0.5 | 0.5 | 0.01 | 0.00 |
| interaction/hover-other | 10 | 10 | 0.90 | 0.81 |
| interaction/idle | 0.2 | 0.2 | 0.03 | 0.02 |
| interaction/idle-focused | 0.2 | 0.2 | 0.02 | 0.02 |
| interaction/scroll-inspector | 21.2 | 21.2 | 1.45 | 1.35 |
| interaction/type-backspace | 16.2 | 16.2 | 0.79 | 0.77 |
| interaction/type-char | 16.1 | 16.1 | 0.80 | 0.77 |
| selection-stress/selection | n/a | n/a | 8.67 | 6.02 |

The planned `--measure` samples report timing ceiling violations on both identical images. Selection's ceiling is
6.0 ms; all nine pairs, including the slower samples, are retained here rather than discarded:

| Pair | Control selection ms | Candidate selection ms |
| --- | ---: | ---: |
| 1 | 8.37 | 6.02 |
| 2 | 8.67 | 10.37 |
| 3 | 9.33 | 14.69 |
| 4 | 9.90 | 11.76 |
| 5 | 5.33 | 4.48 |
| 6 | 12.64 | 4.75 |
| 7 | 10.81 | 6.51 |
| 8 | 4.34 | 5.17 |
| 9 | 4.81 | 4.29 |

The other reported timing violation is exactly `tab-matrix hierarchy->sensors: frameMs 4.68 is over the budget 4.0`
(control pair 6). No allocation ceiling was exceeded. The first standalone `--budgets --skip-build --runs 1` gate after
the planned pairs passes all three scenarios and all nine retention checks; selection's frame median in that run is
4.7 ms. It was scheduled before the pairs started and was not a retry of a failed standalone gate. None of the
measurement findings above is being counted as a passing gate or used to claim a performance improvement.

Three alternating selection census pairs have identical non-`bytes` type counts: **305,725 objects / 21,593,528 bytes**
on both sides in every pair. Full totals retain the raw `bytes` category:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | ---: | ---: |
| 1 | 340,911 / 24,010,840 | 340,910 / 24,010,592 |
| 2 | 340,910 / 24,010,616 | 340,910 / 24,010,584 |
| 3 | 340,910 / 24,010,496 | 340,909 / 24,010,352 |

Three unrestricted paired headless runs all pass. RSS window growth in MiB:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.47 / 3.59 / 0.78 / 5.00 | 30.16 / 3.75 / 0.78 / 5.00 |
| 2 | 30.31 / 3.91 / 0.78 / 5.00 | 29.84 / 3.91 / 0.78 / 5.00 |
| 3 | 29.69 / 4.06 / 0.78 / 5.00 | 30.00 / 3.91 / 0.78 / 5.00 |

Window medians are **30.31 / 3.91 / 0.78 / 5.00** for control and **30.00 / 3.91 / 0.78 / 5.00** for candidate.
No allocation or memory median increases. Budget ceilings, verify behavior and immutable values are unchanged.

The app suite, all nine retention scenarios, 774 compiler tests, self-hosting fixed point and all ten UI suites pass.
Wasm parity passes 502 fixtures (14 existing skips) and all six UI value snapshots. Wasm32 and Wasm GC package builds
and WebGL2 smoke checks pass. All 18 Wasm GC scene pairs complete: nine full and three each static, text-heavy and
editing, with 120 warmup and 120 measured frames. Both actual browser-loaded guests have SHA-256
`e81a925cba8fccafc6430f95fbe1cd6a27feb3f77e34a3b9bd080c3a5ea306a1`. Every full/static/text-heavy sample counts
4,440 objects; every editing sample counts 8,724. Raw captures were deleted immediately after
extracting their numbers, and the idle outer gate worktree was removed when editor measurements finished.

## Float32 enum payload words — measurements

Control is Haxeon `25eb407f`; both builds use committed outer `8ab5cb995` on the same machine.
This checkpoint adds payload bit access, without activating source inline enums. The editor profiles are byte-identical
(97,753,655 bytes, SHA-256 `ff19cde59d778231dc445ad4b36c5ac0da543452ae1dcccfa040731a2ffd90c9`).
The HashLink VM is unchanged; the candidate native runtime adds the two Float32 bit conversions.
Nine alternating action pairs give these allocation and frame-time medians:

| Action | Control → candidate KiB | Control → candidate ms |
| --- | ---: | ---: |
| console->telemetry | 72.5 → 72.5 | 1.1 → 1.09 |
| hierarchy->sensors | 112.6 → 112.6 | 1.55 → 1.54 |
| sensors->hierarchy | 80.1 → 80.1 | 1.21 → 1.21 |
| telemetry->console | 92.9 → 92.9 | 1.16 → 1.15 |
| hover-away | 13.6 → 13.6 | 0.42 → 0.42 |
| hover-enter | 0.5 → 0.5 | 0 → 0 |
| hover-field | 12.4 → 12.4 | 0.42 → 0.43 |
| hover-inside | 0.5 → 0.5 | 0 → 0 |
| hover-other | 10 → 10 | 0.41 → 0.42 |
| idle | 0.2 → 0.2 | 0.01 → 0.01 |
| idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| scroll-inspector | 21.2 → 21.2 | 0.71 → 0.71 |
| type-backspace | 16.1 → 16.1 | 0.41 → 0.41 |
| type-char | 16.1 → 16.1 | 0.41 → 0.42 |

Selection census, three alternating pairs (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,912 / 24,011,264 | 340,910 / 24,010,856 |
| 2 | 340,909 / 24,010,592 | 340,910 / 24,010,904 |
| 3 | 340,908 / 24,010,176 | 340,911 / 24,011,112 |

Every capture has exactly 305,725 non-byte objects / 21,593,528 bytes; the small differences are confined to
raw byte buffers. Paired headless RSS window growth, MiB (all four windows in order):

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30 / 3.44 / 0.78 / 5 | 30.31 / 3.59 / 0.78 / 4.84 |
| 2 | 29.53 / 4.22 / 0.62 / 4.84 | 30.31 / 3.75 / 0.78 / 5.78 |
| 3 | 29.53 / 4.38 / 0.78 / 4.84 | 29.84 / 3.75 / 0.62 / 5 |

Paired median deltas are +0.31 / −0.47 / 0 / +0.16 MiB. Positive sampled windows, including 5.78 MiB, are
recorded, not retried. The previous checkpoint included a 6.41 MiB final window; its separate unchanged-build
calibration spanned 4.84–5.00 MiB there. Thus the 5.78 MiB sample exceeds that calibration range, while the paired
median delta is +0.16 MiB. There is no claim that every RSS sample is identical or lower.
All memory checks and the first scheduled standalone budget check pass, with unchanged allocation medians.

Wasm GC uses nine full-scene pairs and three pairs each for static, text-heavy and editing, 120 warmup / 120 measured
frames. Every pair matches at 4,440 / 4,440 / 4,440 / 8,724 objects respectively. Both loaded guests retain SHA-256
`ff3dc27e5acfde09528c2b1ac52b10d7a2bd739086be1d2b719a67ab061d91c9`. Wasm32's three full-scene load pairs
use byte-identical guests (`5645df810a815c6f74594718d41222cb692fec8cec478e46a0ea4647ff63a4b6`); its runner
has no Wasm GC object counter. No browser timeout occurred.

The word-access fixture verifies Float32 rounding and bit transport (negative values, signed zero, subnormal, NaN
and infinity), crossing 32- and 64-bit words, on the interpreter and all three backends, with and without inlining.
The HashLink exact census and both Wasm allocation counters report zero allocations for 8 and 1,024 warmed calls.
775 compiler tests, self-hosting fixed point, all ten UI suites, 502 parity fixtures (14 existing skips), all six UI
snapshots, the app suite, nine retention scenarios, budgets, memory, and both Web build/smoke checks pass.
Raw captures are deleted after extracting their results; this checkpoint's idle gate checkout is removed.

## Preserve typed iterator sources — measurements

Nine alternating action pairs; existing refill-quantized KiB and median frame ms:

| Action | KiB control → candidate | ms control → candidate |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 72.5 → 72.5 | 1.09 → 1.1 |
| tab-matrix/hierarchy->sensors | 113 → 113 | 1.55 → 1.57 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.2 → 1.22 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.15 → 1.16 |
| interaction/hover-away | 13.6 → 13.6 | 0.42 → 0.42 |
| interaction/hover-enter | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-field | 10.9 → 10.9 | 0.43 → 0.43 |
| interaction/hover-inside | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-other | 10 → 10 | 0.42 → 0.42 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.71 → 0.71 |
| interaction/type-backspace | 16.2 → 16.2 | 0.41 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | census below | 2.96 → 2.96 |

Every action allocation median ties. The editor images and VM/runtime images are byte-identical; timing differences
are not attributed to the compiler change. All action and budget captures passed without a ceiling change.

Three selection census pairs, 30 cycles each (objects / allocated bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,910 / 24,012,392 | 340,909 / 24,012,064 |
| 2 | 340,909 / 24,012,064 | 340,911 / 24,012,544 |
| 3 | 340,912 / 24,012,856 | 340,909 / 24,012,064 |

All six censuses have exactly 305,725 non-byte objects / 21,594,968 non-byte bytes. The remaining variation is in raw byte
buffers. No reduction in those buffers is claimed.

Paired RSS window growth in MiB (cycles 100–200 / 200–300 / 300–400 / 400–500):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 30.16 / 3.75 / 0.94 / 4.84 | 30.31 / 3.44 / 0.78 / 5.00 |
| 2 | 30.16 / 3.44 / 0.78 / 5.00 | 30.47 / 3.91 / 0.62 / 5.00 |
| 3 | 29.84 / 3.91 / 0.78 / 4.84 | 30.00 / 4.06 / 0.78 / 4.84 |

Median paired deltas are +0.16 / +0.15 / −0.16 / 0.00 MiB. These positive windows are retained in the record. All six
leak/RSS gates passed; both images and VM/runtime binaries are identical, and the movements are smaller than the
identical-image A/A window variation recorded above. No additional runs selected a replacement result.

Showcase: 18 Wasm GC scene pairs (9 full; 3 each static, text-heavy and editing) and 3 Wasm32 full-scene pairs, all completed.

| Target / scene | GC objects control → candidate | Frame median / p95 ms control → candidate |
| --- | ---: | ---: |
| wasm-gc / editing | 8,724 → 8,724 | 2.2 / 4.1 → 2.2 / 3.8 |
| wasm-gc / full | 4,440 → 4,440 | 2.1 / 3.7 → 2.2 / 4.1 |
| wasm-gc / static | 4,440 → 4,440 | 1.8 / 3.4 → 1.8 / 3.5 |
| wasm-gc / text-heavy | 4,440 → 4,440 | 2.0 / 3.6 → 2.1 / 3.8 |
| wasm32 / full | not reported | 2.1 / 3.7 → 2.2 / 3.6 |

Binary sizes tie: editor 99,956,762 bytes, Wasm GC Showcase 5,810,217 and Wasm32 Showcase 11,876,090. Each control/candidate
module pair has the same SHA-256. Both browser smoke tests passed. The new outer input explains why this editor image
differs from the previous section; both sides of this comparison use the new input.

Validation: 791 compiler tests, 0 failures; self-hosting fixed point; ten UI gates; 507 parity fixtures (14 existing skips);
six UI snapshots; app suite; nine retention scenarios; budgets; headless memory; all scene pairs above. Source inline
enum activation and the remaining closure/reflection/native integration are still pending.

## Nominal-tag assembly traversal follow-up (2026-11-09) — measurements

The final timing comparison uses the same 661 compiler/stdlib files for every compiler, checkout VM `3ea38fcf`,
stock-Haxe-built compiler executables (matching the reviewed regression measurement), and CPU affinity `0-11`
on both sides. No GC settings change. Control compiler source is `39522d88`; the tagged comparison is `f766c04a`.
Sampling also runs compiler-built executables, confirming the traversal/array-pass costs on the self-hosted path.
Temporary profiling overlays and captures stay outside the checkout; no profiling hooks enter the compiler.
The final input SHA-256 is `5536e50bfb09571f3664d94bebcc0a764d7c73c2e754f26ba60231ec0d76f7bd`.

| Pair | Control IR assembly (ms) | Candidate IR assembly (ms) | Control BodyTyped (ms) | Candidate BodyTyped (ms) |
|---|---:|---:|---:|---:|
| 1 | 5,002.05 | 5,173.04 | 140.72 | 130.61 |
| 2 | 5,113.99 | 5,169.55 | 144.28 | 129.48 |
| 3 | 7,047.45 | 6,387.61 | 137.36 | 140.28 |

Median assembly is **5,113.99 → 5,173.04 ms (+1.15%)**, within observed control variation;
median BodyTyped is **140.72 → 130.61 ms**.
Pair 3 overlaps another compiler suite and app guest; its negative delta is not an improvement claim. All pairs are
retained. Earlier definition-only and lazy-escape cuts still measured +6.47% and +5.64%; the first lane-index cut
measured +2.64%. Those cuts were not accepted as the final compile-time result. Other contended diagnostic sets
varied by seconds and were retained as diagnostic records, not used to claim a speedup.

All three optimized outputs are byte-identical to `f766c04a` on these frozen inputs: **36,033,551 bytes**,
SHA-256 `06d3fea984a3e27b4ce007e69669c884f8acaf82e1d0afcd8116de575ff5c54f`. The first pair's allocator phase meter reports
**2,404,723,136 → 2,419,281,624 bytes**, **55,818,376 → 55,834,661 allocations**; these are compiler phase counters,
not editor action allocations. The unchanged output verifies that this optimization does not change allocation behaviour for this
compiler workload. The batch still needs its editor/Web Tier 2/3 checkpoint before publication.


Final Tier 1: **844 passed, zero failed** with eight workers, all affected tag/array fixtures on HashLink, Wasm32
and Wasm GC with inlining off/on, and a self-hosting fixed point. A final sampling pair also executes the compiler-built
control and fixed-point candidate; their profiled assembly times are 8,266.38 / 5,876.66 ms under concurrent gate
load, so those single observations are diagnostic only and do not replace the unprofiled paired table above.

## Final constructor-initialized metadata field — measurements

Control is published `4b16f69d`; candidate is the source in this commit. Both use frozen outer `2de94628c`
with identical required Flags/NativeIdentity ports, VM `3ea38fcf`, and the same machine. Heavy builds are
serialized with `haxeon-heavy.lock`. Each fixed three-pair measurement holds the measurement lock and
heavy-build lock, includes every sample, and deletes captures after extracting results. All six budget runs,
six 500-cycle memory runs and thirty browser runs pass. No budget ceiling changes.

| Development module | Published control bytes | Final bytes | Reduction |
|---|---:|---:|---:|
| editor | 105,419,778 | 105,384,762 | 35,016 |
| headless | 106,223,172 | 106,190,686 | 32,486 |
| web32 | 12,500,276 | 12,193,198 | 307,078 |
| webgc | 6,010,873 | 5,956,459 | 54,414 |

Final Wasm32 / GC defined-function counts are **7,002 / 4,346** (published **7,249 / 4,436**).
Closure-adapter and closure-cast counts and body bytes return exactly to the pre-enum-batch values on both
targets. Residual growth over that older control is 151,628 / 53,404 bytes: on Wasm32, 45,872 GC-root
metadata, 42,763 patch metadata, 38,680 code and 24,313 other bytes; on GC, 27,562 patch metadata,
16,610 code and 9,232 other bytes. Remaining additions include the concrete style value types, enum equality/
hash and tag escape helpers, and their development metadata. The next native-enum group compares its own
function/section sizes against this corrected result.

| Action | Control KiB | Final KiB | Control ms | Final ms |
|---|---:|---:|---:|---:|
| console->telemetry | 73.0 | 71.0 | 1.41 | 1.44 |
| hierarchy->sensors | 111.0 | 111.0 | 1.93 | 2.01 |
| hover-away | 13.6 | 13.6 | 0.53 | 0.47 |
| hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-field | 12.3 | 12.3 | 0.56 | 0.49 |
| hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-other | 9.9 | 9.9 | 0.56 | 0.50 |
| idle | 0.3 | 0.3 | 0.02 | 0.01 |
| idle-focused | 0.3 | 0.3 | 0.01 | 0.01 |
| scroll-inspector | 21.7 | 21.7 | 0.85 | 0.75 |
| selection | 567.203125 (exact) | 567.203125 (exact) | 3.03 | 3.17 |
| sensors->hierarchy | 78.3 | 78.3 | 1.51 | 1.53 |
| telemetry->console | 89.4 | 89.4 | 1.44 | 1.64 |
| type-backspace | 16.1 | 16.1 | 0.52 | 0.45 |
| type-char | 16.1 | 16.1 | 0.52 | 0.46 |

Timing spread is material: console-to-telemetry pairs are **1.41 → 2.16**, **1.42 → 1.44**,
and **1.28 → 1.33 ms**; telemetry-to-console pairs are **1.44 → 2.24**, **1.48 → 1.64**,
and **1.35 → 1.52 ms**. Selection samples are control **3.03 / 3.02 / 5.47 ms**, final
**3.07 / 3.24 / 3.17 ms**. The table includes every run; these samples do not isolate a small
instruction-cost difference from machine variation. No fastest sample is selected.

Exact final-source censuses again tie, including the aggregated type histograms: hierarchy-to-sensors
**1,677 objects / 117,240 bytes**, selection **8,621 / 580,816**. The refill-quantized KiB counter and exact
census measure different quantities; the exact counts settle any refill-boundary difference.

| Pair | Build | RSS growth 200–500 MiB | 100–200 | 200–300 | 300–400 | 400–500 |
|---|---|---:|---:|---:|---:|---:|
| 1 | control | 9.84 | 30.47 | 3.28 | 0.94 | 5.62 |
| 1 | candidate | 10.62 | 29.22 | 4.06 | 0.78 | 5.78 |
| 2 | candidate | 10.16 | 29.22 | 3.44 | 0.94 | 5.78 |
| 2 | control | 10.31 | 30.00 | 3.91 | 0.78 | 5.62 |
| 3 | control | 10.16 | 29.38 | 3.91 | 0.78 | 5.47 |
| 3 | candidate | 10.16 | 30.31 | 3.59 | 0.78 | 5.78 |

Cumulative RSS-growth medians from cycles 200–500 are **10.16 → 10.16 MiB**. Window medians are
**30.00 / 3.91 / 0.78 / 5.62** → **29.22 / 3.59 / 0.78 / 5.78 MiB**. Last-window growth is +0.16 MiB,
offset by lower earlier-window growth; cumulative growth ties. These are growth measurements, not absolute
RSS or an absolute baseline to which the windows can be added. No run is retried or discarded.

| Target / scene | Control median / p95 ms | Final median / p95 ms | Control objects | Final objects |
|---|---:|---:|---:|---:|
| Wasm GC / full | 2.20 / 2.80 | 2.10 / 2.90 | 4320 | 4320 |
| Wasm GC / static | 2.10 / 2.90 | 2.10 / 2.90 | 4320 | 4320 |
| Wasm GC / text-heavy | 2.30 / 3.70 | 2.40 / 3.90 | 4320 | 4320 |
| Wasm GC / editing | 2.60 / 3.30 | 2.40 / 3.20 | 8604 | 8604 |
| Wasm 32 / full | 2.10 / 2.60 | 2.10 / 2.70 | — | — |

All GC allocation histograms tie: 120 frames at 36 objects in full/static/text-heavy; editing has
93 frames at 79, 24 at 47, and three at 43. Wasm32 retains **3,840 allocation calls / 132,480 bytes**,
one collection and a largest allocation of 262,160 bytes in every sample. Heap high-water and growth
samples are retained in the aggregate report; these counters do not show additional allocated objects/bytes.

Module SHA-256 pairs (published control → final source):

- `editor`: `2c5e92b5f8d1a9b1c16a08f7535c388f823019be0399c6ed4f314987ad339f7f` → `449a72e3b71dbf5e7809f2442c169dca4146fe38c135fc4cd5ea6ded78fca693`.
- `headless`: `c38e087832eb1da313f504c8f205ac2c0f0e4bba8bffcc23ee1fb6986cdbde35` → `219356e5595e1d0d8b680e7d76af8ec75f1ef97aa59e5158c657c37d7e4dc379`.
- `web32`: `2769d31b4b32bce1dfe011e44dbe8ffa4eead136822fddc0e79f4f366efd01c1` → `abb2cf770beef17eacde22f11f121027c240a76b40c9206ae0e184498b914596`.
- `webgc`: `c1cbfa6c2689805237bbe01002d078b42543a3ac458e75ea62cdfc6155e32c09` → `b62e9e52ea08a8f5a9b0f625783020f0df80a4a63b9ced6216141c306d28bdf6`.

Per-function/section diffs and complete paired/census aggregate reports are archived with the session
measurement records. Individual captures and superseded build artifacts are removed after recording.

## Typed native enum boundaries (2026-11-10, next gated batch) — measurements

Tier 1 passes: **857 compiler tests, 0 failures**, and the compiler builds
itself to a fixed point. All **ten UI scripts pass**, including the framework's
4,000-node layout and native input checks. Full parity passes **526 runtime
fixtures** across the three targets, with 14 recorded skips; UI parity also passes
**60 positive and 702 negative checks**, with inlining off/on. App and
production measurements are recorded before publishing this batch. The production
control remains `fcfd253b` with its archived `style-field` modules.

The size investigation compares the same frozen editor source and development
build mode. The first native-decoder prototype added 983,397 bytes to the editor
module; 774,573 bytes were source/debug records and 208,824 bytes were the rest
of the module. In Wasm code, checked native decoders accounted for
13,796/14,548 bytes and centralized mappings for 7,164/7,414 bytes (Wasm32/GC).
The largest decoders were `Key` and `EventKind`, together about 9.4 KiB per
target. Checked decoders now compact consecutive declared integer codes into
exact range guards; sparse gaps and signed endpoints remain checked. This
reduces the editor by 144,839 bytes relative to that prototype, to 106,223,320
bytes. Of the 838,558-byte increase over the published control, 651,287 bytes
are source/debug records and 187,271 bytes are other module data and code.
The all-target fixture explicitly tests gaps and both signed Int endpoints.


| Development module | Published `fcfd253b` control (bytes) | Final native-boundary source (bytes) | Change |
|---|---:|---:|---:|
| `editor.hl` | 105,384,762 | 106,223,320 | +838,558 |
| `headless.hl` | 106,190,686 | 107,027,151 | +836,465 |
| `web32.wasm` | 12,193,198 | 12,525,154 | +331,956 |
| `webgc.wasm` | 5,956,459 | 6,071,457 | +114,998 |

Wasm32's increase splits into 138,959 code bytes, 93,929 GC-root metadata
bytes, 66,827 patch metadata bytes, 18,501 data bytes and 13,740 remaining
section bytes. Its largest named code increases are `__std_string.final`
(10,308 bytes), `$enum-dynamic-equal` (5,124), `TextField.buildField` (3,520)
and `__dynamic_equal` (3,085). The enum equality family adds 7,386 bytes.
After compaction, native decoders occupy 2,349/3,099 bytes and mappings
7,164/7,414 bytes (Wasm32/GC). The compact guards remove 11,459/11,461 bytes
from the prototype Web modules. The new non-inline boundary mappings share
one method per mapping; the six existing small policy mappings retain inlining.
Wasm GC's largest individual additions are `__std_string` (11,014 bytes),
`__haxeon_value_type_name` (3,717), `$value-dynamic-equal` (3,248) and the
central accessibility-role mapping (2,183). The enum equality family adds
7,386 bytes there too. The remaining growth includes nominal enum descriptors,
reflection/escape adapters and existing UI functions affected by the new types.
These figures include the whole unpublished conversion batch, not only the FFI
emitter change. No module is byte-identical, so the runtime comparisons are
required.

Module SHA-256 values (control → candidate):

- `editor.hl`: `449a72e3b71dbf5e7809f2442c169dca4146fe38c135fc4cd5ea6ded78fca693` → `0fc46714fa47a955170ef7d2ff87b7dbedf135bae0cfc33ff76fdc2ebcb089d8`.
- `headless.hl`: `219356e5595e1d0d8b680e7d76af8ec75f1ef97aa59e5158c657c37d7e4dc379` → `535c276692aedc1c629f0dfcda666b480c48d2b889bfa542044ec15f6e23e1dc`.
- `web32.wasm`: `abb2cf770beef17eacde22f11f121027c240a76b40c9206ae0e184498b914596` → `aba8b0043cadb4a89d1679667f4d3d7e35c2b6bc164bfa0029a56d17ad232be8`.
- `webgc.wasm`: `b62e9e52ea08a8f5a9b0f625783020f0df80a4a63b9ced6216141c306d28bdf6` → `980909be70cafc540dcf2659fbf32dabb75ab1882a35b0fae08fa7329e56265d`.

The final batch uses three alternating control/candidate pairs, with both the
shared measurement and heavy-build locks held. All six budget runs and all six
headless memory runs pass. Medians below use the same frozen outer source and
checkout-built VM; captures are deleted after extracting their results.

| Editor action | Control KiB | Candidate KiB | Control frame ms | Candidate frame ms |
|---|---:|---:|---:|---:|
| hierarchy->sensors | 111.0 | 111.2 | 1.81 | 1.76 |
| sensors->hierarchy | 78.3 | 78.3 | 1.36 | 1.35 |
| console->telemetry | 71.0 | 73.0 | 1.2 | 1.17 |
| telemetry->console | 89.4 | 89.4 | 1.25 | 1.24 |
| scroll-inspector | 21.7 | 21.7 | 0.79 | 0.73 |
| hover-enter | 0.5 | 0.5 | 0.0 | 0.0 |
| hover-inside | 0.5 | 0.5 | 0.0 | 0.0 |
| idle | 0.3 | 0.3 | 0.01 | 0.01 |
| idle-focused | 0.3 | 0.3 | 0.01 | 0.01 |
| hover-other | 9.9 | 9.9 | 0.48 | 0.45 |
| hover-field | 12.3 | 10.8 | 0.49 | 0.46 |
| hover-away | 13.6 | 13.5 | 0.48 | 0.44 |
| type-char | 16.1 | 16.1 | 0.46 | 0.43 |
| type-backspace | 16.1 | 16.1 | 0.46 | 0.42 |
| selection | — | — | 2.7 | 2.71 |

Selection-stress does not expose a per-action KiB median in the budget report;
its exact action census is recorded separately. The +0.2/+2.0 KiB movements in
hierarchy-to-sensors and console-to-telemetry are checked against the exact
object/byte census below rather than accepted from the quantized counter alone.

Headless median RSS growth after warmup (frame 200→500) is 9.84→10.00 MiB. The four consecutive window-growth medians are `[30.0, 3.44, 0.94, 5.62]`→`[29.84, 3.59, 0.94, 5.62]` MiB. All memory/leak checks pass.

Paired RSS window-growth runs (MiB), in execution order:

| Pair | Side | Four windows | Post-warmup growth |
|---|---|---|---:|
| 1 | control | `[29.69, 3.28, 0.94, 5.47]` | 9.69 |
| 1 | candidate | `[29.84, 3.91, 0.94, 5.62]` | 10.47 |
| 2 | candidate | `[29.53, 3.59, 0.78, 5.62]` | 10.0 |
| 2 | control | `[30.0, 3.59, 1.09, 5.62]` | 10.31 |
| 3 | control | `[30.0, 3.44, 0.78, 5.62]` | 9.84 |
| 3 | candidate | `[29.84, 3.28, 0.94, 5.62]` | 9.84 |

Browser comparisons use three alternating pairs per scene, 120 warmup and 120
measured frames, under both shared locks. Guest SHA-256 is asserted on every
run, including when switching the module in a shared host artifact directory.
All 30 runs complete; no browser timeout is treated as a pass.

| Target / scene | Control median / p95 ms | Candidate median / p95 ms | Allocations over 120 frames |
|---|---:|---:|---|
| Wasm GC / full | 2.00 / 2.50 | 2.10 / 2.70 | 4,320 → 4,320 objects |
| Wasm GC / static | 1.90 / 2.30 | 1.80 / 2.30 | 4,320 → 4,320 objects |
| Wasm GC / text-heavy | 1.90 / 2.40 | 1.90 / 2.40 | 4,320 → 4,320 objects |
| Wasm GC / editing | 2.10 / 2.60 | 2.20 / 2.70 | 8,604 → 8,604 objects |
| Wasm32 / full | 2.20 / 2.50 | 2.20 / 3.10 | See linear allocator counts below |

Wasm32's measured allocator counts are identical in every pair: **3,840 calls,
132,480 requested bytes** per 120 frames. Heap high-water (572,040 bytes),
measured heap growth (10,464 bytes) and one collection also match. Browser timing
medians stay within 0.1 ms of control; Wasm32's median p95 rises 2.50→3.10 ms
with the median frame unchanged at 2.20 ms. This tail movement is recorded, not
hidden by retrying; it does not accompany additional allocations or heap growth.

Exact action windows compare the published control's existing every-byte census
module against the current calibrated module. The candidate subtracts its one
calibration object before comparison; control totals are exact per-type counters
and do not use sampled stack weights. Both use the second occurrence after
warmup, ending before timeline serialization.

| Exact action window | Control objects / bytes | Candidate objects / bytes | Change |
|---|---:|---:|---:|
| hierarchy→sensors | 1,677 / 117,240 | 1,676 / 117,208 | −1 / −32 |
| console→telemetry | 1,178 / 78,584 | 1,176 / 78,520 | −2 / −64 |
| selection | 8,621 / 580,816 | 8,593 / 579,512 | −28 / −1,304 |

`TextStyleOverride` shrinks from 112 to 96 bytes: one, two and fifty instances
in the three windows respectively. Integer boxes decrease by one, two and
twenty-eight. Selection also saves 40 bytes across five `TabItem` objects and
16 bytes across two `TextField` objects. One 32-byte closure environment changes
its semantic signature from nullable Int to IconName without changing its size.
No other type total changes. Thus the upward KiB-counter movements are buffer
refill granularity, not more allocated program objects or bytes.

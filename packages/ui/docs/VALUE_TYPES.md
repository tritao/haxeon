# UI value types

This records the value conversions in stage 0 of [ADR 0002](../../../docs/adr/0002-reactive-ui-model.md), including typed
style storage and transitions.

**Measurement correction:** The later Wasm GC paired runs through the erased-boundary change swapped the build-source
`nativekit_ui_showcase_wasm_gc.wasm`, but the browser loads `nativekit_ui_haxeon_guest.wasm`. Those runs measured the
candidate guest on both sides, so their claimed paired comparisons were invalid. HashLink pairs and standalone Wasm
censuses were unaffected. Identical guest hashes remain valid evidence of identical generated code. The boundary and
literal-cache comparisons below were rerun by swapping the browser-loaded guest itself.

A 2026-11-05 audit found the same filename error in the word-access and rejected minimum-first growth helpers.
Their originally reported paired scene counts are invalid; the HashLink measurements, standalone Wasm allocation
tests and word-access microbenchmarks are unaffected. The growth trial remains rejected on its measured HashLink RSS
regression. The word-access scene comparison below has been replaced with runs that swap the browser-loaded guest and record
SHA-256 checks before and after every capture.

`Rect`, `Insets`, `Color`, `LayoutAxis` and `Transform2D` are immutable structs declared with `implements Hashable`. Their fields are final;
replace the whole value to change one. Their `==` and `!=` comparisons use the declared conformance. Optional values use `Null<T>`,
including inline optional fields; absent and present remain distinct. `LayoutStyle` owns these values inline in one
object. Render and style caches use compiler-generated `Diff.fingerprint` snapshots, so their field lists stay aligned
with `Diff.mask`.

The data-record conversion also made `TextStyle` and `ParagraphStyle` immutable `Hashable` structs, with whole-value
replacement helpers. `LayoutNode` keeps them in one lazy `LayoutTextStyles` holder only when text styling is present;
ordinary nodes retain a single pointer instead of carrying both optional struct payloads inline. This keeps the node
smaller and allocates one holder rather than separate text and paragraph objects. `DockTextWidthKey` and `Shortcut` are
`Hashable` structs; `EffectParameter` and `CustomEffectDefinition` are `Equatable`; `InkOverflow` is `Hashable`.
`PointerLocation` is an immutable struct in a flat array keyed by pointer ID. `TextRangeRect` is an immutable struct
in a specialized map, and text geometry caches are created only when populated. On Wasm GC, dispatcher setup and the
first pointer move allocate 78 objects with the class representation and 76 with the flat array. After setup, 1,024
pointer moves allocate 1,024 objects with the class representation and zero with the struct representation. A paired
30-cycle HashLink selection census measured medians of 342,111 allocations for the class control and 342,095 for the
flat-array version. The instrumented Wasm GC Showcase full, static and text-heavy scenarios remain at 5,896 objects
over 120 frames; editing falls from 12,835 to 12,622.

The 30-cycle HashLink action medians (KiB) for the actions that changed from the starting baseline are:

| Action | Class baseline | Flat storage |
| --- | ---: | ---: |
| hierarchy to sensors | 114.6 | 112.6 |
| sensors to hierarchy | 80.1 | 78.1 |
| backspace | 16.6 | 16.2 |

The other measured action allocations did not increase. Nine alternating 500-cycle HashLink runs measured identical control and candidate RSS window medians: [30.00, 3.59,
0.78, 5.00] MiB.

The app's mutable `CncPresentation` and `HobbingTelemetry` snapshots are `Diffable` structs. Their values are owned by
their containing models, and no caller depends on a stable object identity.

`LayoutStyle` remains a mutable `Diffable` class with identity equality. Classes cannot declare `Equatable` or
`Hashable`; neither an explicit `equals` method nor a native comparison hook changes class/interface `==`. Content
comparisons use `Diff.mask`, while render and style caches use `Diff.fingerprint` snapshot values. The local-style
cache compares snapshots with `Diff.mask(a, b) == 0`, so distinct equal copies still share a cache entry. The measured struct version boxed 25,625 values
(8,474,960 bytes) as `@haxeon.ui.LayoutStyle`, plus 2,823 optional boxes (948,528 bytes), during selection stress.
The class version kept its 10,165 objects (3,496,760 bytes) and lowered tab-transition allocations. In the class
version, `LayoutNode` uses 120 bytes per node (5,906 nodes, 708,720 bytes); the inline text-style prototype enlarged
every node and slightly raised action allocations, so the two style values now share the lazy holder.

The native layout interface uses an output buffer for resolved geometry. The session reuses that buffer and holds on to
immutable results when their fields have not changed. This keeps the C ABI explicit and avoids rebuilding geometry that
is already available. The other values continue to cross the native boundary through the existing scalar encoder.

Inlining values enlarges their holders. The conversion also removes unnecessary repeated holder creation: retained
docking panes and clean inspector alternatives reuse their trees, and property controls reuse private style templates.
The inspector cache is bounded, and changed transient editor state is discarded on a selection change as before.
Retained alternatives have separate state scopes, validate dependencies and topology, and rearm their self-updating
children before reuse. Verification continues to compare retained trees to fresh builds.

Declarations, computed styles and transitions retain their known value kinds. Computed styles share immutable typed
declarations until modified, and typed equality and interpolation keep structs out of Dynamic. Inspection, dumps and
reflection materialize dynamic values when requested. This replaces the temporary inline-axis and cached snapshot
boxing paths. The textual tree dump skips unused inspection entries and rule provenance while preserving copy hooks and
their failures; public inspection snapshots still expose values to reflection.

Struct boxes can still occur at real dynamic and reflective boundaries. For example, inspecting a dynamic style value
materializes a box; a type census should distinguish `@`-prefixed struct boxes from the former class allocations. The
compiler scalarizes supported direct and typed calls, optional locals and inline field copies; unsupported or escaping
values retain the normal boxed ABI. See [STRUCTS.md](../../../docs/STRUCTS.md) for the calling conventions and attribution.
The same-machine 30-cycle HashLink census starts after the initial editor frame and includes scenario setup. It counts
allocations by type. Entries after conversion are
struct boxes (`@haxeon.ui.*`) if a dynamic boundary is exercised. The per-action KiB and Wasm GC Showcase comparisons are in
[STRUCTS.md](../../../docs/STRUCTS.md).

The Wasm GC Showcase counts in that comparison instrument generated `struct.new` and `array.new` operations. The compiler
flag `--wasm-gc-allocation-count` and CMake option `NKUI_HAXEON_WASM_GC_ALLOCATION_COUNT` are disabled by default; with
the option off, the guest has no counter global, instructions or export. The benchmark wrapper enables the option when
it rebuilds a Wasm GC artifact and reports `memory.wasm_gc_objects` and `memory.wasm_gc_objects_per_frame` for measured
frames after warmup. From `packages/ui`, rebuild and collect the 120-frame comparison in one command:

```sh
NKUI_HAXEON_TARGET=wasm-gc NATIVEKIT_WEB_BENCHMARK_BUILD=1 \
NATIVEKIT_WEB_BENCHMARK_WARMUP=120 NATIVEKIT_WEB_BENCHMARK_FRAMES=120 \
./tools/benchmark-web-haxeon.sh
```

The wrapper also supplies NativeKit's `web_smoke` helper path to Python. To build the instrumented Showcase guest without
running a benchmark, use `NKUI_HAXEON_TARGET=wasm-gc NKUI_HAXEON_WASM_GC_ALLOCATION_COUNT=ON ./tools/build-web.sh`.

| Scenario | Rect | Insets | Color | LayoutAxis | Transform2D |
| --- | ---: | ---: | ---: | ---: | ---: |
| Interaction, classes → current | 7,511 → 0 | 70 → 0 | 487 → 0 | 1,007 → 0 | 1,722 → 0 |
| Tab matrix, classes → current | 12,586 → 0 | 8 → 0 | 1,185 → 0 | 4,956 → 0 | 351 → 0 |
| Selection stress, classes → current | 4,307 → 0 | 512 → 0 | 866 → 0 | 5,364 → 0 | 456 → 0 |

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
see [ADR 0002](../../../docs/adr/0002-reactive-ui-model.md) for the measured sites and totals. The editor budget
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

### Interface-view unbox result ABI (2026-11-05)

The compiler now gives generated interface-unbox helpers the existing scalar
and reference result ABI. The interface conversion still creates its required
escape box; reading an existing interface view as its concrete struct creates
no further box. Inlining on and off gives the same allocation census:

| Target | Casts | Control objects | Candidate objects |
| --- | ---: | ---: | ---: |
| HashLink | 8 / 1,024 | 0 / 0 | 0 / 0 |
| Wasm32 | 8 / 1,024 | 8 / 1,024 | 0 / 0 |
| Wasm GC | 8 / 1,024 | 8 / 1,024 | 0 / 0 |

The fixture carries both scalar and managed-reference leaves across collection.
The full compiler suite passed 751 tests, self-hosting reached a fixed point,
and parity checked 489 fixtures across the three backends (14 existing skips).
Wasm32 browser smoke passed.

The control and candidate Wasm GC Showcase guests are byte-identical
(SHA-256 `07f1dca2f16bc8a6b0765a77aac4ce4ab3c2cde0b63a55f70c37905ab835ddc0`).
Nine alternating full-scene pairs and three pairs for each other scene, in
fixed-step core mode with 120 warmup and 120 measured frames, completed without
a timeout:

| Scene | Control objects | Candidate objects |
| --- | ---: | ---: |
| full | 4,440 | 4,440 |
| static | 4,440 | 4,440 |
| text-heavy | 4,440 | 4,440 |
| editing | 8,724 | 8,724 |

These counts belong to this host configuration and source cohort; compare the
paired control and candidate rather than totals from earlier configurations.

The HashLink editor profile guests are also byte-identical (SHA-256
`429ced0f773a09bd949deb13083fcc9c8d12550236fb9c7ce62b788b352cedd4`).
All 18 captures in nine alternating pairs reported these per-action allocation
counts (KiB); no budget ceiling changed:

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

Three 30-cycle selection census pairs counted 340,912 / 340,909 / 340,912
objects in control and 340,910 / 340,912 / 340,910 in candidate. Total bytes
were 24,011,168 / 24,010,440 / 24,011,096 and
24,010,664 / 24,011,208 / 24,010,696 respectively. Only byte-buffer counts
varied; every other per-type object and byte count matched within each pair.
These are same-binary measurements, including capture formatting variation.
The app suite, all ten UI scripts and all nine retention scenarios passed.

All six 500-cycle headless memory gates passed. The four RSS growth windows
(MiB), preserving pair order, were:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.47 / 3.44 / 0.78 / 5.00 | 29.38 / 3.91 / 0.62 / 5.00 |
| 2 | 29.38 / 4.22 / 0.78 / 5.00 | 30.78 / 3.28 / 0.78 / 4.84 |
| 3 | 30.47 / 3.59 / 0.78 / 4.84 | 30.31 / 4.06 / 0.78 / 4.84 |

Median paired differences were −0.16 / +0.47 / 0 / 0 MiB. The first window
ranged from 29.38 to 30.78 MiB across these identical-module runs, illustrating
RSS variability separately from program allocation. No run was discarded or
repeated to obtain a passing result, and no ceiling was raised.

### Struct equality through Dynamic array views

The initial review-5 array-view reproduction exited 1 with control `72a5ac4b`
on HashLink, Wasm32 and Wasm GC: an `Array<Dynamic>` alias missed a value
accepted by the struct's custom `equals`. The extended fixture exits 26 with
control `efd3a87d` on all three targets, first exposing that a mutating
handwritten `equals` can change the caller's struct values. Owned value copies
fix that boundary; dispatching boxed structs to their declared equality fixes
the array view. The candidate exits 42. Reflection-exposed structs use the same dispatch;
nonconforming structs do not acquire box identity. A shape-erased generic owner
can recover an array without any explicit struct-to-Dynamic conversion: the
conformance belongs to the registered concrete type. Nullable fields, colliding
nominal hashes and equality that shrinks or replaces array elements are covered.
The duplicate native Dynamic-array search/remove implementations have been
removed; the portable IR search owns equality and revalidates the removal index.

The fixture compares existing Dynamic boxes, mutable value snapshots and
interface views in both directions, and searches typed lane elements, at
8 and 1,024 iterations with inlining enabled and disabled. Managed reference
leaves are preserved in each case. HashLink reports
zero allocated bytes during both loops; Wasm32 and Wasm GC allocation counters
report zero objects. The interpreter also checks boxed equality and an
incremental layout edits, conformance removal and conformance restoration. The compiler suite passes
752 tests with zero failures, self-hosting reaches a fixed point, and the
parity suite checks 490 fixtures across all three targets (14 existing skips).

The Wasm GC Showcase comparison uses the same host for alternating control and
candidate guests, with `NKUI_HAXEON_MEMORY_STATS=OFF`, allocation counting enabled
and fixed-step core mode (120 warmup and 120 measured frames). All nine full-scene
pairs and three pairs per other scene matched exactly:

| Scene | Control objects | Candidate objects |
| --- | ---: | ---: |
| full | 4,440 | 4,440 |
| static | 4,440 | 4,440 |
| text-heavy | 4,440 | 4,440 |
| editing | 8,724 | 8,724 |

These totals describe this host/build configuration; compare the paired guests
within it rather than substituting totals from a different host configuration.
The Wasm32 Showcase also builds and passes browser smoke with WebGL2.

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

### Generated callback dependencies and the UI snapshot gate (2026-11-05)

The UI snapshot fixture exposed a missing Wasm GC varargs adapter for
`Canvas -> Void`. Historical source checks identify `ac5c2f79` as the first
bad commit; its parent `9e4819ae` passes. The defect predates the scoped-cleanup
ports, the type-ID collision fix and the interface-unbox ABI change. Generated
scalar escape bodies introduced callback casts after the original adapter scan.
The lowering now processes generated bodies and their adapter dependencies to
completion before reserving signatures and table slots. Wasm32 reuses the same
varargs helper instead of generating a duplicate.

The ten existing UI scripts exercise HashLink, and the Showcase builds a
different reachable graph. The omitted `test-value-snapshot-parity.sh` is now
part of `scripts/test-wasm-gc-parity.sh`. The full parity gate passed 491 fixtures
(14 existing skips), followed by all six UI snapshot combinations: HashLink,
Wasm32 and Wasm GC, with inlining on and off. The reduced callback regression
also passes all six combinations. It crosses genuine Dynamic/variadic escapes;
existing typed closure allocation censuses remain at zero. The compiler suite
passed 753 tests and self-hosting reached a fixed point. All ten UI scripts,
the app suite, all nine retention scenarios, browser smoke, performance budgets
and six headless memory runs passed.

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


### Key-path merge and field-mask port (2026-11-05)

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


### Nested scalar callbacks at HashLink Dynamic boundaries (2026-11-05)

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


### Negative array insertion indices on Wasm (2026-11-05)

The shared-lane mixed-operation test exposed an existing mismatch in ordinary
arrays: both Wasm targets clamped every negative insertion index to zero, while
HashLink and struct arrays first counted from the end. For `[10,20,30]`, inserting
42 at −1 must produce `[10,20,42,30]`. Both Wasm concrete insertion helpers now
add the length before clamping to the valid range. This changes no scalar generic
specialization policy. The reduced regression covers Int, Float, Bool, String,
class references, Int64 and an Array<Dynamic> view, including empty arrays,
extreme indices and both inline settings. Control returned 42 on HashLink and 1
on both Wasm targets; candidate returned 42 on all six target/inline combinations.
The broader mixed lane test also passes on both Wasm targets with this fix alone.

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


### One structural runtime for lane arrays (2026-11-05)

The common `IrValueLaneRuntime` defines 13 verified SSA functions over 16 storage
primitives. Both Wasm backends link those functions; HashLink uses generated C
from the same definition. The three handwritten structural policies are deleted
together. The primitives own storage, barriers and exception-safe lane replacement;
the common code owns bounds, growth selection, validity, overlap direction and
length publication. A CMake freshness check and a compiler unit check prevent the
checked-in C artifact from drifting from its source. This commit preserves the
existing capacity geometry; the decided uniform capacity policy follows in its
own measured commit.

The mixed-operation fixture covers packed 3-byte scalar structs, reference fields,
optional nested fields, nullable elements, holes, sparse growth, iteration, copies,
aliasing, reverse, slice, concat and splice against an ordinary-array model. It
runs on all three targets with inline 0 and 1. Warm typed reads and reversals
allocate zero bytes on HashLink and zero objects on both Wasm targets for both
8 and 1,024 iterations. The production-linked Wasm32 storage test additionally
checks both cleared reference slots, scalar bytes and validity under GC stress.

Wasm GC fixed-step core measurements (120 warmup / 120 measured frames), nine
alternating full-scene pairs and three pairs for each other scene, matched in
every pair:

| Scene | Control objects | Candidate objects |
| --- | ---: | ---: |
| full | 4,440 | 4,440 |
| static | 4,440 | 4,440 |
| text-heavy | 4,440 | 4,440 |
| editing | 8,724 | 8,724 |

Guest SHA-256: control
`6221ae673935fd1d280f7b371c1dcffb0c172a070e8e6162b82c131ffe00bf06`, candidate
`edd093e31f00ed8bd9123b79441a24a4c7281139c51b19d363ac88c60f335b3d`.
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

### Uniform array growth: factor-2 trial (not accepted)

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

### Checkout VM launcher integration

After merging `hl-exit-crash`, the VM and profiler come from the checkout CMake
build through `scripts/hl` and `scripts/hlprof-live`; the compiler suite uses
`scripts/test-driver.sh 16` with private copies of its loaded VM and runtime.
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

### Wasm GC scalar words and range operations

Control is Haxeon `c47a067c`; the capacity policy is unchanged. Typed scalar accesses are specialized before nullable erasure, while their element and field layouts are still available. Accessors retain only array/index/value parameters; stride, field offset, width, signedness and bitmap presence are compile-time facts. Aligned full fields use direct word loads/stores; packed fields use masked word spans. A shared span kernel handles a crossing field and unaligned range words without a staging allocation.

The backend caches each lane cast. Unknown native layouts use bounded word fragments, preserving native validation and exception behavior. Physical ranges use overlap-safe `array.copy`, `array.fill` for complete clears, and byte helpers only at unaligned ends. The common reverse policy tests bitmap presence outside its loop. Native builds use the committed generated C header; the compiler unit verifies drift and deterministic generation. A native build with the Haxe tool directory hidden passed. Dynamic concat consults the shared compatibility primitive and the shared concat guard.

The new `struct-array-word-access.hx` fixture passes on HashLink, Wasm32 and Wasm GC with both inlining settings. Reads, writes and reversal allocate zero guest objects for 8 and 1,024 prepared elements. Existing low-level tests retain 32/64-bit words, unaligned spans, forwarding, lazy references, bitmap boundaries and exception checks. Synthetic native arrays with deliberately arbitrary layouts are untyped; the typed layout checks still enforce the exact element representation.

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

### Minimum-first-capacity growth trial (not accepted)

The single follow-up trial used `max(required, capacity + capacity / 2, minFirst)`, with
`minFirst = max(4, floor(32 / max(1, elementBytes)))`, on ordinary and struct-lane arrays on all three targets.
Explicit construction and resize allocations were exact; resize retained capacity when the new length fitted.
Empty HashLink storage was shared only where no metadata owner needed pinning. Wasm GC empty backings were
shared lazily by storage type, so unused storage types allocated nothing. `ComputedStyle` indexed stores used
implicit growth instead of repeated explicit resize. No other growth variant was measured.

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

### Values have equality; objects have identity (2026-11-05)

Classes now reject `Equatable` and `Hashable` with “use a struct for value equality”. Class and interface `==`
compares instance identity, including interface views of boxed values; converting a boxed value to `Dynamic` still
uses its concrete value conformance. Explicit class `equals` methods remain ordinary methods. Generic value-capability
bounds reject class and interface arguments. The public `haxeon.Identity` API and its native glue were deleted;
the compiler lowers typed reference equality directly and prevents a foreign `__compare` hook from changing it.

`LayoutStyle` remains a mutable `Diffable` class, preserving its aliasing and measured object layout. Its style-cache
snapshots compare through `Diff.mask(a, b) == 0`, with a regression check that distinct equal copies share one cache
entry. Synthesis still requires field conformance: a struct containing class references can explicitly choose identity
in its `equals` implementation. No new class conformance, identity hash, or cache ownership mechanism was added.

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

### IR bytecode optimization merge (2026-11-05)

The reviewed `bytecode-opt` branch was merged after the value/object equality change. It adds dead pure-value
elimination, receiver-check elision, linear jump threading, shared SSA non-null facts for HashLink/Wasm lowering,
and field-load forwarding across clean control flow. The equality intrinsic remains pure and no old identity API
was restored. The HashLink pin, VM library and native runtime are unchanged.

This is the first wall-clock comparison of the combined passes on the current buildable editor: equality-model
control `238c54eb`, detached outer `51947204d`, with no MachineKit source correction copied in. Both images use
the same app sources and VM `d1eb6136`. The previous corrected-snapshot opcode counts in
[BYTECODE_OPPORTUNITIES.md](../../../docs/BYTECODE_OPPORTUNITIES.md) remain historical; they are not the timing baseline.
The current HashLink modules measure 112,538,876 bytes before and 103,141,814 after (9,397,062 bytes / 8.35% smaller).

Nine alternating control/candidate action pairs use the same fixed affinity on four physical performance cores
(CPUs 0, 2, 4, 6), matching the passing equality-model budget comparison. The CPU set was fixed before any capture;
there were no selection changes or retries. Frame-time medians are milliseconds and allocation medians KiB.
The selection action has no frame allocation counter; its exact census is below.

| Scenario/action | Control ms | Candidate ms | Control KiB | Candidate KiB |
| --- | ---: | ---: | ---: | ---: |
| tab-matrix: console->telemetry | 1.11 | 1.09 | 74.5 | 74.5 |
| tab-matrix: hierarchy->sensors | 1.58 | 1.57 | 114.6 | 114.6 |
| tab-matrix: sensors->hierarchy | 1.22 | 1.21 | 80.1 | 80.1 |
| tab-matrix: telemetry->console | 1.16 | 1.15 | 92.9 | 92.9 |
| interaction: hover-away | 0.42 | 0.42 | 13.6 | 13.6 |
| interaction: hover-enter | 0.00 | 0.00 | 0.5 | 0.5 |
| interaction: hover-field | 0.43 | 0.43 | 12.4 | 12.4 |
| interaction: hover-inside | 0.00 | 0.00 | 0.5 | 0.5 |
| interaction: hover-other | 0.42 | 0.41 | 10.0 | 10.0 |
| interaction: idle | 0.01 | 0.01 | 0.2 | 0.2 |
| interaction: idle-focused | 0.01 | 0.01 | 0.2 | 0.2 |
| interaction: scroll-inspector | 0.71 | 0.71 | 21.2 | 21.2 |
| interaction: type-backspace | 0.42 | 0.41 | 16.2 | 16.2 |
| interaction: type-char | 0.42 | 0.41 | 16.1 | 16.1 |
| selection-stress: selection | 3.02 | 2.92 | — | — |

Selection improves by 0.10 ms (3.3%); tab transitions improve by 0.01–0.02 ms, with the remaining changes at
0.00–0.01 ms. These are small runtime improvements despite the larger static bytecode reduction. Every action
allocation median is unchanged, so no allocation ceiling was lowered or raised. Every one of the 18 action captures
passed, as did the single planned final budget run and all nine retention scenarios.

Three unrestricted selection-stress censuses (30 cycles) match every named type at 305,725 objects / 21,593,528
bytes. Only the raw runtime `bytes` bucket varies. Full raw totals are:

| Pair | Control objects / bytes | Candidate objects / bytes |
| --- | --- | --- |
| 1 | 340,911 / 24,011,016 | 340,908 / 24,010,344 |
| 2 | 340,909 / 24,010,496 | 340,910 / 24,010,912 |
| 3 | 340,911 / 24,010,968 | 340,912 / 24,011,320 |

Three unrestricted paired headless runs use the previous memory protocol. RSS window growth in MiB:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.47 / 4.06 / 0.78 / 5.00 | 30.31 / 3.59 / 0.78 / 4.84 |
| 2 | 30.00 / 3.91 / 0.78 / 5.00 | 30.31 / 3.28 / 0.78 / 4.84 |
| 3 | 30.31 / 3.75 / 0.78 / 5.00 | 30.16 / 3.91 / 0.78 / 4.84 |

Median paired deltas are -0.15 / -0.47 / 0.00 / -0.16 MiB. All six headless memory runs pass; every median window
ties or improves against control. No allocation median increased. No budget, verification behavior or memory
threshold changed.

Wasm GC uses the committed guest-selection/hash check: control starts `4f892cc3b546`, candidate `e81a925cba8f`.
All 18 alternating scene pairs completed with 120 warmup and 120 measured frames: nine full, three each static,
text-heavy and editing. Both images count 4,440 objects for every full/static/text-heavy sample and 8,724 for editing.
The runner verifies the actual browser-loaded guest hash before and after every capture.

All full gates passed: 772 compiler tests, self-hosting fixed point, ten UI scripts, 502 parity fixtures (14 existing
skips), all six UI value snapshots, the app suite, all nine retention scenarios, performance budgets and paired
headless memory, and Wasm32/Wasm GC WebGL2 browser smoke tests. The comparison uses frozen bytecode/libraries; raw
captures were deleted once their numbers were extracted. No measurement was retried to obtain a pass.


### Inline enum layout and word-access checkpoint (2026-11-06)

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


### Nullable argument/result ABI checkpoint (2026-11-06)

The compiler now preserves the scalar ABI namespace when nullable primitive arguments are expanded into presence and
payload components. A direct factory or forwarding function returning a struct no longer loses its scalar-result
contract and fails verification with `A scalar stack reference cannot escape its call`. The verifier is unchanged.
The regression fixture exercises scalar-only and managed-reference results on HashLink, Wasm32 and Wasm GC, with
inlining on and off. Managed cases explicitly export and require their setup function and reject a null owner.
Every 8/1,024-call census is zero; HashLink uses the exact object census. This composes existing lowering passes and
does not implement the deferred scalar generic specialization stage.

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

### Binary-size merge and native build policy (2026-11-06)

The reviewed `binary-size` series is merged at `b34b0754`. The paired control is `98465674`; both editor modules use
outer source `b75441f801f4d8cbd3704a59ad57a049e216cdf4`, isolated from unrelated uncommitted work. Project controls
explicitly set `HAXEON_COMPILER_SOURCE` to the archived control source and use the corresponding old CLI. Artifact
variables alone do not select the compiler for ordinary project builds. A first misconfigured comparison selected
current source twice and is withdrawn; the tables below are the complete replacement fixed schedule. The already-passed
standalone candidate budget and retention gates were not retried.

The initial merge accidentally coupled development metadata to native `Debug` optimization. Its app gate failed with
`Worker gallery tests failed: The gallery costs 10.7 ms of CPU per tick, over the limit of 5 ms`.
Module metadata policy now travels separately from the native build profile. Both development and release retain the
previous optimized native `Release` configuration; the corrected app suite passes at 1.8 ms per gallery tick. An
end-to-end tiny CMake fixture checks native configuration and emitted metadata in default/development/release modes.
No budget or limit was changed.

Changing a prebuilt compiler through the Web build environment also left CMake's guest current: the selected compiler
was absent from its command and dependencies. The build now configures that choice explicitly and depends on the
selected module. The integration check rebuilds real Wasm32 and Wasm GC guests after compiler-path and file updates,
checks byte identity for an identical compiler copy, and restores the original configuration. The initial stale-guest
comparison is withdrawn. The replacement browser schedule verifies each actually loaded guest hash.

| Artifact | Control bytes | Candidate bytes |
| --- | ---: | ---: |
| Editor HashLink, development | 104,683,583 | 97,644,103 |
| Showcase Wasm32, development | 30,017,042 | 11,867,682 |
| Showcase Wasm GC, allocation counter enabled | 5,802,490 | 5,802,490 |

The HashLink reduction is compact line-table encoding; default development metadata stays enabled. The Wasm32 reduction
is reachable closure adapters. The Wasm GC guests are byte-identical. Editor control SHA-256 is
`55dbef2eed544de5e4efc61ac5f8da2e66f30fa331bb8374f374d126673aec73`; development candidate is
`5c0cabd84bf30bd947ab57901ef21e17e6658e11a7389bbd41dd9bd71330ae70`.
VM library SHA-256 is `db26c9e28722fd8a080d11f2c397a09f79f818615a8763b5b49c51f0683714eb` and runtime is
`aeeb5a1bacd90f01db883c459762bec00914a461cc884effefd173fb4bdbdb29`, identical across the pair.

Nine alternating editor pairs, affinity `0,2,4,6`, median action results:

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
| --- | ---: | ---: | ---: | ---: |
| console->telemetry | 72.5 | 72.5 | 1.10 | 1.10 |
| hierarchy->sensors | 112.6 | 112.6 | 1.56 | 1.57 |
| sensors->hierarchy | 80.1 | 80.1 | 1.21 | 1.21 |
| telemetry->console | 92.9 | 92.9 | 1.15 | 1.15 |
| hover-away | 13.6 | 13.6 | 0.42 | 0.42 |
| hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-field | 12.4 | 12.4 | 0.43 | 0.42 |
| hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-other | 10.0 | 10.0 | 0.41 | 0.41 |
| idle | 0.2 | 0.2 | 0.01 | 0.01 |
| idle-focused | 0.2 | 0.2 | 0.01 | 0.01 |
| scroll-inspector | 21.2 | 21.2 | 0.70 | 0.71 |
| type-backspace | 16.1 | 16.1 | 0.41 | 0.41 |
| type-char | 16.1 | 16.1 | 0.41 | 0.42 |
| selection | — | — | 2.95 | 2.94 |

Selection-stress reports no action KiB median. Three exact 30-cycle census pairs, objects / bytes:

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,908 / 24,010,240 | 340,907 / 24,010,000 |
| 2 | 340,910 / 24,010,840 | 340,910 / 24,010,928 |
| 3 | 340,910 / 24,010,816 | 340,910 / 24,010,928 |

Every type other than raw `bytes` matches in all three pairs: 305,725 objects / 21,593,528 bytes.
The remaining raw-byte differences are recorded without claiming a new allocation-site attribution.

Headless RSS growth windows, MiB, control → candidate; all six runs pass:

| Pair | First window | Retained window | Primitives window | Tab-inspector window |
| --- | ---: | ---: | ---: | ---: |
| 1 | 30.31 → 30.00 | 3.91 → 3.44 | 0.62 → 0.78 | 4.84 → 6.41 |
| 2 | 30.62 → 29.53 | 3.28 → 4.06 | 0.94 → 0.78 | 4.84 → 4.84 |
| 3 | 30.31 → 29.53 | 3.75 → 4.22 | 0.78 → 0.78 | 4.69 → 5.00 |

Separate-version medians are 30.31 / 3.75 / 0.78 / 4.84 → 29.53 / 4.06 / 0.78 / 5.00 MiB;
median paired differences are −0.78 / +0.47 / 0.00 / +0.31 MiB. The positive windows are reported explicitly.
The withdrawn comparison used exactly the same candidate bytes twice, so its RSS samples remain a zero-change
calibration only: 29.84–30.47 / 3.44–4.06 / 0.78–0.78 / 4.84–5.00 MiB. The later separate-version medians fall within
that variation; one candidate tab-inspector window is 6.41 MiB and is retained in the table. There is no extra renderer
or value-box allocation in the exact census. No ceiling was raised and no passing sample was selected by retry.

Informational load/RSS capture: one control development, one candidate development, then one candidate release run;
`noop`, one cycle, 1 Hz sampling, allocation sampling disabled, warm filesystem. The runtime's `Load bytecode` plus
`Compile and link the module (JIT, native libraries)` phases are read from the native Perfetto export of each HLPC
capture; the lightweight JSON export omits these startup phases. The existing first capture was re-exported, not rerun.
All three modules share the same optimized native libraries. These single-run timings are not a speedup estimate or gate.

| Mode | Module bytes | Bytecode load ms | JIT/native link ms | Sum ms | Peak RSS MiB | First-frame RSS MiB | Final RSS MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| control-development | 104,683,583 | 158.12 | 1261.81 | 1419.93 | 319.43 | 312.80 | 312.80 |
| development | 97,644,103 | 143.48 | 1258.51 | 1401.98 | 321.04 | 311.71 | 313.59 |
| release | 25,841,618 | 104.74 | 1273.79 | 1378.53 | 315.18 | 315.18 | 315.18 |

Release is selected explicitly with `--build-mode release`; its SHA-256 is
`bc2645d2cc77af9277ad6ef82a38ddb00b14f6abbdc7c6545e751695fdd7e537`.
The smaller file and lower sampled peak do not imply a lower first-frame or final RSS in this single run.

Wasm GC uses nine full-scene and three each static/text-heavy/editing pairs, 120 warmup and 120 measured frames.
Every sample matches at 4,440 / 4,440 / 4,440 / 8,724 objects. Both loaded guests have SHA-256
`ff3dc27e5acfde09528c2b1ac52b10d7a2bd739086be1d2b719a67ab061d91c9`. The full-scene startup medians are:

| Target / pairs | Guest fetch ms | Compile ms | Instantiate ms | Initialize ms | First frame ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasm-gc/full / 9 | 8.5 → 9.5 | 5.3 → 5.2 | 6.6 → 6.5 | 15.5 → 13.8 | 147.4 → 146.7 |
| wasm32/full / 3 | 34.6 → 14.4 | 12.4 → 4.9 | 3.4 → 2.6 | 11.4 → 11.2 | 174.1 → 129.3 |

Wasm32 source/control guest is SHA-256 `1d013e7996e93d0cec01975f506d2e98b847ed180bffdcdcee3d43bb166c7be3`;
candidate is `5645df810a815c6f74594718d41222cb692fec8cec478e46a0ea4647ff63a4b6`.
Its smaller transfer and compile load follow the adapter reduction. The Wasm32 browser runner does not expose the
Wasm GC object counter; no object-count result is claimed for it.

Gates pass: 775 compiler tests, self-hosting fixed point, all ten UI scripts, all three binary-size integration tests,
502 cross-target parity fixtures (14 existing skips), all six UI value snapshots, the app suite, all nine retention
scenarios, the first scheduled standalone editor budget check and all paired headless windows. Wasm32 and Wasm GC
build/browser smokes and both real compiler-dependency checks pass. No profiler hang occurred in the informational
capture; its missing JSON startup rows were an export-format selection error. All raw captures are removed after their
numbers are extracted; the idle outer gate checkout and historical audit source archive are removed.

## Float32 enum payload words

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

## Tracking writes after viewport frame preparation

Outer `97a56618c` adopts the viewport frame annotations, explicit owner preparation and presentation tests. Every hunk
in the six requested files was reviewed and included; its app suite passed without the guard. The stricter guard is
compared against Haxeon `3d9c9361` on that same outer snapshot. The control pins compiler, stdlib **and UI sources**;
an initial compiler-only control setup was stopped before measurements because it would use the candidate libraries.
Native runtime and VM binaries are identical between the valid control and candidate.

A failed framework check exposed a remaining tracked write: `Cannot write Observable field coalescingAllowed inside
a reactive tracking scope`. External selection imports now defer their history group break to resolution, alongside
history clears. Local selection updates remain immediate. The focused regression verifies a later edit stays in a
separate undo group; the final framework and app gates pass with the strict guard intact.

Nine alternating pairs give these action medians (KiB are the existing refill-quantized counter):

| Action | Control → guard KiB | Control → guard ms |
| --- | ---: | ---: |
| console->telemetry | 74.5 → 74.5 | 1.1 → 1.1 |
| hierarchy->sensors | 112.6 → 112.6 | 1.56 → 1.56 |
| sensors->hierarchy | 80.1 → 80.1 | 1.21 → 1.21 |
| telemetry->console | 92.9 → 92.9 | 1.16 → 1.15 |
| hover-away | 13.6 → 13.6 | 0.42 → 0.42 |
| hover-enter | 0.5 → 0.5 | 0 → 0 |
| hover-field | 12.4 → 12.4 | 0.43 → 0.43 |
| hover-inside | 0.5 → 0.5 | 0 → 0 |
| hover-other | 10 → 10 | 0.42 → 0.42 |
| idle | 0.2 → 0.2 | 0.01 → 0.01 |
| idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| scroll-inspector | 21.2 → 21.2 | 0.72 → 0.71 |
| type-backspace | 16.1 → 16.2 | 0.42 → 0.41 |
| type-char | 16.1 → 16.1 | 0.42 → 0.42 |

Backspace's sampled 0.1 KiB increase is not accepted as evidence of increased program allocation. Temporary
instrumentation restricted the exact census to the same input-and-submit window, stopping before harness JSON output.
One 30-cycle capture per version/action discards its first cold action and gives these 29-action totals:

| Exact action window | Before outer adoption (`8ab5cb995`) | Adopted control | Guard |
| --- | ---: | ---: | ---: |
| type-backspace | 12,450 objects / 485,424 B | 12,450 / 485,424 | 12,450 / 485,424 |
| console → telemetry | 33,464 objects / 2,202,712 B | 33,464 / 2,202,712 | 33,464 / 2,202,712 |
| telemetry → console | not separately captured | 50,463 objects / 2,741,448 B | 50,463 / 2,741,448 |

Every allocation type total matches within each comparison. The first tab-action pair also matches all sampled stack
groups after normalizing source line numbers and generated source-body hashes. Individual windows can place a buffer
growth in different cycles; the cumulative action totals match. The console → telemetry counter reads 74.5 KiB in both
current builds, versus 72.5 at the preceding checkpoint, but the pre-adoption exact census is equal too. These findings
are consistent with refill granularity, rather than an added object or requested byte. The original nine-pair observations
remain recorded; no budget ceiling or budget tooling changed. Temporary source instrumentation is removed.

Selection census, three alternating pairs (objects / bytes):

| Pair | Control | Guard |
| --- | ---: | ---: |
| 1 | 340,910 / 24,010,856 | 340,910 / 24,010,880 |
| 2 | 340,910 / 24,010,880 | 340,910 / 24,010,872 |
| 3 | 340,908 / 24,010,320 | 340,911 / 24,011,168 |

All non-byte counts and sizes match; only raw byte buffers vary. Paired headless RSS growth in MiB, all windows:

| Pair | Control | Guard |
| --- | --- | --- |
| 1 | 29.53 / 3.75 / 0.78 / 4.84 | 30.31 / 3.44 / 0.78 / 5 |
| 2 | 30 / 4.06 / 0.78 / 4.84 | 30.47 / 3.91 / 0.78 / 4.84 |
| 3 | 30.31 / 3.75 / 0.78 / 4.84 | 30.16 / 3.91 / 0.94 / 4.84 |

All pass. Paired median changes are +0.47 / −0.15 / 0 / 0 MiB; the separate window medians are
30.00 / 3.75 / 0.78 / 4.84 → 30.31 / 3.91 / 0.78 / 4.84 MiB. Positive samples are recorded without retries.
The guard adds no creation stamp to an Observable object. It reuses one per-thread identity log, clears scoped
references on normal and exceptional exit, and releases transient worker entries. Fresh-scope construction allocates
exactly the same Observable objects as untracked construction: HashLink allocated bytes match, and Wasm32/Wasm GC
count exactly 8 / 1,024 objects for 8 / 1,024 calls with either inlining mode. Existing effect/capture zero-allocation
censuses remain green. The owner/worker isolation test is now in the parity list for all targets and both modes.

Wasm GC's nine full-scene and three each static/text-heavy/editing pairs all match at 4,440 / 4,440 / 4,440 / 8,724
objects, with the browser-loaded guest hash checked on every capture. Both Web targets build and pass browser smoke;
three Wasm32 full-scene load pairs also complete. No timeout occurred.

Final gates pass: 776 compiler tests, self-hosting fixed point, all ten UI scripts, 503 parity fixtures (14 existing
skips), six refreshed UI snapshots, app suite, all nine retention scenarios, the first scheduled standalone budget
check, and all paired headless windows. The final source is fingerprinted before measurements; the pre-fix retention
build is excluded. Raw captures and diagnostic builds are removed once their results are recorded, and the idle outer
gate checkout is removed.

## Enum payload reference and case helpers (2026-11-06)

Control: `f91fec13`; candidate: the payload-helper checkpoint following it. Both use outer
`12cf449ce`, the same checkout VM and native runtime, and development build mode. The rebuilt
editor performance module is byte-for-byte identical (`bde021f673ad7487eac986ef4b1a6f958258c0c971d5ac317eee03ffc0e38c2a`),
as are the Showcase guests: Wasm GC `af15b2d50ec8d6b85677741df51fc11d25df6dfc9a642bb52813d154484f99bf`,
Wasm32 `b256f2dd09ebe595618ba75eecdf44a61597e069b2750ccea54ecea43fb9d77a`.
This checkpoint does not activate source enum storage; these comparisons verify that adding
the physical helpers and verifier rules leaves existing emitted programs unchanged.

Nine alternating pairs, medians (control → candidate):

| Action | KiB | Frame ms |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 74.5 → 74.5 | 1.12 → 1.13 |
| tab-matrix/hierarchy->sensors | 112.6 → 112.6 | 1.61 → 1.62 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.24 → 1.24 |
| tab-matrix/telemetry->console | 92.9 → 93.1 | 1.18 → 1.19 |
| interaction/hover-away | 13.6 → 13.6 | 0.43 → 0.49 |
| interaction/hover-enter | 0.5 → 0.5 | 0.0 → 0.0 |
| interaction/hover-field | 12.4 → 12.4 | 0.44 → 0.49 |
| interaction/hover-inside | 0.5 → 0.5 | 0.0 → 0.0 |
| interaction/hover-other | 10.0 → 10.0 | 0.42 → 0.48 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.72 → 0.8 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | — | 3.01 → 3.18 |

The quantized counter's telemetry→console +0.2 KiB is not an allocation change in the program:
exactly the same module and libraries ran on both sides. Timing also varied with machine load.
Preserve the scheduled pair-8 candidate failure: `selection-stress selection: frameMs 6.01 is over
the budget 6.0`. Selection medians in the first five pairs were 2.93–3.19 ms; later control samples
reached 4.16–5.29 ms and candidates 3.18–6.01 ms. No pair was retried or discarded. The separate,
already-scheduled budget gate passed (selection 4.5 ms); its retention checks passed all nine scenarios.

Selection-stress exact census, 30 cycles (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,909 / 24,010,760 | 340,908 / 24,010,560 |
| 2 | 340,911 / 24,011,224 | 340,909 / 24,010,760 |
| 3 | 340,910 / 24,011,008 | 340,910 / 24,011,048 |

Every pair has identical non-byte-buffer types: 305,725 objects / 21,593,528 bytes. Only raw byte
buffers vary. All three headless memory runs passed, with the following RSS window growth in MiB
(cycles 100–200 / 200–300 / 300–400 / 400–500):

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 29.53 / 4.22 / 0.62 / 5.0 | 30.0 / 4.06 / 0.78 / 5.0 |
| 2 | 29.22 / 4.22 / 0.78 / 5.0 | 29.53 / 4.38 / 0.78 / 5.0 |
| 3 | 29.84 / 4.22 / 0.78 / 4.84 | 30.94 / 3.75 / 0.78 / 4.84 |

Paired median RSS deltas are +0.47 / −0.16 / 0 / 0 MiB. The positive first-window observation is retained;
the identical executable and library bytes rule out an implementation memory increase between
these executions. Nothing was retried to obtain a lower window.

All 36 Wasm GC scene runs completed: full/static/text-heavy 4,440 → 4,440 objects; editing
8,724 → 8,724. Three Wasm32 startup pairs and both browser smokes also completed.
The compiler suite passed 782 tests, self-hosting reached a fixed point, all ten UI scripts
passed, and parity passed 503 fixtures (14 skips) plus six UI value snapshots. The app suite
passed in the detached outer checkout. Its first attempt mixed the old runner with the newer
shared checkout's two-line fingerprint protocol and failed with `Project fingerprint has an invalid result`;
setting `MATERIA_INSTALL_ROOT` to the frozen checkout corrected that setup mismatch without a product edit.

The new native fixtures exercise mixed case construction/projection, nested and optional payloads,
managed reference rooting, pointer/type transport, and carrier lane arrays on HashLink, Wasm32 and Wasm GC,
with inlining enabled and disabled. At 8 / 1,024 calls, mixed cases allocate exactly the explicitly
created Source objects; warmed carrier-array access and scalar handle transport allocate zero.
Twenty-two negative verifier checks cover carrier escapes, forged lane helpers and invalid scalar
word transport. These are private payload proofs; source generic enum metadata, logical container
and closure descriptors, escape adapters and source enum activation remain unfinished.

## Reachable lane runtime operations (2026-11-06)

An unused enum case such as `Items(values:Array<Pair>)` describes lane storage without making its
allocation or mutation operations reachable. At `e7d8716e`, the reduced monomorphic enum failed to
build on Wasm32 with `Unknown Wasm function "$lane-runtime:ensure"`. Adding an ordinary
`Array<Dynamic>.push` reproduced the corresponding Wasm GC failure:
`Unknown Wasm function "$lane-storage:new-like"`.

Wasm32 now registers only reachable lane natives, including the allocator used by retyping.
Wasm GC's Dynamic array paths check whether the lane policy was actually linked, independently
of whether the type plan contains a lane wrapper. This keeps logical type descriptors available
without emitting calls into an absent runtime. It adds no runtime fields or allocations.

The `enum-unused-lane-payload` fixture covers iteration, reads/writes, growth, copies, slices,
concat, reverse, splice and resize of ordinary Dynamic arrays alongside the unused lane payload.
It passes on HashLink, Wasm32 and Wasm GC with both inlining modes. This is a compiler runtime
reachability fix, required before concrete generic enum payload metadata exposes more such types;
it does not activate source inline enums.

Control: `e7d8716e`; both editor builds use outer `368cc15ea`, development mode, and the same
checkout VM and native runtime. Their emitted modules are byte-identical:
`bb2358c5c376cd70ef047d2665411c7af7414b0ca4bd7653aa083282b46c1267`.
Nine alternating editor pairs, medians (control → candidate):

| Action | KiB | Frame ms |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 72.5 → 72.5 | 1.2 → 1.23 |
| tab-matrix/hierarchy->sensors | 112.8 → 112.8 | 1.72 → 1.77 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.34 → 1.35 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.25 → 1.27 |
| interaction/hover-away | 13.6 → 13.6 | 0.44 → 0.44 |
| interaction/hover-enter | 0.5 → 0.5 | 0.0 → 0.0 |
| interaction/hover-field | 12.4 → 12.4 | 0.45 → 0.44 |
| interaction/hover-inside | 0.5 → 0.5 | 0.0 → 0.0 |
| interaction/hover-other | 10.0 → 10.0 | 0.44 → 0.43 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.75 → 0.72 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | — | 3.38 → 3.28 |

All scheduled pair checks pass. Per-action allocation medians match; individual quantized counter
samples vary even with identical executable bytes. No pair was retried or discarded.
Selection-stress exact census, 30 cycles (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,911 / 24,011,088 | 340,910 / 24,010,800 |
| 2 | 340,912 / 24,011,336 | 340,910 / 24,010,816 |
| 3 | 340,909 / 24,010,632 | 340,911 / 24,011,144 |

Every non-byte-buffer type matches in every pair: 305,725 objects / 21,593,528 bytes. Only raw
byte buffers vary. All paired RSS windows pass (MiB; cycles 100–200 / 200–300 / 300–400 / 400–500):

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.16 / 3.75 / 0.78 / 5.0 | 30.0 / 3.75 / 0.78 / 5.0 |
| 2 | 30.47 / 3.44 / 0.78 / 4.84 | 30.47 / 3.59 / 0.62 / 5.0 |
| 3 | 30.16 / 4.22 / 0.78 / 5.0 | 29.69 / 4.38 / 0.62 / 4.84 |

Paired median RSS deltas are −0.16 / +0.15 / −0.16 / 0 MiB. The positive observations are retained;
the unchanged module and libraries provide the control for process/allocator variation.

| Guest | Control bytes | Candidate bytes |
| --- | ---: | ---: |
| Wasm GC | 5,810,159 | 5,810,159 |
| Wasm32 | 11,888,319 | 11,876,162 |

The Wasm GC guest remains byte-identical (`af15b2d50ec8d6b85677741df51fc11d25df6dfc9a642bb52813d154484f99bf`).
Wasm32 removes 12,157 bytes of unused helpers; the new guest is
`65f4388a9d61671876a9093e898f6924895b20a902e1211be62a6312e605aa7a`.
All 36 Wasm GC scene runs complete: full/static/text-heavy 4,440 → 4,440 objects; editing
8,724 → 8,724. Three Wasm32 startup pairs also complete. Informational full-scene startup medians:

| Guest | Compile ms | Init ms | First frame ms |
| --- | ---: | ---: | ---: |
| wasm-gc | 5.8 → 6.2 | 18.5 → 16.5 | 164.4 → 175.8 |
| wasm32 | 5.9 → 6.0 | 15.5 → 14.6 | 182.6 → 166.0 |

These timing observations are not used to infer a code cost from the identical Wasm GC guest.
Final gates pass: 783 compiler tests with `scripts/test-driver.sh 16`, self-hosting fixed point,
ten UI suites, 504 parity fixtures (14 existing skips), six UI value snapshots, app suite,
all nine retention scenarios, the standalone editor budget check, paired headless memory
checks and both browser smokes. All scheduled measurement pairs pass.

The initial overlapping self-hosting seed ended with `Terminated` and
`FAIL: the compiler sources do not build under the Haxe interpreter`. The system's `earlyoom`
log identifies SIGTERM to Haxe PID 1705268 (3,406 MiB RSS) at 12:59:02, with available memory
below 10%. The final-source run, after the large concurrent builds finished, passed both stages
and the fixed-point check. Subsequent heavy jobs ran sequentially; parity used four compilation
jobs without changing its cases, while the compiler suite retained 16 jobs. No system memory
threshold, verification rule or budget ceiling changed. Raw captures were deleted after extraction,
finished caches were pruned before the next Web build, and the idle gate checkout is removed
after recording this commit.


### Complete dependencies requested by generated enum methods (2026-11-06)

A handwritten enum equality method can construct a specialized owner whose methods request hashing,
key paths and captured closures. On `430f68f7`, the regression fails IR verification with
`Unknown or mismatched IR object "$generic:$owner:LateBox[constrained]<class:Key<>>"`.
Typing source bodies and each helper category once leaves declarations requested by later bodies unfinished.
Owners, closures, key paths, codecs, reflection adapters, equality and hashing now complete together to a
fixed point; the native type descriptor snapshot is taken afterward. This fixes the dependency ordering
without weakening verification. Source inline enum activation remains a subsequent step.

The regression runs on HashLink, Wasm32 and Wasm GC with inlining off and on. The interpreter test also
checks cold, cached and edited builds. Final-source compiler validation passes 785 tests with zero failures,
self-hosting reaches a fixed point, all ten UI suites pass, parity checks 505 fixtures with 14 existing skips,
and the six UI value snapshots pass. The frozen outer checkout is `3e5757d80`; the compiler control is
`430f68f7`. Its application sources match the preceding frozen measurement checkout; only the submodule pin differs.
The app suite and all nine retention scenarios pass.

The freshly built HashLink profile module is byte-identical to the control: 99,536,585 bytes,
SHA-256 `bb2358c5c376cd70ef047d2665411c7af7414b0ca4bd7653aa083282b46c1267`.
The VM and runtime library bytes are unchanged. Nine alternating control/candidate pairs give these medians:

| Action | Control KiB | Candidate KiB | Control ms | Candidate ms |
| --- | ---: | ---: | ---: | ---: |
| tab-matrix/console→telemetry | 72.5 | 74.5 | 1.16 | 1.12 |
| tab-matrix/hierarchy→sensors | 112.6 | 113.0 | 1.66 | 1.61 |
| tab-matrix/sensors→hierarchy | 80.1 | 80.1 | 1.27 | 1.24 |
| tab-matrix/telemetry→console | 92.9 | 92.9 | 1.21 | 1.17 |
| interaction/hover-away | 13.6 | 13.6 | 0.43 | 0.43 |
| interaction/hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| interaction/hover-field | 12.4 | 12.4 | 0.44 | 0.43 |
| interaction/hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| interaction/hover-other | 10.0 | 10.0 | 0.42 | 0.42 |
| interaction/idle | 0.2 | 0.2 | 0.01 | 0.01 |
| interaction/idle-focused | 0.2 | 0.2 | 0.01 | 0.01 |
| interaction/scroll-inspector | 21.2 | 21.2 | 0.72 | 0.72 |
| interaction/type-backspace | 16.2 | 16.2 | 0.42 | 0.41 |
| interaction/type-char | 16.1 | 16.1 | 0.42 | 0.42 |
| selection-stress/selection | — | — | 3.06 | 3.08 |

All 18 action runs and the separately scheduled standalone budget gate pass. The +2.0 KiB
console→telemetry and +0.4 KiB hierarchy→sensors medians are observations of the same binary,
not increases in program allocation. A separate diagnostic uses census mode to disable the
refill fast path and measure exact bytes. Three alternating pairs, 100 cycles each, give identical
median bytes for all four tab actions in every run (99 steady frames per action):

| Action | Control bytes | Candidate bytes |
| --- | ---: | ---: |
| hierarchy→sensors | 115,136 | 115,136 |
| sensors→hierarchy | 81,384 | 81,384 |
| console→telemetry | 75,800 | 75,800 |
| telemetry→console | 94,520 | 94,520 |

This directly checks the refill-counter explanation rather than discarding the original KiB results.
No budget tooling or ceiling changed. Timings from the identical uninstrumented binary are observations
of machine variation, not a compiler speedup.

Three selection-stress census pairs, 30 cycles each (objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,908 / 24,010,224 | 340,911 / 24,011,080 |
| 2 | 340,910 / 24,010,744 | 340,910 / 24,010,800 |
| 3 | 340,911 / 24,011,008 | 340,909 / 24,010,544 |

Every type other than raw `bytes` matches exactly in each pair: 305,725 objects / 21,593,528 bytes.
The raw-buffer differences above do not establish a program allocation increase.

Paired 500-cycle RSS windows in MiB:

| Pair | Control windows | Candidate windows |
| --- | --- | --- |
| 1 | 30.16 / 4.06 / 0.78 / 5.47 | 29.84 / 4.06 / 0.62 / 5.00 |
| 2 | 29.69 / 4.22 / 0.78 / 4.69 | 29.53 / 3.91 / 0.78 / 5.00 |
| 3 | 30.62 / 3.44 / 0.78 / 4.84 | 29.84 / 4.22 / 0.78 / 4.84 |

All six memory gates pass. The paired median window differences are −0.32 / 0 / 0 / 0 MiB;
the same-binary variation does not establish a memory improvement.

An initial diagnostic suite was cancelled because `TMPDIR` was unset: `LspProtocolMain` placed its
workspace fixture inside the checkout and discovered the checkout's ancestor `.hxml` files, spending
time recovering compiler syntax. Its result was not accepted. The complete final-source suite above
uses the dedicated disk scratch directory. Heavy gates run sequentially; completed parity, test-main
and self-hosting build trees were removed before the editor build, whose disk preflight showed 7.7 GiB free.

Both Showcase guests build and pass their browser smokes. Their sizes are unchanged:

| Target | Control bytes | Candidate bytes |
| --- | ---: | ---: |
| Wasm GC | 5,810,159 | 5,810,159 |
| Wasm32 | 11,876,162 | 11,876,162 |

The Wasm guests are not byte-identical. The Wasm GC change is confined to 47 bytes in the type
section: 27 function-signature entries are permuted, with the same multiset of types. Struct and array
type definitions are unchanged, and none of the changed type indices is used by a function declaration.
Every other section, including executable code, matches. Control/candidate SHA-256:

- Wasm GC: `af15b2d50ec8d6b85677741df51fc11d25df6dfc9a642bb52813d154484f99bf` /
  `fa645ffd3c9ff6c57168d24902c4d4897e343475e93c59cc5aedaf6eb4659e8e`.
- Wasm32: `65f4388a9d61671876a9093e898f6924895b20a902e1211be62a6312e605aa7a` /
  `f263ce0d8feaf514e0369f32b7147093959f882417fcb3918111467ea37a7c4f`.

All 36 Wasm GC runs complete: nine alternating full-scene pairs and three pairs each for static,
text-heavy and editing. Counts are equal in every pair; load and frame timings below are observations,
not a claim of a compiler speedup. Three Wasm32 load pairs also complete. Full-scene startup medians, ms:

| Target | Compile control → candidate | Init control → candidate | First frame control → candidate |
| --- | ---: | ---: | ---: |
| wasm-gc | 6.0 → 6.6 | 19.3 → 17.5 | 167.8 → 168.4 |
| wasm32 | 5.9 → 6.1 | 15.9 → 16.0 | 158.6 → 155.9 |

Scene object counts and medians of per-run frame measurements, ms:

| Scene | Control → candidate objects | Median frame control → candidate | p95 frame control → candidate |
| --- | ---: | ---: | ---: |
| wasm-gc/full | 4440 → 4440 | 2.30 → 2.20 | 4.70 → 4.70 |
| wasm-gc/static | 4440 → 4440 | 2.30 → 2.50 | 4.40 → 4.60 |
| wasm-gc/text-heavy | 4440 → 4440 | 2.30 → 2.60 | 4.40 → 5.00 |
| wasm-gc/editing | 8724 → 8724 | 2.60 → 2.60 | 5.00 → 5.00 |
| wasm32/full | not counted → not counted | 2.50 → 2.40 | 4.90 → 4.90 |

The three-pair static and text-heavy frame medians are 0.20 and 0.30 ms higher respectively; these
observations are retained rather than rerun away. They do not establish a speedup or a causal timing cost
for this dependency-order change. All scheduled comparisons and required gates pass. No budget ceiling,
verification rule or immutable value changed. Raw captures were deleted after extraction; only the current
comparison artifacts and measurement records are retained until the commit is recorded, then the idle
gate checkout is removed.


### Self-hosting body-typing follow-up (2026-11-06)

The `36bc1497` review asked whether the combined completion loop repeatedly generates enough helper bodies
to regress typing time. Three alternating pairs compare `430f68f7` and `36bc1497` compiler modules, both
bootstrapped by the pinned Haxe and running on the same checkout-built VM. Each compiles the identical
archived `36bc1497` compiler and stdlib: 640 source files, a fresh process per run, affinity `0,2,4,6`.
The restored enum-metadata edits are outside this frozen workload and are not part of either measured compiler.

The driver's `bodies=` metric is `ProgramTyper.metrics.bodiesMs`, ending immediately before
`advanceAll(BodyTyped)` and including the helper completion loop. Ordinary class bodies are typed earlier
in `metadata=`, which is shown too; `bodies=` alone is not total source-body typing time.

| Pair | Bodies control → candidate ms | Metadata control → candidate ms | Typing/lowering control → candidate ms |
| --- | ---: | ---: | ---: |
| 1 | 51.63 → 52.58 | 5127.41 → 5451.24 | 10463.85 → 10806.72 |
| 2 | 52.26 → 51.10 | 5401.67 → 5004.34 | 10755.05 → 10223.61 |
| 3 | 56.93 → 53.91 | 5196.06 → 5503.34 | 10724.87 → 11354.68 |

Body medians are 52.26 → 52.58 ms, with paired differences +0.95 / −1.16 / −3.02 ms; the paired
median difference is −1.16 ms. These overlapping observations do not demonstrate a measurable body-typing
increase. Metadata medians are 5,196.06 → 5,451.24 ms; total typing/lowering medians are
10,724.87 → 10,806.72 ms. Those observations are retained without a speedup claim.

Body-phase allocation medians are 31,196,448 → 31,371,160 bytes and 1,099,259 → 1,102,464 objects,
with no body-phase collection in any run. The extra registrations and completion bookkeeping are visible
in these compiler allocations; this is separate from editor action allocations. All six compiles emit
identical 33,973,526-byte modules, SHA-256
`9b3c65eaabef5abfc9c0f6842529fc591778f3f5222780a5ba00c477f537408c`.
No generator-cursor change is justified by this timing sample. It does not establish that whole-request
regeneration is cheap for every codec-heavy input; a measurable case should switch the generators to
consume newly queued requests rather than weaken completion or repeat benchmarks until a pass.


For the concrete enum-metadata candidate, a separate comparison compiles a frozen post-inference-fix
643-file compiler/stdlib snapshot with `36bc1497` and the candidate. The same affinity, VM and alternating
order apply. An earlier candidate run failed with `Null access` before timing completed: preliminary
empty-array inference had requested an enum's physical storage without an instance. The reduced case is
an empty array filled by `push` from an enum pattern. Inference now asks for semantic parameter types,
and physical storage lookup requires its enum instance. The failure and original stack were retained;
its incomplete comparison is excluded from the following replacement experiment on the corrected source.

| Pair | Bodies control → candidate ms | Metadata control → candidate ms | Typing/lowering control → candidate ms |
| --- | ---: | ---: | ---: |
| 1 | 60.16 → 61.48 | 6027.51 → 4927.66 | 11512.28 → 9986.22 |
| 2 | 58.89 → 61.25 | 5157.90 → 4969.28 | 10520.36 → 10040.73 |
| 3 | 68.11 → 91.04 | 5407.51 → 5867.55 | 10815.50 → 11330.32 |

Body medians are 60.16 → 61.48 ms, with paired differences +1.32 / +2.36 / +22.93 ms.
The final-run rise is retained. The sample does not isolate repeated generator typing from new metadata
work or run variation. Body allocation medians are 31,444,928 → 32,698,584 bytes and
1,105,370 → 1,142,637 objects, with no body-phase collection. All six compiles emit the same
34,040,156-byte module, SHA-256 `93bf18542ad2648b5e84641d888f5a4fa687de2786e531d833d5513c48be616e`.

### Concrete enum payload metadata checkpoint (2026-11-06)

This is metadata preparation for source inline enums, not activation of inline enum storage. The compiler retains every
case of a closed generic enum, including constructors that do not mention its parameter, and carries the recursion
decision through canonical IR. Generic factories and owners whose bodies create these enums retain the semantic
argument. Recursive generic payloads still use the existing boxed erased transport at this checkpoint.

Control compiler: `36bc1497`; candidate: this concrete-metadata change. The isolated outer checkout is `b1b31835f`.
Outer main acquired committed machinekit changes since the previous checkpoint, so the control profile was rebuilt
with archived `36bc1497` compiler source against the same 3,335-file input as the candidate. Comparing the previous
99,536,585-byte profile directly would confound those outer changes with this compiler change. The native VM and
runtime libraries are byte-identical in both sides. All captures are on disk and deleted after their numbers are saved.

HashLink: nine alternating action pairs, three selection census pairs and three 500-cycle RSS pairs. Action timing
uses affinity `0,2,4,6`. Allocation medians are unchanged except the quantized hierarchy-to-sensors counter:

| Action | KiB control → candidate | Frame ms control → candidate |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 72.5 → 72.5 | 1.35 → 1.68 |
| tab-matrix/hierarchy->sensors | 112.8 → 112.6 | 1.96 → 2.45 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.58 → 1.93 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.44 → 1.75 |
| interaction/hover-away | 13.6 → 13.6 | 0.49 → 0.60 |
| interaction/hover-enter | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-field | 12.4 → 12.4 | 0.49 → 0.68 |
| interaction/hover-inside | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-other | 10.0 → 10.0 | 0.49 → 0.70 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.02 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.77 → 0.92 |
| interaction/type-backspace | 16.2 → 16.2 | 0.44 → 0.50 |
| interaction/type-char | 16.1 → 16.1 | 0.45 → 0.50 |
| selection-stress/selection | not reported | 3.63 → 3.81 |

The 0.2 KiB counter decrease is not claimed as a permanent allocation improvement and does not justify lowering a
budget. No action allocation median increased. Two candidate **measurement-mode** runs reported timing overruns:
pair 4: `selection-stress selection: frameMs 7.12 is over the budget 6.0`; pair 5:
`selection-stress selection: frameMs 6.05 is over the budget 6.0`. They are retained, not replaced. The separately
scheduled non-measurement budget gate, including retention, passed. Selection medians are 3.63 → 3.81 ms; control
runs range 2.99–5.46 ms and candidate runs 3.05–7.12 ms. These are timing findings, not evidence of a speedup.

The checkout-built `hldump --hashes` compares 33,811 functions. Twenty differ: async outcome construction/projection,
file-dialog callbacks and call-stack formatting. Selection functions are unchanged. For example, `Promise<Int>.complete`
passes its integer directly into the concrete `Outcome<Int>` constructor instead of emitting `OToDyn`. This comparison
does not establish a cause for the timing variation and does not discard either overrun.

Selection-stress census (30 cycles, objects / bytes):

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,910 / 24,010,792 | 340,912 / 24,011,288 |
| 2 | 340,911 / 24,011,080 | 340,911 / 24,011,072 |
| 3 | 340,912 / 24,011,280 | 340,911 / 24,011,136 |

Every run has exactly 305,725 non-byte objects / 21,593,528 non-byte bytes; total differences are only byte buffers.
Object medians are 340,911 on both sides, with paired median difference zero.

RSS windows, MiB, control → candidate (initial / second / third / final windows):

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.16 / 3.59 / 0.78 / 4.84 | 29.84 / 3.91 / 0.78 / 4.84 |
| 2 | 29.84 / 4.22 / 0.78 / 5.00 | 30.31 / 3.59 / 0.78 / 5.00 |
| 3 | 30.16 / 3.91 / 0.78 / 4.84 | 30.00 / 3.75 / 0.78 / 5.00 |

All six memory runs pass. Paired median differences are −0.16 / −0.16 / 0 / 0 MiB; these observations do not establish
a memory improvement.

Artifact bytes (development mode; no binary-size improvement is attributed to the small differences):

| Module | Control | Candidate |
| --- | ---: | ---: |
| HashLink editor profile | 99,660,361 | 99,659,508 |
| Wasm32 Showcase | 11,876,162 | 11,876,090 |
| Wasm GC Showcase | 5,810,159 | 5,810,183 |

Both Web builds and browser smoke tests pass. Wasm GC uses the committed allocation counter: nine full-scene pairs
and three pairs each for static, text-heavy and editing, 36 runs total. All object counts agree in every pair.
Wasm32 has three load pairs, six runs, without the GC object counter. Medians of per-run frame measurements, ms:

| Target / scene | Objects control → candidate | Median frame control → candidate | p95 frame control → candidate |
| --- | ---: | ---: | ---: |
| wasm-gc/full | 4440 → 4440 | 2.40 → 2.50 | 4.60 → 5.10 |
| wasm-gc/static | 4440 → 4440 | 2.50 → 2.40 | 5.20 → 4.50 |
| wasm-gc/text-heavy | 4440 → 4440 | 2.40 → 2.30 | 4.50 → 4.40 |
| wasm-gc/editing | 8724 → 8724 | 2.60 → 2.70 | 5.00 → 5.40 |
| wasm32/full | not counted | 2.40 → 2.50 | 4.70 → 5.40 |

Full-scene startup medians, ms:

| Target | Compile control → candidate | Init control → candidate | First frame control → candidate |
| --- | ---: | ---: | ---: |
| wasm-gc | 6.2 → 6.2 | 18.3 → 19.4 | 161.9 → 172.0 |
| wasm32 | 5.6 → 6.2 | 14.3 → 16.5 | 160.9 → 170.9 |

The full and editing GC frame medians rise by 0.10 ms; other scene medians, p95s and startup observations are retained
in the tables rather than rerun away. No causal timing improvement or regression is established by this sample.

Required gates: 787 compiler tests, zero failures; self-hosting fixed point; all ten UI scripts; 506 parity fixtures
across all three targets (14 existing skips), including all six UI value snapshots; the app suite; all nine retention
scenarios; the separately scheduled performance budgets; all six headless memory runs; both Web smoke tests. The
concrete-payload and generated-dependency fixtures additionally pass all twelve native target/inlining combinations.
Compiler tests cover canonical IR, cold/cached/edited callers, recursive wrappers, phantom arguments, and semantic
empty-array inference from enum patterns. The self-hosting phase-time follow-up immediately above records both the
fixed-point control comparison and the corrected metadata candidate comparison. No budget ceiling, verification rule
or immutable value changed.

Source inline enum ABI, enum arrays/closures and the UI enum conversions remain subsequent steps; these gates do
not claim they are implemented by the metadata checkpoint.

### Reference cycles do not make enum layouts recursive (2026-11-06)

The semantic classifier and IR planner now follow only value containment: enums, value structs and nullable values.
Array, iterator, map, key-path, closure, managed-class and anonymous-record payloads break the path. The baseline
classified `Tree.Node(Array<Tree>)`, `H.On(H->Void)` and map payloads as recursive/boxed; the candidate classifies them
as finite inline shapes. Direct nullable enum containment stays boxed. No target requires conservative classification
for the tested reference cycles.

`InlineEnumReferenceCycleMain` constructs/copies the actual private case storage for array, closure and map payloads.
Its only retained roots are carrier globals. HashLink forces major collections and reuses garbage slots; Wasm GC forces
V8 collections; Wasm32 enables guest GC stress and asserts the guest collection counter advances during churn. All
three payload kinds survive. HashLink exact census and both Wasm allocation counters report **zero allocations** for
8 and 1,024 copies, on all three targets, with inlining disabled and enabled. Both Haxe evaluation and a HashLink-hosted
compiler run the checks. This tests inline carrier construction/projection and roots; source enum construction remains
on its existing ABI until the separate source-lowering step.

Layout recursion and boxed generic descriptor completion are separate relations over the same finite declaration graph.
Removing reference dependencies from both exposed unbounded requests for `E<T> -> Array<E<Array<T>>>`; a diagnostic-only
overlay stopped after 16 requests. Preserving the existing boxed-transport dependency relation keeps that reduced case
at two schemas, while its value-recursion flag is false and the inline planner accepts its finite layout. This transport
check does not select a boxed inline representation. Concrete cyclic generic transport remains part of source lowering.

Required gates pass: 788 compiler tests, zero failures (rerun after strengthening guest-GC coverage); self-hosting fixed
point; ten UI scripts; 506 cross-target fixtures with 14 existing skips and all six UI snapshots; app; all nine retention
scenarios; the separately scheduled budgets; six headless memory runs; both Web builds and smoke tests. All eighteen
measurement-mode action runs also report no budget failures. No ceiling, verification rule or immutable value changed.

Control: `861c37aa`; frozen outer input: `2425ee7bc` (3,336 files). Both compilers build this same outer input; the
control compiler comes from its archived commit. Intervening outer awake/rendering changes are therefore shared by both
sides. The editor profiles are byte-identical: 99,788,585 bytes, SHA-256
`41ac5670063181aa2811b73c26fb15c7af48054f4f5d884ed1c95e71e78a23dd`. The native VM/runtime libraries are also identical.

Nine alternating action pairs, affinity `0,2,4,6`; medians:

| Action | KiB control → candidate | Frame ms control → candidate |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 72.5 → 72.5 | 1.12 → 1.12 |
| tab-matrix/hierarchy->sensors | 112.8 → 113.0 | 1.60 → 1.61 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.24 → 1.23 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.18 → 1.18 |
| interaction/hover-away | 13.6 → 13.6 | 0.43 → 0.43 |
| interaction/hover-enter | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-field | 12.4 → 10.9 | 0.44 → 0.43 |
| interaction/hover-inside | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-other | 10.0 → 10.0 | 0.43 → 0.42 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.72 → 0.72 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | not reported | 3.00 → 3.05 |

The hierarchy-to-sensors KiB counter moves +0.2 and hover-field moves −1.5 despite identical programs. Three further
alternating 100-cycle, census-enabled tab-action pairs measure exact action-window byte medians (99 steady frames per
action): hierarchy-to-sensors **115,136 → 115,136**, sensors-to-hierarchy **81,384 → 81,384**, console-to-telemetry
**75,800 → 75,800**, telemetry-to-console **94,520 → 94,520**, equal in every run. This establishes no actual tab-action
allocation increase; the counter is quantized by shared buffer refills. The hover-field decrease is not claimed as a
permanent improvement and does not justify lowering a budget. The original runs are retained, not replaced.

Selection-stress census, 30 cycles, objects / bytes:

| Pair | Control | Candidate |
| --- | ---: | ---: |
| 1 | 340,911 / 24,012,464 | 340,910 / 24,012,176 |
| 2 | 340,911 / 24,012,448 | 340,910 / 24,012,152 |
| 3 | 340,910 / 24,012,160 | 340,909 / 24,011,904 |

Every run has exactly 305,725 non-byte objects / 21,594,968 non-byte bytes; only byte buffers vary. Three paired
500-cycle RSS windows, MiB:

| Pair | Control | Candidate |
| --- | --- | --- |
| 1 | 30.31 / 4.06 / 0.78 / 5.00 | 29.53 / 4.22 / 0.78 / 4.84 |
| 2 | 29.84 / 4.06 / 0.78 / 5.00 | 30.00 / 4.06 / 0.78 / 5.00 |
| 3 | 30.47 / 3.75 / 0.78 / 5.00 | 29.69 / 3.75 / 0.62 / 5.00 |

All six memory gates pass; paired median deltas are −0.78 / 0 / 0 / 0 MiB. Identical programs and these observations
do not establish a memory or timing improvement.

Wasm GC: nine full-scene pairs, three pairs each for static, text-heavy and editing, 36 runs; Wasm32: three full-scene
load pairs, six runs. Object counts agree in every GC pair. The guests are byte-identical: Wasm GC 5,810,183 bytes,
Wasm32 11,876,090 bytes. Medians of per-run frame measurements, ms:

| Target / scene | Objects control → candidate | Median frame control → candidate | p95 frame control → candidate |
| --- | ---: | ---: | ---: |
| wasm-gc/full | 4440 → 4440 | 2.20 → 2.20 | 4.50 → 3.80 |
| wasm-gc/static | 4440 → 4440 | 2.00 → 2.00 | 3.70 → 3.60 |
| wasm-gc/text-heavy | 4440 → 4440 | 2.30 → 2.50 | 3.90 → 4.20 |
| wasm-gc/editing | 8724 → 8724 | 2.50 → 2.40 | 4.60 → 4.40 |
| wasm32/full | not counted | 2.20 → 2.20 | 4.00 → 3.60 |

Full-scene startup medians, ms:

| Target | Compile control → candidate | Init control → candidate | First frame control → candidate |
| --- | ---: | ---: | ---: |
| wasm-gc | 5.7 → 5.5 | 16.0 → 17.4 | 158.0 → 160.7 |
| wasm32 | 5.3 → 5.7 | 13.7 → 13.9 | 138.0 → 154.9 |

The text-heavy frame median is 0.20 ms higher; that observation is retained with the others, without attributing a
causal cost to this classification change. Raw captures were deleted immediately after extraction. The finished gate
checkout and obsolete builds are removed at the commit boundary; only the next control artifacts and records remain.

### Logical enum arrays and escape adapters (candidate)

This checkpoint adds the logical-array ABI helpers; source inline enums remain inactive. `Array<E>` and
`Iterator<E>` retain their public enum descriptors while typed access transports private tag/scalar/reference
records. Genuine Dynamic reads box the nominal enum and checked writes unpack it. Native ordinary enum arrays
migrate through validated forwarding headers, preserving aliases. Nullable erasure and closure ABI rewriting
retain the storage association and recursion classification. Source `Null<E>` already has the canonical
null-capable `Enum(E)` IR type. Canonical IR version 15 stores the association explicitly and rejects older
formats; obsolete decoder branches were removed.

The control is Haxeon `61e70087`, on the same machine and frozen outer `595e13687`. Work ran in
`materia-worktrees/haxeon-flat-structs` after the requested checkout move. Both sides use the same app/native
inputs. The rebuilt VM has the same HashLink pin (`d1eb6136`) and compiler/feature settings; initial pairs
retain each side's saved VM/runtime, and the RSS diagnostics also hold the VM image constant. NativeKit remains
pinned at `2654fd08`.

All 790 compiler tests, the self-hosting fixed point, ten UI scripts, 506 parity fixtures (14 existing skips),
six UI value snapshots, app suite, nine retention scenarios, performance budgets, and both Web smoke tests
passed. All eighteen scheduled action captures and all valid RSS captures were within their gates. No ceiling
changed.

The actual three-target array fixtures cover typed copy isolation, array-only reference roots across collection,
null and payload Dynamic round trips, native-array migration/alias writes, and size-scaled
construction/iteration. Reading/writing 8 or 1,024 times allocates zero objects. Constructing and iterating
either 8 or 1,024 elements allocates **four objects** on each target, with inlining disabled and enabled: the
array header, two backing lanes and iterator. There is no per-element enum box. An unrelated optional field
forces Wasm nullable erasure in the fixture. Negative tests reject ordinary array operations on enum lanes,
malformed storage associations and obsolete canonical IR. These are ABI infrastructure tests, not proof that
source enum lowering is complete.

| Artifact | Control bytes | Candidate bytes |
| --- | ---: | ---: |
| Editor, development | 99,871,693 | 99,871,693 |
| Showcase Wasm32 | 11,876,090 | 11,876,090 |
| Showcase Wasm GC | 5,810,183 | 5,810,217 |

The editor modules are byte-identical, SHA-256
`18cbaa8c748b8a6847be502af77eefd1e598721f8a539f3ea10f1555026f462a`; Wasm32 modules are also byte-identical. Wasm
GC adds 34 bytes for the checked retype path.

| Action | KiB control → candidate | ms control → candidate |
| --- | ---: | ---: |
| tab-matrix/console->telemetry | 72.5 → 74.5 | 1.40 → 1.19 |
| tab-matrix/hierarchy->sensors | 112.8 → 112.8 | 1.98 → 1.71 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.55 → 1.31 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.48 → 1.24 |
| interaction/hover-away | 13.6 → 13.6 | 0.56 → 0.56 |
| interaction/hover-enter | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-field | 12.4 → 12.4 | 0.57 → 0.58 |
| interaction/hover-inside | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction/hover-other | 10.0 → 10.0 | 0.55 → 0.56 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.95 → 0.96 |
| interaction/type-backspace | 16.2 → 16.2 | 0.44 → 0.48 |
| interaction/type-char | 16.1 → 16.1 | 0.44 → 0.48 |
| selection-stress/selection | — | 3.58 → 3.54 |

These are medians of nine alternating pairs; timing movements are observations, not a speedup claim for this
infrastructure change. Selection allocation is reported by the separate thirty-cycle census below, rather than
inventing a missing per-action KiB field.

Console→telemetry moves +2.0 KiB in the ordinary counter. Three additional alternating pairs of 100 tab cycles
recorded the following exact steady-frame byte medians in **every** run (99 measured frames per action).

| Action | Exact bytes, control | Exact bytes, candidate |
| --- | ---: | ---: |
| hierarchy->sensors | 115,136 | 115,136 |
| sensors->hierarchy | 81,384 | 81,384 |
| console->telemetry | 75,800 | 75,800 |
| telemetry->console | 94,520 | 94,520 |

With the allocation census enabled, HashLink's shared `GC_TLAB_POLICY` disables buffered allocation in both
native and JIT paths. The ordinary allocator then charges `gc_stats.total_allocated` per allocation, so these
census-mode action windows use exact rounded bytes. Without the census, the same counter charges whole buffer
refills. The +2 KiB movement is counter granularity, not additional program allocation. Census-mode timing is
not compared with ordinary timing.

| Selection census pair | Control objects / bytes | Candidate objects / bytes |
| --- | ---: | ---: |
| 1 | 340,908 / 24,011,632 | 340,909 / 24,011,920 |
| 2 | 340,909 / 24,011,936 | 340,911 / 24,012,400 |
| 3 | 340,910 / 24,012,168 | 340,908 / 24,011,656 |

Every selection run has exactly 305,725 non-byte-buffer allocations and 21,594,968 corresponding bytes. All
total-count differences above are raw byte buffers; they are retained rather than attributed to a particular
site without evidence.

RSS window growth is MiB for cycles 100→200, 200→300, 300→400 and 400→500. The initial paired median differences
are +0.47 / +0.31 / 0.00 / +0.16. Diagnostics hold the rebuilt VM constant, then compare an identical candidate
image under both labels. A final fixed-path set also uses identical capture/preload path strings; these are
distinct diagnostic controls, not replacements for the original results.

| RSS set / pair | Control windows | Candidate windows |
| --- | --- | --- |
| Initial / 1 | 29.84 / 3.75 / 0.78 / 4.84 | 30.31 / 4.06 / 0.78 / 5.00 |
| Initial / 2 | 29.69 / 3.91 / 0.78 / 4.84 | 30.47 / 3.44 / 0.78 / 5.00 |
| Initial / 3 | 30.00 / 3.75 / 0.94 / 5.31 | 29.53 / 4.06 / 0.78 / 5.00 |
| candidate-aa / 1 | 30.47 / 3.75 / 0.78 / 5.00 | 30.00 / 4.06 / 0.78 / 4.69 |
| candidate-aa / 2 | 30.62 / 3.44 / 0.62 / 5.00 | 30.31 / 3.59 / 0.78 / 4.84 |
| candidate-aa / 3 | 30.78 / 3.44 / 0.94 / 4.84 | 29.84 / 4.06 / 0.78 / 5.00 |
| common-vm / 1 | 29.69 / 4.22 / 0.78 / 5.00 | 30.62 / 3.28 / 0.78 / 5.00 |
| common-vm / 2 | 29.38 / 4.22 / 0.78 / 5.16 | 30.47 / 3.28 / 0.62 / 4.84 |
| common-vm / 3 | 29.84 / 3.59 / 0.94 / 4.84 | 29.84 / 4.22 / 0.31 / 5.31 |
| candidate-aa-same-path / 1 | 29.53 / 4.22 / 0.62 / 5.00 | 30.94 / 3.44 / 0.78 / 4.69 |
| candidate-aa-same-path / 2 | 30.31 / 3.59 / 0.78 / 5.00 | 29.22 / 4.06 / 0.78 / 4.84 |
| candidate-aa-same-path / 3 | 30.47 / 3.44 / 0.78 / 5.00 | 30.16 / 3.44 / 0.78 / 5.00 |
| common-vm-same-path / 1 | 30.00 / 4.22 / 0.47 / 4.84 | 30.62 / 3.59 / 0.94 / 4.84 |
| common-vm-same-path / 2 | 29.53 / 4.22 / 0.94 / 5.00 | 30.62 / 3.44 / 0.94 / 4.84 |
| common-vm-same-path / 3 | 30.62 / 3.59 / 0.94 / 4.53 | 30.47 / 3.59 / 0.94 / 4.84 |

The fixed-path comparison shifts +0.62 MiB into the first window and −0.63 MiB out of the next; the paired
median cumulative change through those two windows is −0.01 MiB. Its final two window differences are zero. The
identical-image fixed-path calibration has paired medians −0.31 / 0.00 / 0.00 / −0.16 and a first-window pair
ranging as far as +1.41 MiB despite identical code and inputs. Window movements overlap observed identical-image
variability; these measurements do not establish an added retained heap or a per-window improvement. Every valid
retained-count and RSS gate passed, and all sets remain reported.

One final A/A attempt is invalid: a diagnostic `objcopy --dump-section` invocation without an output ELF rewrote
the mapped VM snapshot and caused SIGBUS (PID 3035615). An unloaded-copy `strace` reproduction confirmed
`O_WRONLY|O_TRUNC` on the input. Both snapshots were restored and their original hashes verified; artifact
publication was made atomic and only the remaining planned A/A slots were completed. This was a diagnostic
error, not an accepted benchmark sample. No product VM/library source or shared toolchain was changed by that
diagnostic.

| Web scene | GC objects control → candidate | Frame median ms | Frame p95 ms |
| --- | ---: | ---: | ---: |
| wasm-gc/editing | 8,724 → 8,724 | 2.4 → 2.3 | 4.4 → 4.0 |
| wasm-gc/full | 4,440 → 4,440 | 2.3 → 2.2 | 4.3 → 3.9 |
| wasm-gc/static | 4,440 → 4,440 | 2.0 → 1.9 | 4.0 → 3.5 |
| wasm-gc/text-heavy | 4,440 → 4,440 | 2.0 → 2.2 | 3.5 → 3.8 |
| wasm32/full | not a GC-object metric | 2.1 → 2.1 | 3.8 → 3.9 |

All 36 GC scene captures tie in object count: full/static/text-heavy 4,440; editing 8,724. The full scene uses
nine alternating pairs and the others three; Wasm32 load comparison uses three pairs. No timeout occurred in
this final-source comparison.

| Web scene | Fetch ms | Compile ms | Instantiate ms | Init ms | First frame ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| wasm-gc/editing | 9.2 → 9.1 | 5.5 → 6.1 | 6.7 → 6.5 | 14.3 → 14.9 | 146.0 → 145.9 |
| wasm-gc/full | 9.9 → 8.9 | 5.4 → 5.3 | 6.8 → 6.5 | 15.5 → 16.1 | 160.9 → 158.3 |
| wasm-gc/static | 9.0 → 9.9 | 5.2 → 5.1 | 6.8 → 7.1 | 15.8 → 15.6 | 160.9 → 149.0 |
| wasm-gc/text-heavy | 10.9 → 8.2 | 5.1 → 5.1 | 6.6 → 6.5 | 16.1 → 15.9 | 152.9 → 139.6 |
| wasm32/full | 15.8 → 17.5 | 5.1 → 5.7 | 2.5 → 2.6 | 12.7 → 11.6 | 156.6 → 138.8 |

Source enum activation, public closure/field/reflection adapters and the UI enum conversions remain next. A
separate live-patch ABI follow-up below now includes the enum storage association in the ABI key, so a storage
change requires a domain reload before source activation.

### Enum storage association in the live-patch ABI

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

### Preserve typed iterator sources

Control `9e3afbab` and candidate use the same committed outer input `46044a271` on the same machine. The typer now
passes the original array to the compiler-owned `IteratorNew` operation. Coercing it to Dynamic first inserted an enum
array view and erased the element type; explicit `Array<E>.iterator()` failed with
`Unsupported ABI boundary cast from Iterator(Dyn) to Iterator(Enum(...))`. The new source fixture fails on the old
compiler and passes on HashLink, Wasm32 and Wasm GC with inlining disabled and enabled. It covers managed payloads,
saved values after element replacement, growth, exhaustion, nullable elements and map-value iteration.

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


### Dynamic lane writes without staging arrays

Control: `74db4f7a`; candidate: the following runtime change on `flat-structs`, with outer input frozen at
`46044a271` on the same machine. A dynamic lane write previously converted into a temporary one-element array, then
copied its lanes. The write bridge now converts and snapshots every leaf before preparing storage and committing it.
The shared policy prepares any missing Wasm GC reference lane before publishing growth or shifting elements. Rejected
writes retain all aliases and contents. No per-array scratch cache or compatibility path was added.

The new `struct-array-dynamic-store` fixture warms capacity and reference storage, then performs two dynamic stores
and one insertion per call. Its exact paired census is identical with inlining disabled and enabled:

| Target / exact measure | 8 calls, control → candidate | 1,024 calls, control → candidate |
|---|---:|---:|
| HashLink allocated bytes, census mode | 4,992 → 0 | 638,976 → 0 |
| Wasm32 objects | 72 → 0 | 9,216 → 0 |
| Wasm GC objects | 56 → 0 | 7,168 → 0 |

HashLink census mode disables allocation-buffer charging, so these byte totals are exact. The fixture also checks
rejected sparse writes and insertions, overlapping insertion, saved copies, optional payload clearing, and the first
managed reference arriving during capacity growth. The three-target IR test covers optional structs containing type
handles without constructing an invalid null handle.

The external source-inline-enum Dynamic probe improves from 14 to 8 allocations per call on Wasm32 and from 13 to 8
on Wasm GC. Its boxed source control still uses 7. A Wasm GC per-site trace identifies exactly three backing/header
objects versus two in the control, two `Owner` objects on each side, and three genuine enum boxes on each side. The
candidate has no private enum-packet allocation in that trace; dynamic reads materialize values that the boxed control
already stores as objects. This prerequisite does not activate source inline enums. The remaining source ABI work and
the measured UI allocation requirement remain pending; this escape-heavy micro-probe is not evidence of a UI win.

Self-hosting seed body-typing time (`bodies` in the compiler phase report) was 229.34 ms in the control checkpoint and
228.70 ms in this candidate on the same machine. These single gate observations show no measurable growth and are
not a compile-speed claim; no generator request policy changed in this commit.

Host measurements for the staging-array removal use nine alternating control/candidate action pairs. Per-action
medians follow; all runs passed their budgets, and the final budget run also passed retention.

| Scenario / action | KiB, control → candidate | ms, control → candidate |
|---|---:|---:|
| tab-matrix / console->telemetry | 74.5 → 72.5 | 1.10 → 1.11 |
| tab-matrix / hierarchy->sensors | 113.0 → 112.8 | 1.57 → 1.57 |
| tab-matrix / sensors->hierarchy | 80.1 → 80.1 | 1.21 → 1.21 |
| tab-matrix / telemetry->console | 92.9 → 92.9 | 1.16 → 1.17 |
| interaction / hover-away | 13.6 → 13.6 | 0.42 → 0.42 |
| interaction / hover-enter | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction / hover-field | 12.4 → 10.9 | 0.43 → 0.43 |
| interaction / hover-inside | 0.5 → 0.5 | 0.00 → 0.00 |
| interaction / hover-other | 10.0 → 10.0 | 0.42 → 0.42 |
| interaction / idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction / idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction / scroll-inspector | 21.2 → 21.2 | 0.71 → 0.71 |
| interaction / type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction / type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress / selection | not reported | 2.96 → 2.98 |

Every action's allocation median is nonincreasing. The KiB counter remains quantized by buffer refills: its downward
steps are not treated as durable object/byte reductions or used to lower ceilings. The deterministic store/insert
micro-census above establishes the actual removal of staging allocations. No budget ceiling changed.

Selection-stress exact census, three alternating pairs (objects / bytes):

| Pair | Control | Candidate |
|---|---:|---:|
| 1 | 340,911 / 24,012,520 | 340,911 / 24,012,568 |
| 2 | 340,911 / 24,012,584 | 340,911 / 24,012,624 |
| 3 | 340,910 / 24,012,232 | 340,909 / 24,011,984 |

All six captures have exactly 305,725 non-`bytes` objects / 21,594,968 bytes. The small raw-byte-buffer variations are
retained in the totals above; there is no selection allocation-reduction claim.

RSS growth windows in MiB, for 100→200 / 200→300 / 300→400 / 400→500 cycles:

| Pair | Control | Candidate |
|---|---|---|
| 1 | 29.53 / 4.22 / 0.78 / 4.69 | 30.00 / 4.38 / 0.94 / 4.84 |
| 2 | 29.53 / 4.06 / 0.78 / 5.00 | 30.16 / 3.59 / 0.78 / 5.00 |
| 3 | 30.00 / 3.59 / 0.78 / 5.00 | 30.31 / 3.44 / 0.62 / 5.00 |

Paired median deltas are +0.47 / -0.15 / +0.00 / +0.00 MiB. The positive first window remains explicit;
it is below the earlier recorded same-image A/A spread (including a +1.41 MiB first-window difference). All six
headless captures passed without memory/leak failures. No captures were replaced to obtain a pass.

The development editor module changes from 99,956,762 to 99,957,149 bytes (+387). The VM binary is unchanged; the candidate
uses the updated native runtime matching its four-argument write bridge. Both sides use the same frozen outer input.

Browser measurements for the staging-array removal: nine full-scene pairs and three pairs each for static,
text-heavy and editing on Wasm GC; three full-scene pairs on Wasm32. Both smoke tests passed, every capture completed,
and no timeout was counted as a pass. Object counts tie in every pair.

| Target / scene | Objects, control → candidate | Median / p95 ms, control → candidate |
|---|---:|---:|
| wasm-gc/editing | 8,724 → 8,724 | 3.5 / 6.5 → 3.4 / 6.3 |
| wasm-gc/full | 4,440 → 4,440 | 3.6 / 7.5 → 3.0 / 5.0 |
| wasm-gc/static | 4,440 → 4,440 | 3.6 / 5.9 → 3.1 / 4.8 |
| wasm-gc/text-heavy | 4,440 → 4,440 | 2.8 / 5.1 → 3.1 / 7.3 |
| wasm32/full | not reported | 2.7 / 5.3 → 2.8 / 6.2 |

Timing moves in both directions; the table preserves the slower text-heavy and Wasm32 observations and makes no
browser speedup claim. Wasm GC Showcase shrinks from 5,810,217 to 5,808,484 bytes; Wasm32 shrinks from 11,876,090 to
11,810,665 bytes. Control/candidate artifact hashes and every paired row are retained in the disk measurement record;
raw captures were deleted after extracting their numbers.

Validation: 792 compiler tests, 0 failures; self-hosting fixed point; all ten UI scripts; 508 parity fixtures (14 existing
skips); six UI snapshots; the app suite; nine retention scenarios; all budget runs and six headless memory captures;
all browser pairs above. The first compiler-suite attempt exposed three synthetic/native test bridges still using the
old callback protocol. They were ported, retaining exception, alias, GC and missing-barrier assertions, and the full
suite was rerun after that correction. Source inline-enum lowering and the remaining semantic ABI work are unfinished.


### Enum equality uses the ordinary value ABI

Control: `098fa40a`; candidate: the next equality-helper classification change. The generated-function filters in
`IrScalarArguments` and `WasmScalarAbi` omitted declared and reflective enum equality, although the Wasm backend
already had the general scalar/reference argument and result ABI. Both filters now use the naming predicate owned
by `EnumEqualityGenerator`. The ownership guard, receiver rules and ordinary inlining policy are unchanged.

The three-target IR fixture uses concrete inline enum storage, managed reference payloads, null and empty cases,
declared and reflective equality, and checked Dynamic round trips. Both inlining modes produce the same census:

| Measure, all three targets | 8 calls, control → candidate | 1,024 calls, control → candidate |
|---|---:|---:|
| Typed equality objects | 0 → 0 | 0 → 0 |
| Equality after two genuine Dynamic round trips | 32 → 16 | 4,096 → 2,048 |

An overlay of the old two filters fails the strict new test on every target/mode combination. The separate ordinary
struct fixture checks multiple value arguments, a field snapshot before another argument mutates its owner, mutable
receivers and a genuine Dynamic escape. Its warmed census already measured zero before this change; this fix does
not broaden ownership analysis. The external source enum probe drops from seven to two allocations per call on both
Wasm targets without forced inlining. Source inline-enum activation and the remaining logical/physical ABI work are
still pending.

The full comparison freezes outer `46044a271` on both sides. Editor module, Showcase modules, VM and runtime are
byte-for-byte identical between control and candidate: this checkpoint changes the eligible inline-enum helper path,
which source application lowering does not activate yet. Nine alternating action pairs report:

| Action | KiB control → candidate | Median ms control → candidate |
|---|---:|---:|
| tab-matrix/console->telemetry | 72.5 → 74.5 | 1.1 → 1.11 |
| tab-matrix/hierarchy->sensors | 112.8 → 113 | 1.57 → 1.58 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.21 → 1.22 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.16 → 1.16 |
| interaction/hover-away | 13.6 → 13.6 | 0.42 → 0.42 |
| interaction/hover-enter | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-field | 10.9 → 10.9 | 0.43 → 0.43 |
| interaction/hover-inside | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-other | 10 → 10 | 0.42 → 0.41 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.71 → 0.71 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.41 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | not measured | 2.93 → 2.96 |

The increased tab counters above are observations from identical executable artifacts, not an introduced allocation
path. No ceiling changes and no replacement runs were used. A separate census-enabled
three-pair tab check gives identical exact bytes in every action window: hierarchy→sensors 115,136;
sensors→hierarchy 81,384; console→telemetry 75,800; telemetry→console 94,520. Census mode disables the refill
fast path, so these are exact allocated bytes, confirming that the normal KiB movement is buffer accounting.
The extraction script initially encountered a null cycle on an unmeasured frame; it was corrected and consumed
the already completed capture, without replacing that measurement. Three selection census pairs record:

| Pair | Objects control → candidate | Bytes control → candidate |
|---|---:|---:|
| 1 | 340911 → 340912 | 24012624 → 24012792 |
| 2 | 340910 → 340909 | 24012288 → 24011992 |
| 3 | 340909 → 340912 | 24011952 → 24012544 |

Every non-byte type ties in all three pairs (305,725 objects / 21,594,968 bytes). The differing byte buffers and measured
RSS variation occur with the same module, VM and runtime hashes. Six memory captures pass; their four RSS windows (MiB):

| Pair | Control | Candidate |
|---|---|---|
| 1 | 29.84 / 4.06 / 0.78 / 5 | 30.16 / 3.59 / 0.94 / 4.84 |
| 2 | 30.31 / 4.06 / 0.78 / 4.84 | 29.69 / 4.22 / 0.78 / 5 |
| 3 | 30 / 3.59 / 0.62 / 4.84 | 30.62 / 3.44 / 0.94 / 6.25 |

Paired median deltas are +0.32 / −0.15 / +0.16 / +0.16 MiB, retained without retries. The third candidate's last window
is 6.25 MiB; it passes the unchanged gate. These are same-image observations, not evidence of a layout memory increase.

All 36 Wasm GC captures and six Wasm32 captures complete without timeout. Full/static/text-heavy scenes keep 4,440
objects; editing keeps 8,724. Frame medians / p95 (ms), control → candidate:

| Target / scene | Median / p95 |
|---|---:|
| wasm-gc/editing | 2.6 / 5.4 → 2.9 / 5.2 |
| wasm-gc/full | 2.3 / 4.3 → 2.2 / 4.3 |
| wasm-gc/static | 2.1 / 3.8 → 1.9 / 3.5 |
| wasm-gc/text-heavy | 2.3 / 4.5 → 2.3 / 4.6 |
| wasm32/full | 2.4 / 4.5 → 2.3 / 4.6 |

No timing improvement is attributed to this change: the actual application artifacts tie. Editor stays 99,957,149 bytes
(SHA256 `89c9d7b7cf31ee776b6f70177a10e7bcde3f6b24b60f54e7e76bd1eeb1830c6b`), Wasm GC 5,808,484 bytes
(`24f2a3a31d18d28769165a80e35336155ef2b317b36b29b187e95aa70877b8ea`), Wasm32 11,810,665 bytes
(`3b1e48cc20dc72fa5724d2e727d4d2f2f51500d4048f95a0ddb84e62113c667b`). Every paired row and artifact hash is
retained in the disk measurement record; raw captures are removed after extracting their numbers.

Validation: 794 compiler tests, 0 failures; self-hosting fixed point; all ten UI scripts; 509 parity fixtures with 14
existing skips; six UI snapshots; app suite; nine retention scenarios; budgets and six headless memory captures;
all browser pairs above. Source inline-enum lowering and the UI enum conversions remain unfinished.


### Registered enum arrays use the assembled-program lane pass

Control: `a9c0e31c`; candidate: the enum-array discovery change. The existing logical-enum-array fixture now supplies
ordinary allocations, element operations and iterator operations to `IrValueArrayProgramRewrite.rewriteAll`, instead
of manually assembling the factory and element helpers. The pass discovers registered inline enums, passes their
storage declarations to the layout factory, and checks physical value types at logical enum element boundaries.
A recursive enum in the same program remains a reference array. Negative read/iterator fixtures reject a logical
boxed enum where a private value packet is required.

The control discovery pass fails this fixture with `IR verification failed for main: ordinary array operation on inline
value lanes`. Candidate passes on HashLink, Wasm32 and Wasm GC with ordinary inlining enabled and disabled. Warm typed
read/write calls allocate zero objects at 8 and 1,024 calls; construction plus iteration has constant allocation counts
for 8 versus 1,024 elements. Mutation coverage includes push, unshift, insert, pop and shift; existing Dynamic/native
round trips, aliasing and managed-reference GC checks remain in the fixture. Source enum activation remains separate.

The full editor comparison freezes outer `46044a271` on both sides. The editor module is byte-for-byte identical
between control and candidate (99,957,149 bytes; SHA256
`89c9d7b7cf31ee776b6f70177a10e7bcde3f6b24b60f54e7e76bd1eeb1830c6b`). Source inline storage is not activated by
this discovery change. Nine alternating action pairs report:

| Action | KiB control → candidate | Median ms control → candidate |
|---|---:|---:|
| tab-matrix/console->telemetry | 72.5 → 72.5 | 1.14 → 1.14 |
| tab-matrix/hierarchy->sensors | 112.8 → 112.8 | 1.63 → 1.66 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.27 → 1.28 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.19 → 1.21 |
| interaction/hover-away | 13.6 → 13.6 | 0.43 → 0.43 |
| interaction/hover-enter | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-field | 12.4 → 12.4 | 0.44 → 0.44 |
| interaction/hover-inside | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-other | 10 → 10 | 0.42 → 0.42 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.72 → 0.72 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | not measured | 3.06 → 3.1 |

The ordinary KiB readings are quantized by buffer refills. Changes below occur with identical executable artifacts;
no new runtime allocation path or timing improvement is attributed to the compiler discovery change. No budget was
raised and no completed measurement was replaced. Selection census results (three pairs):

| Pair | Objects control → candidate | Bytes control → candidate |
|---|---:|---:|
| 1 | 340912 → 340911 | 24012856 → 24012616 |
| 2 | 340909 → 340912 | 24012096 → 24012928 |
| 3 | 340910 → 340909 | 24012448 → 24012176 |

Every non-byte type ties in every pair: 305,725 objects / 21,594,968 bytes. All six memory captures pass the unchanged
gate. Their four RSS windows (MiB) are:

| Pair | Control | Candidate |
|---|---|---|
| 1 | 30.31 / 3.91 / 0.78 / 5 | 30 / 3.91 / 0.94 / 5 |
| 2 | 30.31 / 3.75 / 0.78 / 5 | 30 / 4.22 / 0.78 / 4.84 |
| 3 | 29.38 / 4.22 / 0.62 / 5.16 | 29.22 / 4.22 / 0.62 / 5.94 |

Paired median deltas are -0.31 / +0.00 / +0.00 / +0.00 MiB. Positive observations are retained; they occur with the same module, VM and runtime.

Self-hosting BodyTyped observations (ms), control → candidate: seed 227.90 → 240.63; stage 1 69.55 → 55.60;
stage 2 48.64 → 47.47. These single observations move in both directions and do not establish a generator timing
regression or speedup. This change does not alter the typer or generation loops. The compiler reaches its fixed point.

Both Showcase modules are also byte-for-byte identical: Wasm GC 5,808,484 bytes (SHA256
`24f2a3a31d18d28769165a80e35336155ef2b317b36b29b187e95aa70877b8ea`), Wasm32 11,810,665 bytes
(`3b1e48cc20dc72fa5724d2e727d4d2f2f51500d4048f95a0ddb84e62113c667b`). All 36 Wasm GC and six Wasm32
captures complete. Object counts tie at 4,440 for full/static/text-heavy and 8,724 for editing. Frame median / p95
observations (ms), control → candidate:

| Target / scene | Median / p95 |
|---|---:|
| wasm-gc/editing | 2.9 / 5.7 → 2.9 / 6.1 |
| wasm-gc/full | 2.3 / 4.8 → 2.3 / 4.4 |
| wasm-gc/static | 2.3 / 4.8 → 2.3 / 4.2 |
| wasm-gc/text-heavy | 2.5 / 4.7 → 2.3 / 4.4 |
| wasm32/full | 2.5 / 4.7 → 2.7 / 5.3 |

The first browser launch attempt produced no measurement: the copied logging wrapper had lost its executable bit,
and the harness reported `Chrome DevTools endpoint did not become available` / connection refused. Its failure log is
preserved. Restoring the script mode and adding an executable preflight fixes the launch; no completed capture was
replaced and no guest source changed. The completed comparisons above include the slower Wasm32 observations.

Validation: 794 compiler tests, 0 failures; self-hosting fixed point; all ten UI scripts; 509 parity fixtures with
14 existing skips; six UI snapshots; app suite; nine retention scenarios; all budget runs, six memory captures and
all browser pairs above. Full paired records and hashes are retained on disk; raw captures are deleted after reading.
Source inline-enum activation and the UI enum conversions remain unfinished.


### Function-valued globals retain null and closure semantics

Control: `e8d70a4b`; candidate: the HashLink function-global storage fix. The native VM initializes raw `HFUN` globals
with its `null_function` code pointer. Haxeon's source function-valued fields contain closure references, so a default
field incorrectly compared non-null and calling it read machine code as a closure. The boxed source control reproduced
a SIGSEGV at the closure call; the core identifies the sentinel's code address in the supposed closure register.

HashLink's symbol table now uses `HNULL(HFUN)` for data-global storage, retaining the function signature and normal
closure registers. This stores the same pointer and adds no heap wrapper. No runtime or submodule pin changes are
needed. The ABI fixture checks nullable global metadata, argument/result signatures, ordinary scalar globals and
unchanged callable registers. Its old-storage control fails with `Function data global uses the raw HFUN slot ABI`.
The source fixture checks default null, initialization, clearing/restoring, GC survival of a captured owner and warmed
calls. The candidate passes on all three targets with inlining on/off; 8 and 1,024 typed calls allocate zero bytes in
HashLink's exact census and zero objects on both Wasm targets. Source inline-enum activation remains unfinished.

The full editor comparison freezes outer `46044a271` on both sides. Its emitted control and candidate modules are byte-for-byte identical (99,957,149 bytes; SHA256
`89c9d7b7cf31ee776b6f70177a10e7bcde3f6b24b60f54e7e76bd1eeb1830c6b`). Nine alternating action pairs report:

| Action | KiB control → candidate | Median ms control → candidate |
|---|---:|---:|
| tab-matrix/console->telemetry | 74.5 → 72.5 | 1.17 → 1.17 |
| tab-matrix/hierarchy->sensors | 113 → 113 | 1.68 → 1.68 |
| tab-matrix/sensors->hierarchy | 80.1 → 80.1 | 1.29 → 1.29 |
| tab-matrix/telemetry->console | 92.9 → 92.9 | 1.21 → 1.21 |
| interaction/hover-away | 13.6 → 13.6 | 0.43 → 0.42 |
| interaction/hover-enter | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-field | 10.9 → 12.4 | 0.44 → 0.43 |
| interaction/hover-inside | 0.5 → 0.5 | 0 → 0 |
| interaction/hover-other | 10 → 10 | 0.43 → 0.42 |
| interaction/idle | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/idle-focused | 0.2 → 0.2 | 0.01 → 0.01 |
| interaction/scroll-inspector | 21.2 → 21.2 | 0.72 → 0.71 |
| interaction/type-backspace | 16.2 → 16.2 | 0.42 → 0.42 |
| interaction/type-char | 16.1 → 16.1 | 0.42 → 0.42 |
| selection-stress/selection | census below | 3.13 → 3.11 |

Selection census (three pairs):

| Pair | Objects control → candidate | Bytes control → candidate |
|---|---:|---:|
| 1 | 340909 → 340912 | 24012128 → 24012800 |
| 2 | 340910 → 340911 | 24012408 → 24012584 |
| 3 | 340908 → 340910 | 24011824 → 24012288 |

Every non-byte type ties in every pair: 305,725 objects / 21,594,968 bytes. Byte-buffer variation occurs with the same
executable, VM and runtime hashes. All six memory captures pass. Four RSS windows (MiB):

| Pair | Control | Candidate |
|---|---|---|
| 1 | 30.62 / 3.75 / 0.47 / 4.84 | 30.47 / 3.59 / 0.78 / 5 |
| 2 | 29.69 / 3.75 / 0.78 / 5 | 30.78 / 3.28 / 0.94 / 4.84 |
| 3 | 29.69 / 3.91 / 0.78 / 4.84 | 30.62 / 3.59 / 0.62 / 5.16 |

Paired median deltas: +0.93 / -0.32 / +0.16 / +0.16 MiB. The positive observations are retained; identical program/runtime/VM artifacts rule out a new program memory path here. No ceiling or completed capture was changed.

Self-hosting BodyTyped observations (ms), control → candidate: seed 240.63 → 230.22; stage-1 55.60 → 49.19; stage-2 47.47 → 48.99. These single observations are recorded without a timing attribution; the change is in backend global metadata.

Both Showcase modules also tie byte-for-byte: Wasm GC 5,808,484 bytes (SHA256
`24f2a3a31d18d28769165a80e35336155ef2b317b36b29b187e95aa70877b8ea`), Wasm32 11,810,665 bytes
(`3b1e48cc20dc72fa5724d2e727d4d2f2f51500d4048f95a0ddb84e62113c667b`). All 36 Wasm GC and six Wasm32 captures
complete without timeout. Object counts tie at 4,440 for full/static/text-heavy and 8,724 for editing.
Frame median / p95 observations (ms), control → candidate:

| Target / scene | Median / p95 |
|---|---:|
| wasm-gc/editing | 2.9 / 5.7 → 2.8 / 5.4 |
| wasm-gc/full | 2.5 / 4.9 → 2.5 / 4.9 |
| wasm-gc/static | 2.1 / 4.3 → 2.5 / 4.7 |
| wasm-gc/text-heavy | 2.5 / 4.9 → 2.3 / 5.0 |
| wasm32/full | 2.8 / 4.8 → 2.6 / 5.3 |

The slower static-scene and Wasm32 p95 observations are retained. These same-image timings imply no change-specific
speedup or slowdown. No capture was replaced and no ceiling was raised. Full paired rows and artifact hashes are
retained on disk; raw captures are deleted after their numbers are extracted.

Validation: 796 compiler tests, 0 failures; self-hosting fixed point; all ten UI scripts; 510 parity fixtures with
14 existing skips; six UI snapshots; app suite; nine retention scenarios; all budget runs, six memory captures and
all browser pairs above. Source inline-enum lowering and UI conversions remain unfinished.


### Scalar closures forward reference leaves through verified private calls

Control: `b4751a62`; candidate: the private closure ABI change. The verifier accepted traced reference carriers at
direct scalar calls but rejected the same exact components at typed closure calls. `IrScalarArguments` now owns the
shared private-signature predicate used by the verifier and Wasm call normalization. Callable constructors and direct
stack-reference calls check the actual verified function table; a native borrowing the prefix is rejected. Wasm's
null-check forwarding helper declares the private ABI for typed component signatures, retaining its null exception.

The new IR fixture passes on HashLink, Wasm32 and Wasm GC with inlining on/off. A callback over a tag and traced
managed reference allocates zero objects at 8 / 1,024 calls (HashLink exact census; Wasm allocation counters), with
HashLink major GC before capture and Wasm32 GC stress enabled. Negative cases cover native prefix forgery for carrier
and stack-reference signatures, direct stack-reference escape to a forged native, Dynamic/cast escape, ordinary
callables consuming carriers, and repeated arguments hiding a type mismatch. Existing return/field/array carrier
rejection tests remain. The old Wasm normalizer failed verification because its forwarding helper had an ordinary
signature; the shared policy now marks the helper as an actual private function rather than adding a verifier bypass.
Source inline-enum activation remains unfinished.

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


### Nongeneric interface calls preserve value carriers

Control: `6f816201`; candidate: the shared value-interface normalization. A nongeneric interface method returning a
struct with an Int and managed reference allocated two private value packets per HashLink call: 16 / 2,048 objects at
8 / 1,024 calls, with inlining off or on. Selecting the existing typed dispatcher before scalar ABI selection removes
both packets (0 / 0 in the same exact census). The same common policy replaces the enum prototype's local dispatcher
selection; it passes all three targets with inlining on/off.

The source fixture also exposed a correctness gap in the control: bound interface methods failed compilation with
`Unknown or receiver-less IR closure target "ValueReader.read"`. The candidate handles direct and bound calls through
inherited contracts, value arguments and results, replacement/copy independence, exceptions and managed references.
HashLink exact bytes and Wasm32/Wasm GC object counts are zero in its measured loops at 8 / 1,024 calls, with both
inlining settings. HashLink major GC runs before measurement; Wasm32 runs with GC stress. The IR test checks that source
functions remain unchanged, reference-only methods retain their calls, direct/bound uses share dispatchers, signature
mismatches are rejected, and regenerated bodies do not retain a removed implementation. Scalar-only specialization is
unchanged and remains in roadmap item a2. Source inline-enum activation and UI conversions remain unfinished.

The first self-hosting attempt rejected an implementation check with
`IrTypedInterfaceDispatch.hx:42:10: E1025: Enum "compiler.ir.IrInstruction" does not conform to Equatable`.
Host Haxe accepted an enum-identity comparison used to detect replacements; the compiler's own value-equality rules
correctly rejected it. Normalization now records an explicit replacement flag. No enum conformance or equality rule
was changed. The failed source/logs are retained; affected gates run again on the corrected source.

A second self-hosting check reported `IrTypedInterfaceDispatch.hx:179:19: E1014: Array index must be Int` at the nullable
map lookup used to replace a dispatcher. Generation now explicitly checks the lookup before indexing. This preserves
the consistency check and source-level null safety; it does not use a cast or relax the verifier. Both failed attempts
are retained separately from final-source validation.

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

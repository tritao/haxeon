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

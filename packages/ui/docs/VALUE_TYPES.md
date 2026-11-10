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


### Constant-time typed interface dispatch (November 2026)

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

### Host export roots before enum layout selection (Tier 1 checkpoint)

Requested exports now reach the frontend as `Expose` roots before value layout/call lowering. This prepares the
first source enum classification to keep host-exposed enum signatures nominal. Adding or removing export roots
invalidates compilation; equivalent root sets reuse it, and cached source IR remains unchanged.

`HostExportRootsMain` checks the CLI session input and all three targets with inlining off/on. At 8/1,024 calls,
returning the cached nominal enum and inspecting it allocate zero bytes on HashLink and zero objects on Wasm32 and
Wasm GC. Source `@:expose` retention survives removal of the requested roots. Tier 1 passes: 804 compiler tests,
zero failures, and the self-hosting fixed point.

BodyTyped single-run observations (ms), table checkpoint → export-root checkpoint: seed 222.26 → 229.68;
stage 1 45.84 → 46.72; stage 2 46.58 → 49.42. These observations are retained without a change-specific timing
attribution. Editor/Web builds and Tier 2/3 validation belong to the upcoming batch head; no product measurements
are claimed for this staging commit.

### First closed source inline enum subset (Tier 1 checkpoint)

Source constructors, matches, tag-zero nulls, nullable joins, direct functions, typed closures, object/static fields and
array elements now share the existing lane layout. Classification is program-wide and conservative; the exact admitted
forms and remaining widening work are listed in STRUCTS.md (E1–E9). Unsupported escapes keep the whole enum boxed.
No UI enum conversion is included in this checkpoint.

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

### Fail-closed inline enum IR validation (Tier 1 checkpoint)

A global verifier invariant rejects selected enums' nominal carriers in physical signatures, fields, instruction values
and phi inputs, including bodies outside a selective incremental verification set. Only canonical generated escape
adapters and logical array/iterator descriptors are exempt. Type tokens may feed matching array descriptors and the
array bridge's exact-type check; other descriptor uses fail. The negative fixture forges 14 cases in each of the six
target/inlining modes (84 checks), including nested function/nullable/array/iterator types, native/C-native signatures,
phi operands, non-array type-token uses and a misleading helper name. Positive fixtures retain logical collection
handles and check real generated adapters.

The older manual logical-array fixture now expresses its genuine Dynamic/native round trips through the generated
box/unbox adapters, while its typed census remains zero at 8/1,024 calls on all targets and inlining modes. An initial
fixed-point check caught a three-binding `MakeEnum` pattern in the new verifier; Haxeon correctly requires all four
bindings, unlike the host compiler's permissive pattern. The pattern was corrected before the final Tier 1 run.

The preceding activation's Tier 2 run passed all ten UI scripts but stopped at `rpc-lifecycle` on Wasm32:
`IR verification failed for __haxeon_closure_adapter_34a39671ba8460368538a2bf65b2a36e_010640cf77729dfb6daf9068fb271e80:
Inline value storage requires a logical cast adapter`. The isolated `962367ad` control compiles that fixture;
`57e69910` reproduces the failure. The batch remains unpublished and the RPC cause is the next correctness commit.
No paired product measurements have been accepted from this incomplete Tier 2 head.

Final-source Tier 1: 807 compiler tests, zero failures; all affected six-mode fixtures; self-hosting fixed point.
BodyTyped observations (ms), activation → verifier: seed 235.50 → 214.87; stage 1 45.65 → 44.76;
stage 2 45.78 → 46.74. These remain single-run observations, not a change-specific timing attribution.

### Typed callback method transport (Tier 1 checkpoint)

The `rpc-lifecycle` bisection isolates the Wasm32 build failure to activation: the pre-activation `962367ad` control
compiles; `57e69910` fails while generating an adapter from `RpcConnectResult -> Void` to `ManagedBytes -> Bytes`.
The scalar-closure safe-use list did not recognize method arguments, so the first callback was incorrectly left in the
boxed adapter source set. The fix checks every possible receiver's declared callback argument against its exact type.
It keeps the callback on the typed scalar ABI; no Dynamic fallback or verifier exemption is introduced.

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

### Nominal interface checks found by the batch app gate

On frozen outer `8195b397f04e2d527430607e8e3624a38df8d950`, both the `530bda5a` compiler control and `42bae206`
candidate stop at `SceneVisibilityTests.hx:311`: `hover updates the row without rebuilding its owner`. A small probe
isolates a waiting `TooltipHoverDelay` incrementing the scheduler's rebuilding revision. The tooltip scheduling fix is
separate; the app failure has not been accepted as a pass.

Implementing the existing delayed-animation contract exposed a HashLink runtime error: a class implementing
`DelayedAnimation` also passed the test for unrelated `RetainedAnimation`, because the latter's methods are a prefix of
the former's. The runtime now checks exact declared-interface caches, including cached ancestors, and unwraps interface
views before testing. No fields, wrappers or allocation operations are added. The same compiled regression module exits
12 under the control runtime and 42 under the corrected runtime. The fixture checks sibling interfaces with identical
and prefix method sets, inherited classes, base-interface views, Dynamic views and undeclared lookalikes. It passes in
the interpreter and on all three targets with inlining off/on; its existing HashLink tracked loop remains allocation-free.
Tier 1: 810 compiler tests, zero failures. Paired product measurements remain pending on the final batch head; the
control runtime is retained separately. Records: `haxeon-flat-work/enum-first-batch-gates/nominal-interface`.

### Interface conformance across live generations

The review follow-up reproduced a real limit in the pointer-only fix: re-emitting the interface's source module and
appending an implementing class preserve existing type pointers, but a full reload creates new pointers. A retained
pre-patch object then failed the new module's conformance test (`Old object lost conformance after reload: 1`).
Virtual types now carry a nominal contract identity in shared metadata (HLB 8 / HLP 11); the same-generation pointer
comparison stays first. No instance fields, wrapper fields or global registries are added. The live regression retains
both the old object and a cached interface view, checks inherited interfaces and casts/calls after each edit, forces a
major GC while the old generation awaits retirement, rejects a same-shaped sibling and a changed contract, and drains
the retirement backlog after release. The corrected test passes.

Tier 1 on the final source: 811 compiler tests, zero failures, the six-mode nominal-interface fixture and the
self-hosting fixed point. The first fixed-point run caught `HlSymbolTable.hx:441:50: E1014: Array index must be Int`
from a nullable map lookup used as an index; using the existing typed index API fixes it. A strengthened reflection
probe initially omitted the runtime intrinsic configuration; the final fixture configures the compiler explicitly.
Neither diagnostic was accepted as a gate pass. BodyTyped observations (ms), callback checkpoint → this change:
seed 216.86 → 223.43; stage 1 44.83 → 44.88; stage 2 46.08 → 46.37. These remain single-run observations; they do not
establish a repeated-generator regression. Product Tier 2/3 comparisons remain pending after the
separate tooltip deadline correction. Records: `haxeon-flat-work/enum-interface-identity`.

### Waiting tooltip deadlines preserve retained rows

The frozen app failure above was present in both compiler control and candidate. Its standalone `SceneTreeRow` probe
showed the owner build count rising from 1 to 2 immediately on hover: starting `TooltipHoverDelay` incremented the
scheduler's rebuilding revision while the tooltip was still waiting. The timer now implements the existing
`DelayedAnimation` contract. Positive waits leave rebuilding state unchanged; crossing the deadline invalidates the
view, while cancellation before the deadline removes the wait. The timer's configured duration is `durationSeconds`;
`delaySeconds()` reports its remaining wait. All callers use the new form.

The reduced app row now stays at one owner build across hover. Regression checks cover the wake deadline, unchanged
revision while waiting, expiration, cancellation and an immediate deadline. Search-picker integration passes, as do
all six UI snapshot target/inlining configurations and Tier 1 (811 compiler tests, zero failures). This is a correctness
fix to invalidation, with no new ownership or caching mechanism. The full app gate and paired product measurements
remain pending on this batch head. Records: `haxeon-flat-work/tooltip-deadlines` and
`haxeon-flat-work/enum-first-batch-gates/hover-probe`.

### Null string-map keys found by the full app gate

After the tooltip correction, the app reached `SceneCollisionTests.editor` and crashed in
`EditorScene.object(null)` (`EditorScene.hx:1972`, caller `SceneCollisionTests.hx:183`). GDB shows
`hl_hbget -> hl_hbfind -> hl_hash_gen` with a null key. The tiny nonempty-map query reproduces under the archived
`530bda5a` compiler and the original `4a33fa08` VM/libraries too. Both Wasm targets already return a missing result.

HashLink now hashes null as zero and compares it as a distinct key, including when it collides with the empty string.
It adds no storage or allocations and preserves the literal `"null"` key separately. The fixture covers replacement,
growth through 64 additional keys, key/value iteration, shallow copies, removal, clear, stored null values, and numeric
as well as reference values. The IR interpreter previously rejected `__map_string_ref_alloc`; its logical String-map
model now runs the same fixture.

Missing-key get/exists/remove census, both inlining modes:

| Target / measure | 8 queries | 1,024 queries |
|---|---:|---:|
| HashLink allocated bytes | 0 | 0 |
| Wasm32 allocated objects | 0 | 0 |
| Wasm GC allocated objects | 0 | 0 |

Tier 1 passes: 813 compiler tests, zero failures, the interpreter/six-mode fixture and self-hosting fixed point.
The full frozen-source app suite exits zero, including `SceneCollisionTests`. An initial fixture dereferenced a nullable
get result before checking it; a local null check fixes that invalid test. A first census harness omitted the requested
Wasm exports; it now declares them before layout selection and at the backend boundary. No product measurements were
accepted from either diagnostic. BodyTyped observations (ms), nominal-identity checkpoint → this change:
seed 223.43 → 229.14; stage 1 44.88 → 44.05; stage 2 46.37 → 44.59. These are single-run observations; the native-hosted
stages decreased. Product allocation/RSS/browser comparisons remain pending on the final batch head.
Records: `haxeon-flat-work/map-null-keys`; the original app failure is retained as
`enum-first-batch-gates/app-scene-collision-failure.log`.


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

### Rejected payload sizing conversion (2026-11-09)

Against `1fae06c3`, the directed `LayoutSizing` payload enum conversion passes the initial framework check and the
final trial's six UI value snapshot checks, but is not allocation-neutral. An exact HashLink census of a typed class
setter storing newly constructed `LayoutAxis.fixed(i)` values measures:

| Updates | Committed representation | Payload sizing enum trial |
|---:|---:|---:|
| 8 | 0 objects / 0 bytes | 8 objects / 192 bytes |
| 1,024 | 0 objects / 0 bytes | 1,024 objects / 24,576 bytes |

Every additional allocation is `enum<haxeon.ui.LayoutSizing>`. The trial removes the redundant axis fields and
preserves the native record mapping, but the current E3/E6/E7 classification keeps the nested enum boxed across
`ComputedStyle.setAxis`/`getAxis`, style equality methods, reflection and descriptors. Correctness parity is therefore
insufficient to land it. The complete reproduction and eligibility findings are recorded in `STRUCTS.md` under
"UI sizing conversion: measured stop"; the patch is preserved on disk and the source was restored. No candidate editor
or Web module from this rejected conversion is published, and no per-action allocation, RSS or binary-size win is
claimed. Complete the documented transport and reflection prerequisites before retrying the payload sizing port.
After restoring the source, `scripts/test-driver.sh 8` passes all 838 tests with zero failures.

### Cache payload-free boxed enum cases on Wasm (2026-11-09)

The host lifecycle plain-enum trial exposed a general compiler gap. HashLink reuses payload-free enum case values,
but both Wasm backends emitted a new enum allocation at every case reference. This affected ordinary comparisons
against a case as well as construction. The compiler now initializes one managed module-global cache per referenced
case lazily. Wasm32 reserves and registers the cache roots before generating its collector; Wasm GC uses managed
reference globals. Payload constructors retain their ordinary boxed allocation behavior.

The small `NullaryEnumCacheMain` regression forces boxed storage with a by-value recursive case. Its measured loop
references two payload-free cases, switches on them, compares declared equality and `Type.enumIndex`, and writes them
through class methods into a field and a preallocated array. Setup and case initialization precede the allocation
window. It clears every ordinary owner and array, churns payload values, collects, and reacquires the cases to check
that the cache globals alone keep them alive. The Wasm32 run enables collection stress and checks that collection ran;
the Wasm GC run forces an engine collection. Both inlining modes pass on all targets.

| Target | Iterations | Before objects | After objects |
|---|---:|---:|---:|
| HashLink | 8 / 1,024 | 0 / 0 | 0 / 0 |
| Wasm32 | 8 / 1,024 | 16 / 2,048 | 0 / 0 |
| Wasm GC | 8 / 1,024 | 16 / 2,048 | 0 / 0 |

The separately preserved lifecycle probe constructs sessions and performs stop/dispose transitions. These counts
include the sessions and their two empty-array allocations, so they are not expected to be zero. Control uses the
committed integer enum abstract; the trial uses the plain enum. All rows agree with inlining off and on:

| Target | Session cycles | Integer control | Plain enum before fix | Plain enum after fix |
|---|---:|---:|---:|---:|
| Wasm32 | 8 | 27 | 88 | 27 |
| Wasm32 | 1,024 | 3,075 | 10,248 | 3,075 |
| Wasm GC | 8 | 28 | 89 | 28 |
| Wasm GC | 1,024 | 3,076 | 10,249 | 3,076 |

The probe includes one initial session per call; Wasm GC also counts its static callback closure. The exact HashLink
census, which constructs its callback and initial session before the window, ties at 3,072 objects / 122,880 bytes for
1,024 cycles, including 48-byte session objects. These are isolated form checks, not editor action measurements. The
lifecycle source port remains separate from this compiler fix; editor/Web comparisons and Tier 2 run on the batch head.
Tier 1 passes 839 compiler tests with zero failures, the six target/inlining combinations above, and self-hosting to a
fixed point.

### Host lifecycle as a closed enum (2026-11-09)

`UiHostLifecycle` now names its six states with a plain `Equatable` enum. Its former integer values were not a native,
wire or file contract, so implicit integer conversions have been removed. The transition switch is exhaustive;
host callers already use named cases. The value snapshot parity gate checks startup, repeated transitions,
stop/dispose idempotence, terminal states and invalid restarts, and rejects implicit conversions in both directions
on HashLink, Wasm32 and Wasm GC, with inlining off and on (24 checks including the existing snapshot).

The nullary-case cache prerequisite above makes the plain-enum lifecycle probe tie the integer control on both Wasm
targets. The exact HashLink census also ties at 3,072 objects / 122,880 bytes for 1,024 session cycles; the session
object remains 48 bytes. Tier 1 passes all 839 compiler tests with zero failures and the 24 parity checks above.
These isolated checks establish the representation cost; paired editor/Web modules and full Tier 2 gates are
assessed separately on the batch head.

### Closed style tags (2026-11-09)

`EffectKind`, `DecorationKind` and `EffectParameterType` are plain `Equatable` enums instead of implicitly
convertible strings. Their lowercase/hyphenated spellings were display labels, not a native or serialized contract.
Explicit exhaustive label switches preserve those descriptions without reflective enum formatting. Parameter
component counts remain 1/2/4/4, including the existing zero result for a null parameter type.

A stored-value probe constructs a record containing effect/decoration tags and an `EffectParameter` struct, reads
the tags through the record and checks its scalar payload. Setup warms all referenced cases before counting:

| Target | Iterations | String tags | Plain enums |
|---|---:|---:|---:|
| HashLink | 1,024 | 1,024 objects / 73,728 bytes | 1,024 objects / 65,536 bytes |
| Wasm32 | 8 / 1,024 | 8 / 1,024 objects | 8 / 1,024 objects |
| Wasm GC | 8 / 1,024 | 8 / 1,024 objects | 8 / 1,024 objects |

Both inlining modes agree. HashLink's probe record shrinks from 72 to 64 bytes as eligible tags use scalar storage;
there are no extra enum boxes in the loop. This is a representation probe, not an editor allocation claim. Editor
and Showcase size/allocation comparisons belong to the batch-head measurements.
Tier 1 passes 839 compiler tests, all 42 UI value parity/conversion checks and the framework test. No compiler
sources change in this port; the cache prerequisite's self-hosting fixed point still applies.

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

### Cursor intent as a closed enum (2026-11-09)

The UI's platform-independent `CursorShape` now uses a plain `Equatable` enum. `UiContext` maps every intent through
its exhaustive native-cursor mapping before comparing or invoking the native cursor handler; window-decoration
regions use the same mapping. The UI intent no longer implicitly converts to or from an integer. The native
platform cursor constants remain the boundary contract, separate from the UI enum's constructor order.

The all-target value fixture checks all ten mappings, array storage and nullable render-node cursor fields, and
rejects integer conversions in both directions. All 60 value/parity checks pass with inlining off/on, as do all
839 compiler tests. No compiler sources change.

An isolated probe repeatedly writes and reads `RenderNode.cursor` and `windowDecorationCursor` on a preallocated
node, after warming both referenced cases. Both inlining modes agree:

| Target | Writes to both fields | Integer representation | Plain enum |
|---|---:|---:|---:|
| HashLink | 1,024 iterations | 2,048 objects / 32,768 bytes | 0 objects / 0 bytes |
| Wasm32 | 8 / 1,024 iterations | 16 / 2,048 objects | 0 / 0 objects |
| Wasm GC | 8 / 1,024 iterations | 16 / 2,048 objects | 0 / 0 objects |

The old nullable integer fields box each assignment. The enum stores cached case values, so assigning an intent
does not allocate. A separate exact HashLink census constructing 1,024 initialized nodes falls from 6,144 objects /
827,392 bytes to 4,096 / 794,624. `RenderNode` remains 296 bytes, `LayoutNode` 120, `LayoutStyle` 344 and `WidgetId` 16;
the complete difference is the 2,048 integer boxes. These are representation probes; editor/Web allocation and
binary-size deltas are measured on the next batch head.

### Payload-free enum tag storage (2026-11-09)

Payload-free source enums now use a nominal I32 carrier on every compiled target, including class fields that
previously forced boxed enum storage. Constructor index plus one encodes the value; zero encodes null. Enum identity
survives in the type, array descriptor and checked escape adapters. A genuine Dynamic/reflection escape uses the
cached boxed case introduced above; typed operations do not need a box or a private value object.

The source fixture deliberately combines class and anonymous-record reflection, nullable fields, Flat records,
arrays and iterators, closures called through Dynamic, specialized generic fields and reference-valued maps.
It also checks that a tag array cannot cast to Array<Int>, and that two concrete instantiations of a phantom generic
enum cannot cast to each other. Both inlining modes agree:

| Measurement | HashLink | Wasm32 | Wasm GC |
|---|---:|---:|---:|
| Flat record: enum tag + Int | 8 B / alignment 4 | 8 B / alignment 4 | 8 B / alignment 4 |
| Typed operations and warmed Dynamic round trips, 8 / 1,024 iterations | 0 / 0 objects | 0 / 0 objects | 0 / 0 objects |
| Construct/populate an array, 8 versus 1,024 elements | 2 / 2 objects | constant object count | constant object count |

HashLink's two array constructions allocate 152 / 4,392 bytes. Those totals include the header, retained geometric
growth policy and allocator rounding; they are not an element-size calculation. The independent IR lane test checks
that each element occupies exactly 32 scalar bits and zero reference slots. Native field metadata checks four-byte
enum fields, and source sizeof/alignof/offsetof checks the complete Flat record on each target. Captures are deleted
after reading their exact type totals.

HashLink retains a distinct four-byte native enum-tag descriptor, including in boxed recursive enum payloads.
The native formatter and `enum_parameters` return the logical case (`Wrap(On)`, not `Wrap(2)`); dynamic closure
calls return the shared case instead of a private integer-shaped box. A tag plus Int in a class occupies 16 bytes
including the eight-byte object header. Descriptor persistence rejects invalid case counts, boxed types and cache
indices, and a retained object's tag field survives a live body patch and a fresh module load.

`EnumTagStorageMain` additionally executes the nominal scalar carrier, serialized IR, and a boxed native-ABI stub
on all three targets with inlining off/on. The post-array verifier rejects ordinary reads, writes and iterator
creation on tag lanes. Full editor/Web allocation, RSS and size comparisons belong to this batch's Tier 3 checkpoint;
these representation fixtures do not substitute for that comparison.

A serial self-host build pair at the pre-native-metadata checkpoint uses the same 661 compiler/stdlib source files, with both control and candidate
compiler executables built by stock Haxe. BodyTyped (`bodies`) is 74.81 → 64.89 ms; IR assembly is 7,469.60 →
6,103.33 ms. These are single paired observations, not an asserted timing improvement. The measured body phase did
not grow, so this change does not add generator cursors solely for the earlier fixed-point typing concern. The
source-input digest and phase numbers are retained with the measurement records; the generated modules are deleted.

The native-metadata checkpoint also reaches a self-hosting fixed point. Concurrent gate observations report
BodyTyped at 239.23 / 82.83 / 56.37 ms for seed / stage 1 / stage 2; these are not a paired timing comparison.
The initial native-metadata suite exposed a host-interpreter inference bug in the new receiver check: comparing
a fetched Dynamic receiver with zero inferred an Int even for class receivers. Branch-specific checks fix the
cause, and a direct reference-receiver regression test accompanies the existing tag-zero rejection test.

Tier 1 on the native-metadata source: **843 passed, zero failed** with eight workers; all source/tag fixtures pass
on HashLink, Wasm32 and Wasm GC with inlining off/on, and self-hosting reaches a fixed point. Tier 2 and paired
editor/Web comparisons remain required before publishing this batch.

A final serial pair builds the same 661 compiler/stdlib sources with the stock-Haxe-built control and candidate
compilers: BodyTyped **64.32 → 65.04 ms**, IR assembly **5,235.14 → 5,978.75 ms**. This single pair identifies no
material body-typing growth; the extra representation work is in IR assembly. The final source-input SHA-256 is
`8a5c235144e5691cbde206818f4c37edd3515cb11ec937f2ce7af48b581ef824`. Generated comparison modules are deleted
once these numbers are recorded. The VM reader additionally rejects forged case-cache global indices before
hot-reload hashing can use them; the live-patch fixture exercises that malformed-bytecode path.


### Nominal-tag assembly traversal follow-up (2026-11-09)

The 5,235.14 → 5,978.75 ms assembly observation above is a regression checkpoint, not an accepted final cost.
Sampling the same compiler/stdlib compilation identified unconditional IR copying, temporary operand arrays,
eager function-signature arrays, repeated field/method walks, and two escape traversals as new work. The follow-up
retains unaffected functions, values and instruction locations; discovers representation changes once per SSA
definition; indexes inherited field/method signatures; and constructs escape arguments and fresh IDs only when
an actual adapter is inserted. The first escape transition checks only rewritten functions. The later pass still
checks generated reflection/runtime helpers. The tag verifier still visits every operand, including phi edges,
using an exhaustive visitor that does not construct temporary input arrays.

The regression fixture checks 1,000 and 4,000 unrelated functions, unchanged instruction identity, repeated escape
lowering, nested descriptors and an invalid phi operand. Source fixtures cover inherited class and interface
signatures and inherited Dynamic fields on all three targets, with inlining disabled and enabled.


An allocation-stack census isolated the remaining tag-triggered cost in the lane-array pass: before its fix,
control/candidate assembly allocated **55,802,950 / 58,884,891 objects**, **2,404,120,848 / 2,539,939,384 bytes**.
Stacks sampled every 1,024 bytes attributed about 49 MiB to speculative Dynamic-view rebuilding, 25 MiB to
function summaries and 18 MiB to repeated type-key construction. These are sampled site attributions; the census
totals are exact. The pass now indexes live lane keys once, discovers carriers from SSA definitions, encodes each
shape once, shares its function lookup across shapes, appends generated helpers without repeated full-list copies,
and allocates blocks/locations only for actual Dynamic-array operations. The original array-scaling assertion is
unchanged: the final unrelated-body overhead is **65,384 / 79,368 bytes** for one/eight shapes; unused Dynamic and
reference-array parameters cost **69,456 bytes**. Removing fixed discovery overhead exposed the remaining per-shape
function-map/list rebuilding; that cause was fixed rather than relaxing the test.

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

### RawRepresentable synthesis (2026-11-09)

`RawRepresentableMain` runs the same source on HashLink, Wasm32 and Wasm GC,
with inlining disabled and enabled. An Int-backed raw enum occupies one I32
class field and four bytes inside an eight-byte two-field native struct. Exact
HashLink census and both Wasm counters report **0 objects for 8 and 1,024 calls**
to `rawValue()` through direct and constrained generic calls. Checked Int/String
conversions cover unknown values, zero, aliases and incremental constant edits;
implicit conversions and a nonconforming generic argument are rejected.
`fromRaw()` retains the existing nullable scalar ABI; inline nullable scalars
remain assigned to a2.

Tier 1: **846 passed, 0 failed** (8 workers), all six target/inlining combinations,
and self-hosting fixed point. Existing permissive enum-abstract fixtures now
declare the conversions they exercise; annotation arguments are checked against
the nominal enum before serializing its raw constant, and integer operators
honor explicitly declared conversions. The former declaration-hint tables are
deleted.

Self-hosted compiler-source phase comparison uses stock-Haxe-built compilers
from `52bbc93a` and this change, the same checkout VM, CPU affinity 0–11, and
663 unchanged source files (source digest
`6ff03cbac877dd39e55a8c56003515079a529bc0e3e876ce77d582b2247d54af`). The fixed
three-pair comparison ran after this session's suite and fixed-point processes
finished. All samples are retained below, in milliseconds.

| Phase | Control samples | Candidate samples | Control median | Candidate median |
|---|---|---|---:|---:|
| IR assembly | 8011.77, 7607.58, 7764.08 | 8145.13, 7679.36, 7138.85 | 7764.08 | 7679.36 |
| BodyTyped | 234.73, 174.49, 191.59 | 251.30, 223.80, 189.32 | 191.59 | 223.80 |

Assembly median changes by -1.09%, within the control spread. BodyTyped's
wall-time median increases 16.81%, but the ranges overlap (174.49–234.73 versus
189.32–251.30 ms), with one GC in each sample. Its allocation median decreases
from 33,571,712 bytes / 1,174,288 objects to 33,559,944 / 1,174,037. Metadata
typing also decreases from approximately 1,978,721,456 bytes / 56,483,531 objects
to 1,969,975,304 / 56,353,566. There is no repeated synthesis of previously
generated raw helpers: the completion loop drains only newly requested members.
The short BodyTyped wall-time result does not establish a generator retyping
regression; the complete measurements are recorded rather than selecting a
faster pair.

The earlier comparison overlapping this session's suite was inconclusive:
assembly control 8964.10 / 16910.07 / 7232.04 ms, candidate
15136.56 / 9711.56 / 10259.38; BodyTyped control 383.75 / 594.85 / 181.04,
candidate 255.45 / 256.49 / 423.15. Those samples are not the acceptance measure.

Compiler modules are stable within each side: 36,082,265 → 36,083,601 bytes
(+1,336), SHA-256
`2f6d551710b7b859d9581fa6baffe86496dcd68c43029e56a395b6cf47966b70` →
`a448197f90e906370ea4bc797c8146c7cd798252d3a33834fef1ea20952508a1`.
Editor/Showcase module comparison runs at the batch head under Tier 3.

### Flags and checked raw conversion follow-ups

The 32-case `RawRepresentable` fixture compares the previous equality chain with
one typed integer switch, using identical input and runtime. Successful
`fromRaw` calls allocate 8 / 1,024 objects for 8 / 1,024 calls on HashLink,
Wasm32 and Wasm GC, both without and with inlining. HashLink's exact byte census
is 128 / 16,384 bytes on both sides. These are the existing nullable-Int result
boxes (a2), not enum boxes. Unknown values return null. Integer aliases share a
switch case; String constants retain equality checks. The emitted-IR census is
65 blocks / 32 conditional branches on every target, with inlining off and on;
the current general switch lowering has not introduced a jump table.

The Flags fixture stores a set in four bytes (an eight-byte two-field struct),
and repeated operations allocate zero objects for 8 and 1,024 calls on all
three targets, with inlining off and on. The census excludes readable String
formatting. Checked raw construction, immutable updates and the signed high bit
are included. Native boundary checks in the same loop also allocate zero:
8/16/32/64-bit all-ones words are masked to the schema's declared bits,
including each signed high bit. Direct `Flags.fromRaw` still rejects unknown
bits. Generated native field, out/inout, array and result readers apply this
mask explicitly; the event decoder fixture supplies an undeclared modifier bit
and expects only the declared Control bit to survive.

A diagnostic identical-input compiler comparison isolates the canonical operand
visitor cleanup: old visitor IR assembly 2,435,090,920 bytes / 56,200,626 objects;
shared visitor 2,435,094,344 / 56,200,841. The early collector implementation
allocated about 255 MB more and was discarded. These overlapping runs are not a
paired timing acceptance measurement; batch timing and editor measurements are
recorded after the final ports.


Flags validation: compiler suite **849 passed, 0 failed** (8 workers),
self-hosting fixed point, and all six target/inlining combinations pass. The UI
framework passes, including unknown native modifier bits and the native/UI
modifier-mask alignment check; the frozen outer app suite also passes. Detached
app setup uses the existing OCCT prefix, an explicit `MATERIA_INSTALL_ROOT`, and
fixture output directories `build`, `app/build` and `app/build-cad`.

The framework compile exposed a large flow-fact scan: candidate compile
734,089 ms, metadata typing 398,344 ms and 98,021,442,280 typing/lowering bytes.
Two stack samples land in `FlowFacts.resolve`, allocating `prefix + "."` while
merging refinements. The preceding `4fb8b1c7` compiler lands in the same scan;
its original UI source fails nominal native-enum binding checks already ported
in this change. This is not a completed paired compile-time comparison or an
acceptance result. A control with the required boundary casts is being checked;
the flow-fact scaling issue remains a follow-up until that comparison completes.
Batch editor/Web allocation and memory measurements remain pending Tier 3.


### Typed cursor keys and flag reads (655fd164 follow-up)

The native cursor cache uses its native shape as the key; both cursor mappings
return native cases directly, and the controller's switch is exhaustive.
Interaction changes read typed maps without unchecked casts and check the
current-state invariant before reading a present value. IME flags and platform
option defaults also use typed flags.

The expanded fixture compares the former cast with the presence-checked read,
including an empty flags value. Results are identical with inlining off and on:

| Runtime | 8 reads, old → checked | 1,024 reads, old → checked |
|---|---:|---:|
| HashLink objects / bytes | 0 / 0 → 0 / 0 | 0 / 0 → 0 / 0 |
| Wasm32 objects / bytes | 8 / 64 → 8 / 64 | 1,024 / 8,192 → 1,024 / 8,192 |
| Wasm GC objects | 8 → 8 | 1,024 → 1,024 |

The Wasm objects are the existing nullable-scalar map result boxes (a2).
Reference-valued maps keyed by a nominal native-shape enum abstract allocate
zero objects on every target, as do the repeated flags operations. The
interpreter checks the core flags and field initializer; reference-valued
native map primitives are not implemented there, so map allocation comparisons
run on the three runtimes.

Compiler suite: **850 passed, 0 failed**. The full UI value snapshot matrix
passes 24 positive and 36 negative checks; settings and layout also pass.
The snapshot gate exposed a pre-existing omission in enum-tag scalar-storage
verification, fixed separately in `1e42b4c6`, with valid four-byte storage and
malformed-width tests. Older layout/native-enum integer casts remain assigned
to their queued type-conversion groups; this follow-up removes the casts around
the newly typed flags and cursor intent.

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

### Closed layout transaction codes (2026-11-10)

`LayoutVisualKind` and the currently retained `LayoutSizing` code type are native contracts: their values are the
`nkui_layout_visual_kind` (1–4) and `nkui_layout_sizing` (0–3) fields of the NativeUI binary transaction declared in
`include/nativekit_ui_layout.h`. They now implement `RawRepresentable`, with synthesized `rawValue()` and checked
`fromRaw()` and no implicit Int conversions. The encoder, content fingerprint and snapshot boundary use explicit
raw projections; native record values and scalar storage are unchanged.

This does not land the withheld payload sizing conversion: its measured E3/E6/E7 blocker remains recorded in
STRUCTS.md. `LayoutAxis.value`/`growWeight` remain part of that unfinished conversion, with one existing sizing API.
The payload-free UI alignment/direction policies are separate from these native code contracts and remain assigned
to the plain-enum group.

The layout-code fixture checks every declared value, unknown inputs, value equality and encoded native bytes on
HashLink, Wasm32 and Wasm GC with inlining off/on. Four negative fixtures reject implicit Int conversions in both
directions for both types. The expanded UI snapshot matrix passes 30 positive and 60 negative checks; the compiler
suite passes 856/856. Production allocation and module-size comparisons are recorded at the next gated batch head.

### Plain layout policies (2026-11-10)

`LayoutDirection`, `LayoutAlignmentX`, `LayoutAlignmentY`, `LayoutDistribution`, `LayoutPositioning`,
`LayoutWrapMode` and `LayoutSelfAlignment` are UI policy choices, not raw native codes. They are plain Hashable enums.
The transaction matches every case to the corresponding native binding literal; absolute positioning becomes native
flags. UI case order is not the native ABI. The redundant sizing-code and policy-code range tests are removed;
numeric size, spacing and transform validation stays in place.

Style declarations now retain each policy's enum type in a scalar field. Typed declaration readers replace the old
integer casts, and `setInteger` accepts only `StyleProperty<Int>`. The untyped `integerProperty` factory is deleted.
The existing opaque cache keys keep their numeric case-index form through the enum-index intrinsic. No new cache or
ownership mechanism is introduced.

The policy fixture covers all seven declarations, equality/copying, inspection, arrays, native transaction bytes and
negative numeric sizing validation. Fourteen negative fixtures reject implicit Int conversions for every policy;
a further negative fixture rejects `setInteger` on an enum property with its exact argument diagnostic. Production
editor and headless modules build; allocation and size comparison is performed at the gated batch head.

Validation for this group: compiler suite **856/856**; the complete UI snapshot matrix passes **36 positive and
150 negative** checks across the three targets with inlining off/on. Both frozen production modules build.

### Closed native text codes (2026-11-10)

`FontFamily`, `TextAlignment`, `TextWrap` and `TextDirection` retain their native integer contracts from
`include/nativekit_ui.h` and implement `RawRepresentable`. Font family is the finite native role code
(Default 0, Emoji 1, Monospace 4), not an arbitrary font identifier; reserved codes 2 and 3 are rejected.
The four types have no implicit Int conversion. Text-layout calls, font registration and transaction encoding
project their values explicitly with `rawValue()`.

`TextCaret.direction` retains its existing scalar native-code ABI. Comparisons and geometry equality tests
project declared direction cases explicitly with `rawValue()`. Converting every native caret through nullable
`fromRaw()` would introduce a 16-byte scalar box per query (the already measured nullable ABI assigned to a2),
so that conversion is not introduced. Scalar field storage and the native transaction format are unchanged.

The text-code fixture checks every declared value, unknown values, reserved font codes and encoded transaction
bytes. Eight negative fixtures reject implicit Int conversions in both directions for every type. Batch gates,
allocation and module-size comparisons are recorded at the measured batch head.

Validation: compiler suite **856/856**; full Wasm parity and the expanded UI snapshot matrix pass, with
**42 positive and 198 negative** checks across HashLink, Wasm32 and Wasm GC with inlining off/on. Final editor,
headless and both Web modules build, and the app/CAD and all retention scenarios pass. The remaining batch UI
and paired performance gates are recorded at the measured batch head.

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

### Discrete style properties and generated closure size (2026-11-10)

The layout/text enum batch above grew the default development Showcase modules by
458,706 bytes on Wasm32 and 107,818 bytes on Wasm GC. A per-function body census
identified an unused capability on `StyleProperty<T>`: even discrete properties
instantiated its nullable `T -> T -> Float -> T` interpolation field. Seven enum
signatures entered the closure-cast graph. Wasm32 consequently emitted 152 extra
closure adapters and eight extra cast dispatchers; their bodies alone added
78,405 and 15,764 bytes. The resulting functions also expanded GC-root, patch,
slot and name metadata. Wasm GC emitted seven 808-byte enum varargs adapters,
along with other closure and type-dispatch growth.

Interpolation now belongs to `StyleInterpolatedProperty<T>`. Discrete properties
retain their typed default and no interpolation function signature. Float and
reference properties that actually interpolate use the explicit capability;
color retains its dedicated typed implementation. There is no second legacy
constructor or fallback implementation.

| Development Showcase module | Before enum batch | Enum batch (`4b16f69d`) | Callback split, virtual-getter trial |
| --- | ---: | ---: | ---: |
| Wasm32 bytes | 12,041,570 | 12,500,276 | 12,194,793 |
| Wasm GC bytes | 5,903,055 | 6,010,873 | 5,958,117 |
| Wasm32 defined functions | 6,901 | 7,249 | 7,005 |
| Wasm GC defined functions | 4,309 | 4,436 | 4,349 |

The fix removes 305,483 / 52,756 bytes respectively. Both targets' closure-adapter
and closure-cast body counts and bytes return exactly to their pre-enum-batch
values. The remaining growth includes the seven concrete style value classes,
enum equality/hash and tag escape helpers, and metadata for those types. On
Wasm32 the residual 153,223 bytes comprise 45,511 bytes of GC-root metadata,
43,117 patch metadata, 39,882 code, and 24,713 other sections. On Wasm GC the
remaining 55,062 bytes comprise 27,916 patch metadata, 17,529 code, and 9,617
other sections. These are measured development modules, with patch metadata
retained. The final native-enum group must compare its own function/section
sizes against this corrected control.

In the virtual-getter trial, HashLink editor size falls from 105,419,778 to **105,377,728 bytes**; the headless
module falls from 106,223,172 to **106,183,652 bytes**. Exact action-window
censuses tie the published control, including the aggregated per-type tables:
**1,677 objects / 117,240 bytes** for hierarchy-to-sensors and **8,621 / 580,816**
for selection. Native census rows with the same printed type name are summed,
rather than overwritten.

Validation: compiler suite **856 passed / 0 failed**, all ten UI scripts, full
Wasm parity and UI snapshots (both inlining modes), app suite including CAD plate
workflow, and all nine retention scenarios. The snapshot fixture checks float
and reference interpolation as well as rejection of discrete interpolation.
The detached app's native configure step reported `CadKit needs a prebuilt OCCT
and none was found.` at its relative cache path; the freshly compiled app tests
passed with the existing unchanged native libraries used by the preceding gate.

One editor build before serialization ended with **SIGTERM** (HashLink status
`1073741839`) and no compiler diagnostic. The machine was reported at load 37
on 20 cores. The failed attempt is excluded. A one-shot rebuild under the shared
heavy-build lock succeeded; signal tracing recorded no SIGTERM in that run.
The original sender was not observed, so resource pressure remains the likely
explanation, rather than a confirmed signal source.

The virtual-getter trial used three alternating pairs under both shared locks.
All samples are retained; this is the pre-field revision, not a selected passing retry.

| Action | Control KiB | Trial KiB | Control ms | Trial ms |
|---|---:|---:|---:|---:|
| console->telemetry | 73.0 | 73.0 | 1.42 | 1.56 |
| hierarchy->sensors | 109.3 | 111.0 | 2.03 | 2.21 |
| hover-away | 13.6 | 13.6 | 0.47 | 0.45 |
| hover-enter | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-field | 12.3 | 12.3 | 0.49 | 0.46 |
| hover-inside | 0.5 | 0.5 | 0.00 | 0.00 |
| hover-other | 9.9 | 9.9 | 0.50 | 0.46 |
| idle | 0.3 | 0.3 | 0.01 | 0.01 |
| idle-focused | 0.3 | 0.3 | 0.01 | 0.01 |
| scroll-inspector | 21.7 | 21.7 | 0.77 | 0.73 |
| selection | 567.203125 (exact) | 567.203125 (exact) | 2.87 | 2.95 |
| sensors->hierarchy | 78.3 | 78.3 | 1.57 | 1.71 |
| telemetry->console | 89.4 | 89.4 | 1.52 | 1.63 |
| type-backspace | 16.1 | 16.1 | 0.44 | 0.43 |
| type-char | 16.1 | 16.1 | 0.45 | 0.43 |

Hierarchy’s refill counter rises 109.3 → 111.0 KiB, while its exact object/byte census above ties.
No budget ceiling changes. Frame medians vary substantially within these runs; the table includes all pairs.

| Pair | Build | 200–500 growth MiB | Window 1 | Window 2 | Window 3 | Window 4 |
|---|---|---:|---:|---:|---:|---:|
| 1 | control | 10.47 | 29.53 | 3.91 | 0.94 | 5.62 |
| 1 | candidate | 10.62 | 29.53 | 4.06 | 0.94 | 5.62 |
| 2 | candidate | 10.31 | 30.16 | 3.75 | 0.62 | 5.94 |
| 2 | control | 10.00 | 29.53 | 3.59 | 0.78 | 5.62 |
| 3 | control | 10.47 | 29.06 | 4.06 | 0.78 | 5.62 |
| 3 | candidate | 10.31 | 29.53 | 3.75 | 0.78 | 5.78 |

All six memory gates pass. Cumulative RSS-growth medians from cycles 200–500 are
10.47 → 10.31 MiB; last-window growth medians are 5.62 → 5.78 MiB. The earlier
49.99 → 50.77 MiB “absolute” estimate double-counted the cumulative growth and is invalid.
The final source retains the original constructor-initialized, externally read-only metadata
field to avoid introducing virtual dispatch on this path. The callback remains confined to
interpolated properties. That source is measured separately against the same published control.

Every browser trial retains 4,320 GC objects in full/static/text-heavy and 8,604 in editing,
including identical per-frame allocation histograms. Wasm32 retains 3,840 allocation calls / 132,480 bytes.

#### Final constructor-initialized metadata field

The final source keeps `hasInterpolation` as an externally read-only field initialized by constructors.
Discrete properties carry no interpolation callback; interpolated properties own their non-null typed callback.
This preserves the original direct metadata read. All ten UI scripts and all-target snapshots pass on this
revision, as do the freshly built app suite and all nine retention scenarios. The compiler is unchanged from
the 856/0 suite and full compiler parity run.

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

### Plain widget choices (2026-11-10, next gated batch)

`ButtonVariant`, `SpinnerKind`, `ProgressMode`, `ImageFit`, `SplitSide` and
`SplitOrientation` are plain `Hashable` enums. Their old integers selected Haxe
rendering or layout behaviour; none is a native, wire or persisted-number
contract. Callers continue to use named cases. Spinner kind and split direction/
side numeric validation is removed; speed, dimensions and other float checks
remain. Image fitting switches explicitly cover all four cases.

The group fixture checks six enum fields in a 28-byte struct (including its
4-byte marker), copied array elements, equality/hash, exhaustive matching,
reflection get/set and rejection of another enum at a field boundary. It passes
on HashLink, Wasm32 and Wasm GC with inlining off/on; all 144 negative Int/String
conversion checks pass. The compiler suite passes **856/856**, and the framework
smoke test including 4,000-node layout pressure passes. Production binary-size
and paired allocation results are collected at the next Tier 2 batch head before
publication; the control is `fcfd253b` and its archived `style-field` modules.

### Plain presentation choices (2026-11-10, next gated batch)

`TextRole`, `IconName` and `DockPanelHeaderMode` are plain `Hashable` enums.
Their old integers selected Haxe typography, procedural icon paths and dock
header ownership; none is a native, wire or persisted-number contract. Theme
role and icon rendering switches cover every case explicitly. Icon cache keys
retain their previous numeric case-index prefix rather than allocating longer
case-name strings. Dock fingerprints likewise use the case index, including the
existing `-1` sentinel for an absent icon.

The group fixture verifies three tag fields plus a marker occupy 16 bytes,
copying array elements, equality/hash and nullable icon reflection get/set with
wrong-enum rejection. All six target/inlining combinations pass, as do all 72
negative Int/String conversion checks. The framework smoke test including
4,000-node layout pressure passes. The compiler suite passes **856/856** under the shared heavy-build lock
with eight workers. Production binary-size and paired allocation results
are collected with the next Tier 2 batch against `fcfd253b`.

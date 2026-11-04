# UI value types

This records the value conversions in stage 0 of [ADR 0002](../../../docs/adr/0002-reactive-ui-model.md), including typed
style storage and transitions.

**Measurement correction:** The later Wasm GC paired runs through the erased-boundary change swapped the build-source
`nativekit_ui_showcase_wasm_gc.wasm`, but the browser loads `nativekit_ui_haxeon_guest.wasm`. Those runs measured the
candidate guest on both sides, so their claimed paired comparisons were invalid. HashLink pairs and standalone Wasm
censuses were unaffected. Identical guest hashes remain valid evidence of identical generated code. The boundary and
literal-cache comparisons below were rerun by swapping the browser-loaded guest itself.

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

`LayoutStyle` remains a mutable `Equatable, Diffable` class. It is not `Hashable`: its fields change in place, while
render and style caches use `Diff.fingerprint` snapshot values. The measured struct version boxed 25,625 values
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

Each action dirtied all 100 frames in both runs. The census disables the allocation-buffer refill accounting that
causes `Gc.totalAllocated` to round slightly differently; no action allocated more bytes after conversion.

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

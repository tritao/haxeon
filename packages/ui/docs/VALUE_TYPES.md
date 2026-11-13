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

Earlier struct, conformance, erased-boundary and literal-cache comparisons are recorded in the
[UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#initial-value-conversion-measurements).
Typed Float-hash and generic-closure fixtures allocate zero objects for 8 and 1,024 calls across all targets and
inlining modes.

The earlier closure, pointer, type-identity and reactive-runtime comparisons retained the documented action-allocation
behavior within their paired controls. Fixed-step Showcase runs avoid animation-phase variation in allocation counts.
The individual revisions, captures and paired samples are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#earlier-paired-runtime-and-ui-measurements).

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

The paired editor and Wasm measurements retained the documented behavior. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

The callback dependency and UI snapshot gates passed on all three targets and both inlining modes. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Key-path merge and field-mask port (2026-11-05)

`RenderNode` and `StyleResolver` use typed key paths and field masks; the full gate and paired comparison passed. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Nested scalar callbacks at HashLink Dynamic boundaries (2026-11-05)

Nested function arguments and results bridge independently of the outer scalar ABI. The callback fixture passes across all targets with inlining off/on. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

Negative insertion indices are tested on both Wasm targets; the complete parity and product gates passed. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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
The structural runtime and production clear/validation policy passed the target fixtures and product gates. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Uniform array growth: factor-2 trial (not accepted)

The factor-2 and factor-1.5 growth trials were withheld after their HashLink memory regressions; the committed target-specific capacity policy remains in force. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Checkout VM launcher integration

After merging `hl-exit-crash`, the VM and profiler come from the checkout CMake
build through `scripts/hl` and `scripts/hlprof-live`; the compiler suite uses
`scripts/test-driver.sh 16` with private copies of its loaded VM and runtime.
Project fingerprints stamp the actual checkout VM, and project generation and UI tools use the checkout launcher. The rejected growth policy stays parked. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Wasm GC scalar words and range operations

The capacity policy is unchanged. Typed scalar accesses are specialized before nullable erasure, while their element and field layouts are still available. Accessors retain only array/index/value parameters; stride, field offset, width, signedness and bitmap presence are compile-time facts. Aligned full fields use direct word loads/stores; packed fields use masked word spans. A shared span kernel handles a crossing field and unaligned range words without a staging allocation.

The backend caches each lane cast. Unknown native layouts use bounded word fragments, preserving native validation and exception behavior. Physical ranges use overlap-safe `array.copy`, `array.fill` for complete clears, and byte helpers only at unaligned ends. The common reverse policy tests bitmap presence outside its loop. Native builds use the committed generated C header; the compiler unit verifies drift and deterministic generation. A native build with the Haxe tool directory hidden passed. Dynamic concat consults the shared compatibility primitive and the shared concat guard.

The new `struct-array-word-access.hx` fixture passes on HashLink, Wasm32 and Wasm GC with both inlining settings. Reads, writes and reversal allocate zero guest objects for 8 and 1,024 prepared elements. Existing low-level tests retain 32/64-bit words, unaligned spans, forwarding, lazy references, bitmap boundaries and exception checks. Synthetic native arrays with deliberately arbitrary layouts are untyped; the typed layout checks still enforce the exact element representation.

Typed scalar accessors keep stride, offset, width and bitmap presence as compile-time facts; packed and unaligned ranges use the shared word-span kernel. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Minimum-first-capacity growth trial (not accepted)

The single follow-up trial used `max(required, capacity + capacity / 2, minFirst)`, with
`minFirst = max(4, floor(32 / max(1, elementBytes)))`, on ordinary and struct-lane arrays on all three targets.
Explicit construction and resize allocations were exact; resize retained capacity when the new length fitted.
Empty HashLink storage was shared only where no metadata owner needed pinning. Wasm GC empty backings were
shared lazily by storage type, so unused storage types allocated nothing. `ComputedStyle` indexed stores used
implicit growth instead of repeated explicit resize. No other growth variant was measured.

Minimum-first-capacity growth remains rejected because the measured HashLink RSS regression was not acceptable. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

The comparison and unchanged allocation windows are archived with their controls. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

The enum layout planner and packed-word access helpers were brought up before source-enum activation; subsequent sections document the implemented representation. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Nullable argument/result ABI checkpoint (2026-11-06)

The compiler now preserves the scalar ABI namespace when nullable primitive arguments are expanded into presence and
payload components. A direct factory or forwarding function returning a struct no longer loses its scalar-result
contract and fails verification with `A scalar stack reference cannot escape its call`. The verifier is unchanged.
The regression fixture exercises scalar-only and managed-reference results on HashLink, Wasm32 and Wasm GC, with
inlining on and off. Managed cases explicitly export and require their setup function and reject a null owner.
Every 8/1,024-call census is zero; HashLink uses the exact object census. This composes existing lowering passes and
does not implement the deferred scalar generic specialization stage.

The corrected nullable ABI comparison selected compiler source explicitly for each project build. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

Float32 enum payload words use the portable word helpers; their implementation and target fixtures are retained. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

Changing an enum storage association requires `ReloadDomain`; an unchanged association with a body edit remains patchable. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Preserve typed iterator sources

Control `9e3afbab` and candidate use the same committed outer input `46044a271` on the same machine. The typer now
passes the original array to the compiler-owned `IteratorNew` operation. Coercing it to Dynamic first inserted an enum
array view and erased the element type; explicit `Array<E>.iterator()` failed with
`Unsupported ABI boundary cast from Iterator(Dyn) to Iterator(Enum(...))`. The new source fixture fails on the old
compiler and passes on HashLink, Wasm32 and Wasm GC with inlining disabled and enabled. It covers managed payloads,
saved values after element replacement, growth, exhaustion, nullable elements and map-value iteration.

The typed iterator path and target fixtures passed; paired measurements are archived. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

Verified scalar closure forwarding preserved zero-allocation typed calls in the target fixtures. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

Nongeneric interface value carriers passed the target fixtures and product gates. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

### Constant-time typed interface dispatch (November 2026)

Only `ViewportContent.paint(Canvas, Rect)` selects this ABI in the UI package. Class tables live in module metadata, do not enlarge instances and add no per-call allocations; the source audit and benchmark are in `GENERIC_SPECIALIZATION.md`. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

The first source inline-enum subset was gated independently; the historical product measurements are retained below. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

Typed callback transport passed the target and inlining matrix; the historical micro and product comparisons are retained below. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

The full product comparison, frozen inputs, allocations, timing and module hashes are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#closed-source-enum-batch-final-product-comparison).

### Final batch validation after the 614024b2 rebase

The rebased validation and its control comparison are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#final-batch-validation-after-the-614024b2-rebase).

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

The nullary cache and closed-tag allocation, timing and module comparisons are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#nullary-enum-cache-and-closed-tag-batch-final-measurements-2026-11-09).

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

The assembly traversal fix passed the target fixtures; individual timing observations are archived. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

The pre-rebase raw/flags batch evidence is in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#closed-rawflags-conversions-pre-rebase-batch-checkpoint-2026-11-10).

### Restoring self-hosting after origin/main 090589e5

Compiler sources remain self-hostable by using explicit types and nullable checks, exhaustive typed instruction comparisons and storage-independent generic map reads. Final fields and verifier checks remain intact. The original failure-to-commit ledger and validation are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#restoring-self-hosting-after-originmain-090589e5).

### Closed raw/flags conversions: rebased integration checkpoint (2026-11-10)

The rebased raw/flags validation, full gate outcomes and individual timing samples are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#closed-rawflags-conversions-rebased-integration-checkpoint-2026-11-10).

### Quiet-machine selection and Wasm32 timing check (2026-11-10)

The quiet-machine repeat tied selection medians at 2.43 ms and Wasm32 median/p95 at 1.50/2.10 ms. [Paired samples and conditions](../../../docs/history/ui-value-types-2026-11.md#quiet-machine-selection-and-wasm32-timing-check-2026-11-10).

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

The layout/text batch gates, artifact hashes and paired measurements are in the [UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#gated-layout-and-text-enum-batch-2026-11-10).

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

The constructor-initialized metadata design was validated against the previous module and retained as the field representation. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

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

### Complete nominal-tag escapes in retained Wasm assemblies (2026-11-10)

A callback taking both a value struct and a nullary enum, converted through
`Dynamic` and restored, compiled on HashLink but failed while preparing the
retained HashLink assembly of a Wasm compilation. The source-enum fixture on
`d8b322c2` reproduced:

```
IR verification failed for $scalar-closure:erased-call:5fa30522a1cd0352dc17fa565f102625: Unknown IR call "$enum-tag:unbox:ClosureMode"
```

The retained assembly creates its scalar closure adapters after frontend tag
escape completion. Complete tag escapes on that assembly copy immediately after
creating those adapters, as the target-specific Wasm adapters already do. This
keeps the original logical program available to the Wasm backend.

The extended `enum-tag-storage` fixture covers the mixed struct/enum closure
round trip. Its source-enum matrix passes on HashLink, Wasm32 and Wasm GC, with
inlining off/on. Existing tracked tag-loop windows still allocate **zero objects
for 8/1,024 iterations**; HashLink tag arrays retain **2/2 objects and 152/4,392
bytes** for 8/1,024 elements. The explicit Dynamic closure round trip is a
correctness check outside those allocation windows. The compiler suite passes
**856/856** with eight workers, and self-hosting reaches a fixed point. Both
heavy checks run under the shared build lock. Production size and paired runtime
results belong to the following enum-conversion batch.

### Typed native enum boundaries (2026-11-10, next gated batch)

The generated native binding owns integer codes. Non-flags native enums and the
callback-error enum are closed `RawRepresentable` types. Typed native reads call
shared, non-nullable checked decoders instead of nullable `fromRaw`, so successful
reads allocate nothing. Each owning type module supplies one uniquely named
decoder container; dependent interfaces share its methods. No open-enum form is
introduced.

| UI choices | Classification and boundary |
|---|---|
| `LayoutSizing`, `LayoutVisualKind` | Plain UI enums; native layout transactions map to generated native cases. Axis payload fields retain the previously measured representation. |
| `FontFamily`, `TextAlignment`, `TextWrap`, `TextDirection` | Plain UI enums; font/text calls take generated enum types. UI carets carry UI text direction. Monospace maps to native code 4 independently of its UI tag. |
| `CompositeMode`, `LineCap`, `LineJoin`, `ImageFormat`, `ImageFilter` | Plain UI enums; drawing/image boundaries map to native cases. Packed command buffers explicitly encode those native raw values. |
| `MaskKind`, `CachePolicy` | Plain UI choices; compositor and retained-cache boundaries map to generated native cases. |
| `AccessibilityRole`, `AccessibilityOrientation` | Plain semantic UI choices; accessibility projection maps to the generated native types. |

The existing cursor/effect kinds remain plain enums. Effect encoding now uses
native cases rather than handwritten integers and explicitly covers every UI
kind, rejecting operations that normalization should have removed. UI
fingerprints/snapshots use case indices independently of native numbers.

All UI-to-native enum switches now live in `NativeEnums`, including the six
layout policy mappers formerly private to `LayoutTransaction` and the cursor,
effect, cache, mask and accessibility projections. The existing small inline
layout policy switches keep their inline declarations. Future UI types that
mirror native enums directly use the generated binding type; the already
migrated types above retain their representation as decided.

The value fixture matrix passes **18 positive and 360 negative cases** across
HashLink, Wasm32 and Wasm GC, with inlining off/on. Native enum scalar/fixed-array
read/write/decode windows allocate **zero objects for 8/1,024 iterations** on all
six combinations. After consolidating the mappings, the four affected fixture
groups also pass **24 positive and 330 negative checks** across all six
combinations. The native callback regression on HashLink rejects invalid
arguments before invoking the callback and rejects invalid returned codes.
Split function/type-module and imported-enum tests confirm one owning decoder.

NativeKit's GTK backend can produce pointer-button codes 5/6, unnamed in the
vendor header. The binding import header completes the finite closed domain
0–7. Compatible C enum value groups merge; conflicting enum/flags groups fail.
The canonical ABI audit passes on four desktop and two Wasm targets. The platform
event fixture accepts 5/6 and rejects 8, and retains raw payload handling for a
declared, unhandled event kind while rejecting an unknown native event code.
The vendor/nativekit pin is unchanged.

The native result domain also includes the HTTP/transport error constants that
NativeKit carries through common result fields. The all-target record fixture
accepts `TransportWouldBlock`/`HttpDns` and rejects an unknown result (six positive
and 216 negative checks). The restyle field-coverage test now varies enum roles
and orientations explicitly, keeping its coverage assertion and unknown-field
failure intact.

`Icon.namePrefix` checks call the actual private cache method after warming
all 46 icon names. Both control (`d8b322c2`) and the native-boundary candidate
allocate **zero objects for 8/1,024 cached lookups** on HashLink, Wasm32 and
Wasm GC, with inlining off/on (six combinations per side). The nominal
`Type.enumIndex(name)` boundary reuses cached case objects; no replacement
intrinsic or mapping switch is needed. The measurement harness verifies Wasm
only after target-specific closure adapters and supplies the same shared-memory
contract as UI parity; earlier harness setup errors are excluded from the
allocation result.

Checked native decoders compact consecutive declared integer codes into exact range guards; sparse gaps and signed endpoints remain checked. The target fixtures and product gates passed. [Measurement history](../../../docs/history/ui-value-types-2026-11.md).

## Release code size after enum conversions

Closed-tag release selection removes unobserved descriptors and uses scalar arrays where the nominal descriptor cannot
be observed. Enum escape reachability is shared by payload eligibility, closed-tag ABI selection and Dynamic descriptor
registration; reflection and native boundaries retain nominal identity. Wasm32 reuses its registered stringifier and
numeric formatters. Closure receiver probes share one physical implementation without merging semantic signatures.

The latest measured release sizes are 6,595,956 bytes for Showcase Wasm32, 3,982,976 for Showcase Wasm GC and
27,402,978 for the HashLink editor. The paired enum-representation fixture measured no growth on either Wasm target and
24–26 bytes less on HashLink. The final 15-action census recorded 16,251 objects / 1,048,304 bytes, with `type-char` at
417 / 16,360; all other action counts matched the checkpoint.

### Final release attribution and physical closure probes

The development modules measured 11,581,890 bytes on Wasm32, 6,038,119 on Wasm GC and 101,643,349 for the HashLink
editor. The emitted-function attribution, controls, per-run logs and full gate results are preserved in the
[UI checkpoint history](../../../docs/history/ui-value-types-2026-11.md#release-code-size-after-enum-conversions-2026-11-11).

### Stage 5 component batches

| Batch | Allocation evidence (objects / bytes) |
| --- | --- |
| Native scope and text ownership | Standard 15 actions: fourteen identical; telemetry → console 1,710 / 93,752 → 1,708 / 93,680. CNC resume 1,479 / 77,304 → 1,462 / 76,384. Telemetry step 14,978 / 629,752 → 15,080 / 630,520: approved correctness exception because the control disposed all 18 live worker bindings early (ADR 0002 stage 5); native counts are the baseline for later batches. |
| Immutable Text / Icon leaves | Selection 8,589 / 583,816 → 8,565 / 581,608; the other fourteen standard actions are identical. CNC source 4,705 / 276,616 → 4,615 / 268,336; telemetry step 15,080 / 630,520 → 15,078 / 630,336. No action increases. |
| Native IconButton / equal BIM history children | All fifteen standard actions and six CNC pilot actions are identical. Telemetry step 15,078 / 630,336 → 14,983 / 624,712 (95 objects / 5,624 bytes saved). No action increases. |
| Captured focus / blur dispatch | All fifteen standard and seven pilot actions are identical to `835a2bbc8` / outer `7eff0a036`. Prepared-event dispatch through resolved, transformed nodes allocates zero on HashLink, Wasm32 and Wasm GC, with inlining off/on; event construction is unchanged. |
| Button body-root components / stable WidgetIdCache (unpublished) | Fresh 22 actions against `835a2bbc8`, renewed on the same `9707f25de` compiler: CNC progress 5,466 / 278,240 → 5,465 / 277,912; selection 8,649 / 585,416 → 8,563 / 589,792; resume 1,462 / 76,384 → 1,455 / 76,968. Structural byte residues attributed in ADR 0002. Telemetry 14,983 / 624,712 → 14,851 / 625,032 has a user-approved temporary +320 B exception for the dev-c5/a1 compiler gaps; re-measure and eliminate it when those fixes land. Every other action meets the refined acceptance rule. The closed event-phase enum preserves all 22 counts exactly against a same-compiler Button control. |

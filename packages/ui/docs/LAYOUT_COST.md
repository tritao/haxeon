# Layout submit cost

`HAXEON_UI_LAYOUT_COST=1` enables per-submission timing records in the process output. It is off by default: the
setting is read once and disabled probes neither read a clock nor format output. Times are seconds, measured with
`Sys.time()` in Haxe and `steady_clock` in native code. Each successful submit emits backend, native and Haxe records,
with a node count in each and the encode start timestamp in the Haxe record. Clean frames that reuse the submitted layout emit no records.

The measured boundaries are:

- `encode`: `LayoutTransaction.encodeInto`, including its tree walk, validation, string table, record writes and successful-submission receipt swap.
- `parse`: native transaction decoding into `LayoutNode`s, applying the retained mutation and publishing its identity/topology index.
- `prepare`: native backend validation, adjacency/ID tables, floating layers and Clay capacity setup.
- `solve`: Clay BeginLayout, tree declaration and EndLayout, including intrinsic measurement and text shaping callbacks.
- `snapshot`: reading Clay geometry, text layouts, transforms/clips, primitives and paint order into `LayoutSnapshot`.
- `hash`: hashing the completed snapshot for render-epoch invalidation.
- `decode`: exporting the resolved-item buffer across FFI and decoding/reusing Haxe resolved items.

These are disjoint phases, not an exact accounting of `UiFrameMetrics.nativeLayoutSeconds`: session locks, measure-content
registration, FFI submission setup, custom-paint pruning and probe output are outside them. Output formatting occurs after
the measured intervals. Capture without the sampling profiler and with retention verification disabled for representative
times; verification deliberately submits additional reference trees. The log report assumes one submitting thread, as in
the editor's headless scenarios.

To reproduce, from the outer repository, run each of `interaction`, `tab-matrix` and `selection-stress`:

```sh
HAXEON_UI_LAYOUT_COST=1 python3 app/tools/profile-editor.py --scenario interaction --cycles 60 --no-profile
```

The first capture builds the editor and native library. Subsequent captures can use `--skip-build`. Then run:

```sh
python3 haxeon/packages/ui/tools/report-layout-cost.py app/build/profiles/<capture>/launch.log
```

The report uses `frame-timeline.jsonl` beside the launch log to associate submits with frames by their Haxe timestamp.
It omits setup, verification frames and cycle 0 (or the first occurrence of each action where cycles are unnumbered),
sums all layout passes within each frame, then takes independent per-phase medians over
frames that actually performed layout. It also reports median passes per frame and the range of tree sizes. Idle and
paint-only frames do not dilute the result. The timeline distinguishes layout cost from complete frame and input latency.


## Measurements and decision (2026-10-30)

Same machine, 60 cycles per scenario, release HashLink, no sampling profiler. Per-frame phase medians in milliseconds;
node counts are the range of submitted tree sizes. `interaction` includes only its active layout frames, not idle,
paint-only or explicit verification frames. Tab setup frames are excluded. Captures: `ui-layout-frame-interaction`,
`ui-layout-frame-tab-matrix`, `ui-layout-frame-selection-stress`.

| scenario | active frames | passes/frame (median) | nodes | encode | parse | prepare | Clay solve | snapshot | hash | decode |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| interaction | 354 | 1 | 350–351 | 0.154 | 0.047 | 0.046 | 0.137 | 0.081 | 0.020 | 0.051 |
| tab-matrix | 236 | 1 | 344–485 | 0.159 | 0.048 | 0.053 | 0.172 | 0.081 | 0.020 | 0.075 |
| selection-stress | 59 | 2 | 350 | 0.318 | 0.095 | 0.097 | 0.285 | 0.163 | 0.040 | 0.132 |

**The data supports (a): keep Clay and address encode, snapshot and decode costs before considering a solver rewrite.**
Clay solve is about 25–28% of the sum of these phase medians, and includes shaping/measurement that a Haxe solver would
still need. Encoding alone is comparable to solving; encode plus snapshot plus decode is about twice solve. Moving the
solver into Haxe could remove bridge work but the measurements do not establish that an unimplemented Haxe solver would
outperform Clay or justify replacing its sizing, floating, clipping and text integration. This commit only measures;
neither direction has been started.

Snapshot construction does contain repeated linear searches: resolving a node's baseline searches `out.text_layouts`,
and each Clay render command searches `out.items` for its node. Those can be quadratic as the tree grows. At these sizes,
the entire snapshot phase is only about 0.08 ms per submit, so the searches are not evidence of a dominant quadratic cost
in the current editor. `layout_render_compiler.cpp` contains further snapshot lookups, but runs during rendering rather
than layout submit and is not charged to this measurement. Hashing is about 0.02 ms per submit. Selection's second layout
pass matters: quoting per-submit timings as per-frame timings would understate its cost by roughly half.

With probes disabled, before/after allocation medians (KiB per action) remain within the supplied baseline table:

| action | before | after instrumentation |
|---|---:|---:|
| hierarchy→sensors | 171.9 | 171.9 |
| sensors→hierarchy | 138.6 | 139.4 |
| console→telemetry | 118.2 | 118.2 |
| telemetry→console | 135.6 | 135.6 |
| hover-other | 18.1 | 18.1 |
| hover-field | 29.2 | 29.2 |
| hover-away | 31.5 | 31.5 |
| scroll-inspector | 26.5 | 26.5 |
| idle | 0.2 | 0.2 |
| type-char | 20.1 | 22.1 |
| type-backspace | 22.1 | 22.1 |

These are single budget runs; the typing regression is still present and is investigated separately. Absolute complete
frame times before/after were 1.44–1.89/1.51–2.04 ms for tab transitions, 0.69–0.71 ms for typing, and 3.54/3.64 ms for
selection. This measurement-only change claims no latency improvement. Allocation and latency gates, all ten UI scripts,
all nine retention scenarios, and the compiler suite (608 passed, 0 failed) passed. The first overlapping capture/retention
attempt exhausted disk space; redundant capture bytecode was removed and retention rerun successfully with `TMPDIR=/dev/shm`.

## Bridge work: baseline and selection feedback (2026-10-30)

Remeasured at `8624a138` on this machine before changes, 60 cycles, release runtime, probes enabled, no profiler or
retention verification. These three captures ran sequentially after the build completed. Captures under the outer
repository's `app/build/profiles`: `ui-bridge-before-interaction`, `ui-bridge-before-tab-matrix`, and
`ui-bridge-before-selection-stress`. Redundant captured bytecode was removed; launch logs and timelines remain.

| scenario | active frames | passes/frame | nodes | encode | parse | prepare | Clay solve | snapshot | hash | decode |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| interaction | 354 | 1 | 350–351 | 0.147 | 0.047 | 0.046 | 0.138 | 0.082 | 0.020 | 0.053 |
| tab-matrix | 236 | 1 | 344–485 | 0.155 | 0.048 | 0.057 | 0.181 | 0.082 | 0.020 | 0.086 |
| selection-stress | 59 | 2 | 350 | 0.303 | 0.097 | 0.098 | 0.286 | 0.162 | 0.040 | 0.134 |

### Item 1: the selection pass depends on solved content

A temporary trace at every package `requestLayoutFeedback` call identified `ScrollView`'s vertical `updateScrollbar`
as the requester on every selection frame. Neither ellipsis fitting nor tab/tooltip/popup placement requested a pass.
The trace was removed after diagnosis. The outer editor's `InspectorPanel` creates a new `PropertyInspector` on a selection
revision, keyed by `scene-inspector:<selectedId>`. That inspector owns a fresh `ScrollController` and passes it explicitly
to its `ScrollView`. Its initial viewport and content extents are zero, so its track starts hidden with zero length.

The first solve determines viewport height **535.4263916015625** and content height **724.5** in this fixture. The resolved
content callback publishes those metrics, which establish track length **531.4263916015625** and thumb length
**392.73942754598136**, and reveals the scrollbar. The requested second solve gives those nodes correct geometry, clipping,
hit testing and paint in the same published frame. On subsequent selection changes the inspector identity changes again;
the new controller correctly starts without metrics. The remembered overlay host width alone cannot supply content extent.

This pass is inherent to the current Haxe-owned scrollbar geometry contract: arbitrary inspector content is measured by
native layout, then Haxe writes track/thumb layout inputs from that measurement. It is not redundant state invalidation or
a second view build. Suppressing feedback would publish stale or zero scrollbar geometry. Reusing another selection's
metrics, retaining unmounted inspector trees, or assuming fixed row heights would only predict the answer and still require
feedback for changed content, fonts, viewport or expansion state. Those are not a general solution.

A single solve would require declaring the scrollbar's viewport/content dependency to native layout and resolving its
track and thumb there after content sizing, including offset clamping, overlay-host coordinates, semantics and hit geometry.
That is a new scrollbar layout facility, rather than removal of a redundant submit. Keep the convergence check and both
passes; incremental transactions should make the second pass submit only its actual changes. Item 1 changes documentation
only, so its after measurements are the same as this baseline.

Validation for this checkpoint: all ten UI scripts PASS; all nine retention scenarios PASS with verification every active
frame; performance budgets PASS without ceiling changes; all three 500-cycle memory runs PASS. Compiler sources and
stdlib are unchanged; the compiler suites will also run at the end of the bridge work.

### Item 2: retained native inputs and incremental transactions

The bridge remains inside `packages/ui`; no NativeKit session API outside the package is changed. Clay still solves the
complete tree. API version 23 keeps full transaction version 17 and adds patch version 18 to the same submit entry point.
A patch contains updated 264-byte node records, removed IDs, and ordered child lists for changed parents. Parent ID zero
owns the root. New IDs carry their input records and nonempty child lists. Unchanged records and child lists are absent.
The header validates exact metadata lengths, final node count and a reserved zero before applying anything.

**One dirty classification.** `UiStyleInvalidationMetrics.compare` and `RenderNode.syncRevisions` still decide what changed,
including generated `Structural.changedMask` style differences, text, intrinsic content, hit policy and retained scene
revisions. `LayoutChanges` is reusable transport scratch populated from those decisions, not another style cache or
fingerprint. The encoder walks for membership, order, validation and intrinsic registration, but validates and writes input
records only for changed or new nodes. Successful-submission identity tables are swapped into place and reused by decode;
failed submissions do not advance the Haxe base. The complete encoder remains for first submits, newly created sessions,
explicit full submits, direct callers without retained dirty information, and verification reference builds.

The previous comparison walked the old tree *after* building had detached retained children from it. Those nodes then
looked new despite already being native. `UiContext` now preserves the published frame's complete node index before building.
Two reusable `RenderTreeTopology` tables preserve exact parent IDs and ordered child IDs: live parent/child pointers change
while a builder reparents cached subtrees. This fixes the source of the existing comparison rather than deduplicating its
false positives in another bridge cache. A regression rebuilds a parent around a retained child, requires zero changed
styles and native layout reuse, then reorders the children and requires a native submit matching a full rebuild.

**Retained storage and preparation.** Native owns a stable node slot per live ID, with dense input records in reusable
chunks. Identity, visitation and exported-geometry metadata live outside those hot input arrays. A topology edit rebuilds
an ordered pointer view and materializes its parent indices without copying or moving untouched input records. Child-list edits stay keyed by ID.
Changed records exchange with their old values until solve succeeds; additions and removals commit with the topology.
Malformed packets, duplicate IDs/parents, missing children, cycles, disconnected nodes and failed solves preserve the input
tree and published snapshot. Full submits retain the same atomic behavior. Free slots are reused after unmounting.

Clay preparation retains adjacency, element IDs, intrinsic IDs and floating-layer tables. Style/content-only patches update
intrinsic versions only for changed custom nodes; unrelated inputs reuse these tables. Actual topology changes rebuild the
index-dependent tables, and positioning/overlay/z-order changes rebuild floating layers. Patch topology has already been
validated by the retained-tree traversal, so preparation does not repeat its ID/cycle validation; full/direct engine inputs
still receive the complete validation. Intrinsic measurement ID entries are needed only for Custom nodes.

**Geometry feedback and decode.** Geometry callbacks announce their node edits through the existing `willEditRetained`
prior mechanism before changing input fields. The same comparison classifies these priors for a subsequent incremental
submit. Feedback revisions accumulate with the first pass and are not reset by the final metrics summary. Two reusable
prior slots per announced ID keep an event/input prior alive through that frame's geometry feedback; the cache belongs to
`BuildContext`, is pruned on unmount and cleared on retained-code release. It adds no fields to every `RenderNode`.
The outer document-path popup also announces its geometry edit.

Native compares the 96-byte resolved record with that ID's previous exported record and exports only changed geometry.
Paint remains in the native snapshot; unchanged geometry needs no Haxe paint metadata. The full geometry API is retained.
Updates are repeatable reads, not a consumed queue. Haxe decodes only the returned records, reuses immutable items otherwise,
and assembles tree order using the successful-submission identity index and two reusable result arrays. No per-ID Haxe map
entries are allocated while panels change.

**Verification and intrinsic versions.** With retention verification enabled, every submit also fully encodes its captured
inputs and asks native to compare every node field and parent/order with the retained tree. C++ defaulted equality covers
all input fields, including future additions. The existing retention reference rebuild forces full encoding and preparation
and still compares the rebuilt UI and geometry. Fingerprints and `checkUnannouncedEdits` remain intact.

An intrinsic provider can invalidate itself while measuring or receiving resolved viewport dimensions; the text editor does.
Its version is now captured in the existing `LayoutNode.measureVersion` input during comparison, *after* unannounced edits
are checked. A shared comparison prior is detached before that field changes. The reference encoding checks that captured
input version, not a later external version produced by the solve itself. The next submit samples the provider again and
uses the same dirty path. The low-level session similarly samples attached providers before encoding. A regression changes
a provider's version during measurement, verifies the submitted tree, and requires remeasurement on the next submit.

Native tests exercise 1,201 nodes, paint/geometry/text changes, floating layers, empty patches, identity replacement,
sibling reversal, malformed packets and rollback after a solve failure, comparing complete exported geometry bytes and
native inputs against full submissions. Haxe tests cover 1,101 nodes, unchanged item identity, reordered/added/removed nodes,
root replacement, full resubmission and a deliberately omitted input change which must fail verification.

UTF-8 bytes follow the successful-submission identity index, so changing patch record order does not reallocate unchanged
strings. Empty text shares one byte buffer. The comparison and input-sync walks avoid captured visitors and boxed counters;
the exact typing census falls from 18,552/18,808 bytes (character/backspace) to 18,200/18,456, 352 fewer bytes per action.
The ordinary budget replay reports 17.8 KiB for both. All measured actions remain at or below the fresh baseline allocation.

Same-machine item 2 measurements, sequential 60-cycle captures `ui-bridge-step2-published-{interaction,tab-matrix,selection-stress}`:

| scenario | passes/frame | nodes | encode | parse | prepare | Clay solve | snapshot | hash | decode | bridge sum before → after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| interaction | 1 | 350–351 | 0.020 | 0.001 | 0.003 | 0.136 | 0.081 | 0.020 | 0.010 | 0.293 → 0.034 (−88%) |
| tab-matrix | 1 | 344–485 | 0.048 | 0.034 | 0.022 | 0.184 | 0.085 | 0.020 | 0.045 | 0.346 → 0.149 (−57%) |
| selection-stress | 2 | 350 | 0.097 | 0.052 | 0.023 | 0.285 | 0.164 | 0.040 | 0.063 | 0.632 → 0.235 (−63%) |

Bridge sum is encode + parse + prepare + decode, summed from the independent phase medians. The interaction and tab sums
also beat half of the original table's 0.298/0.335 ms. Solve and hash remain effectively unchanged; the tab solve/snapshot
differ by 3 microseconds from this session's baseline. Snapshot's linear searches remain for item 3. Probe-off allocations
(KiB, fresh baseline → incremental): hierarchy→sensors 169.4→164.9, sensors→hierarchy 135.5→129.0, console→telemetry
112.8→112.5, telemetry→console 132.8→130.5; hover-other 13.1→13.1, hover-field 25.6→23.9, hover-away 26.8→24.9,
scroll-inspector 22.9→22.3; typing 17.8→17.8. No budget ceiling changed.

Validation: all ten UI scripts PASS, all nine every-frame retention scenarios PASS, performance budgets PASS, all three
500-cycle memory runs PASS, native layout invariants/render compiler/session tests PASS, compiler suites 608 passed,
0 failed. The missing-delta and rejected rotated-clip diagnostics in the regression tests are intentional negative cases.

### Item 3: indexed snapshot lookups

Snapshot construction builds two reusable flat indices once per snapshot: node ID → output-item index, and node ID → first
text layout with a baseline. Geometry and Clay-command resolution use these indices instead of scanning text layouts or
items. The first-match rule matches the former linear searches, including multiple measured text layouts for a node.
The table uses open addressing at at most half occupancy, accepts 64-bit text-layout IDs, and retains its capacity between
frames. No node-owned hash entries are allocated. IDs are nonzero by the existing layout contract.

The render compiler had the same text-layout scan and four `snapshot.find` call sites, some repeated for every primitive.
It now builds item and text-layout indices in reusable `LayoutRenderFrame` scratch. Parent traversal reads the indexed
item's parent ID, eliminating a separately allocated parent-ID map. Snapshot order, primitives, clipping and paint order
are unchanged. The general `LayoutSnapshot.find` helper remains available for occasional callers outside these loops.

`nativekit_ui_layout_snapshot_index_test` compares indexed output with a separately compiled, test-only linear-search
engine. Both engines use the same implementation except for the two lookups; production has no runtime bypass. Defaulted
C++ equality compares every snapshot payload field (including text bytes, lines, baselines, geometry, transforms, clipping,
primitives and paint order). Every exported 96-byte resolved record is also compared with `memcmp` through the same encoder
used by the C API. The test covers 1,201 nodes / 600 labels over 104 frames, including text/transform changes, floating
layers and clipping. Index regressions cover growth, collisions, first-match duplicates, missing IDs, reset and 64-bit IDs.
The regression runs in `test-haxeon-layout.sh` and is registered with CTest, including sanitizer builds.

Paired native measurements on this machine, probes enabled, 4 warmup frames then 100 samples per engine: median snapshot
**0.425 ms linear → 0.178 ms indexed (−58%)** at 1,201 nodes. This compares the former searches with the indexed path in
one process, alternating engines so both have the same warmup and fixture. Reproduce with:

```sh
cmake --build out/packages/ui/native --target nativekit_ui_layout_snapshot_index_test
HAXEON_UI_LAYOUT_COST=1 out/packages/ui/native/nativekit_ui_layout_snapshot_index_test > /tmp/snapshot-index.log 2>&1
```

The `snapshot-index engine=… frame=…` markers identify the following `layout-cost backend` record; omit frames 0–3 and
take the median `snapshot` value independently for each engine. The saved paired log is
`/home/joao/dev/materia-cache/claude-scratch/ui-bridge-evidence/snapshot-index-reference.log`.

Final same-machine measurements: three fixed sequential 60-cycle repeats after the compiler run completed. Captures are
`ui-bridge-final-{interaction,tab-matrix,selection-stress}` and `ui-bridge-final-r{2,3}-{interaction,tab-matrix,selection-stress}`.
Use the report command above for each capture. The after rows below take the median over all active frames from all three
repeats (1,062 / 708 / 177 frames), using that tool's `read_submissions` and `frame_costs`; no repeats are discarded. The
first interaction repeat had a cross-phase timing spike; retaining it makes this table more conservative than the earlier
single final capture. Baseline remains the original sequential 60-cycle run. Phase medians in ms per active layout frame
(selection still sums two submits):

| scenario | passes/frame | nodes | encode | parse | prepare | Clay solve | snapshot | hash | decode | bridge sum |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| interaction before | 1 | 350–351 | 0.147 | 0.047 | 0.046 | 0.138 | 0.082 | 0.020 | 0.053 | 0.293 |
| interaction after | 1 | 350–351 | 0.020 | 0.001 | 0.003 | 0.142 | 0.076 | 0.020 | 0.012 | 0.036 |
| tab-matrix before | 1 | 344–485 | 0.155 | 0.048 | 0.057 | 0.181 | 0.082 | 0.020 | 0.086 | 0.346 |
| tab-matrix after | 1 | 344–485 | 0.051 | 0.034 | 0.022 | 0.184 | 0.077 | 0.020 | 0.048 | 0.155 |
| selection-stress before | 2 | 350 | 0.303 | 0.097 | 0.098 | 0.286 | 0.162 | 0.040 | 0.134 | 0.632 |
| selection-stress after | 2 | 350 | 0.101 | 0.056 | 0.027 | 0.296 | 0.156 | 0.040 | 0.067 | 0.251 |

Bridge work falls 88% / 55% / 60%. Snapshot improves in all three scenarios; hash is unchanged to the displayed precision.
Solve code is unchanged. Its combined medians are 4 / 3 / 10 microseconds higher than the single baseline; individual final
repeat medians span 0.137–0.206 / 0.182–0.191 / 0.285–0.311 ms. These small aggregate differences sit within substantial
wall-clock run variation; the measurements do not establish a solver regression, and should not be read as a solver speedup. Probe-off final allocation
medians (KiB) are 165.1 / 127.0 / 112.5 / 132.5 for the four tab actions, 13.1 / 23.9 / 25.0 for the three rebuilding
hovers, 22.3 for inspector scroll and 17.8 for both typing actions. Every action remains at or below the fresh baseline,
including idle and pointer-only actions. Budget ceilings are unchanged.

Final validation: all ten UI scripts PASS (the snapshot regression is included in haxeon-layout); all nine retention
scenarios PASS; performance budgets PASS; all three 500-cycle memory runs PASS; native invariants, render compiler,
snapshot index and transaction tests PASS; compiler suites **608 passed, 0 failed**. The final compiler run's GC owner
stress test was slow (the native child remained active), then completed normally; no runtime or test changes were made.
Verification checks and all budget ceilings remain unchanged.

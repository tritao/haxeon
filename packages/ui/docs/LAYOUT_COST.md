# Layout submit cost

`HAXEON_UI_LAYOUT_COST=1` enables per-submission timing records in the process output. It is off by default: the
setting is read once and disabled probes neither read a clock nor format output. Times are seconds, measured with
`Sys.time()` in Haxe and `steady_clock` in native code. Each successful submit emits backend, native and Haxe records,
with a node count in each and the encode start timestamp in the Haxe record. Clean frames that reuse the submitted layout emit no records.

The measured boundaries are:

- `encode`: `LayoutTransaction.encodeInto`, including its tree walk, validation, string table and record writes.
- `parse`: native transaction decoding into `LayoutNode`s.
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

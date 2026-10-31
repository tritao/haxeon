# Render cost and incremental compilation

## Measurement boundary

The editor's ordinary headless performance scenarios stop after `EditorSession.submit`. They measure build and layout,
not painting, render-plan construction or GPU submission. Their frame medians must not be used as complete render times.
`profile-editor.py --render-ui` additionally submits the UI to a temporary mapped OpenGL window from its on-demand
surface frame callback. It uses the same editor fixture, dimensions and actions, without rendering the 3D viewport.
`render-timeline.jsonl` records render CPU time, callback wait and the complete submit/render interval separately.
The interval excludes input dispatch, profiler serialization and presentation after the callback returns. GPU submission
is measured; GPU completion is not. Waiting for a frame callback is not render CPU work.

The framebuffer must reach the requested 1320×900 logical size at the window's reported scale before capture starts.
An unmapped GTK surface can report a 1×1 framebuffer. Drawing outside the frame callback also repeatedly acquires the
GTK framebuffer and produces misleading driver cost. The harness rejects the former and avoids the latter. The stream
buffer pixel test now runs inside that callback too; its pixel, memory-budget and recovery assertions are unchanged.

`HAXEON_UI_RENDER_COST=1` enables probes, off by default. Disabled probes do not allocate, read clocks or format records.
Haxe uses `Sys.time`; native durations use `steady_clock`, with a wall timestamp for frame association. Native frontend,
executor and worker records share a diagnostic frame ID; the worker uses the existing submission ticket. This is diagnostic
correlation only, not scene change tracking. One record is written after each measured scope. Probe output itself costs
CPU time, so use probe-off captures for final speed comparisons and allocation gates. Verification performs extra work
and is excluded from timing runs.

```sh
# From materia; repeat for tab-matrix and selection-stress.
TMPDIR=/dev/shm HAXEON_UI_RENDER_COST=1 HAXEON_UI_LAYOUT_COST=1 \
  python3 app/tools/profile-editor.py --scenario interaction --cycles 30 \
  --render-ui --no-profile --output-dir /dev/shm/ui-render-interaction
python3 haxeon/packages/ui/tools/report-render-cost.py \
  /dev/shm/ui-render-interaction/launch.log --json /dev/shm/ui-render-phases.json
python3 haxeon/packages/ui/tools/report-layout-cost.py /dev/shm/ui-render-interaction/launch.log
```

Subsequent captures can use `--skip-build`. A working display is required. Use the same hardware display for comparisons;
software rendering under Xvfb is useful for pixel tests, not comparable GPU performance. The report excludes initial,
setup, warmup, verification and cycle-zero frames, using the same rules as the layout report. It rejects missing probes,
failed renders and mismatched timelines. Only frames actually rendered are included. Reused idle submissions skip GPU
work. Individual phase medians need not add to the median of their sum.

## Phase coverage

- Submit: build/style/reconciliation up to native layout, layout bridge including the resolved snapshot, and other submit
  work. Feedback passes emit separate records, summed into their enclosing host frame.
- Haxe render: paint walk, custom-paint callbacks (decorations and renderable content included), display-list encoding,
  renderable-content updates and the native call. Encoding inside a custom callback is subtracted from callback time.
- Native frontend: acquire/locks, custom-list composition/cache lookup, whole-plan reuse checks, layout primitive-to-plan
  compilation, resource binding/publication, atlas uploads/backend initialization, sealing and execution/enqueue.
- Executor: schedule, frame begin, external dependencies, draw/pass execution, frame end/GPU submission. The layout
  compiler writes directly to a render plan; there is no separate layout-wide display list to time. Custom display lists
  are timed both when encoded in Haxe and when composed natively.
- Physical render worker: context bind, backend setup, atlas upload, execute, cleanup and completion dispatch. GTK aliases
  render execution onto the platform executor, so these worker phases are zero on this machine. A nested producer plan
  is already included in its outer executor interval and is not added twice.

Haxe `paint_other` excludes callbacks, encoding and the native call. Native acquire includes its initial synchronization;
`resources` includes binding retained/custom resources. `other` in the full frame is the residual after build, layout and
render, including diagnostics and host bookkeeping. It is not a proposed optimization target without further attribution.
See [LAYOUT_COST.md](LAYOUT_COST.md) for the encode/parse/prepare/solve/snapshot/hash/decode boundaries inside layout.

## Same-machine reconnaissance baseline

Captured after the retained panels and controls, before render behavior changes: Haxeon runtime sources from `70c42495`
(with later concurrent documentation-only commits), Linux GTK, NVIDIA GeForce GTX 1060 3GB, driver 550.144.03,
OpenGL 4.6, scale 1. Thirty cycles per scenario, no sampling profiler. Captures live in materia's ignored
`app/build/profiles/ui-render-*` directories; bytecode copies are removed after inspection. The native/Haxe baseline
artifact hashes and GPU information are in `ui-render-before-gates`. The three `ui-render-gpu-before-*` captures are
probe-off; `ui-render-cost-before-*` contain both cost probes. Their timelines and logs are retained as evidence.

Probe-off CPU medians (ms), after warmup:

| Scenario | Native render | Complete Haxe render | Active submit + render |
|---|---:|---:|---:|
| interaction | 2.382 | 2.604 | 3.490 |
| tab-matrix | 2.322 | 2.699 | 4.498 |
| selection-stress | 2.136 | 2.688 | 7.158 |

Full breakdown with probes enabled (ms):

| Scenario | Build | Layout | Render | Other | Active frame | Callback wait | Wall frame |
|---|---:|---:|---:|---:|---:|---:|---:|
| interaction | 0.213 | 0.687 | 2.577 | 0.090 | 3.545 | 12.738 | 16.301 |
| tab-matrix | 0.767 | 0.930 | 3.153 | 0.926 | 5.739 | 10.309 | 16.143 |
| selection-stress | 3.387 | 1.174 | 2.883 | 0.795 | 7.799 | 11.487 | 18.809 |

Render breakdown with probes (ms):

| Phase | interaction | tab-matrix | selection-stress |
|---|---:|---:|---:|
| Custom callbacks | 0.005 | 0.084 | 0.128 |
| Haxe display-list encoding | 0.012 | 0.035 | 0.046 |
| Other Haxe paint work | 0.172 | 0.253 | 0.317 |
| Acquire | 0.011 | 0.011 | 0.012 |
| Custom plans | 0.034 | 0.037 | 0.038 |
| Layout plan compilation | 0.470 | 0.503 | 0.458 |
| Resource binding | 0.056 | 0.098 | 0.081 |
| Atlas/backend | 0.002 | 0.002 | 0.002 |
| Seal | 0.003 | 0.003 | 0.002 |
| Executor schedule | 0.003 | 0.003 | 0.003 |
| Executor begin | 0.001 | 0.001 | 0.001 |
| Dependencies | 0.001 | 0.001 | 0.000 |
| Draw commands/passes | 1.269 | 1.413 | 1.238 |
| Frame end/submission | 0.499 | 0.550 | 0.499 |

There are 174/116/29 measured rendered frames respectively, about 315–316 primitives and 180–181 commands in four
passes. No whole-plan reuse occurs: this cache currently serves the physical render worker, and these are changed frames.
Render work dominates interaction and tab frames. Selection's largest cost is build; it still also pays for rendering.
Native plan compilation is only about one sixth of render time. Eliminating it alone cannot halve total render work.
The executor and streaming-resource path therefore need measurement alongside incremental compilation.

A preliminary direct-execution experiment used the executor's existing non-recording path. Its first short interaction
run appeared faster, but a longer tab run did not reproduce the gain. The experiment was reverted. No speedup is claimed
from changing the execution policy or from correcting the capture harness.

## Incremental design

The authoritative inputs already exist: retained node identity/topology, content/geometry/composite revisions and changed
resolved records. Consume those inputs; do not add another scene fingerprint or an independent dirty-node walk. A local
geometry revision alone is insufficient: an ancestor resize, transform or scroll can move a node without changing its
local style. Resolved-record changes must invalidate that node's compiled geometry and clip.

Keep resource-free command templates and immutable prepared resources per node. Compose them in the snapshot's existing
paint order; unchanged nodes reuse their segments. Clip and effect nesting are structural boundaries, not arbitrary
subtree slices. Reparenting, removal and changed pass boundaries must rebuild composition while preserving unaffected
node resources. Custom painters already have revision-keyed display-list plans; preserve that mechanism.

Frame-local resource slots are assigned during composition in the same order as a full compile. A cached command template
must not retain a slot belonging to a different frame. Prepared text is reusable only while its existing layout, font and
atlas publication generations remain valid; settle atlas preparation before publishing UVs. Keep the existing conservative
full path for unversioned native clients, the first frame, reset and reference compilation.

An inline frame can borrow retained segment resources while the session lock is held. Only submissions crossing the
physical render boundary need immutable sealed ownership. Reuse producer plan storage and executor scheduling/stream
buffers without mutating data a worker still owns. Persistent compiled segments must release removed-node resources and
respect the current streaming memory budget and recoverable allocation failures.

Verification must construct a separate full reference output without reading or modifying incremental caches. Compare
canonical command/pass bytes and prepared path/glyph payload bytes, with deterministic frame-local slot assignment;
exclude pointer values, capacities and C++ padding. Hash equality is insufficient. Retention verification must select this
comparison as well as its existing full tree/layout checks. A mismatch reports the canonical byte offset and output sizes; GPU payload mismatches also identify the node/pass/command.
This preserves the current fingerprints and unannounced-edit checks.

The measurement checkpoint introduced no execution-policy change. The implementation below follows that checkpoint;
its final measurements and validation are recorded separately.

## Measurement checkpoint validation

All ten UI scripts pass, all nine editor retention scenarios pass, strict budgets pass, and the compiler driver reports
608 passed / 0 failed. Three 500-cycle memory runs pass, with post-warmup growth 5.31 / 5.62 / 6.41 MiB, two workspace
listeners and 148 widget resources throughout. The stream-buffer pixel test and layout-render-compiler test pass.
The layout report produces identical output before and after sharing its frame-association helper.

With probes and GPU rendering disabled, exact allocation census is unchanged from the control commit for every replayed
action. Thirty-cycle tab medians (first three cycles omitted) remain 165168 / 130120 / 115056 / 133944 bytes. Interaction
medians remain 1728 / 1728 / 13592 / 22080 / 23584 / 19336 / 880 / 18152 / 18408 / 880 bytes in the harness's action
order. Selection's measured submit-phase sum remains 868496 bytes under the same exclusion rule. Coarse TLAB accounting
moves slightly between runs and is not evidence of an allocation change. No ceiling is raised. Evidence is retained in
`app/build/profiles/ui-render-measure-{census-*,memory,budgets,actions,gates}`, without bytecode copies.


## Retained compiler and executor

`LayoutRenderFrame` owns command templates and immutable prepared paths/glyphs by node and text-line identity. The native
resolved-record exporter is also the renderer's geometry invalidation source: when that existing comparison publishes a
changed record, it invalidates that node's segments. Removing a retained node releases its segments. Full transactions
clear them. Content, geometry and composite revisions reject other changed inputs; zero revisions retain the conservative
full path. Raster-plane placement, clipping and pixel scale are compilation inputs, compared exactly. Composition still
visits the snapshot's paint order and effect boundaries, assigning the same transient slots as a full compile.

The atlas preparation pass can reuse already prepared lines while the text engine's existing layout/line/grid, font and
atlas publication metadata match. If a newly prepared label changes the atlas after a reused label was visited, all current lines are
settled before publication. Cached commands and snapshots are never patched in place. Resource generations include pixel
scale, since a prepared path's device geometry changes with scale even when its logical primitive is unchanged.

The inline path keeps its plan and owned resource bindings in the session under its lock. Only cross-executor submissions
seal ownership. The existing whole-plan input/dependency cache now works with either a borrowed inline frame or a sealed
worker frame; verification forces compilation. No additional scene hash or dirty-node tracker was introduced.

Plan command-vector capacity and frame binding slots survive ordinary inline frames. A binding-table reset immediately
expires every old value and releases owned resources; unused table slots are pruned on the following reset. The table's
frame stamp describes binding lifetime only and does not classify scene changes. This replaces per-frame hash-node
allocation without allowing a stale lookup to succeed.

The executor begins a real GPU frame and finishes live surface producers immediately. It then encodes owned plan commands
into a reusable per-pass byte buffer and submits that stream once per pass. It does not construct a second sealed GPU
frame batch. Standalone immediate and explicit sealed-batch renderer modes remain available and retain their tests.

### GPU geometry and command fragments

Versioned native path and glyph commands can retain their converted vertex/index data. Keys consume the compiled resource
generation and actual placement/pass dimensions; they are backend resource-cache keys, not another UI invalidation
scheme. Custom paths use their existing immutable path/paint identities, tessellation key and retained scene owner as well.
Textured paths and unversioned commands keep the existing streaming path. Atlas identities/generations remain
part of glyph material validation.

Geometry occupies reusable 64 KiB vertex/index pages. Dirty pages upload once, between passes, before any plan draw. The
cache uses at most the smaller of 4 MiB, a quarter of the existing stream budget and the currently available budget;
stream allocation accounts for its pages. Entries used by the current frame cannot be evicted. A version must appear in two frames before it receives GPU pages;
one-frame custom paths stream normally. Admission uses the same bounded version entries and does not add scene revisions.
Old versions use bounded
LRU eviction; oversized meshes and a full cache fall back to streaming. CPU shadows, free ranges and GPU buffers remain
owned by the renderer and are released with it.

This deliberately uses whole-page dynamic updates. NativeKit's arbitrary-range update currently copies the complete
shadow buffer for a partial write, and a second update in the same frame can replace the underlying Sokol object.
Coalescing all changes to one page upload avoids both behaviors without changing the GPU API or increasing its budget.

Each entry also retains its encoded GPU command fragment. The executor copies that fragment into the current pass buffer
instead of rebuilding every binding/uniform record. A changed atlas image binding rebuilds the fragment. Vertex/index
ranges stay valid until their entry is evicted, and shader/material resources retain their normal renderer ownership.

### Verification

`HAXEON_UI_VERIFY_RETENTION=N`, for positive N, additionally enables native comparisons on rendered frames. The existing
Haxe full rebuild, transaction comparison, fingerprints and unannounced-edit checks are unchanged. Native verification
compiles a separate full frame without using the segment cache and compares canonical pass/command and prepared resource
bytes. Addresses, capacities and C++ padding are excluded; float bit patterns, including signed zero, are preserved.
Cached GPU mesh payloads are compared with fresh preparation, and retained command fragments with fresh encoding.
Any difference fails rendering. Whole-plan reuse is bypassed while these comparisons are enabled.

`HAXEON_UI_VERIFY_RENDER=1` runs the native comparisons independently. This is useful for exercising cache hits across many
editor actions: the Haxe retention verifier intentionally installs its full reference rebuild in the live session, which
can clear primitive segments. Both modes are tested; the render-only setting does not disable any retention checks.

Native tests deliberately omit a geometry invalidation and require the byte comparison to reject the stale segment.
They also cover signed-zero differences, binding expiration/storage reuse, bounded geometry allocation, eviction without
corrupting current-frame entries, stream page rollover, raster recycling, pixel output, allocation failures and recovery.
Renderer pixel fixtures execute inside a full-sized surface frame callback, where their framebuffer remains valid through
readback. Their pixel/resource assertions remain intact.

### Measurement controls

The display must be awake. On this machine, DPMS turning the monitor off throttled GTK callbacks to about one per second;
those captures are diagnostic only. Window activation alone does not wake the display. Record DPMS state and CPU affinity
with the capture, and keep both constant for a paired comparison. `capture.json` records affinity. The controlled runs use
CPUs 8 and 9, on the same physical core, for both variants. Probe-off captures determine final speed comparisons; probes
explain where work remains. The shared machine also runs unrelated compiler jobs, so repeat measurements rather than
attributing changes in unrelated build/layout intervals to the renderer.

The existing resolved-node traversal publishes a filtered painter/cache-policy index alongside `submittedNodes`.
The paint pass visits that reused sequence rather than recursively checking every structural node again.
It is derived during the same traversal, not maintained by a separate dirty-node scheme.
A node caches its complete local paint fingerprint in the storage previously used for its prefix. Existing content
revision changes, callback reconciliation and routed state updates invalidate it. This removes repeated fingerprint
strings without adding node fields or a second change classification. Framework tests cover hover, decoration style,
callback additions and explicit paint invalidation.

Before submitting a pass, the UI executor removes identical pipeline, uniform, image, sampler, buffer and scissor state
records. Draw order is preserved. A pipeline change invalidates remembered uniforms and index state; graphics images and
native images share a binding slot but retain distinct record types. Unknown records conservatively reset remembered
state. This is pass-local GPU state compaction, not retained scene invalidation. Pixel tests compare immediate, sealed
and encoded modes, and a native boundary test checks shader changes, image types, draw preservation and malformed records.

## Controlled before/after result

The reconnaissance runs above were taken under different shared-machine load and are not the denominator for the final
speedup. A later run of unchanged baseline sources was already substantially faster. The controlled comparison rebuilds
both the native library and Haxe bytecode from the measurement checkpoint (`bc32f057`) and the retained implementation,
using the same profiling host, CPU affinity 8/9, scale 1 and awake hardware display. Four rounds interleave before/after,
30 cycles per scenario per variant. No sampling, allocation census, verification or cost probes are enabled. Each capture
records the bytecode and native-library SHA-256. Initial/setup/warmup/cycle-zero frames are excluded consistently.

Pooled rendered-frame medians over all four rounds, ms:

| Scenario | Native before | Native after | Complete render before | Complete render after | Render reduction | Active frame before | Active frame after |
|---|---:|---:|---:|---:|---:|---:|---:|
| interaction | 1.145 | 0.489 | 1.266 | 0.556 | 56.1% | 1.876 | 1.183 |
| tab-matrix | 1.425 | 0.722 | 1.624 | 0.914 | 43.7% | 3.188 | 2.556 |
| selection-stress | 1.198 | 0.592 | 1.472 | 0.831 | 43.5% | 4.835 | 4.308 |

Per-round complete-render median ranges are 1.221–1.426 → 0.531–0.618 ms for interaction,
1.571–1.783 → 0.883–0.933 ms for tabs, and 1.412–1.546 → 0.767–1.091 ms for selection.
These are CPU submission measurements, not GPU completion or window-presentation latency.
The 50% complete-render target is reached for interaction and remains unmet for tabs. Native tab time falls 49.3%.
No larger speedup is claimed from the slower reconnaissance baseline.

Exact headless allocation census remains unchanged from the controls checkpoint for all ten interaction actions,
all four tab actions (165168 / 130120 / 115056 / 133944 bytes), and the selection submit-phase median (868496 bytes),
with the first three cycles omitted for these allocation comparisons. GPU paint allocations fall for every measured
action; for example inspector scroll is 5960 → 2744 bytes and telemetry→console is 11912 → 8696 bytes.
Those GPU figures include the Haxe custom-paint and native-call allocation counters, not C++ allocator internals.
No ceiling is raised. Existing headless ceilings cannot be lowered from render-only savings.

Evidence is retained under materia's ignored `app/build/profiles/ui-render-retained-*` captures, with bytecode removed.
The runtime manifest identifies each before/after artifact. The final per-pass submission probe was added after these
timings and is disabled in ordinary runs; it separates packed-stream compaction from NativeKit replay.

Final attribution with probes enabled (independent medians, ms; not the probe-off speed comparison):

| Scenario | Build before → after | Layout before → after | Render before → after | Other before → after | Active frame before → after |
|---|---:|---:|---:|---:|---:|
| interaction | 0.126 → 0.143 | 0.413 → 0.440 | 1.336 → 0.595 | 0.063 → 0.066 | 2.010 → 1.246 |
| tab-matrix | 0.413 → 0.480 | 0.515 → 0.638 | 1.533 → 0.956 | 0.563 → 0.585 | 2.956 → 2.659 |
| selection-stress | 2.443 → 1.843 | 1.226 → 0.984 | 2.199 → 0.859 | 0.934 → 0.797 | 6.792 → 4.533 |

The final tab capture attributes 0.158 ms to layout-to-plan compilation, 0.060 ms to resource binding,
0.021 ms to geometry preparation, 0.066 ms to custom callbacks, 0.020 ms to Haxe encoding and 0.101 ms to other
Haxe paint work. Executor pass execution is 0.381 ms, including 0.192 ms inside NativeKit packed-command replay
and 0.012 ms in pass-state compaction. These nested medians must not be added as independent phases.
At the median tab frame, 101 primitive segments are reused and 20 compiled; 166 GPU command groups are reused
and 16 prepared/streamed. The measured geometry cache occupies 884736 bytes, within its existing shared budget.
Selection's largest remaining phase is building, about 1.843 ms; its render phase is 0.859 ms with probes enabled.

## Remaining renderer API boundary

The UI now retains prepared primitives, command templates, converted geometry and encoded fragments. Replaying those
fragments still enters NativeKit for every pass. On NativeKit `36aea98175c69b208606d12d1952dfa27f0a1c3b`,
`modules/gpu/src/adapter.cpp::nkgpu_submit_commands` parses every record and calls `submit_command`, which resolves handles
and applies backend state/draws again. Existing sealed batches also call this same replay path from `nkgpu_batch_submit`.
They retain ownership, but are not pre-resolved backend command bundles. Buffer-range updates already suffice for the
UI page cache; they are not the missing capability.

The next clean design is an opaque, reusable GPU bundle API owned by NativeKit's GPU module:

- Build a bundle from an owned packed command segment, validate it and retain its referenced resources once.
- Submit an ordered list of bundle references plus changed segments inside the existing acquired frame/pass transaction.
  Bundles carry complete state; live producers and callbacks finish through the existing dependency path first.
- Let the backend own resolved bindings, compatible draw batching and invalidation when dynamic updates replace backing
  objects, atlas images change, a context/device is lost, or a referenced resource is released. UI supplies its existing
  resource generations and retained scene revisions; it does not duplicate that backend lifetime state.
- Account bundle storage and pinned resources in the existing budgets. Keep the full recording/replay path for first
  frames, resets, unsupported backends and reference verification.
- In verification, expand retained bundle streams and compare their bytes with fresh full recording, alongside the current
  full plan/prepared-payload checks. Hash equality is insufficient. Profile bundle compilation and replay before claiming
  that this API reaches the remaining tab target.

This requires changes to NativeKit's GPU API and backend resource ownership outside `packages/ui`. Following the requested
renderer API boundary, this work stops before implementing it. The retained implementation and this design are committed;
the unmet tab target is reported explicitly. Trials of generic mesh batching and zero-offset page/draw coalescing were
pixel-correct but did not establish a repeatable timing gain, so they are not included.

## Retained implementation validation

All ten UI scripts, all nine retention scenarios, strict editor budgets and three independent 500-cycle memory runs pass.
The compiler driver reports 622 passed, 0 failed. Native backend, stream-buffer, frame-resource, layout-compiler, public
renderer, session renderer, stress and moving-row tests pass. GPU captures additionally pass both retention verification
on every frame and independent native render verification across cache hits. Fingerprints, unannounced-edit checks,
full layout comparisons and allocation ceilings remain intact.

The final diagnostic capture encountered a full shared root filesystem and an asleep display. Those incomplete captures
are excluded; temporary artifacts were moved to tmpfs, and final attribution was repeated with the display awake.

### Validation after the upstream compiler rebase

Before publication, main gained `c7704d86`, `24686ab8` and `ecd34e1e`. Their conservative pretyping of receiver mutations
introduced false nullable-capture diagnostics in existing Tabs/editor callbacks and extra capture-cell allocations.
The fix refines storage candidates when their actual type is known: receiver-only mutations of references need no cell;
mutable values retain shared storage. Whole-binding assignments, recursive functions and unknown/abstract receiver types
keep conservative storage and flow effects. Known receiver mutations preserve binding presence; actual nullable assignments
and changes to nullable child fields still invalidate their checks. No caller casts or nullable-check bypasses were added.

Compiler tests cover inferred class/interface/container references without extra cells, mutable-value and reassigned-reference
cells that must remain, valid reference/value mutations and rejection of real null reassignments. All 622 compiler tests,
ten UI suites, nine retention scenarios, strict budgets and three 500-cycle memory runs pass after this fix. A fresh exact
census restores every interaction/tab/selection number above with no allocation regression or ceiling change.
The interleaved render timing table deliberately uses the matched pre-rebase compiler for both variants; the later compiler
integration is validated separately and is not credited as render speedup. Post-rebase evidence is stored in
`ui-render-retained-rebased-*` and `ui-render-retained-gates` under the outer profiles directory.

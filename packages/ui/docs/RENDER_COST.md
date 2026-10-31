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

## Same-machine baseline

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
comparison as well as its existing full tree/layout checks. A mismatch fails with the node/pass/command that differs.
This preserves the current fingerprints and unannounced-edit checks.

Implementation and final before/after results remain pending. The measurement commit introduces no incremental-output
claim and makes no renderer execution-policy change.

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

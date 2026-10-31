# Retained subtrees

## Editor coverage baseline (2026-10-30)

Before extending retention to the remaining five panels, remeasured `72a75ee8` with the outer repository at
`47159e089` on this machine (2026-10-30). `check-editor-performance.py --budgets --measure` used probes off;
all measured actions are within their existing ceilings. A separate `TMPDIR=/dev/shm python3 app/tools/check-ui-retention.py --skip-build` passed all nine scenarios. Measurement mode itself skips that verification gate.
These are the starting measurements, not results of the pending panel or render changes.

| action | baseline allocation KiB | baseline frame ms |
|---|---:|---:|
| hierarchy→sensors | 165.1 | 1.70 |
| sensors→hierarchy | 129.0 | 1.35 |
| console→telemetry | 112.5 | 1.16 |
| telemetry→console | 130.7 | 1.22 |
| hover-other | 13.1 | 0.42 |
| hover-field | 23.9 | 0.43 |
| hover-away | 25.0 | 0.43 |
| hover-enter / hover-inside | 0.6 | 0.00 |
| scroll-inspector | 22.3 | 0.72 |
| type-char | 17.8 | 0.43 |
| type-backspace | 17.8 | 0.42 |
| idle / idle-focused | 0.2 | 0.00 |
| selection | not reported | 3.05 |

Captures in the outer repository: `app/build/profiles/budget-tab-matrix-20261030-190150-0`,
`budget-interaction-20261030-190152-0`, and `budget-selection-stress-20261030-190154-0`.
Their timeline, action and allocation records are retained; redundant captured bytecode was removed to save disk.

## Current model (2026-10-30)

A frame rebuilds the view by default. Work is skipped in three ways, and one check keeps all of them honest.

**Retained caches** reuse a built subtree: `RetainedView`, and in `DockWorkspace` the pane and panel caches. A cached subtree
is reused while all of these hold:

- its optional key matches (a `RetainedView` revision, a panel's `cacheKeyHash`, plus style revision and viewport);
- the widget states its build read have the same revisions (`stateIdsUsedSince` / `stateRevisions`);
- every value it read through `BuildContext.observeInt`, `observeBool` or `observeString` reads the same again (`Dependencies`);
- the interaction state of nodes a widget built from interaction state is unchanged (`InteractionStateSnapshot`; hover is
  ignored where no stylesheet rule matches it, and widgets that update themselves are left out).

Prefer observing to keys: `context.observeString(() -> session.label())` returns the value and records the read, so a
dependency cannot be left out. `CommandButton` observes its command's presence and enabled and checked states. The editor's
top and status bars have no keys; panel contents still use `cacheKeyHash`.

**In place** changes without rebuilding the view. A widget's own rebuild goes through one step, `RenderNode.reconcile`; the other two ways
are edits that have no build to reconcile.

- `BuildContext.selfUpdating(id, build)`: the widget rebuilds alone, on a pointer change over it or when it asks
  (`requestPatch`, after `State.updateQuietly`; `TextField` does), and the result is reconciled with the node it built before.
  The node stays. A rebuild replaces what the builder made on it and nothing else:
  - style: only the properties that differ between the two builds (`haxeon.Structural.changedMask`/`assignChanged`), so a
    style change a caller made after build stays;
  - computed style, interaction state, and semantics (unless the caller replaced them);
  - the listeners, outside-pointer, geometry and paint callbacks and decorations the builder made (counted when it returned
    the node, `BuiltNode`); the ones callers appended after stay behind them;
  - the children the builder made, each swapped in place for its new build; children callers added stay where they are.
  Properties that come from the widget instance (focusable, enabled, cursor, tab index) are not reapplied. A build whose node
  changed kind cannot be reconciled and replaces the node (`replacedBy`, followed by the caches that held it), without what callers
  added; the root of the whole tree is left to the next full build. `Button`, `IconButton`, `Checkbox`, `Toggle`, `Radio`,
  `TextField`, `Slider`, `ProgressBar`, `Tabs` and `SelectionPopup` use it. A widget qualifies when its build makes the same kind of node every time.
  A closure that captures its build root calls `RenderNode.latest(root)` when it needs the node: reconcile forwards that
  discarded build root to the instance kept in the tree. Descendant captures remain valid because the built children are
  swapped into the tree.
  Children are swapped rather than patched field by field because the new build's closures refer to the nodes it made
  (`TextField`'s pointer handlers read `textNode.resolved`), so those must be the ones in the tree; a hand-kept list of node
  properties to copy would also go stale with every new one.
- Hover never needs a flag: `BuildContext.hoverRebuilds` says hover alone matters to a node only if a stylesheet rule matches it
  on hover (or it belongs to a self-updating widget, which follows it itself). Otherwise caches ignore it and a node that
  paints from live state (`TreeView` rows) is repainted by the frame (`UiContext`: `patchFramePaintNodes`). A widget that does
  more with hover than resolve its style must update itself.
- `BuildContext.willEditRetained(node)` before changing a node of the submitted tree directly (scrollbar fades, scrolled
  content, fitted text): the next frame compares it with how it was and lays it out without a rebuild. Animations whose frames
  only do this implement `RetainedAnimation` and do not count as rebuild work. This stays a separate mechanism because there is
  no build to reconcile: a scroll offset or a fade changes every frame from a controller, and rebuilding the widget (and its
  state) for it would cost far more than the edit; what it shares with `reconcile` is the stand-in of how the node was, which
  the frame comparison needs.

A frame where only these happened runs as a patch frame: the submitted tree stays, only the reconciled widgets and edits are
applied and the view is not built. That is how `requestPatch` and pointer changes are scheduled, not another way to update: it
exists because skipping the view build is where the saving is, so `selfUpdating` widgets cost one build each per frame.

**Verify mode** is the safety net: `UiContext.verifyRetention` builds the view again with every cache, patch and edit
bypassed and compares the trees. `verifyRetentionEvery` or `HAXEON_UI_VERIFY_RETENTION=N` runs it every N frames that did work
and throws on a difference; `app/tools/check-ui-retention.py` runs the editor scenarios that way. While it is on, every node
is also fingerprinted at the end of a frame, and a node still in the next tree whose fingerprint changed without
`willEditRetained` or a reconcile is reported. A stale cache key, quiet update or unannounced edit shows up as a failure instead
of old UI.

Rules that keep it working:

- Read data a retained build depends on, outside widget state, through `observe*`.
- Change a node of the submitted tree only after `willEditRetained`, or inside its own widget's build (which `selfUpdating`
  reconciles).
- Update state quietly (`State.updateQuietly`) only when no build reads it, or the build that changes it already used the value.
- Panels with a hand-written `cacheKeyHash` should move their reads to `observe*`, one panel at a time, under verify mode.
  All editor panels now declare their external dependencies; `panel-flows` (check-ui-retention) covers the five panels added here.

## Inspection camera retention (2026-10-30)

The camera now synchronizes its viewport in the editor's explicit submit step, before checking retained dependencies.
Creation, document replacement, presentation binding, joint/geometry providers, simulation samples and renderer settings
no longer depend on rebuilding the dock panel. An independent public `view()` still initializes the camera before
returning its view, preserving callers that submit that view directly; the hosted submit uses its already-sampled frame. A running simulation is sampled before this update; the ordinary build
and the verification reference use that same logical frame. Unchanged simulation revisions do not recopy pose arrays.

The panel observes its overlay state and binding revision, presentation/host availability, generation and viewport binding identity. Its
presentation controls observe the view and procedure choices, cursor state, enablement, active instruction and evidence.
Camera motion and physics revisions belong to the image rather than the surrounding controls. Observing the bound
viewport's identity also handles disposing and recreating it within the same document generation.
The binding revision represents the mount lifecycle: dock→overlay→dock must rebuild the cached dock's binding even
though its final overlay boolean matches its original value. A changed image that cannot request a patch also advances
that revision, following `requestPatch`'s ordinary rebuild fallback. This makes new samples visible on the first frame
after returning to a hidden tab, before its previous registration has been rearmed. Otherwise that cached tree can still refer to the old dock
registration while the viewport's patch handle names the now-unmounted overlay registration. The perspective panel
observes the camera's controls only while the overlay is shown, rather than invalidating its entire tree on image motion.

`EditorPerspectiveViewport` uses `BuildContext.selfUpdating` and `RenderNode.reconcile`. The explicit update requests a
patch when the existing paint key changes, so the mounted image keeps its identity and its controls remain retained.
`InteractionStateSnapshot` retains a self-updating root's registration independently of whether it reads pointer flags.
Previously its early skip of non-interactive roots also skipped that registration, so a cached custom image could not
resume patching after unmount/remount. Descendants owned by a self-updating widget still skip separate interaction checks.
Navigation callbacks do not capture their build root's geometry; they use the viewport's resolved size, so they require
no special root handles. Disposal clears the patch context. The paint key includes the evaluated presentation revision
(which includes its geometry fingerprint and simulation state), cosmetic-thread visibility and overlay visibility in
addition to the existing scene, camera, drag, lighting, sample, size, grid and collision inputs. This closes omissions
that an ordinary rebuild previously masked; no verification or fingerprint check is bypassed.

`panel-flows` exercises the no-assembly and no-host states, then supplies a one-part assembly and headless host services
with invalid window/surface handles. It builds the real camera controls, changes disclosure, zoom and a view label, and
changes image paint independently of controls, then moves the camera into picture-in-picture and back into its dock. It also hides and remounts an unchanged cached
image, checks that its registration returns without replacing its node, patches it again, and changes paint while hidden
to verify the first visible frame uses the new sample. The ordinary replay checks image and control identity; the verification
replay compares each submitting frame with a fresh tree. The fitted Select label records its displayed text after layout;
that existing feedback is consumed on a separate frame before isolating paint. A temporary state-change trace confirmed
that only the fitted labels changed state after relabelling, and that subsequent image-patch frames built no dock panels.
The trace was removed after diagnosis. Identity across verification frames is not a valid assertion:
`UiContext.verifyRetention` deliberately leaves its fresh reference mounted. The headless fixture does not submit GPU
work and therefore does not establish pixel equivalence on a desktop GPU.

### Camera validation and cost

All ten UI scripts pass (the settings script reports `Settings tests passed`), all nine retention scenarios pass,
the normal camera fixture passes eight cycles including image/control identity and redocking, and the strict budgets
and three 500-cycle memory runs pass. Verification and budget ceilings are unchanged. A temporary Main-only control
was used to explain refill-counter movement: the closed-camera workloads cannot execute the changed camera/viewport
code, so restoring only `Main.hx` isolates the production changes those workloads reach. The same updated test harness
was used on both sides. The control source was restored byte for byte before rebuilding and rerunning the gates.

With census enabled (`--census 1`, 30 cycles, no sampling profiler), actual allocation never increases:

| action / phase | Main control bytes | camera implementation bytes | change |
|---|---:|---:|---:|
| hierarchy→sensors, whole frame | 169,264 | 169,112 | −152 |
| sensors→hierarchy, whole frame | 131,208 | 131,056 | −152 |
| console→telemetry, whole frame | 115,912 | 115,760 | −152 |
| telemetry→console, whole frame | 134,792 | 134,640 | −152 |
| selection, tree/style only | 851,408 | 851,304 | −104 |
| all ten interaction actions | unchanged | unchanged | 0 |

The interaction census medians include 18,200 bytes for typing a character and 18,456 for backspace. Raw refill-counter
medians can move in either direction even when actual allocation falls. The independently run, probe-off comparison
with the starting baseline is below; these are observations, not a claimed latency improvement for closed cameras.

| action | baseline KiB | camera KiB | baseline ms | camera ms |
|---|---:|---:|---:|---:|
| hierarchy→sensors | 165.1 | 166.9 | 1.70 | 1.96 |
| sensors→hierarchy | 129.0 | 127.0 | 1.35 | 1.58 |
| console→telemetry | 112.5 | 112.5 | 1.16 | 1.37 |
| telemetry→console | 130.7 | 132.5 | 1.22 | 1.43 |
| hover-other | 13.1 | 13.1 | 0.42 | 0.66 |
| hover-field | 23.9 | 22.1 | 0.43 | 0.68 |
| hover-away | 25.0 | 25.0 | 0.43 | 0.67 |
| scroll-inspector | 22.3 | 22.3 | 0.72 | 1.16 |
| type-char | 17.8 | 16.9 | 0.43 | 0.66 |
| type-backspace | 17.8 | 17.8 | 0.42 | 0.66 |
| idle / idle-focused | 0.2 | 0.2 | 0.00 | 0.01 |
| hover-enter / hover-inside | 0.6 | 0.6 | 0.00 | 0.00 |
| selection | not reported | not reported | 3.05 | 3.42 |

Allocation source attribution comes from the census comparison, not the phase of a TLAB refill. Census timing is not
comparable with probe-off timing. No raw budget median fell consistently enough here to justify tightening its ceiling.
The normal eight-cycle fixture (`app/build/profiles/ui-camera-normal`) measures image-patch submit at
0.115 ms median over seven warm frames. This is headless UI submission, not GPU execution or presentation latency.
Gate logs are retained in `app/build/profiles/ui-camera-gates`.
Captures under `app/build/profiles`: `ui-camera-cost-{tab-matrix,interaction,selection-stress}` and
`ui-camera-census-{after,main-control}-{tab-matrix,interaction,selection-stress}`. Captured bytecode is omitted.

## BIM retention (2026-10-30)

BIM now observes a model-owned `cadkit.parametric.Document.metadataRevision`, its active projection and selection, and the
editor binding. CadKit advances this non-persisted counter at the record mutation/restore methods for collection
membership, names, typed properties, definition input/default metadata, instance overrides/definition reassignment, and
relationship endpoints. Undo, redo and codecs use those same paths. The counter is not restored with a historical
`Definition.revision`, so restoring an earlier input revision cannot make an old retained snapshot current again.
It is catalog/metadata invalidation, not a revision for feature geometry or derived shape caches.

Both BIM tree models return this scalar revision. Their previous signatures enumerated and serialized elements,
relationships, definitions and instance counts during revision checks. The type signature also missed an instance rename
that left its count unchanged. A scalar getter allocates nothing and covers that rename as well as property-schema edits.
The UI does not maintain a second list of model fields to hash, and direct model edits need no editor history revision.

The dock supplies its known width through `BimModelEditor.atWidth`; standalone builds use the context viewport width.
The editor no longer measures its width and changes the next build's breakpoint from an `onResolved` callback. Compact
and wide composition therefore use the same inputs on the submitting build and its verification reference.

Tree selection has one owner. `TreeView.selectionProvider` is an optional observed primary-selection source; normal
uncontrolled trees keep their previous behavior. A controlled tree clamps unavailable keys to no visible selection and
synchronizes only its private state quietly after choosing the value this build will render. Input still updates normal
widget state and notifies the owner once; synchronization does not notify the owner. As for other observed reads, the
owner schedules a frame/build when external model values change. BIM's inspector and each projection now use the same
selection, rather than letting a newly created tree restore a different old selection from its internal store. An empty
owner selection no longer silently highlights the first tree root while the inspector still says to select an object.

An initialized tree also reuses its stored `PointerClickSequence`: building an unused placeholder on every rebuild was
unnecessary allocation. This keeps double-click history intact while accommodating the controlled-selection binding.

The `panel-flows` fixture constructs one project/site/building/storey and one window type/instance, without loading a
source project. It exercises real row clicks and keyboard expansion/collapse, both projections, renaming, property
addition/removal and type replacement, undo/redo, definition default restoration with a repeated history revision,
instance overrides and labels, wide/compact resize, unchanged-node retention and document replacement. Row hit-test paths
must contain the row identified by resolved geometry. The normal replay checks retention identity; verify mode continues
to rebuild and compare every submitting frame. Existing fitted-label feedback gets a settling frame before isolating an
unchanged frame.

The tree-selection suite separately checks externally controlled selection through a retained parent, null and missing
keys, input notifications and comparison with a full rebuild. `CADKIT_SMOKE_ENTRY=MetadataRevisionSmoke bash
cadkit/scripts/test-haxeon` checks the revision invariants, including no invalidation for an identical property, collection
insertion/removal, low-level restores, history and decoding. The existing `BimEditorProjectionTests` also pass.

The ten UI suites, all nine verify-every-frame editor scenarios, the ordinary eight-cycle panel replay and all three
500-cycle memory runs pass. Allocation ceilings are unchanged. Same-machine probe-off measurements against the starting
baseline are below; BIM was closed in these standard cost scenarios, so these establish regression coverage rather than
a claimed speedup for BIM. Exact census comparisons against the preceding camera commit show unchanged bytes for all
four tab transitions and all ten interaction actions. Selection tree/style allocation falls from 851,304 to 851,272 bytes
(the full selection-frame allocation is not reported).

| action | baseline KiB | BIM KiB | baseline ms | BIM ms |
| --- | ---: | ---: | ---: | ---: |
| hierarchy → sensors | 165.1 | 165.4 | 1.70 | 1.66 |
| sensors → hierarchy | 129.0 | 127.0 | 1.35 | 1.30 |
| console → telemetry | 112.5 | 112.5 | 1.16 | 1.13 |
| telemetry → console | 130.7 | 132.5 | 1.22 | 1.21 |
| hover-other | 13.1 | 13.1 | 0.42 | 0.42 |
| hover-field | 23.9 | 23.9 | 0.43 | 0.43 |
| hover-away | 25.0 | 25.0 | 0.43 | 0.43 |
| scroll-inspector | 22.3 | 22.3 | 0.72 | 0.72 |
| type-char / type-backspace | 17.8 | 17.8 | 0.43 / 0.42 | 0.42 / 0.42 |
| idle / idle-focused | 0.2 | 0.2 | 0.00 | 0.00 |
| hover-enter / hover-inside | 0.6 | 0.6 | 0.00 | 0.00 |
| selection | not reported | not reported | 3.05 | 3.60 |

Raw allocation differences caused by refill attribution must not be interpreted as object-allocation changes; the exact
census comparison above covers that distinction. Selection timing varies between captures (3.1 ms in the strict budget
run); no latency improvement is claimed. Evidence is retained under `app/build/profiles/ui-bim-cost-*`,
`ui-bim-census-*`, `ui-bim-normal` and `ui-bim-gates`, omitting captured bytecode.

## Machine control retention (2026-10-30)

The document lifecycle already configures the main presentation viewport when it is created or its assembly is replaced.
Machine control no longer repeats that setup from its build. `MachineControlPanel.update` handles generation changes and
cancels gestures when simulation, project ownership or document workflows lock editing, before retained dependencies are
checked. The public standalone `view()` entry point also runs this update. Generation changes clear draft text, errors and
free-detent choices, so a different document cannot inherit a previous machine's transient edit settings.

The observing panel reads the document generation/revision and the identity of the assembly definition and live pose.
Session edit/restore APIs replace those records, including live gesture previews that create no history revision. The
document revision covers initial-pose and dependent-joint edits. Axes are enumerated only when a build is needed, rather
than constructing an axes array to check retention. Edit locks, viewport/section availability, draft fields, detent choices
and errors are observed directly. Hobbing controls observe the player binding and their displayed handling/inspection and
cut state. The enclosure panel observes its controller binding, published status text and enabled actions, rather than
rebuilding just because a new simulation sample was published.

`MachineAngleControl` uses the same `selfUpdating`/`reconcile` mechanism as Slider. Input updates the value and requests a
patch; it does not edit the mounted semantics directly. Pointer handlers follow `RenderNode.latest` to the mounted node
when reading geometry. Gesture bookkeeping updates quietly because it is not a displayed input. The shared slider's
caller-supplied begin/finish listeners remain attached across its patches, as required by the normal reconcile contract.

The bounded `panel-flows` machine fixture has one linear joint and one rotary joint with detents. It needs neither a
source generator nor a simulation worker. It covers numeric drafts/errors, external uncommitted pose previews, real
slider and angle gestures across frame submissions, undo/redo, free turning, keyboard edits, saving the initial pose,
locking during a gesture and document replacement. Normal replay also checks unchanged panel identity. The separate
`MachineControlTests` exercise decorated controls on the cached/patch path and compare them with fresh builds.

This fixture exposed a verification formatting defect: a regular expression removed `states=hovered` from
`states=hovered,checked`, leaving a stray `,checked`. It also removed those words from arbitrary label/value text.
Verification now asks the inspector to mask only the intended hover/press flag bits before formatting. Checked, selected,
focused and disabled flags, semantics, labels and values still compare. Regression tests cover mixed pointer/checked flags
and prove that checked-state and label-text mismatches are reported. The lock fixture also exercises the second layout/build pass that clears focus from a disabled control. Each committed
pass now records its fingerprints before starting a focus pass. Previously the next pass could compare fresh nodes against
fingerprints of different nodes with the same IDs from the previous frame. The fingerprint contents and unannounced-edit
check are unchanged; each pass still checks edits against the nodes actually committed before it. Interaction changes are
acknowledged after the focus pass, so self-updating widgets receive the blur/focus changes that routing produced after the
first build. A regression test disables a focused retained button and checks both focus and fresh-build equivalence.

All ten UI suites, all nine verify-every-frame scenarios, strict budgets, three 500-cycle memory runs and 209
`MachineControlTests` checks pass. The enclosure runtime suite also compiles with the explicit update/context API; its
large physical hobber fixture is not used for retention coverage. Exact census allocations match the preceding BIM commit
for every tab and interaction action and for selection tree/style (851,272 bytes). No ceiling is raised or lowered.

Same-machine probe-off comparison with that preceding BIM capture:

| action | BIM KiB | machine KiB | BIM ms | machine ms |
| --- | ---: | ---: | ---: | ---: |
| hierarchy → sensors | 165.4 | 165.3 | 1.66 | 1.66 |
| sensors → hierarchy | 127.0 | 127.0 | 1.30 | 1.29 |
| console → telemetry | 112.5 | 112.5 | 1.13 | 1.13 |
| telemetry → console | 132.5 | 132.5 | 1.21 | 1.20 |
| hover-other | 13.1 | 13.1 | 0.42 | 0.42 |
| hover-field / hover-away | 23.9 / 25.0 | 23.9 / 25.0 | 0.43 | 0.43 |
| scroll-inspector | 22.3 | 22.3 | 0.72 | 0.72 |
| type-char / type-backspace | 17.8 | 17.8 | 0.42 / 0.42 | 0.42 / 0.41 |
| idle / idle-focused | 0.2 | 0.2 | 0.00 | 0.00 |
| hover-enter / hover-inside | 0.6 | 0.6 | 0.00 | 0.00 |
| selection | not reported | not reported | 3.60 | 3.05 |

These standard workloads keep machine control closed and establish regression coverage; no latency reduction is claimed
from the small timing differences or the variation between selection captures. Evidence is retained under
`app/build/profiles/ui-machine-cost-*`, `ui-machine-census-*`, `ui-machine-normal` and `ui-machine-gates`, without bytecode.

## Mission retention (2026-10-30)

Mission presentation now reads its installed mission/job records, chosen controller, execution state and startup progress
through observed dependencies. `MissionController` exposes allocation-free selection/mission/player and active-step reads;
checking a retained panel does not construct its former program array, progress record or view-state snapshot. The player's
`progressPhase`, `startupAxis` and `startupPhase` expose the same inputs used by progress/status presentation. The panel
and status card do not format robot status labels merely to check retention. Installed source records are replaced through
the document lifecycle; their binding and the document generation/revision cover authored metadata. The viewport observes whether work
exists and no longer allocates a mission snapshot merely to decide whether to show its status card. `MissionStatusView`
records its dependencies at its build boundary, so its containing panel/card is retainable. A newly supplied card still
uses its caller's current optional action and callback; it does not hide those constructor inputs behind another cache.

`MissionPanel.update` runs before cache checks, including the public standalone editor `view()` path. It resets transient
selection/following on source replacement and moves the scroll controller when the current step changes. Builds only read
that presentation and populate the list's derived model cache. A wheel event pauses following immediately, before smooth
scrolling advances; keyboard/scrollbar/direct offset changes are also noticed by the update step. Following again cancels
any outstanding smooth-scroll target before returning to the current step. Selecting a detail without a scene target still
requests a frame.

The shared list now has an optional observed `selectionProvider`, like the tree's controlled selection. Invalid/disabled
indices render unselected, synchronization updates only private state quietly, and input alone notifies the owner. This
keeps row highlighting aligned with the mission detail after program changes, following and document replacement. The
list observes its model revision and the scroll controller's revision, which advances on published scroll changes and
resolved metrics. A retained list therefore materializes a newly scrolled window instead of translating only its old rows.

The first real mission fixture exposed fallback-height virtualization: the first build used 300 pixels, but native layout
resolved a taller viewport, so an immediate full rebuild materialized an additional row. `BuildContext.requestBuildFeedback`
now lets a resolved constraint request another build before publication. The list requests it when its resolved viewport
or a layout-clamped offset differs from the inputs its window used. Scroll metrics invalidate only the retained content
that observed them; normal retention and the incremental layout transaction remain in use. Build feedback is bounded to
eight passes and fails explicitly on non-convergence. Frame time/animations advance only on the initial build. Intermediate
layout passes record fingerprints for the next comparison, but focus requests, focus events and resource disposal wait
until the children have settled. A regression test requests focus for a target that is revealed by build feedback.
Verification still compares the first published frame; there is no settling-frame exception for the list.

The `panel-flows` fixture uses one grounded box, one controller and a digital loopback. It executes actual signal mission
steps without a source generator, CAD, motion planner or background playback. It covers the empty/unchanged panel,
authored program selection, row details, replacement, progress following, wheel interruption and resumption, completion,
reset, a missing-input failure and clearing. The card also checks adding/replacing/removing a caller action without an
execution-state change. Normal replay checks unchanged heading identity. The restyle suite separately
checks grow/shrink/one-pixel resolved windows, scrolling through an outer cache with an unchanged key, controlled selection,
clearing, unavailable indices and exactly-once input notifications against fresh builds.

All ten UI suites, all nine verify-every-frame editor scenarios, strict budgets, the ordinary eight-cycle panel replay and
all three 500-cycle memory runs pass. Exact census medians match the preceding machine-control commit for all four tab
transitions, all ten interaction actions, and selection tree/style (851,272 bytes); the captured selection phase sum is
also unchanged at 880,872 bytes. An initially unconditional mission-card dependency added 80 bytes in headless selection
frames; observing it only where a real viewport builds that card removes that unused dependency. No ceiling is changed.

Same-machine probe-off comparison against that preceding commit, after rebasing onto upstream `727ebf0c`:

| action | machine KiB | mission KiB | machine ms | mission ms |
| --- | ---: | ---: | ---: | ---: |
| hierarchy → sensors | 165.3 | 165.3 | 1.66 | 1.71 |
| sensors → hierarchy | 127.0 | 127.0 | 1.29 | 1.34 |
| console → telemetry | 112.5 | 112.5 | 1.13 | 1.16 |
| telemetry → console | 132.5 | 132.5 | 1.20 | 1.22 |
| hover-other | 13.1 | 13.1 | 0.42 | 0.43–0.64 |
| hover-field | 23.9 | 23.9 | 0.43 | 0.44–0.67 |
| hover-away | 25.0 | 25.0 | 0.43 | 0.44–0.66 |
| scroll-inspector | 22.3 | 22.3 | 0.72 | 0.73–1.15 |
| type-char / type-backspace | 17.8 | 17.8 | 0.42 / 0.41 | 0.42–0.43 |
| idle / idle-focused | 0.2 | 0.2 | 0.00 | 0.00–0.01 |
| hover-enter / hover-inside | 0.6 | 0.6 | 0.00 | 0.00 |
| selection | not reported | not reported | 3.05 | 3.13 |

These standard scenarios keep mission closed; they establish regression coverage rather than a claimed speedup. The
interaction range records two unchanged-code after runs: hover/scroll slowed in the first capture and returned close to
the earlier timings in an isolated repeat. Both captures are kept. Exact allocations are unchanged; no raw refill-counter
change justifies tightening a ceiling. All gates were repeated after the rebase, including the compiler suites
(608 passed, 0 failed). Captures are retained under `app/build/profiles/ui-mission-cost-*`, `ui-mission-census-*`,
`ui-mission-interaction-repeat`, `ui-mission-normal` and `ui-mission-gates`, without bytecode.

## Typing allocation (2026-10-30)

The reported 2 KiB step was not all a reconcile allocation. HashLink's thread-local allocation buffers reserve 2,048-byte
runs (`vendor/hashlink/src/gc.c`, `GC_TLAB_RUN`); `Gc.totalAllocated()` counts the refill, not each consumption of a slot.
Which action crosses a refill changes its reported median. Census mode disables that fast path and counts actual object
allocations. Capturing the UI sources immediately before `6d14bc5f` and the current sources on this machine showed about
312 bytes more per typing action in census mode. A separate replacement-path control removed exactly 360 bytes: the
288-byte comparison RenderNode and its 72-byte children array. Both historical controls were removed after capture;
verify mode and the runtime's allocation counter were not changed.

The remaining typing allocations were traced with `--census 1` and an isolated
`MATERIA_INTERACTION_ONLY=type-char,type-backspace` replay (100 cycles), then checked with the full interaction replay.
The comparison prior is now reused by its `BuiltNode`, including its child storage; it is overwritten only when another
patch takes a snapshot, after the previous frame consumed it. A change between shared and copied layout storage creates
a compatible prior; copied styles are updated with `Structural.assignChanged`. The cache retains at most one previous
snapshot/subtree per self-updating widget and has the lifetime of that build entry.

Other measured, discarded work on the same typing path was removed:

- Scroll layout callbacks built three Transform2Ds even when the offset was unchanged (about 1,008 bytes per action).
  They now construct the translation only when it changes. Unchanged scrollbar geometry also retains its four immutable
  axes (about 384 bytes); scrollbar visibility, focus and numeric semantics are still updated every time.
- Self-updating build pruning copied the map's keys (about 320 bytes). A maintained ID array now supplies membership;
  pruning still checks every registered ID against the mounted tree, removes absent builders, and supports rearming them.
- Ellipsis labels constructed clipped-bounds Rects to rediscover the same available width (about 240 bytes). Their existing
  memo now caches width by immutable resolved-item identity, which changes when geometry or clipping changes.
- The patch builder copied its saved typography stack (72 bytes). It can borrow it: `withTextStyle` balances pushes on
  success and failure. Native submits also allocated an empty resolved array before replacing it (72 bytes); it is now
  created only for the reuse path. Native hit-path arrays are sized once from the known ID count rather than grown by push
  (about 416 bytes). An empty animation scheduler returns after time validation instead of copying an empty list.

These are measured sources, not a claim that each was introduced by `6d14bc5f`. Removing the actual stand-in allocation
alone would not reliably meet targets expressed through the refill counter. Census medians fell by exactly 2,864 bytes:

| isolated action | census before bytes | census after bytes |
|---|---:|---:|
| type-char | 21,416 | 18,552 |
| type-backspace | 21,672 | 18,808 |

Normal budget replay on the same machine, KiB per action, with census disabled:

| action | before | after |
|---|---:|---:|
| hierarchy→sensors | 171.9 | 168.5 |
| sensors→hierarchy | 138.6 | 135.0 |
| console→telemetry | 118.2 | 112.8 |
| telemetry→console | 135.6 | 132.8 |
| hover-other | 18.1 | 13.1 |
| hover-field | 29.2 | 25.8 |
| hover-away | 31.5 | 26.8 |
| scroll-inspector | 26.5 | 22.9 |
| idle | 0.2 | 0.2 |
| type-char | 20.1–22.1 | 17.8 |
| type-backspace | 22.1 | 17.8 |

Three additional full interaction runs measured typing at 17.8–18.3 KiB for char and 17.8 KiB for backspace. Refill attribution
also moves some non-typing medians between runs, so the census is the source attribution and the normal replay is the
acceptance test. Full frame latency remains about 0.7 ms for typing and 1.45–1.91 ms for tab transitions. No budget ceiling
or retention check was raised or weakened; the typing ceilings are lowered to 19.8/19.9 KiB. Nine retention scenarios and all three 500-cycle memory runs pass.

## Live roots for slider and progress callbacks (2026-10-30)

`RenderNode.latest` now follows both forms of replacement: an old mounted node replaced by a different-kind build, and a
fresh build root discarded by reconciliation in favor of the already-mounted node. Reconcile links that fresh root to the
live one after applying its build. A captured root therefore resolves to current geometry and computed style, including
when a later build changes kind. Reusing a non-fresh root as a new reconcile input is rejected to prevent identity cycles.

This extends the existing canonical-identity mechanism instead of adding widget-specific pointer state, allocating live
handles, looking nodes up by ID, or changing every callback signature. Resolving a reconciled build root normally takes
one pointer hop and allocates nothing. Closures must resolve it when invoked, rather than cache the resolved instance.
`Slider` uses this for drag geometry and paint style; `ProgressBar` uses it for paint style (its geometry was already passed
into paint correctly). Both register their builds through `BuildContext.selfUpdating`.

Slider value changes request a patch and update their invalidation state quietly, with ordinary state invalidation as the
fallback when the widget is unregistered. The dragging state is read only by its own handlers and also updates quietly.
Semantics are produced by the reconciled build, rather than mutated on the submitted node by an input handler. Progress
keeps its existing retained painter/animation resource; a target change requested as a patch updates that painter and its
semantics without rebuilding the retained panel.

The motion regression test performs 32 steps against a reference that rebuilds every frame, including frames without
input: repeated slider dragging, keyboard changes, animated progress targets, and caller pointer listeners. At every
step it checks node identity, caller listener/style/child/paint preservation, live-root resolution, and equality of geometry,
semantics and actual rectangle/color paint operations. The retained panel builds once. No fingerprint or verification
check is bypassed.

This mechanism removes a root-capture obstacle wherever it occurs, but does not make `Tabs` or `SelectionPopup` a direct
conversion: tabs also build arbitrary panel content and register host drag/drop/header geometry, while the popup mutates a
supplied trigger root and builds a conditional overlay/option subtree with scroll and focus behavior. Their ownership and
registration lifecycles still need separate design. Neither is converted here.

The final same-machine budget replay after this conversion measures 17.8 KiB for each typing action, tab transitions at
112.8–169.4 KiB and 1.51–1.99 ms, and selection at 3.66 ms. Every supplied allocation baseline is unchanged or lower. All
ten UI scripts, nine retention scenarios, the tightened typing budgets, three 500-cycle memory runs, and the final compiler
suite (608 passed, 0 failed) pass.

## History

Status 2026-09-30: **stopped after stage 1 and a bound on stage 3; the design below was not implemented as written.** See
"Outcome". Its verify mode and the dock chrome measurements led to the model above.

See [LAYOUT_COST.md](LAYOUT_COST.md) for the 2026-10-30 per-frame encode, parse, Clay, snapshot, hash and decode breakdown.

## What the numbers say

Measured on the headless `tab-matrix` workload (320 nodes) after the allocation work in `app/tests/performance/README.md`:

- A frame where nothing changed costs about 0.001 ms: the UI already skips a clean frame entirely. There is no per-frame floor to remove.
- A tab switch costs about 2.0 ms: 0.9 ms Haxe tree build and style, 1.05 ms layout submit (Haxe encode, native layout and shaping, decode).
- Only about 11 of the 320 nodes are new panel content (`subtrees` in the frame timeline), yet about 65 `RenderNode`s are allocated per frame and 142 nodes are style-changed.
  Panel contents and the top and status bars are already retained, so the rest of the per-frame build is the dock chrome: `Tabs`, `Button`, `SplitView`, `DockWorkspace`.
- Allocation by owning widget (census, per cycle): `Tabs` 7.5%, `Button` 6.1%, `SplitView` 5.0%, `DockWorkspace` 4.6%, `DockTextWidthCache` 1.4%: about a quarter of what the app allocates, before counting the shared `RenderNode`, `ComputedStyle` and `BuildContext` cost those widgets cause.
- The cost of retention itself is small: `RenderNode.walk` (the retained-tree walks) is about 4% of profiled frame time.

So the lever is not "reuse more of the same": it is retaining the dock chrome, and making the existing retention cheap and uniform. Reusing layout work is out of scope: native layout is a whole-tree Clay pass, and a native incremental layout is not planned.

## What exists

Two copies of the same mechanism:

- `RetainedView` (top and status bar): an application-supplied revision string, plus `"|style=" + styleRevision + "|viewport=" + w + "x" + h`, compared with the cached entry's key.
- `DockPanelCache` / `DockPanelView` (panel contents): the same, plus `"|width=" + availableWidth`.

Both then run `statesMatch`, which walks every node of the cached subtree to compare hover/press/focus bits, and `claimRetainedTree`, which walks it again to register every ID in the per-frame `claimed` map.
The validity check and the ID claim are therefore O(nodes) even on a hit, and the keys are strings built each frame. Neither cache covers the dock chrome.

## Design

One primitive in `haxeon.ui.core`, used by all three:

```haxe
context.retained(id, key:RetainedKey, function() return view)   // returns the cached RenderNode or builds and stores it
```

- **Key** is a small value object, not a string: `styleRevision`, `viewportWidth`, `viewportHeight`, `width`, and an application `revision:Int`. Comparing it allocates nothing. Callers that only have a string revision hash it once when the source changes, not per frame.
- **Record** holds: root, the subtree's ID set (an `Array<Int>` built once), the state IDs and revisions it depends on (what `stateUsageMarker` and `stateRevisions` provide today), and its interactive footprint: the IDs of nodes that carried a hover, press or focus bit when it was built.
- **Validity in O(interactive), not O(nodes).** `BuildContext` already knows which IDs are currently hovered, pressed or focused (at most a few). A record is stale only if its interactive footprint differs from the current interaction state for IDs inside it: for each current interactive ID, check membership in the record's ID set and compare that node's bits; for each ID in the footprint, check it is still interactive. No tree walk.
- **Claims without a walk.** Retained IDs live in a persistent set owned by the record, added when it is built and removed when it is dropped. `BuildContext.id` checks a freshly built ID against the per-frame map and the retained sets. Duplicate detection between two retained records is checked once, when the second is built.
- **Dock chrome.** `DockWorkspace` wraps each pane's tab strip and each split divider in `context.retained`, keyed by what determines them: the pane's tab list, active tab, resolved label widths, and split ratio. A tab switch in one pane rebuilds that pane's strip only. Panel contents keep their existing keys, ported to the same primitive so `DockPanelCache` disappears.
- **Hooks for later, not built now.** A record could also carry the encoded `LayoutTransaction` bytes for its subtree so the encode is a copy; nothing in this design depends on it.

## Correctness

The failure mode is a stale UI: a subtree that should have rebuilt and did not.
The risk is the key, not the mechanism, so:

- The key is built from the same revisions the current keys use, plus state revisions the record already tracks. No new invalidation source is invented.
- A debug mode (`MATERIA_RETAINED_VERIFY=1`) rebuilds every retained subtree on a hit and compares the fresh `LayoutNode` tree with the cached one (structure, style fingerprint, text). It runs in the headless scenarios and fails the run on any difference. It is off in release.
- Behaviour-preserving first: porting `RetainedView` and `DockPanelCache` to the primitive must leave the existing scenarios and `edit-regression` unchanged.

## Stages, each with a go/no-go

1. **Measure the dock chrome.** Add build probes around `buildTabs`, `buildSplit` and the tab widgets (the existing `buildProbe` only covers panels) to see how much of the 0.9 ms they are on a tab switch.
   Go if they are at least about 30% of tree build and style time (about 0.3 ms).
2. **The primitive and the port.** Implement `context.retained`, port `RetainedView` and `DockPanelCache`, add verify mode.
   Go if allocation and latency are unchanged or better and verify mode is clean across the scenarios.
3. **Retain the dock chrome.** Wrap the tab strips and dividers.
   Target: about 0.3 ms per tab switch (2.0 to about 1.7 ms) and about a quarter less allocation. Keep only if an interleaved A/B (four rounds) beats the noise by at least 0.15 ms.
4. **Optional: cached encoding** for retained subtrees, only if the profile after stage 3 shows the Haxe encode is worth it.

If stage 1 or 3 misses its target the work stops there; the primitive from stage 2 is still a simplification of two duplicated caches.

## Outcome

Stage 1 (measured with `dock-workspace` and `panel-hit:*` build probes, tab-matrix, median of 40 cycles):

| transition | tree + style ms | dock workspace ms | panel cache hits ms | panels built ms |
|---|---|---|---|---|
| hierarchy to sensors | 0.96 | 0.50 | 0.05 | 0.10 |
| sensors to hierarchy | 0.71 | 0.39 | 0.02 | 0.09 |
| console to telemetry | 0.74 | 0.42 | 0.02 | 0.08 |
| telemetry to console | 0.94 | 0.64 | 0.02 | 0.35 |

- The dock chrome (tab strips, dividers, tab buttons) is 37-41% of tree-and-style time, which passed the stage 1 bar.
- A panel cache hit, including its `statesMatch` and `claimRetainedTree` walks, costs 0.02-0.05 ms. The general primitive of stage 2 would speed up almost nothing, so it is dropped as a performance project.
- Timing `Tabs.build` separately (header strip only, the tab contents subtracted) gave 0.17-0.21 ms for all four strips together, about 0.05 ms each.
  Retaining the three strips of panes that did not change would save at most 0.12-0.16 ms (6-8% of a 2.0 ms frame) before the cost of a hit: the retained-subtree checks, and replaying the drop-target registrations that each header's build performs (`onTabHeaderBuilt` calls `interaction.registerTabTarget`).
  `Tabs` also builds its header and the active panel content together, so a strip could not be retained without splitting the widget.
  Realistic gain is about 0.1 ms, below the 0.15 ms keep threshold and inside measurement noise on a shared machine, so stage 3 is a no-go.

Conclusion: the remaining tab-switch cost is spread thinly over hundreds of nodes and over native layout and shaping of content that really changed, not over work a retained subtree can skip. Revisit only if the tree grows much larger or a frame with many independent panes becomes common; then a retention keyed on the pane's tab list, active tab, label widths and drag preview, with the drop-target registrations replayed on a hit, is where to start.


## CNC retention and composite updaters (2026-10-30)

CNC source resets, selection resets, executing-line following and failure-disclosure resets now run in an explicit
`CncPanel.update` before retention is checked. `ToolpathPlayer.sourceText` returns the immutable program without splitting
and rejoining it. A reusable structural presentation captures the source and displayed execution inputs; generated
`Structural.changedMask`/`assignChanged` compare and publish them without a maintained equality field list. Builds read this captured presentation, so the retained and reference builds use the same execution sample. Printer-link
text is observed at the dock boundary. The controlled list selection keeps the highlighted row and restart selection in
agreement after source replacement.

The CNC content owns a stable self-updating box. Changed execution samples request its ordinary reconcile patch, while
unchanged samples reuse it and its dock. If an unmounted registration cannot accept a patch, a binding revision forces a
build on return, as for the inspection camera. The wrapper does not retain caller arguments independently: replacing a
caller-supplied printer line or theme builds a new binding normally.

Live hobbing telemetry is a reusable structural value separate from the completed inspection result. The existing semantic
projection fills a second reusable telemetry value; generated comparisons decide whether to request a patch. Inspection
identity is compared separately: `HobbingStock.finish` publishes the result after generating its traces and qualifications.
The report keeps its plot, disclosure and scroll state while telemetry changes. CNC tool/spindle and print
layer/temperature status methods cache the strings they display, using their displayed primitive inputs, so asking for an
unchanged status does not allocate arrays or strings.

Composite patches exposed two framework lifetime requirements that leaf controls did not exercise. Each self-updating
build now owns its current observed reads, state IDs/revisions and nested updater registrations. Enclosing caches retain
that mutable boundary rather than the obsolete descendants from its first build. Ordinary state updates still invalidate
the enclosing cache; quiet updates plus `requestPatch` retain their existing meaning. Hidden dock caches retain the latest
owned resources without rearming unmounted widgets. A changed state-membership set requests the existing bounded build
feedback pass, so resources removed by a patch are disposed before the frame is published. Stable capture arrays are reused,
and stateless leaves need no additional dependency record. Boundary capture walks directly and stops at each owner's built children; caller-added updating children retain their independent boundaries. The default one-element typography stack can be shared because
push/pop scopes are balanced; non-default stacks are copied as before.
Nested retained views can move an existing child into the fresh builder before reconciliation. Reconcile recovers its slot
from the existing committed `RenderTreeTopology`, rather than introducing another topology record. Added builder children
precede caller decorations even when the earlier build had no children. Cached subtree IDs, like fresh IDs, are claimed
with the completed tree rather than during a patch; reusing a nested updater still records its ownership boundary.

An announced edit must also precede its owner's patch when capturing priors. Scrolling first changed an existing translated
child, then the composite builder replaced it with a new child using the same offset. Recording the edited child as the
prior lost the native transform update. `UiContext` now consumes announced priors before patches run, retaining the later
collection for edits made during building. A focused test reproduced the native incremental-tree mismatch before the fix;
it passes afterward. Fingerprint checks and native/full-build comparisons are unchanged.

List window feedback now compares the actual scroll viewport, where `ScrollView` records its metrics, rather than its
parent box. Float32 layout can give these two boxes slightly different heights; comparing them exactly never converged.
Comparing the same viewport on both sides preserves exact checks and covers fractional sizes without a tolerance.

The bounded CNC fixture uses three physical Cartesian slides, explicit small box support hulls, and a finite rapid/dwell
program. It avoids source generation, CAD, stock cutting and the mill project. It exercises source replacement, controlled
selection, real execution and following, feed hold/resume, speed override, completion, hiding/remounting, reset and clearing. The existing hobbing report tests cover the
telemetry/result split (42 checks); direct mill callers explicitly update before submitting their views.

Same-machine exact census, 30 cycles with the first three cycles omitted, relative to the preceding mission commit:

| action / phase | before bytes | after bytes | change bytes |
|---|---:|---:|---:|
| hierarchy→sensors, complete action | 169112 | 165408 | -3704 |
| sensors→hierarchy, complete action | 131056 | 130432 | -624 |
| console→telemetry, complete action | 115760 | 115320 | -440 |
| telemetry→console, complete action | 134640 | 134152 | -488 |
| hover-other | 13592 | 13592 | 0 |
| hover-field | 22080 | 22080 | 0 |
| hover-away | 23584 | 23584 | 0 |
| inspector scroll | 19336 | 19336 | 0 |
| typing / backspace | 18200 / 18456 | 18200 / 18456 | 0 |
| idle / focused idle | 880 | 880 | 0 |
| selection, tree/style | 851272 | 846840 | -4432 |
| selection, summed measured submit phases | 880208 | 875776 | -4432 |

The durable tab reduction lowers its allocation ceiling from 217 to 214 KiB. Exact census avoids attributing TLAB refill
noise to the code; the ordinary budget capture remains the source for probe-off latency and allocation medians.


Probe-off medians on this machine, relative to the preceding mission checkpoint (interaction before times span its two
same-code captures; timings are descriptive, not a claimed speedup):

| action | before KiB | after KiB | before frame ms | after frame ms |
|---|---:|---:|---:|---:|
| hierarchy→sensors | 165.3 | 162.4 | 1.71 | 1.76 |
| sensors→hierarchy | 127.0 | 126.7 | 1.34 | 1.36 |
| console→telemetry | 112.5 | 112.3 | 1.16 | 1.17 |
| telemetry→console | 132.5 | 132.2 | 1.22 | 1.23 |
| hover-other | 13.1 | 13.1 | 0.43–0.64 | 0.42 |
| hover-field | 23.9 | 23.9 | 0.44–0.67 | 0.43 |
| hover-away | 25.0 | 24.9 | 0.44–0.66 | 0.43 |
| inspector scroll | 22.3 | 22.3 | 0.73–1.15 | 0.72 |
| typing / backspace | 17.8 | 17.8 | 0.42–0.43 | 0.42 |
| idle / focused idle | 0.2 | 0.2 | 0.00–0.01 | 0.00 |
| selection | not reported | not reported | 3.13 | 3.17 |

Small probe-off hover allocation differences reflect TLAB-refill attribution; exact interaction counts are unchanged,
so no interaction ceiling is changed. The added ownership checks preserve correct composite lifetimes; tab and selection timing medians are
higher in this capture, and no general frame-time speedup is claimed. The ten UI suites, all nine retention scenarios,
strict budgets (including retention again), an ordinary eight-cycle panel replay, and three 500-cycle memory replays pass. The latter retain exactly two workspace listeners,
148 widget resources and 209 style entries; post-warmup RSS growth is 6.09 / 6.09 / 5.94 MiB. Normal panel-flow replay
contains 5413 frames, including real CNC hold/resume, override and completion. Captures are retained in the outer
repository under `app/build/profiles/ui-cnc-cost-*`, `ui-cnc-census-*`, `ui-cnc-normal` and `ui-cnc-gates`, without bytecode.

## Tabs and selection popup reconciliation (2026-10-31)

Tabs retain their root and reconcile local selection and close-button visibility. Controlled selection remains owned by the
caller: it reports the requested key, and the caller supplies the next selection. Scheduling an additional local patch in
that case would build the old composite immediately before the caller rebuilds it. Optional retained headers observe close
visibility, so quiet hover/focus updates cannot leave their close controls stale.

SelectionPopup retains its root and its public option-node/visibility bridge while reconciling option selection and keyboard
navigation. Select and ComboBox route active-option changes through that bridge; committing a value, closing and changing a
query still update their enclosing control. The popup uses ScrollView's existing retained scrolling and resource lifetime,
rather than binding a controller to discarded roots. Revealing the active row is a one-shot navigation request stored with the controller, allowing
subsequent manual scrolling even across enclosing builds. Wheel input is owned by the popup even at its scroll limits.

Composite updaters may declare `buildsFromHover=false` when their only hover reads are stylesheet resolution or live paint.
Style rules still request a rebuild; otherwise hover repaints the node directly. The default remains conservative for widgets
that compute additional content from hover. This prevents a composite boundary from turning plain descendant hover into a
whole-panel rebuild. Resource membership changes request a complete settling build only outside an active complete frame;
that frame already records and releases resources through StateStore's existing frame lifetime. Empty observation and
interaction captures share immutable empty arrays. State-ID and revision lists reuse unchanged snapshots; changed lists
reserve their final size. StateStore interns its stable handles until their stored values are released. These changes avoid
adding allocation churn when a controlled pane registers its updater again during an ordinary complete build.

The decorated-control tests switch tabs with pointer and keyboard input, skip disabled choices, navigate and select popup
options, scroll and close the popup. Every step compares against a fresh build and checks stable roots, caller styles,
children, listeners and paint. Scrolling also tests stationary-pointer hover: old paths can reference replaced objects, so
event routing updates the current node through UiContext's existing ID index. Post-layout hover and focus changes settle
through bounded submission feedback before paint; paint-only changes invalidate the custom list rather than layout-input
revisions after submission. AccessibilityContract now verifies every frame, including real Select/ComboBox rebuilds and
scrolling. Verification comparisons and fingerprints remain unchanged.

Same-machine exact allocation census, probes and verification off, 30 cycles before (`30cf5c5e`, editor `f3251e58e`)
and after. These are allocator-counted bytes rather than the runtime's coarser allocation-block accounting. Closed-popup
interaction actions not listed here are unchanged, including hover, scrolling and idle. The complete-submit selection
figure sums its measured view, tree/style, native-layout and reconciliation phases within each frame before taking the median.

| action | before bytes | after bytes |
|---|---:|---:|
| hierarchy→sensors | 165408 | 165168 |
| sensors→hierarchy | 130432 | 130120 |
| console→telemetry | 115320 | 115056 |
| telemetry→console | 134152 | 133944 |
| type-char | 18200 | 18152 |
| type-backspace | 18456 | 18408 |
| selection, measured submit phases | 876440 | 869288 |

Captures under the outer repository's `app/build/profiles`: `ui-cnc-census-*` (before) and `ui-controls-census-*` (after).
Bytecode copies are removed after analysis. The hierarchy→sensors ceiling is lowered from 214 to 213.8 KiB; no ceiling is
raised. The allocation savings are small: the purpose is independently updating decorated controls without adding cost to
existing editor actions. This change claims no frame-time improvement.

Probe-off budget medians from the same machine (`ui-cnc-cost-*` before, `ui-controls-cost-*` after):

| action | before KiB | after KiB | before ms | after ms |
|---|---:|---:|---:|---:|
| hierarchy→sensors | 162.4 | 161.1 | 1.76 | 1.73 |
| sensors→hierarchy | 126.7 | 126.6 | 1.36 | 1.34 |
| console→telemetry | 112.3 | 112.0 | 1.17 | 1.16 |
| telemetry→console | 132.2 | 130.0 | 1.23 | 1.24 |
| hover-field | 23.9 | 24.1 | 0.43 | 0.48 |
| hover-other | 13.1 | 13.1 | 0.42 | 0.44 |
| hover-away | 24.9 | 24.9 | 0.43 | 0.46 |
| scroll-inspector | 22.3 | 22.3 | 0.72 | 0.76 |
| typing / backspace | 17.8 | 17.8 | 0.42 | 0.43 |
| selection | — | — | 3.17 | 3.09 |

Runtime allocation-block refill attribution moves the hover-field median by 0.2 KiB despite an identical 22080-byte exact
census. The census establishes that no action allocates more; neither the apparent refill savings on tab transitions nor
the small timing differences are attributed as improvements. All ten UI suites, all nine editor retention scenarios, the
strict lowered budgets and three independent 500-cycle memory captures pass. Memory growth after warmup is 5.47 MiB in
each final capture, with listeners=2, widget resources=148 and style entries=209 stable. Final logs and source hashes are in
`app/build/profiles/ui-controls-gates`.

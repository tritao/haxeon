# Retained subtrees

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
  `TextField`, `Slider` and `ProgressBar` use it. A widget qualifies when its build makes the same kind of node every time.
  A closure that captures its build root calls `RenderNode.latest(root)` when it needs the node: reconcile forwards that
  discarded build root to the instance kept in the tree. Descendant captures remain valid because the built children are
  swapped into the tree. `Tabs` and `SelectionPopup` still build with their panel.
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
  The editor's panels are all observing except the BIM, inspection camera, machine control, mission and CNC panels, whose builds
  keep state of their own and scroll or push into viewports; `panel-flows` (check-ui-retention) covers the rest.

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

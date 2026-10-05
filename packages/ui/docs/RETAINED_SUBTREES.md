# Retained subtrees

Status: 2026-09-30. **Stopped after stage 1 and a bound on stage 3; nothing below was implemented.** See "Outcome".

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

# 9. Layout in Haxeon, retained and incremental, with no layout feedback

Date: 2026-11-28

## Status

Accepted. Decisions 1 and 2 have landed: `haxeon.ui.layout.LayoutSolver` lays every submitted tree out, NativeKit builds
the scene from its geometry, and Clay is gone. Decisions 3 to 8 follow in the migration below. It supersedes the layout
half of [ADR 0002](0002-reactive-ui-model.md): decision 6 (floating nodes placed after the flow, two-phase layout) and the
clause that kept Clay "an immediate full solver" until "measurements later show layout as the main remaining cost".
Anchored placement (`LayoutAnchor`, landed with ADR 0002's decision 6) is kept and now runs in the solver.

## Context

A frame laid the whole tree out with Clay, natively, then ran geometry callbacks (`RenderNode.onResolved`). Some of them
compute something that depends on the geometry, edit the tree (`BuildContext.willEditRetained`), and ask for another pass
(`requestLayoutFeedback`), which laid the whole tree out again, up to eight times (`UiContext`).

Measured on the native explorer smoke (2026-11-28, `HAXEON_UI_RENDER_COST=1`, `HAXEON_UI_LAYOUT_COST=1`; ADR 0002 records
the numbers): 28 of 46 frames took two or three solves. 20 of those came from the scrollbar's geometry, 8 from virtual
lists rebuilding their window. A Clay solve of these 200-node trees took about 3.3 ms, and Clay keeps no state between
solves, so every solve costs the whole tree, whatever changed. Around it, a mirrored native tree was patched by encoded
records and decoded back every pass: about 1.3 ms more per solve (snapshot, parse, prepare, encode, decode).

The feedback comes from geometry-dependent content computed in the wrong place:

| Content | Today | Where it belongs |
| --- | --- | --- |
| Scrollbar thumb, its visibility and its accessible range | nodes edited after layout from the viewport and content extents | paint and hit geometry derived at paint time, as Flutter's scrollbar painter does |
| Scroll clamping and reveal requests (`ScrollView`, `Tabs`, `SelectionPopup`) | a pass after layout clamps the offset or scrolls a target into view | the scroll metrics reported during layout, the controller resolving them before the content is placed |
| Virtual list window | rebuilt after layout from the viewport and offset | children built during layout, from the constraints, as Flutter's slivers and Compose's lazy layouts do |
| Middle ellipsis | text replaced after layout from the width | a truncation mode of the text layout |
| A popup limited to the room beside its anchor | sized at build from last frame's geometry | a size limit of the anchor, applied when it is placed |
| Geometry callbacks that write state (`ComboBox`, `Select`, `Menu`, `TextField`, `SearchPicker`, `SidebarHost`, `TreeView`) | a signal written after layout asks for another build | each case read at event time, made an anchor or a builder, or allowed to take effect next frame |

Making the scrollbar paint alone is not enough: a track that hit-tests where there is nothing to scroll steals clicks
from the content under it, and whether there is anything to scroll is a layout output. So paint-time content needs hit
regions and semantics that follow paint geometry.

Where the engine lives decided most of this. Every input to layout, and every consumer of its feedback, is in Haxe: the
tree and what changed in it (signals, recorded reads, per-node revisions, `TreeDiff`), the builders a virtual list would
run during layout, the painters whose hit regions and semantics a scrollbar needs. A native engine would mirror the tree
and rediscover each change from a record diff, and build during layout by calling back into the VM mid-solve. Native
keeps what is native by nature: text shaping and measurement, rasterization, the compositor and the GPU.

A prototype settled whether Haxeon is fast enough. A full solve of the explorer's trees in Haxeon took about 0.14 ms on
the JIT and allocated nothing, against Clay's 3.3 ms, with sizes differing from Clay's on under 1% of nodes.

## Decision

1. **Layout is solved in Haxeon**, by `haxeon.ui.layout.LayoutSolver`: fit sizes go up, sizes come down (percent, then
   grow by weight up to maximums, or shrink largest first down to minimums), widths before heights so text wraps at its
   width, then positions from distribution and alignment, wrapped lines, baselines, and absolute and anchored nodes. The
   rules are ours, not Clay's, and documented on the solver; Clay is not a compatibility target.
2. **Native builds the scene from the solver's geometry.** Each submit sets one record per node with
   `nkui_layout_session_set_geometry` (bounds, where its text goes, its baseline); the scene builder resolves transforms,
   clips, content and hit bounds, shapes text at the given widths, and emits the paint primitives in paint order. The
   solver measures text with `nkui_layout_session_measure_text` on the session's fonts and keeps the results per node,
   and measures custom content through `LayoutContent`, keeping each node's last results per version and constraints.
   The C API keeps no layout: a C host supplies its own geometry, as `native/examples/ui_c_api` does.
3. **Retained and incremental.** Each node keeps its last constraints and result; a change marks it and its ancestors
   dirty up to a relayout boundary, a node whose size does not depend on its children. A frame lays out the dirty
   subtrees only. The per-node records then go: the solver hands native one scene record per changed node.
4. **Builders that run during layout.** A node may build its children from its constraints: a virtual list asks for the
   rows that fit, during the solve, and the window rebuild passes go.
5. **Floating nodes after the flow**, placed by `LayoutAnchor`, which gains a size limit from the room beside its anchor.
6. **Paint geometry with hit regions and semantics.** A painter declares the regions it hit-tests and the semantics it
   exposes from the geometry it paints with. The scrollbar becomes one node per axis that paints its track and thumb from
   its scroll controller; scroll metrics are reported during layout, so clamping and reveal need no pass.
7. **Truncation in the text layout**: end and middle ellipsis as paragraph style, applied while measuring.
8. **No layout feedback.** With these, a geometry callback reads geometry and never edits the tree.
   `requestLayoutFeedback`, the pass loop in `UiContext` and, with ADR 0002's stage 7 (layers), `willEditRetained` and
   `RetainedAnimation` are deleted, and layout becomes one pure stage of the frame pipeline.

## Migration

1. Done: the solver, the geometry hand-off and text measurement; Clay, its backend, its native tests, the native measure
   callback and the linear reference engine deleted; native tests place their fixtures with `tests/fixture_geometry.h`.
2. Retained relayout with relayout boundaries and scene records; checked by comparing an incremental solve with a
   from-scratch one on every frame in verify mode.
3. Paint hit regions and semantics; the scrollbar on them; scroll metrics during layout.
4. Truncation; `MiddleEllipsisText` on it. The anchor's size limit; `SelectionPopup` on it.
5. Layout-time builders; the virtual collections on them. The state-writing callbacks, case by case.
6. Delete the feedback loop; then stage 7's layers delete `willEditRetained`.

The frame count of solves (`UiFrameMetrics.layoutSolves`) falls to one on every smoke frame by the end.

## Consequences

- Layout costs a fraction of a millisecond on the measured trees, and will follow what changed once retained.
- Text is measured by the solver and shaped by the scene builder; both use the text engine's layout cache, so text is
  shaped once per text, style and width.
- Layout semantics are tested in Haxe (`LayoutSessionSmoke`, the framework and showcase suites, the web visual suite);
  the native tests cover the scene builder, records, hit testing and rendering.
- Some layouts differ from Clay's where the rules differ, such as measured content widening a fitting parent; the web
  visual goldens were updated where they did.

## Alternatives considered

- **A native engine of our own in C++** (this ADR's first draft). Fast per operation, but it mirrors the tree, cannot see
  what changed without a diff, and needs re-entrant calls into Haxe for layout-time builders and painter regions.
- **Re-solve only changed floating subtrees with Clay** (ADR 0002's revised decision 6). It cuts the scrollbar's passes
  but keeps the loop, the whole-tree solves and the post-layout code.
- **Keep Clay and accept the passes.** Each cost about 7 ms on the measured trees, on most frames that change anything.

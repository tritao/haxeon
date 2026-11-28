# 9. A retained, incremental layout engine of our own, with no layout feedback

Date: 2026-11-28

## Status

Proposed. It supersedes the layout half of [ADR 0002](0002-reactive-ui-model.md): decision 6 (floating nodes placed after
the flow, two-phase layout) and the clause that kept Clay "an immediate full solver" until "measurements later show layout
as the main remaining cost". They now do. Anchored placement (`LayoutAnchor`, landed with decision 6) is kept and becomes
part of this engine.

## Context

A frame lays the whole tree out with Clay, then runs geometry callbacks (`RenderNode.onResolved`). Some of them compute
something that depends on the geometry, edit the tree (`BuildContext.willEditRetained`), and ask for another pass
(`requestLayoutFeedback`), which lays the whole tree out again, up to eight times (`UiContext`).

Measured on the native explorer smoke (2026-11-28, `HAXEON_UI_RENDER_COST=1`, `HAXEON_UI_LAYOUT_COST=1`; ADR 0002 records
the numbers): 28 of 46 frames took two or three solves. 20 of those came from the scrollbar's geometry, 8 from virtual
lists rebuilding their window. A Clay solve of these 200 to 2,000-node trees took about 3.3 ms, most of a frame's layout
(a one-solve frame 3.9 ms, a two-solve frame 10.8 ms). Clay keeps no state between solves, so every solve costs the
whole tree, whatever changed.

The feedback comes from four kinds of geometry-dependent content, each computed in the wrong place:

| Content | Today | Where it belongs |
| --- | --- | --- |
| Scrollbar thumb, its visibility and its accessible range | nodes edited after layout from the viewport and content extents | paint and hit geometry derived at paint time, as Flutter's scrollbar painter does |
| Virtual list window | rebuilt after layout from the viewport and offset | children built during layout, from the constraints, as Flutter's slivers and Compose's lazy layouts do |
| Middle ellipsis | text replaced after layout from the width | a truncation mode of the text layout |
| A popup limited to the room beside its anchor | sized at build from last frame's geometry | a size limit of the anchor, applied when it is placed |

Making the scrollbar paint alone is not enough: a track that hit-tests where there is nothing to scroll steals clicks
from the content under it, and whether there is anything to scroll is a layout output. So paint-time content needs hit
regions and semantics that follow paint geometry, which is the engine's and the layers' business, not a widget's.

## Decision

1. **Our own layout engine replaces Clay**, in `packages/ui/native/src/layout`, behind the same node records, transactions
   and resolved-item output, so the Haxe side barely changes. Text keeps the existing text engine.
2. **Constraints down, sizes up, and retained.** Each node keeps its last constraints and result; a change marks the node
   and its ancestors dirty up to a relayout boundary, a node whose size does not depend on its children (fixed or
   parent-determined). A frame lays out the dirty subtrees only, so its cost follows what changed, not the tree.
3. **Builders that run during layout.** A node may build its children from its constraints (a callback into the build,
   as Flutter's `LayoutBuilder` and slivers do): a virtual list asks for the rows that fit, during the solve. The window
   rebuild passes go.
4. **Floating nodes after the flow**, placed by `LayoutAnchor`, which gains a size limit from the room beside its anchor.
   A float is its own relayout boundary, so moving one reruns its placement, and resizing one re-solves it alone.
5. **Paint geometry with hit regions and semantics.** A custom painter can declare the regions it hit-tests and the
   semantics it exposes from the geometry it paints with, recomputed at paint time; changing them needs no layout. The
   scrollbar becomes one node per axis that paints its track and thumb from its scroll controller and declares the
   thumb's region and the slider's range.
6. **Truncation in the text layout**: end and middle ellipsis as paragraph style, applied while measuring.
7. **No layout feedback.** With these, a geometry callback reads geometry and never edits the tree. `requestLayoutFeedback`,
   the pass loop in `UiContext` and, with ADR 0002's stage 7 (layers), `willEditRetained` and `RetainedAnimation` are
   deleted, and layout becomes one pure stage of the frame pipeline.

## Migration

1. The engine with Clay's feature set (rows and columns, wrap, fit, grow and percent sizing with limits and weights,
   alignment and distribution, aspect ratio, padding and gaps, clipping, floats, measured content), behind a session
   option. Verify mode lays every frame out with both and compares the resolved items and primitives byte for byte, as
   the linear reference layout was verified before; every UI suite runs under it.
2. Retained relayout with relayout boundaries; measured against Clay's full solve on the explorer smoke and the dock.
3. Paint geometry with hit regions and semantics; the scrollbar on it.
4. Truncation; `MiddleEllipsisText` on it. The anchor's size limit; `SelectionPopup` on it.
5. Layout-time builders; the virtual collections on them.
6. Switch the session to the engine, delete Clay and the feedback loop; then stage 7's layers delete `willEditRetained`.

Each step lands with its suites passing under verify mode, and the frame count of solves (`UiFrameMetrics.layoutSolves`)
falls to one wherever it fell to one before.

## Consequences

- Layout cost follows the change, and feedback passes disappear by construction instead of being made cheaper.
- The engine is ours to keep: Clay's behaviour has to be matched exactly first, which verify mode makes checkable, and its
  vendored fork goes.
- Widgets lose a class of post-layout code (scrollbar, ellipsis, popup sizing, window rebuilds) that each solved the same
  problem by hand.

## Alternatives considered

- **Re-solve only changed floating subtrees with Clay** (ADR 0002's revised decision 6, phase two). It cuts the scrollbar's
  passes but keeps the loop, the whole-tree solves and the post-layout code, on an engine this replaces.
- **The scrollbar's geometry in C++.** It moves the formula out of Haxe, cannot see Haxe-provided content extents, and
  serves only scrollbars; ADR 0002 rejected it for those reasons.
- **Keep Clay and accept the passes.** Each costs about 7 ms on the measured trees, on most frames that change anything.

# UI architecture notes (2026-10-30)

A summary of the architecture discussions held after the retention, reconcile and layout bridge work. The decisions
they led to are in [ADR 0002](../../../docs/adr/0002-reactive-ui-model.md); this records the reasoning, the comparisons and
the questions that were settled along the way.

## Where the UI stands

The model is **declarative build over a retained tree**: authors write builds as if the whole UI were rebuilt each
frame, and the framework skips what it can prove unchanged.

- Retained subtrees (`RetainedView`, dock caches) are reused while their recorded dependencies match: widget-state
  revisions, observed reads (`observe*`) and the interaction state they were built from.
- Self-updating widgets rebuild alone and are reconciled into their existing node (`RenderNode.reconcile`); controller
  edits are announced with `willEditRetained`. A frame with only these is a patch frame and builds no view.
- Verify mode rebuilds from scratch and compares, so a missed dependency fails the gates instead of showing stale UI.
- Layout is incremental across the native boundary: only changed nodes are sent and only changed geometry returns.

Same-machine headless numbers: hover and typing about 0.4 ms of UI work, a tab switch 1.2–1.7 ms, selection about 3 ms
with two layout passes. Allocation per action: tab switch 112–165 KiB (from 301–362 on 2026-10-29), hover 13–25 KiB,
typing 17.8 KiB, idle 0.2 KiB. The layout bridge (encode, parse, prepare, decode) fell 88% on interaction and 55% on tab
switches. Details: `RETAINED_SUBTREES.md`, `LAYOUT_COST.md`.

## Generated structural code

`@:structural` classes get compiler-generated `copy`, `hash`, `changedMask`, `assignChanged`, `fieldBit` and
`allFieldsMask`, and `haxeon.Equality.equals` compares them by field (`haxeon/docs/STRUCTURAL_EQUALITY.md`). This removed
the hand-maintained style field lists, which had drifted (the node fingerprint skipped corner radii).

Remaining hand-written field lists, and whether to add compiler features for them:

- **Dock label-width cache key.** Builds a string on every lookup. Worth fixing, without a compiler feature: a
  `@:structural` key class looked up by `Structural.hash` and confirmed by `Equality.equals`, with a reused scratch key.
  Queued.
- **Style resolver value keys.** Cached per parent style, so off the hot path, and guarded by a test. Not worth it now.
- **`Semantics.same`.** Needs a per-field exclusion or custom comparison (`@:structural.skip`). Guarded by a test that
  changes every field; add the feature when a second class needs it.
- **`Mask`** compares its image by identity on purpose.

## Comparison with GPUI (Zed)

GPUI rebuilds and caches; we retain and patch.

| | GPUI | Haxeon UI |
|---|---|---|
| Memory | Rust; per-frame elements in an arena | HashLink GC; allocation is tracked per action |
| Core model | `render()` makes a throwaway element tree; cached views replay prior layout and paint | one long-lived node tree, patched in place |
| Invalidation | explicit `cx.notify()` | recorded reads, automatic |
| Correctness check | none built in | verify mode in the gates |
| Layout | Taffy, in-process | Clay, native, incremental bridge |
| Rendering | scene of primitives; cached views reuse their scene range | full render compile per changed frame (being made incremental) |

GPUI is ahead on paint reuse, near-free per-frame allocation and the absence of a layout boundary, and in maturity. We are
ahead on automatic dependency tracking with verification, single-node updates, generated style code, accessibility and a
Wasm target. Its scene-range reuse confirms the direction of the render work; its previous/current text-layout cache is
worth comparing with ours.

## A per-frame arena

Not now. Collections already run in idle time (0.7 ms average), no tab-matrix interaction contains one, GC is under 0.1%
of time on the heavy simulation scene, and incremental GC was tried and lost. More importantly, most of what a frame
allocates in a retained model outlives the frame (listeners, nodes, styles stored in the tree), so an arena would need
escape proofs, and a mistake would be memory corruption that verify mode cannot catch. If allocation needs compiler work,
escape analysis with scalar replacement is the safe form; a young generation in the HashLink fork is the GC-native form
but hard with conservative stack scanning. Reconsider if GC marking shows in interaction p99.

## Is the current model right?

It works and is verified, but it grew one mechanism per case: retained caches and keys, three ways to record a dependency,
`selfUpdating` with `reconcile`, `BuiltNode` and `RenderNode.latest`, `requestPatch` with `updateQuietly`,
`willEditRetained` with priors and `RetainedAnimation`, patch frames, and binding revisions for widgets that cannot be
patched while hidden. Recent work spends its time on the edges between them. `updateQuietly` depends on the author knowing
who reads the state.

Most of these are one idea at different sizes: a scope records what it reads, re-runs when one of those values changes,
and updates the existing nodes. That idea is what the ADR adopts.

## Designing from scratch

The ADR's target: tracked values (signals) as the only dependency mechanism; components that run once and bind signals to
node properties, with keyed `Show`/`For`/`Switch` for structure; compiler support to infer bindings and reject untracked
reads; a flat node store shared with native code, so there is no layout encode or decode; interaction state as signals and
style rules as derived values; incremental native layout with the scrollbar as a layout constraint; retained per-node
display lists with scroll, transform and opacity as layer properties; and the same verification against a fresh store.

## Run-once components versus React/GPUI rebuilding

Two decisions are separate:

1. **The engine** (signals, shared store, incremental layout, retained rendering) is right for any component model.
   React Native and GPUI moved the same way.
2. **The component model** is the real choice. Rebuild models are easier to read and debug, handle structural churn well
   and are proven at scale. Run-once wins here because the goal is near-zero allocation per interaction on a
   non-generational GC, because bindings write the shared store with nothing to compare or transfer, because the editor is
   mostly static panels full of live values, and because we own the compiler that can catch run-once's characteristic
   bug. If the goal were only "fast enough", the current rebuild model already meets it.

Compose-style re-running scopes are the middle option: plain control flow with automatic dependencies, at some allocation
per re-run. The ADR's stage 3 converts one live panel each way on the same signals and decides by measurement. The
expected result is bindings for leaf widgets and live values, small re-running scopes where structure is dynamic.

## Next steps

1. Let the current Codex session (remaining panels, Tabs/SelectionPopup, render-side cost and incremental render compile)
   finish.
2. Apply the queued cleanups: lazy state initial values, a hobbing-player revision, one per-frame camera update, required
   BIM width, BIM default selection, the structural dock label key.
3. Start ADR 0002 stage 1: signals under `State` and `observe*`.
4. Language and compiler features the design needs, in order: `haxeon/docs/UI_LANGUAGE_FEATURES.md`.

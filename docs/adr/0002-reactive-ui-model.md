# 2. Reactive UI model: tracked values over a shared node store

Date: 2026-10-30

## Status

Proposed. Stage 1 starts after the current retention and render work in `packages/ui` lands. The component model
(decision 2) is confirmed or revised by the stage 3 experiment. The discussion behind this record, including the comparison
with GPUI and the per-frame arena question, is summarized in `packages/ui/docs/ARCHITECTURE_NOTES.md`.

## Context

The UI package builds a view each frame and does as little of that build as it can prove safe. It is fast: hover and typing
cost about 0.4 ms of UI work, a tab switch 1.2–1.7 ms, and the Haxe↔native layout bridge is now incremental. Verify mode
rebuilds from scratch and fails on any difference, so stale UI is a gate failure, not a bug report. See
`packages/ui/docs/RETAINED_SUBTREES.md` and `LAYOUT_COST.md`.

The way it got there is one mechanism per case. An author or maintainer has to know retained caches and keys, observed
reads, state revisions, interaction snapshots, `selfUpdating` and `reconcile`, `BuiltNode`, `RenderNode.latest`,
`requestPatch`, `updateQuietly`, `willEditRetained` and its priors, `RetainedAnimation`, patch frames, and binding
revisions for widgets that cannot be patched while hidden. Each was a correct fix; the recent work spends more of its time
on the edges between them (composite updaters, ordering of announced edits and patches, unmounted registrations).
`updateQuietly` is correct only when the author reasons correctly about who reads the state.

Two costs remain structural rather than incidental:

- **Allocation.** A rebuild allocates nodes, closures and style objects. With caching, steady interactions still allocate
  13–25 KiB each and a tab switch over 100 KiB. Rebuild models elsewhere pay little for this (React has a generational
  GC, GPUI an arena); HashLink's GC is not generational, and the goal is near-zero allocation per interaction.
- **The native boundary.** Every changed frame compares trees and transfers changed nodes to native layout, and a
  layout-dependent widget (the scrollbar) needs a second layout pass.

Most of the mechanisms above are one idea at different sizes: a scope records what it reads, re-runs when one of those
values changes, and updates the existing nodes. This record makes that idea the model.

## Decisions

1. **One dependency mechanism: tracked values.** `Signal<T>` holds a value, `Derived<T>` caches a computation over signals,
   `Effect` runs a side effect. Reading a signal inside a tracking scope records the dependency; writing it marks exactly its
   readers dirty. Writes batch per frame; invalidation is push (mark dirty) then pull (recompute lazily when read), so
   there are no glitches or repeated work. `State`, `observe*`, state revisions, interaction snapshots and cache keys all
   become this. External models join through one adapter, `Signal.fromRevision(() -> model.revision)`, sampled once per
   frame; models expose one revision rather than many observed fields.
2. **Components run once; changes flow through bindings.** A component function runs at mount, creates nodes and binds
   signals to node properties. A change re-runs only the binding, which writes one field. Structural change goes through
   keyed primitives that own child scopes: `Show`, `For` (by key), `Switch`. Only they create or destroy nodes. Scopes own
   their children and cleanup, so unmounting disposes everything under it. This replaces retained caches, `selfUpdating`,
   `reconcile`, `BuiltNode`, `RenderNode.latest`, `requestPatch`, patch frames and binding revisions.
3. **The compiler supports the model.** Haxeon compiles component bodies so a signal read in a property position becomes a
   binding, and reports a signal read outside any tracking scope (the characteristic bug of run-once components) in
   debug builds.
4. **Nodes are records in a flat store shared with native code.** Stable handles (index and generation); one record per
   node, with dirty bits per channel: layout, paint, text, semantics, transform. Bindings write fields and set bits;
   native layout and rendering read the same memory. There is no encode, parse or decode. Record layout, change masks and
   channels are generated from `@:structural` declarations, so adding a style property updates all of them.
5. **Interaction state is signals; style rules are derived values.** Hovered, pressed, focused and disabled are per-node
   signals. Stylesheet rules compile to derived values over them, so a pointer move recomputes only the properties whose
   rules read hover, on the two nodes involved. This replaces `InteractionStateSnapshot` and `hoverRebuilds`.
6. **Layout is incremental and native.** The engine caches each node's measurement and solution; a dirty node invalidates
   itself and its ancestors up to a fixed-size boundary, and the solve reuses the rest. Text measurement is cached by
   content and style. Layout-dependent geometry is a layout constraint, not feedback: scrollbar track and thumb are solved
   from content and viewport size, so the selection frame's second pass disappears. Solved geometry is written to the store
   and readable as signals.
7. **Rendering is retained per node, with layers.** Each node keeps its recorded display-list segment; only paint-dirty nodes
   re-record. Scroll offset, transform and opacity are layer properties: scrolling changes a layer offset, with no
   re-recording and no layout. Animations are signals driven by the frame clock and bound to these properties. This replaces
   `willEditRetained` and `RetainedAnimation`.
8. **Semantics and input use the same store.** The accessibility tree updates from semantics dirty bits. Events dispatch by
   hit test on solved geometry to handlers attached once at mount.
9. **Verification stays, and gets stronger.** Debug mode mounts the application fresh into a second store, runs full layout
   and paint, and compares records, geometry and display lists byte for byte. The reactive core rejects untracked reads in
   bindings and store writes that do not come from a binding.

## Mapping from today

| Today | Becomes |
|---|---|
| `context.state`, `State.update` | `Signal` |
| `observeInt/Bool/String`, `cacheKeyHash` | tracked reads; `Signal.fromRevision` for external models |
| `State.updateQuietly` | removed: writes know their readers |
| `RetainedView`, dock pane and panel caches | removed: components run once |
| `selfUpdating`, `reconcile`, `BuiltNode`, `RenderNode.latest` | bindings |
| `requestPatch`, patch frames | a frame where only bindings ran |
| `bindingRevision` | a scope dirtied while hidden runs when shown |
| `InteractionStateSnapshot`, `hoverRebuilds` | per-node interaction signals and derived style |
| `willEditRetained`, `RetainedAnimation` | layer properties and animation signals |
| `LayoutTransaction` encode / native parse / decode | shared store |
| second layout pass for scrollbars | scrollbar layout constraint |
| `UiContext.verifyRetention`, fingerprints | fresh-store comparison; untracked-read checks |

## Migration

Each stage deletes mechanisms rather than adding them. Each passes the existing gates — UI scripts, every-frame
retention scenarios, budgets that may only go down, memory runs, compiler suites — before the next starts.

1. **Signals core under the current API.** `State` and `observe*` become signals and tracked reads; dependency records
   are reusable arrays, not per-frame allocations. `updateQuietly` becomes an error in verify mode when a tracked reader
   exists. Go: gates pass and no action allocates more.
2. **Shared node store.** Move node fields into flat records with dirty channels shared with native, keeping `RenderNode`
   as a handle-based view over the store so callers are unchanged. Delete the transaction encode and decode. Go: bridge
   phases at zero, no frame-time regression.
3. **Component model experiment.** Convert one live panel (CNC or telemetry) to run-once bindings with `Show`/`For`, and
   another to small re-running scopes (Compose style) on the same signals. Compare allocation, frame time and how the
   code reads. Decide decision 2 from the result and amend this record. The expected outcome is bindings for leaf widgets
   and live values, and small re-running scopes only where structure is genuinely dynamic.
4. **Compiler support.** Binding inference in component bodies, untracked-read diagnostics.
5. **Widgets, then panels.** Convert leaf widgets to bindings and delete `selfUpdating`/`reconcile`; convert panels and
   delete retained caches, patch frames and binding revisions. Interaction signals and derived style replace hover handling.
6. **Incremental native layout.** Per-node layout caches over the store; scrollbar constraint; remove layout feedback for
   it. Clay is replaced, or kept only for its algorithms.
7. **Retained rendering and layers.** Per-node display-list segments and layer properties; delete `willEditRetained` and
   `RetainedAnimation`.

## Consequences

- Authors learn four things: signal, binding, `Show`/`For`, effect. Most of the mechanisms listed under Context are
  deleted.
- Steady-state updates write fields; allocation happens on mount and unmount, not per interaction.
- The layout bridge disappears, and layout-dependent geometry costs one pass.
- Code in a component body runs once: a plain `if` over a signal does not update, and must be `Show`. Compiler checks
  limit this; it remains the main learning cost.
- Debugging moves from "why did this rebuild" to "why did this binding not run". Signal dependency inspection becomes a
  required tool.
- External mutable models need revision adapters; deeply nested ones need more work.
- The work is large: reactive core, store, native incremental layout, retained display lists and compiler support.

## Alternatives considered

- **Keep the current model and clean its edges.** It meets "fast enough" today (GC is under 0.1% of time), but it keeps the
  mechanism count, keeps allocation per interaction as an optimization target rather than a property, and keeps the bridge.
- **Rebuild and cache (React, GPUI).** The simplest model to read and debug, and cheap structural change. Its per-update
  allocation is what we cannot make free on a non-generational GC, and it still needs comparison and transfer to native.
  The engine decisions (1, 4, 6, 7) apply to it too; only decision 2 differs.
- **Re-running scopes (Compose).** Plain control flow with automatic dependencies; allocation per re-run, kept small by
  small scopes. The stage 3 experiment compares it directly with bindings.
- **A per-frame arena allocator.** Most of what a frame allocates outlives it in the retained tree, so an arena would need
  escape proofs to be safe, and GC cost is already low. Escape analysis in the compiler is the safe form, and is independent
  of this record.

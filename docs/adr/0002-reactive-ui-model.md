# 2. Reactive UI model: tracked values over a shared node store

Date: 2026-10-30

## Status

Proposed. Stage 1 starts after the current retention and render work in `packages/ui` lands.

The decisions do not carry the same confidence, and the migration treats them differently:

- **Committed:** tracked values (1), interaction state as signals (5), retained rendering with layers (7), semantics and
  input from the same model (8), verification (9). Mature UI frameworks have converged on each, and each removes
  mechanisms we have today.
- **Pending an experiment:** the run-once or re-running implementation of components (2). Stage 3 decides; the
  author-facing builder syntax is the same for either implementation.
- **Options that must prove themselves:** the shared native store (4) and an incremental layout engine (6). After the
  incremental bridge, the interaction bridge costs 0.036 ms and Clay's full solve about 0.14 ms, so neither is justified by
  speed alone. Each gets a prototype and a measured go/no-go before any migration. Local placement of independent
  feedback edits (also decision 6) is committed: it is small, lives in our backend and removes the selection frame's
  second solve.

The rationale for this record is mostly simplicity, and making near-zero allocation a property of the design rather than
an optimization target: the current model is already fast (hover and typing about 0.4 ms). The expensive parts have to
earn their place. The discussion behind this record, including the comparison
with GPUI and the per-frame arena question, is summarized in `packages/ui/docs/ARCHITECTURE_NOTES.md`. The language and
compiler features it needs are in `docs/UI_LANGUAGE_FEATURES.md`.

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

1. **One dependency mechanism: tracked values.** `Signal<T>` holds a standalone value, `Derived<T>` caches a computation,
   and `Effect` runs a side effect. Models we own can declare `class Model implements Observable { public var phase:Phase; }`
   and retain ordinary field syntax. The compiler instruments each field read inside a tracking scope to record the
   object and field bit after one flag check; a changed write marks only that field's readers dirty. One dependency list
   belongs to each object, with no per-field `Signal` objects or revision counters. `Observable` applies to classes;
   structs have no identity, so a struct-valued observable field is tracked as one field. A signal is effectively a
   one-field observable. Signal and observable-field writes that do not change the value are skipped, using the type's
   declared `Equatable` conformance or identity for nonconforming classes, as in Compose and Solid.

   Writes batch per frame; invalidation is push (mark dirty) then pull (recompute lazily when read), so there are no
   glitches or repeated work. `State`, `observe*`, state revisions, interaction snapshots and cache keys become this.
   All current models are ours and become `Observable`; add an adapter only if a real external model appears.
   Per-field signal objects allocate and require `.get()`/`.set()`; revision counters invalidate unrelated readers and a
   missed increment leaves stale UI. Precedents include Swift Observation, MobX observable objects, Vue `reactive()`,
   Svelte 5 class fields and Solid stores.
2. **Option: components run once; changes flow through bindings.** A component function runs at mount, creates nodes and binds
   signals to node properties. A change re-runs only the binding, which writes one field. Structural change goes through
   keyed primitives that own child scopes: `Show`, `For` (by key), `Switch`. Only they create or destroy nodes. Scopes own
   their children and cleanup, so unmounting disposes everything under it. This replaces retained caches, `selfUpdating`,
   `reconcile`, `BuiltNode`, `RenderNode.latest`, `requestPatch`, patch frames and binding revisions.
3. **General language features support component syntax; the compiler does not know UI concepts.** A result builder
   declared by a library combines sequential statements, `if` with or without `else`, `switch` and `for` by rewriting
   each form into builder calls. An interface can attach the builder to a method, and implementations inherit it:
   `interface View { @:builder(ViewBuilder) function body():View; }`. Helpers opt in with `@:builder(ViewBuilder)`.
   The library's signature supplies list keys, for example `forEach<T:Identifiable>`, so an unkeyed list is an ordinary
   bound error. Each form has one fixed lowering signature, with no overload resolution across builder methods; errors
   point at the user's control flow and type checking stays fast, avoiding Swift result builders' diagnostic and cost
   problems.

   A general lazy parameter such as `function label(text:Lazy<String>):View` lets a caller write
   `label(cup.phase.toString())`; the compiler passes the expression unevaluated and the library turns it into a binding.
   Lazy parameters also serve logging, assertions and defaults. `Observable` supplies tracked reads. The library, not
   the compiler, chooses run-once bindings or re-running scopes, with identical author code either way. Reads outside a
   tracking scope are a runtime debug check (decision 9); builder control flow prevents the usual untracked plain `if`
   in a run-once component.

   Stateful components are classes `implements View` with `body()`, their own tracked `var` state, and cached derived
   getters when purity inference proves eligibility. Stateless composition uses plain functions returning `View`,
   explicitly builder-annotated when they use control flow. Props are constructor arguments and final fields, using
   `Lazy<T>` where they must remain live; public mutable prop fields are not used. UI-specific compiler intrinsics are
   added only if profiling finds a gap the general optimizer cannot close.
4. **Option: nodes are records in a flat store shared with native code.** Stable handles (index and generation); one record per
   node, with dirty bits per channel: layout, paint, text, semantics, transform. Bindings write fields and set bits;
   native layout and rendering read the same memory. There is no encode, parse or decode. Record layout, change masks and
   channels are generated from `Diffable` field numbering and `@Channel(...)` annotations. Observable field bits,
   `Diffable` masks and channel masks share one numbering per type; bindings write fields and dirty the channel masks.
   The costs: strings, text, callbacks and object references do not fit native records and need side tables, and raw
   records are harder to inspect than objects. With the incremental bridge, the speed gain is small; the case rests on
   deleting the transaction code. Adopted only if the stage 2 prototype shows a net simplification.
   Records are `Flat` structs from `docs/STRUCTS.md`, the design written for Beartooth's world components: one C layout
   inline in GC memory and in native memory, in-place field writes through `NativeSpan` and `p.ref`, and inferred flatness
   that splits native from managed fields, as Beartooth's world splits native from managed columns. That makes the side
   tables a compiler-derived split rather than hand-written bookkeeping, and the prototype depends on `STRUCTS.md`
   stages 2 and 3.
5. **Interaction state is signals; style rules are derived values.** Hovered, pressed, focused and disabled are per-node
   signals. Stylesheet rules compile to derived values over them, so a pointer move recomputes only the properties whose
   rules read hover, on the two nodes involved. This replaces `InteractionStateSnapshot` and `hoverRebuilds`.
6. **Feedback edits to independent nodes are placed locally, without another solve; incremental layout is an option.**
   A geometry callback may still edit layout inputs after the solve. When every edited node is *independent* (absolutely
   positioned or floating, fixed size, and its parent's size does not depend on it), the layout backend places those nodes
   and their independent descendants directly: parent origin plus position, fixed size, inherited clip. Otherwise it falls
   back to a full solve. The scrollbar's track and thumb are such nodes, so the selection frame's second solve disappears
   while the scrollbar logic stays in Haxe and virtualized lists keep supplying their content extent from Haxe. The same
   step covers other feedback of this kind, such as scroll-offset clamping (a pure translation) and overlay placement.
   It lives in our backend, not in Clay, which stays an immediate full solver. Absolute overlays are excluded from their
   parent's content bounds, so a scrollbar never reads as content overflow. Verify mode compares every local placement
   with a full solve. Rejected: native scrollbar geometry (moves the formula to C++, cannot see Haxe-provided content
   extents, serves only scrollbars) and a scrollbar constraint inside Clay (deeper changes to a vendored fork for what the
   backend can do on top). Solved geometry is readable as signals. A layout engine of our own that caches each node's solution, invalidating a
   dirty node and its ancestors up to a fixed-size boundary, is considered only if measurements later show layout as the
   main remaining cost; Clay's full solve is about 0.14 ms today.
7. **Rendering is retained per node, with layers.** Each node keeps its recorded display-list segment; only paint-dirty nodes
   re-record. Scroll offset, transform and opacity are layer properties: scrolling changes a layer offset, with no
   re-recording and no layout. Animations are signals driven by the frame clock and bound to these properties. This replaces
   `willEditRetained` and `RetainedAnimation`.
8. **Semantics and input use the same store.** The accessibility tree updates from semantics dirty bits. Events dispatch by
   hit test on solved geometry to handlers attached once at mount.
9. **Verification stays, and gets stronger.** Debug mode mounts the application fresh into a second store, runs full layout
   and paint, and compares records, geometry and display lists byte for byte. The reactive core rejects untracked reads in
   bindings and store writes that do not come from a binding.
   **Read-only phases are enforced at runtime.** While a tracking scope runs (a build or component setup, a derived value,
   a binding, an observed getter), writing a signal, observable field or `State` throws at the write, with its stack trace, as Svelte 5
   (`state_unsafe_mutation`) and Compose do. It costs one flag check per signal write and is on in debug builds and every
   gate, not only verify runs. State the UI depends on lives in signals (decision 1), so this covers the writes that made
   panels hard to retain; plain internal fields stay plain and verify mode covers their effect on output. A compile-time
   purity contract (`docs/PURITY.md`) is deferred until these checks show real holes.

For example, a panel today records a revision and constructs keyed children explicitly:

```haxe
function build(context:BuildContext):View {
	context.observeInt(() -> model.revision);
	var children = [new KeyedView("phase", label(model.phase.toString()))];
	if (model.ready) children.push(new KeyedView("ready", readyBadge()));
	for (item in model.items) children.push(new KeyedView(item.id, itemView(item)));
	return new Column("panel", children);
}
```

With the planned general features, the same component can be written schematically as:

```haxe
class Panel implements View {
	final model:Model;
	public function body():View {
		label(model.phase.toString()); // label takes Lazy<String>
		if (model.ready) readyBadge();
		for (item in model.items) itemView(item); // item is Identifiable
	}
}
```

`View` supplies the builder, `Observable` tracks `model` fields, and the library decides whether these bindings run once
or the scope re-runs. Panels do not need rewriting when the stage 3 experiment chooses between those implementations.

## Mapping from today

| Today | Becomes |
|---|---|
| `context.state`, `State.update` | tracked component fields or standalone `Signal` |
| `observeInt/Bool/String`, model revision counters, `cacheKeyHash` | observable fields and tracked reads |
| `State.updateQuietly` | removed: writes know their readers |
| `RetainedView`, dock pane and panel caches | removed: components run once |
| `selfUpdating`, `reconcile`, `BuiltNode`, `RenderNode.latest` | bindings |
| `requestPatch`, patch frames | a frame where only bindings ran |
| `bindingRevision` | a scope dirtied while hidden runs when shown |
| `InteractionStateSnapshot`, `hoverRebuilds` | per-node interaction signals and derived style |
| `willEditRetained`, `RetainedAnimation` | layer properties and animation signals |
| `LayoutTransaction` encode / native parse / decode | shared store if its prototype passes; otherwise the incremental bridge stays |
| second layout pass for scrollbars | local placement of independent feedback edits |
| `UiContext.verifyRetention`, fingerprints | fresh-store comparison; untracked-read checks |

## Migration

Each stage deletes mechanisms rather than adding them. Each passes the existing gates — UI scripts, every-frame
retention scenarios, budgets that may only go down, memory runs, compiler suites — before the next starts.

0. **Structs for small values — done.** `Rect`, `Insets`, `Color`, `LayoutAxis` and `Transform2D` are immutable
   structural structs, stored inline in `LayoutStyle`. Nullable fields have inline presence flags, eligible temporary
   values stay scalar, and Wasm GC flattens their fields. See [UI value types](../../packages/ui/docs/VALUE_TYPES.md)
   for the retained-holder and typed-style designs and measurements. The interaction, tab-matrix and selection-stress
   censuses allocate none of the five types after setup; their real Dynamic and reflection escapes still box.
1. **Signals core under the current API.** `State` and `observe*` become signals and tracked reads; dependency records
   are reusable arrays, not per-frame allocations. `updateQuietly` becomes an error in verify mode when a tracked reader
   exists. Writes to signals or `State` inside a tracking scope throw in debug builds and gates (decision 9). Go: gates
   pass and no action allocates more.
1b. **Observable models.** Implement compiler-generated `Observable` field tracking, test it on every target and cover
   it in verify mode. Convert revision-adapter models we own, including hobbing `statusRevision`, BIM and CNC, and delete
   their counters. This does not depend on the stage 3 run-once experiment. Go: gates pass and no action allocates more.
2. **Shared node store prototype.** Move one channel (paint) into flat records shared with native, keeping `RenderNode`
   as a handle-based view so callers are unchanged. Compare code size, the side tables needed, debuggability and frame cost
   against the incremental bridge. Go (migrate the remaining channels and delete the transaction code): a net
   simplification with no frame-time or allocation regression. No-go: keep the incremental bridge, record why here, and
   continue with stage 3.
3. **Component model experiment.** Compare run-once bindings and small re-running scopes using the same builder-style
   panel code and tracked model. Measure allocation and frame time, decide decision 2, and amend this record; authors do
   not rewrite panels when the implementation changes.
4. **General compiler support.** Implement result builders and lazy parameters, with separate designs and target tests;
   runtime debug checks enforce tracked reads.
5. **Widgets, then panels.** Convert leaf widgets and panels to the builder API; delete `selfUpdating`/`reconcile`,
   retained caches, patch frames and binding revisions. Interaction signals and derived style replace hover handling.
6. **Local placement for independent feedback edits.** First exclude absolute overlays from content bounds. Then add the
   backend's independence check and local placement, with full-solve fallback, and verify-mode comparison against a full
   solve. Go: selection runs one Clay solve per frame with byte-identical geometry, and no scenario takes the fallback
   where it did not need a second solve before. A layout engine of our own needs its own record, and only when
   measurements show layout as the main remaining cost.
7. **Retained rendering and layers.** Per-node display-list segments and layer properties; delete `willEditRetained` and
   `RetainedAnimation`.

## Consequences

- Authors use tracked state, ordinary builder control flow, lazy props and effects. Most mechanisms listed under Context
  are deleted.
- Steady-state updates write fields; allocation happens on mount and unmount, not per interaction.
- Layout-dependent geometry of independent nodes costs one solve plus a local placement. The layout bridge disappears only if the shared store passes its prototype.
- Builder control flow stays reactive under either component implementation; reads outside tracking scopes are runtime
  debug errors.
- Debugging moves from "why did this rebuild" to "why did this binding not run". Signal dependency inspection becomes a
  required tool.
- Add an adapter only if a real external model appears; deeply nested models need more work.
- The committed work (reactive core, retained display lists) is moderate. Compiler support, a shared store and a layout
  engine are large, which is why they are gated on experiments and measurements.

## Alternatives considered

- **`@:component` or compiler-special-cased `View`.** These teach the compiler UI semantics, couple UI design changes to
  compiler changes and bake the stage 3 choice into the transform. Result builders and lazy parameters are general.
- **AOP-style weaving.** Pattern-matched, non-local rewriting is hard to optimize and conflicts with Haxeon's rule
  against general macros.
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

# UI architecture notes (2026-10-30)

A summary of the architecture discussions held after the retention, reconcile and layout bridge work. The decisions
they led to are in [ADR 0002](../../../docs/adr/0002-reactive-ui-model.md); this records the reasoning, the comparisons and
the questions that were settled along the way.

## Where the UI stands

The model is **declarative build over a retained tree**: authors write builds as if the whole UI were rebuilt each
frame, and the framework skips what it can prove unchanged.

- A component (`ScopeView`) keeps its body while its parent describes it with equal inputs and nothing the body read
  changed; `TrackedScope` makes one from a plain body. The dock's pane and panel caches reuse built subtrees while
  their recorded dependencies match: widget-state values and tracked reads, interaction states included.
- Components run alone when something their body read changes, and keep their body while their parent describes them
  with equal inputs; controller edits are announced with `willEditRetained`. A frame with only these builds no view.
  (Self-updating widgets and `RenderNode.reconcile`, the earlier mechanism, are deleted.)
- Verify mode rebuilds from scratch and compares, so a missed dependency fails the gates instead of showing stale UI.
- Layout is incremental across the native boundary: only changed nodes are sent and only changed geometry returns.

Same-machine headless numbers: hover and typing about 0.4 ms of UI work, a tab switch 1.2–1.7 ms, selection about 3 ms
with two layout passes. Allocation per action: tab switch 112–165 KiB (from 301–362 on 2026-10-29), hover 13–25 KiB,
typing 17.8 KiB, idle 0.2 KiB. The layout bridge (encode, parse, prepare, decode) fell 88% on interaction and 55% on tab
switches. Details: `RETAINED_SUBTREES.md`, `LAYOUT_COST.md`.

## Input event phases

`UiEvent.phase` uses the closed `UiEventPhase` enum: `Capture`, `Target`, or `Bubble`.
Focus, blur and focus-lost capture from root through the target, then deliver at the target without bubbling.
Ancestors observe descendant focus in capture; a component uses its body root as its node identity. Each target
listener runs exactly once in its phase.
See [Event phases](EVENTS.md) for routing, propagation and allocation rules.

## Declared value conformances

`Hashable` and `Diffable` declarations use one generated equality/hash and declaration-order field masks
(`haxeon/docs/STRUCTURAL_EQUALITY.md`). This removed
the hand-maintained style field lists, which had drifted (the node fingerprint skipped corner radii).

Remaining hand-written field lists, and whether to add compiler features for them:

- **Dock label-width cache key.** Builds a string on every lookup. Worth fixing: a `Hashable` key class looked up by
  `Hashing.hash` and confirmed by `Equality.equals`, with a reused scratch key.
  Queued.
- **Style resolver value keys.** Cached per parent style, so off the hot path, and guarded by a test. Not worth it now.
- **`Semantics.same`.** Needs a per-field exclusion or custom comparison. Guarded by a test that
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

It works and is verified, but it grew one mechanism per case: retained caches and keys, `selfUpdating` with `reconcile`,
`BuiltNode` and `RenderNode.latest`, `requestPatch`,
`willEditRetained` with priors and `RetainedAnimation`, patch frames, and binding revisions for widgets that cannot be
patched while hidden. ADR 0002 stages 1 and 1b now supply `Signal`, `Derived`, `Effect` and compiler-tracked `Observable`
fields. Polling reads and owned revision adapters have been removed. The older quiet-write path is gone because changed
signals invalidate their readers directly.

Most of these are one idea at different sizes: a scope records what it reads, re-runs when one of those values changes,
and updates the existing nodes. That idea is what the ADR adopts.

## Designing from scratch

The ADR's target: tracked values (signals) as the only dependency mechanism; components that run once and bind signals to
node properties, with keyed `Show`/`For`/`Switch` for structure; compiler support to infer bindings and reject untracked
reads; a flat node store shared with native code, so there is no layout encode or decode; interaction state as signals and
style rules as derived values; feedback edits to independent nodes (the scrollbar) placed by the layout backend without
a second solve, with incremental native layout only if layout becomes the main cost; retained per-node
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

## Component model: end state

Decided 2026-11-27, after every widget became a component and the self-updating model was deleted.

**A component is an immutable description, built in one call.** Every input is a `final` field set by its constructor,
which callers call with [named arguments](../../../docs/design/NAMED_ARGUMENTS.md); no configuration is set afterwards.
The class has identity, which `latestOf`, a kept body's newest description and the same-instance fast path use.
`inputsEqual` compares the inputs: values by `==` (arrays element by element), the style by `Diff.mask`, event
callbacks by presence (called through the newest description) and callbacks the body calls while building by identity.

```haxe
new TextField(key: "name", placeholder: "Name", onChange: next -> name = next);
```

This is the call shape of the [end state below](#beyond-the-end-state-descriptions-as-values), where the class becomes
an `Equatable` struct and its constructor the memberwise initializer, with the same names in the same order: callers
change once. A separate inputs struct (`new TextField(new TextFieldProps(...))`) was considered and left out: callers
would change to it and back, and the struct would be deleted when the component becomes one; its only gain meanwhile is
a synthesized `inputsEqual`.

The rules the whole UI follows:

- **Descriptions are immutable.** No `var` configuration set after construction; adjust a copy of the props instead.
- **State:** local state in signals the component holds, shared models `Observable`, caller-owned values controlled
  (the caller passes the value and is told of changes).
- **Every read is a dependency, interaction states included.** A component runs again exactly when something it read
  changed.
- **Styling.** A widget gives its style identity once, as a `StyleIdentity` struct, to one styled-node factory
  (`BuildContext.styled`), which reads only the states some rule selects for it and resolves the style from exactly
  those and the widget's authored states. A part of a control (a check box's indicator) resolves from the control's
  states (`resolveStyled` with the control's ID, `applyStyled` with `statesOf`). Routing owns `RenderNode.states`; the widget
  supplies only its authored states (disabled, selected, checked). Small values (`TextSelection`, `Insets`, `Color`,
  `Rect`) are structs; `LayoutStyle` becomes one only if measurements allow.
- **Roots.** A view's build returns a `ViewRoot`, which a caller can place and read (`walk` gives read-only `NodeInfo`)
  but not change; it adds to it only through `RootModifier`, and `RootModifier.modify` applies one to a view something
  else builds. Only the framework (core, components, the dock caches, the tooltip overlay host) reaches the node.
  Widgets that compose a text primitive into a node of their own use its `makeNode` factory.
- **The render tree is output-only.** Scroll offsets, fades and animated transforms are layer properties (ADR 0002
  stage 7); independent nodes are placed after layout without another solve (stage 6); `willEditRetained` goes.
- **One kind of view.** `View` and `ScopeView` merge into one component interface, with a cheap form for small bodies
  that hold no state and read nothing.
- **The frame is a pipeline of typed stages:** input, settle state, run components, settle structure, compare, layout
  and its feedback, paint and composite, semantics. Reference and verify modes are options of the pipeline.
- **Events are typed enums**, not strings.

Not adopted: reference records (classes keep identity equality), struct construction from anonymous literals,
positional component keys (subtle under conditionals), and compile-time body purity, which [PURITY.md](../../../docs/design/PURITY.md)
defers in favour of the runtime checks.

## Beyond the end state: descriptions as values

Decided 2026-11-27 as the direction after immutable components. A component description becomes an `Equatable` struct
implementing the component interface, and the framework keeps a body when `description == previous`: no component
writes a comparison, and none can fall out of step with its fields. A struct boxes when converted to the interface,
which is the allocation a class description costs today. Child views then compare by value; a button with a label view
built afresh each run compares its old and new label by identity today, so it never keeps its body.

It needs, in this order:

1. **Borrowed struct parameters** ([STRUCTS.md](../../../docs/design/STRUCTS.md#borrowed-parameters-planned)), then
   `LayoutStyle` as a struct, gated on the live-memory census and frame time.
2. **Equality through an interface.** Values of an interface that extends `Equatable` are equal when they have one
   dynamic type and its `==` holds; today interface `==` is identity. It replaces each component's type check.
3. **Callbacks.** Function fields have no synthesized equality, which stays right in general. A UI type whose equality
   is presence holds event callbacks, called through the newest description as `latestOf` does; a callback the body calls
   while building keeps identity equality.
4. **Child views by value**, a framework-wide change to what keeps; measured before it lands.

Until then each component writes `inputsEqual` by the rules above; a shared base class for its few common terms was
considered and left out. The conversion changes no caller, since the constructor becomes the memberwise initializer.

## Next steps

1. Without compiler work: the read-only root type (done: `ViewRoot`); the `StyleIdentity` struct with the styled-node factory
   (done: `BuildContext.styled`, `resolveStyled`, `applyStyled`), where
   routing owns `RenderNode.states`.
2. Haxeon: named arguments, then the memberwise initializer and `with` (done:
   [NAMED_ARGUMENTS.md](../../../docs/design/NAMED_ARGUMENTS.md)). Then make every component an
   immutable description with a named-argument constructor: TextField first (the one built and then configured), then
   the rest in one pass.
3. The `willEditRetained` survey, then ADR 0002 stages 6 and 7.
4. The `View`/`ScopeView` merge and the frame pipeline.
5. Descriptions as values ([above](#beyond-the-end-state-descriptions-as-values)), which replaces generating parts of
   `inputsEqual`.

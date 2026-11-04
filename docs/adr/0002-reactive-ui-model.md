# 2. Reactive UI model: tracked values over a shared node store

Date: 2026-10-30

## Status

Accepted. Stages 1 and 1b landed together on 2026-11-01: the signals core and compiler-generated `Observable` field
tracking now provide one dependency mechanism. Combined allocation acceptance is measured against the item 2 baseline.

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
reads, interaction snapshots, `selfUpdating` and `reconcile`, `BuiltNode`, `RenderNode.latest`, `requestPatch`,
`willEditRetained` and its priors, `RetainedAnimation`, patch frames, and binding revisions for widgets that cannot be
patched while hidden. Each was a correct fix; the recent work spends more of its time on the edges between them (composite
updaters, ordering of announced edits and patches, unmounted registrations).

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
   structs have no identity, so a struct-valued observable field is tracked as one field. Struct and enum conformances
   also use `implements`, as in `struct Value implements Equatable`. A signal is effectively a
   one-field observable. Signal and observable-field writes always store their value; change detection uses the type's
   declared `Equatable` conformance or identity for nonconforming classes to decide whether to invalidate readers.

   Dependency edges are deduplicated by source and reader identity plus field bit. Readers first check their last edge
   and the source's first edge. A capture slice promotes to a reader-local identity table after 1,024 distinct reads;
   a subscribing reader promotes only after it has over 1,024 edges and has also spent 1,024 steps on fallback scans.
   The bound limits scan work while avoiding an index for large readers whose sources already find their edge at the
   head. Table hashes are collision-checked against source identity and never reserve unique IDs: HashLink hashes the
   non-moving object address, while the single-threaded Wasm runtimes use a wrapping pseudo-random hash stream. A
   capture table clears only its occupied slots, releasing source references without rescanning a previously large
   table on every small slice. The two reader modes reuse fields they do not otherwise need, so small readers retain
   their existing object size and tracked reads allocate nothing. This needs no global IDs, native counter or shared
   subscriber index. Observable sources retain the concrete runtime class's field count
   for field-bit validation. A generated virtual method supplies that count on the first tracked read, even through a
   base-class reference; incremental structural edits invalidate dependent field layouts.

   Against Haxeon `9c1750fb`, three selection-stress census pairs fell from 342,089–342,091 allocations to
   340,909–340,910; interaction fell from 533,607 to 533,526. Nine alternating action pairs reported
   hierarchy-to-sensors at 112.6 → 114.6 KiB and console-to-telemetry at 72.5 → 74.5 KiB. Exact-window allocation
   censuses, however, matched on all 29 warm actions for both object counts and bytes: hierarchy-to-sensors had 1,661
   objects / 115,200 bytes on 28 actions and 1,705 objects / 118,456 bytes on the remaining action. Console-to-telemetry
   had 1,154 objects / 75,864 bytes on 28 actions and 1,210 objects / 80,376 bytes on the remaining action. Totals were
   48,213 objects / 3,344,056 bytes and 33,522 objects / 2,204,568 bytes respectively, with identical types.

   The reported 2 KiB step is refill accounting, not a growing capture scan buffer. A scratch HashLink trace with the
   fast allocator enabled showed that `Gc.totalAllocated()` charges an entire thread-local run on refill
   (`GC_TLAB_RUN` is 2,048 bytes). In 29 warm hierarchy-to-sensors actions, the original identity prototype shifted
   404 to 425 refills; 32-byte array slots accounted for 65 to 89 refills while other size classes moved in both
   directions. Triggering sites included `RenderNode.add`, `LayoutNode.add`, layout measurement, event handlers and
   docking code. Exact per-action censuses count the program's objects and bytes with that fast path disabled; the
   refill-based KiB results remain recorded above and the editor budgets are unchanged.
   Three paired 500-cycle RSS runs had median windows of 30.31 / 3.75 / 0.78 / 4.84 MiB for IDs and
   30.16 / 3.75 / 0.78 / 4.84 MiB for identity. Wasm GC Showcase counts matched in the full, static, text-heavy
   and editing scenes (4,440 / 4,440 / 4,440 / 8,724 objects).

   A 32-entry index threshold caused a real selection-stress increase: about 44 objects and 53 KiB, traced to table
   growth in docking captures and retained dependency replacement. The 1,024-entry threshold avoids those indexes
   in the measured editor while keeping the scan bound independent of input size. Three final selection-stress pairs
   were 340,908 → 340,909, 340,912 → 340,909 and 340,912 → 340,910 allocations. Nine paired action runs had identical
   allocation medians, including hierarchy → sensors 114.6 KiB, console → telemetry 74.5 KiB, sensors → hierarchy
   80.1 KiB, telemetry → console 92.9 KiB, hover away 13.6 KiB, hover enter/inside 0.5 KiB, hover field 12.4 KiB,
   hover other 10.0 KiB, idle/idle-focused 0.2 KiB, scroll inspector 21.2 KiB, backspace 16.2 KiB and type 16.1 KiB.
   The interaction census matched at 533,526 objects in all three pairs; a full site census traced small byte variation to the
   byte variation to the benchmark's `HeadlessEditorProfile.submit` JSON timing output, not reactive indexes.
   Median 500-cycle RSS windows were 30.16 / 3.59 / 0.94 / 5.00 MiB before and 30.16 / 3.91 / 0.78 / 5.00 MiB
   after; the 0.32 MiB rise in the second window is within the recorded same-binary variation. Frame medians rose
   modestly in the tab matrix (for example hierarchy → sensors 1.57 → 1.60 ms) and selection 3.04 → 3.08 ms;
   existing budgets passed.

   In three alternating HashLink timing pairs, creating 10,000 readers of one signal fell from a 131.40 ms median to
   4.79 ms, and retracking them fell from 101.29 ms to 2.59 ms. Capturing 10,000 distinct sources fell from
   104.64 ms to 2.36 ms; at 5,000 sources it fell from 25.19 ms to 1.63 ms. A single effect over 10,000 distinct
   sources took 1.14 → 1.27 ms to create and 0.57 → 0.68 ms to retrack; a 2,000-row effect took 0.245 → 0.258 ms
   to create and 0.118 → 0.134 ms to retrack. These timings include the hash and fast-path overhead; unlike the
   original scans, the measured shared-source and capture cases no longer grow quadratically at these sizes.

   Nine alternating final-source Wasm GC full-scene pairs matched at 4,440 objects. Three pairs each for static,
   text-heavy and editing also matched at 4,440 / 4,440 / 8,724 objects. An earlier run timed out on its ninth
   candidate after the renderer disappeared with 8.1 GiB free in `/dev/shm`; its browser log reports GPU stalls but
   no explicit crash or out-of-memory cause. The completed comparison ran without concurrent session builds.

   The stricter tracking-write guard is parked while the outer editor viewport changes are uncommitted; its saved patch
   and fixture are in `materia-cache/claude-scratch/haxeon-flat-work/write-guard/`. Resume and gate it once those
   viewport field annotations land in outer `HEAD`.

   Writes batch per frame. A source pushes a *maybe stale* mark through the graph; a reader pulls by validating source
   versions. A derived node recomputes only when an input version changed and increments its own version only when its
   declared equality says the result changed. Effects and retained readers therefore stop at equal derived results,
   including through chains and diamonds, without glitches or repeated computation. A direct or indirect cycle in a
   derived computation throws `Cyclic Derived computation`; the failed pull can be retried after the cycle is removed.
   An effect that throws retains the dependencies reached by its failed run and is queued again only when one changes, including after a failed initial
   run. A flush runs every queued effect, then rethrows the first error and reports the number of additional failures in
   `ReactiveRuntime.lastFlushSuppressedErrors`. Disposing a failed effect removes its subscriptions, and a rejected
   off-thread subscription never queues work on the owner graph. Dependency edges are intrusive doubly linked nodes
   shared by the source and reader, found by identity and field and reused on each run. A per-run
   stamp identifies edges reached by the latest computation; there is no observer array on every source or global ID in
   subscribe/unsubscribe. Observable changes mark only the matching subscriber edges stale; those marks replace a
   separately allocated per-object field-version array. The single-owner effect queue retains its cursor and initial
   capacity, so a successful write-and-flush does not allocate after subscription. This also avoids allocating the
   exception-visible loop cursor as a captured cell on every flush. Frame capture uses two reusable read
   logs; retained records keep and release only live edges.
   `State` is a `Signal` handle and signal reads are tracked automatically. `DockPanelContent.cacheKey` and
   `cacheKeyHash` are removed in favor of tracked reads. Models we own use `Observable`; there is no polling API or
   adapter unless a real external model appears.
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
   **Tracked writes are enforced at runtime.** While a tracking scope runs, writing a signal or `State` throws at the
   write. An `Observable` field write throws when another computation has
   subscribed to that field; a fresh source or unread field can be initialized without a false positive. Implementation
   fields excluded with `@:unobservable` do not participate in field tracking; public getters track their observable
   inputs. These checks run in debug builds and every gate, not only
   verify runs. A compile-time
   purity contract (`docs/PURITY.md`) is deferred until these checks show real holes.

   Tracking scopes belong to the thread executing the computation. A worker reading an Observable while the UI builds
   must not append to the UI's collector or inherit its write restrictions. The active collector is thread-local and is
   restored on normal and exceptional scope exit; an inactive thread holds no TLS root. HashLink roots a native
   thread-local collector directly, avoiding a heap-allocated TLS slot for every scope. Wasm's synchronous stand-in
   threads drop cleared worker slots. Runtime initialization binds the reactive graph to the application thread;
   later subscriptions and writes to a source field with readers reject other threads before changing the graph. The
   write check names the source type and field, and performs no thread check or allocation when that field has no
   readers. Unobserved state may still be prepared on a worker. These checks run with the other tracked-write guards in
   debug builds and gates; they do not make shared graphs thread-safe.

For example, a panel reads its model directly and constructs keyed children explicitly:

```haxe
function build(context:BuildContext):View {
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

0. **Structs for small values and data records — done.** `Rect`, `Insets`, `Color`, `LayoutAxis`, `Transform2D`,
   `TextStyle`, `ParagraphStyle`, `DockTextWidthKey`, `Shortcut`, `EffectParameter`, `InkOverflow`,
   `CustomEffectDefinition`, and the app's presentation/telemetry snapshots are structs with declared conformances.
   Nullable fields use inline presence flags, eligible temporaries stay scalar, and Wasm GC flattens supported fields.
   `LayoutStyle` remains a class because its measured struct form allocated more. See
   [UI value types](../../packages/ui/docs/VALUE_TYPES.md) for the alias audit and measurements. The interaction,
   tab-matrix and selection-stress censuses allocate none of the five geometric value types after setup; genuine Dynamic
   and reflection escapes still box.
1. **Signals and Observable models — implemented together.** `Signal<T>`, `Derived<T>` and `Effect` use push
   maybe-stale propagation, version-checked pull recomputation and per-submit effect batching. Equal derived outputs do
   not advance their source version, so downstream effects and retained readers do not rerun. Intrusive source-reader
   edges are reused across runs and removed when a dependency disappears; frame capture uses reusable dependency logs.
   A self-updating build owns its subscriptions while registered or held by a retained interaction snapshot. Pruning
   an unmounted build releases the registry's ownership; the last owner disposes its subscriptions and child snapshots.
   Cached alternatives keep their subscriptions for validation and transfer their invalidation owner when rearmed.
   `haxeon.Identity.same` compares class instances by identity without invoking declared value equality.
   `State` is a signal handle. Every signal and Observable write stores its supplied value; equality decides only whether
   readers are invalidated. Floating-point change detection treats NaN as equal to NaN and the two zero signs as equal,
   while preserving the written bits. Observable field reads track one field bit per object, and changed writes invalidate
   only that field's readers. A tracked struct field is updated by copying it, modifying the copy, and assigning the
   whole value back; the compiler rejects in-place mutation until it can track the entire place correctly. Signal and
   `State` writes always throw inside tracking; Observable writes throw when that field already has readers, allowing fresh object
   initialization. Property readers take no invocation context and track model reads directly. Command buttons read a
   retained derived enabled/checked result, so a context replacement that leaves the result unchanged does not rebuild
   the button. `State.updateQuietly`,
   `observe*`, root polling and plain-read validation are removed. The owned revision-adapter models were migrated and
   their adapter counters deleted. The dependency primitives live in Haxeon's stdlib under `haxeon.reactive`, so a
   non-UI model can implement compiler-known `Observable` without importing the UI package. Typing adds the generated
   `ObservableSource` and `ReactiveRuntime` dependencies to that model's source module; otherwise a generic method can
   reach IR generation without its object layout or runtime calls. The combined allocation table records the item 2
   comparison below.
   Assembly presentation views use Observable records, so edits to a view label invalidate the controls that read it.
   The cursor is an immutable Equatable struct replaced on the Observable controller. Its declared value equality
   skips equal replacements; the viewport caches the solved presentation by cursor value and scene state, then assigns
   a render version after recomputation for its native image cache. It does not poll a fingerprint of the cursor's
   individual fields. A standalone HashLink census of 1,000 cursor-field updates allocated zero objects with the
   struct and 1,000 anonymous cursor records (48,000 bytes) with the former representation.
   The Wasm GC allocation counter exposed a compiler-generated diagnostic string on every Observable write, even
   when no reader existed. The generated write now checks the guard before constructing its field-specific error.
   In an isolated 1,000-update cursor probe, this reduced GC objects from 4,003 to 2,009 with inlining both enabled
   and disabled; the remaining per-update objects are the probe's `"view"` string. The guard still throws at the write
   for a tracked field with readers.
   A paired Wasm GC Showcase rerun of the saved baseline and current artifacts measured 5,896 objects for each full,
   static and text-heavy run, and 12,835 for editing, over 120 measured frames after 120 warmup frames. Three
   additional paired editing runs also matched, including their per-function counts. The earlier 12,833-object editing
   capture lies within the two-object run variation recorded in VALUE_TYPES.md; the paired comparison shows no
   item-4 allocation increase in any Showcase scenario. A fresh build after the Observable write-guard cleanup measured
   5,896 full, 5,894 static, 5,896 text-heavy and 12,835 editing objects, again within or below the paired baseline.
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
   `SelfUpdatingBuild` (including its ownership counter), `RetainedVariants`, `InteractionStateSnapshot`, `BuiltNode`,
   retained caches, patch frames and binding revisions. Until then, change this machinery only for tested correctness
   fixes and the required no-regression work. Interaction signals and derived style replace hover handling.
6. **Local placement for independent feedback edits.** First exclude absolute overlays from content bounds. Then add the
   backend's independence check and local placement, with full-solve fallback, and verify-mode comparison against a full
   solve. Go: selection runs one Clay solve per frame with byte-identical geometry, and no scenario takes the fallback
   where it did not need a second solve before. A layout engine of our own needs its own record, and only when
   measurements show layout as the main remaining cost.
7. **Retained rendering and layers.** Per-node display-list segments and layer properties; delete `willEditRetained` and
   `RetainedAnimation`.

### Signals-only interim allocation measurement — 2026-11-01

These historical 30-cycle medians cover the signals-only checkpoint. They are superseded by the combined stage 1 + 1b
measurement below, which is the allocation acceptance comparison against the item 2 baseline.

| Transition | Item 2 baseline | Signals core | Change |
| --- | ---: | ---: | ---: |
| console → telemetry | 75.4 | 80.2 | +4.8 |
| hierarchy → sensors | 118.2 | 118.2 | 0.0 |
| sensors → hierarchy | 82.2 | 85.8 | +3.6 |
| telemetry → console | 95.3 | 98.8 | +3.5 |

The budget and retention checks passed with plain-read validation present at that checkpoint. The combined table below
replaces these interim results.

### Combined stage 1 + 1b measurement — 2026-11-02

The final 30-cycle editor budget measurement, run in an isolated outer worktree against committed machinekit, gave
these per-action HashLink allocation medians in KiB. The item 2 column is the same-machine acceptance baseline:

| Action | Item 2 | Combined |
| --- | ---: | ---: |
| console → telemetry | 75.4 | 74.5 |
| hierarchy → sensors | 118.2 | 112.6 |
| sensors → hierarchy | 82.2 | 78.1 |
| telemetry → console | 95.3 | 92.9 |
| hover away / enter / field / inside / other | 15.0 / 0.5 / 13.5 / 0.5 / 10.0 | 13.6 / 0.5 / 12.4 / 0.5 / 10.0 |
| idle / idle focused / scroll inspector | 0.2 / 0.2 / 21.3 | 0.2 / 0.2 / 21.2 |
| type backspace / character | 16.3 / 16.2 | 16.2 / 16.1 |

The 30-cycle selection-stress census fell from 403,157 allocations across 832 types to 342,872 across 747 types;
the current capture was run without profiler sampling. A direct census measured 17,120 bytes per backspace before the
last TextField cleanup, 16 above the item 2 baseline of 17,104. The final rebuilt app measured 16,704 bytes per
backspace and 16,664 bytes per character. Each rebuild had supplied document length both through the optional
`Semantics` constructor argument and the immediately following `setValueSource` call. An isolated 1,000-construction
census found exactly 1,000 `i32` boxes (16,000 bytes) for the optional argument and none when `setValueSource` alone
supplied the length. The isolated app suite, nine retention scenarios, budget and headless memory gates passed. The
shared checkout could not compile because another session's uncommitted machinekit constructor call has the wrong
argument type; the isolated worktree used the committed machinekit tree and the same Haxeon and app changes.

The follow-up moved the stdlib primitives to `haxeon.reactive`, reopened already initialized text-editor resources
without constructing their factories, and reused the resolved-node visitor. Hover dispatch now passes a prefix length
instead of copying paths for enter and leave events. A same-machine 60-cycle direct allocation capture measured character
typing at 16,504 bytes before and 16,496 bytes after; the earlier 16.2 → 16.3 KiB table entry was a real increase before
these changes, rather than rounding alone. The corresponding backspace medians were 16,536 and 16,544 bytes, and
hover-other medians were 10,168 and 10,200 bytes. Those last two differences remain below the 0.1 KiB reporting
precision; the prescribed 30-cycle budget medians above are equal or lower for every action. The final Wasm GC Showcase
medians over three 120-frame runs per scenario were 5,896 full, 5,894 static, 5,896 text-heavy and 12,835 editing objects,
matching the saved paired baseline.

The headless memory gate was compared in three complete invocations per tree, nine 500-cycle captures each, using the
item 2 Haxeon commit `281c9422` with its matching pre-signals app commit `5fb040624` as the baseline. The first
100-cycle RSS window had a 31.09 MiB median on the baseline (29.69–31.41) and 30.94 MiB on the combined tree
(28.59–31.09). The second window was higher on the combined tree: 6.88 MiB median (0.31–8.12) versus 4.69 MiB
(3.75–6.72). One combined capture crossed the unchanged consecutive-window limit by 0.12 MiB; the baseline had no
failures. The later windows were stable: 0.78 / 4.53 MiB median on the baseline and 0.78 / 4.84 MiB on the combined
tree. The combined profile bytecode is 98 MiB versus 89 MiB at item 2, and the new reactive dependency graph and
Observable accessors expand one-time code and subscription warm-up; the later flat windows and stable retained counts
show no continuing growth. This was a real warm-up increase, not a passing retry or a pre-existing gate flake. The
generated read path had repeated source creation and field recording blocks at each access site; the generated write
path had repeated null-check and invalidation blocks. Both now call small shared runtime helpers. The profile bytecode
fell from 101,928,103 to 98,595,908 bytes, a 3,332,195-byte reduction. Three more full invocations on the changed
tree passed all nine captures: first-window median 30.62 MiB (30.00–31.41), second-window median 3.75 MiB
(1.09–6.41), later-window medians 0.78 and 4.84 MiB. The second window is now below the item 2 baseline's 4.69 MiB
median. The threshold remains unchanged.

The selection-stress investigation did not reproduce the reported stall after roughly 40 cycles. The current 60-cycle
run completed (median selection frame about 3.0 ms, p95 3.2 ms); the item 2 60-action capture also completed, with a
3.14 ms median and 3.71 ms maximum. Neither showed a stall.

No `observe*` polling remains.

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

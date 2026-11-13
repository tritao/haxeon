# 2. Reactive UI model: tracked values over a shared node store

Date: 2026-10-30

## Status

Accepted. Stages 1 and 1b landed together on 2026-11-01: the signals core and compiler-generated `Observable` field
tracking now provide one dependency mechanism. Combined allocation acceptance is measured against the item 2 baseline.

The decisions do not carry the same confidence, and the migration treats them differently:

- **Committed:** tracked values (1), interaction state as signals (5), retained rendering with layers (7), semantics and
  input from the same model (8), verification (9). Mature UI frameworks have converged on each, and each removes
  mechanisms we have today.
- **Committed by stage 3:** re-running structural scopes with explicit live text bindings (2); the measurements and
  decision are recorded below.
- **Rejected by stage 2:** the shared native node store (4). An incremental layout engine (6) remains conditional on a
  measured need. Local placement of independent feedback edits (also decision 6) is committed: it is small, lives in
  our backend and removes the selection frame's second solve.

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

   Outer `97a56618c` prepares viewport presentation frames in the owner update phase and marks transient frame state
   unobservable. Tracked builds consume the prepared snapshot. The stricter tracking-write guard can therefore reject
   writes to pre-existing Observable objects even when no reader has subscribed to the written field.

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
2. **Decision (2026-11-11): re-running structure and explicit text bindings.** Stage 3 compared re-running scopes (R),
   run-once keyed iteration and text bindings (B), and their hybrid on both the CNC and telemetry panels. R's telemetry
   step allocated 11.83% more bytes than B after scoped skipping, so it misses the 10% rule. B did not beat R by more
   than 10% on both panels: R used fewer bytes on every changed CNC action. The hybrid closes the telemetry gap and
   does not increase any measured action, so it wins without result builders, lazy parameters, or a new language feature.

   The kept library surface is `haxeon.ui.component.TrackedScope`, `EqualChild<T:Equatable>` and `BoundText`. A scope tracks
   its reads and re-runs its own body; an equal child is reused only when its declared inputs, own dependencies, style,
   viewport and interaction state still match. `BoundText` mounts a text node once, schedules a frame on tracked changes,
   and updates its text and semantics. Requests coalesce, and a failed getter does not suppress a later frame request.
   Ordinary Haxe `if`, `switch`, comprehensions and functions describe structure.
   The keyed run-once `BoundEach` experiment is deleted. At the stage 3 checkpoint, `TrackedScope` ran on
   `BuildContext.selfUpdating` and retained reconciliation. The stage 5 foundation below replaces that implementation
   with a native render-tree owner; reconciliation remains until its widget and panel callers have been ported.

   Exact calibrated action windows are objects/bytes below. Each is the same warmed second action occurrence used by
   the allocation census, including the trigger through its submitted frame. The `cnc-progress` window is a tick which
   actually advances the line. The control uses the current model; R and B were crossed over on both panels; H is the
   hybrid. The four binaries were built from the same compiler and outer baseline, before the public scope was renamed
   from `RScope` to `TrackedScope`; the rename changed only the identifier. The calibration marker is one object,
   16 bytes and 17 sampled stack bytes and is excluded; type and stack byte totals were checked before subtraction.

   | Action | Control | R | B | H |
   |---|---:|---:|---:|---:|
   | CNC unchanged | 19/640 | 19/640 | 19/640 | 19/640 |
   | CNC select | 2,334/134,176 | 2,248/127,016 | 2,315/131,824 | 2,248/127,016 |
   | CNC source | 4,761/278,688 | 4,706/273,152 | 4,723/273,984 | 4,706/273,152 |
   | CNC progress | 5,926/316,928 | 5,539/283,000 | 5,792/295,664 | 5,519/281,024 |
   | CNC hold | 3,280/184,032 | 1,011/46,512 | 1,015/46,736 | 1,011/46,512 |
   | CNC resume | 3,547/199,616 | 1,505/79,864 | 1,917/108,520 | 1,479/77,008 |
   | Telemetry step | 19,676/827,904 | 16,228/706,192 | 15,075/631,512 | 14,978/627,128 |

   Frame times below are milliseconds: each cell is the median control / variant frame time from seven alternating
   pairs. Each column is a separate paired series, so compare the two numbers in a cell rather than across columns.
   The full pairs, including direct R-versus-B and B-versus-H comparisons, are in the evidence file. The short unchanged
   frame is especially sensitive to timing noise.

   | Action | Control / R | Control / B | Control / H |
   |---|---:|---:|---:|
   | CNC unchanged | 0.015 / 0.018 | 0.017 / 0.021 | 0.011 / 0.010 |
   | CNC select | 0.542 / 0.624 | 0.484 / 0.588 | 0.447 / 0.467 |
   | CNC source | 1.516 / 1.206 | 1.225 / 1.447 | 1.121 / 1.158 |
   | CNC progress | 1.108 / 1.042 | 1.147 / 1.261 | 0.998 / 0.940 |
   | CNC hold | 0.782 / 0.454 | 0.709 / 0.536 | 0.649 / 0.407 |
   | CNC resume | 0.903 / 0.833 | 0.861 / 1.182 | 0.638 / 0.499 |
   | Telemetry step | 3.453 / 4.230 | 3.862 / 2.740 | 3.102 / 2.422 |

   In the direct telemetry series, B's median was 2.774 ms and H's was 2.500 ms; the median of the seven paired
   H/B changes was -8.28%. The corresponding allocation windows were 631,512 and 627,128 bytes.

   All 15 budgeted editor actions were also checked: neither pure pairing nor H increased objects or bytes against the
   control. The control includes the shared retained-child correctness and deferred idle-metrics fixes; compared with
   the original control, unchanged CNC changed from 20/904 to 19/640 and the other six panel windows were identical.
   Four budgeted reused-frame windows each lost one object/264 bytes; the other eleven were identical. The full
   per-action counts, allocation sites, module hashes, and seven alternating timing pairs are in
   `/media/joao/DATA1/haxeon-component-gates/evidence/0002-stage3-evidence.json` (SHA-256
   `ac98dafceb628f74bcceb1a52d023606aee4d02e6c102a45dc1e2cfa82d05d8a`). Frame times measure the submitted frame;
   the triggering simulation or input work is included in the census, not that timer. The control's existing
   `panel-flows` failure, `Headless editor profile failed: Inspection camera ignored its view label`, reproduces before
   telemetry and is recorded separately; the focused CNC and telemetry flow passed with retention verification on.
   The outer app suite also reports the existing `appearance edit rebuilds the child's material` assertion; it reproduced
   with the original panels and current-model UI. The viewport metrics test passes after its direct internal-field read
   was ported to the public metrics accessor.

   R reads like ordinary Haxe and localizes control flow, though explicit scopes and equality props add some scaffolding.
   B requires the structure to be expressed as keys and row dispatch, and live leaves require closures whose scheduling
   and captures must be followed when debugging. The hybrid keeps the ordinary structural code and uses those explicit
   closures only for live text. Mounted R, B and hybrid idle submissions allocate zero objects on HashLink, Wasm32 and
   Wasm GC with inlining both enabled and disabled; tests also cover equal-child skipping, stable bindings and updates.
3. **Conditional language work.** Result builders and lazy parameters are not required by the selected model. They
   remain separate general-language proposals only if later measured evidence establishes a need; neither is part of
   this stage or a prerequisite for stage 5. The compiler has no UI-specific syntax or intrinsics.
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

For example, a panel uses ordinary Haxe to describe structure and binds its live text explicitly:

```haxe
function build(context:BuildContext):View {
  return new TrackedScope("panel", () -> {
    var children = [new KeyedView("phase", new BoundText("phase", () -> model.phase.toString()))];
    if (model.ready) children.push(new KeyedView("ready", readyBadge()));
    for (item in model.items) children.push(new KeyedView(item.id, itemView(item)));
    return new Column("panel", children);
  });
}
```

The structural scope tracks the fields its body reads. The text binding tracks its own getter and schedules its update;
no builder transform or lazy parameter is involved.

## Mapping from today

| Today | Becomes |
|---|---|
| `context.state`, `State.update` | tracked component fields or standalone `Signal` |
| `observeInt/Bool/String`, model revision counters, `cacheKeyHash` | observable fields and tracked reads |
| `State.updateQuietly` | removed: writes know their readers |
| `RetainedView`, dock pane and panel caches | migrate incrementally to tracked scopes and bindings; remove caches when no longer needed |
| `selfUpdating`, `reconcile`, `BuiltNode`, `RenderNode.latest` | native scope foundation implemented in stage 5; delete these after the remaining widget and panel callers are ported |
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
   Class and interface `==` compares instance identity. Only value types can declare `Equatable` or `Hashable`;
   reactive edge and source comparisons use ordinary `==` without an identity API or boxing.
   `State` is a signal handle. Every signal and Observable write stores its supplied value; equality decides only whether
   readers are invalidated. Floating-point change detection treats NaN as equal to NaN and the two zero signs as equal,
   while preserving the written bits. Observable field reads track one field bit per object, and changed writes invalidate
   only that field's readers. A tracked struct field is updated by copying it, modifying the copy, and assigning the
   whole value back; the compiler rejects in-place mutation until it can track the entire place correctly. Signal and
   `State` writes always throw inside tracking. Observable writes during tracking are allowed only on objects created in
   that same tracking invocation; an object made in an outer, inner or earlier invocation is not fresh for the current
   scope. This makes the rule independent of whether a field happens to have readers. A reusable per-thread creation log
   records object identities in nested scope slices, clears its references on exit, and compares class identity with `==`.
   It adds no field to each Observable. Lookup checks the newest objects first, so ordinary constructor initialization
   finds its just-created receiver immediately. Reflective writes follow the same rule; reflective copies register their
   newly allocated receiver. Text fields apply external text and selection to their local editor resource during build,
   then finish history clears and coalescing breaks in the resolution callback outside tracking. Repeated resolution
   does not repeat a completed history change, and later edits retain their undo groups.
   Property readers take no invocation context and track model reads directly. Command buttons read a
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

   **Prototype design (2026-11-11).** Today `RenderNode.syncLayoutInputs` turns dirty flags into
   `LayoutChanges.inputs`; `LayoutTransaction` walks the tree and encodes a whole mixed-channel record for each
   changed node. `LayoutSession.submit` passes those bytes to `read_layout_transaction`, which validates and decodes
   them into native `LayoutNode`s; resolved geometry returns through a separate byte buffer and
   `ResolvedLayoutItem.decode`. The census attributes 146,040 bytes across the 15 actions to native bridge copies,
   including geometry and FFI outputs, so removing paint serialization alone is not assumed to remove that total.

   The proposed paint record is 104 bytes, aligned to eight: background RGBA `Float64` at bytes 0–31, top-left,
   top-right, bottom-left and bottom-right `Float64` radii at 32–63, text RGBA `Float64` at 64–95, then 32-bit slot
   generation and paint dirty state at 96 and 100. The 64-bit values preserve the existing Haxe `Float` reads; native
   consumers convert to their existing 32-bit rendering values at use. These are the paint values currently encoded in
   the layout record; visibility, clipping and visual kind also affect other channels and stay with those channels during
   the prototype.
   Custom paint callbacks, display lists, effects and other managed references remain in their existing side tables;
   they are not pointers embedded in the flat record. The native declaration and Haxe flat struct must agree on
   field offsets, size and alignment on each target. Native rendering reads the record directly, without reconstructing
   a second paint copy. Existing color and radius validation remains at the boundary.

   The layout session owns the native arena and its record slots for its lifetime, and disposes them with the session;
   temporary owners use scoped cleanup. A slot handle is an index and generation, checked on access; removing a node
   invalidates its generation before reuse. Growth must not leave native consumers holding a stale pointer: publish the
   current span after growth and retain it only while its owner is live. HashLink and both Wasm targets write the same
   native memory, including Wasm GC linear memory; there is no managed-array staging copy per frame. `RenderNode` remains
   the public view and resolves its handle to the record; callers retain the existing API. Rebuilt nodes for the same
   live identity must resolve to the same slot, while stand-ins and verify builds must not mutate the live record.
   Nodes and mutable `LayoutStyle` values can also be created before a session and a style can be passed to more than
   one node. The prototype must preserve those construction and shared-mutation semantics when attaching records; it
   cannot silently make style assignment a per-node copy. Test both attachment and subsequent shared-style writes.

   A paint write marks its slot dirty using the existing `Diff`-based paint classification, including direct layout
   mutations and text color. Native consumes those bits before rendering and acknowledges them only after a successful
   submit; failure preserves pending changes. Clay currently copies background and text colors into its declarations;
   the prototype must use the current record when producing those declarations and invalidate retained paint when a
   record changes, even if geometry is unchanged. Topology, layout, text, geometry and composite invalidation retain their
   existing paths until migrated. Verification continues to compare the live result with an independent fresh tree,
   including paint values. Inspector snapshots and dumps read paint through the handle, with managed style provenance
   still available; a test must demonstrate that a changed record is visible to inspection and verification.
   The target tests also cover exact Haxe-side color and radius reads (including signed zero), shared-style mutation,
   slot reuse and stale handles, failed-submit dirty retention, and disposal. Paint-only updates are measured after warmup on all three
   targets; Wasm GC must pass the linear-memory record to native without a per-frame managed-to-native copy.
   Borrowed views of managed flat arrays and optional flat values are not needed by this design yet.

   **Stage 2 decision (2026-11-11): no-go.** Keep the incremental layout transaction and its verification.
   The paint prototype increased allocation, frame times and module size, and introduced a native arena, generation
   management and binding side tables without simplifying the mixed-channel bridge. Do not migrate the other channels.

   The same calibrated harness measured each action once for exact allocation, and four alternating control/prototype
   timing pairs for the `tab-matrix`, `interaction` and `selection-stress` scenarios. Frame times below are the median
   of each run’s per-action median, in milliseconds. A matching native UI library was built for each module with the
   same release flags. The 30/60/60 scenario cycles exclude setup and verification frames from timing.

   | Action | Objects control | Objects prototype | Bytes control | Bytes prototype | ms control | ms prototype |
   | --- | ---: | ---: | ---: | ---: | ---: | ---: |
   | hierarchy->sensors | 1,676 | 1,920 | 117,208 | 131,264 | 1.5260 | 1.9474 |
   | sensors->hierarchy | 1,149 | 1,258 | 79,656 | 86,432 | 1.1386 | 1.5681 |
   | console->telemetry | 1,176 | 1,230 | 78,520 | 81,432 | 1.0350 | 1.2829 |
   | telemetry->console | 1,712 | 1,772 | 93,176 | 96,424 | 1.0871 | 1.3350 |
   | scroll-inspector | 227 | 233 | 23,072 | 23,184 | 0.7147 | 0.8747 |
   | hover-enter | 33 | 33 | 1,296 | 1,296 | 0.0031 | 0.0031 |
   | hover-inside | 33 | 33 | 1,296 | 1,296 | 0.0025 | 0.0029 |
   | idle | 18 | 18 | 848 | 848 | 0.0072 | 0.0075 |
   | idle-focused | 18 | 18 | 848 | 848 | 0.0070 | 0.0080 |
   | hover-other | 187 | 193 | 9,712 | 9,936 | 0.4219 | 0.5535 |
   | hover-field | 323 | 329 | 17,296 | 17,520 | 0.4338 | 0.5708 |
   | hover-away | 257 | 264 | 12,512 | 12,792 | 0.4302 | 0.5630 |
   | type-char | 417 | 423 | 16,360 | 16,584 | 0.4163 | 0.5475 |
   | type-backspace | 432 | 438 | 16,992 | 17,216 | 0.4138 | 0.5460 |
   | selection | 8,593 | 8,851 | 579,512 | 597,368 | 2.5010 | 3.3549 |

   Across these actions, allocations rose from 16,251 objects / 1,048,304 bytes to 17,013 / 1,094,440. The HashLink
   module rose from 102,434,594 to 102,561,106 bytes (+126,512); the four new paint-store classes and native record
   header added 272 lines before changes to the existing bridge. Across the production bridge, store, native API and
   inspector, the prototype added 640 lines and removed 133, excluding generated HXI and tests. The prototype retained
   the bridge for the other channels and added linked binding tables for shared styles and nodes, so it did not provide
   a net simplification.

   The prototype’s inspector exposed live background, text color and radii, and its inspector fixture passed on
   HashLink, Wasm32 and Wasm GC with inlining both on and off. Direct warmed paint updates allocated nothing in the
   focused tests on those targets; the editor census nevertheless increased. Native incremental/full-tree verification
   and the layout smoke test passed, including deliberate detection of a missing delta. This shows that the failure is
   the measured editor tradeoff, not a failure to implement or inspect paint records.

   The control module SHA-256 was `9a04479bb4165b46712e39e143eb3d14ddbe33b7a3c28dd9a5d7696105f691ca` and the prototype module was
   `5a02f3dac4ccc56cb2479f8788e42d9271f3b5ead275beecb96e61f8d6ccf780`. The calibrated harness SHA-256 was `426e07eec67e6744c35eb60f355077ef9ceea6bef8dcbc1ac4eb906b95b941e1`.
   The prototype is removed; the existing incremental bridge and verify mode remain in use.

3. **Component model experiment (completed 2026-11-11).** Test plain Haxe, without builders, lazy parameters or other language features.
   Start with re-running scopes (R) on `CncPanel` and run-once bindings (B) on `TelemetryPanel`. CNC currently samples
   an `Equatable` presentation and patches its whole description; telemetry builds a plot and keyed worker, zone and
   separation rows from the current snapshot. R needs tracked scopes with owned cleanup and an equality-gated child
   input; B needs owned live-leaf bindings and only the conditional and keyed iteration primitives the panel uses.
   Scope and binding lifetimes must follow mount/unmount, including changed dependencies and keyed row removal.

   Compare both mechanisms on **both** panels before applying the decision rule, using temporary crossover versions
   during the experiment. Measure the unchanged frame, CNC source/selection/progress/hold/resume and telemetry
   snapshot/worker/zone/row changes, as well as the existing console ↔ telemetry budget actions. Extend the existing
   warmed, calibrated exact action-window census for live updates; report object counts, requested bytes and site
   attribution alongside paired uninstrumented frame times. Retain all 15 existing budget action comparisons against
   the same current-model control. Existing `RenderNode`/widget and reconcile allocations are V, callbacks and captured
   environments C, dependency edges T, and children arrays and formatted strings A; attribute actual captures rather
   than assuming every site disappears. Test updates, equal-child skipping, binding stability and zero-allocation
   unchanged frames on HashLink, Wasm32 and Wasm GC. Record source readability and debugging tradeoffs with results.
   Prefer R within 10% of B on both panels; otherwise test a structural-R/leaf-binding hybrid. Every action must allocate
   no more than control, fewer mechanisms break a tie, and builders plus `Lazy<T>` are a separate later item only if B
   wins by over 10% on both panels and the hybrid cannot close the gap.

   The existing `CncRetention` fixture covers source replacement, selection, progress, hold, resume, speed and
   hide/remount; `panel-flows` exercises telemetry physics steps and worker zones. Use identical seeded inputs and
   warmed state for the three implementations, and add isolated windows around the triggering input or simulation
   step through the submitted frame. The existing `submit` timer starts after those triggers, so preserve separate
   input and frame timings rather than treating it as total action time. Calibrate each census window with the marker
   and byte-sum checks described in `ALLOCATION_CENSUS.md`; exclude only that marker. A panel-flow baseline failure
   must be reproduced on control before it is classified as the known failure, and must not stand in for live-update
   measurements.
4. **Conditional compiler support.** Result builders and lazy parameters need separate designs and target tests only
   if later measurements justify them. Runtime debug checks continue to enforce tracked reads.
5. **Widgets, then panels.** Convert the remaining leaf widgets and panels incrementally to scoped structure and explicit
   text bindings, measuring each conversion. Keep the existing retained and patch machinery until the converted uses no
   longer need it; reimplement `TrackedScope` natively before removing its `selfUpdating`/reconcile foundation, then
   remove obsolete paths rather than keeping compatibility layers. Interaction signals and derived
   style replace hover handling where measured.

   Native scope ownership uses a stable wrapper node and one replaceable body child. The wrapper keeps caller-added
   children and decorations; replacing its body updates the render and layout child slots together, without builder
   snapshots or redirects from removed nodes. Each scope subscribes directly to its structural reads and restores its
   captured key scope, inherited style and text style when rerunning. Parents run before their children; removed children
   release subscriptions before pending work can run. Resource ownership follows each mounted scope's current body,
   rather than a flattened parent snapshot. Failed bodies leave the installed child intact and remain invalidatable.
   A native scope's resource handle owns its current state IDs through the state store. Retaining that handle keeps
   the current body alive while a panel is hidden; hidden scopes pause until remounted. Releasing the handle disposes
   the scope. This uses resource reachability instead of snapshot ownership counters: enclosing caches retain one
   handle and need not learn a second scope API or copy changing descendant state lists. A focused hidden-panel
   regression reproduced premature disposal before this ownership change. Pilot verification remains pending.
   Interaction routing recognizes the nearest native scope and invalidates that scope directly for changes its body
   renders. It does not route those changes through an enclosing legacy panel. An early experiment tracking every
   interaction read added signals and dependency edges for text/layout nodes and regressed the pilot census; it was
   removed. Per-node interaction signals and derived styles remain part of the later widget migration.
   Bound text keeps its last submitted text on its own native leaf node. Text changes classify content, geometry and
   semantics directly, instead of cloning an entire render/layout/style node for comparison. The measured native-scope
   telemetry case spent six additional snapshots on live text (144 objects / 6,512 bytes overall). The leaf's submitted
   fingerprint substitutes only its owned text/label, so verification still rejects unrelated unannounced edits.
   A fresh control built after the allocator size-class update reproduces a legacy resource-lifetime defect:
   after a scope reruns through an equal-child cache hit, the next retained frame can dispose a still-mounted bound
   text effect. A focused reproduction loses its subscription and leaves text stale on HashLink, Wasm32 and Wasm GC,
   with inlining both enabled and disabled; native ownership retains the subscription and updates the text on all six
   configurations. Paired editor traces confirm that the control disposes all 18 worker bindings during the first
   telemetry step and invokes none on the following eight steps; the native version invokes all 18 on every step
   and releases them when the panel unmounts.
   The portable `BindingLifetimeMain` regression fails against the pristine control (`hl`, inline off: return 5)
   and passes against the native foundation on all three targets with inlining both on and off.

   **Foundation correctness exception (lead decision, 2026-11-11).** For `telemetry-step`, the control measures
   14,978 objects / 629,752 bytes and the native foundation 15,080 objects / 630,520 bytes: +102 objects / +768 bytes
   (0.12%). The control disposed live bindings early, so its lower allocation count describes incorrect behaviour.
   Keeping those bindings alive is a correctness fix; the lead explicitly accepts this difference. The native
   foundation's 15,080 objects / 630,520 bytes become the correct baseline for later batches. This exception does
   not relax other actions, verification, or budget ceilings. The standard 15-action census must still have no
   increase: telemetry → console saves 2 objects / 72 bytes, and the other fourteen actions are identical.
   A similar exception requires a demonstrated correctness fix; other unresolved allocation increases still stop
   the affected family. Foundation gates and the remaining widget/panel migrations must complete before stage 5
   is marked done.

   **Native text and icon leaves.** `Text` and `Icon` have constructor inputs in final fields and emit their terminal
   render nodes directly. Structural ownership belongs to their enclosing `TrackedScope` / `EqualChild`; changing
   leaf text uses `BoundText`. These leaves have no component-owned state and need no additional structural owner.
   Text applies an authored typography override only when at least one font-size, letter-spacing or color value
   is present; explicit zero spacing and transparent color remain authored values. Icon painting uses the existing
   canvas save/restore operations with `defer`, preserving restoration on failure without a nested paint lambda.
   No binding primitive or compatibility API is added. `TextIconMain` covers inherited, stylesheet and local
   typography precedence and icon semantics on HashLink, Wasm32 and Wasm GC with both inline settings.

   **Native icon-button structure.** `IconButton.body()` describes its styled control node inside a native
   `TrackedScope`. The scope wrapper owns structural replacement and keeps caller-added listeners and overlay
   children separate from that replaceable body. The button's semantic/focus target retains its existing widget ID
   inside the scope. Enabled state and the activation callback are constructor inputs in final fields, including
   PropertyEditor's reset action. This is the same structural primitive as panels use, with no widget-specific
   updater or adapter. The terminal body remains an internal native render primitive; interaction changes rerun
   its enclosing scope using the foundation's existing interaction routing. Per-node interaction signals remain
   the later stage-5 interaction migration, rather than introducing a second binding mechanism for this control.
   BIM's undo/redo children are final descriptions behind `EqualChild`, with editor identity and action as their
   declared inputs. Their callbacks are made only when those inputs change. The input value implements equality
   explicitly using class identity, so replacing an editor with the same visible key also replaces its actions.
   This avoids repeatedly mounting native owners for unchanged controls during telemetry updates. The portable
   control fixture checks both equal-input retention and replacement-owner callback routing on all three targets.
   Against the pushed text/icon head, telemetry step falls from 15,078 objects / 630,336 bytes to
   14,983 / 624,712; the fifteen standard actions and six CNC pilot actions are identical. No exception is used.

   **Focus capture before widget ports.** Focus, blur and focus-lost follow capture from root through the target,
   followed by target dispatch, with no ancestor bubbling. Each registered target listener runs in its selected phase
   exactly once. Stable component wrappers can therefore observe focus without attaching callbacks to replaceable
   body nodes or adding Button-specific callback props. Recursive traversal fixes the ancestor path before handlers
   run without allocating an array. Dispatch of a prepared event allocates zero; construction of the existing
   `UiEvent` remains outside that interval. The portable routing and allocation fixtures cover all three targets.
   The event phases are documented in `packages/ui/docs/EVENTS.md`. The exact fifteen standard and seven pilot actions
   are unchanged against `835a2bbc8` / outer `7eff0a036`; pilot fresh-mount verification passes. The routing regression
   fails against the old control on HashLink (exit 1), and passes on all three targets with inlining off/on.

   **Button constructor and composition port (in progress).** Presentation inputs are a sparse, typed constructor
   record stored in final fields. Composites supply their complete `Semantics` description as data rather than
   editing a replaceable body after mount; the control owns that description. Default semantics and activation
   forwarding are made once from immutable inputs. Decorations compose through existing child-view slots, where
   they inherit the control's computed style. The stable structural wrapper keeps caller listeners; focus uses the
   semantic control's widget ID. This uses ordinary values and `View` composition, not a decorator hook, patch
   fallback or new binding primitive. Existing mutable property setters are removed as their callers are ported.
   A styled terminal element projects its resolved outer layout (axes, positioning, visibility, clipping and transform)
   onto the stable scope wrapper; its content node fills that box and retains padding and paint. This keeps CSS layout
   and caller wrapper edits valid across reruns without adding fields to every scope owner. A changed projection records
   its prior before mutation; unchanged projections need no style snapshot. Portable scope and Button fixtures cover
   projection changes, caller overrides and accessible metadata/decorations across interaction reruns.
   Topology snapshots stop at a native scope's owned body, and interaction snapshots leave native-owned flags to the
   scope. Otherwise leaf hover/focus or an independent body replacement invalidates the enclosing cache even though
   its own inputs did not change. Interaction traversal keeps existing lifetime records for unported descendant
   updaters. Caller-added wrapper children still participate in interaction and topology checks. Native membership queries reuse
   the registered owner and its existing body pointer; no owner fields, caches or binding primitives are added.
   Portable regressions fail before the interaction (exit 8) and topology (exit 12) ownership checks. They verify native
   hover/focus refresh without rebuilding the parent, constructor-input changes that do rebuild it, and removal of a
   caller-added child that invalidates the cached variant.
   Focus-dependent composition uses capture listeners on the stable wrapper, following the independent event-model
   change above; Button has no focus-specific callback props.


   **Button allocation stop (2026-11-12; draft remains uncommitted).** The previous pushed head is
   `835a2bbc8`, with outer control `7eff0a036`. The final measured draft uses the independently committed focus
   capture change, native scope ownership/topology fixes, and hover-selector identity matching without temporary
   style targets. Scope and Button regressions pass on all three targets, inlining off/on. Pilot verification
   still compares against a fresh mount every frame and passes. These checks do not accept the allocation gate.
   The fifteen standard actions and seven pilot actions are:

   | Action | Control objects / bytes | Button draft objects / bytes | Delta objects / bytes |
   | --- | ---: | ---: | ---: |
   | hierarchy->sensors | 1,672 / 121,720 | 1,685 / 125,040 | +13 / +3,320 |
   | sensors->hierarchy | 1,145 / 80,904 | 1,105 / 79,048 | -40 / -1,856 |
   | console->telemetry | 1,174 / 79,288 | 1,174 / 79,152 | +0 / -136 |
   | telemetry->console | 1,708 / 93,680 | 1,647 / 89,280 | -61 / -4,400 |
   | scroll-inspector | 227 / 25,784 | 232 / 26,744 | +5 / +960 |
   | hover-enter | 32 / 1,032 | 32 / 1,032 | +0 / +0 |
   | hover-inside | 32 / 1,032 | 32 / 1,032 | +0 / +0 |
   | idle | 17 / 584 | 17 / 584 | +0 / +0 |
   | idle-focused | 17 / 584 | 17 / 584 | +0 / +0 |
   | hover-other | 187 / 9,760 | 188 / 9,848 | +1 / +88 |
   | hover-field | 323 / 17,432 | 321 / 16,928 | -2 / -504 |
   | hover-away | 257 / 12,576 | 257 / 12,552 | +0 / -24 |
   | type-char | 417 / 16,456 | 417 / 16,456 | +0 / +0 |
   | type-backspace | 432 / 17,088 | 432 / 17,088 | +0 / +0 |
   | selection | 8,565 / 581,608 | 8,836 / 608,160 | +271 / +26,552 |
   | cnc-unchanged | 19 / 640 | 19 / 640 | +0 / +0 |
   | cnc-select | 2,193 / 123,272 | 2,193 / 123,272 | +0 / +0 |
   | cnc-source | 4,615 / 268,336 | 4,615 / 268,336 | +0 / +0 |
   | cnc-progress | 5,467 / 278,736 | 5,470 / 278,544 | +3 / -192 |
   | cnc-hold | 1,011 / 46,736 | 1,003 / 45,880 | -8 / -856 |
   | cnc-resume | 1,462 / 76,384 | 1,502 / 81,552 | +40 / +5,168 |
   | telemetry-step | 14,983 / 624,712 | 15,104 / 639,816 | +121 / +15,104 |

   The inspector-scroll increase is entirely five additional immutable `ResolvedLayoutItem` snapshots, one per
   added structural wrapper whose geometry moves. Interaction flag and topology ownership fixes removed the large
   accidental enclosing-cache rebuilds, but native Button mounts and wrapper geometry still exceed the old form.
   The remaining selection, resume and telemetry increases are not demonstrated correctness costs, so the foundation's
   telemetry exception does not apply. A value-type terminal body was also measured and rejected: returning it through
   `View` still boxed it and slightly increased bytes; the draft retains the class form. No budget or verification
   change is accepted. This stops the Button family under the stage's allocation rule, rather than publishing a
   regressing batch or introducing another retained-update path.
   The framework gate also fails with `Uncaught exception: Dock workspace contract failed at line 6519`:
   Escape cancellation uses the focused inner Button ID while the stable tab wrapper owns pointer capture. That
   interaction defect remains unfinished in this rejected draft. Tier 1 and the remaining Tier 2 checks have not been
   run on this final draft; it is not eligible for commit or push. The independent focus commit is local and still
   awaits its remaining Tier 2 gates. The queued closed event-phase enum port has not started.
   Machine-readable counts, source hashes, allocation stacks and gate output remain on DATA1 under
   `button-allocation-stop.json`, `button-selector-{all,pilot}-census.json`,
   `candidate-button-selector-source-hashes.json` and `button-selector-framework.log`.

   **Lead-directed allocation attribution before changing scope identity (2026-11-12).** The lead requested
   measurement before removing scope wrappers, and a report before changing direction if non-wrapper costs were
   responsible. A new control capture reproduces selection at 8,565 objects / 581,608 bytes and telemetry step at
   14,983 / 624,712, exactly matching the previous control. The final rejected native draft measures 8,836 / 608,160
   and 15,104 / 639,816. Exact per-type object counts and every-byte site weights reconcile to both complete deltas;
   allocation-site byte samples are not interpreted as object counts.

   | Cause | Selection delta objects / bytes | Telemetry delta objects / bytes |
   | --- | ---: | ---: |
   | Render nodes and element projection storage | +20 / +9,280 | +14 / +6,496 |
   | Layout nodes | +20 / +2,400 | +14 / +1,680 |
   | Resolved geometry | +6 / +1,152 | +0 / +0 |
   | Layout styles | +13 / +4,472 | +12 / +4,128 |
   | Native scope ownership records | +20 / +3,840 | +14 / +2,688 |
   | Removed legacy ownership records | -40 / -3,040 | -28 / -2,128 |
   | Scope/body descriptions | +40 / +1,280 | +28 / +896 |
   | Interface adapters | +40 / +1,440 | +28 / +1,008 |
   | Closures and environments | +72 / +2,704 | +46 / +1,776 |
   | Constructor input records | +20 / +2,400 | +14 / +1,680 |
   | Arrays | +34 / -1,056 | -25 / -3,328 |
   | Reactive edges | +10 / +720 | +0 / +0 |
   | Other types and object size changes | +16 / +960 | +4 / +208 |
   | Total | +271 / +26,552 | +121 / +15,104 |

   `TrackedScope.build` creates the extra plain root, and `RenderNode.new` creates its `LayoutNode`.
   Twenty selection and fourteen telemetry Button mounts explain the additional render/layout node pairs. The
   render-node byte delta also includes 184 extra bytes per styled body in `ComponentElement`, allocated at
   `Button.buildButton`, for projecting its outer layout onto the wrapper. `ResolvedLayoutItem.decode` accounts
   for six additional geometry objects in selection and none in telemetry; the telemetry increase is not extra
   geometry snapshots. Layout-style counts are net of the old updater's removed style copies.
   Native ownership records allocate at `BuildContext.mountRenderScope`: twenty / fourteen `RenderScope` instances.
   They replace twenty / fourteen each of `SelfUpdatingBuild` and `BuiltNode`; ownership records therefore save
   twenty / fourteen objects in aggregate, despite increasing bytes. The `TrackedScope` plus `ButtonBody`
   descriptions add forty / twenty-eight objects, and the `View` plus reactive-tracking interface adapters add
   another forty / twenty-eight. Closure/environment sites include `captureBuild`, `mountRenderScope` and
   `TrackedScope.build`; all closure types together add seventy-two / forty-six objects after subtracting removed
   legacy closures. Sparse constructor-input records add twenty / fourteen more objects.
   Thus wrapper render/layout nodes account for 40 of the +271 selection objects and 28 of the +121 telemetry
   objects. Scope descriptions, adapters, constructor inputs and closures are material independent costs; this is
   not a wrapper/geometry-only increase. Per the lead's step 3, report this attribution before changing representation.
   No wrapper-free implementation, native decoration transfer, or alternative retained-update path has been added.
   Detailed type deltas and allocation-site byte deltas are in DATA1 `evidence/button-lead-attribution.json`; the
   fresh control allocation stacks are in `evidence/button-direction-control-stacks.json`.

   **Lead-directed mount overhead reductions (in progress, 2026-11-12).** Stateful controls implement
   `ScopeView` directly: their own key, final-input equality and native `buildBody` method form one component description.
   Button and IconButton no longer manufacture a `TrackedScope` description and a separate body view. Function-based
   scopes implement the same protocol. Equality reads final fields and compares authored class names by content;
   accessible descriptions use the existing deferred-value-safe semantic comparison. A portable input-contract
   fixture checks equal presentation, changed callback ownership, style, classes and accessibility, with zero allocation
   for repeated comparisons on HashLink.
   Step 1's controlled twenty-mount comparison, including component construction and cold state registrations after
   warming runtime/theme metadata, reduces Button from 3,422 objects / 242,912 bytes to 3,362 / 241,632, and IconButton
   from 3,437 / 234,752 to 3,377 / 233,632. This saves three objects per mount; it does not yet accept the editor census.
   Step-zero sources were reconstructed and SHA-checked against the rejected draft. Exact counts are retained in
   DATA1 `evidence/component-description-step1-measurement.json` and `scope-mount-step{0,1}-{button,icon}-raw.json`.
   The next reduction stores inherited key/style/text inputs on the native owner and calls the component method directly,
   rather than allocating captured build functions. Tracking entry/exit will share the existing read/creation-log
   bookkeeping through a value frame; this changes no subscription or observable-creation rule and introduces no
   widget binding API. Native lifetime cleanup will belong to the existing state handle, avoiding per-mount resource
   cleanup closures or a second owner-holder object. Failure recovery and retained hidden-resource lifetime must retain
   their current tests on all three targets. The wrapper remains until the lead's final identity/decorations step.
   Step 2's direct mount path reduces the same twenty Button mounts from 3,362 objects / 241,632 bytes to
   3,104 / 233,256, and IconButton from 3,377 / 233,632 to 3,119 / 225,256. The complete type census contains no
   BuildContext mount-path closure environments or mutable result cells. Content/paint callbacks within the widgets
   are unchanged. The state handle now directly releases its native scope; no native lifetime-holder object or
   per-owner cleanup callback is created. Only that state subtype gains an owner field; normal state handles gain no
   instance fields. Existing per-frame state reachability and hidden-panel resource ownership remain the mechanism.
   Native bodies use the existing local read capture, transferring reads to the owner on both success and failure;
   the redundant outer collector is removed. This also removes the per-owner reactive interface adapter. A recovery
   regression caught the missing failed-read transfer and now retries when the failed body's dependency changes.
   The shared tracking entry/exit value frame preserves nested collector and observable-creation bookkeeping.
   An initially mutable try result allocated a cell, while a try-expression allocated a captured thunk; both measured
   forms were rejected. The final direct helper keeps its immutable result inside the try statement and allocates
   neither. Exact measurement is DATA1 `evidence/component-direct-mount-step2-measurement.json`.
   A minimal non-generic reference-class reproduction already isolates the interface issue: converting 1,024 existing
   instances to a one-method and a two-method interface allocates 2,048 HashLink virtual adapters / 73,728 bytes
   (32,768 + 40,960). No value-type boxing or generic erasure is involved. `TToInterface` lowers to `ToVirtual`, and
   HashLink emits its allocating virtual-view operation; both Wasm lowerings preserve the reference for these classes.
   The reproduction is DATA1 `interface-mount-repro/InterfaceMountRepro.hx`, with exact HashLink census in
   `evidence/interface-mount-repro-raw.json`. This compiler gap is reported to the lead; no compiler sources or
   interface-avoidance workaround have been changed. Cross-target counters confirm the gap: both Wasm targets allocate zero for 8 / 1,024 instances, inlining off/on; HashLink allocates 2,048 adapters / 73,728 bytes for 1,024 instances with either inline setting. The full reproduction and compiler-owner report are DATA1 `evidence/reference-interface-gap.{json,md}`.

   Step 4 removes the sparse `ButtonOptions` heap record entirely. All presentation inputs are direct optional
   constructor arguments stored in the component's final fields; the equality check reads those fields. The first
   four constructor arguments retain their roles. Highly customized composites have a longer argument list, but
   this uses ordinary Haxe without a second props object, a builder API, forced inlining or a compiler feature.
   Authored mutable styles/class arrays retain their existing defensive ownership rules. No record compatibility
   overload or alias remains. Controlled twenty-mount input-record/direct-input builds with identical enabled,
   variant, classes, icon size and accessible name reduce 3,134 objects / 235,576 bytes to 3,094 / 232,856:
   forty objects / 2,720 bytes saved, comprising the input records and their optional numeric boxes. Exact evidence
   is DATA1 `evidence/component-direct-inputs-step4-measurement.json`. Button and input-contract fixtures pass
   on all three targets with both inline settings. The representation still contains the structural wrapper;
   removing it and transferring caller ownership remain unfinished, and no editor allocation gate is accepted.

   **Body-root prototype and remaining mount cost (unpublished, 2026-11-12).** The next prototype removes
   `ComponentElement` and the render/layout wrapper. A scope reserves the actual body's ID before interaction and
   style reads; primitive roots use `BuildContext.rootId` and `createNode`. Only actual scope roots carry an owner
   reference (`ScopeRootNode`, or `ScopeTextRootNode` for live text); ordinary descendants and live text leaves gain
   no instance fields. Native owners resolve replaced roots through their logical resource lifetime, rather than
   `RenderNode.replacedBy`, `latest`, or a global numeric-ID redirect. The native root registry map is removed.
   A value boundary records authored layout, semantics, callback counts and owned children. Replacement transfers
   caller overrides, listeners, paint/resolution callbacks and overlays to the new body. Caller style ownership
   survives an authored default temporarily matching its value. Forwarding scopes can share one physical root;
   their declared boundaries advance together when an inner scope replaces it. None of this uses `BuiltNode` or
   reconciliation. Equal-input retention still uses `EqualChild`; the protocol's field comparison is present, but
   automatic component-mount skipping is not implemented in this draft.
   HashLink regressions pass for replacement identity, throwing-body recovery, caller decoration transfer,
   forwarding boundaries, retained reparenting, live binding lifetime, Button and IconButton. Replaced native children
   retain their authored ownership instead of becoming caller overlays. An equal-child hit that temporarily detaches
   the body root restores its parent slot. Scheduled ancestors take precedence even after scope storage order changes.
   Removing a caller overlay still invalidates the retained variant; that assertion is preserved. Focus and dock
   assertions now address the actual Button root, but the full dock/framework gate has not run on this prototype.
   A real cached-submission regression, with fresh verification enabled every changed frame, fails on the old
   top-level submission selection (80-pixel old root versus 120-pixel new root), and passes when submission resolves
   the native owner's current root. It is included in the layout-session gate. A separate duplicate-key regression
   preserves rejection of two fresh mounts in one build while allowing independent mounted-body refreshes.
   The three-target gates are unfinished; these HashLink checks are not a batch acceptance.

   Step 5's same-input twenty-mount comparison reduces 3,094 objects / 232,856 bytes to 2,680 / 204,328
   (minus 414 / 28,528). A separate fresh control using the published `835a2bbc8` Button and its old constructor/setter
   API, with identical enabled, variant, classes, icon size and accessible name, measures 2,672 / 198,296.
   Presentation parity passes for all twenty controls: authored root/label layout fingerprints, selector classes,
   enabled/focusable state, semantic role/name/actions/states and label typography/color. Thus this control is correct;
   there is no correctness exception for the remaining **plus 8 objects / 6,032 bytes**.
   Default-input Buttons independently reproduce the same excess: 2,682 / 198,696 control versus
   2,690 / 204,728 native. IconButton uses the same body-root form and improves its twenty-mount published control
   from 3,437 / 234,752 to 2,705 / 200,088 (minus 732 objects / 34,664 bytes).

   | Remaining twenty-mount difference | Objects | Bytes |
   | --- | ---: | ---: |
   | Body root owner reference, replacing ordinary roots | 0 | +160 |
   | `RenderScope` + `ScopeState`, replacing `SelfUpdatingBuild` + `BuiltNode` | 0 | +3,200 |
   | Button instance storage | 0 | +640 |
   | Scope protocol interface adapters | +20 | +1,120 |
   | Boxed value-boundary constructor temporaries | +20 | +1,120 |
   | Removed infrastructure closure functions and environments | -80 | -2,400 |
   | Arrays, scalar boxes and allocation buffers | +48 | +2,192 |
   | Total | +8 | +6,032 |

   These are exact aggregated type counts; equal printed type names are summed rather than overwritten. Site
   evidence is byte weighted, not interpreted as object counts. The native lifetime registration additionally appears
   at `StateStore.scopeLifetime` (including twenty Boolean boxes), with usage arrays at `StateStore.markUsed`.
   The ownership/lifetime record storage is a remaining cost beyond the five directed description/closure/interface/
   input-copy/wrapper causes. Per the lead's stop rule, do not change that representation further or publish this
   prototype before reporting the attribution. No current 22-action census or final stage-3 comparison is claimed.

   The boundary temporary also exposes a second compiler limitation, separate from reference-interface adapters.
   A minimal struct with six conditional scalar assignments, stored in an existing class field, allocates 1,024
   temporary values / 24,576 bytes for 1,024 operations on HashLink, with inlining both off and on. Five conditional
   assignments plus one direct assignment produce identical results and allocate zero. The existing value-constructor
   expansion is bounded to sixteen blocks and sixty-four instructions (`IrValueConstructors`); the reproduction
   crosses its block bound: five-branch construction has sixteen blocks / thirty-nine instructions, while six has
   nineteen / forty-three. The actual boundary constructor has nineteen blocks / sixty-three instructions and is
   left as a constructor call. Report this compiler gap at its cause rather than splitting the UI constructor, forcing
   inlining or raising expansion limits. No compiler/IR or HashLink edits, new binding primitive, verify-mode change
   or budget change have been made. Source, exact counters and the owner report remain on DATA1 under
   `evidence/{scope-root-native-vs-control-types,scope-root-lifetime-site-bytes,scope-root-input-parity,bounded-constructor-hl}.json`
   and `interface-mount-repro/bounded-constructor/BoundedConstructorRepro.hx`.

   **Lead-directed ownership storage reductions (2026-11-12, unpublished).** Native scopes now have one owner
   record. `StateStore` stores `RenderScope` directly in a typed registry; `ScopeState` and the unused
   `State.releaseResource` hook are deleted. A successful mount installs the owner after its body succeeds, preserving
   the previous installed computation when a replacement throws. Managed membership uses the existing flat integer
   `IdSet`, with allocation-free cluster repair on deletion, instead of boxed Boolean map values. Per-frame usage
   IDs and persistent managed-resource IDs use reusable integer storage with logical lengths; nested captures and
   resource compaction no longer resize their backing storage down. State-usage arrays belong to the store's existing
   ownership table rather than being duplicated on each owner. Logical resource IDs are integers; the body root holds
   its own widget identity, and initial build identity lives only in context scratch while construction runs. Packing
   the owner's scalar fields reduces `RenderScope` from 256 to 224 bytes.

   | Twenty same-input Button mounts | Objects | Bytes |
   | --- | ---: | ---: |
   | Correct published control | 2,672 | 198,296 |
   | Body-root prototype before storage changes | 2,680 | 204,328 |
   | Single native owner | 2,660 | 203,208 |
   | Flat managed membership | 2,622 | 201,872 |
   | Reusable usage and managed ID storage | 2,612 | 201,168 |
   | Compact owner without duplicated identity/usage data | 2,612 | 200,528 |

   The actual remaining difference is **minus 60 objects / plus 2,232 bytes**. Both compiler-gap items remain
   unchanged: twenty scope-interface adapters / 1,120 bytes and twenty boundary-constructor value temporaries /
   1,120 bytes. Arithmetic subtraction of those measured items gives 2,572 / 198,288, eight bytes below control;
   this is attribution, not a claim that a patched compiler has been measured. No UI workaround for either compiler
   gap, forced inlining, expanded constructor limit, or verify/budget change is introduced. Per the lead's updated
   condition, stop and report while the excess is accounted for only by these compiler gaps. Full dock/framework
   gates, the 22-action census and publication wait for the compiler-side fixes. The next outer gate must use local
   outer main `60d9d4c36`, superseding `771c20b61`; no outer gate has run on either base during this batch.
   Exact counters are DATA1 `evidence/scope-mount-{single-owner,flat-managed,flat-usage,compact-owner}-button-raw.json`.
   Focused validation passes: nine HashLink fixtures covering ownership, binding lifetime, inputs and controls;
   `IdSetMain` and `StateStoreFlatMain` on all three targets with inlining off/on (twelve configurations); and
   the real `UiContext` root-replacement submission regression on HashLink with fresh-build verification.

   **Updated lead acceptance direction.** Preserve the Button batch locally and run full three-target,
   dock/framework and exact 22-action gates despite the twenty-mount residue. Publication is decided per measured
   action, under the user's 2026-11-12 refined acceptance rule. Steady-state actions (`idle`, `idle-focused`,
   `hover-*`, `scroll-inspector`, `type-*`, `telemetry-step`, `cnc-unchanged`, `cnc-progress`) must not increase
   objects or bytes against the correct control. Structural actions (tab switches, selection, `cnc-select`,
   `cnc-source`, `cnc-hold`, `cnc-resume`) must not increase objects; additional bytes require measured,
   per-action attribution recorded here. The two owned compiler gaps qualify only when their contribution is
   demonstrated: dev-c5 owns HashLink interface adapters and a1 owns value-constructor destination construction.
   No UI workaround is authorized. Report frame-time and GC-pause percentiles alongside allocations. The
   twenty-mount microbenchmark is attribution, not the per-action publication decision. A failing correctness
   gate still prevents publication; neither fresh-build verification nor budget ceilings may be weakened.
   If the batch cannot be published, preserve its named branch and continue the approved independent queue.

   Stage 5 additionally requires a collections checkpoint at the composites stage: keyed row scopes,
   zero-allocation scrolling and correct reorder for ListView, TreeView, TableView and VirtualGrid, with
   measurements. Before removing old update machinery, test live patches that change inputs and structure while
   preserving component identity and state. Finish with a short `packages/ui/docs` guide, "Writing a Haxeon UI
   component", separate from this decision history. The decorations-as-input inventory and proposal follows the
   Button batch's publication or parking; implementation waits for the lead's decision on that proposal.

   **Nested scope ownership regression (unpublished).** A native body replacement detached the physical child
   stored in its legacy parent's authored `BuiltNode.children` snapshot. Rebuilding that parent then inserted the
   new child without removing the current one; a focused regression failed with "Layout node IDs must be unique".
   Reconciliation now resolves each native authored child through its own owner before comparing or replacing it.
   With that corrected, a simultaneous parent and child invalidation exposed a second failure: "A removed native
   body ran after its legacy parent replaced it: 2". Native scheduling had treated every owner without a native
   parent as attached. `flushRenderScopes` now requires the submitted root, and attachment follows the actual
   parent chain to that tree's current root. Every producer and test caller is ported; no zero-argument fallback
   remains. This adds no per-component storage or mount allocation. The native reproduction passes both fixes
   and a fresh-build comparison. The additional lifetime regressions and allocation checkpoint below extend
   this evidence; final family gates still require a fresh post-rebase run.
   The existing failed-replacement test also failed at check 21 on an isolated `93e399bca` source snapshot:
   the original mounted scope lost its subscription when the replacement threw and the frame swept unused
   resources. Distinct instance tickets had stopped a failed mount from touching the previous live ticket.
   Mount rollback now retains the mounted owner of the same logical slot on the failure path only. This adds
   no successful-mount allocation or per-owner field. The regression and six existing ownership/control checks
   pass on HashLink after correction. `ScopeLegacyReplacementMain` also passes all three targets with
   inlining off/on, and the full native framework/dock/input gate passes. The fresh editor now passes the former
   `cnc-source` revision mismatch, but fails later at `cnc-returned` with "Widget state has not been initialized
   for 954415806". A focused hidden-variant test reproduced premature native-owner disposal while full-frame
   retention was still in progress. Detached scopes now stop scheduling immediately, while an active or requested
   full-frame resource sweep decides whether cached owners remain live. Patch-only removals without such a sweep
   still release obsolete owners immediately. The focused test checks stable widget IDs and that returning cached
   variants do not recreate their retained widget state; it and four existing ownership checks pass on HashLink.
   The cache and replacement regressions pass all twelve target/inlining configurations. The fresh editor
   passes all three pilot cycles, as recorded below; no final stage-3 census or publication is claimed.

   **Button allocation checkpoint (unpublished; renewed on compiler base `7b97c092e`).** Both control and native pilot panels pass
   fresh-build verification for three complete CNC/telemetry cycles, including source replacement and hidden-panel
   return. The correct control is the previous published UI head `835a2bbc8`, rebuilt against outer `e9173b977`
   and the same compiler/runtime as the candidate. These are the exact 15 census actions plus seven pilot actions;
   this is an allocation checkpoint, not the final stage-3 comparison or a passing batch. The following numbers include the sorted-array cache fix. Formatting, rebase, Tier 1 (895 passed,
   zero failed), fixed-point self-hosting and all ten native UI gates pass. The renewed full Tier 2 gates
   remain unfinished; telemetry has the temporary approval recorded below.

   | Action | Control objects | Native objects | Control bytes | Native bytes | Objects delta | Bytes delta |
   | --- | ---: | ---: | ---: | ---: | ---: | ---: |
   | `hierarchy->sensors` | 1,672 | 1,660 | 121,720 | 120,200 | -12 | -1,520 |
   | `sensors->hierarchy` | 1,145 | 1,142 | 80,904 | 80,664 | -3 | -240 |
   | `console->telemetry` | 1,174 | 1,162 | 79,288 | 78,272 | -12 | -1,016 |
   | `telemetry->console` | 1,708 | 1,700 | 93,680 | 93,056 | -8 | -624 |
   | `scroll-inspector` | 227 | 226 | 25,784 | 25,592 | -1 | -192 |
   | `hover-enter` | 32 | 32 | 1,032 | 1,032 | +0 | +0 |
   | `hover-inside` | 32 | 32 | 1,032 | 1,032 | +0 | +0 |
   | `idle` | 17 | 17 | 584 | 584 | +0 | +0 |
   | `idle-focused` | 17 | 17 | 584 | 584 | +0 | +0 |
   | `hover-other` | 187 | 182 | 9,760 | 9,520 | -5 | -240 |
   | `hover-field` | 323 | 313 | 17,432 | 16,472 | -10 | -960 |
   | `hover-away` | 257 | 249 | 12,576 | 12,104 | -8 | -472 |
   | `type-char` | 417 | 417 | 16,456 | 16,456 | +0 | +0 |
   | `type-backspace` | 432 | 432 | 17,088 | 17,088 | +0 | +0 |
   | `selection` | 8,649 | 8,563 | 585,416 | 589,792 | -86 | +4,376 |
   | `cnc-unchanged` | 19 | 19 | 640 | 640 | +0 | +0 |
   | `cnc-select` | 2,193 | 2,193 | 123,272 | 123,272 | +0 | +0 |
   | `cnc-source` | 4,615 | 4,595 | 268,336 | 267,448 | -20 | -888 |
   | `cnc-progress` | 5,466 | 5,465 | 278,240 | 277,912 | -1 | -328 |
   | `cnc-hold` | 1,011 | 1,001 | 46,736 | 45,648 | -10 | -1,088 |
   | `cnc-resume` | 1,462 | 1,455 | 76,384 | 76,968 | -7 | +584 |
   | `telemetry-step` | 14,983 | 14,851 | 624,712 | 625,032 | -132 | +320 |

   Selection and resume meet the structural object rule; their byte increases are measured representation costs.
   Selection includes thirteen additional `LayoutStyle` instances / 4,472 bytes from constructing immutable style
   inputs and copying them in Button. Its forty compiler-gap items contribute 3,040 bytes; the remaining net UI
   residue is 1,336 bytes. Resume has six compiler-gap items / 456 bytes and 128 net bytes from node/owner, Button
   fields and array storage. Complete per-type sums and caller sites are in the DATA1 attribution files.
   Telemetry removes 132 objects but adds 320 bytes: its fourteen interface adapters / 784 bytes and fourteen
   boundary temporaries / 1,344 bytes account for the excess. Arithmetic removal of those compiler items gives
   minus 160 objects / minus 1,808 bytes; this is attribution, not a patched-compiler measurement.

   **Historical cause, fixed by the cache change below.** Before that fix, `cnc-progress` added one object / 496 bytes. The exact
   byte-site delta is `BuildContext.pruneKeyCaches`, not either compiler gap. A census-window-only native debugger
   breakpoint confirms `hl_freelist_resize`: old capacity 41, head 41, new capacity 62, payload 496 bytes.
   Its backtrace is `hl_freelist_resize` → `hl_freelist_add_range` → `hl_hbremove` →
   `BuildContext.pruneKeyCaches` (`idsByPath.remove` at the captured line 946). The debugger run reproduces the
   same exact 5,467 objects / 278,736 bytes. HashLink map removal grows its fragmented-slot freelist; this is a
   separate runtime allocation, not the interface-adapter or constructor-temporary limitation and not a correctness
   exception. No HashLink edit was made. After the attribution report, the lead assigned this to UI cache
   maintenance and requested the stable-capacity fix below. At that checkpoint, telemetry remained unpublished pending the lead decision. The later user approval
   is recorded below; no exception was assumed during those measurements.
   Evidence: DATA1 `evidence/instance-body-root-exact-22-comparison.json`,
   `native-child-ownership-*-type-delta.json`, `instance-body-root-structural-byte-attribution.json`,
   `cnc-progress-freelist-confirmed-gdb.log` and its calibrated census JSON.

   **Lead-directed UI cache fix (implemented and remeasured).** The follow-up trace identifies
   nineteen stale paths ending in `slot:N/row/item:line-N/text`: CNC auto-follow moves a fixed-size virtualized
   window. The slot roots remain, but each recycled slot changes its keyed text child. Removing those old IDs
   is correct; retaining dead IDs or dropping the item key would change identity semantics. Repeated removal and
   insertion fragments the global string map's free-slot ranges and grows its freelist during a steady action.
   Replace that map and its separate traversal list with `WidgetIdCache`: sorted parallel path/WidgetId arrays,
   binary lookup, in-place pruning and retained high-water storage. It starts empty and grows only for actual
   insertions; no capacity pre-sizing is used. The cache preserves WidgetId references, path hashing, collision
   resolution, liveness checks and the existing 8,192-ID bound. Stale references are cleared without trimming the
   backing arrays. The cache fix changes neither HashLink nor the compiler and adds no per-widget entry object.
   On the freshly built `065e0de61` compiler base and pinned HashLink `7d33c19fb`, the minimal original-map path
   fails after eight warm cycles with "Steady key-cache pruning allocated backing storage: 2736". The new
   alternating-window regression passes on HashLink, Wasm32 and Wasm GC, with inlining off/on: 1,024 frames
   allocate nothing, retain exactly the live IDs and keep stable backing storage. The fresh 22-action census on `7b97c092e` confirms `cnc-progress` at 5,465 objects / 277,912 bytes:
   one object / 328 bytes below the correct control. Its pruning byte-buffer allocation falls to zero. Selection
   additionally saves one object / 1,120 bytes versus the pre-fix candidate; no other action increases. Full
   batch gates remain unfinished. Evidence is
   DATA1 `evidence/cache-old-path-new-base.json` and `evidence/cache-new-base-three-target.log`. Telemetry
   has the temporary user approval recorded below for its two compiler-gap items.

   **Paired frame and GC diagnostics (renewed on `9707f25de`).** Seven alternating control/native pairs cover all 22 actions.
   Frame p50 / p95 / p99 in milliseconds (control → native): selection
   2.882 / 5.826 / 6.307 → 3.206 / 6.028 / 8.172 (21 samples per side); CNC progress
   0.897 / 1.221 / 1.545 → 0.957 / 1.709 / 1.862 (672 samples); CNC resume
   0.496 / 0.797 / 0.820 → 0.528 / 0.860 / 0.895 (21 samples); telemetry step
   2.670 / 3.777 / 4.470 → 2.763 / 3.793 / 4.424 (63 samples). These are diagnostics,
   not timing acceptance thresholds. Every action's frame GC-pause p50 / p95 / p99 is zero on both
   sides: no collection occurred within those measured frame intervals. Frame GC scheduling was enabled;
   it suppresses automatic collection during rendering and may collect at the end of a frame or during idle.
   The counters include `endFrame`, so a forced boundary collection would be counted. Process-wide pilot
   counters record 21 collections on each side across the seven pairs, outside the selected frames; the
   maximum individual process pauses were 3.404 ms control and 3.551 ms native. These zero-inclusive per-frame percentiles do
   not describe the distribution of individual GC pauses or establish a GC-free application. Complete raw
   frame samples, all-action percentiles and process GC counters are in DATA1
   `evidence/publish-9707-paired-frame-gc.json`; exact allocations are in
   `evidence/publish-9707-full-census-report.json` (also available as a 22-row Markdown table). The original checkpoint rejected telemetry's +320 bytes; the temporary user approval follows.

   **Temporary telemetry exception approved by the user.** For the Button batch, `telemetry-step`
   changes from 14,983 objects / 624,712 bytes to 14,851 / 625,032: minus 132 objects and plus 320 bytes.
   This steady-state byte residue is accepted temporarily, attributed to the two measured compiler gaps:
   HashLink class-to-interface adapters (owner: dev-c5) and value-constructor temporaries (owner: a1).
   Re-measure when those fixes land. The residue must disappear; if it does not, the remaining increase is
   a regression to fix, not a continuing exception. This approval does not relax verify mode, budgets, or
   any other action's allocation rule. Publication still requires the remaining full batch gates and rebase.

   **Closed event phases (ported; final batch gates pending).** `UiEventPhase` closes the public event
   phase to `Capture`, `Target` and `Bubble`; registration takes the same enum, with `Bubble` as the default.
   The existing target-only bubble subscription is an internal listener-selection policy, represented by a
   separate private enum in the existing handler field. It adds no per-listener record or field and never
   appears as an event phase. Outside-pointer notifications remain separate direct subscriptions and report
   `Target`, with the original pointer target and subscribed node as `currentTarget`; there is no fourth routed
   phase. Producers, readers, UI/example callers and outer callers are ported together, without string overloads.
   The routing regression covers listener ordering, target-only selection and outside delivery; negative fixtures
   reject string assignment and registration. All eighteen runtime target/inlining cases and twelve string-rejection cases pass;
   dispatch allocation remains zero on all targets. Standalone HashLink pairs with inlining off/on
   also preserve event-construction bytes (163,680 for the warmed 1,024-event counter window) and listener
   registration bytes (106,576 for 1,024 listeners). The subsequent same-compiler 22-action comparison
   is exactly unchanged, as recorded below. Final batch gates and rebase still precede publication.

   **Renewed publication evidence on `9707f25de`.** The fresh published-head control, Button-before-enum
   control and Button-plus-enum modules use the same compiler and runtime. All 22 action counts in the table
   above are unchanged from the parked checkpoint. The enum-only comparison is exactly equal in objects and
   bytes for every action. Pilot fresh-mount verification passes on all three modules. The portable component
   suite passes 162 target/inlining configurations plus twelve string-rejection cases; UI value snapshots pass
   sixty positive and 702 negative configurations. The full compiler gate passes all eighty integration stages,
   both 897-test driver runs, Wasm backend/parity, compiler embedding and external-tool checks. The explicit
   fixed-point check also passes, with identical stage-1/stage-2 hashes. No full-gate baseline skips were needed.

   Outer gates use `e9173b977`, with `MATERIA_ROOT` set to the shared supplier-data checkout and all outputs,
   caches and temporaries on DATA1. App tests and headless performance pass. Retention passes eight scenarios;
   `panel-flows` stops with "Inspection camera ignored its view label", reproduced on the fresh control with
   verification enabled. The budget runner repeats that same known retention failure; its three performance
   scenario results contain no budget failures. This is a documented outer baseline skip, not a weakened
   verifier or raised ceiling. All ten native UI scripts pass, including the full framework/dock/input and
   1,101-node layout transaction gates. The seven final frame/GC pairs are complete and reported above.
   Fresh reports are DATA1 `evidence/publish-9707-exact-22-comparison.json`,
   `publish-9707-enum-comparison.json`, `publish-9707-full-gate-summary.json` and
   `publish-9707-outer-gate-classification.json` and `publish-9707-ten-ui-summary.json`. Publication still
   requires the final publication checks below.

   The publication branch is rebased onto `bac1af1c8`. Its rebuilt compiler passes Tier 1 with
   898 tests and zero failures, including 554 live, plain and plain-without-early-pruning cases.
   Self-hosting reaches a byte-identical stage-1/stage-2 fixed point. All 162 component runtime
   configurations and twelve string-phase rejection cases also pass after the rebase. UI and native
   runtime sources and pins are unchanged from the renewed census above. Fresh editor control and
   candidate builds pass, with equal source hashes and non-output arguments, but their raw modules
   differ from the earlier compiler's modules. The previous runtime measurements were therefore
   not accepted as proof for this compiler: all 22 actions were captured again.

   **First post-rebase capture: publication stopped.** Twenty-one actions kept their earlier candidate
   counts, including the exact approved telemetry exception. CNC resume instead measures
   1,462 objects / 76,384 B on the control and 1,547 / 80,464 B on the candidate: **+85 objects /
   +4,080 B**, failing the structural object rule. Compared with the previous candidate, the
   extra 92 objects / 3,496 B comprise snapshot encoding, JSON serialization and file-persistence
   allocation sites, including `FileDockWorkspacePersistence.save`. Both sides use identical
   `WorkspaceSaveWorker` source; its background thread encodes and writes a pending snapshot after
   a 150 ms quiet period. This is evidence of possible setup-save activity entering the process-wide
   census window, not permission to subtract it or accept a passing retry. A deterministic scheduling
   reproduction and a correction at the measurement cause were required, as resolved below. No UI increase was
   been excused. Fresh module-bound evidence is DATA1 `evidence/publication-rebase-exact-22-comparison.json`
   and `publication-rebase-cnc-resume-persistence-stop.json`. The earlier frame/GC pairs above belong
   to the earlier modules; the current-module diagnostics are recorded below.

   **Workspace-save census barrier; corrected baseline on `bac1af1c8`.** The controlled reproduction
   queues a setup snapshot under the worker's enqueue lock, opens the census, then releases the lock and
   lets the normal quiet timer expire. The old path fails with one save marker in the window; its stack
   enters through `WorkspaceSaveWorker.run`. Waiting on `awaitIdle()` before opening the window removes
   that marker. A save scheduled by the action itself is included: the harness waits for its encode/write
   and asserts idle before stopping the census. The end-barrier reproduction counts exactly one such save.
   Neither barrier enqueues a save or bypasses the quiet period. Errors remain available through `takeError()`.

   The harness registers every editor it creates, including the additional CNC editor, and drains them
   after setup and at both capture boundaries. The worker and harness changes are identical in the
   published-head control, pre-enum control and candidate. The idle barrier allocates zero on HashLink,
   Wasm32 and Wasm GC with inlining off/on; the worker tests cover quiet completion, no extra writes,
   action saves, coalescing and error reporting. All 22 actions were captured again after the source
   correction, without subtracting any work from the earlier failing capture. The corrected census passes
   the refined acceptance rule. CNC resume is back to -7 objects / +584 B; telemetry remains the exact
   approved -132 objects / +320 B temporary exception. Tab switches now include their own workspace saves
   on both sides, so their absolute counts rise equally and their deltas remain unchanged.

   | Action | Control objects / B | Candidate objects / B | Delta objects / B |
   | --- | ---: | ---: | ---: |
   | hierarchy->sensors | 2,092 / 137,168 | 2,080 / 135,648 | -12 / -1,520 |
   | sensors->hierarchy | 1,565 / 96,384 | 1,562 / 96,144 | -3 / -240 |
   | console->telemetry | 1,594 / 94,776 | 1,582 / 93,760 | -12 / -1,016 |
   | telemetry->console | 2,128 / 109,136 | 2,120 / 108,512 | -8 / -624 |
   | scroll-inspector | 227 / 25,784 | 226 / 25,592 | -1 / -192 |
   | hover-enter | 32 / 1,032 | 32 / 1,032 | +0 / +0 |
   | hover-inside | 32 / 1,032 | 32 / 1,032 | +0 / +0 |
   | idle | 17 / 584 | 17 / 584 | +0 / +0 |
   | idle-focused | 17 / 584 | 17 / 584 | +0 / +0 |
   | hover-other | 187 / 9,760 | 182 / 9,520 | -5 / -240 |
   | hover-field | 323 / 17,432 | 313 / 16,472 | -10 / -960 |
   | hover-away | 257 / 12,576 | 249 / 12,104 | -8 / -472 |
   | type-char | 417 / 16,456 | 417 / 16,456 | +0 / +0 |
   | type-backspace | 432 / 17,088 | 432 / 17,088 | +0 / +0 |
   | selection | 8,649 / 585,416 | 8,563 / 589,792 | -86 / +4,376 |
   | cnc-unchanged | 19 / 640 | 19 / 640 | +0 / +0 |
   | cnc-select | 2,193 / 123,272 | 2,193 / 123,272 | +0 / +0 |
   | cnc-source | 4,615 / 268,336 | 4,595 / 267,448 | -20 / -888 |
   | cnc-progress | 5,466 / 278,240 | 5,465 / 277,912 | -1 / -328 |
   | cnc-hold | 1,011 / 46,736 | 1,001 / 45,648 | -10 / -1,088 |
   | cnc-resume | 1,462 / 76,384 | 1,455 / 76,968 | -7 / +584 |
   | telemetry-step | 14,983 / 624,712 | 14,851 / 625,032 | -132 / +320 |

   Evidence: DATA1 `evidence/workspace-census-unsafe-summary.json`, `workspace-census-barrier-summary.json`,
   `workspace-idle-parity-summary.json`, `workspace-barrier-identical-inputs.json` and
   `workspace-barrier-exact-22-comparison.json`. The fresh enum-only comparison is exactly unchanged on all
   22 actions. Outer app tests and three 500-cycle headless performance runs pass. Retention passes eight
   scenarios; its only failure, "Inspection camera ignored its view label", reproduces on the fresh barrier
   control with verification enabled. The budget runner fails only that same nested retention check;
   its three performance scenarios have no budget failures. No verifier or ceiling changed. The local outer
   commit is `d2ca0968d`, based on `e9173b977`; it is never pushed from this worktree.

   Seven alternating frame/GC pairs use the same fresh modules as the corrected census. Frame time is
   ordinary UI submission time; the allocation-only workspace barriers are inactive in these timing runs.
   Selected p50 / p95 / p99 frame times in milliseconds are:

   | Action | Control | Candidate |
   | --- | ---: | ---: |
   | selection | 2.978 / 5.554 / 5.644 | 2.911 / 5.899 / 5.939 |
   | CNC progress | 0.885 / 1.098 / 1.578 | 0.934 / 1.306 / 1.776 |
   | CNC resume | 0.491 / 0.569 / 0.737 | 0.523 / 0.751 / 0.813 |
   | telemetry step | 2.601 / 4.477 / 5.410 | 2.754 / 3.483 / 3.711 |

   All 22 actions have zero in-frame GC-pause p50/p95/p99 and zero collections in their captured frames.
   The component-panel processes have 21 collections per side outside those frames, with maximum pauses
   of 3.232 ms control and 3.410 ms candidate. These are per-frame pause sums and process maxima, not a
   per-collection percentile distribution or a claim of a GC-free application. All 22 allocation rows and
   diagnostic percentiles are in DATA1 `evidence/workspace-barrier-full-census-report.json` and `.md`;
   outer classification is `workspace-barrier-outer-gate-classification.json`. The final source fetch and
   publication check still precede the push.

   **Undo update-order correction (in progress after the Button push).** The published foundation runs
   child work before a root build that can remove it. The headless create/create/undo fixture fails with
   "Unknown scene object: rectangle-2" after mounting the second inspector. A portable UI fixture reproduces
   stale removed legacy, native-scope and bound-text getters on all three targets with inlining off/on;
   it also checks that cached dirty children which survive the root build still update.

   Root structure now runs before queued structural work, and legacy patches must supply the current root
   and validate physical attachment as well as registration identity. The intermediate fixture passes every
   structural and surviving-child case, but bound text still runs too early in the generic effect queue.
   Live leaf work must follow root/native/legacy structure and validate attachment before invoking a getter.
   The chosen internal form is one native dependency owner per existing `BoundText`, replacing its separate
   `TextBinding` and `ScheduledBindingEffect` records and their scheduling/action closures. The public
   `BoundText` constructor and getter input remain unchanged; no new authoring binding primitive is added.
   Model effects continue to settle before the root decision. UI leaf tracking runs after structure, using
   the same dependency-set protocol and a native context-owned list. Detached cached bindings stay dirty
   and can update when remounted. Widget state remains alive through blur and normal frame retirement.
   Low-level binding fixtures must explicitly flush the native leaf phase instead of the generic model
   effect queue; both scheduling forms will not coexist. A failed root build also re-arms pending leaf
   dependencies, so a later source write can request another frame even when the leaf phase never ran.
   The regression fixture caught the lost wake-up before this retry handling was added.

   The fresh editor module now passes all three create/create/undo cycles with a fresh-mount comparison on
   every frame. The same scenario on the published control fails on its first undo with the exact error
   above; DATA1 `undo-order-before-editor-summary.json` and `undo-order-after-editor-summary.json` bind the
   results to module and log hashes. Allocation and full-gate acceptance remain required before this
   correctness batch can be published. No allocation increase is waived by this design note.


   The first exact 22-action capture against published `e6cf9a07d` is not accepted. All steady-state
   actions are unchanged or lower; selection drops 846 objects / 59,584 B and telemetry-step drops
   1,292 objects / 89,920 B. Four tab transitions increase: hierarchy→sensors +12 / +1,568 B,
   sensors→hierarchy +74 / +18,592 B, console→telemetry +1 / +16 B, and telemetry→console
   +52 / +3,936 B. Site traces put the isolated 16 B at `InteractionStateStore.set`; the larger
   transitions include another Button body and comparison/key storage. This is attribution to sites,
   not yet proof of the underlying scheduling cause. The batch stays unpublished while that cause is
   investigated. DATA1 `undo-order-exact-22-comparison.json` and the initial structural type/site
   delta reports retain the failed acceptance evidence. No count is subtracted or waived.

   The interaction investigation also reproduced an incoming-owner defect in a portable fixture: a
   parent brings back a cached physical scope instance with the same logical widget ID, while pending
   input work still targets the outgoing instance. Routing only before the root build leaves the incoming
   body stale. After root structure settles, interaction changes are resolved against the incoming tree
   while structural queues settle. A later fixture disproved using physical identity or matching node
   flags as evidence that a body read current input: routing can update flags without rebuilding its body.
   Successful body builds now record the current submission epoch, using the owner storage formerly used
   by its validation guard. Incoming native owners that did not build this submission receive pending
   interaction changes, including when a native ancestor replaces its body without a root rebuild.
   Lookup uses raw numeric IDs without temporary `WidgetId` allocation. The regression checks
   both retained and fresh incoming bodies, including exactly one body build, and does not change the
   public component or event APIs. Fresh census acceptance is still outstanding; this diagnosis does not
   waive the first failed comparison. The intermediate routing snapshot preserved zero managed allocations over
   1,024 mounted unchanged submissions per component mode (`TrackedScope`, `BoundText`, and their nesting)
   on HashLink, Wasm32 and Wasm GC, with inlining off/on and verify mode enabled on every frame;
   DATA1 `undo-rerouted-idle-parity-summary.json` records the source and result hashes.

   Incoming interaction routing alone leaves the same four tab increases in a second exact capture
   (`undo-order-rerouted-exact-22-comparison.json`). The actual tab-matrix verify run then exposed a
   distinct candidate defect: `UIKit incremental tree differs from full encode`, followed by
   `layoutSession.verifyIncrementalTree failed with NativeKit UI status -3`; the published control passes
   that run. An incoming cached root was recorded as its own prior, overriding the different physical
   node submitted under the same logical ID. The focused fixture demonstrates a submitted content
   revision of 20 incorrectly resetting to 2. Comparison overrides now require physical membership in
   the previous submitted frame. `BuildContext` borrows the existing comparison index for that phase;
   no new map or per-frame capture is allocated. Standalone owner fixtures explicitly publish their prior
   instances before checking overrides. The focused fixture covers cached and freshly built incoming
   bodies, press, hover entry and hover exit; fresh editor verification and census remain required.

   On base `62f64276d`, the nested incoming fixture still failed with
   `Incoming cached scope missed the pending interaction: flag=2 enter=true nested=true`.
   The scope sweep disposed a detached cached child before its pending ancestor could adopt it.
   Native refresh now defers detached-owner cleanup until structural and incoming-input work settle;
   leaf getters remain after that phase. The expanded incoming fixture passes on all three targets,
   inlining off/on (`undo-62f64276d-settle-focused-after-sweep.log`). Replacing the validation Boolean
   with the successful-build epoch preserves the measured HashLink owner size: 1,024 owners allocate
   1,024 objects / 262,144 bytes before and after on the new toolchain. This microbenchmark is not census
   acceptance; renewed editor gates and the exact action comparison are still required.

   **Renewed correctness evidence on `62f64276d` (unpublished).** The complete component matrix passes
   180 positive configurations, 12 negative event-phase configurations, and 16 explicit zero-allocation
   checks, with unchanged source inputs and matching compiler/runtime hashes. Fresh matched editor modules
   reproduce the published control's `Unknown scene object: rectangle-2` failure and pass all three undo
   cycles on the candidate with a fresh-mount comparison on every frame. Both modules pass the tab matrix
   and CNC/telemetry verification. The telemetry scenario deliberately runs nine steps for three cycles;
   the report audit was corrected to require all nine after initially expecting three. Original failed
   audit evidence remains recorded; the editor process itself succeeded.

   The renewed exact census is incomplete: the control's `cnc-progress` capture failed stack/type byte
   reconciliation. A standalone registered-worker probe demonstrates a HashLink census stop race:
   one 16-byte allocation contributes 17 sampled bytes when capture completes before stop (the known
   initial zero-budget byte), but contributes zero sampled bytes when stop occurs during stack capture.
   The exact original occurrence remains unassigned because the old helper removed its failed temporary
   window. The shared capture helper now preserves failed raw windows and launch logs; its existing
   rejection assertions remain unchanged. No successful diagnostic capture replaces the failed census,
   and no allocation exception or publication is justified by it. DATA1 evidence includes
   `undo-62f64276d-component-model-summary.json`,
   `undo-order-62f64276d-editor-verification-corrected.json`, and `hl-census-stop-race-repro.md`.
   Final mounted-idle parity, allocation acceptance and the remaining gates are still required.

   **Reusable interaction transactions (unpublished undo follow-up).** Correct input routing exposes the old
   interaction store's per-change boxed flags and temporary change records. The store now keeps one typed
   record per observed identity and reuses its pending and borrowed change arrays, preserving the first
   value in a transaction and omitting net-zero changes. The regression fixture fails the old store's
   allocation assertion and passes on HashLink, Wasm32 and Wasm GC with inlining off/on: 1,024 prepared
   workloads allocate zero objects/bytes. This is fixture evidence, not action-census acceptance.
   On compiler base `3d8a96e58`, Tier 1 passes 904/904; the focused store fixture passes all six configurations.
   Other HashLink UI fixtures encounter the control-reproduced IR verification error
   `Unknown IR call "haxeon.reactive.ReactiveRuntime.recordObservableCreation"` in
   `Reflect.reflectCopy.haxeon.editor.TextDocument`; no compiler workaround was added. The remaining focused
   Wasm checks pass twelve configurations and eight explicit zero-allocation checks. Fresh editor modules,
   action captures and the remaining gates are still required before publishing the undo batch. Evidence:
   `interaction-store-regression-control-summary.json`, `interaction-store-3d8a96e58-tier1-summary.json`,
   `interaction-store-3d8a96e58-focused.log`, `interaction-store-3d8a96e58-remaining-wasm-summary.json`, and
   `ui-hl-reflect-copy-3d8a96e58-report.md` under the DATA1 evidence directory.

   **Hidden native-body key lifetime (measured follow-up).** Pruning kept a native owner's identity path but
   discarded stateless descendants of its retained, unmounted body. A minimal regression fails with
   "Pruning dropped a child ID of a retained native body". Key and diagnostic-path pruning now share a
   borrowed flat membership set containing live scope identities and hidden body descendants; disposed
   bodies no longer retain those paths. The prototype passes all three targets with inlining off/on and
   zero allocations over 1,024 prepared prune workloads. Undo, tab and pilot verification also pass.
   On `3d8a96e58`, the paired 15 editor actions save 19 objects / 1,840 bytes on hierarchy→sensors,
   19 / 1,864 on sensors→hierarchy, and 5 / 80 on selection relative to the interaction-store checkpoint;
   the other twelve actions match. Against the published UI control, sensors→hierarchy and
   telemetry→console still each add 42 objects / 3,712 bytes, including a Button body rebuilt to correct
   stale hover. Those increases remain unaccepted. Evidence: `retained-widget-id-parity-summary.json`
   and `retained-widget-id-editor-15-comparison.json` on DATA1. Production Tier 1 passes 904/904;
   the regression and nested-cache lifetime fixtures pass all three targets with inlining off/on.
   The additional WidgetIdCache and flat-state fixtures pass both Wasm targets; their HashLink checks
   reproduce the same reflected-copy compiler failure on the published UI control. This is a local
   checkpoint: the remaining batch gates and complete census are still required before publication.

   The fresh control pilot census again stops on `cnc-progress` with the analyzer's stack/type byte
   reconciliation assertion. This time the original raw window is preserved: type counts total 9,361
   objects / 415,680 bytes; stack samples total 415,665 bytes including the expected extra calibration
   byte. The `bytes` type alone is missing 16 sampled bytes. No subtraction or retry is accepted and
   no complete 22-action comparison is claimed. See `undo-3d8a96e58-census-accounting-failure.json`.

   **Reflected-copy compiler baseline retired (`c6da3300b`).** Fresh compilers on this base pass all 48
   configurations of WidgetIdCache, flat state, routing, focus dispatch, hidden-body IDs, nested scope lifetime,
   patch ordering and incoming interactions: HashLink, Wasm32 and Wasm GC with inlining off/on. The 24 explicit
   Wasm allocation checks also pass. The missing `recordObservableCreation` callee is no longer an accepted
   baseline failure; the earlier `3d8a96e58` reports are historical. DATA1 evidence:
   `c6da3300b-retired-baseline-focused-summary.json` and `compiler-baseline-exceptions-current.json`.
   The separate HashLink census accounting failure remains unresolved; this compiler fix does not waive it.

   **Settings compiler baseline on `c6da3300b`.** The renewed settings project gate fails with
   `HashLink lowering failed for $value-dynamic-equal: Object type "Obj(haxeon.ui.core.PointerLocation)"
   must be registered before use`. A standalone project-source replay reproduces the same lowering
   failure on both the typed-ID candidate and unmodified `c6da3300b` UI, using the same compiler and
   FFI inputs. This is separate from the retired reflected-copy failure. Compiler sources are unchanged;
   settings is recorded as baseline red, not retried to obtain a pass. Evidence:
   `settings-c6da3300b-roots-corrected-lowering-control.json` and
   `compiler-baseline-exceptions-current.json`. The first replay attempt supplied nonexistent source
   roots and failed before lowering; its setup failure remains recorded separately.

   **Typed scope resources (implementation under validation).** Replace the negative-number namespace with
   `ScopeResourceId`, an erased integer abstract accepted by scope-owner APIs. Widget APIs continue to take
   `WidgetId`. Mixed ownership and liveness lists use the separate erased `ResourceId`: its low bit selects
   widget or scope ownership and its remaining 31 bits hold the payload. Decode with an unsigned shift;
   the encoded sign is payload, never a domain test. This preserves the existing ID range without allocating
   wrapper objects, adding a map per component, or retaining an integer overload. Scope and widget maps can
   independently contain the same numeric payload. Resource cleanup selects the domain before accessing
   either map, so disposing one cannot erase the other.
   The regression covers equal payloads, parent retention, independent disposal and counter wrap; negative
   compile fixtures reject raw integers and widget/scope mixing at the public APIs. A cold 1,024-entry
   container comparison on `c6da3300b` measures identical typed/plain costs with inlining off/on: HashLink
   62 objects / 66,192 bytes, Wasm32 18 / 24,528, and Wasm GC 50 objects (engine byte sizes are not exposed).
   This supplements the zero-allocation warmed access probes; it does not replace the component gates or
   the unchanged-action census requirement. The full component matrix passes 198 positive configurations,
   30 expected compile failures and 32 explicit zero-allocation checks, with unchanged source inputs and no
   compiler-baseline skips. On matched `c6da3300b` editor modules, both versions pass three-cycle undo,
   tab-matrix and component-panel scenarios with fresh-mount verification every frame (telemetry steps
   cover indices 0 through 8). This proves behavior, not allocation acceptance. Tier 1 passes
   907 tests with zero failures. The full 22-action census remains pending; the port is unpublished. All 15 editor actions have identical
   object and byte counts against the matched untyped-resource checkpoint on this compiler. This is
   per-family evidence, not acceptance against the previous pushed head; the pilot accounting failure
   and the undo return-tab increases remain unresolved. See
   `scope-id-c6da3300b-editor-15-comparison.json`. See also
   `scope-id-c6da3300b-editor-verification.json` and `scope-id-c6da3300b-paired-build-audit.json`.
   DATA1 evidence: `scope-id-cold-c6da3300b-summary.json`,
   `typed-scope-id-c6da3300b-frozen-inputs.json`, and `typed-scope-id-c6da3300b-component-model-summary.json`.

   **Rejected return-tab constructor optimization.** An isolated Button probe moves the callback wrapper
   from description construction to body construction. It saves 40 objects per twenty descriptions on
   all three targets (HL 960 bytes; Wasm32 640 bytes), with callback/disabled/precedence checks passing
   inlining off/on. However, the current return-tab action traces allocate no Button descriptions:
   their Button allocations are body-build label closures. Constructor savings cannot remove that
   body cost. No production change is made and the queued optimization editor builds were canceled
   before starting. See `button-activation-c6da3300b-probe-summary.json` and
   `button-activation-return-tab-rejection.json`. The fresh matched `c6da3300b` control comparison
   confirms +42 objects / +3,712 bytes for both sensors-to-hierarchy and telemetry-to-console; all
   other thirteen editor actions are unchanged or lower. These increases remain unaccepted. See
   `undo-order-c6da3300b-editor-15-comparison.json`; this is not a complete 22-action census.

   **Retained-tree claim traversal (under validation).** The action trace attributes six capturing
   visitors and six function objects to `BuildContext.claimRetainedTree` in a return-tab window.
   Replace that visitor with direct recursive ID claiming, preserving traversal order and duplicate-ID
   errors without introducing storage or an update path. `RetainedClaimMain` fails before the fix with
   49,152 allocated bytes over 1,024 claims, then passes on HL, Wasm32 and Wasm GC with inlining off/on;
   all measured claims allocate zero. Seventeen IDs are claimed and a duplicate root is rejected.
   Tier 1 passes 907/0 and four affected component fixtures pass all 24 target/inline configurations.
   The fresh editor capture saves 12 objects / 288 bytes on each tab switch and eight / 192 on
   selection, with no other action changing. Return-tab actions remain +30 objects / +3,424 bytes
   against the pushed UI control and remain unaccepted. The final fixture also fails against the
   frozen pre-fix source with the same 49,152-byte error; its source-root override is explicit.
   See `retained-claim-focused-summary.json`, `retained-claim-affected-components-summary.json`,
   `retained-claim-c6da3300b-vs-pushed-editor-15.json` and
   `retained-claim-old-final-fixture-explicit-root.log`.

   **Decorations as inputs — direction approved, implementation deferred until undo publication.** The reviewed inventory
   contains 69 site groups in 46 files: 40 production UI groups, 10 outer groups (including one test),
   18 UI-test groups and one example group. Outer references are pinned to the requested `60d9d4c36`;
   UI references are the formatted local checkpoint plus the typed-ID draft. File/line contributions,
   alias and post-submit reviews, and synthetic regression requirements are in DATA1
   `decorations-reviewed-inventory.md` and `decorations-reviewed-sites-c6da3300b.json`. This is a
   source inventory, not a promise that all mutations are expressible as root style overrides.

   Approved API: one optional immutable `RootInputs` data argument to `View.build(context, ?inputs)`
   and the scope body protocol. It contains ordinary arrays of existing typed `StyleValue` declarations,
   typed event/listener records, geometry/paint callbacks and overlay Views, plus typed node-property
   declarations for semantics, cursor, tab index, command scope, window decoration and hit testing.
   Presence is explicit: a missing declaration inherits the authored value; a declaration may set the
   default value or clear a nullable property. No builder DSL, authored-value comparison, binding
   primitive, wrapper View or layout node is introduced. For example a caller supplies a key listener
   and width declaration when building a Button instead of mutating the returned RenderNode.

   Each body authors its root from these inputs before resolving child style or mounting overlays.
   The existing native owner retains the effective input reference for independent refresh; component
   descriptions do not acquire another nullable field. Forwarding scopes compose outer inputs with
   their authored root inputs before invoking the inner body, with caller declarations taking precedence
   and listener order preserved. Composition happens when inputs change, not on unchanged mounted
   frames. Inputs participate in equal-child decisions. A null input takes a direct path without a new
   record, array or closure. Production callers cease mutating built nodes in the same port batch;
   no apply-after-build adapter is introduced at any point.

   `ScopeRootBoundary` then loses its style copy, child copy, authored-field snapshots, override masks,
   handler counts and transfer operations. Root identity, current-root resolution, focus/capture and
   resource lifetime stay native. Overlay Views build as body-owned children, with dependencies and
   resources tracked by that body; ownership checks must stop treating input overlays as foreign roots.
   Replacement rebuilds from inputs rather than moving old children or handlers.

   Root data alone does not cover the whole inventory. Tooltip placement/lifting becomes authored
   anchor/content slots with a host-owned overlay tree; WindowTitleBar client/drag regions become
   authored child inputs; Text/HighlightedText intrinsic rendering and ellipsis feedback remain leaf
   responsibilities. Row drag paint and option navigation are supplied while creating keyed rows.
   Built-node registration callbacks become identity/geometry observations without mutation authority.
   Inspector events and its paint overlay belong to host inputs/host overlay structure supplied before
   submission. Deliberate verification fault injection remains low-level test code. Tests retain field
   clearing, listener order, focus identity, forwarding refresh and overlay lifetime coverage.

   Cost evidence rules out simply adding a field to every constructor. The isolated twenty-Button
   probe on `c6da3300b`, inline off/on, measures an absent nullable field at +0 objects / +0 bytes per
   mount on HL, but +0 / +8 bytes on Wasm32. A present seven-reference header with null payload arrays
   adds +1 object / +64 bytes on HL and +1 / +48 bytes on Wasm32 relative to the plain description.
   Wasm GC reports +0 absent objects and +1 present object; engine byte sizes are unavailable. These
   are storage measurements with the old boundary still present, not the full payload or net API cost.
   Proposed owner storage replaces the boundary rather than adding per-description storage; its net
   absent cost and present declaration costs must be measured on all targets before implementation
   acceptance. No zero-byte or census claim is inferred from removing snapshots. Evidence:
   `decoration-header-c6da3300b-hl-summary.json`, `decoration-header-c6da3300b-wasm-driver.log`, and
   `decorations-input-storage-c6da3300b-findings.md`.

   Lead decision: finish the undo batch's return-tab object increase and full census, and publish that
   batch before starting this implementation. First land the protocol and native-owner storage alone,
   before porting callers. Inputs replace boundary state on the existing owner, never add a field to
   every component description. Measure absent inputs on HL, Wasm32 and Wasm GC: zero additional
   objects and zero additional bytes per mount are required. Report present-declaration costs per kind;
   the header-only probes above do not satisfy this gate, including unavailable Wasm GC byte evidence.

   Then port family batches in order: controls; overlays/tooltip; window chrome; collections rows;
   inspector/host. Each batch removes its family's post-build mutations in the same commit and ports
   the corresponding outer callers on the local outer branch (10 inventoried outer groups overall).
   Preserve explicit field clearing, listener order, focus identity, forwarding refresh and overlay
   lifetime coverage. The last family deletes the remaining ScopeRootBoundary transfer machinery:
   style/child copies, snapshots, masks and handler counts. All batches meet the census rule:
   steady-state objects and bytes cannot regress; structural objects cannot regress, and structural
   byte increases require measured, recorded attribution. The census decides acceptance, not a mount
   microbenchmark. The non-root-data sites described above remain required scope; stop and report if
   any requires a new primitive. No decorations production API code has started.

   **Independent review corrections (local, before renewed gates).** The body-root batch `0892af06d` had four
   reproduced correctness defects. `ScopeRootStateMain` overflowed recursive `StateStore.retain` for a Checkbox
   with `onChange`; the actual TextField fixture with loaded fonts threw "Native scope resource has a different
   owner type". Native owners now use negative scalar resource IDs, disjoint from positive widget-state IDs, with
   no extra identity allocation. Injected installation failure also reproduced a subscribed owner left in the
   pending list; installation is now inside mount rollback. `SelectionFocusMain` failed with "Selection requested
   focus on a non-focusable label or icon"; Select, ComboBox and SelectionPopup now request the Button root ID.
   `ScopeVariantRootMain` failed with "Returning to A returned B"; variant caches record their nested root owner
   and exclude the enclosing scope currently building the alternative. `ScopeNodeFieldsMain` failed with "Caller
   node fields lost on body replacement"; cursor, tab index, command scope, window-decoration region/cursor,
   hit-test policy, focus trap and self hit testing now have authored baselines and persistent caller override bits.
   Forwarding rebases those baselines. The new node-field baseline increases owner/boundary size and must be
   remeasured; the earlier twenty-mount counts describe the unreviewed snapshot only.

   All four regressions pass focused HashLink checks after correction, including repeated stateful mounts,
   installation cleanup, A/B/A leaves and nested scopes, focus return/navigation, and repeated field transfer with
   a coinciding authored default. The Menu measurement concern did not reproduce: the old default Button style
   contributes row gap/direction/alignment, while width calculation consumes padding and typography only.
   `MenuMeasurementMain` confirms equal horizontal padding, font size and letter spacing on the default theme;
   the measurement code retains its null inline style with this dependency documented. These fixtures join the
   three-target suite. The real TextField fixture additionally requires native fonts. All interrupted gate outputs
   are rejected; full gates and the exact 22-action census restart after these fixes.

   **Native instance lifetimes (gate correction).** The full dock gate and an isolated reproduction found that
   a component's widget identity cannot also identify its lifetime: mounting cached pane B disposed A's Button
   owners even though the pane cache retained A. Native owners now receive distinct scalar instance IDs; stable
   widget identity still addresses focus, capture, layout and key paths. The same native record holds both scalar
   identities, without an allocated identity holder. A flat set retains the widget paths of live instances. Retained
   caches resolve their own completed root scope rather than a forwarding ancestor displaying another alternative.
   A detached child stays subscribed when its parent's existing ownership table still retains it; actual removals
   still unsubscribe. Disposal unregisters the native record immediately, including patch-only frames, and compacts
   reusable managed-ID storage before tombstones cause unnecessary growth. No retained-update path, ownership
   counter, compiler change, budget change or verify exception is introduced.

   The new failures were reproduced before correction: "Cached pane native owner disposed by another variant",
   "A cached native component's lifetime was overwritten by another instance", "Inactive cached nested component
   was disposed", and "Native patch updates retained obsolete component owners". Focused HashLink checks now pass,
   including original dock A/B/A reuse, moved panels and model callback replacement. The reviewed twenty-mount
   Button result remains 2,612 objects / 201,968 bytes against control 2,672 / 198,296. The two compiler-gap items
   account for 40 objects / 3,040 bytes; subtracting them is attribution only and leaves 632 bytes above control.
   The caller-property baseline adds 32 bytes per owner and 40 per boundary temporary relative to the earlier
   compact-owner result. Actual action counts, rather than this mount probe, decide publication.

   Full restyle tests also required two assertion ports: selector classes live on the Button body root, and caller
   decorations follow its native current root under the same widget ID. Listener, style, overlay and fresh-build
   comparisons remain required. Outer gates use `60d9d4c36`; the existing OCCT prefix is an explicit read-only input
   (the source difference is Vcpkg configuration unused by Linux Ninja), and the fresh worktree needs its standard
   root `build/` output directory. The app control reproduces the missing-directory failure and passes after that
   setup correction. The initial failed setup results are rejected. Full gates and all 22 action windows must run
   again on the corrected native ownership implementation.

   Foundation evidence is retained under `/media/joao/DATA1/haxeon-stage5-gates/evidence/`:
   `native-foundation-pilot-comparison.log`, `worker-binding-trace-comparison.json`, the paired
   `current-*-all-census.json` and `current-*-pilot-census.json`, and the six-configuration
   `*-resource-lifetime-parity.log` reproductions.

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

- Authors use tracked state, ordinary Haxe control flow inside scopes, and explicit closures for live text. The remaining
  widgets and panels keep the current model until stage 5 converts them.
- An unchanged cached submission allocates no managed objects; changed actions still allocate, as the stage 3 census
  shows. Scope and binding work is measured rather than assumed free.
- Layout-dependent geometry of independent nodes costs one solve plus local placement. The measured stage 2 result keeps
  the existing native bridge.
- Runtime tracking checks and retention verification remain in force. Debugging may involve both scope invalidation and
  binding scheduling; dependency inspection remains useful.
- Add an adapter only if a real external model appears; deeply nested models need more work. Further language or layout
  mechanisms require separate evidence and decisions.

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
  small scopes. The stage 3 measurements selected a hybrid with leaf text bindings.
- **A per-frame arena allocator.** Most of what a frame allocates outlives it in the retained tree, so an arena would need
  escape proofs to be safe, and GC cost is already low. Escape analysis in the compiler is the safe form, and is independent
  of this record.

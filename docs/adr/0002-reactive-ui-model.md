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

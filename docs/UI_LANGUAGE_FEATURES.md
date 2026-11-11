# Language features for the reactive UI model

Status: updated after the 2026-11-11 stage 3 decision. Lists the Haxeon language and compiler features that
[ADR 0002](adr/0002-reactive-ui-model.md) needs or may benefit from, with the stage each one serves. Several extend designs
already in progress: [STRUCTS.md](STRUCTS.md), [INLINING_AND_VALUE_TYPES.md](INLINING_AND_VALUE_TYPES.md),
[NATIVE_MEMORY.md](NATIVE_MEMORY.md) and the deferred [SCOPED_PLACES.md](SCOPED_PLACES.md). Each feature gets its own
design document before it is implemented. The broader plan for conformances, generic specialization, result builders
and lazy parameters is in [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md).

These features use narrow, typed declarations and work on every backend. Capabilities are declared by conformance; the
compiler implements general mechanisms without UI-specific concepts or general-purpose macros.

## Needed by the design

### 1a. Result builders (conditional, not needed by stage 3)

A library declares a builder type whose fixed, typed methods combine sequential statements, `if` with or without
`else`, `switch` and `for`. A `@:builder(ViewBuilder)` annotation on an interface method is inherited by implementations;
helper functions opt in explicitly. The library's `forEach<T:Identifiable>` signature supplies keys, so unkeyed lists are
ordinary bound errors. Each control-flow form has one fixed lowering signature, with no overload resolution across builder
methods; diagnostics point to the user's control flow and type checking stays fast. The compiler knows builders, not UI.
A separate result-builder design is required before implementation.

### 1b. Lazy parameters (conditional, not needed by stage 3)

A parameter such as `text:Lazy<String>` receives the caller's expression unevaluated. The UI library turns it into a
binding, keeping props live across component boundaries; logging, assertions and defaults can use the same general
feature. A separate lazy-parameter design is required before implementation. `Observable` supplies tracked reads, and
reads outside tracking scopes remain runtime debug checks.

Stage 3 selected ordinary Haxe re-running scopes for structure and explicit library bindings for live text. The measured
hybrid closes the gap to run-once bindings, so neither result builders nor lazy parameters is a stage 5 prerequisite.
Their descriptions above are proposals, not commitments; revisit them only if later measurements justify separate designs.

Features 2 and 3 served the shared node store prototype, which ADR 0002 rejected at stage 2. Feature 3 is `STRUCTS.md`'s
existing plan and remains useful on its own; feature 2 is conditional on a new measured need. Feature 4 pays off under
any model.

### 2. Per-field change channels (stage 2, if the store goes ahead)

A field names the dirty channel it belongs to. This should not be a new compiler feature: `STRUCTS.md` already plans typed
annotations (`@:annotation` types, checked at compile time and recorded in the type's descriptor), so `Channel` is a UI
library annotation, and the mask per channel folds from `typeInfo<T>()`:

```haxe
@:annotation enum abstract Channel(Int) { var layout; var paint; var text; var semantics; var transform; }

struct NodeRecord {
	@Channel(layout) var width:LayoutAxis;
	@Channel(paint) var background:Color;
}
```

What remains for the compiler is generating, from the same descriptor, setters that write a field and set its channel
bit; `Diffable` supplies the shared field numbering and change masks (`bitEquals` on flat records is also available).

### 3. Flat structs in GC and native memory (stage 2): the `STRUCTS.md` design

`STRUCTS.md`'s `Flat` and `Portable` design, written for Beartooth's world components, is what a node store needs:

- **One layout everywhere.** A `Flat` struct (scalars, integer `enum abstract`s, nested flat structs, fixed arrays) uses
  its C layout inline in a GC object or array, in a local, and in native memory. Moving it between managed and native
  storage is a copy of `sizeof<T>()` bytes; native layout and rendering read it with no encode or decode.
  `NodeRecord`'s layout and paint fields (floats, enums, `Color`, `Insets`, `LayoutAxis`, `Transform2D`) are flat.
- **Flat and managed parts split by the compiler, not by hand.** Strings, text, callbacks and object references are not
  flat. Beartooth's world reads inferred flatness from the descriptor to choose native or managed columns; the node store
  does the same, which is the principled form of the side tables ADR 0002 lists as a cost of decision 4.
- **`NativeSpan<T>` and `p.ref` places.** `span.at(i).ref.width = …` writes one field in place at a constant offset, with
  no copy of the record. That is the in-place edit the store needs, and replaces the deferred `ref` parameters of
  `SCOPED_PLACES.md` for this purpose.
- **`bitEquals`** compares flat records byte for byte, which is the right test for change detection.
- **`Portable`** (flat and pointer-free, identical layout on HashLink, wasm32 and native) lets the same records cross to
  Wasm unchanged.

The UI does not need a separate feature for this; it needs `STRUCTS.md` stages 2 and 3 (flatness and C layout inline in
GC objects; native memory operations) and stage 5 for descriptors and annotations. Its stages 3a (scoped places) stays
deferred.

### 4. Structs for small values, and nullable struct fields — implemented

`Color`, `Insets`, `LayoutAxis`, `Rect` and `Transform2D` are immutable `Hashable` structs, with conformance-based equality
and inline storage in `LayoutStyle`. Optional fields use `Null<S>` with an inline presence flag. The compiler rejects
writes through temporary values, scalar-replaces eligible values and their callers, and flattens struct fields and locals
on Wasm GC. Dynamic and otherwise escaping values still box; the measured UI scenarios allocate none of the five
value types after setup. See
[STRUCTS.md](STRUCTS.md) for the compiler rules and
measurements and [UI value types](../packages/ui/docs/VALUE_TYPES.md) for the UI boundary and retention changes.

### 5. Purity contracts (deferred)

Every panel that was hard to retain (inspection camera, BIM, machine control, mission, CNC) was hard because its build
changed state, and verify mode found that indirectly. The first answer is not a language feature: ADR 0002 makes the state
the UI depends on signals and throws at a tracked write when another computation could observe it, at the line that
writes (decision 9, stage 1), as Svelte 5 and Compose do. A compile-time `@:pure` contract ([PURITY.md](PURITY.md)) is deferred until those
runtime checks show real holes, such as writes through non-Observable external objects during builds.

Purity *inference* without annotations is a separate, smaller idea for the optimizer (dead call removal, common
subexpressions, loop-invariant hoisting); it needs no user-facing contract.

### 5a. Observable model fields (ADR 0002 stages 1 and 1b)

Implemented. Class-only `Observable` conformance instruments plain field reads and writes for field-level dependency
tracking, with one dependency list per object and no per-field signal allocation. Writes that are equal by declared
`Equatable` conformance (or identity for nonconforming classes) do not invalidate readers. Field bits share the
`Diffable` numbering. HashLink, Wasm32 and Wasm GC tests cover fresh-object initialization, per-field invalidation and
the write guard; UI verify mode covers retained reads. Owned revision-adapter models were migrated and their counters
removed. Add an adapter only if a real external model appears.

Use `@:unobservable` on stored implementation fields that do not represent model state. A public getter that exposes a
derived value must read the observable fields that define that value. `TextDocument` publishes `revision` and delegates
text storage to an unobservable `TextDocumentBuffer`; the editor's private state uses that buffer directly. This keeps
private synchronization inside a tracked widget build separate from edits to a shared observable document.

## General allocation work

### 6. Escape analysis and scalar replacement

Already the next stage of `INLINING_AND_VALUE_TYPES.md`. Temporaries that never leave a function become locals. This is
the safe form of a per-frame arena (see `packages/ui/docs/ARCHITECTURE_NOTES.md`) and helps all code on both backends.

### 7. Non-allocating closures

A closure that captures nothing is created once; a closure that captures only `this` reuses a per-instance binding when
taken repeatedly. Bindings and handlers attached at mount make this less pressing, but it removes common hidden allocation.

## Smaller field-diff extensions

8. **Field exclusion and custom comparison** for `Diffable`, so `Semantics.same` can be generated. Add when a second
   class needs it.
9. **More than 32 fields**: 64-bit or multi-word masks, needed once a node record carries every channel.
10. **Compile-time hashed IDs**: `context.id("click-sequence")` builds strings at runtime; a constant-hash intrinsic makes
    keys free.

## Order

Start with what pays off whatever the experiments decide, then let the ADR's go/no-go results unlock the rest.

1. Escape analysis and construct-in-place (6): already planned, and a precondition for structs in hot code.
2. Structs for small values (4), after `STRUCTS.md` stages 1a and 1b: copies and optionals, then the Wasm GC
   representation. `Rect` and `Insets` can be measured on HashLink before 1b lands, but not merged as a default for Wasm.
3. `Observable` model fields (5a): after ADR 0002 stage 1, independent of the stage 3 experiment.
4. Result builders and lazy parameters (1a–1b): defer; write separate designs only if later evidence shows the selected
   scoped-structure and text-binding model needs them.
5. `STRUCTS.md` stages 2, 3 and 5 (3): continue on their own merits, including Beartooth's needs; stage 2 rejected the
   UI node store.
6. Change-channel setters (2): defer unless a new measured need appears.
7. The field-diff extensions (8–10) and closures (7): when a need appears.
8. Purity contracts (5): only if the runtime read-only checks of ADR 0002 stage 1 leave real holes.

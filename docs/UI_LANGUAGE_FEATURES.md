# Language features for the reactive UI model

Status: proposal (2026-10-31). Lists the Haxeon language and compiler features that
[ADR 0002](adr/0002-reactive-ui-model.md) needs or benefits from, with the stage each one serves. Several extend designs
already in progress: [STRUCTS.md](STRUCTS.md), [INLINING_AND_VALUE_TYPES.md](INLINING_AND_VALUE_TYPES.md),
[NATIVE_MEMORY.md](NATIVE_MEMORY.md) and the deferred [SCOPED_PLACES.md](SCOPED_PLACES.md). Each feature gets its own
design document before it is implemented.

The rule for all of them is the one `@:structural`, `haxeon.Equality` and the profiler pass follow: narrow intrinsics or
attributes generated from declarations, typed in place and working on every backend. No general-purpose macros.

## Needed by the design

### 1. Reactive component bodies (stages 4–5, if the stage 3 experiment chooses run-once)

A `@:component` function that the compiler understands:

- a signal read in a property position becomes a binding:
  `label.text = count.get() + " items"` compiles to a binding that rewrites `text` when `count` changes;
- a signal read outside any tracking scope is an error in debug builds, which catches the characteristic run-once bug;
- later, `if` and `for` over signals compile to `Show` and `For`, so component bodies read like ordinary code.

Order: diagnostics, then binding inference, then control flow. This is what makes run-once components practical to
write; do it once the stage 3 experiment confirms the component model.

Features 2 and 3 serve the shared node store, which ADR 0002 keeps as an option until its stage 2 prototype. Feature 3 is
`STRUCTS.md`'s existing plan and useful on its own; feature 2 is worth building only if the store goes ahead. Feature 4
pays off under any model.

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
bit; `Structural.changedMask` (or `bitEquals` on flat records, below) covers comparisons.

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

### 4. Structs for small values, and nullable struct fields

Independent of the store: `Color`, `Insets`, `LayoutAxis`, `Rect` and `Transform2D` are `@:structural` classes, one GC object
each. As structs they sit inline in `LayoutStyle` (one object instead of about five) and geometry temporaries cost nothing.
No UI or editor code mutates their fields in place and no style field is set to `null`, so copy semantics are safe. Needed:

- `@:structural` and `haxeon.Equality` accepting `struct`, and an audit of `==`, which becomes fieldwise (`STRUCTS.md`
  migration note);
- scalar replacement and construct-in-place (inlining stages 2 and 3), which `STRUCTS.md` makes a precondition for hot
  code;
- **nullable struct fields**: about eight UI fields use `null` for "not set" (`Text.color`, `Icon.color`,
  `Popup.backdropColor`, `TextField.whitespaceColor`, `Canvas.clip`, some caches), and `Null<S>` fields are rejected today.
  Either a presence-flag representation of `Null<S>` fields generated by the compiler, or an option struct in the library.

### 5. Purity contracts (stage 1 onward)

A `@:pure` contract for derived computations and component setup: no writes to signals, and no writes to fields reachable
from outside the function. Every panel that was hard to retain (inspection camera, BIM, machine control, mission, CNC) was
hard because its build changed state; verify mode found that indirectly, this finds it at compile time. Useful under the
current model too, so it can start first.

## General allocation work

### 6. Escape analysis and scalar replacement

Already the next stage of `INLINING_AND_VALUE_TYPES.md`. Temporaries that never leave a function become locals. This is
the safe form of a per-frame arena (see `packages/ui/docs/ARCHITECTURE_NOTES.md`) and helps all code on both backends.

### 7. Non-allocating closures

A closure that captures nothing is created once; a closure that captures only `this` reuses a per-instance binding when
taken repeatedly. Bindings and handlers attached at mount make this less pressing, but it removes common hidden allocation.

## Smaller `@:structural` extensions

8. **Field exclusion and custom comparison** (`@:structural.skip`, a per-field comparator), so `Semantics.same` can be
   generated. Add when a second class needs it.
9. **More than 32 fields**: 64-bit or multi-word masks, needed once a node record carries every channel.
10. **Compile-time hashed IDs**: `context.id("click-sequence")` builds strings at runtime; a constant-hash intrinsic makes
    keys free.

## Order

Start with what pays off whatever the experiments decide, then let the ADR's go/no-go results unlock the rest.

1. Purity contracts (5): help the current model and every later stage.
2. Escape analysis and construct-in-place (6): already planned, and a precondition for structs in hot code.
3. Structs for small values and nullable struct fields (4): measurable now, under any model.
4. `STRUCTS.md` stages 2, 3 and 5 (3): shared with Beartooth, and needed by the stage 2 store prototype.
5. Change-channel setters (2): only if the store prototype passes.
6. Reactive component bodies (1): only if the stage 3 experiment chooses run-once.
7. The `@:structural` extensions (8–10) and closures (7): when a need appears.

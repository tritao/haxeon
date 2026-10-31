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

Features 2–4 serve the shared node store, which ADR 0002 keeps as an option until its stage 2 prototype. Feature 3 and 4
are useful to the language on their own; feature 2 is worth building only if the store goes ahead.

### 2. Per-field change channels (stage 2, if the store goes ahead)

Extend `@:structural` so a field names the dirty channel it belongs to:

```haxe
@:structural class NodeRecord {
	@:channel(layout) public var width:LayoutAxis;
	@:channel(paint) public var background:Color;
}
```

The compiler generates setters that write the field and set its channel bit, and `Structural.channelMask(T, "layout")`.
The node store's change tracking then comes from one declaration, as style comparison does today.

### 3. Flat arrays of structs, in GC or native memory (stage 2)

`STRUCTS.md` measured that a struct stored in an `Array` still allocates. The node store needs `Array<S>` and
`NativeArray<S>` laid out inline, with `array[i].field` compiling to a load or store at an offset and no temporary. With
`@:repr("C")` the same storage is readable by native layout and rendering, which is ADR decision 4 (no encode or decode).

### 4. `ref` places (stage 2)

`SCOPED_PLACES.md` proposed `ref` parameters for mutable struct places and was deferred for want of a consumer. Editing a
node record through its handle, without copying it out and back, is that consumer:

```haxe
store.edit(handle, (ref record) -> record.width = LayoutAxis.fixed(120));
```

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
2. Escape analysis (6): already planned and independent.
3. Flat struct arrays and `ref` places (3, 4): useful on their own, and needed by the stage 2 store prototype.
4. Change channels (2): only if the store prototype passes.
5. Reactive component bodies (1): only if the stage 3 experiment chooses run-once.
6. The `@:structural` extensions (8–10) and closures (7): when a need appears.

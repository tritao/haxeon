# Language roadmap

Status: plan (2026-11-01). Collects the language and compiler features Haxeon has decided on or is considering, beyond
what the UI needs ([UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md)). Each feature gets its own design document, or a
section in an existing one, before it is implemented.

The rules for every entry:

- **Capabilities are declared through types.** A type opts into a capability by conformance (`implements Hashable`,
  `implements Observable`), not by metadata or by the compiler recognizing a library type. The compiler knows general
  mechanisms, never UI or other library concepts.
- **Narrow, typed, declarative.** Features are typed in place and work on every backend (HashLink, Wasm32, Wasm GC). No
  general-purpose macros and no aspect-style weaving.
- **No compatibility layers.** A feature that replaces an existing form ports every use in the same change and deletes
  the old form. Haxeon, its packages and their applications are maintained together.

## Decided

| Feature | Summary | Recorded in |
|---|---|---|
| Interfaces as the abstraction | No separate trait feature. Interface bounds dispatch statically and specialize for struct type arguments; a struct boxes only when converted to an interface-typed value. | [STRUCTS.md](STRUCTS.md) |
| Generic specialization for structs | Generic code over struct type arguments uses the concrete representation, the general fix for `Array<S>`, `Map<K, S>` and `T`-typed closures boxing structs. Extends [GENERIC_SPECIALIZATION.md](GENERIC_SPECIALIZATION.md). | [STRUCTS.md](STRUCTS.md) |
| `Equatable`, `Hashable` | Declared value equality, synthesized when every field supports it; `==` on a struct that does not conform is a compile error. Replaces `@:structural`. | [STRUCTS.md](STRUCTS.md) |
| `Diffable` | Explicit conformance for field masks (`Diff.mask/apply/bit/all`); writes only to writable fields. | [STRUCTS.md](STRUCTS.md) |
| Signals core | `Signal<T>`, `Derived<T>` and `Effect`, with push invalidation, pull recomputation and per-frame batching. | [ADR 0002](adr/0002-reactive-ui-model.md) |
| `Observable` | Classes whose fields are tracked individually by the compiler; replaces per-field signals and revision counters. | [ADR 0002](adr/0002-reactive-ui-model.md) |
| Result builders | A library-declared builder lowers `if`, `switch` and `for` in a body; attached to an interface method and inherited by implementers. | [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md) |
| Lazy parameters | `Lazy<T>` parameters receive the caller's expression unevaluated. | [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md) |

## Considered

Drawn mostly from Swift, filtered for Haxeon's goals: value types without allocation, typed native interop, and explicit
capabilities.

### Key paths

`\Node.width` is a typed, first-class reference to a field: passable, composable and comparable. A key path into a struct
compiles to a constant offset and allocates nothing.

It could give `Diff.bit` and `@Channel` annotations a typed field reference instead of a name, and let bindings name
their target (`bind(\Label.text, value)`).
The proposed typing, place semantics and relationship to `Diffable` field numbering are in
[KEY_PATHS.md](KEY_PATHS.md). Implementation remains future work.

### Inline enums with payloads

Enums with payloads (`Paint.Solid(color)`) allocate one object per value today. A value enum stores its tag and largest
payload inline, as `Null<S>` stores its presence flag; `Null<S>` is the one-case version. It reuses struct flattening and
scalar flow, and belongs with flat structs ([STRUCTS.md](STRUCTS.md) stages 2–3). Candidates: `Paint`, sizing modes,
effects. Enums have no identity, including when boxed; payload enums require declared `Equatable` or `Hashable` for
`==`/`!=`, while nullary enums have tag equality. The full rule, including `Type.enumEq`, is in
[STRUCTS.md](STRUCTS.md#enum-value-semantics-and-inline-layout). Declared equality is implemented for boxed enums;
inline enum storage remains to be implemented.

### Resource cleanup

Deterministic release is layered by need rather than solved with one mechanism:

1. **Scoped cleanup.** `defer` runs a statement at scope exit, and a scoped binding over a `Disposable` conformance
   (`scoped var file = File.open(path);`, spelled differently from Haxe's `using` for static extensions) disposes the
   value when the scope ends, including on exceptions. This covers locks, files, profiler scopes and temporary native
   buffers, which is most resource code, as C# `using`, Java try-with-resources and Python `with` do.
2. **Owner scopes.** UI-held resources (GPU textures and buffers, subscriptions) register cleanup with their reactive
   scope and are released on unmount ([ADR 0002](adr/0002-reactive-ui-model.md) decision 2). No language feature.
3. **Move-only types,** below, only where a mistake corrupts memory rather than leaks: native memory and GPU handles
   passed between owners.

Finalizers are not used for resources: their timing is nondeterministic.

### Move-only types and parameter ownership

Deferred until layers 1 and 2 above leave real bugs in practice.

Structs that cannot be copied, only moved, with cleanup that runs when their owner ends (Swift `~Copyable` with
`borrowing`/`consuming` parameters; Rust ownership). They suit native resources (GPU buffers and textures, native-memory
spans, file handles), which today are GC classes with manual release, where a double free or a missed release is found
only at run time. They also give `NativeSpan<T>` and `RawPtr` explicit lifetimes. Belongs with
[NATIVE_MEMORY.md](NATIVE_MEMORY.md) and `STRUCTS.md` stage 3.

### `inout` parameters

Passing a struct place to a function that edits it in place, with `&` written at the call site and exclusive access
checked. [SCOPED_PLACES.md](SCOPED_PLACES.md) defers `ref` parameters for lack of a consumer; record-editing helpers in a
flat node store (ADR 0002 decision 4) would be one. Decide with that prototype.

### Typed storage for the standard collections

The specialized generic `Map` and inline struct arrays store values in their concrete representation, but the standard
reference maps (`IntMap`, `StringMap`, `ObjectMap`) still keep native values in `Dynamic` boxes, and arrays of nullable
elements go through the dynamic array ABI. Each needs a checked conversion where the boxed view meets typed code (for
example when iterating the values of a nested map, or after `copy`/`slice` of a nullable-element array). Give these
collections the same specialized, typed storage so the values are never boxed, then delete those boundary conversions in
the same change. Belongs with the flat structs and generic specialization work.

The same change covers scalars. Generic code specializes for scalar type arguments (`Int`, `Float`, `Bool`, `Int64`)
as it does for structs and raw pointers, so `Array<Int64>` or `Signal<Int64>` does not box each value. `Null<T>` of a
scalar uses the inline presence-flag layout of `Null<S>` rather than a boxed primitive. `Int64` arithmetic lowers to
native 64-bit instructions on HashLink rather than runtime calls.

### Optional flat values in native layout

`Null<S>` is not Flat today, so an optional value cannot appear in an FFI record, `RawPtr`/`NativeSpan` memory or a
native node-store record; code must spell an explicit presence field and convert at the boundary. Decided: when `S` is
Flat, `Null<S>` is Flat, with a defined C layout `{ uint8_t present; padding to S's alignment; S value; }` whose payload
is zeroed when absent, so records compare byte for byte. It is Portable when `S` is. Generated C headers emit one named
optional type per use (for example `hx_optional_rect`). Wasm GC keeps its flattened managed form; the C layout applies
wherever bytes are exposed. Implement with native memory and the node-store prototype (ADR 0002 stage 2), with
cross-target layout tests, and record it in STRUCTS.md "Flat and Portable".

### Smaller conveniences

Check each against what Haxeon already supports before designing it.

- **`if let` / `guard let`:** unwrap an optional, including `Null<S>`, and narrow in one step.
- **Default interface methods:** static extensions cover most uses; add on demand.
- **Serialization by conformance:** express STRUCTS.md's descriptors and the [MessagePack](MESSAGEPACK.md) attributes as
  a conformance (`implements Codable`), consistent with `Hashable`, `Diffable` and `Observable`.

### Not planned

- **Property wrappers** (`@State`, `@Published`): `Observable` covers them, and they are macro-like.
- **General macros:** contrary to the rules above.
- **Opaque result types** (`some View`) and builders that produce nested static types: they serve SwiftUI's static
  diffing; Haxeon's views are runtime trees.
- **Aspect-oriented weaving:** behaviour applied from elsewhere by pattern matching is non-local, fragile under renames
  and hard to optimize. Cross-cutting concerns use declared mechanisms (`Observable`, `Diffable`, the profiler pass,
  verify mode).
- **Actors and structured concurrency:** revisit if simulation work becomes multithreaded.
- **Reference counting** (Swift ARC) instead of the tracing GC: cycles leak without manual `weak` links, every pointer
  copy costs a retain/release unless a large ownership optimizer removes it, and Wasm GC uses the host's tracing
  collector. Deterministic cleanup comes from the resource layers above; GC cost is addressed by allocation-free values
  and, if pauses ever matter, generational or incremental collection in HashLink.

## Order

1. `Equatable`, `Hashable` and `Diffable`, replacing the former structural metadata; key paths designed alongside.
2. Signals core (ADR 0002 stage 1).
3. `Observable` (ADR 0002 stage 1b).
4. Result builders and lazy parameters, only if the ADR 0002 stage 3 component experiment needs them. The experiment
   runs first with plain Haxe expressions (re-running scopes) against explicit library primitives (run-once
   bindings); plain code is preferred when it is within 10% on allocation and frame time, because it keeps code
   meaning what it looks like.
5. Flat structs, arrays of structs and generic specialization for structs, with inline enums. Struct arrays and
   struct-specialized generic storage are implemented across HashLink, Wasm32 and Wasm GC; payload enums use declared
   value equality and remain boxed, and inline enum lowering remains to be implemented. See [STRUCTS.md](STRUCTS.md) and
   [GENERIC_SPECIALIZATION.md](GENERIC_SPECIALIZATION.md) for the layouts and measurements.
6. Typed storage for the standard reference maps and nullable-element arrays, deleting their boxed boundary
   conversions; generic specialization and inline `Null<T>` for scalars, and native `Int64` operations.
7. Scoped cleanup (`defer`, `Disposable` scoped bindings).
8. `inout` with the node store prototype; move-only types for native memory only if scoped cleanup and owner scopes
   leave real bugs.
9. Smaller conveniences when a concrete use appears.

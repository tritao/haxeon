# Language roadmap

Status: plan (2026-11-01). Collects the language and compiler features Haxeon has decided on or is considering, beyond
what the UI needs ([UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md)). Each feature gets its own design document, or a
section in an existing one, before it is implemented.

The rules for every entry:

- **Capabilities are declared through types.** A type opts into a capability by conformance (`: Hashable`,
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
| `Observable` | Classes whose fields are tracked individually by the compiler; replaces per-field signals and revision counters. | [ADR 0002](adr/0002-reactive-ui-model.md) |
| Result builders | A library-declared builder lowers `if`, `switch` and `for` in a body; attached to an interface method and inherited by implementers. | [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md) |
| Lazy parameters | `Lazy<T>` parameters receive the caller's expression unevaluated. | [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md) |

## Considered

Drawn mostly from Swift, filtered for Haxeon's goals: value types without allocation, typed native interop, and explicit
capabilities.

### Key paths

`\Node.width` is a typed, first-class reference to a field: passable, composable and comparable. A key path into a struct
compiles to a constant offset and allocates nothing.

It would replace the closure pairs in `StyleProperty<T>` (`readLayout`/`writeLayout`), give `Diff.bit` and `@Channel`
annotations a typed field reference instead of a name, and let bindings name their target (`bind(\Label.text, value)`).
Design it with `Equatable`/`Diffable`, since all three share the per-type field numbering.

### Inline enums with payloads

Enums with payloads (`Paint.Solid(color)`) allocate one object per value today. A value enum stores its tag and largest
payload inline, as `Null<S>` stores its presence flag; `Null<S>` is the one-case version. It reuses struct flattening and
scalar flow, and belongs with flat structs ([STRUCTS.md](STRUCTS.md) stages 2–3). Candidates: `Paint`, sizing modes,
effects.

### Move-only types and parameter ownership

Structs that cannot be copied, only moved, with cleanup that runs when their owner ends (Swift `~Copyable` with
`borrowing`/`consuming` parameters; Rust ownership). They suit native resources (GPU buffers and textures, native-memory
spans, file handles), which today are GC classes with manual release, where a double free or a missed release is found
only at run time. They also give `NativeSpan<T>` and `RawPtr` explicit lifetimes. Belongs with
[NATIVE_MEMORY.md](NATIVE_MEMORY.md) and `STRUCTS.md` stage 3.

### `inout` parameters

Passing a struct place to a function that edits it in place, with `&` written at the call site and exclusive access
checked. [SCOPED_PLACES.md](SCOPED_PLACES.md) defers `ref` parameters for lack of a consumer; record-editing helpers in a
flat node store (ADR 0002 decision 4) would be one. Decide with that prototype.

### Smaller conveniences

Check each against what Haxeon already supports before designing it.

- **`if let` / `guard let`:** unwrap an optional, including `Null<S>`, and narrow in one step.
- **`defer`:** run cleanup at scope exit; pairs with move-only resources and profiler scopes.
- **Default interface methods:** static extensions cover most uses; add on demand.
- **Serialization by conformance:** express STRUCTS.md's descriptors and the [MessagePack](MESSAGEPACK.md) attributes as
  a conformance (`: Codable`), consistent with `Hashable`, `Diffable` and `Observable`.

### Not planned

- **Property wrappers** (`@State`, `@Published`): `Observable` covers them, and they are macro-like.
- **General macros:** contrary to the rules above.
- **Opaque result types** (`some View`) and builders that produce nested static types: they serve SwiftUI's static
  diffing; Haxeon's views are runtime trees.
- **Aspect-oriented weaving:** behaviour applied from elsewhere by pattern matching is non-local, fragile under renames
  and hard to optimize. Cross-cutting concerns use declared mechanisms (`Observable`, `Diffable`, the profiler pass,
  verify mode).
- **Actors and structured concurrency:** revisit if simulation work becomes multithreaded.
- **Reference counting and `deinit` on classes:** deterministic cleanup belongs on move-only structs.

## Order

1. `Equatable`, `Hashable` and `Diffable`, porting every `@:structural` use; key paths designed alongside.
2. `Observable` (ADR 0002 stage 1b).
3. Flat structs, arrays of structs and generic specialization for structs, with inline enums.
4. Result builders and lazy parameters, before ADR 0002 stages 3–5.
5. Move-only types and `inout`, with native memory and the node store prototype.
6. Smaller conveniences when a concrete use appears.

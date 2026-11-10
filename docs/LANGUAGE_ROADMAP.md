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
| `Equatable`, `Hashable` | Value-only declared equality, synthesized when every field supports it; nonconforming struct comparisons are errors. Class/interface `==` is always identity; classes cannot declare either capability. Replaces `@:structural`. | [STRUCTS.md](STRUCTS.md) |
| `RawRepresentable` | Closed Int/String enum abstracts synthesize inline raw-value access and checked conversion from declared constants; implicit conversions are rejected. Implemented. | [STRUCTS.md](STRUCTS.md#closed-raw-value-enums) |
| `Flags` | Closed integer flags synthesize checked bit sets, immutable operations and readable formatting with no implicit conversions. Implemented. | [STRUCTS.md](STRUCTS.md#closed-flags) |
| `Diffable` | Explicit conformance for field masks (`Diff.mask/apply/bit/all`); writes only to writable fields. | [STRUCTS.md](STRUCTS.md) |
| Key paths | Typed field references, readable/writable capabilities, composition and `Diff.bit` paths. Escaped nullable-struct values await scalar callable ABI support. | [KEY_PATHS.md](KEY_PATHS.md) |
| Signals core | `Signal<T>`, `Derived<T>` and `Effect`, with push invalidation, pull recomputation and per-frame batching. | [ADR 0002](adr/0002-reactive-ui-model.md) |
| `Observable` | Classes whose fields are tracked individually by the compiler; replaces per-field signals and revision counters. | [ADR 0002](adr/0002-reactive-ui-model.md) |
| Result builders | A library-declared builder lowers `if`, `switch` and `for` in a body; attached to an interface method and inherited by implementers. | [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md) |
| Lazy parameters | `Lazy<T>` parameters receive the caller's expression unevaluated. | [UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md) |

### RawRepresentable (implemented)

Closed `enum abstract X(Int|String) implements RawRepresentable` synthesizes inline
`rawValue()` and checked static `fromRaw(value):Null<X>` from declared constants.
Unknown values return null; implicit `from`/`to` conversions are compile errors.
The nominal type survives checking while storage keeps the underlying
representation. Generic constrained calls specialize against the concrete type.
See [STRUCTS.md](STRUCTS.md#closed-raw-value-enums).

### Key paths (implemented)

`\Node.width` and chained paths resolve stored fields at the expression site.
`WritableKeyPath<R,V>` grants checked writes through root places; `KeyPath<R,V>`
is readable. Composition, declaration-based equality/hash, display, Observable
tracking and `Diff.bit(\Type.field)` are implemented. The field-name `Diff.bit`
form is removed. Known paths and generic constant path arguments lower to field
operations independently of inlining. Escaped scalar-valued paths pass zero-object
censuses on HashLink, Wasm32 and Wasm GC, including composed nested-struct roots.

Escaped `Null<Struct>` values still box across typed callable boundaries. This
general closure/generic-call ABI gap is assigned to queue item **a2: inline
`Null<T>` through the callable ABI**.
The recorded failing allocation expectation stays in KEY_PATHS.md until a2
passes it.
Nested tracked-struct writes remain explicit `E1027` errors. Bindings, optional
traversal, reflection by name and general `inout` are excluded.
See [KEY_PATHS.md](KEY_PATHS.md) for the specification and measured blocker.

## Considered

Drawn mostly from Swift, filtered for Haxeon's goals: value types without allocation, typed native interop, and explicit
capabilities.

### Generated UI-to-native enum mappings (NativeMapped by case name)

Consider generating exhaustive mappings between plain UI enums and closed native
binding enums from case names, with an explicit renaming table where necessary.
Revisit once roughly 15–20 hand-written mappings justify it; native integer
ownership stays in the generated binding, and UI tags remain independent.

### Inline enums with payloads

Enums with payloads can allocate one object per value. An inline enum stores its tag and largest
payload inline, as `Null<S>` stores its presence flag; `Null<S>` is the one-case version. It reuses struct flattening and
scalar flow, and belongs with flat structs ([STRUCTS.md](STRUCTS.md) stages 2–3). UI conversions cover sizing modes
and effects; `Paint` remains a native resource with identity and lifetime. Enums have no identity, including when boxed; payload enums require declared `Equatable` or `Hashable` for
`==`/`!=`, while nullary enums have tag equality. The full rule, including `Type.enumEq`, is in
[STRUCTS.md](STRUCTS.md#enum-value-semantics-and-inline-layout). Declared equality is implemented. Source inline storage starts with the closed non-generic subset documented there;
the remaining escape, native-layout and generic transport blockers are listed explicitly. Spare-bit (niche) encoding
may later store a presence flag or tag within a payload, shrinking forms such as `Null<Bool>` and small enums in structs;
consider it with a2's inline `Null<T>`.

### Resource cleanup

Deterministic release is layered by need rather than solved with one mechanism:

1. **Scoped cleanup (implemented).** `defer` runs a statement at block exit, and `scoped var` disposes a value whose
   type implements `Disposable`. Cleanup runs on normal and exceptional exits in reverse registration order, with the
   first exception preserved; nullable values are skipped. The compiler rejects direct escapes and reassignment. The
   syntax, typing and target lowering are in [SCOPED_CLEANUP.md](SCOPED_CLEANUP.md).
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

### Borrowed native views of struct arrays

An `Array<S>` of Flat structs already stores its elements in C layout. A scoped borrow (`scoped var span =
rects.borrowSpan();`) lends that storage to native code as a `NativeSpan<S>` for the scope: without a copy on HashLink
and Wasm32, and through one copy into linear memory (and back, for a writable borrow) on Wasm GC, whose arrays native
code cannot address. Operations that can reallocate or reorder the array are rejected while it is borrowed. Only Flat
element types qualify. Data that native code or the GPU reads every frame, or large data, is allocated in native memory
from the start instead; that is the default for frame data. The borrow is implemented with the node-store prototype
(ADR 0002 stage 2) only when a concrete caller needs it.

### Optional flat values in native layout

`Null<S>` is not Flat today, so an optional value cannot appear in an FFI record, `RawPtr`/`NativeSpan` memory or a
native node-store record; code must spell an explicit presence field and convert at the boundary. Decided: when `S` is
Flat, `Null<S>` is Flat, with a defined C layout `{ uint8_t present; padding to S's alignment; S value; }` whose payload
is zeroed when absent, so records compare byte for byte. It is Portable when `S` is. Generated C headers emit one named
optional type per use (for example `hx_optional_rect`). Wasm GC keeps its flattened managed form; the C layout applies
wherever bytes are exposed. Implement with native memory and the node-store prototype (ADR 0002 stage 2), with
cross-target layout tests, and record it in STRUCTS.md "Flat and Portable".

### Errors as values: `Result<T, E>` and `?`

`Result<T, E>` is an ordinary payload enum (`Ok(value)`, `Err(error)`), stored inline like other eligible enums, so
returning one allocates nothing. A postfix `?` on a `Result` expression returns early with the error and otherwise
yields the value; it is allowed only in functions whose result is a compatible `Result`. Errors that callers are
expected to handle (parsing, IO, RPC, file formats) use `Result`; exceptions remain for programming errors and
unrecoverable failures. Decide together with the must-use rule below.

### Must-use results

A call whose result type is declared must-use (`Result`, `Disposable` values, builders) and whose result is discarded is
a compile error, unless explicitly discarded (`_ = f();`). Catches swallowed errors and leaked resources; pairs with
scoped cleanup. Declared by conformance or a single compiler-known marker interface, not per-call metadata.

### Allocation-free iterator chains

`filter`, `map`, `fold`, `sum`, `any`, `count` and similar adapters over arrays, struct arrays and ranges lower to a
single loop with no closure, iterator or intermediate array allocation, specialized like other generic code. The
existing `Lambda`/array helpers that allocate per step are ported to the same API and deleted (no parallel forms).
Measured by the usual zero-allocation censuses on all targets. A strong fit for per-frame UI code.

### Explicit `unsafe` regions for raw memory

`RawPtr` arithmetic, unchecked `NativeSpan` access and other operations whose misuse corrupts memory are allowed only
inside an `unsafe { ... }` block (or an `unsafe` function), so dangerous code is visible and searchable. Checked
`NativeSpan` access stays safe. Relevant now that native memory is the default for frame data.

### Interface extensions: retroactive conformance and static members

Haxeon keeps interfaces as its only abstraction (no separate trait system) and extends them only where a consumer needs
it:

- **Conformance extensions:** `extension Rect implements Hashable { ... }` makes an existing type conform outside its
  declaration. Allowed only in the package that declares the type or the one that declares the interface (an orphan
  rule), so conformances cannot conflict. Needed when a bindings or stdlib value type must be a map key or `Codable`.
- **Static interface members and `Self`:** an interface may require static functions, and may name the conforming type
  as `Self` (`static function decode(r:Reader):Self`). Decoding needs this because no value exists yet to call an
  instance method on (`function load<T:Decodable>(r:Reader):T return T.decode(r);`). In specialized generic code `T` is
  concrete and `T.decode(r)` is a direct static call with no boxing; in erased code the call goes through the type's
  runtime descriptor (the same per-type metadata as the constant-time class tables). Same route as Swift required
  initializers, Rust associated functions and C# 11 `static abstract` members. Also enables default values
  (`static function defaultValue():Self`) and generic math (`T.zero()`, `T.add(a, b)`). Rejected alternatives: passing
  decoder objects at every call site (unchecked, verbose), decode-into-a-default-value (needs a static default anyway,
  fails for immutable structs and enums), and compiler special cases for `Codable` (violates the general-mechanisms
  rule). Implement when `Codable` is picked up, on all three backends with the usual tests.

Default interface methods stay on demand; associated types and blanket implementations are not planned unless the
iterator work requires them.

### Smaller conveniences

Check each against what Haxeon already supports before designing it.

- **`if let` / `guard let`:** unwrap an optional, including `Null<S>`, and narrow in one step.
- **Default interface methods:** static extensions cover most uses; add on demand.
- **`Codable`** (= `Encodable` + `Decodable`): format-independent field encoding for value types, synthesized when every
  field conforms; `Encodable`/`Decodable` alone for one-way data. Not object-graph serialization (objects have identity;
  graphs stay explicit), and distinct from Haxe's `haxe.Serializer` format. Replaces the MessagePack attributes and the
  metadata-driven codec requests; requires static interface members (decode) and uses conformance extensions for types
  declared elsewhere.

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

1. `Equatable`, `Hashable` and `Diffable`, replacing the former structural metadata; key paths specified alongside.
2. Signals core (ADR 0002 stage 1).
3. `Observable` (ADR 0002 stage 1b).
4. Result builders and lazy parameters, only if the ADR 0002 stage 3 component experiment needs them. The experiment
   runs first with plain Haxe expressions (re-running scopes) against explicit library primitives (run-once
   bindings); plain code is preferred when it is within 10% on allocation and frame time, because it keeps code
   meaning what it looks like.
5. Flat structs, arrays of structs and generic specialization for structs, with inline enums. Struct arrays and
   struct-specialized generic storage are implemented across HashLink, Wasm32 and Wasm GC; payload enums use declared
   value equality. The closed source subset uses inline lanes; wider enum transport and the UI conversion remain in progress. See [STRUCTS.md](STRUCTS.md) and
   [GENERIC_SPECIALIZATION.md](GENERIC_SPECIALIZATION.md) for the layouts and measurements.
6. Key paths are implemented before UI bindings: typed stored-field references, checked writes, composition,
   equality/hash and the `Diff.bit` port.
7. Inline `Null<T>` through the callable ABI (queue **a2**): carry presence and payload through closures and generic
   calls, including escaped key paths, and make their recorded nullable-struct census zero.
8. Typed storage for the standard reference maps and nullable-element arrays, deleting their boxed boundary
   conversions; generic specialization and inline `Null<T>` for scalars, and native `Int64` operations.
9. Scoped cleanup (`defer`, `Disposable` scoped bindings) is implemented.
10. `inout` with the node store prototype; move-only types for native memory only if scoped cleanup and owner scopes
   leave real bugs.
11. Smaller conveniences when a concrete use appears.

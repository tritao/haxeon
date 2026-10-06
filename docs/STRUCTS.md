# Structs

Status: design. Nothing here is implemented yet. `struct` is meant to replace
both `@:value class` and `@:value @:repr("C") class`; those forms keep
compiling while code migrates.

## Why

Haxeon has two value forms today, and each covers half of what fixed-layout
data needs:

| | `@:value class` | `@:value @:repr("C") class` (native record) |
|---|---|---|
| Purpose | avoid one heap object per small value | data with an exact C layout in native memory |
| Semantics | copied on every bind ([value semantics](INLINING_AND_VALUE_TYPES.md#value-semantics)) | address-only: no copies, no identity, no GC header |
| Local, argument, return value | yes | no ("address-only and cannot be stored by value") |
| Stored | inline in its parent object | native memory only: arenas, FFI buffers |
| Field types | any Haxe type | fixed-width scalars, `Int`, `Float`, `Bool`, pointers, nested records |
| Layout | HashLink's; no C promise | C ABI through `HxiAbi`; `sizeof`/`offsetof` fold to constants |
| Field access | `v.x` | manual: `offsetof`, `byteOffset`, `castTo` |
| Methods | direct calls | none |

Some data has to be both: stored in native memory, and also used as an
ordinary value in code. Examples are ECS components (Beartooth's component
schema is the first consumer), network messages, GPU buffer records and file
format records. A component lives in a native column and is copied into a
Wasm script's memory, while script code does
`var h = e.get<Health>(); h.value -= 10;`. Neither current form can do
both.

## Model

```haxe
struct Health : Component {
	@replicate @range(0, 100) var value:Float32;
	var regenRate:Float32;
	var lastHitBy:EntityRef;

	public function new(value:Float32) {
		this.value = value;
	}

	public function damage(amount:Float32):Void {
		value -= amount;
	}
}
```

- **A struct is a value type.** It has today's value-class semantics:
  - a copy on every bind;
  - in-place writes through places;
  - no identity, and `null` is excluded;
  - no inheritance;
  - constructors and non-virtual methods, called directly.
- **Conformance.** `struct Name : A, B` declares conformance to interfaces.
  In the first version, conformance is used only by generic constraints
  (`get<T:Component>()`). Boxing a struct into an interface-typed value is
  deferred.
- **`==` compares fields.** This fixes the current reference equality on
  value classes.

### Flat and Portable

The compiler works out two properties from a struct's fields. Neither has to
be written, but either can be asserted (`struct Vec3 : Portable`), and an
assertion that doesn't hold is a compile error that names the offending
field.

- **`Flat`:** no managed references. A struct is flat when every field is one
  of these:
  - fixed-width scalars, `Int`, `Float`, `Bool`;
  - an `enum abstract` over an integer type;
  - `RawPtr<T>`;
  - a flat struct, or a fixed array of a flat type.

  Strings, arrays, class instances, closures, `Dynamic` and enums that carry
  data are not flat. A flat struct gets:
  - a C layout wherever it is stored;
  - use through `RawPtr<T>`, `NativeSpan<T>` and `Arena`;
  - a full descriptor, with offsets (see Reflection), and C header output.
- **`Portable`:** flat, and no `RawPtr` anywhere, including in nested fields.
  - Its layout is identical on every supported target. Pointer width is the
    only layout difference between `hl` (64-bit), `wasm32` and native
    x86-64/arm64, and all of them are little-endian.
  - So a portable struct's bytes can move between a 32-bit Wasm module, a
    64-bit host, the network and saved files without any layout translation.
  - A cross-target layout test enforces this claim.

Both properties can be used as generic constraints: `T:Flat`, `T:Portable`.
FFI records are flat. Data that crosses processes or targets should be
portable.

A struct that isn't flat is still a valid value type. It can't be placed in
native memory or exported as a C header, and it gets a reduced descriptor
instead of a full one.

## Layout and bytes

- **One layout.** A flat struct uses its `HxiAbi` C layout in every place it
  can live:
  - inline in a GC object or array;
  - in a local that hasn't been scalar-replaced;
  - in native memory.

  Moving a flat struct between managed storage and native memory is then a
  copy of `sizeof<T>()` bytes.
- **Padding is always zero.** The bytes between fields are zero after every
  construction and copy:
  - HashLink `New` already zero-fills;
  - `Arena.alloc` of a flat type must zero-fill (it returns `malloc` memory
    today);
  - whole-record stores write zero padding;
  - field stores never touch padding.

  With this rule, byte comparison of flat structs is well defined.
- **Two comparisons.** `==` compares fields, so `-0 == 0` and `NaN != NaN`.
  `bitEquals(a, b)`, for flat types only, compares bytes. Change detection
  (replication, undo) wants `bitEquals`: any change to a bit counts as a
  change.

## Native memory operations

These extend [native values and memory](NATIVE_MEMORY.md), which excluded
them in its first foundation.

- **Whole-record copies:** `p.load()` and `p.store(v)` for a flat struct
  pointee. This is a copy between storage locations, not a by-value calling
  convention change.
- **Field places through pointers:** `p.ref.value -= 10` and
  `p.ref.pos.x = 0`. `p.ref` is a place, never a value. It lowers to a load
  or store at a constant offset, with no copy of the record.
  `p.ref.pos.addr()` gives the `RawPtr<Vec3>` of the nested field.
- **Spans:** `NativeSpan<T>.get(i)` copies a flat struct out, and
  `span.at(i).ref.x` accesses one field in place.
- **Wasm32:** `RawPtr` memory instructions have to lower to linear memory.
  `WasmFunctionLower` currently rejects them, and creator scripts in
  Beartooth need them. `wasm-gc` native memory is deferred.

## Fixed arrays

A flat struct field can be a fixed array, `var slots:Int32[4];`.

- Length is a compile-time constant; `slots.length` folds.
- Indexing is bounds-checked; unchecked access goes through a pointer.
- Layout matches C's `int32_t slots[4]`.
- Fixed arrays are flat when their element type is, and portable when their
  element type is.

## Reflection

`typeInfo<T>()` folds to a constant descriptor for every struct:

- **Flat structs** get a full descriptor:
  - the name, size and alignment;
  - each field's name, offset, type and typed annotations;
  - a content hash over all of the above.
- **Non-flat structs** get a reduced descriptor: the name, each field's
  name, type and typed annotations, and a content hash. There are no
  offsets or size, because the layout is not a C layout. Element types of
  arrays and nested structs are described recursively.

Non-flat descriptors have three known consumers in Beartooth:
- generator parameters, which hold child lists and arrays;
- remote-event payloads, which hold strings and lists;
- saved player data.

All three need tooling, codecs and schema evolution without being flat.

The build also writes descriptors out as an artifact, in a versioned binary
format with a JSON dump for tests. Descriptors are cached incrementally and
invalidated with their module, like IR.

### Descriptors and the wire layer

Haxeon ends up with two schema strategies. Each fits a different kind of
data, and both stay:

| | `@:wire` + `@:id(n)` ([MESSAGEPACK.md](MESSAGEPACK.md)) | Descriptors |
|---|---|---|
| Field identity | permanent numeric IDs, written by the programmer | field names, plus `@renamedFrom` for renames |
| Schema at runtime | compiled into both ends; not sent | sent with the data, or checked by hash |
| Fits | protocols between independently versioned programs whose schema programmers own (RPC services, an engine's session protocol, tool protocols) | schemas owned by end users (game creators), types known only at runtime, and data files that embed their schema |
| Precedent | protobuf | Avro |

Rules for descriptor-driven encoding:
- **Same build at both ends** (checked by comparing schema hashes): encode
  fields by position. No IDs or names are written.
- **Across builds** (persisted data, messages between different versions):
  record the writer's schema hash and keep its descriptor available. The
  reader matches fields by name:
  - added fields take their defaults;
  - removed fields are skipped;
  - `@renamedFrom` maps old names.

  A changed field type needs an explicit migration function.
- **No numbering.** The compiler never numbers fields automatically.
  Numbers derived from declaration order would decode reordered fields
  into the wrong fields without any error, once data crosses builds.

A descriptor-driven codec reuses the wire layer's MessagePack writer and
reader, its limits and its canonical byte rules. Only how fields are looked
up differs.

### Typed annotations

Metadata on structs and fields is checked against declared annotation types,
so an unknown or ill-typed annotation is a compile error:

```haxe
@:annotation enum abstract Replicate(Int) {
	var all;
	var owner;
}

@:annotation struct Range {
	var min:Float;
	var max:Float;
}
```

Annotation values become part of the descriptor. Libraries define their own
annotation types; the compiler knows only the mechanism.

### Context-hidden fields

An annotation type can declare that the fields it marks are hidden unless a
compile context is active:

```haxe
@:annotation @:hiddenUnless("server") struct Server {}
```

Reading or writing a hidden field is then a compile error that names the
field, the annotation and the active context. Descriptors still list hidden
fields, because the contexts that can see them need their layout. The
compiler knows contexts and rules, not what "server" means. Beartooth uses
this for server-only component fields; an application can use it for
editor-only data.

## C headers

Flat structs marked for export are emitted as C headers. A header exported
from a struct and imported back through HXI must reproduce the same struct:
same `HxiAbi` layout, same field names and types. Projects check generated
headers in, and a build check reports headers that are out of date.

## Migration

- `@:value class` becomes `struct`. Flatness is worked out as usual.
- `@:value @:repr("C") class` becomes `struct ... : Flat`. These records
  gain by-value use, which only adds capability.
- HXI-imported records become flat structs. This also completes the
  unification of HXI record projections that
  [NATIVE_MEMORY.md](NATIVE_MEMORY.md) lists as future work.
- Both old forms remain accepted as aliases until their uses are migrated.
  Diagnostics then suggest `struct`, and later the forms are removed.
- **One semantic change:** `==` on former value classes changes from
  reference to field comparison. Existing uses, mainly in Materia's UI code,
  have to be audited before S1 lands.

## Dependencies

- **Scalar replacement** ([inlining stage 2](INLINING_AND_VALUE_TYPES.md#plan))
  and **construct-in-place** (stage 3). Without them, every struct local on
  HashLink allocates a heap temporary. Structs work without these stages, but
  shouldn't be recommended for hot code until they land.
- **Live patching.** A change to a struct's layout is a structural type
  change, so it remains a reload boundary until the runtime has a non-moving
  type arena ([live patching](LIVE_PATCHING.md)). Migrating stored data
  across a layout change is a host concern (for example a Beartooth world).
  It needs the old and new descriptors, which reflection provides.

## Stages

Each stage keeps the driver suite, Wasm parity and the self-hosting fixed
point green.

0. **Spike.** Make `typeInfo<T>()` work for one existing native record on
   HashLink, and emit its descriptor.
   - Checkpoint: the descriptor agrees with `sizeof`/`offsetof`, its hash is
     identical across builds and targets, and the change is small. If it
     isn't small, revisit this design before S1.
1. **`struct` keyword.**
   - Parsing, the value-class semantics above, interface conformance used as
     generic constraints, field-wise `==`, and language server and formatter
     support.
   - Checkpoint: value-class tests pass when rewritten with `struct`, and the
     Wasm parity suite runs them.
2. **`Flat` and `Portable`.**
   - Working out the two properties, asserting them, and using them as
     constraints.
   - C layout for flat structs inline in GC objects; the padding rule.
   - Checkpoint: the cross-target layout test (`hl`, `wasm32`, x86-64 and
     arm64 headers) agrees for portable structs.
3. **Native memory operations.**
   - Whole-record `load`/`store`, `p.ref` places, `NativeSpan` of structs,
     and zero-filling `Arena.alloc`.
   - Migrate native records and HXI records to structs.
4. **Wasm32 native memory.**
   - Lower `RawPtr` operations to linear memory.
   - Checkpoint: the native-memory parity programs pass on `wasm32`.
5. **Reflection and typed annotations.**
   - Full descriptors for flat structs and reduced descriptors for
     non-flat ones, the descriptor artifact, incremental caching and
     `@:annotation` types.
   - A descriptor-driven MessagePack codec: positional within one build,
     matched by name across builds.
6. **C header output.** The HXI round-trip test.
7. **Fixed arrays.**
8. **Context-hidden fields.**

## Open questions

- **Conformance syntax.** `struct X : I` reuses the inheritance syntax. Should
  conformance have its own keyword (`struct X is I`)?
- **Fixed-array syntax.** `Int32[4]`, or a type such as `Fixed<Int32, 4>`,
  which would need integer generic arguments?
- **HashLink layout.** Does HashLink's inline layout for value structures
  already agree with `HxiAbi` for every flat field type? If not, the compiler
  has to insert explicit padding fields when it lowers flat structs inside
  GC objects.
- **Generic structs.** Value classes don't support generics yet. Deferred
  until a concrete need, such as a fixed-capacity ring buffer.

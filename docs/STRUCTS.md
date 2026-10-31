# Structs

Status: design, with the basic form implemented (see "Implemented so far"). `struct` is meant to replace
both `@:value class` and `@:value @:repr("C") class`; those forms keep
compiling while code migrates.

## Implemented so far

Stage 1a (2026-10-31): temporary receivers are rejected for field
writes, compound assignments, increments and methods not proven receiver-read-only. Getter and call-result chains identify
the source expression that produced the copy. A method can have unrelated global effects and still be called on a temporary
when receiver-effect analysis proves that it does not write the receiver. Its result is tracked alongside purity facts so
incremental compilation invalidates callers when that answer changes. Compound-assignment receiver
bindings preserve places instead of introducing value copies. `RawPtr.ref` and `RawPtr.load()` have distinct internal
operations, so loading a value does not accidentally create a writable pointer place. Postfix increments through a
native pointer update the pointed-to field, including nested fields, and evaluate the pointer expression once.
Receiver-effect analysis follows statically dispatched methods on the same struct, including recursive cycles, and treats
primitive field arguments as values rather than aliases. Property getters remain effectful unless their dependencies are
proven pure; a method or getter that can write the receiver still requires a writable place.

`@:structural` is accepted on structs as built-in metadata. `Structural.copy` binds an ordinary value copy, including
final fields and nested values, without invoking a constructor or assigning fields after construction. `assignChanged`
binds its target as a place, evaluates it once, and snapshots the before/after values using ordinary copies. Fieldwise
`==` and `Equality.equals` were already implemented before this work; the earlier status below predates those changes.
Language `==` now applies each field's own `==`: ordinary class and array fields compare by identity, payload enum fields
use enum identity semantics, and abstract comparison operators are honoured. Deep `Equality.equals` remains a separate
operation. A layout-edit test checks that incremental compilation regenerates the fieldwise comparison.
Focused checks cover immutable copies, generic forwarding, mutable-copy independence and nested writable places on
HashLink. Nullable struct bindings now copy present payloads, preserve absence and use fieldwise equality; an absent
value raises a catchable null-access error when cast to its non-null struct. A focused program covers these behaviours,
including nested managed fields, on HashLink, Wasm32 and Wasm GC. Locals, parameters, returns and array elements retain
their existing boxed representation; fields store a presence flag and recursively flattened payload inline. The compiler
rejects direct and indirect by-value layout cycles, including cycles through `Null<S>`; references and arrays break cycles.
Captured value bindings use shared cells when a field write or mutating receiver can change them, including nullable values;
known reference-type receivers continue to be captured directly. Tests cover writes inside and outside closures.

The stage 1a checkpoint passed: the full driver reported 617 passed and 0 failed (baseline: 608 passed), the compiler
reached a self-hosting fixed point, and 390 fixtures agreed across HashLink, Wasm32 and Wasm GC (14 existing skips).
The standalone Wasm backend suite passed; its runtime-freshness check was skipped because a wasm32-capable clang was not
configured. The nullable-field and capture fixtures also passed on all three targets with inlining disabled. Mutating
methods called on `p.ref` still change a loaded copy; this native-memory gap belongs to stage 3. The native-place probe
returns 4 instead of 0 after fixing postfix increments; it returned 6 with a compiler built from pristine `27da944b`.

Equality audit: `ExpressionTyper.compareOperands` already requested deep structural equality for both `struct`
and legacy `@:value class` at the starting revision. That rejected value types containing ordinary class references and
compared array and payload-enum fields deeply. The new fieldwise operation accepts those class fields and uses their
ordinary reference equality; arrays and payload enums now also follow their own `==`. `struct-value-semantics.hx` covers
ordinary, nested, legacy and native-width value equality; `struct-field-equality.hx` covers the changed field behaviour.
The other value-copy/map/array/escape fixtures compare scalar fields or absence. No production value declarations occur
in `src` or `stdlib`; the separate UI migration remains outside this work.

Checked on 2026-10-29: a `struct` with fields, a constructor and non-virtual methods compiles and runs with copy semantics
(`var w = v; w.x = 6` leaves `v` alone). Measured per 1,000 operations, against a `class` of the same shape:

| pattern | struct | class |
|---|---|---|
| local temporaries | ~0 | 49 KB |
| returned from a small function (the inliner may have inlined it) | ~0 | 23 KB |
| field of a holder object | 25 KB | 41 KB |
| pushed into an `Array` | 42 KB | 51 KB |

So a struct costs nothing as a temporary and sits inline in its holder, but still allocates in an `Array` or `Map`. It saves
the object header and not the data: converting a small immutable class such as `Rect` mostly helps temporaries, not storage.
The rest of this design (interface conformance, attributes, native layout, fieldwise `==`) was not checked here and may not
be implemented.

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
be written. Explicit assertions use `@flat` or `@portable` on a struct;
an assertion that does not hold is a compile error that names the offending
field. These attributes verify the inferred property; they cannot grant it.
`Flat` and `Portable` are compiler-recognized representation constraints,
not base classes or ordinary marker interfaces.

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
  - Its record representation needs no layout translation between supported
    targets. This is not proof that its logical value transfers as raw bytes:
    process/world-local tokens still require descriptor codecs to translate
    their referents. Portable layout, ownership and logical serialization are
    separate contracts.
  - A cross-target layout test enforces this claim.

Both properties can be used as generic constraints: `T:Flat`, `T:Portable`.
FFI records are flat. Data that crosses processes or targets should be
portable.

### Interface requirements and compiler checking

An interface can require representation properties of its implementing types.
Requirements propagate transitively through interface conformance. For example,
a GPU library could define:

```haxe
interface GpuRecord : Portable {
}

struct Vertex : GpuRecord {
    var x:Float32;
    var y:Float32;
}

struct Invalid : GpuRecord {
    var name:String; // Error: GpuRecord requires Portable; name is managed.
}
```

`interface GpuRecord : Portable` requires implementers to be portable; it does
not assert a storage layout for the interface itself. `Vertex : GpuRecord`
declares conformance, not implementation inheritance. No additional
`@portable` assertion is necessary on `Vertex`.

The compiler knows `Flat` and `Portable`, but has no special knowledge of any
library interface. This is a general interface requirement mechanism available
to libraries, including interfaces such as `NativeRecord : Flat`.

An interface doesn't have to require a property to use it. Beartooth's
`Component` requires none: a component may hold strings and sequences, and the
world reads the inferred flatness from the descriptor to choose native or
managed storage. Engine components that native code reads assert `@flat`.

After resolving field types, the compiler recursively infers the properties,
records them in type metadata, and checks explicit assertions, generic
constraints and inherited interface requirements against that metadata.
`Portable` implies `Flat`. For generic structs, inference uses the actual type
arguments, or their proven constraints inside generic code. Declaring
conformance cannot bypass the field checks. Diagnostics identify the required
property and the field path that violates it, including nested fields.

The inferred properties determine layout, native-memory eligibility, descriptor
form and whether fields require GC tracing. They add no runtime interface
object or dispatch. Tests must cover transitive interface requirements,
nested pointer/reference rejection and generic instantiations, as well as the
cross-target layout checks.

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

## Scoped mutable access

[SCOPED_PLACES.md](SCOPED_PLACES.md) proposes restricted `ref` parameters and
scoped callbacks, which operate on caller-provided places without granting
pointer escape. Ordinary struct parameters still copy. The proposal is
deferred: Beartooth's component API uses whole-value `get`/`set`/`update`
and doesn't need it.

## Immutability and copies

Value types have one well-known trap: a write to a field of a temporary copy changes the copy and is silently lost, as
in `node.style.padding.left = 4` when `style` or `padding` is reached through a getter or call result. C# rejects it
(CS1612) and added `readonly struct` for values that should never be edited in place; Swift rejects it through `let`.

- **Writes to a temporary are a compile error.** A field write, compound assignment or mutating method call whose target
  is not a place (a local, a field of a place, an array element, a `p.ref` place) is rejected, naming the expression that
  produced the copy.
- **A struct whose fields are all `final` is immutable.** It can only be replaced as a whole. Small values (colors,
  rectangles, insets, transforms) should be written this way; the trap above then cannot arise for them, and replacing a
  whole field is what code holding them does anyway. Mutable structs remain for records edited in place, such as world
  components and store records.
- `Structural.copy` of a struct is its ordinary copy, so the final-field restriction on `copy` applies only to classes.
  `Structural.assignChanged` writes the fields of its target, so a holder of immutable struct fields still updates
  them by replacement.

## Equality and hashing

Decided 2026-10-31, not yet implemented. Value equality is a capability a type declares, as in Rust (`derive`) and Swift
(`Equatable`/`Hashable` with synthesis), rather than something every struct gets implicitly as in Go or C#'s
`ValueType.Equals`:

- **Equality is part of a type's contract.** Implicit equality makes every field, including private and cached ones,
  part of `==` and `hash`; adding such a field, or one whose type cannot be compared, silently changes or breaks
  comparisons far from the declaration. A declaration puts that decision, and its errors, at the type.
- **Custom equality is needed.** `Semantics.same` excludes a field and `Mask` compares its image by identity. A declared
  capability can be derived or written by hand, and every consumer uses the one implementation.
- **Declaring later never breaks anyone; removing implicit equality does.**

The rules:

1. **`@:structural` derives** equality, hashing and the field operations (`Structural.changedMask`, `assignChanged`,
   `fieldBit`, `allFieldsMask`) for a struct or a class. Derived equality compares each field with that field type's
   declared equality (below); derived hashing agrees with it.
2. **A type may instead implement `function equals(other:T):Bool` and `function hash():Int`**, as a pair: one without
   the other is an error, as is combining them with `@:structural`. Field operations are not available on such a type.
3. **One equality per type, used everywhere.** For a struct with declared equality, `==`, `!=`, map keys,
   `haxeon.Equality.equals`, `Structural.hash` and the derived equality of every type that contains it all use that
   implementation. This replaces the stage 1a split, where a struct's `==` applied each field's own `==` while
   `Equality.equals` and `Structural.hash` compared deeply.
4. **A field's declared equality** is: for primitives and integer enum abstracts, `==` (floats follow IEEE: `NaN` is
   unequal to itself and `0.0 == -0.0`, and hashing maps `-0.0` to `0.0`); for structs and `@:structural` or
   custom-equality classes, their declared equality; for `Null<T>`, equal when both are absent or both present and
   equal; for strings, content; for enums, constructor and payload by the same rules; for arrays, maps and anonymous
   structures, element by element as `Equality.equals` already does; for other class instances, identity.
5. **`==` on a struct without declared equality is a compile error** naming the type and suggesting `@:structural`.
   Copying stays implicit: a struct is a value, and Haxeon has no moves, so Rust's `Clone`/`Copy` split has no
   counterpart. Nor does `PartialEq`/`Eq`: there is one equality, with IEEE floats.
6. **Classes keep identity `==`.** `@:structural` or a custom pair gives a class content equality through
   `Equality.equals`, `Structural.hash` and containing types, never through `==`.

Implementation, after the UI value-type conversion: the `==` diagnostic, the `equals`/`hash` pair and its checks, the
shared equality used by `==`, `EqualityGenerator` and `StructuralIntrinsics`, and migration of the struct fixtures
(`struct-value-semantics.hx`, `struct-field-equality.hx` and those comparing structs without `@:structural`). Then
`Semantics.same` becomes a custom pair, or derived once a per-field exclusion exists.

## Nullable structs

`null` is excluded from struct values, but "absent" is a real state: an optional color or clip rectangle. A `Null<S>`
field stores a presence flag and the value inline in its holder. Testing null reads the flag, assigning null clears the
flag and zeroes the payload, and reading an absent value raises the usual null-access error. Locals, parameters and returns
keep their existing representation and convert at field boundaries. Shared IR retains `Nullable(Obj(S))` until field
lowering expands each optional into the flag and recursively flattened payload slots. Field reads and writes convert at
the boundary; methods called on a field place use a specialized receiver so their writes remain visible through aliases.

Arrays of structs, including `Null<S>` elements, keep their existing boxed element representation in stage 1a. Inline
struct arrays are later work: HashLink's packed-array allocator and packed move are possible building blocks, but an
interior element pointer must not escape into a heap field, because the incremental collector accepts interior roots but
matches heap-field references exactly. A place must retain its owner and array growth must not leave a pending write
addressing an old backing store. A nullable by-value cycle such as `struct Node { var next:Null<Node>; }` has no finite
inline layout and is rejected.

### Allocation-free optional value flow

The UI migration exposed an allocation boundary that stage 1a deliberately leaves boxed. A `Null<Rect>` can travel
from an inline field through a local, a typed callback and another inline field. On Wasm GC, a prototype converting
only `Rect` and `Insets` increased the fixed-time Showcase's 120-frame object count from 8,654 to 19,936; a per-function
instrumentation attributes 6,480 allocations each to the optional `CanvasState.clip` getter and its `copyFrom` caller.
On HashLink, an interaction census recorded 23,217 `@haxeon.ui.Rect` and 9,811 `@haxeon.ui.Insets` allocations over
30 cycles after that prototype. The prior class census recorded 7,511 `Rect` and 70 `Insets` allocations. These are
whole-capture counts, not per-action counts. The prototype also raised the measured inspector-scroll median from
22.3 to 29.4 KiB, and the hierarchy-to-sensors median from 158.2 to 182.1 KiB. The conversion is not accepted on this
evidence. The allocation-instrumented Wasm counts include generated `struct.new` and `array.new` instructions; they do
not establish byte sizes or cover separately encoded function bodies.

#### Implemented: non-optional HashLink value temporaries

Eligible direct calls, including statically known typed closures and monomorphic methods, specialize non-optional
value arguments into scalar parameters. Results use references to caller-owned scalar slots; the references are confined
to the call and cannot escape. This uses HashLink's existing reference instructions, avoiding a new VM calling convention.
Calls that cannot be proven safe retain their original boxed ABI, including calls that exceed the VM's 256-argument JIT
limit. The VM's temporary argument table now matches its existing 256-argument storage limit; its register allocator
tracks stack arguments individually instead of using a 32-bit mask. This extends the existing calling convention without
adding a second VM ABI. Inline-field construction and copies are scalar-replaced even when ordinary function inlining is disabled.
Typed static-initialization checks preserve the value representation instead of converting it to Dynamic.

With the Rect/Insets prototype on the baseline machine, the HashLink interaction census over 30 cycles changed from
23,217 to 16,539 boxed `Rect` allocations and from 9,811 to 779 boxed `Insets` allocations. The hierarchy-to-sensors
median changed from 182.1 to 162.6 KiB and inspector-scroll from 29.4 to 21.6 KiB. The 120-frame Wasm GC Showcase
count remained 19,936 objects in full mode and 26,762 in editing mode, as this step targets HashLink. These are
intermediate measurements: the class baseline and remaining optional flow still determine acceptance.

The per-action HashLink medians below are KiB allocated per action on the same machine. The prototype converts only
`Rect` and `Insets`; step A adds non-optional lowering, step B adds optional field-copy fusion, and step C adds scalar optional flow. Selection-stress
does not report per-action bytes.

| Scenario / action | Classes | Prototype | Step A | Step B | Step C |
| --- | ---: | ---: | ---: | ---: | ---: |
| tab-matrix / console → telemetry | 110.9 | 120.7 | 112.7 | 112.7 | 112.7 |
| tab-matrix / hierarchy → sensors | 158.2 | 182.1 | 162.6 | 162.1 | 162.1 |
| tab-matrix / sensors → hierarchy | 124.8 | 138.9 | 127.8 | 126.9 | 128.9 |
| tab-matrix / telemetry → console | 128.6 | 137.8 | 131.0 | 131.0 | 131.0 |
| interaction / hover away | 24.9 | 25.0 | 25.2 | 25.0 | 25.2 |
| interaction / hover enter | 2.6 | 2.6 | 2.6 | 2.6 | 2.6 |
| interaction / hover field | 22.1 | 24.0 | 22.2 | 22.2 | 24.0 |
| interaction / hover inside | 0.6 | 0.6 | 0.6 | 0.6 | 0.6 |
| interaction / hover other | 13.1 | 13.2 | 13.2 | 13.2 | 13.2 |
| interaction / idle | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 |
| interaction / idle focused | 0.2 | 0.2 | 0.2 | 0.2 | 0.2 |
| interaction / scroll inspector | 22.3 | 29.4 | 21.6 | 21.6 | 21.6 |
| interaction / type backspace | 17.8 | 17.9 | 17.9 | 17.9 | 17.9 |
| interaction / type character | 17.8 | 17.9 | 17.9 | 17.9 | 17.9 |

The interaction allocation census counts whole 30-cycle captures, including startup:

| Type | Classes | Prototype | Step A | Step B | Step C |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rect | 7,511 | 23,217 | 16,539 | 16,539 | 5,932 |
| Insets | 70 | 9,811 | 779 | 779 | 759 |
| Color | 487 | 487 | 487 | 487 | 487 |
| LayoutAxis | 1,007 | 1,007 | 1,007 | 1,007 | 1,007 |
| Transform2D | 1,722 | 1,722 | 1,722 | 1,722 | 1,722 |

| Wasm GC Showcase objects / 120 frames | Classes | Prototype | Step A | Step B | Step C |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full | 8,654 | 19,936 | 19,936 | 6,976 | 6,976 |
| Editing | 15,482 | 26,762 | 26,762 | 13,802 | 13,802 |

#### Implemented: optional field-to-field copies

Nullable value copies remain explicit in the typed tree until the destination is known. A direct field-to-field copy
snapshots the source presence flag and every flattened leaf before writing the destination slots. Owner expressions run
in source order, and source and destination null errors occur at their original accesses. This preserves nested optionals,
managed references, side effects, and overlapping or identical places. Other copies keep their boxed representation.

The interaction census was unchanged in step B. The Wasm GC Showcase counts fell by 12,960 objects in both scenarios,
removing the paired clip getter and copy allocations measured in the prototype. These totals are below the class baseline;
HashLink per-action acceptance still needs further allocation reductions.

#### Implemented: scalar optional flow

Nonescaping optional locals carry a presence flag and recursively flattened leaves. Eligible direct calls, typed closures
and exact-type methods use specialized scalar component carriers; calls across unsupported or reference-representation
boundaries materialize the logical value. Mutated local places keep their current components across branches, loops,
callbacks and exception handlers. Value-method specializations preserve receiver writes on both normal and exceptional
returns. HashLink keeps eligible flat value places in frame registers, including across handlers, and extends its existing
scalar call convention to the component carriers. Bounded value constructors, including validation branches and joins,
and isolated value phis can also be scalar-replaced without ordinary inlining. Constructor expansion preserves validation
and exception order; recursive and unsupported exception-handler bodies retain their calls. Native-layout optional values
also use scalar flow, preserving narrow integer and Float32 stores; unsupported receiver aliases retain their boxed representation. Packed arrays remain a separate design.

Value joins are scalarized before choosing the call ABI on all targets, and again after HashLink call lowering when that
creates new joins. Optional-value methods on class receivers can use scalar flow when every possible subclass selects the
same implementation. The lowering preserves the receiver null error after argument evaluation; overriding methods keep
virtual dispatch. On the exploratory all-five-value UI build, this reduced the 30-cycle interaction Color census from
2,994 to 1,315 and the tab-matrix census from 4,997 to 1,654. HashLink per-action results still exceed the class baseline
for multiple actions, so further work is required before accepting the conversion.

HashLink scalar ABI selection now splits value joins introduced by call rewriting before testing whether a candidate can
stay in registers. On the same all-five-value prototype, the 30-cycle interaction census counted 192 Rect, 146 Insets,
1,309 Color, 807 LayoutAxis and 132 Transform2D boxes. The four tab transitions measured 125.5, 182.2, 143.0 and
143.5 KiB; hover away, enter, field, inside and other measured 26.5, 2.6, 23.3, 0.6 and 14.3 KiB; idle and focused
idle were 0.2 KiB each, inspector scroll was 21.7 KiB, and backspace and character input were 18.7 KiB each. Wasm GC
allocated 6,138, 13,168, 6,136 and 6,138 objects over 120 measured frames in full, editing, static and text-heavy modes.
These prototype measurements still do not meet the HashLink acceptance rule.

Unwrapped optional aliases passed by value to eligible direct calls and known typed closures snapshot their flattened
leaves before the call. Generated value-equality helpers use the same scalar calling convention, avoiding a box when a
nullable value is compared with a non-nullable value. A known static closure that no remaining operation observes can be
removed after its call is made direct; its debug binding is then omitted. Mutating receiver aliases remain
ineligible for this transformation so their writeback semantics are preserved.

Native-layout optional values now use the same flow as other structs. Scalar stores retain native-width truncation and
Float32 rounding. Generated structural hashes omit the null check on a non-nullable nested struct, which otherwise
boxed the inline value. On the Rect/Insets prototype, the 30-cycle interaction census fell from 5,932 to 316 Rect boxes
and from 759 to 146 Insets boxes; 120-frame Wasm GC Showcase counts fell from 6,976 to 6,496 in full mode and from
13,802 to 13,322 in editing mode. These remaining boxes include actual dynamic and array escapes. HashLink per-action
medians in KiB were 112.7, 162.1, 126.9 and 129.6 for the four tab-matrix transitions; interaction hover away, enter, field,
inside and other were 25.0, 2.6, 22.2, 0.6 and 13.2; idle and idle focused were 0.2 each, inspector scroll was 21.4,
and backspace and character input were 17.9 each. They remain intermediate results against the class baseline above.

An exploratory all-five-value UI build after scalar aliases and branching constructor expansion still has HashLink
regressions. Its 30-cycle interaction census contains 192 Rect, 146 Insets, 2,994 Color, 825 LayoutAxis and 132
Transform2D boxes. The four tab transitions measured 127.0, 183.5, 143.2 and 145.5 KiB; hover away, enter, field,
inside and other measured 26.5, 2.6, 25.0, 0.6 and 14.3 KiB; idle and focused idle were 0.2 KiB each, inspector
scroll was 23.7 KiB, and backspace and character input were 18.7 KiB each. This is an intermediate prototype,
not acceptance of the UI conversion.

The cross-target tests exercise present and absent values, nested managed fields, aliases, side effects, typed closures,
recursion, exceptions and reentrancy, as well as allocation bounds. They run on HashLink, Wasm32 and Wasm GC with and
without inlining. The Rect/Insets prototype above remains an intermediate measurement: several HashLink actions still
allocate more than the class baseline, so it does not yet meet the UI migration's acceptance rule.

## Representation on Wasm GC

Wasm GC cannot embed one struct type inside another, so the backend recursively flattens struct fields into their holder.
It specializes methods on field places, preserving intermediate writes visible to callbacks, and represents nonescaping
values with scalar locals, including across exception handlers. Direct calls and eligible typed closure and virtual calls
pass scalar parameters and return multiple values. Scalar receiver methods return their updated fields even on a Haxe
exception, before the original exception is rethrown. Narrow fields retain their stored-width behaviour. Dynamic,
external and other reference-representation boundaries still materialize boxes when required. Eligible optional locals
use scalar components as described above; array elements retain their boxed representation. Native-memory operations
continue to use linear memory.

The pre-change representation, checked on 2026-10-31 in `WasmGcRepresentation`, had these costs:

- An ordinary value class is a separate Wasm GC struct, referenced from its holder, and every copy (`TCopy`) allocates a
  new one. Scalar replacement removes copies that never leave a function, but a value stored in a field and read back
  costs more on Wasm GC than a class instance does.
- A flat record with native layout is stored as bytes in an `i8` array payload. Each scalar field read or write is
  assembled byte by byte, and reading a nested inline record allocates a view object.

Required for structs on Wasm GC:

- **Flattening.** A struct field contributes its scalar fields directly to the holder's Wasm GC struct
  (`padding_left`, `padding_top`, …), recursively, so reading `holder.padding.left` is one `struct.get`.
- **Scalarized locals, parameters and returns.** A struct local is one Wasm local per field, passed as several
  parameters and returned through multi-value returns, so a copy is a set of local moves.
- **Byte payloads only where bytes are the point**: data shared with native code or linear memory. Their field access
  should use wide array loads where the engine supports them rather than one byte at a time.

With inlining disabled on this x86-64 machine, an instruction-level Wasm GC allocation census counted the following
allocations over 100,000 iterations, including setup. Comparing zero iterations confirms that all remaining allocations
are setup; the field, copies and calls allocate nothing in the loop.

| Workload | Before | After |
|---|---:|---:|
| Field read and copy | 200,003 | 1 |
| Value argument and return | 400,003 | 1 |
| Static, captured and bound typed closure calls | 600,008 | 7 |

For one million iterations of the same programs, paired on Node 22.21.1 with inlining disabled, three warmups and nine
samples gave these median times on an Intel i5-13600K. The machine was shared with other work during measurement.

| Workload | Before (ms) | After (ms) |
|---|---:|---:|
| Field read and copy | 4.791 | 0.641 |
| Value argument and return | 18.412 | 0.671 |
| Static, captured and bound typed closure calls | 27.865 | 9.956 |

The five-sample `scripts/benchmark-wasm-gc.sh` control exercises the Wasm32 linear-memory collector, not the Wasm GC
backend. Its median times before and after were 0.080/0.096 ms for stress allocation bursts, 0.031/0.035 ms for budgeted
bursts, 0.789/0.822 ms for deep chains and 1.593/1.673 ms for wide arrays. Allocation counts and bytes were unchanged
(2,048/32,768 for bursts, 20,000/320,000 for chains and 30,002/600,056 for arrays).

The stage 1b checkpoint passed: the driver reported 622 passed and 0 failed, self-hosting reached a fixed point, and
395 fixtures agreed across HashLink, Wasm32 and Wasm GC with 14 existing skips, both with and without inlining. The
standalone Wasm backend and native-memory integration tests passed. The Wasm runtime freshness check was skipped because
a wasm32-capable clang was not configured.

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

Non-flat descriptors have these known consumers in Beartooth:
- components and resources with string or sequence fields, stored in
  managed columns;
- generator parameters, which hold child lists and arrays;
- remote-event payloads, which hold strings and lists;
- saved player data.

All of them need tooling, codecs and schema evolution without being flat.

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

The same annotation can also mark a type (a struct or a class) or a method. A
hidden declaration is left out of builds whose context doesn't make it visible,
and naming it from code compiled in such a build is a compile error that names
the declaration, the annotation and the active context. An override takes the
context of the method it overrides. Beartooth uses this at every level, so one
behavior class can hold server, client and shared members while each build of a
game contains only its own side's code (Beartooth's script plan, SR-D7).

Beartooth's remote methods also need the other build to see a hidden method's
signature, but not its body, so that it can be called through a typed proxy.
Whether that is a compiler feature or generated proxies is decided with S8.

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
  HashLink allocates a heap temporary. Both now run inside the inliner
  (`IrScalarReplacement`; construct-in-place on HashLink, `8e33f0cd`), with one
  known limit: an object whose class has a value class field is not scalar
  replaced, which is exactly the nested case (a style holding insets and colors).
  Lifting that limit is needed before nested structs are recommended for hot code.
- **Wasm GC representation** (stage 1b above). Without it, structs allocate more
  on Wasm GC than classes do.
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
1a. **Copies and optionals.**
   - The temporary-write error; immutable structs (all fields `final`); `Null<S>` fields with an inline presence flag.
     Array elements retain their existing boxed representation until inline struct arrays are implemented later.
   - Checkpoint: the error fires on getter and call-result chains, and `Null<S>` programs give the same results on all
     targets.
   - Nested scalar replacement now tracks recursive value fields and whole-field copies, including construction into
     inline HashLink fields. A 100,000-iteration nested-layout census fell from 100,000 allocations (2,400,000 bytes)
     to zero; see [scalar replacement](INLINING_AND_VALUE_TYPES.md#scalar-replacement) for the limits.
1b. **Wasm GC representation.**
   - Flatten struct fields into their holder, scalarize locals, parameters and returns.
   - Checkpoint: a struct stored in a field, read and copied allocates nothing on Wasm GC, and the parity suite passes.
2. **`Flat` and `Portable`.**
   - Working out the two properties, asserting them with attributes, and
     using them as constraints, including transitive interface requirements.
   - Field-path diagnostics and generic-instantiation checks; no engine-specific
     compiler knowledge.
   - C layout for flat structs inline in GC objects; the padding rule.
   - Checkpoint: the cross-target layout test (`hl`, `wasm32`, x86-64 and
     arm64 headers) agrees for portable structs.
3. **Native memory operations.**
   - Whole-record `load`/`store`, `p.ref` places, `NativeSpan` of structs,
     and zero-filling `Arena.alloc`.
   - Migrate native records and HXI records to structs.
3a. **Scoped mutable places** (deferred; no current consumer).
   - Validate the restricted ref/scoped callback contract in SCOPED_PLACES.md.
   - Include escape diagnostics, transitive non-suspension checks and module
     contract preservation. Native and Wasm parity gate the creator edit API.
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
8. **Context-hidden fields, types and methods.**

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

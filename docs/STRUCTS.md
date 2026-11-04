# Structs

Status: implementation in progress. `struct` replaces
both `@:value class` and `@:value @:repr("C") class`; their uses will be ported and the old forms removed in the same change.
The broader plan for conformances and struct-specialized generics is in [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md).

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

Declared `Equatable`, `Hashable` and `Diffable` conformance selects one equality and hash implementation per type.
`Hashable` implies `Equatable`; generated implementations recurse through fields that support the same conformance, and
diagnostics name unsupported fields. A handwritten `equals(other:T):Bool` supplies equality; a handwritten hash is
required with it for `Hashable`. Struct comparisons without `Equatable` are rejected, while nonconforming classes keep
identity comparison. `haxeon.Equality.equals` and `==` use that same implementation. `Diff.mask/apply/bit/all` operate
on `Diffable` declarations. `Diff.copy` remains only for mutable `Diffable` classes; a struct is copied by binding
it to a value.
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
The other value-copy/map/array/escape fixtures compare scalar fields or absence. At the compiler-conformance checkpoint,
there were no production value declarations in `src` or `stdlib`; UI value migrations are tracked separately under
[ADR 0002](adr/0002-reactive-ui-model.md) and [UI value types](../packages/ui/docs/VALUE_TYPES.md).

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
struct Health implements Component {
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
- **Conformance.** `struct Name implements A implements B` declares conformance to interfaces; classes and enums use the same spelling.
  Interfaces remain the abstraction; there is no separate trait feature. A generic bound such as
  `lerp<T:Interpolate>` dispatches statically after specialization for each struct type, without boxing. Converting a
  struct to an interface-typed value boxes it, like a Rust `dyn Trait`; using an interface as a bound does not.
  Retroactive conformance requires coherence rules and is deferred, as are associated types and default interface
  methods, until a concrete need arises. [ADR 0002](adr/0002-reactive-ui-model.md) also plans class-only `Observable`
  conformance, whose field bits share `Diffable`'s numbering; it is future work, not part of this migration.
- **Declared equality.** Conformance to `Equatable` or `Hashable` declares value equality; the compiler synthesizes
  it when possible, as described in [Equality and hashing](#equality-and-hashing).

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
interface GpuRecord extends Portable {
}

struct Vertex implements GpuRecord {
    var x:Float32;
    var y:Float32;
}

struct Invalid implements GpuRecord {
    var name:String; // Error: GpuRecord requires Portable; name is managed.
}
```

`interface GpuRecord extends Portable` requires implementers to be portable; it does
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

Wasm32 and Wasm GC flatten struct fields into their containing managed object. Wasm32 uses the native offsets and
widths for flat fields, including nested records and padding; a managed record can also contain reference slots next
to its flat fields. A cross-target fixture checks copies and null access, verifies the nested bytes on Wasm32, and
checks that references survive a stressed collection. With inlining either enabled or disabled, constructing 1,024
holders allocates 1,024 objects on each Wasm target, with no additional object for the struct field.

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
- Struct bindings are ordinary value copies, including final fields. `Diff.copy` is only for `Diffable` classes.
- `Diff.apply` writes changed, writable fields of its target. It reports immutable fields by name.

The flow analyzer can infer construction as effect-free when it writes only the fresh receiver, does not let that
receiver escape, and its initializers and callees are effect-free. It tracks nested constructors in the same purity
fixpoint as other functions, so a getter that constructs a value can preserve a caller's nullable field refinements.
Effectful or unsupported constructors and initializers invalidate those refinements, including after incremental edits.
The proof covers exact non-generic declarations without inherited initialization.

Fresh values copied into inline fields, including closure environments, stay scalar when eligible. Copies snapshot their
leaves before writing; values at genuine escape boundaries retain their existing allocation. HashLink frame-owned scalar
locals include full-width native fields across exception handlers, while narrow fields retain their storage conversions.

A same-machine, same-compiler attribution sampled 28 warmed tab transitions. In bytes, the all-five prototype's
`LayoutStyle` grew from 16,896 to 19,008 with Rect/Insets and 29,240 with all five on console-to-telemetry and
telemetry-to-console; on the other two transitions it grew from 18,048 to 20,304 and 30,960. In transition order,
`ResolvedLayoutItem` was 2,960/17,360/6,560/3,440 bytes as classes and 4,736/27,776/10,496/5,504 with Rect/Insets.
In the all-five prototype `LayoutNode` grew by 1,344–1,416 bytes; `ResolvedLayoutItem` changed by +888, +5,208, +1,968
and +1,032 bytes respectively. Eliminating `Rect` saved 1,840, 9,280, 3,760 and 2,080 bytes, while eliminating
`LayoutAxis` saved 1,824, 2,064, 2,064 and 1,824 bytes. These are independent per-type medians, not additive action
totals. The holder increase exposed unnecessary per-build work, addressed by retaining stable pane and inspector variants
and by reusing private style templates while preserving immutable full-width values.

On Wasm32, ordinary struct fields currently use boxed backing storage. Replacing a field copies the new value into its
existing backing place, including nested value fields, so a receiver already bound to that place sees changes made by a
callback. A field's first assignment adopts its newly copied value. This does not add a box per replacement; value reads
still make their usual independent copies. Wasm GC uses flattened fields for the same place semantics.

## Enum value semantics and inline layout

An enum value has no identity. Recursive enums, enums with a disproportionately large case, and values boxed at Dynamic,
reflection or native boundaries retain exactly the same value semantics as inline values. A payload enum declares
`enum E implements Equatable` or `enum E implements Hashable` to use `==` and `!=`; comparing a payload enum without that conformance is
an error, as for structs. Checking a payload enum against a payload-free case uses a `switch` or pattern match; the
constant case does not create an exception to the conformance rule. App and library code use declared equality or case
patterns rather than reflective `Type.enumEq`. Synthesized equality compares the case tag and then its payload fields
according to their own declared equality. Synthesized hashing uses the same tag and payload distinctions. Handwritten
implementations are allowed under the same equality/hash contract as structs. Enums without payloads have tag equality and are trivially
`Equatable` and `Hashable`. `Type.enumEq` remains reflective structural comparison and agrees with synthesized equality
for a conforming enum.

`Reflect.compare` does not define an order for enum values. Comparing an enum through that API returns its existing
invalid-comparison result (`0xAABBCCDD`), including when both operands are the same boxed value. Equality conformance
does not imply an ordering, and using an allocation address would make boxing observable. This rule applies across
HashLink, Wasm32 and Wasm GC; reflective structural equality remains available through `Type.enumEq`.

Handwritten payload-enum conformance uses instance methods inside the enum declaration, matching structs:
`equals(other:E):Bool` and, for `Hashable`, `hash():Int`. Direct calls and declared equality use those methods; a
handwritten equality on a `Hashable` enum requires a handwritten hash. The methods are statically dispatched for each
concrete enum type so generic arguments retain their type semantics. `Type.enumEq` deliberately remains structural,
including when the enum supplies handwritten equality. Nullary enums retain tag equality and do not override it.

At a genuine conversion to `Dynamic`, a generic enum needs its concrete type arguments to select handwritten or
constrained equality after the escape. The boxed enum's runtime descriptor carries that type; an already-boxed enum
therefore does not need a second wrapper allocation. Declared equality and reflective structural equality use separate
generated operations. Casts, type tests, reflection and native boundaries preserve the source enum type; a raw pointer or
object identity comparison is not a fallback. Dynamic array reads and writes use the same enum descriptor as typed access.
An erased `Array<E<T>>` view must retain the concrete enum type at each element escape, including when the array was
created and populated before that view. The current boxed enum ABI erases `T`, so inspecting the nominal enum name or
its payload cannot recover the right conformance in general (a case may not contain `T` at all). Preserving array
aliases therefore also requires carrying the concrete type through the boxed representation; choosing equality by nominal
name, payload shape, or object identity would change program meaning. The selected design gives each concrete boxed enum
specialization a canonical runtime type descriptor, sharing its physical layout when possible. The descriptor selects the
conformance and survives ordinary array reads and native/reflection escapes. It is per type, not an allocation or side
table entry per element. Inline enum values keep their statically known type and materialize the same descriptor only at
a genuine erased boundary. Generic code that constructs or erases such an enum must retain the concrete specialization,
as described in `GENERIC_SPECIALIZATION.md`. This descriptor is implemented for boxed enum values; inline enum
representation remains pending.

The candidate inline layout uses tag zero for null and one-based case tags, followed by the maximum scalar-word and
reference-slot counts across cases. The scalar and reference payloads overlap across cases. Classification is stable
across targets: a recursive enum stays boxed, as does an enum whose largest case needs more than eight 64-bit scalar
words plus reference slots and more than twice the next-largest case (using one as the minimum comparison size). This
bounds the cost of putting one exceptional payload in every containing value. The thresholds are an implementation
choice to be checked against the required no-regression measurements; this layout is not implemented yet.

This rule avoids making allocation strategy observable and does not require an identity token in the agreed tag, scalar
and reference-slot layout. Existing payload-enum comparisons declare conformance where value equality is intended and
express any former identity-dependent distinction explicitly. The compiler enforces this rule for boxed enums; inline
enum lowering remains pending.

### Enum equality checkpoint measurements (candidate)

On the same machine, the starting baseline was Haxeon `ca255ae6` and outer `045d3585c`. The candidate keeps the
existing boxed enum layout while adding declared equality and specialized generic enum descriptors. Allocation medians
are KiB per action:

| Action | Starting baseline | Candidate |
| --- | ---: | ---: |
| hierarchy → sensors | 114.6 | 112.6 |
| sensors → hierarchy | 80.1 | 78.1 |
| console → telemetry | 74.5 | 74.5 |
| telemetry → console | 92.9 | 92.9 |
| hover enter / inside | 0.5 / 0.5 | 0.5 / 0.5 |
| hover other / field / away | 10.0 / 12.4 / 13.6 | 10.0 / 12.4 / 13.6 |
| scroll inspector | 21.2 | 21.2 |
| idle / idle focused | 0.2 / 0.2 | 0.2 / 0.2 |
| type character / backspace | 16.1 / 16.6 | 16.1 / 16.2 |

The 30-cycle selection-stress census measured 342,877 allocations at the starting baseline and 342,100 in the candidate;
five alternating pairs against the previous semantic checkpoint had a median of 342,098 on each side. Wasm GC Showcase
object counts were 5,896 / 5,896 / 5,896 / 12,835 at baseline and 5,896 / 5,896 / 5,896 / 12,622 in the candidate
(full, static, text-heavy, editing; the baseline editing repeats were 12,835 / 12,833 / 12,835).

The nine starting-baseline headless RSS window medians were [30.47, 4.06, 0.94, 4.69] MiB. In 27 alternating pairs
against the previous semantic checkpoint, control medians were [30.00, 3.59, 0.78, 4.84] and candidate medians were
[29.84, 3.75, 0.78, 5.00] MiB; median paired differences were [-0.16, 0.16, 0.00, 0.00] MiB. A separate 27-pair
calibration using identical control bytecode on both sides produced medians [30.00, 3.75, 0.78, 5.00] and
[30.00, 3.75, 0.78, 4.84] MiB, with a -0.15 MiB median paired difference in the fourth window. The second-window
candidate difference is not explained by that calibration and remains an open measurement. A matched 500-cycle census
recorded 1,825,372 versus 1,825,376 allocations; the four extra allocations were 1,424 bytes of byte buffers. A
30-cycle every-allocation stack census attributed differences to `JsonPrinter` and headless profile output, but does not
prove the cause of the RSS difference. No ceiling was raised. Inline enum lowering and its allocation measurements remain
pending.

After adding native-signature descriptor discovery, the same action medians were unchanged and the selection census was
342,098. The Wasm GC Showcase counts were 5,894 / 5,896 / 5,896 / 12,620. In 27 alternating pairs against the same
previous semantic checkpoint, both control and candidate had RSS window medians [29.84, 3.75, 0.78, 5.00] MiB; the
median paired differences were [0.15, 0.00, 0.00, 0.00] MiB. A matched 500-cycle allocation census recorded 1,825,380
versus 1,825,371 allocations and 151,717,696 versus 151,715,344 bytes; all of the difference was in byte buffers.
The `+0.15` MiB paired first-window difference remains visible even though the window medians match; it is not claimed
as a measured improvement.

After removing the extra Dynamic enum wrapper and rejecting enum ordering in `Reflect.compare`, the Wasm GC Showcase
counts were 5,896 / 5,896 / 5,896 / 12,622 (full, static, text-heavy, editing). The same-machine starting baseline
was 5,896 / 5,896 / 5,896 / 12,835. The interaction allocation medians in the table above were unchanged in five alternating
interaction pairs against the previous semantic checkpoint; one separate candidate capture measured hover-away at
12.1 KiB, but four of five paired captures measured 13.6 KiB, so its ceiling was not lowered. Selection stress counted
342,098 allocations. Its `@haxeon.ui.TextStyle` and `@haxeon.ui.ParagraphStyle` counts were 140 each; the starting
baseline had 161 and 140 respectively, plus 240 `@haxeon.ui.widgets.docking.DockTextWidthKey` allocations, now zero.

For the same revision, 27 alternating RSS pairs against the previous semantic checkpoint gave control window medians
[30.00, 3.91, 0.78, 4.84] MiB and candidate medians [30.00, 3.59, 0.78, 4.84] MiB, with median paired differences
[+0.16, -0.15, 0.00, 0.00] MiB. A separate 27-pair calibration using identical control bytecode on both sides gave
paired differences [-0.15, +0.15, 0.00, 0.00] MiB. Three alternating allocation-census pairs around the affected
window gave 100-cycle control/candidate medians of 399,162 / 399,161 allocations and 32,784,344 / 32,784,600 bytes,
and 200-cycle medians of 755,678 / 755,673 allocations and 62,475,528 / 62,474,784 bytes. These results show
page-scale variation and no material increase in counted allocations, but the positive paired first-window difference
remains visible; it is not reported as a measured improvement.

The candidate now removes reflective enum helpers that no `Type.enumEq` operation can reach, while preserving the
concrete descriptors used by Dynamic equality. Nested typed reflection and adding reflection during an incremental
compile have dedicated tests. In the editor profile this removed 201 helpers and reduced bytecode from 102,820,303 to
102,226,757 bytes. A fresh 27-pair RSS comparison against the same control had window medians [30.00, 3.59, 0.78, 4.84]
MiB for control and [30.16, 3.59, 0.78, 4.84] MiB for the reduced candidate; median paired differences were
[-0.31, 0.00, 0.00, 0.00] MiB. The starting-baseline fourth-window median was 4.69 MiB; both current group medians are
0.15 MiB higher, within the page-scale variation shown by the identical-bytecode calibrations above. The measured
numbers are retained here rather than presenting the first-window paired result as a general RSS improvement.

The reduced candidate's first interaction capture reported hover-field at 12.6 KiB versus the starting 12.4 KiB. In a
fixed nine-pair comparison, the median was 12.4 KiB on both sides and one capture on each side reported 12.6 KiB; all
other interaction allocation medians matched. The 30-cycle selection census was 342,099 allocations, with 140
`@haxeon.ui.TextStyle` and 140 `@haxeon.ui.ParagraphStyle` allocations. No budget ceiling was raised or lowered on the
basis of the variable hover measurements.


After the struct-array iterator and verifier fixes, the semantic-equality candidate was measured again against the
previous lane-safe editor build. Nine alternating interaction pairs had identical per-action allocation medians; a
single candidate backspace sample was 16.6 KiB while the paired median was 16.2 KiB on both sides. Nine alternating
selection-stress censuses had medians of 342,097 allocations on both sides and a paired median difference of +1. The
original selection baseline was 342,877. Nine alternating 500-cycle headless RSS captures had control window medians
[30.00, 3.91, 0.78, 5.00] MiB and candidate medians [30.31, 3.59, 0.78, 4.84] MiB, with paired median differences
[+0.62, 0.00, 0.00, 0.00] MiB. The first-window difference remains an open measurement; prior identical-bytecode
calibration showed page-level variation, but does not establish the cause of this result. Five alternating Wasm GC
Showcase pairs had equal full and text-heavy medians of 5,896 objects; one control text-heavy sample had 5,894.
Static and editing counts were 5,896 and 12,622 respectively. No performance ceiling was raised.


After porting the application and libraries from reflective enum comparison to declared conformance and case
patterns, nine alternating pairs against the preceding enum checkpoint had the same allocation median for every
action in the table above. The selection-stress census medians were 342,097 on both sides (paired median delta zero);
its candidate had 140 `@haxeon.ui.TextStyle`, 140 `@haxeon.ui.ParagraphStyle`, and no
`@haxeon.ui.widgets.docking.DockTextWidthKey` allocations. The two tab allocation ceilings were lowered to retain the
measured reduction from the starting baseline.

In nine paired 500-cycle headless captures, control and candidate RSS window medians were
[29.84, 3.75, 0.78, 4.84] and [30.16, 3.75, 0.78, 5.00] MiB, with paired median differences
[+0.31, +0.16, 0.00, +0.16] MiB. A separate nine-pair identical-bytecode calibration had window medians
[30.16, 3.59, 0.78, 5.00] and [29.84, 3.91, 0.78, 5.00] MiB, with paired differences
[-0.31, +0.47, 0.00, 0.00] MiB. The fourth-window candidate difference remains visible; these measurements do not
prove an RSS improvement. Five paired allocation censuses of the same workload had control/candidate medians of
1,825,370 / 1,825,374 allocations and a paired median difference of +6. Three further type comparisons found only
byte-buffer differences, of -6, -4, and +3 allocations; their source is not established. The 30-cycle selection
census type comparison found only 176 additional byte-buffer bytes and no allocation-count difference.

## Equality and hashing

Decided and implemented 2026-11-01. Value equality is declared by interface conformance, following Swift's
`Equatable` and `Hashable` model:

```haxe
struct Color implements Hashable { /* fields */ }
class Record implements Hashable { /* fields */ }
```

`Equatable` supplies `==`; `Hashable` implies `Equatable`, so a type that is also a key ordinarily declares only
`Hashable`. The compiler synthesizes equality and hashing when every field supports the required conformance, and names
an offending field otherwise. Hand-written `equals` and `hash` implementations satisfy the same interfaces rather than
forming a separate declaration mechanism. A type has one equality used by `==`, maps, `haxeon.Equality.equals`,
`haxeon.Hashing.hash` and containing types.

A handwritten `equals(other:T):Bool` on a `Hashable` type requires a handwritten `hash():Int`. The compiler cannot
infer which distinctions the custom equality ignores, so a hash synthesized from all fields could give unequal hashes
to equal values. The author is responsible for keeping the two methods consistent. A handwritten hash may accompany
synthesized equality. A class with a synthesized hash must have immutable stored fields; otherwise changing a field while
the object is a map key could change its hash. The compiler diagnoses writable fields. A handwritten hash is an
explicit author contract and may read mutable state only when that state cannot change the key's hash while it is stored.
For classes, synthesis visits stored base fields before fields declared by the derived class, resolving generic base
arguments at each step. A handwritten method is inherited like an ordinary method, including its equality and hash
contract.

A struct that does not conform to `Equatable` cannot be compared with `==` or `!=`; the compiler diagnoses the missing
conformance. Classes keep identity equality unless they conform. Primitives and integer enum abstracts retain their
value semantics; floats retain IEEE equality. Float hashing folds the IEEE bits after canonicalizing both zero signs
and all NaNs, so equal values hash alike and infinities or large finite values do not require a numeric conversion. With
specialized interface bounds, `Map<K:Hashable, V>` and `Equality.equals<T:Equatable>` are checked at compile time and struct-bound calls
are statically dispatched without boxing.

`Array<S>.indexOf`, `contains` and `remove` require `S` to implement `Equatable` and use that same declared equality, including a
handwritten `equals`. They examine inline elements as values and `remove` shifts the lanes in place. Nullable struct
arrays compare absence with absence and use the declared equality for present elements. Requiring the conformance keeps
array lookup consistent with `==` instead of inventing an identity for copied values.

These three compiler-known interfaces are erased from HashLink's per-instance virtual-cache slots: their operations are
statically selected, so retaining an interface cache would enlarge every conforming class and every inline value field.
Ordinary runtime interfaces keep their cache slots and dispatch behavior.

Field operations are a separate opt-in through the compiler-known `Diffable` interface, for example
`struct Style implements Diffable implements Hashable` or `class Record implements Diffable`. The compiler synthesizes `Diff.bit`,
`Diff.all` and `Diff.mask` for conforming types. Masks expose declaration order and field count, so the type's
author must choose that contract; adding or reordering private fields must not silently expose it. Rust and Swift likewise
do not synthesize field-level operations by default.
For a derived class, inherited fields occupy the first bits in base-to-derived declaration order; copying, applying and
fingerprinting use that same traversal.

`Diff.apply` requires `Diffable` and writable destination fields; an immutable field produces a compile error naming
the field. Struct binding already copies values, so `Diff.copy` is unnecessary for structs and remains for
`Diffable` classes. `Diff.fingerprint(value)` synthesizes the same ordered field traversal as `Diff.mask` and combines
`Hashing.hash` for each field. Every field must conform to `Hashable` when this operation is used. The result is a
snapshot fingerprint, not a map-key contract, so it is valid for mutable `Diffable` classes. Float fields follow the
same `Hashable` behavior: `0.0` and `-0.0` match, and NaNs use the canonical hash. All `@:structural` declarations and
the old mask and hash APIs have been removed.

An `Observable` field containing a struct must currently be replaced as a whole: copy the field into a local, modify
the local, and assign it back. The compiler rejects nested field writes, increments, mutating method calls and bound
mutating method references rooted in a tracked Observable struct field, because those places cannot yet preserve
invalidation and exception semantics. Reads,
read-only methods, and places rooted in `@:unobservable` fields remain available. Whole-field assignment tracks the
change normally and remains eligible for value scalarization. In a scalar-and-reference struct fixture, replacing the
old in-place write with copy-and-assign retained zero allocations on HashLink for 1,024 writes and on Wasm32 and Wasm GC
for 8 and 1,024 writes, with inlining enabled and disabled.

Conformance provides one mechanism for both equality and generic bounds, without a separate metadata layer. Rust uses
`derive` because it lacks conformance with compiler synthesis. Retroactive conformance, associated types and default
interface methods remain deferred until there is a concrete need.

The data-record aliasing audit converted `TextStyle`, `ParagraphStyle`, `DockTextWidthKey`, `Shortcut`,
`EffectParameter`, `InkOverflow`, `CustomEffectDefinition`, and the app's `CncPresentation` and `HobbingTelemetry`
records to structs with the needed conformances. These values carry configuration, keys or snapshots; callers rely on
their contents rather than reference identity. The UI continues to encode values at its existing scalar native boundary.
`LayoutStyle` stays a mutable `Equatable, Diffable` class: its struct prototype boxes at layout-node call sites and
regresses transition allocations. It is not `Hashable`, because its fields change in place; render and style caches use
the compiler-generated `Diff.fingerprint` snapshot, which hashes its stored fields without making it a map key. The census
and per-action measurements are recorded in [UI value types](../packages/ui/docs/VALUE_TYPES.md). Future ADR 0002 per-field `@Channel(...)` declarations fold into
the masks produced by `Diffable`. Current rules are summarized in [STRUCTURAL_EQUALITY.md](STRUCTURAL_EQUALITY.md).

At a genuine Dynamic callback boundary, HashLink boxes a headerless struct as a typed Dynamic value and copies the
payload; a value returned from the generic callback wrapper is copied into the typed result as well. This keeps a
saved Dynamic value independent of later writes to either the original argument or the returned value, and keeps its
managed references alive across GC. Wasm32 and Wasm GC follow the same observable value semantics.

## Nullable structs

`null` is excluded from struct values, but "absent" is a real state: an optional color or clip rectangle. A `Null<S>`
field stores a presence flag and the value inline in its holder. Testing null reads the flag, assigning null clears the
flag and zeroes the payload, and reading an absent value raises the usual null-access error. Eligible nonescaping locals,
parameters and returns also use a presence flag and flattened leaves. Shared IR retains `Nullable(Obj(S))` until lowering;
escaping and unsupported boundaries use their boxed representation. Methods called on a field place use a specialized
receiver so their writes remain visible through aliases.

Arrays of structs, including `Null<S>` elements, keep their existing boxed element representation in stage 1a. Inline
struct arrays are later work: HashLink's packed-array allocator and packed move are possible building blocks, but an
interior element pointer must not escape into a heap field, because the incremental collector accepts interior roots but
matches heap-field references exactly. A place must retain its owner and array growth must not leave a pending write
addressing an old backing store. A nullable by-value cycle such as `struct Node { var next:Null<Node>; }` has no finite
inline layout and is rejected.

### Allocation-free optional value flow

The UI migration exposed allocations when a `Null<Rect>` traveled from an inline field through a local, a typed
callback and another inline field. The compiler changes below keep eligible value flow scalar while preserving the
boxed representation at genuine escape boundaries.

#### Implemented: non-optional HashLink value temporaries

Eligible direct calls, including statically known typed closures and monomorphic methods, specialize non-optional
value arguments into scalar parameters. Results use references to caller-owned scalar slots; the references are confined
to the call and cannot escape. This uses HashLink's existing reference instructions, avoiding a new VM calling convention.
Calls that cannot be proven safe retain their original boxed ABI, including calls that exceed the VM's 256-argument JIT
limit. The VM's temporary argument table now matches its existing 256-argument storage limit; its register allocator
tracks stack arguments individually instead of using a 32-bit mask. This extends the existing calling convention without
adding a second VM ABI. Inline-field construction and copies are scalar-replaced even when ordinary function inlining is disabled.
Typed static-initialization checks preserve the value representation instead of converting it to Dynamic.

The same-machine HashLink medians below are KiB per action. The all-five column is the full-width exploratory
conversion before removing repeated holder allocations. Selection uses a direct allocation census because the budget
script does not report that action's bytes. `Gc.totalAllocated` reports reservations in chunks, so tiny differences
between adjacent actions can move between those actions; a direct per-action census checks the current counts. For
example, backspace measured 18.1 KiB in another reservation-based run, but its direct census fell from 18,392 to
17,056 bytes.

| Action | Classes | Rect/Insets | All five | Current |
| --- | ---: | ---: | ---: | ---: |
| console → telemetry | 110.9 | 112.7 | 125.0 | 74.9 |
| hierarchy → sensors | 158.2 | 162.1 | 183.5 | 118.2 |
| sensors → hierarchy | 124.8 | 126.9 | 145.0 | 82.2 |
| telemetry → console | 128.6 | 131.0 | 145.5 | 95.3 |
| hover away | 24.9 | 25.0 | 26.5 | 15.0 |
| hover enter | 2.6 | 2.6 | 2.6 | 0.5 |
| hover field | 22.1 | 22.2 | 25.0 | 14.0 |
| hover inside | 0.6 | 0.6 | 0.6 | 0.5 |
| hover other | 13.1 | 13.2 | 14.3 | 10.0 |
| idle | 0.2 | 0.2 | 0.2 | 0.2 |
| idle focused | 0.2 | 0.2 | 0.2 | 0.2 |
| scroll inspector | 22.3 | 21.6 | 23.7 | 21.3 |
| type backspace | 17.8 | 17.9 | 18.7 | 16.3 |
| type character | 17.8 | 17.9 | 18.7 | 16.2 |
| selection (census) | 927.7 | — | — | 895.7 |

The 120-frame instrumented Wasm GC Showcase counts generated `struct.new` and `array.new` operations; these counts do
not establish byte sizes or cover separately encoded function bodies.

| Showcase scenario | Classes | Rect/Insets | All five | Current |
| --- | ---: | ---: | ---: | ---: |
| Full | 8,654 | 6,496 | 6,138 | 5,896 |
| Editing | 15,482 | 13,528 | 13,168 | 12,833 |
| Static | 8,654 | 6,496 | 6,136 | 5,894 |
| Text-heavy | 8,656 | 6,496 | 6,138 | 5,896 |

A separate same-compiler replay uses fixed frame times to compare allocations against the class build in each scenario.
The corresponding class totals were 8,656, 15,688, 8,656 and 8,656 respectively; none of the 120 frames in any
scenario allocated more objects than its corresponding class frame.

#### Implemented: optional field-to-field copies

Nullable value copies remain explicit in the typed tree until the destination is known. A direct field-to-field copy
snapshots the source presence flag and every flattened leaf before writing the destination slots. Owner expressions run
in source order, and source and destination null errors occur at their original accesses. This preserves nested optionals,
managed references, side effects, and overlapping or identical places. Other copies keep their boxed representation.

This removes the paired allocations in the optional clip getter and its copy caller.

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

Value joins are split before selecting the scalar call ABI. Eligible read-only fresh receivers, direct closures,
branching and nested value constructors, native-layout optional values, and structural equality and hashing can also
remain scalar. Receiver aliases retain writeback semantics; narrow native stores retain truncation and Float32 rounding.
Dynamic, reflective, native and otherwise unsupported boundaries retain the boxed ABI.

The cross-target tests exercise present and absent values, nested managed fields, aliases, side effects, typed closures,
recursion, exceptions and reentrancy, as well as allocation bounds. They run on HashLink, Wasm32 and Wasm GC with and
without inlining.

### Dynamic fields holding values

The UI style pipeline stores known types in declarations, computed styles and transitions, using per-kind typed
implementations. `Dynamic` values are materialized for inspection, debugging
and reflection. This removes avoidable erasure and the temporary inline-axis and cached local-snapshot boxing paths,
without a compiler transformation that would have to preserve dynamic access, reflection, identity, mutation, exception
order and native escape. A same-machine 30-cycle HashLink census after initial setup found no allocations of the five
value types in interaction, tab matrix or selection stress; see [UI value types](../packages/ui/docs/VALUE_TYPES.md).

Generic owners and functions specialize for struct type arguments, providing unboxed `Array<S>`, `Map<K, S>`,
`State<S>` and typed closures. This also enables later replacement of per-kind declaration implementations with
`StyleValueOf<T>`. Interface bounds dispatch statically for each specialized struct, without boxing; an
interface-typed value remains a boxed dynamic boundary. Equality and hashing are compiler-known capabilities declared
through `Equatable` and `Hashable`, so bounds such as `Map<K:Hashable, V>` are checked at compile time. This remains
separate from the stage 0 UI migration. The specialization policies and escape boundaries are documented in
[GENERIC_SPECIALIZATION.md](GENERIC_SPECIALIZATION.md).

## Representation on Wasm GC

Wasm GC cannot embed one struct type inside another, so the backend recursively flattens struct fields into their holder.
It specializes methods on field places, preserving intermediate writes visible to callbacks, and represents nonescaping
values with scalar locals, including across exception handlers. Direct calls and eligible typed closure and virtual calls
pass scalar parameters and return multiple values. Scalar receiver methods return their updated fields even on a Haxe
exception, before the original exception is rethrown. Narrow fields retain their stored-width behaviour. Dynamic,
external and other reference-representation boundaries still materialize boxes when required. Eligible optional locals
use scalar components as described above; array elements retain their boxed representation. Native-memory operations
continue to use linear memory.

The inline array representation uses one scalar lane and, only when needed, one traced reference lane. Scalar
fields are interleaved per element in 32-bit words when their stored widths permit it, and in 64-bit words otherwise;
reference slots have their own fixed per-element stride. Nested values are expanded, including presence flags and
payloads for optionals. HashLink uses the same split so its collector scans references without interpreting scalar bits.
The array and its lanes own their storage; an element place retains the array and index, not a pointer that growth could
invalidate. Growing an array of non-null structs can leave slots unwritten; a validity bitmap in the scalar lane keeps
those slots distinct from initialized values. Nullable struct elements use their existing presence flag. The bitmap is
stored after the payload within the same allocation, and growth relocates it when capacity changes. A mutating method
called on an element place accesses its fields through the retained array and index, so callbacks see completed writes,
growth cannot strand a write in an old allocation, and writes made before an exception remain visible.

A flat value retains its C field offsets, internal padding and exact byte stride within the scalar lane. That stride
need not divide a lane word: consecutive three-byte records, for example, can start in different parts of a 32-bit
word. Reads and writes therefore handle fields crossing word boundaries; padding remains zero. A flat value nested in
a managed struct retains its C alignment and padding inside that struct's scalar portion. Native-memory copies use the
same bytes.

Lane classification follows each target's actual representation: for example, a native callback is a traced managed
handle on HashLink but a scalar function-table index on Wasm. Both use the same two-lane scheme without treating a
HashLink-managed pointer as untraced data or boxing the Wasm index.

The Wasm GC type plan represents an inline value array as a subtype of the shared array wrapper, preserving an
`Array<Dynamic>` view's identity. Its inherited data field holds the scalar lane, or the reference lane if there are no
scalar words; an additional nullable field holds the reference lane when both are needed. This permits one-lane values
without an empty second backing array. For mixed values the reference lane is allocated on the first non-null store;
null reads, stores and clears do not allocate it. Generated dynamic bridge closures are shared between arrays of the
same shape. The plan reserves `i32`, `i64`, and nullable `anyref` lane types only in modules that use the value-array
allocator.

The Wasm GC array rewrite has been exercised through the frontend and backend with packed values,
nullable elements, managed references, growth and collection operations. On this machine, an instrumented 100-element
push-and-iteration test counted 14 Wasm GC objects for scalar values and 25 for nullable values with a managed reference;
the counts include array growth and shared bridge closures. The scalar test counted 214 before generated element helpers
were included in the scalar call ABI. These are compiler tests, not editor or Showcase measurements. The rewrite is
enabled in the normal compilation pipeline.

The same instrumented 100-element tests count 11 allocations on Wasm32 and 14 on Wasm GC for struct elements with
nullable scalar fields, nullable struct elements, and alternating `pop`/`shift` removals. A lookup test performs 5,050
handwritten equality calls with the same counts. Non-escaping nullable scalars flow as a presence flag and scalar
payload through joins; a Dynamic escape still materializes the required box. Generated element boundaries and scalar
call arguments are lowered independently of the inlining setting.

Compiler-generated reference-slot accesses use an internal lane-reference carrier, separate from Haxe `Dynamic`.
Packing and unpacking the carrier preserve the reference itself: HashLink reinterprets the traced pointer, Wasm32
preserves the linear-memory address, and Wasm GC checks the exact reference type on extraction. The verifier confines
the carrier to lane operations, so an unboxed native handle cannot accidentally be treated as a Dynamic box. Wasm GC
rejects a scalar handle in this path; its lane layout stores those handles in the scalar lane instead.
The slot-access emitter uses the planned byte offset, width and signedness for scalar leaves and the reference-slot
index for managed leaves. It does not allocate a temporary value, and it leaves element growth, initialization and
optional-ancestor checks to the enclosing array-place operation. Generated place helpers take the array and index on
every access; their checks distinguish assigning an optional field from dereferencing that field. The place lowering
must invoke those checks before evaluating later operands.
When a method reads a nullable scalar from an element, it captures the presence and payload at that read. Both values
flow separately through control-flow joins, so a later callback cannot change the snapshot and no nullable box is needed.
For a value copied between two places in one element, the method rewrite reads every source leaf before writing the
destination leaves. This keeps self-copy and overlapping projections well defined, including nested optional flags and
references. Constructed values and value arguments, including nullable scalar fields, are split into scalar fields before
the lane writes.

When a lane-backed array is viewed through `Array<Dynamic>`, the view keeps the same array identity. Its dynamic reads
materialize a value, and writes check the element type before changing the array and copy the value into the lanes.
HashLink's array header carries shared type-specific read, write and type-check accessors for this boundary; copies retain
the same accessors. The compiler must share these accessors per concrete element layout, rather than allocating closures
for every array or element. Empty HashLink value arrays allocate their backing lanes on the first write, avoiding the
working-set cost of reserving storage for arrays that remain empty. Ordinary typed accesses do not call these accessors.
An unwritten slot of a non-null value array reads as null through a dynamic view, matching existing dynamic-array behavior.

Explicit typed iterators retain the array and an index, and read values through the lane accessors. Their generated
structural adapters use the scalar value calling convention, so iterating does not allocate a box per element, even
with inlining disabled. Dynamic iteration and reflection materialize a value at the escape. HashLink array string
conversion uses the array representation's read accessor, including for arrays nested in other arrays; it must not
interpret the scalar lane as a contiguous array of object pointers. Allocation tests count zero allocations for 8 and
1,024 typed reads on HashLink, Wasm32 and Wasm GC in both inlining modes.

On the same machine as the original value-struct baseline, the iterator safety fix preserved the four tab-switch
allocation medians at 112.6, 78.1, 74.5 and 92.9 KiB. Nine paired interaction captures with the previous and current
native libraries matched on every action; hover-field was 12.4 KiB in every capture. The 30-cycle selection census
counted 342,096 allocations, versus 342,877 at the original baseline. Wasm GC Showcase counts for full, static,
text-heavy and editing were 5,896, 5,896, 5,896 and 12,622, respectively (original: 5,896, 5,896, 5,896, 12,835).
Nine paired 500-cycle captures using the same editor bytecode and the previous/current native libraries had median RSS
window growth of 30.00/4.06/0.78/4.84 MiB and 30.00/3.91/0.78/4.84 MiB. Their median paired first-window delta was
+0.15 MiB; an identical-runtime control had a +0.31 MiB paired median, so the difference is within observed variation.

A dynamic array that is later checked as `Array<S>` may already have aliases to its original header. On HashLink the
conversion builds and validates a lane descriptor before changing that header, then keeps the header as a forwarding
handle to the descriptor. Its length and capacity track the descriptor across growth and shrinking. This extra
descriptor is only needed for the dynamic conversion; an array created as `Array<S>` directly owns its lanes. A failed
conversion leaves the dynamic array and its aliases unchanged. Native-created arrays with boxed struct storage use the
same conversion: HashLink's raw struct pointers acquire a temporary Dynamic wrapper while the fields are copied.

The Wasm GC prototype uses a one-element forwarding lane in the original wrapper when converting ordinary dynamic
storage. The lane points at the inline descriptor, which in turn retains the original header and synchronizes its
length. Validation and descriptor construction precede publishing the forwarding lane. Directly created inline arrays
do not allocate a forwarding lane. Frontend tests cover dynamic aliases, growth, iteration, insertion, copying, reversal,
resizing, and a rejected conversion; native boxed struct arrays are converted at the dynamic boundary.

The Wasm32 prototype reserves an extended array header for inline values. Its scalar backing is untraced; its separate
reference backing is traced using the element count times the reference stride. Bridge closures and a forwarding header
are also traced. Ordinary arrays retain their existing header. A standalone Wasm32 test exercises packed scalar and
reference-slot reads, writes, clears, bounds checks and initialization bits. The allocator and growth operation have
also been exercised under forced collection, retaining a reference reachable only through the array and relocating the
validity bitmap. Frontend-rewritten fixtures also exercise insertion, resize, copy, slice, concat, splice, reversal,
nested fields and managed references under forced collection. Generated element boundaries are expanded as mandatory
lowering before scalar replacement, independently of user-controlled inlining. A 100-element push-and-iteration census
falls from 211 allocations to 11 for scalar values and counts 22 for nullable values with a managed reference. A converted
dynamic array keeps its original header as a forwarding handle; the descriptor synchronizes its length and traces both
headers. Frontend tests exercise dynamic aliases, collection operations, nullable references and rejected conversions
under forced collection. Normal compiler integration and the cross-target parity gates cover these paths.

The generated HashLink bridge has been exercised through dynamic reads and writes, including nested nullable structs
and reference clearing. Dynamic writes and insertions currently stage the converted element in a temporary lane array
before changing the destination, so a conversion exception cannot expose partial writes. These temporary allocations
occur at dynamic escapes; typed element access uses the lanes directly.

`copy`, `slice` and `concat` on a concrete struct array lower directly to lane range operations. The targetless IR
interpreter implements the same independent value-copy semantics for these operations in its own representation;
portable IR no longer contains a generated per-element copy loop or a pass to remove one.
Allocation tests copy, slice and concatenate arrays of 8 and 5,000 managed-reference values on HashLink: both sizes
allocate nine objects and no value boxes. The corresponding scalar-array test allocates six objects for 8 or 1,024
values on Wasm32 and Wasm GC, with inlining both enabled and disabled; all three results remain independent copies.
A specialized generic function performing the same three operations on structs with a managed reference allocates
nine objects for either 8 or 1,024 elements on each Wasm target. A HashLink census records nine arrays plus the census
dump's byte buffer for both sizes, with no struct boxes; the allocation count does not grow per element.

On the same machine, the 30-cycle HashLink selection census fell from 342,877 allocations to 342,351. The nine-run
median RSS growth windows were 30.47 / 4.06 / 0.94 / 4.69 MiB at the original baseline and 30.00 / 3.75 / 0.94 /
4.84 MiB with lazy lanes. A same-checkout pre-array control measured 30.00 / 3.75 / 0.94 / 4.84 MiB; its last window
matches the inline-array result. Eagerly allocating lanes for empty arrays raised that last median to 5.47 MiB, which
is why the runtime waits for the first write. A fixed-time, 120-frame Wasm GC Showcase comparison counted 5,896 objects
for each of full, static and text-heavy, and 12,835 for editing, both before and after the array change. Browser
requestAnimationFrame runs varied with frame intervals, so the fixed-time comparison keeps the scenarios identical.

The editor's per-action HashLink allocation medians, in KiB, were:

| Action | Baseline | Inline arrays | Current compiler |
| --- | ---: | ---: | ---: |
| hierarchy → sensors | 114.6 | 112.6 | 112.6 |
| sensors → hierarchy | 80.1 | 78.6 | 80.1 |
| console → telemetry | 74.5 | 74.5 | 74.5 |
| telemetry → console | 92.9 | 92.9 | 92.9 |
| hover enter / inside | 0.5 / 0.5 | 0.5 / 0.5 | 0.5 / 0.5 |
| hover other / field / away | 10.0 / 12.4 / 13.6 | 10.0 / 12.4 / 13.6 | 10.0 / 12.4 / 13.6 |
| scroll inspector | 21.2 | 21.2 | 21.2 |
| idle / idle focused | 0.2 / 0.2 | 0.2 / 0.2 | 0.2 / 0.2 |
| type character / backspace | 16.1 / 16.6 | 16.1 / 16.1 | 16.1 / 16.2 |

A subsequent same-checkout comparison of the generic-owner work measured 342,352 selection allocations with both the
committed and modified compilers. Nine alternating 500-cycle RSS runs gave median growth windows of
30.31 / 3.75 / 0.78 / 4.84 MiB for the control and 29.84 / 3.75 / 0.94 / 4.84 MiB for the modified compiler. The third
window is 0.16 MiB higher; the original recorded baseline and the modified result are both 0.94 MiB. A separate
nine-pair same-binary control produced median differences of up to 0.31 MiB in other windows, so this measurement
cannot establish an exact RSS match. The 500-cycle allocation census counted 1,827,398 control allocations versus
1,827,404 modified allocations, while the modified run allocated 129,336 fewer bytes overall; the six extra allocations
were byte arrays. Further work must retain this evidence when evaluating memory changes.

After generic owners, the specialized map and direct array range lowering, the 30-cycle selection census recorded
342,111 allocations (the starting baseline was 342,877). In nine alternating 500-cycle runs, the committed control's
median RSS growth windows were 29.84 / 4.06 / 0.78 / 4.84 MiB and the new compiler's were 29.84 / 3.91 / 0.78 /
4.84 MiB. The original baseline was 30.47 / 4.06 / 0.94 / 4.69 MiB. The last window remains 0.15 MiB above that
original measurement but matches the paired control; the earlier same-binary paired control varied by up to 0.31 MiB,
so the measurements do not establish an exact match to the original. The headless memory gate passed all three runs.

After preserving inlined receiver checks, five alternating 100-cycle interaction runs measured the same 12.41 KiB
median for hover-field on control and current. Nine alternating 500-cycle runs measured RSS windows of
30.31 / 3.75 / 0.78 / 4.84 MiB for control and 30.16 / 3.75 / 0.78 / 5.00 MiB for current. The last-window
difference is smaller than the earlier 0.31 MiB same-binary variation and does not establish an RSS change. The
selection census remained 342,111; the fixed-time Wasm GC object counts remained 5,896 for full, static and
text-heavy and 12,835 for editing.

With the final generic map, state and closure work, the 30-cycle selection census recorded 342,112 allocations. Five
alternating 100-cycle interaction runs matched at the displayed precision, including 12.41 KiB for hover-field. Nine
alternating RSS runs measured 30.00 / 3.59 / 0.78 / 5.00 MiB for control and 30.16 / 3.59 / 0.78 / 5.00 MiB for
current; the 0.16 MiB difference in the first window is below the earlier 0.31 MiB same-binary variation. The fixed-time
Wasm GC Showcase remained at 5,896 objects for full, static and text-heavy, and 12,835 for editing.

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

The compiler-generated `$haxeonObservableState` on an `Observable` class is a runtime
subscription handle, not a model field. It is omitted from wire codecs, public
reflection, equality, hashing and `Diff` field numbering. A wire round-trip of
an Observable record therefore has the same bytes and public fields as the
record without tracking. The source is allocated when the object is first read
in a tracking scope; ordinary construction and untracked access do not need it.

This compiler-owned hidden field is distinct from the proposed annotation
mechanism below, which controls source visibility by build context.

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
- Port every use of the old forms in the same change and remove them.
- **One semantic change:** equality on former value classes follows declared `Equatable` conformance. Audit existing
  comparisons before the change lands.

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

- **Fixed-array syntax.** `Int32[4]`, or a type such as `Fixed<Int32, 4>`,
  which would need integer generic arguments?
- **HashLink layout.** Does HashLink's inline layout for value structures
  already agree with `HxiAbi` for every flat field type? If not, the compiler
  has to insert explicit padding fields when it lowers flat structs inside
  GC objects.
- **Generic structs.** Value classes don't support generics yet. Deferred
  until a concrete need, such as a fixed-capacity ring buffer.

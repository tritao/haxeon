# Generic specialization invariants

Generic calls retain their semantic type arguments while emitted bodies use a deterministic representation chosen per parameter.

- `shape` shares a body when a parameter occurs only in ABI-erased positions.
- `layout` keeps the concrete type when it appears inside arrays, maps, functions, nullable values, anonymous records, or applied types.
- `constrained` keeps the concrete type so constrained operations and dispatch remain valid.

An unconstrained struct argument also uses `layout`, including a struct with managed references that has no native
layout. Its fields and value calling convention depend on the declared struct, so two different structs do not share
the erased reference body even when their current fields have the same shapes. Ordinary class arguments continue to
share the `shape` body unless a constraint requires their concrete conformance. Generic owners with struct arguments
also specialize their stored fields and methods, as described below.

With inlining disabled, a managed `struct` with a null reference field passed through `identity<T>(value:T):T` allocates
zero times for 1,024 calls on Wasm GC and 2,048 times on Wasm32. The equivalent class allocates 1,024 times on either
target. Those numbers describe the earlier function-only checkpoint. The shared Wasm scalar-result ABI now keeps value
lanes in locals on both targets. A regression test keeps a non-null managed object in the value and passes it through
instance and static typed closures: both Wasm targets allocate zero objects for 8 and 1,024 calls, with inlining on
and off. The Wasm32 test also uses stress GC to check that the reference lanes stay live.

The initial editor measurement after this policy change reported 12.6 KiB for `hover-field`, versus 12.4 KiB at the
starting baseline and in a build made with the committed pre-change compiler. In matched 60-cycle allocation censuses,
both builds recorded 533,935 allocations and identical instrumented action medians. Two alternating pairs using the
same uninstrumented capture path measured 12,704/12,712 and 12,704/12,704 bytes for control/current respectively.
This evidence is consistent with capture accounting variability; the source of the initial 224-byte difference is not
established, and it does not justify a lower budget ceiling. An isolated census of the hover-other/hover-field sequence
recorded 101,358 allocations in each build with equal per-action medians; total allocation sizes were 8,109,824 bytes
for control and 8,109,608 for current, with the entire difference in byte buffers.

The same-machine selection-stress census was 342,354 allocations, compared with 342,877 at the starting baseline.
The 120-frame fixed-time Wasm GC Showcase counts were 5,896, 5,896, 5,896 and 12,835 for full, static, text-heavy and
editing, matching the baseline. In nine alternating control/current 500-cycle headless captures, median RSS window
growth was respectively [30.00, 3.75, 0.78, 4.84] and [30.16, 3.75, 0.78, 4.84] MiB. The original baseline medians
were [30.47, 4.06, 0.94, 4.69] MiB; all captures passed the memory gate. The 0.16 MiB first-window difference against
the paired control is retained here rather than treated as a demonstrated improvement.

The subsequent member-resolution fix measured 342,353 selection-stress allocations and Wasm GC Showcase counts of
5,896, 5,894, 5,896 and 12,835. Its nine paired headless runs had median RSS windows [30.16, 3.59, 0.78, 4.84] MiB for
the preceding compiler and [30.31, 3.59, 0.94, 4.84] MiB for the fix. All runs passed the memory gate, but the first and
third medians are 0.15–0.16 MiB higher in that pairing. A matching 30-cycle allocation census recorded 149,815
allocations in both builds, with the fixed build using 32 more bytes, all in byte buffers; sampled stacks include the
benchmark's JSON timeline serialization. This does not determine the cause of the RSS differences. The original
baseline windows were [30.47, 4.06, 0.94, 4.69] MiB, and the fourth window was 4.84 MiB in both paired builds.
An additional matched 30-cycle census sampled every allocation stack: it recorded 149,816/149,817 allocations and
11,980,904/11,981,160 bytes for control/fix. All differences in byte-buffer stacks were in the benchmark's own
`JsonPrinter` or `HeadlessEditorProfile` string construction; the net 256-byte difference came from serialization.
This isolates the observed allocation difference in that capture, but does not prove the cause of the RSS medians.

The policy label and representation signature are both part of the generated function name and persisted registry
key. Changing policy therefore creates a new identity instead of reusing an incompatible body.

Generated bodies are owned by the module declaring their generic origin. Incremental compilation regenerates them
when a generic body changes and prunes them when that owner becomes unreachable or the specialization is no longer
requested.

Constraints are semantic signatures. Changing a function or owner constraint invalidates dependent callers even when the runtime ABI shape is unchanged.

## Generic owners with value arguments

Owner specialization limits selected representation nesting to 64 levels and its expanded type arguments to 4,096
nodes; arguments erased to a shared shape do not contribute their source type nesting. A request beyond either limit reports `E1028` at the owner declaration, identifying the owner and suggesting polymorphic
recursion. This bounds programs such as
`Box<T>.wrap():Box<Box<T>>` whose specialized methods would otherwise enqueue owners without reaching a fixed point.
Recursive anonymous records are visited only once on each active path, so their cycles do not consume the limit.
The limits apply to one owner request, not to the total number of independent specializations.

For the 2026-11-03 editor check, adding the limit left the headless bytecode byte-for-byte identical. Nine paired
30-cycle selection censuses had medians of 342,097 and 342,098 allocations (paired median difference zero). Nine
paired 500-cycle RSS captures had control/candidate window medians [29.84, 3.59, 0.78, 5.00] /
[30.00, 3.75, 0.78, 4.84] MiB and paired median differences [0.00, -0.16, 0.00, 0.00] MiB. Wasm GC Showcase
full/static/text-heavy/editing counted 5,896 / 5,894 / 5,896 / 12,620 objects, within the previously measured
2-object variation. Per-action allocation medians were unchanged.

After restricting the guard to selected representations, the editor bytecode was still identical. A further nine
selection-census pairs had equal group medians of 342,097 and a paired median difference of +1 allocation. RSS group
medians were [30.62, 3.59, 0.78, 5.00] / [29.84, 3.91, 0.78, 5.00] MiB, with zero paired median differences in all
four windows. One unpaired sensors-to-hierarchy sample measured 78.4 KiB versus the earlier 78.1 KiB median; both
occurred in earlier pairs of identical builds. The remaining action allocations matched the preceding medians. The
final Wasm GC Showcase counts were 5,896 / 5,896 / 5,896 / 12,622 objects in the same scenario order.

The compiler specializes generic class owners for concrete struct arguments and retains the source owner identity
through erased views. Typed fields, methods, inherited owners, constrained calls, and typed closures use the concrete
layout; converting a struct to an interface creates a value-copy box at that boundary. Incremental builds retain
specializations used by unchanged callers and retire unused layouts. HashLink, Wasm32 and Wasm GC scalarize supported
typed closure calls; conversion to or from Dynamic uses a boundary adapter. The generic map described below replaces
the earlier compiler-generated hashable-map object.

Wasm closure boundary lowering closes the dependency graph of generated bodies before planning signatures and table
slots. Escape and restoration helpers can introduce further function casts, including a class callback parameter
of a struct-taking function. Those casts receive the same checks and varargs adapters as source casts. Generated
helpers are memoized and processed once; Wasm32 and Wasm GC reuse one varargs adapter per semantic target signature.
The `scalar-closure-nested-callback` fixture covers this combination and a variadic factory returning a callback.

HashLink also bridges ordinary functions whose nested callback arguments or results
use scalar struct carriers. Whether the outer function itself can use scalar
arguments is independent of whether its callback needs a Dynamic boundary adapter.
Restoration preserves that outer ABI, erases nested callbacks before crossing the
Dynamic boundary, and restores function results to their physical signature.
The same fixture covers a boxed outer struct call with a struct-taking callback
and a variadic factory returning that callback, with inlining off/on. Previously
the former threw `Can't cast (dynamic (dynamic)) to (void (i32,Anchor,ref<i32>,ref<Anchor>))`
on HashLink. Ordinary typed calls retain their allocation-free carrier ABI.


The UI snapshot regression was introduced by `ac5c2f79`; its parent `9e4819ae` compiles the fixture, while
`ac5c2f79`, pre-cleanup `aed2c2db`, the cleanup merge `ba9a332e` and `efd3a87d` report
`Unknown Wasm function "__haxeon_varargs_adapter_Function([Obj(haxeon.ui.Canvas)],Void)"` on Wasm GC.
Reverting only Canvas's cleanup port also reproduces it. The generated scalar escape wrapper added that callback
cast after the initial varargs scan. `scripts/test-wasm-gc-parity.sh` now runs
`packages/ui/tools/test-value-snapshot-parity.sh` on all three targets with inlining enabled and disabled. The ten
other UI scripts exercise HashLink; the Showcase uses a different reachable graph and did not cover this fixture.

Wasm exports that accept or return a scalar struct closure adapt it at the host boundary. The internal closure keeps
its scalar calling convention even when the same signature is exported: a 1,024-call typed loop allocates no objects
on Wasm32 or Wasm GC, and exported closure arguments and results round-trip through the host. Without the boundary
adapter, merely exporting the signature forced the loop to allocate once per call on Wasm GC.
A matching escape or restore adapter unwraps to its stored closure, so a typed-to-Dynamic-to-typed round trip preserves
closure identity and repeated round trips do not accumulate adapter frames. The inverse round trip preserves a genuine
Dynamic closure as well. The runtime receiver query matches the compiler-generated adapter target before exposing its
environment; arbitrary closure receivers are not treated as adapter environments. HashLink uses a static closure marker,
Wasm32 uses its tagged static target, and Wasm GC resolves the generated target slot directly without allocating a
marker closure. After initial setup, recognizing an existing adapter allocates zero objects on all three targets.
An unobserved `Signal<S>` holding an immutable struct with a managed reference also performs 1,024 distinct updates and
reads without allocation on HashLink, Wasm32 and Wasm GC; the Wasm tests cover both 8 and 1,024 updates and both
inlining modes. `packages/ui/tools/test-struct-allocations.sh` checks the same workload through a real
`State<S>` and `StateStore` on all three targets, including managed-reference identity and both inlining modes.

The semantic identity of a generic class remains its source declaration and type arguments. Its physical owner is
specialized when an argument needs a struct layout or raw-pointer carrier; every stored field, constructor, instance
method and inherited generic base must use that same substitution. Other arguments follow the existing shape, layout
and constrained policies; an unconstrained owner with no value or raw-pointer argument keeps its current shared
representation. Specialization identities include the exact value arguments and the representation policy, so
distinct structs cannot silently share an incompatible layout.
Static fields belong to the source declaration and are not duplicated by a
specialization. Discover specializations to a fixed point, including those requested by generated method bodies, and
retain and invalidate them with their declaring module and the value layouts they depend on.

A generic owner with a constrained parameter is specialized for each concrete constrained argument even when it is a
reference or scalar. Its instance bodies are templates checked with the selected substitutions, so operations such as
`Hashing.hash(key)` and declared equality resolve to the static conformance instead of attempting to hash `Dynamic`.
This also lets the same ordinary generic map handle value and reference keys without a compiler-generated map object.
Boxed generic enums require the full semantic type arguments in their canonical runtime type descriptor, even when
multiple specializations share one physical payload layout. An `Array<E<T>>` can be viewed through `Array<Dynamic>`
after it has been populated, and an enum case may contain no `T` payload from which to infer the type. Generic bodies
that construct or erase `E<T>` therefore retain the concrete enum specialization under the layout policy; generic owners
whose fields or instance signatures contain `E<T>` likewise specialize the relevant parameter even when it is a reference
type. They must not collapse it to the nominal enum or infer it from a payload. The descriptor is shared per concrete type and the existing
boxed enum carries it without a separate per-value allocation or side table. Inline enum storage uses the concrete
static layout; conversion to Dynamic, reflection, or a native boxed representation materializes the corresponding
runtime descriptor at that boundary. Generic enum constructors without a contextual enum type do not yet infer their type
arguments from payloads; that existing compiler gap requires a separate fix. A concrete typed binding preserves the
specialization before an erased boundary.

An explicitly erased view of a constructed owner remains a Dynamic boundary. Constructing a constrained owner with
`Dynamic` as the constrained argument is rejected: no concrete conformance exists to select for its instance bodies.

The generic map allocates its dense key, value, hash and bucket arrays on first insertion. An empty map therefore
costs one object, including when its arguments are structs; 128 empty maps allocate 128 objects on each Wasm
target, compared with 1,283 before lazy storage. Empty reads, removal, iteration, copying and clearing preserve
ordinary map behavior. After insertion, it uses dense key, value and hash arrays with an open-addressed integer
bucket array. A removal moves the
last dense entry into the gap and updates its bucket, so removed managed references are released and no default value
of `K` or `V` is needed. Tombstones are rehashed before they fill the bucket table, reusing its capacity when live
entries do not require growth. This keeps struct keys and values in the existing inline array lanes and avoids boxing
a hash or bucket index on each lookup. Repeated updates and lookups of maps with struct keys and values allocate zero
objects after setup for 8 and 1,024 operations on all three targets, with inlining on and off. Growing three maps
(struct keys and values, integer keys with struct values, and struct keys with integer values) to 512, 1,024 and 2,048
entries allocated 287, 331 and 384 objects respectively on both Wasm targets. The increments follow backing-array and
bucket growth, rather than allocating an object for each inserted struct. A HashLink allocation census of the same
three-map workload recorded 458, 529 and 617 allocations respectively: three map objects, one byte buffer and arrays,
with no `MapKey` or `MapValue` objects at any size.

**Map-key specialization and floating-point keys.**

The typer chooses the physical map owner once and publishes that choice for IR lowering; lowering consumes the chosen
owner instead of repeating a separate key classifier. Ordinary specialized `HashMap<K,V>` handles supported keys,
including concrete scalar keys and nullable enum keys. A nullable enum retains absence separately
from its case tag, including when a nullary enum uses an integer tag. Payload enums still require `Hashable`.

Hash maps require a reflexive key equivalence. For Float keys, two NaNs are equivalent, positive and negative zero are
equivalent, and all other keys use ordinary numeric equality. This key equivalence does not change IEEE `==` elsewhere.
Hash Float keys by their IEEE bits after canonicalizing every NaN to one bit pattern and both zero signs to zero; the
same bit hashing handles infinities and large finite values without a trapping numeric conversion. The target supplies
an allocation-free bit reinterpretation. The hash used by synthesized `Hashable` values follows the same canonical
Float hashing, and equal keys must always have equal hashes. The compiler-generated Float hash implements this
bit-based rule on all targets; the duplicated arithmetic helpers have been removed. Nullable nullary enum keys retain
their nullable enum representation in the generic map, preserving absence separately from every case; non-null enum
keys can use their existing integer representation. The compiler records the chosen specialized owner against the
source `Map` type, including across incremental compilation, so an explicitly used `HashMap<K,V>` cannot accidentally
change a separate native `Map<K,V>` representation.

Cross-target tests cover Float, Bool, Int64, UInt32, nullable Float and nullable enum keys, custom reference equality,
NaNs, signed zero, infinities and large finite values. Updating and looking up a Float-keyed map of structs allocates
zero objects after setup for 8 and 1,024 operations on HashLink, Wasm32 and Wasm GC, with inlining on and off.

An explicitly erased `G<Dynamic>` view is a real Dynamic boundary. It must refer to the same generic object as its
concrete source: reads materialize values for Dynamic, writes check and copy them back to the concrete field, and
identity, aliases, exceptions and inherited dispatch remain observable. A view cannot be implemented by copying the
owner or by keeping an independently mutable Dynamic field beside the inline field. The normal typed `G<S>` path must
not allocate a box or a per-instance bridge; erasure work belongs at the explicit boundary and its operations.
The representation for an erased owner is the original object reference carried as `Dynamic`. Generated
operation dispatchers test the actual owner layout and call its physical field or method, checking and copying a struct
payload at the boundary. They preserve identity without a wrapper and need no additional storage in ordinary instances.
Numeric erased writes require the exact runtime kind: Int, Float, Bool and Int64 are distinct, including nullable
values. In particular, a Dynamic Float cannot be truncated into an Int field, and a Dynamic Int is not implicitly
widened into a Float field at this boundary. A rejected write leaves the existing field unchanged. Typed numeric
conversions retain their normal rules. String, enum and interface writes likewise check their runtime type before
changing storage and permit null. Array writes check the array kind and the concrete element storage before the
store; a Dynamic array can be validated and retyped in place, while mismatched scalar, reference and struct-lane
layouts are rejected without changing the destination. Function writes check the closure's arity and recorded
signature before the store. HashLink and Wasm GC retain semantic function signatures; a scalar struct closure crossing
Dynamic is recognized by its signature-specific adapter without boxing its ordinary typed calls.

Wasm32 records the semantic signature separately from the calling representation. A static closure refers to a shared
immutable module descriptor containing its function slot and signature; a bound closure keeps the signature in its
existing header. A Dynamic cast to another signature creates a checked adapter, including when both signatures use the
same machine representation. This keeps distinct views distinct while a matching cast and ordinary typed calls do not
allocate. The module interns full semantic signatures to distinct identifiers, avoiding hash collisions. Array value
bridges and reflection use the same static descriptor representation as ordinary calls.

After literal warmup, 8 and 1,024 matching static and bound closure casts and calls allocate zero objects on Wasm32 and
Wasm GC with inlining on and off; HashLink's allocated-byte counter likewise stays unchanged. The two Wasm GC objects
used to materialize the first string literals occur in both the control and candidate before warmup.

Managed byte buffers and native map abstracts check their runtime kind too. Wasm32 gives strings and managed bytes
distinct type ids in their existing headers, including byte views, stream results and native aggregate buffers. Its
iterator header retains the semantic `Iterator<T>` descriptor in an existing word while the collector continues to
scan the common iterator layout. Erased writes therefore reject the wrong byte kind or iterator element type. Wasm GC
and the interpreter also distinguish runtime iterator element types. HashLink's runtime iterator type test still
exposes only the common iterator kind; source-level structural iterator adapters can have stricter checks. HashLink
currently lowers every `Iterator<T>` type value to one abstract type, and the underlying array's physical element
type cannot distinguish nested semantic shapes such as `Array<Int>` and `Array<String>`. Exact checks there require
carrying an interned semantic descriptor through iterator construction and erased type tests without enlarging the
iterator allocation; deriving it from the physical array alone would accept mismatched nested shapes.

The header changes add no allocations: in paired Wasm32 and Wasm GC censuses with inlining on and off, creating 8 /
1,024 escaped iterators used 8 / 1,024 objects on each side. Allocating 8 / 1,024 managed byte buffers used 8 / 1,024
objects on Wasm32 and 16 / 2,048 on Wasm GC, unchanged from the control.

Raw pointers specialize generic owners and functions to their scalar pointer representation and remain unboxed in
typed code. At a genuine Dynamic escape, each Wasm target uses a distinct pointer box, preserving null and checking
the kind on unbox; an Int cannot be written through an erased view of a concrete pointer field. Dynamic pointer boxes
compare their contained addresses, including null. Erased generic interface argument and result adapters use the same
checked box. Typed pointer access performs no allocations on HashLink, Wasm32 or Wasm GC, with inlining on or off. A raw-pointer box
is a GC leaf: on Wasm32, a managed object is reclaimed even when its address is held as a raw pointer.

Typed generic interface calls and bound methods retain their semantic argument and result carriers. The compiler
generates a typed dispatch entry for each used interface method signature, calls the matching implementation with its
physical carriers, and keeps struct leaves in scalar and reference slots. Generic implementors specialize scalar
carriers where an inherited interface requires them. A struct converted to an interface is boxed at that conversion;
calls through it retain the boxed receiver as a mutable place. Erased interface views and reflection continue to use
checked Dynamic conversions.

Casting an existing interface view back to its concrete struct copies scalar and reference leaves through the same
result ABI. The generated interface-unbox helper participates in scalar argument/result lowering; inspecting its
result does not create another value box. The interface's original box remains the genuine escape allocation.
`struct-interface-unbox-census` keeps a managed reference live across collection and checks both leaves. With
inlining enabled and disabled, 8 / 1,024 casts allocate 0 / 0 objects on HashLink (unchanged), and 0 / 0 on Wasm32
and Wasm GC (previously 8 / 1,024 on each). The Wasm parity gate checks those allocation counters directly.

With inlining enabled and disabled, the cross-target census performs 8 and 1,024 calls with zero allocations for
`hl.Bytes`, `Int`, `Float`, and a struct containing an `Int` and a managed reference, through both concrete and generic
implementations. This includes a `PointerSource<hl.Bytes>.get()` result, struct interface receivers, and captured
methods. On Wasm32, the pointer getter previously allocated 1,024 times per 1,024 calls (the earlier pre-pointer-box
compiler allocated zero); it now allocates zero. A paired HashLink argument-and-result census over 1,024 calls changed
from 0, 16,384, 32,768 and 81,920 allocated bytes respectively for those four carriers to zero for each.

A separate owner-policy gap remains when a reference field's type argument uses a shared shape: its physical field is
`Dynamic`, and the erased setter has no semantic type descriptor with which to reject a mismatched value. For example,
`Box<Anchor, String>` accepts an Int through `Box<Dynamic, Dynamic>`. Giving that owner an `Array<T>` field forces a
concrete layout and makes the setter reject the write. The owner must retain enough semantic type information to check
shape-erased fields without conflating it with the pointer box representation.

The descriptor cannot be recovered solely at the owner allocation: in
`make<T>(value:T):Dynamic { return new Box<Anchor,T>(new Anchor(1), value); }`,
the shape-shared body has already replaced `T` with `Dynamic` before lowering the
allocation. Both this factory and a plain `Box<String>` accept an `Int` through
an erased view on HashLink, Wasm32 and Wasm GC. The remaining runtime change must
carry semantic descriptors through shape-shared function and method calls,
forwarding and captured closures, and retain them on the owner for checked
erased writes. It must preserve shared code and typed-call allocation counts;
deriving a descriptor from the physical field or only from a direct construction
would leave the factory case unsound.

Native callback handles and runtime type handles have distinct Dynamic representations. Typed Wasm calls retain
their unboxed word carriers; a callback or type handle is boxed only at a Dynamic boundary, and recovery checks the
handle kind. HashLink compares erased callback handles by their underlying value. With inlining enabled and disabled,
8 and 1,024 typed callback calls allocate zero times on Wasm32 and Wasm GC before and after the change; the paired
HashLink census allocates zero bytes on both sides.
On Wasm32, the collector treats both boxes as leaves: a numeric handle that happens to equal a managed object's
address does not keep that object alive. The GC-stress regression covers callback and type handles, as well as raw
pointers, and exercises callback boxes with inlining both enabled and disabled.

A closure in a specialized generic field carries a struct's scalar and traced reference leaves through its typed
argument and result. In a Wasm GC census, the apparent 16 / 2,048 allocations for 8 / 1,024 calls came from evaluating
a string literal in the loop: its byte array and string wrapper were rebuilt on every iteration. Immutable literals
are now rooted and reused per module. A previously unseen literal allocates its two objects once; after setup, the
managed-reference struct closure performs 8 and 1,024 calls with zero allocations on all three targets, with inlining
on and off.
These dispatchers must cover inherited members, captured methods, reflection and exceptions on all targets; generic
owners are not complete until those paths and incremental invalidation are tested.
Reflection reads copy a value out of its specialized field, and writes check the supplied payload before changing the
field. The cross-target reflection tests cover direct and generic owners, optional payloads, null and invalid writes,
reference identity within the copied value, and both inlining modes.

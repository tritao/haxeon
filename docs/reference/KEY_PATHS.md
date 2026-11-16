# Key paths

Status: specification with a partial implementation (2026-11-05). The nullable
escaped-value allocation requirement below remains blocked on callable ABI work.
Key paths are
compiler-checked references to stored fields, independent of UI concepts.

## Types and formation

`\T.field` has type `KeyPath<T, V>`, where `V` is the declared type of the
field, and `\T.a.b` denotes the ordered chain from `T` through `a` to `b`.
`T` is a concrete class or struct type, including its type arguments. Each
type parameter of `KeyPath` and `WritableKeyPath` is invariant. Each
component is resolved and checked for accessibility at the expression site,
exactly as in an ordinary field access. Inherited fields resolve to their
original declarations; the path's root remains `T`. Missing, inaccessible,
static, method and computed-property components are errors identifying the
component and reason. A path names declarations, never strings looked up at
runtime. Renames and layout changes require recompilation.
Path types have no public constructor or conversion from strings, integers or
offsets; literals and composition are their checked construction operations.

The root may be qualified and instantiated, for example `\model.Box<Int>.item`.
Without explicit type arguments, the longest leading qualified name resolving
to a class or struct is the root; at least one stored-field component must
follow it. Parenthesize a literal before calling a path operation, for example
`(\Node.width).get(node)`, so operation names cannot be confused with field
components. `\Node` alone is not an identity path.

A final field may be named and read, but its presence makes a write that must
assign that field invalid. Writable literals additionally have the subtype
`WritableKeyPath<T, V>`, which converts to `KeyPath<T, V>` without allocation.
Writability follows ordinary assignment through the whole chain: a final
reference does not prevent mutation of its referenced object, whereas a final
struct component prevents replacement of its value. Restricted write access
is checked at path formation too: a readable field can produce a readable path
where its setter is inaccessible. This distinction is part of the path type,
so an unknown read-only path cannot acquire a setter at run
time. Custom getters or setters are computed-member access and are excluded
even if the declaration also reserves storage. A `Null<S>` field may be the
last component, with value type `Null<S>`; it cannot be an intermediate component. This applies to
all explicitly nullable intermediate types, including `Null<C>` for a class.
Optional traversal and implicit unwrapping are excluded. A class reference in a chain is
followed as an ordinary field access; a null reference has the same behavior as
that access. Paths do not retain a root instance. Constructing a path to a private field is allowed only where that field
is accessible; passing the resulting value is an explicit grant of that path's
operations.

## Operations and places

For `p:KeyPath<R, V>`, `p.get(root)` reads the value with the same copy and
tracking semantics as the corresponding field expression. For
`p:WritableKeyPath<R, V>`, `p.set(root, value)` writes it and returns `Void`.
Calling `set` on a `KeyPath<R, V>` is a compile-time error even if the actual
descriptor happens to designate a writable field. The first argument of `set`
is a compiler-checked writable root place, not a by-value parameter: it is evaluated once, as is the
value, and struct changes propagate back to that place. Evaluation follows
direct-assignment order for a statically known path: evaluate the path, capture
the root place and intermediate receivers, evaluate the supplied value, then
store. For an escaped, non-constant path, evaluate the path, root place and
value first, then traverse the field chain and store. Thus replacing an
intermediate reference while evaluating the value changes the destination of
an escaped write; a known path still targets the receiver captured before that
evaluation. This difference is intentional and does not depend on enabling
the function inliner. If value evaluation
throws, the destination remains unwritten. Exceptions from the field write
preserve the stores and effects of the ordinary write, including a store that
preceded a throwing equality check; no additional copyback is attempted on
failure. The place and every
component needed for the assignment must be writable under ordinary assignment
rules. A temporary struct, final component that must be replaced, or otherwise
non-writable place is rejected with a diagnostic. For a class root, mutating
the object's field does not require reassignment of its reference binding.
These operations do not introduce general `inout` parameters.

`p.then(q)` composes `KeyPath<R, V>` with `KeyPath<V, W>` to give
`KeyPath<R, W>`; types must match exactly and the result is the concatenated
field sequence. Composition observes the same nullable and place restrictions
as a directly spelled chain. Composing two `WritableKeyPath` operands produces
a `WritableKeyPath`; otherwise the result is a readable `KeyPath`. This type
rule is independent of constant folding and never recovers a capability erased
by a readable type annotation. A single chained literal can still be writable
through a final class reference, because that assignment never replaces the
reference itself. Equality compares the root type and the sequence
of resolved field declarations, not physical offsets. Hashing uses the same
identity, so equal paths have equal hashes. Paths support `Equatable` and
`Hashable`; `haxeon.Hashing.hash(p)` supplies the hash. `p.toString():String`
renders the root and field names in source order, for example `\Node.width`;
it is not a serialization format or an
API for resolving a path by name.

## Observable fields

A read or write through a path has the same observable effects as the
corresponding direct operation: tracked reads record the same object and field
bit, and writes perform the same guard, store, equality check and invalidation.
A path ending at a tracked struct-valued field assigns the entire field. For a
path continuing into that struct, a write must perform a tracked whole-field
replacement, preserving single evaluation, guard and exception behavior; it
must not silently mutate the stored struct without invalidation. The current
compiler rejects the equivalent direct nested mutation (see STRUCTS.md). This
case requires compiler place-lowering work to preserve that contract. Until
tracked whole-field replacement exists, writes that would mutate a struct
inside a tracked Observable field are compile-time errors (`E1027`), including
when the root place itself is such a field. A path cannot bypass that existing
restriction. No change to the reactive runtime is intended.

For non-constant composition whose second path may write back a struct, the
compiler must also prove that the first path cannot project tracked struct
storage. A known first path is checked by its declaration sequence; for an
unknown first path the check conservatively examines its root's reachable
stored-field types. A potentially tracked projection is rejected with `E1027`.
Compose a readable `KeyPath` operand for read-only traversal in that case.
This restriction prevents composition from granting a deferred write operation
after the declaration sequence has escaped.

## Representation and lowering

A known path applied to a concrete root lowers to the same direct field
operations as a spelled-out chain, using target-specific offsets or field
indices. Composition of known paths folds before lowering. This is
allocation-free on HashLink, Wasm32 and Wasm GC, with inlining enabled or
disabled; specialization retains path constants when both root and path are
known, including across generic calls.

An escaped path is an immutable compiler-generated descriptor reference. One
canonical descriptor per root type, declaration sequence and granted capability
contains the identity, component metadata needed for display, and typed read/write dispatch
for that sequence; descriptors are shared, not allocated per use. A composed
path whose components are not known statically may allocate a compact
immutable concatenation descriptor once at composition, with equality and
hashing based on the flattened declaration sequence. All dispatch functions
and their environments are created with the descriptor. Neither `get` nor
`set` allocates a descriptor, closure, prepared writer, box or other temporary
object on any target, including when the path escapes and inlining is disabled.
Target-specific typed access functions handle references, struct copies and
tracking; no runtime name lookup or portable byte offsets are used.

The descriptor's typed write function follows the references and stores for a
class root, with no root writeback. For a struct root it returns the updated
root value; the compiler writes it
back to the caller's captured struct place when the assignment reaches that
storage, including when the supplied value compares equal to the previous one.
The descriptor records whether struct writeback reaches the root: following a
class reference breaks that propagation. This avoids an extra tracked outer
field write when the actual mutation is inside a referenced object.
Reference roots keep their identity.
This preserves the caller's writable place rather than mutating a boxed copy.
The descriptor has no setter for a read-only literal; readable and writable
descriptors for the same sequence still compare equal and hash alike. Upcasting
a writable descriptor to `KeyPath` keeps the descriptor and grants no setter
through that readable type. Descriptors and hashes are process-local and are
not stable serialized identifiers.

Allocation censuses must cover escaped `get` and `set` on class roots and on
struct roots in writable places: 1,024 calls allocate zero objects on HashLink,
Wasm32 and Wasm GC, with inlining enabled and disabled. Descriptor construction
and unknown-path composition happen before the measured call loop; the loop
must retain runtime path selection so these tests exercise escaped dispatch.

## Diff integration

`Diff.bit(\T.field)` accepts a single stored-field path rooted at a `Diffable`
type and produces its declaration-order mask bit as a compile-time `Int`.
The path must be statically known; an unknown runtime path is rejected with a
diagnostic requiring a known direct-field path. Inherited fields precede
fields declared in the derived class. A nested path is rejected because the
mask represents the outer field as a unit. The bit is not a byte offset.
For field numbering, `Diff.bit` also accepts an accessor property with stored
backing, such as `@:isVar`; this does not make that property a usable key-path
value or bypass its accessor. Properties without stored backing are rejected.
The previous field-name form has been removed and its callers ported.

## Implementation checkpoint and backend dependency

Formation, capabilities, direct reads/writes, escaped typed dispatch, composition,
identity equality/hash, display and `Diff.bit` are implemented. Constant path
arguments remain constants in generic specializations independently of inlining.
The scalar-value allocation censuses exercise known/generic paths and escaped
class, local struct, static struct and composed nested-struct dispatch on all
three targets with inlining on and off, at 1,024 calls with zero allocations.
Nested mutation of tracked Observable structs remains an explicit `E1027` error.

**The full allocation contract is not yet implemented.** Escaped paths with
`Null<S>` as their final value type use the existing boxed callable ABI. In
`tests/programs/key-path-nullable.hx`, after `NullableKeyPath.prepare()`, calling
`NullableKeyPath.perform(1024)` on Wasm32 with inlining disabled and allocation
counting enabled returns 1024 but allocates 2048 objects. Final nullable fields
remain functionally supported; nullable intermediates remain rejected.

The shared HashLink scalar-closure planner and Wasm scalar callable planner
explicitly exclude layouts containing presence lanes (`IrScalarClosures.scalarizable`
and `WasmScalarAbi.scalarizable`). Meeting the specification requires those ABIs
to carry nullable presence and payload lanes across typed indirect calls,
including forwarding/composed accessors and nullable struct arguments/results.
This is a backend dependency, not a reason to weaken the allocation contract or
introduce a per-call writer. Implementation stops at this checkpoint under the
parallel-work boundary; that ABI work and its allocation regressions must land
before key paths can be marked complete.

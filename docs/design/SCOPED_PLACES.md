# Scoped mutable places

Status: deferred language proposal, not implemented. Beartooth's component API
uses whole-value `get`/`set`/`update` and no longer plans an `edit` built on
this; the proposal needs another consumer to justify it. Proposed syntax introduces
`ref` parameters for mutable struct places and a `@scoped` callback parameter
contract. Parser spelling must be validated in the implementation spike. This
extends [STRUCTS.md](STRUCTS.md); it is not component-specific compiler behavior.

## API shape

```haxe
// Signature sketch, not compiling syntax today.
function edit<T:Component>(@scoped callback:(ref T) -> Void):Void;

entity.edit<Health>((ref health) -> {
    health.value -= 10;
});
```

The callback's `health` denotes the caller's private draft storage, not a copied
argument and not a pointer into ECS columns. Reading it as a value copies T;
assigning it or its fields writes the draft. Calling a mutating struct method
uses the same place as receiver. `var copy = health` creates an independent value;
subsequent writes to copy do not affect the draft. Field/subfield access remains
a place, including nested structs and bounds-checked fixed-array elements.

`ref` is a parameter mode, not a storable reference type. It requires an addressable
mutable place at the call site. A function-return temporary is not such a place;
assign it to a local first. Ordinary value parameters keep existing copy semantics.
`@scoped` on the callback parameter promises synchronous invocation and no retention
by the callee, and requires a non-suspending callback. The compiler verifies both
the callee implementation and caller use. These contracts are part of typed
function signatures and module metadata, not comments erased at separate compilation.

## Escape and suspension rules

A ref parameter cannot be returned as an alias, boxed, stored in an object/array,
captured by another closure, converted to Dynamic, or turned into RawPtr through
addr/casts/FFI. Copying its value into ordinary storage is allowed when T permits
that value operation. Returning a value copy from a ref-taking helper is allowed.
The edit callback itself returns Void, so returning exits the callback normally
and commits; rollback is triggered by failure, not an implicit early return.

Ref places can be forwarded only to synchronous ref-taking helpers whose checked
contracts do not escape them. Call-site checking prevents overlapping mutable
ref arguments in one call, including a struct and one of its fields. Initial
implementation conservatively rejects cases it cannot prove disjoint. This is a
restricted place facility, not a general borrow checker or promise that arbitrary
unsafe native pointers cannot alias.

A scoped callback cannot be saved, returned or forwarded to an ordinary callback
parameter by its callee. It may be forwarded to another checked scoped parameter.
The callback may capture ordinary surrounding values; it cannot capture an outer
ref or another scoped value. An inline callback is the initial supported form;
conversion from ordinary function values is rejected until their contracts can
be proven. This keeps escape checking local and reviewable.

The callback and helpers it calls cannot yield, await or otherwise suspend through
that call chain. Creating an asynchronous task that captures the ref is rejected.
Scheduling work from ordinary value copies does not extend ref lifetime and has
ordinary side effects. Calls lacking a verified non-suspending contract are
rejected inside this scope; dynamic dispatch and externs require trusted declared
contracts, with privileged declarations restricted to engine/library code.
This requires a small transitive suspension analysis, not a general effect system.

## Lowering and runtime boundaries

Type checking records scoped regions, place provenance and non-suspending call
contracts. Lowering emits field loads/stores against the provided draft address.
It preserves normal struct copy, layout and zero-padding rules. Ref is internal
calling-convention information and is not exported as a Portable field type.

HashLink passes an address to draft storage held alive for the synchronous call.
Wasm uses private linear-memory draft storage and checked host acquisition/commit
calls. Neither target exposes a world-column address to creator scripts. Ordinary
struct methods invoked through the place mutate the draft; source semantics are
identical even when scalar replacement changes physical storage.

Compiler checks protect well-typed source; the Wasm host additionally enforces
edit ownership, active scope, entity/component locks, write authorization, bounded
draft size and script cleanup. Commit only after normal callback completion.
Exception, trap, cancellation or script termination releases locks and discards
uncommitted drafts. An untrusted module cannot bypass field/authority rules by
committing arbitrary component bytes. Existing server-only field restrictions
remain in force for both reads and writes.

## Required diagnostics and spike

Reject writes through value temporaries, escaping/captured refs, address extraction,
overlapping ref arguments, retained scoped callbacks and suspension through helper
calls. Diagnostics identify the place or call path and suggest a local value copy
or explicit get/modify/set where appropriate. No compiler knowledge of World,
Component or transactions is needed.

Before implementing Beartooth edit, validate a tiny generic library with its own
local draft, on HashLink and Wasm: nested-field mutation, mutating methods, explicit
copy independence, forwarding and early return. Add negative compile fixtures for
each escape/suspension rule and separate-module contract checking. Verify cleanup
with callback failure and a Wasm trap in host integration. If the required compiler
work expands beyond these restricted rules, keep get/set as the initial creator
API and defer edit rather than ship ordinary copied callback parameters under
mutable-looking syntax.

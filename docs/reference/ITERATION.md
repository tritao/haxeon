# Iteration

`Iterator<T>` is a structural contract with `hasNext():Bool` and `next():T`.
`Iterable<T>` is a structural contract with `iterator():Iterator<T>`.
Classes do not need an `implements` declaration. Inherited methods and
function-valued fields qualify, as do anonymous objects with callable fields.
The methods must accept no arguments; `next()` must return a value.

A single-value `for` loop accepts arrays, maps, ranges, user iterables, and
user iterators. A user iterable's `iterator()` is called once. The source
expression is evaluated once, including for comprehensions. Array and map
comprehensions support the same single-value iteration protocol.

```haxe
function total(values:Iterable<Int>):Int {
    var result = 0;
    for (value in values)
        result += value;
    return result;
}

var counts:Map<String, Int> = ["first" => 2, "second" => 4];
var matches = Lambda.count(counts, value -> value > 2);
```

`Lambda.count`, `has`, `find`, and `exists` accept `Iterable<T>`. Counting an
array without a predicate retains its constant-time length path.

## Representation and allocation

Concrete user-object loops use ordinary typed calls. Arrays retain indexed
loops, and ranges retain counted loops. Generic iterable parameters specialize
on the concrete collection representation, in addition to the element type,
so a generic helper over an array does not allocate an iterator or a protocol
adapter. Parameters that are reassigned or flow into inferred local storage retain the
structural contract instead of being narrowed by specialization. The storage
check is conservative, including read-only aliases.

An erased contract, such as a non-generic `Iterable<Int>` parameter or a stored
`Iterator<Int>` field, is represented by a record of callable fields. Converting
a concrete collection to that contract allocates an adapter record and captured
callables once at the conversion boundary. Calling its `iterator()` can produce
an iterator adapter as well. These allocations are not repeated for each element.
A user-defined `iterator()` may allocate its own iterator independently.

Map iteration keeps the existing snapshot behavior: value iteration materializes
the values before entering the body. This change does not replace that snapshot
with a live cursor. Key/value loops retain the existing array/map paths.

The structural iteration regression checks clean and incremental HashLink,
Wasm32, and Wasm GC execution, malformed protocol diagnostics, and allocation-free
IR for a concrete iterator loop and a generic array loop. Run it with
`tests/integration/test-structural-iteration-wasm.sh`.

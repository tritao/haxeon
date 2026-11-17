# Differential checks

Run `tests/differential/run.sh` with the pinned tools and native runtime built.
The runner compares exit status and exact output. New fixtures also require a
successful reference exit, preventing identical crashes from counting as a pass.

The exception/capture fixtures cover nested typed catches, rethrows, shared
mutable captures, shadowed bindings, independent loop captures, and loop exits
through protected regions. Assignment fixtures log receiver, index, and RHS
evaluation, including mutation of the target, thrown operands, conditional
operands, postfix updates, and replacement of a nested field's receiver.
The `local-inference-*` fixtures cover locals whose type a later use fixes:
an empty array, `var x;`, `var x = null`, `new Map()`, an object literal that
takes the structure of a later typed use, and Ints flowing into a local that
is already Float. The `lazy-*` fixtures cover unannotated fields, whose type is
their initializer's: comprehensions, `map` with a lambda, lambdas, fields read
across classes before their declaration, calls to unannotated and annotated
functions and module-level functions, enum constructors, a generic class's
`new Array<T>()`, and a mixed array both compilers reject. The `lazy-return-*`,
`lazy-argument-body` and `lazy-accessor` fixtures cover unannotated functions,
whose result and arguments are what their bodies give them: several returns
(Float then Int, `null` first, no value return, only a throw), recursion,
returned structures and lambdas, calls between unannotated functions and from
field initializers, arguments fixed by their uses and defaults, accessors of a
typed property, and the return and override mismatches both compilers reject.
`lazy-argument-generic` covers unannotated arguments of a generic class's
constructor and methods and of a static generic function, whose types mention
the declaration's own type parameters, called from a generic and a concrete class.

## Reference exception

`exception-loop-control` uses Haxe 4.3.7's interpreter as its reference. With the
pinned HashLink backend, reference Haxe prints `control:12`; its interpreter
prints `control:14`, agreeing with this compiler. The assignment `total += i`
at `i == 2` must survive the throw. Other runtime fixtures use reference Haxe
compiled to HashLink. The two source files for each new fixture are identical.

## No-return operands

A call inferred as never returning keeps its declared result while it is used
as an operand:

```haxe
function fail():Int { throw "stop"; }
function main():Int {
    var value = 1;
    try { value += fail(); } catch (error:Dynamic) {}
    return value;
}
```

The call has no special no-return opcode in IR. Its runtime throw prevents the
addition, while statement context still seals control flow for a standalone
no-return call. The assignment fixture covers this behavior directly.

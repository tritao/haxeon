# Differential checks

Run `tests/differential/run.sh` with the pinned tools and native runtime built.
The runner compares exit status and exact output. New fixtures also require a
successful reference exit, preventing identical crashes from counting as a pass.

The exception/capture fixtures cover nested typed catches, rethrows, shared
mutable captures, shadowed bindings, independent loop captures, and loop exits
through protected regions. Assignment fixtures log receiver, index, and RHS
evaluation, including mutation of the target, thrown operands, conditional
operands, postfix updates, and replacement of a nested field's receiver.

## Reference exception

`exception-loop-control` uses Haxe 4.3.7's interpreter as its reference. With the
pinned HashLink backend, reference Haxe prints `control:12`; its interpreter
prints `control:14`, agreeing with this compiler. The assignment `total += i`
at `i == 2` must survive the throw. Other runtime fixtures use reference Haxe
compiled to HashLink. The two source files for each new fixture are identical.

## Remaining compiler limitation

A call inferred as never returning is rejected in numeric operands, even if
the function declares an `Int` result:

```haxe
function fail():Int { throw "stop"; }
function main():Int {
    var value = 1;
    try { value += fail(); } catch (error:Dynamic) {}
    return value;
}
```

Accepting its `Never` type alone is insufficient: lowering then tries to emit
an operation after the call's CFG terminator. This needs consistent propagation
of expression termination through operand evaluation. The assignment fixture
uses a throwing function with a possible return path to exercise exceptions
without depending on this unfinished behavior.

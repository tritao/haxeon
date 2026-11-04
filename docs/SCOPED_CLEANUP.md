# Scoped cleanup

Status: design, pending implementation. This is layer 1 of the resource cleanup plan in
[LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md). It does not introduce ownership or move-only values.

## Syntax and registration

```haxe
{
    scoped var file = File.open(path);
    defer lock.release();
    defer { profiler.end(); }
    // use file
}
```

`defer` is a statement followed by a statement or block. `scoped var` is a local binding with a required initializer,
optionally with an explicit type (`scoped var file:Null<File> = open()`). It uses `scoped`, not `using`, which already
means static extensions in Haxe. A scoped declaration introduces one binding; it is not a field, parameter, or loop
header. Its scope and visibility are those of an ordinary local. A defer belongs to its immediately enclosing lexical
block; require braces where no block exists. It is registered only when execution reaches it. A scoped binding registers
its disposal only after its initializer completes successfully. A null initializer registers a no-op cleanup. An
exception from initialization therefore cannot dispose an uninitialized value, but earlier registrations still run.

Each block invocation has its own registrations. On every exit, registered actions run exactly once in reverse order,
interleaving `defer` and scoped declarations. This includes fallthrough, return, break, continue and an exception.
Nested blocks unwind from inner to outer. A loop body block is entered and cleaned up on each iteration, including
`continue` and `break`; a registration outside the loop belongs to its surrounding block. Return values and other
exit operands are evaluated once before cleanup. Deferred statements execute at exit, observing the then-current values
of ordinary locals, rather than snapshots at registration. They may declare their own locals and nested cleanups.

A deferred statement must be valid where declared and type-check as a statement. Its control flow cannot return from
the enclosing function or break/continue to a target outside the deferred statement; internal loops and function
returns in nested functions retain their usual meanings. This avoids replacing an already pending exit with a second
nonlocal transfer. Deferred code can throw. Closures created inside it have ordinary closure semantics; the compiler
must not introduce a closure merely to implement cleanup.

## Failures

Every registered cleanup is attempted even if a later cleanup throws. The first exception in exit order is primary:
if the body is already throwing, it remains primary; otherwise the first cleanup exception becomes primary and cancels
a pending normal transfer. Later cleanup exceptions are suppressed, without replacing the primary exception. They do
not require allocating an aggregate or attaching a list; the original exception identity and stack are retained. After
all cleanups run, the primary exception propagates to the enclosing handler. This deterministic rule prevents a failed
release from hiding the cause of unwinding and works with arbitrary thrown values. Traps, process termination and
unrecoverable runtime failures are outside language exception handling and do not promise cleanup.

## Disposable and scoped values

The standard library declares `interface Disposable { function dispose():Void; }`. Classes, structs and enums opt in
with `implements Disposable` and satisfy the ordinary interface conformance rules; method shape alone is insufficient.
A scoped initializer's static type must conform, or be `Null<T>` where `T` conforms. Generic parameters require a
`Disposable` bound. Disposal dispatches according to the statically known conformance, without forcing a struct into
an interface box. For `Null<T>`, test presence and call `dispose()` only on a present value. The binding is immutable:
assignment, compound assignment, increment and other rebinding are errors. Mutating a value through its permitted
methods or fields follows ordinary type and place rules; disposal acts on the bound value, not a second copy.

Scoped bindings are a local lifetime aid, not an ownership proof. Reject direct local escapes of the scoped value:
returning it, assigning it to a field, static, array or map element, or non-scoped local, capturing it in a closure, and
converting it to `Dynamic`. Calling methods on the binding and passing it as an argument to functions or methods on
other objects are allowed. A callee retaining or returning the argument is not detected, as with C# `using`; neither are
hidden aliases from before the initializer, native code, or arbitrary unsafe operations. These rules do not establish
unique ownership. Diagnostics should name the scoped binding and the escaping operation. A future checked borrowing
contract could tighten argument passing without changing cleanup semantics.

## Lowering and targets

Represent registrations and scope exits explicitly in typed control flow. Lower each lexical scope to protected body and
cleanup paths, or equivalent direct exit edges, with saved exit kind/value and primary exception as needed. Generate a
cleanup chain in reverse registration order, guarding conditional registrations. Each action has an exception edge that
continues the chain while preserving the primary failure. An exception handler outside the scope sees the exception only
after the chain finishes. Cleanup bodies are ordinary code, not callbacks; no closure, per-scope object, boxed value or
heap-allocated cleanup stack is introduced. Each syntactic registration can use compiler locals and branches; repeated
loop execution uses the loop body's fresh dynamic extent. Preserve source positions for debugging and perform the
transformation independently of inlining.

HashLink lowers protected regions and rethrow through its exception machinery and direct control-flow edges. Wasm32 and
Wasm GC use their existing exception/control-flow lowering, with typed locals for exit state and the nullable value's
native representation. Backends must preserve the same ordering and exception identity; neither interface dispatch nor
nullable checking may introduce a box for a concrete struct. Allocation censuses on all three targets, with inlining
on and off, must measure repeated scope entry and exit, including mixed registrations. Tests also cover exceptions,
nested exits, conditional registration, null, loops and compile-time escape errors.

## Functions, iterators and scope

A function call has its own lexical scopes. Capturing an ordinary local in a deferred body does not extend its lifetime
past the containing block, because the body executes before that block exits. A closure cannot capture a scoped binding,
even when it appears locally invoked, until a checked non-escaping closure contract exists. Iterator objects are ordinary
objects and do not by themselves keep a block active; normal cleanup occurs when the block exits. If suspension or
generators are introduced, their suspended frame and cancellation cleanup need a separate design; this feature does not
promise cleanup on an abandoned suspended frame.

Owner scopes for UI resources, finalizers, `inout`, move-only types, general borrow checking and async cancellation are
out of scope. The reactive runtime and retained UI machinery are not changed by this feature. No dependency on changes
to generic specialization or inline enums is intended; allocation requirements must nevertheless be verified for the
representations supported by each backend.

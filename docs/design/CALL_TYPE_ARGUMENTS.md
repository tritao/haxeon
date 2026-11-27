# Type arguments at calls (design note)

Status: proposal (2026-11-27), for the user's review; not started.

A call names its callee's type arguments, as in `MessagePack.decode<User>(bytes)`. Inferring them from the arguments and
from the expected type stays the default; the explicit form covers the calls where neither gives them.

## Problem

A generic function whose type parameter appears only in its result gets it from the expected type alone, and many uses
have none. `decode<T>(bytes):Result<T, WireError>` ([ERROR_MODEL.md](ERROR_MODEL.md#migration)) is the common case:

```haxe
var user:Result<User, WireError> = MessagePack.decode(bytes); // a typed local: works
var user:User = try MessagePack.decode(bytes);                 // `try` passes the expected type down: works
switch MessagePack.decode(bytes) { ... }                       // no expected type: an error
MessagePack.decode(bytes).mapErr(ConfigError.Wire);            // the receiver has none either: an error
```

The others in the standard library are `JsonWire.decode<T>`, `RpcMethod.wire<Req, Res>(id)`, `RawPtr.castTo<U>()`,
`NativeArena.alloc<T>()` and ui's `BuildContext.existingState<T>(id)`. Each one's callers write a typed local or a
check-type expression `(e : T)` to state a type that belongs to the call. The same gap stops a generic function from
taking `T` = `Void` from a lambda with no arguments (`apply(() -> 1)` for `apply<T>(f:T->Int)`), which
[ERROR_MODEL.md](ERROR_MODEL.md#void-is-the-unit-type) lists as not yet done.

Inferring through more positions (a `switch` subject, a method receiver) would fix the first two lines of the example and
none of the rest. It would also make a call's type depend on how its value is used further away.

## Proposal

- **Syntax.** A callee written as a name or a field access may be followed by type arguments before its arguments:
  `decode<User>(bytes)`, `RpcMethod.wire<Query, Answer>(100)`, `items.map<String>(describe)`. This is the form
  `new Map<String, Int>()` already has, and the one C#, Kotlin, TypeScript and Dart readers expect.
- **Parsing.** After a name or a field access, `<` starts type arguments when the tokens up to its matching `>` parse as
  a list of types and the next token is `(`. The parser decides this by looking ahead over tokens, as `try` looks for
  its `catch`. The rule depends only on the token shapes, not on what the names resolve to, so a formatter or highlighter
  parses it the same way. Without that `(`, `<` stays a comparison.
- **Typing.** The type arguments bind the callee's own type parameters in declaration order, before the arguments are
  typed, so lambdas and literals are typed against them (`apply<Void>(() -> 1)`). A generic owner's parameters still come
  from the receiver. The call gives all of the callee's own type parameters or none of them. Each is checked against
  its constraints as an inferred one is. A result that does not fit the expected type is the same mismatch as with
  inferred arguments.
- **Intrinsics.** `MessagePack.decode`, `JsonWire.decode` and `RpcMethod.wire` already declare their type parameters, so
  their lowering reads the explicit argument when one is given, and the expected type otherwise.
- **Errors.** Type arguments for a callee with no type parameters of its own, or the wrong number of them, are errors
  that name the callee and its parameters.

## Haxe compatibility

Haxe has no call type arguments, so the new reading can only take code that Haxe reads as comparisons, and only one
shape: `f(a < b, c > (d))`, which Haxe reads as two arguments. Under the new rule it is a call of `a` with type
arguments `b` and `c`. The two readings never both type: the comparison needs `a`, `b` and `c` to be values, and the call needs
`a` to be a generic function and `b` and `c` to be types. So no Haxe code silently changes meaning. That one shape fails
to compile instead, with an error that suggests parentheses, `(a < b), (c > d)`. C# made the same choice for
`F(G<A, B>(7))`.

## Alternatives

- **Rust's `decode::<User>(bytes)`.** It needs no lookahead, but adds a token Haxe does not have for a form readers know
  from elsewhere without it.
- **Passing the type as a value (`decode(bytes, User)`), as Swift's `JSONDecoder` and Haxe's `Std.downcast` do.**
  Classes are values in Haxe, but `Array<User>`, `Map<String, User>` and structures are not, and wire decodes all of
  them.
- **Inferring through `switch` subjects and receivers.** See [Problem](#problem).

## Work

1. The parser's lookahead and a call node carrying its type arguments, through the AST walkers. The parser tests cover
   the ambiguous shape and nested arguments (`decode<Array<User>>(bytes)`, whose `>>` closes two lists).
2. The typer binding explicit arguments, with the arity and constraint checks, including generic methods.
3. The wire and RPC intrinsics reading the explicit argument. The stdlib's typed locals and check-type expressions that
   only state a call's type argument become the explicit form.
4. Docs: [LANGUAGE_SUPPORT.md](../reference/LANGUAGE_SUPPORT.md), the generics and wire learn pages, and
   ERROR_MODEL.md's wire note and `Void` limit.

## For the user

- Whether to add the form, and with this spelling.
- Whether a call may give only some type arguments, with `_` for the rest, as Rust's `collect::<Vec<_>>()` does. The
  proposal is all or none, with `_` added when a callee with several type parameters needs it.

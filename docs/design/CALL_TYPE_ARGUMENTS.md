# Type arguments at calls (design note)

Status: implemented (2026-11-27), as decided by the user: the spelling below, all type arguments or none.

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

## Rules

- **Syntax.** A callee written as a name or a field access may be followed by type arguments before its arguments:
  `decode<User>(bytes)`, `RpcMethod.wire<Query, Answer>(100)`, `items.map<String>(describe)`. This is the form
  `new Map<String, Int>()` already has, and the one C#, Kotlin, TypeScript and Dart readers expect.
- **Parsing.** After a name or a field access, `<` starts type arguments when the tokens up to its matching `>` are
  only what types are written with (names, `.`, `,`, `->`, `?`, `:`, braces, and a parenthesis whose `)` is followed by
  `->`, as a function type's is) and the next token is `(` (`Parser.typeArgumentsAhead`). The parser decides this by
  looking ahead over tokens, as `try` looks for its `catch`. The rule depends only on the token shapes, not on what the
  names resolve to, so a formatter or highlighter parses it the same way. Without that `(`, `<` stays a comparison. The
  AST wraps the call written without them: `GenericCall(call, typeArguments, span)`, so every pass that reads a `Call`
  or `MethodCall` reads it unchanged.
- **Typing.** The type arguments bind the callee's own type parameters in declaration order, before the arguments are
  typed, so lambdas and literals are typed against them (`apply<Void>(() -> 1)`). They are the call's: the arguments
  convert to them rather than refine them, so `same<Float>(5)` is a `Float` and `same<Dynamic>(5)` a `Dynamic`. A generic
  owner's parameters still come from the receiver, and so do those a static extension's or an array or map method's
  receiver fixes: `[1, 2].fold<String>(f, "")` writes only `Lambda.fold`'s `B`. The call gives all of the callee's own
  type parameters or none of them. Each is checked against its constraints as an inferred one is. A result that does
  not fit the expected type is the same mismatch as with inferred arguments. The typer keeps the written arguments by
  the call's span while the call is typed (`CallResolver.typeGenericCall`), and each path that resolves a generic callee
  binds them (`bindTypeArguments`), so a call whose arguments no path took is the error below.
- **Intrinsics.** `MessagePack.decode`, `JsonWire.decode`, their `encode` and `RpcMethod.wire` declare their type
  parameters, so their lowering reads the written argument when one is given, and the value or the expected type
  otherwise.
- **Errors.** Type arguments for a callee with no type parameters of its own (`"plain" takes no type arguments of its
  own`), or the wrong number of them (`"make" takes 1 type argument (T), got 2`), are errors that name the callee and its
  parameters. An enum constructor takes its enum's type arguments from the expected type, as before.
- **Tooling.** Signature help skips a call's type arguments back to its callee.

## Haxe compatibility

Haxe has no call type arguments, so the new reading can only take code that Haxe reads as comparisons, and only one
shape: `f(a < b, c > (d))`, which Haxe reads as two arguments. Under the new rule it is a call of `a` with type
arguments `b` and `c`. The two readings never both type: the comparison needs `a`, `b` and `c` to be values, and the call needs
`a` to be a generic function and `b` and `c` to be types. So no Haxe code silently changes meaning. That one shape fails
to compile instead (`Unknown type "b"`), with a note to put each comparison in parentheses. C# made the same choice for
`F(G<A, B>(7))`.

## Alternatives

- **Rust's `decode::<User>(bytes)`.** It needs no lookahead, but adds a token Haxe does not have for a form readers know
  from elsewhere without it.
- **Passing the type as a value (`decode(bytes, User)`), as Swift's `JSONDecoder` and Haxe's `Std.downcast` do.**
  Classes are values in Haxe, but `Array<User>`, `Map<String, User>` and structures are not, and wire decodes all of
  them.
- **Inferring through `switch` subjects and receivers.** See [Problem](#problem).

## Not done

- A call giving only some type arguments, with `_` for the rest, as Rust's `collect::<Vec<_>>()` does: added when a
  callee with several type parameters needs it.
- Type arguments on a function value without a call (`var f = decode<User>;`), and on an enum constructor.

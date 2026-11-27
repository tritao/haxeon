# Error model

Status: the policy was decided by the user on 2026-11-18; errors as values (the `Result` type, must-use, `try`
propagation, `Void` as the unit type) on 2026-11-26. Implemented in [stages](#stages).

How Haxeon's own code and its libraries report failure, and the language support for errors as values.

## Rule

- **Expected failures return a value.** A failure a caller is meant to handle (a file that is missing, input that does
  not parse, a connection that is refused) is part of the function's type: it returns `Result<T, E>`, where `E` is an
  error enum that names each failure and carries its data. The caller matches it.
- **Bugs throw.** A broken invariant, a state the code cannot be in, or a misuse of an API throws an exception. Nothing
  is expected to catch it except a boundary that reports it (a CLI's top level, the compile server, a test runner).

## Exceptions

This follows the decisions made earlier for exceptions:

- Haxeon's own code throws only `haxe.Exception` subclasses (`24db87fe1`): `CompileError` for a located diagnostic,
  `compiler.core.InternalError` for every other failure in the compiler, and a subclass of its own where a caller tells
  failures apart. A catch of `haxe.Exception` therefore never wraps a value.
- The lint rule `throw-non-exception` names a `throw` whose value is not a `haxe.Exception`
  ([CLI lint rules](../reference/cli/test-quality.md#lint)). It is opt-in, so code ported from Haxe that throws strings still builds.

Code the compiler generates for a program (wire codecs, flags, FFI bindings) and the IR interpreter throw what the
program's own code would; the policy does not apply to them.

## Errors as values

### `Result<T, E>`

The standard library's root package declares the one result type, so it needs no import:

```haxe
enum Result<T, E> implements MustUse {
	Ok(value:T);
	Err(error:E);
}
```

- **An ordinary payload enum.** Code matches it with `switch`; `Ok(v)` and `Err(e)` resolve from the expected type.
- **`E` names the failures.** It is an error enum whose cases carry their data (`BadDigit(at:Int)`), not a string or
  an exception, so a caller's `switch` over it is exhaustive.
- **Methods:** `isOk()`, `isErr()`, `map(f)`, `mapErr(f)`, `andThen(f)`, `unwrapOr(fallback)`, and `unwrap()`, which
  throws for an `Err`: a caller that writes it says a failure there is a bug. There is no accessor that returns
  `Null<T>`, since a scalar `Null<T>` reads as its default.
- **Cost.** A generic enum is boxed today, so returning a `Result` allocates; inline generic enums
  ([STRUCTS.md](STRUCTS.md#source-inline-enum-activation-remaining-blockers), E8) remove that without changing the
  type or its API.

### Must-use

- A value whose type implements the root marker interface `MustUse` must not be dropped. An expression statement that
  computes one is an error (`E1033`), and so is a lambda whose expression body computes one where the lambda's result
  is `Void`: `items.forEach(item -> save(item))` drops every failure. `Result` implements `MustUse`.
- **`_ = expr;` discards a value explicitly.** `_` names no variable there, so the statement says the value is not
  wanted.
- `Disposable` values and builders are candidates; each becomes must-use in the change that moves its callers.

### Propagation: `try expr`

- `try e`, where `e` is a `Result<T, E>`, yields the `Ok` value; on an `Err` it returns that `Err` from the enclosing
  function, whose result must be a `Result<U, E>` with the same `E`. A lambda's `try` returns from the lambda.
- **The error type must match.** A different one is converted explicitly with `mapErr`, where a case constructor serves
  as the function: `try read(path).mapErr(ConfigError.Io)`. A conversion conformance is added only if this boilerplate
  proves common.
- **`try` followed by `catch` keeps its exception meaning.** Haxe requires a `catch`, so a `try` without one means
  nothing in Haxe code, and no Haxe code changes meaning. A postfix `?` was rejected: next to the ternary `a ? b : c`
  a reader cannot tell them apart, and `?` stays the null operators' (`?.`, `??`).
- Returning through `try` runs scoped cleanup (`defer`, scoped `Disposable` bindings) as any `return` does.

### `Void` is the unit type

- `Void` has one value and carries no data. A parameter, argument or enum payload of type `Void`, written or
  substituted for a type parameter, is omitted: `Ok()` makes a `Result<Void, E>`, `case Ok():` matches it.
- **Generic code stays valid when a type parameter is `Void`.** A binding of type `T` holds the unit value, and passing
  it where a `Void` argument goes is the same as omitting it. `T->U` with `T` as `Void` is `Void->U`, the function
  with no arguments, as Haxe writes it.
- A `Void` value occupies no storage on any target.
- So `Result<Void, E>` (an operation that succeeds or fails with no value), `Future<Void>` and `Signal<Void>` work.

### Asynchronous operations

An asynchronous operation whose failures are expected settles a `Future<Result<T, E>>`. `Outcome.Failure(Exception)`
then means only that the producer threw, which is a bug, as in synchronous code; `Cancelled` and `Stopped` keep their
meaning ([ASYNC.md](../reference/ASYNC.md)).

## Migration

The packages at the system's edges move to `Result` deliberately, each in one change with all its callers and no
compatibility forms: wire and MessagePack decoding, RPC (its connector's `RpcConnectResult` folds into the error enum),
filesystem, platform requests (`NativeKitError`), and audio and GPU device and shader setup. Misuse checks, such as
ui's argument checks, stay exceptions. Other APIs change when they are next worked on.

The compiler's own source uses none of this until the gates of [ADR 0006](../adr/0006-haxeon-only-compiler-source.md)
hold: stock Haxe parses neither enum methods nor `try` without `catch`. Its failures are diagnostics or bugs anyway.

## Stages

| Stage | Contents | Status |
|---|---|---|
| 1 | Enum methods with type parameters of their own (`map<U>`), which the `Result` methods need | |
| 2 | `Result<T, E>` in the root package, with its methods | |
| 3 | `MustUse`, `E1033` and `_ = expr;` | |
| 4 | `Void` as the unit type | |
| 5 | `try` propagation | |
| 6 | The migration above, with `Future<Result<T, E>>` for RPC and platform requests | |
| 7 | Inline generic enums (STRUCTS.md E8), so returning a `Result` allocates nothing | |

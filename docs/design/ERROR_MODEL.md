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
- **`try` is a prefix operator**, as `!` is: `try a() + 1` adds to the value, and `try read(path).mapErr(f)` converts the
  error before it propagates. An unannotated function, or a lambda whose result is inferred, returns a `Result` with the
  error type of its first `try`.
- **`try` followed by `catch` keeps its exception meaning.** Haxe requires a `catch`, so a `try` without one means
  nothing in Haxe code, and no Haxe code changes meaning. A `try` is a `try`/`catch` when a `catch` follows its body at
  the body's own nesting. A postfix `?` was rejected: next to the ternary `a ? b : c` a reader cannot tell them apart,
  and `?` stays the null operators' (`?.`, `??`).
- Returning through `try` runs scoped cleanup (`defer`, scoped `Disposable` bindings) as any `return` does.

### `Void` is the unit type

- `Void` has one value and carries no data. A parameter, argument or enum payload of type `Void`, written or
  substituted for a type parameter, is omitted: `Ok()` makes a `Result<Void, E>`, `case Ok():` matches it.
- **Generic code stays valid when a type parameter is `Void`.** A binding of type `T` holds the unit value, and passing
  it where a `Void` argument goes is the same as omitting it. `T->U` with `T` as `Void` is `Void->U`, the function
  with no arguments, as Haxe writes it. A generic body writes an item for each `T`, so it is elaborated at `Void` as at
  any other type.
- **Where a `Void` is left out.** Calls, lambdas and patterns follow one rule: where fewer are written than there are
  parameters, each `Void` parameter takes the unit value while more parameters remain than are written, and a `Void` value
  written in its place still takes it. So `Both(42)` makes a `Both(first:Void, second:Int)` and `case Both(n):` matches
  it, `case Ok():` matches a `Result<Void, E>`, and `() -> 7` is a `Void->Int`. Function types compare and unify by their
  other arguments, so a `function f():Void` is a `T->Void` at `T` = `Void`.
- `Void` satisfies `Equatable` and `Hashable`: its one value equals itself and adds nothing to a hash, so a
  `Maybe<Void>` of an `enum Maybe<T:Equatable>` compares.
- A `Void` value occupies no storage on any target. The type checker gives a call one argument per parameter, the unit
  value where one is left out; IR generation then leaves `Void` out of parameters, call operands, function types'
  arguments and enum payloads (`ProgramFacts.enumVoidPayloads`; the payloads after one are stored one place earlier),
  so no backend sees it. Where a type parameter is erased to `Dynamic`, as in a generic class's methods, the unit value
  is null, and a value read as `Void` is the unit value.
- So `Result<Void, E>` (an operation that succeeds or fails with no value), `Future<Void>` and `Signal<Void>` work.
- Not yet: a generic function does not infer `T` = `Void` from a lambda with fewer arguments than `T->U` has
  (`apply(() -> 1)` for `apply<T>(f:T->Int)`), which the call names instead (`apply<Void>(() -> 1)`), and
  `Null<Void>` and `Array<Void>`, which have no use, have no meaning.

### Asynchronous operations

An asynchronous operation whose failures are expected settles a `Future<Result<T, E>>`. `Outcome` has no failure case:
a producer's bug throws where it happens, in the poll or tick that runs it, as in synchronous code, so no observer
handles one. `Cancelled` and `Stopped` keep their meaning ([ASYNC.md](../reference/ASYNC.md)). Platform requests settle
`Future<Result<T, NativeKitError>>`.

## Migration

The packages at the system's edges move to `Result` deliberately, each in one change with all its callers and no
compatibility forms: wire and MessagePack decoding, RPC (its connector's `RpcConnectResult` folds into the error enum),
filesystem, platform requests (`NativeKitError`), and audio and GPU device and shader setup. Misuse checks, such as
ui's argument checks, stay exceptions. Other APIs change when they are next worked on.

- **Wire (done).** `MessagePack.decode`, `JsonWire.decode`, their `decodeWith`, the frame readers and
  `MessagePackSchema` return `Result<T, WireError>` (`Truncated`, `TrailingData`, `Malformed`, `LimitExceeded`,
  `IncompatibleSchema`). Inside a decode the readers and codecs throw a `WireFailure`, which the entry point returns as
  the `Err`; writers throw only for misuse. The codec is generated for the decoded type, which the call names
  (`MessagePack.decode<User>(bytes)`, [CALL_TYPE_ARGUMENTS.md](CALL_TYPE_ARGUMENTS.md)) or an expected `Result` gives:
  a typed local, or `try` (whose value is then expected to be a `Result` of the expected type).
- **RPC (done).** `RpcConnection.call` and a typed service's client methods settle `Future<Result<Response,
  RpcError>>`. `RpcError` is an enum: named cases for this side's failures (`Disconnected(mayHaveRun)`, `Busy`,
  `TimedOut(mayHaveRun)`, `ConnectFailed(reason, retryable)`, `HandshakeFailed(reason)`, ...), the peer's handler
  outcomes (`HandlerFailed`, `HandlerCancelled`, `HandlerStopped`), and `Remote(code, message, mayHaveRun)` for a code
  of the peer's own; `mayHaveRun()` and `code()` read every case. The connector completes with `Result<MessageTransport,
  RpcError>` (`RpcConnectResult` is gone), the server's authorization returns `Result<Void, RpcError>`, envelopes,
  method codecs and notification decoders return `Result<T, WireError>`, and `closeError` says why a connection
  closed. A typed service's own expected failures belong in its response type, usually `Result<Answer, E>`: generic
  enums are wire types for wire-typed arguments, `Void` among them, and a call answers
  `Result<Result<Answer, E>, RpcError>`.

- **Platform, audio and GPU (done).** NativeKit and its GPU module answer one status code for two kinds of failure,
  which `NativeKitStatus` and the GPU package tell apart. A code that is the program's mistake throws a `BindingError`:
  `InvalidArgument`, `InvalidHandle` (as `Disposed`), `WrongThread`, `NotInitialized`, `AlreadyInitialized`,
  `InvalidRequest`, `BufferTooSmall`, and the GPU's `WrongState` and `BufferOverflow`. Any other code is the
  environment's answer, an error enum's case: `NativeKitError` (`Unsupported(reason)`, `NotFound`,
  `PermissionDenied(reason)`, `Cancelled`, `Busy`, `TooLarge`, `OutOfMemory`, `SurfaceLost`, `InvalidData(reason)`,
  `Network(NetworkError)` for an HTTP request's or a transport's failure (`HostNotFound`, `ConnectionFailed(reason)`,
  `TimedOut`, `TlsFailed(reason)`, `ProtocolViolation(reason)`, `Closed`, `AddressInUse`, `TooManyRedirects`,
  `ProxyFailed(reason)`), and `Failed(code, reason)` for the rest) and `GpuError` (`Unsupported(reason)`, `DeviceLost`, `OutOfMemory`, `Failed(code, reason)`).
  NativeKit keeps the two apart at the source: `INVALID_ARGUMENT` is only ever the caller's mistake, content a decoder
  cannot read is `INVALID_DATA`, and a path with nothing there is `NOT_FOUND`. These return a `Result`: platform
  requests, the audio device (`Mixer.configureDevice`, `startDevice`, `restartDevice`, `DspEngine.attachToDevice`),
  decoding audio (`Clip.from*`, `SoundFont.fromMemory`, `AudioBankEntry.createClip`), the credential store, and GPU
  setup (`Renderer.create`, `Shader.create` and a generated shader module's `create`, a shader or pipeline builder's
  `build`). Every other call throws: a misuse as `BindingError`, an environment code as `NativeKitException` or
  `GpuException`, which carry the enum. The checked helpers the NativeKit bindings generate throw what
  `NativeKitStatus.failure` gives, named by the projection's result policy (`"failure"`,
  [C_HEADER_FFI.md](../reference/C_HEADER_FFI.md)). An asset's or audio bank entry's failed load is a
  `NativeKitError` too (`loadError()`, `AudioBank.onFailed`).

The compiler's own source uses none of this until the gates of [ADR 0006](../adr/0006-haxeon-only-compiler-source.md)
hold: stock Haxe parses neither enum methods nor `try` without `catch`. Its failures are diagnostics or bugs anyway.

## Stages

| Stage | Contents | Status |
|---|---|---|
| 1 | Enum methods with type parameters of their own (`map<U>`), which the `Result` methods need | Implemented |
| 2 | `Result<T, E>` in the root package, with its methods; nested patterns count for switch coverage, and a case with a payload is a function value (`mapErr(ConfigError.Io)`) | Implemented |
| 3 | `MustUse`, `E1033` and `_ = expr;` | Implemented |
| 4 | `Void` as the unit type | Implemented |
| 5 | `try` propagation | Implemented |
| 6 | The migration above, with `Future<Result<T, E>>` for RPC and platform requests | Implemented for wire, RPC, files, platform, audio and GPU |
| 7 | Inline generic enums (STRUCTS.md E8), so returning a `Result` allocates nothing | |

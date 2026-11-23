# Error model (policy)

Status: decided by the user on 2026-11-18. A policy only; no code changes with it.

How Haxeon's own code and its libraries report failure.

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
  ([CLI.md](../reference/CLI.md)). It is opt-in, so code ported from Haxe that throws strings still builds.

Code the compiler generates for a program (wire codecs, flags, FFI bindings) and the IR interpreter throw what the
program's own code would; the policy does not apply to them.

## Not decided here

- Where a shared synchronous `Result` type lives. One-shot asynchronous operations use
  [`haxeon.async.Outcome<T>`](../reference/ASYNC.md), including RPC calls. The connector's
  `RpcConnectResult` carries retry policy for connection attempts.
- Moving existing APIs to `Result`. An API changes when it is next worked on, not in a sweep.

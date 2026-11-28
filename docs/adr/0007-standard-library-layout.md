# 7. The standard library's layout

Date: 2026-11-27

## Status

Proposed. Breaks compatibility with Haxe's standard library on purpose; Haxe's API moves to a package of its own.

## Context

The standard library (`stdlib/`) grew from a vendored subset of Haxe's, and its layout is that history:

| Prefix | Modules | What is there |
|---|---:|---|
| root package | 21 | `Std`, `Sys`, `Math`, `StringTools`, `Lambda`, `DateTools`, `Reflect`, `Date`, `EReg`, `List`, `Xml`, `StringBuf`, and Haxeon's `Result`, `MustUse`, `Flags`, `Equatable`, `Hashable`, `Diffable`, `Disposable`, `Observable`, `Any` |
| `haxe.*` | 38 | bytes and streams (`haxe.io`), `Json`, `Int64`, `Exception`, `ds.Option`, `crypto`, `xml`, `Timer`, `PosInfos` |
| `sys.*` | 17 | `FileSystem`, `io.File`, `io.Process`, `net.Socket`, `thread.*` |
| `haxeon.*` | 67 | `async`, `reactive`, `rpc`, `wire`, `collections.HashMap`, profiling, `wasm` host bindings |
| `runtime.*`, `hl.*` | 17 | the implementation: `MemoryFileSystem`, `Ryu`, `NativeSpan`, `hl.Gc` |
| `utest.*` | 7 | a test framework ported from Haxe's ecosystem |

What that costs:

- **No place says where a thing is.** Bytes are `haxe.io`, files are `sys`, a hash map is `haxeon.collections`, an
  `Option` is `haxe.ds` and a `Result` is the root package. A reader has to know the history to find an API.
- **`sys` groups by Haxe's targets, not Haxeon's.** Haxe has `sys` for the targets with an operating system, against
  JavaScript and Flash. Haxeon's targets are HashLink, C, Wasm32 and Wasm GC; what one lacks is not "a system" but
  particular things (processes and sockets on Wasm), and `sys` cannot say which.
- **More than one way to do a thing.** `Sys` had its own path operations beside `sys.FileSystem` until `503c7d3ef`; files
  are reached through `sys.FileSystem`, `haxeon.filesystem` (NativeKit's) and, on Wasm, `runtime.MemoryFileSystem`.
- **Three error styles.** Haxe's API throws strings, NativeKit's throws `NativeKitError`, and some calls answered with a
  `Bool` or `null`; [ERROR_MODEL.md](../design/ERROR_MODEL.md) now says expected failures return `Result`.
- **Helpers instead of methods.** `Std.parseInt`, `StringTools.startsWith`, `Lambda.map` and `DateTools` exist because
  Haxe types could not have methods added; Haxeon's enums and types can.
- **The root package is crowded.** `Result` reserves its name for every program, and an HXI projection without a package
  already ran into it.
- **The brand is in the names.** `haxeon.*` puts the product's name in every import, against the rule that only
  product-facing names carry it.

## Decision

### 1. One prefix: `std`

Every standard-library module is under `std`. The compiler reserves the prefix: a source outside the standard library
may not declare `package std...`. `std` names what it is, does not depend on the product's name, and cannot collide with
a user's or a registry package, as a bare `io` or `fs` would.

### 2. The prelude is what the compiler knows by name

A program uses the prelude without an import. It holds exactly the declarations the compiler names, and nothing else:

| Names | Why the compiler knows them |
|---|---|
| `Int`, `Float`, `Bool`, `String`, `Array`, `Map`, `Void`, `Dynamic`, `Any` | the core types |
| `Result` | `try` propagation and must-use |
| `MustUse` | must-use (`E1033`) |
| `Equatable`, `Hashable` | structural `==` and map keys check them |
| `Diffable`, `Observable`, `Flags` | the compiler generates their implementations |
| `Disposable` | a scoped binding requires it, and disposes of it at the end of its scope |
| `Exception` | the base of what code throws ([ERROR_MODEL.md](../design/ERROR_MODEL.md)) |
| `PosInfos` | the compiler fills a `?pos:PosInfos` argument |
| `Display`, `Debug`, `Formatter` | interpolation, concatenation and `trace` resolve to them ([TEXT_FORMATTING.md](../design/TEXT_FORMATTING.md)) |
| `trace` | the compiler fills its position |

A declaration the compiler does not name is imported from its package, however often it is used: the rule decides, not
taste. A name the compiler comes to know joins the prelude in the same change.

The prelude is an implicit import, not declarations in the root package: its declarations live in `std` packages
(`std.Result` and so on), and a program's own names shadow them, whether declared in its modules or imported. A program
may declare its own `Result` or `Flags`, as an HXI projection without a package now cannot, and a name joining the prelude
breaks no program.

### 3. Absence is `T?`, not `Option`

A value that may be absent is `T?` (today's `Null<T>`), the one way to say so; `std` has no `Option`, and
`haxe.ds.Option` goes to the compatibility package (section 9). Nothing in the compiler, the packages or `lib/`
uses `Option` today.

- **It narrows.** After `x != null`, `x` is a `T`; `?.` and `??` read it without a `switch` or an `unwrap`.
- **It costs nothing.** `T?` takes the inline presence layout (a flag beside the value, as `Null<S>` of a struct has
  now); `Option` is a boxed generic enum, and inline generic enums (STRUCTS.md E8) would only bring it level.
- **It is the C ABI's and Haxe's.** A `T?` reference is a nullable pointer, and ported code already says `Null<T>`.
- **Nesting is the API's job.** `T??` is `T?`, so a lookup of a map whose values are optional cannot answer "no key"
  apart from "a key whose value is absent" in its return type. Such an API says it another way: `exists(key)`, an entry
  or a cursor, or a `Result` when a missing key is a failure.

This is only sound once the language has two things it does not have yet, and they are prerequisites of this section,
not part of it ([FUTURE_LANGUAGE.md](../design/FUTURE_LANGUAGE.md), change 1):

- **Non-null by default.** A plain `T` is never null, so `T?` is what says a value may be absent. Today any reference
  may be null, and `Null<T>` of a reference tells the compiler nothing.
- **No silent default.** A `T?` reads as a `T` only once narrowed. Today a null `Null<Int>` reads as `0` wherever an `Int`
  is expected, which is why `Result` has no accessor returning `Null<T>` ([ERROR_MODEL.md](../design/ERROR_MODEL.md)).

Until they land, `std` APIs return `Null<T>` where a value may be absent and document it, so the move to `T?` is a
rename.

### 4. Packages by domain, not by target

| Package | Contents | From |
|---|---|---|
| `std.reflect` | reflection, dynamic field access, `Type` | `Reflect`, `haxe` |
| `std.collections` | `HashMap`, `List`, `ReadOnlyArray`, sorting | `haxeon.collections`, `haxe.ds`, root |
| `std.text` | `StringBuf`, regular expressions, character codes, number formatting | root, `haxe` |
| `std.bytes` | `Bytes`, `BytesBuffer`, hex, encodings | `haxe.io` |
| `std.io` | `Input`, `Output`, their errors | `haxe.io` |
| `std.math` | `Int64`, `Int32`, functions of `Math` that are not methods | root, `haxe` |
| `std.time` | `Date`, `Timer`, monotonic and CPU time | root, `haxe`, `Sys` |
| `std.json`, `std.xml` | parsing and printing | `haxe` |
| `std.crypto` | `Sha256`, `Base64` | `haxe.crypto` |
| `std.fs` | files and directories, section 8 | `sys`, `haxeon.filesystem`, `runtime.MemoryFileSystem` |
| `std.process` | the process's arguments and environment, child processes | `Sys`, `sys.io` |
| `std.net` | sockets, hosts | `sys.net` |
| `std.thread` | threads, locks, conditions, thread-local values | `sys.thread`, `haxeon.Threads` |
| `std.async` | `Future`, `Promise`, `Outcome` | `haxeon.async` |
| `std.reactive` | signals, derived values, effects | `haxeon.reactive` |
| `std.wire`, `std.rpc` | wire formats, RPC | `haxeon.wire`, `haxeon.rpc` |
| `std.profile` | profiling spans and counters | `haxeon.Profile*` |
| `std.wasm` | what a Wasm guest exchanges with its host | `haxeon.wasm` |

What a target lacks, it lacks by module: importing `std.process` for Wasm is a diagnostic that names the target, as an
unsupported feature is today. No module is half-present, with functions that throw "not available on this target".

### 5. The implementation is not a prefix

`runtime.*` and `hl.*` stop being packages a program can import. Their declarations become `internal` to the modules
that use them, or move to one internal package the compiler keeps out of a program's imports. What a program legitimately
needs from them (`hl.Gc`'s counters, for one) gets a public home such as `std.profile`.

### 6. Errors follow ERROR_MODEL.md everywhere

An expected failure returns `Result<T, E>` with an error enum of the module (`FileError`, `ProcessError`, `NetError`);
a misuse throws an `Exception` subclass. No function answers a failure with `Bool`, `null` or a thrown string.

### 7. Methods instead of helper classes

`Std`, `StringTools`, `Lambda`, `DateTools` and most of `Math` become methods of the types they serve:
`s.startsWith(prefix)`, `Int.parse(s)` returning a `Result`, `values.map(f)`, `x.abs()`. Free functions remain where
there is no receiver (`std.math.max(a, b)`).

### 8. `std.fs`

The first package built to this layout, because files are where the three APIs and error styles meet. Its natives are the
runtime's own ([ADR 0008](0008-native-layers.md)):

- **Paths as the operating system reads them.** `Files.read(path)`, `Files.remove(path)` and the rest take a path and
  resolve it as the system does: absolute or against the working directory, `..` and symbolic links followed. That is
  what the compiler, a build script and a tool need, and they are most callers.
- **Confinement is opt-in.** `Root.open(path)` is a directory that nothing reached through it can leave: `..` and
  symbolic links resolve only beneath it, or fail with `EscapesRoot`. It has the same operations, as methods
  (`root.read(path)`), for code that serves files to someone it does not trust (a workspace server, a plugin host, a
  sandboxed app). Confining every operation instead would make ordinary code open directories first, and fail where a
  kernel lacks safe resolution; such a kernel fails only a `Root` (`Unsupported`). The Wasm in-memory filesystem
  implements both, and a WASI target maps a `Root` to a preopened directory.
- **A path type.** `Path` is an abstract over `String` that stays normalized and joins with `/`; no path is built by
  concatenation.
- **Typed failures.** Each operation returns `Result<T, FileError>`: `NotFound`, `AlreadyExists`, `NotEmpty`,
  `NotADirectory`, `IsADirectory`, `PermissionDenied`, `EscapesRoot`, `Unsupported`, `Io(code, message)`.
- **Operations named for what callers want.** `remove` succeeds when nothing is there ("make sure it is gone"), so no
  caller checks `exists` first, a check that races and costs a second call; `delete` returns `NotFound`. `createDirectory`
  makes the parents and succeeds when the directory exists. `removeTree` and `writeAtomic` replace the hand-written
  copies in the compiler, the build, `lib/haxeon-io` and the tests.
- **Synchronous first.** `Future<Result<T, FileError>>` forms come later, for code on a UI thread.

### 9. Haxe's API is a package of its own

`haxe.*` (with `haxe.ds.Option`), `sys.*`, `Std`, `Sys`, `Lambda`, `StringTools`, `DateTools`, `Reflect` and `utest` move to a compatibility
package (`lib/haxe-compat`), written as adapters over `std`: Haxe's `sys.FileSystem.deleteFile` calls `std.fs` and throws
on the `Err`, as Haxe does. Code ported from Haxe depends on it; new code and the packages do not. Its behaviour is
Haxe's, so the divergences recorded in `stdlib/UPSTREAM.md` go with it.

It ships in the SDK, beside the standard library, at the same version (decided 2026-11-28): ported code adds it without
fetching anything, and the compiler, which builds against it until ADR 0006's gates hold, needs no registry to build.

## Migration

The compiler's source must keep compiling with stock Haxe until the gates of
[ADR 0006](0006-haxeon-only-compiler-source.md) hold, and a self-hosted build compiles that source against Haxeon's
standard library. Haxe's API therefore keeps working, as the compatibility package, for as long as the compiler uses it.
The order:

1. **One table of the names the compiler knows.** The compiler names about 130 standard-library declarations in string
   literals (`haxe.io.Bytes`, `haxe.Rest`, `haxeon.async.Future`, ...). They are gathered into one table first, so each
   later move changes the table, not the compiler. Done: `compiler.core.StdlibNames`, which a compiler test checks
   against the standard library's declarations.
2. **`std.fs`**, built beside today's API and tested on HashLink and both Wasm targets; `haxeon.filesystem` folds into it
   (`Root`), and the package is deleted.
3. **The other `std` packages**, one domain per change, each with its documentation required (as the standard library's
   is today). A module moves, it is not copied: its old name becomes an adapter in the compatibility package in the same
   change.
4. **The packages, templates and site** move to `std`, package by package.
5. **The prelude becomes the implicit import** of section 2, the root package empties, and the prefix is reserved, once
   nothing outside the compatibility package uses the old names.
6. **The compiler** moves off the compatibility package after ADR 0006's gates.

## Open questions

- The first-party packages (`haxeon.ui`, `haxeon.gpu`, `haxeon.audio`, ...) carry the brand too. They are packages, not
  the standard library, and this ADR leaves their names as they are.
- `Dynamic` and reflection: what of `Reflect` and `Type` `std.reflect` keeps, beside the compatibility package.
- When non-null by default (section 3's prerequisite) lands, against this migration: it changes the meaning of existing
  code, so it is a decision of its own.

## Consequences

- One prefix, one place per domain, one error style, one way to say a value may be absent, and one way to do each thing; a module's documentation says what a
  target lacks without a `sys`.
- Haxe code no longer compiles against the standard library alone: it adds the compatibility package. Migration pages on
  the site say which `std` API replaces each Haxe one.
- The move touches every import in the packages, the templates and the site, and is done once, in the order above.

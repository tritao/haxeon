# A future language after Haxe

Status: idea (2026-11-22). Not planned and not scheduled. Records what a language of our own, started from the current
Haxeon compiler and breaking from Haxe where Haxe costs us, would change and why. Nothing here changes current work:
Haxeon stays Haxe-compatible through the Pragtical conversion ([../../ROADMAP.md](../../ROADMAP.md)), and features that
can land as Haxeon extensions are tracked in [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md).

## Why consider it

Haxe gives Haxeon a reference compiler to test against, a language small enough to implement completely, static types
that let a hot patch be validated before it is installed, and freedom to extend. Those reasons still hold.

The cost shows up as work spent only on compatibility:

- Anonymous structures need their own design track ([STRUCTURE_VALUES.md](STRUCTURE_VALUES.md)): open structures,
  width subtyping and dispatch on erased owners.
- `Dynamic`, `Reflect`, UTF-16 strings, nullable references and Haxe's access rules are each carried through the typer,
  the IR and every backend, and each blocks optimization or adds runtime boundaries
  ([DYNAMIC_SITE_BOUNDARIES.md](DYNAMIC_SITE_BOUNDARIES.md)).
- The language is already moving away from Haxe: conformances, structs, `Observable`, key paths and scoped cleanup are
  Haxeon's core, and general macros are excluded by design.

## Approach: one compiler, two dialects

A clean break would discard the Haxe oracle, Haxe code and the compiler's own source at once. Instead:

- **A second front end.** The new language shares the typed AST, the SSA IR, the backends and the runtime with Haxe
  mode. Haxe mode stays, as Java does beside Kotlin or Objective-C beside Swift.
- **Interoperation by module.** Modules in either dialect import each other. The compiler and applications migrate file
  by file, or not at all.
- **Two sources of truth.** Stock Haxe stays the oracle for Haxe mode. The new language gets a written semantics and a
  conformance suite that grows with its features. The byte-identical self-compile remains a check, but it misses
  semantics the compiler never uses.
- **Semantics before syntax.** The value is in the semantic changes below. Syntax stays close to Haxe unless a change
  needs new syntax, which keeps the language easy to learn, keeps machine translation from Haxe mode simple, and keeps
  it familiar to tools and language models.

New compiler work should keep Haxe assumptions out of the IR and the backends, so that a second front end stays possible
without a rewrite. That is mostly true today.

## Changes

Each entry gives Haxe's behaviour, Haxeon's today, the proposal and the reason. "Break" marks changes that alter the
meaning of existing code and so need the new dialect; the others can land in Haxeon first.

### 1. Non-null by default (break)

- **Haxe:** any reference may be null. `Null<T>` matters mainly for basic types on static targets; null safety is the
  opt-in `@:nullSafety` checker.
- **Haxeon today:** follows Haxe. `Null<T>` narrows, and `Null<S>` of a struct uses an inline presence flag; scalars are
  planned to use the same layout.
- **Proposal:** `T` is never null; `T?` is optional, with narrowing and the inline presence layout everywhere.
- **Why:** removes null checks on dereferences and a common class of bugs, and lets the compiler choose flat layouts
  without first proving that a value is present.

### 2. UTF-8 strings (break)

- **Haxe:** encoding depends on the target; on HashLink strings are UTF-16 and `length` and `charAt` count UTF-16 units.
- **Haxeon today:** UTF-16 on HashLink; the Wasm backends carry UTF-16 coordinate translation to match.
- **Proposal:** UTF-8 storage, byte offsets as the primitive index, and explicit iteration by code point or grapheme.
- **Why:** files, the network, C APIs and text rendering use UTF-8. Every native boundary pays a conversion today, and
  the coordinate translation exists only for compatibility.

### 3. 64-bit `Int`, with explicitly sized types (break)

- **Haxe:** `Int` is 32-bit with wraparound; `Int64` is a separate abstract, slow on some targets.
- **Haxeon today:** the same, with work under way so that `Int64` does not box and lowers to native operations.
- **Proposal:** `Int` is 64-bit; `Int8` through `Int64` and the unsigned types are available for layouts and FFI.
- **Why:** sizes, offsets, timestamps and identifiers outgrow 32 bits, and two integer worlds complicate every API that
  touches them.

### 4. `Dynamic` and reflection by opt-in only (partly a break)

- **Haxe:** `Dynamic`, `Reflect` and `Type` work on every value, and many libraries depend on them.
- **Haxeon today:** supports them for compatibility, paying with dynamic call boundaries, generated reflection helpers
  and boxing at the `Dynamic` edge. Its own direction is typed and declared: `Diffable`, key paths, generated codecs.
- **Proposal:** no `Dynamic` type by default. Reflection is a capability a type declares by conformance; untyped data
  (JSON, scripting) uses an explicit variant type.
- **Why:** each `Dynamic` site blocks specialization, keeps code alive that reachability would remove, and forces boxing.
  Haxe mode can discourage it, but only the new dialect can remove it.

### 5. Named types instead of anonymous structures (break)

- **Haxe:** anonymous structures with structural typing and width subtyping.
- **Haxeon today:** each field set lowers to its own class; full Haxe behaviour is the in-progress
  [STRUCTURE_VALUES.md](STRUCTURE_VALUES.md) track.
- **Proposal:** records are named structs or classes. Anonymous structures, if kept, are value tuples with named fields
  and a fixed layout, without width subtyping; polymorphism goes through interfaces.
- **Why:** structural typing at runtime means indirect field access and a large compiler track spent on compatibility.
  Fixed layouts are simpler and faster on every backend.

### 6. Conformances with static requirements and retroactive extension (extension)

- **Haxe:** interfaces have instance members only; retroactive extension exists only as `using` static extensions.
- **Haxeon today:** conformances exist (`Equatable`, `Hashable`, `Diffable`, `Observable`, structs that `implements`).
  [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md) plans conformance extensions (`extension Rect implements Hashable`) and
  static interface members with `Self`.
- **Proposal:** the same, as the language's central abstraction.
- **Why:** typed codecs (`decode`), generic numeric code, and declared capabilities in place of reflection.

### 7. Errors as values (extension)

- **Haxe:** exceptions only.
- **Haxeon today:** typed catch filters. [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md) plans `Result<T, E>` stored inline,
  a postfix `?` and must-use results; exceptions remain for programming errors.
- **Proposal:** the same, with `Result` as the standard library's convention for expected failures.
- **Why:** failures that callers must handle (parsing, IO, RPC) appear in signatures and cost nothing on success.

### 8. A module system with explicit visibility (break to replace; extensions possible)

- **Haxe:** a file is a module, inside packages, with `private`, `@:allow` and `@:access` as special rules.
- **Haxeon today:** matches Haxe, with recent work on `@:allow` paths, visibility enforcement and name resolution.
- **Proposal:** explicit module exports and package-level visibility, with no access-override metadata.
- **Why:** effort now goes into replicating access rules that are intricate by design. Clear module boundaries also help
  incremental compilation and line up with hot-patch units.

### 9. Hot-patch boundaries in the language (extension)

- **Haxe:** nothing; hot reload is not part of the language.
- **Haxeon today:** live mode needs an entry class following a convention (`start`, `tick`, `saveState`, `close`,
  `restoreState`), and structural changes go through an explicit reload boundary
  ([../reference/LIVE_PATCHING.md](../reference/LIVE_PATCHING.md)).
- **Proposal:** declared state that survives patches, declared reload boundaries, and compiler-checked migrations when
  the layout of that state changes.
- **Why:** state that survives an edit is the product's central idea. Declaring it lets the compiler check what
  convention leaves to the author.

## Summary

| Change | In Haxeon today | Needs the new dialect |
|---|---|---|
| 1. Non-null by default | Partly: `Null<T>` layouts | Yes |
| 2. UTF-8 strings | No | Yes |
| 3. 64-bit `Int` | `Int64` work | Yes |
| 4. Opt-in `Dynamic` | Direction only | Partly |
| 5. No anonymous structures | Opposite: the compatibility track | Yes |
| 6. Conformances and extensions | Planned | No |
| 7. `Result` and `?` | Planned | No |
| 8. Module system | No | Yes, to replace the model |
| 9. Hot-patch boundaries | Convention only | No |

Items 1–5 and 8 are what would justify a new language. Items 6, 7 and 9 can land in Haxeon first and try out most of the
new language's ideas before a break is decided.

## Built-in types

The changes above come down to three questions for every built-in type: does it have a known layout, can it be null,
and is it generic without boxing? Haxe's types each fail one of them for a different reason. The names users touch most
(`Int`, `String`, `Array`, `Map`) keep their spelling, so the language still reads like Haxe; what they guarantee
changes.

### Kept

- **`Bool`**: unchanged.
- **`Float`**: stays 64-bit. `Float32` becomes a first-class type for layouts, GPU data and FFI, replacing HashLink's
  `Single`.
- **Function types** `(A, B) -> R`: unchanged syntax. A closure that captures nothing is created once
  ([UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md), item 7).
- **`Bytes`**: kept, and the backing type for strings and spans.

### Changed

- **`Int`**: 64-bit, with `Int8` through `Int64` and `UInt8` through `UInt64`; the `Int64` abstract goes away (change 3).
  Overflow wraps, as in Haxe, because it is predictable and identical on every backend; checked and saturating
  operations are methods.
- **`String`**: immutable UTF-8 with byte-offset indices and explicit code point or grapheme iteration (change 2).
  `StringBuf` becomes an ordinary library builder.
- **`Array<T>`**: still a growable reference type, but always specialized to its element type: `Array<Rect>` stores
  contiguous structs and `Array<Int>` raw integers. Haxeon already does much of this as an optimization; the new
  language guarantees it.
- **`Map<K, V>`**: Haxe's `Map` is an abstract that selects `IntMap`, `StringMap` or `ObjectMap` by key type, with
  identity for object keys. It becomes one generic hash map, `Map<K:Hashable, V>`, driven by the key's declared
  `Hashable`, as `haxeon.collections.HashMap` already is. `Set<T:Hashable>` sits beside it.
- **`Null<T>`** becomes **`T?`**, with the inline presence layout for every type (change 1).
- **`Iterator<T>` and `Iterable<T>`**: Haxe declares them as anonymous structure typedefs (`{hasNext, next}`), so
  iteration depends on structure values. They become interfaces, and loops specialize over concrete iterators without
  boxing (change 5).
- **`Void`**: a real unit type usable as a type argument, so `Result<Void, E>`, `Signal<Void>` and `Future<Void>` work.

### Removed or restricted

- **`Dynamic`**: removed. Untyped data (JSON, scripting, RPC payloads) uses an explicit variant enum from the library
  (change 4).
- **`Any`**: only an explicit boxed value, with checked casts out and no field access.
- **`Class<T>`, `Enum<T>`, `Type` and `Reflect`**: available only for types that declare a reflection capability, as
  `Diffable` works today.

### Added

- **Value tuples** with named fields, in place of anonymous structures (change 5).
- **Fixed-size arrays** `T[N]`, which [STRUCTS.md](STRUCTS.md) already has inside flat structs.
- **Slices, `Span<T>`**: views without copying over arrays, bytes, strings and native memory, generalizing `NativeSpan`.
- **`Result<T, E>`** in the core library (change 7).

## Syntax

Haxe's syntax stays the base. The changes are a handful of forms that are clumsy or that clash with the semantics above,
and each can be translated mechanically from Haxe mode.

### Kept

- **Capitalized types, built-ins included.** One rule: types are capitalized, values are not. `Int` and `Rect` look
  alike because both are value types. Lowercase primitives bring back the split that Java's `int` and `Integer`
  show the cost of. Sized types follow the rule: `Int8`, `UInt64`, `Float32`.
- Annotations as `x:Int`, generics as `<T>`, constraints as `T:Hashable`.
- Expression orientation: `if`, `switch` and blocks are values.
- Pattern matching in `switch`, enums with payloads, `?.` and `??`.
- Semicolons. Without them newlines become significant in an expression-oriented grammar, which adds ambiguity.
- `function`: renaming it is cosmetic and costs familiarity.

### 1. Typed attributes in place of `@:` metadata

Haxe metadata is untyped: `@:name(args)` takes any name and any expressions, unknown names are accepted silently, and
each compiler feature parses its own arguments. The `@:` prefix exists to separate compiler metadata from user metadata,
which is for macros; with no macros, that distinction has no purpose.

Most of the metadata Haxeon uses today is a feature that the semantics above give real syntax:

| Today | Becomes |
|---|---|
| `@:allow`, `@:access`, `@:privateAccess` | the module system (change 8) |
| `@:optional` | `T?` (change 1) |
| `@:from`, `@:to` | explicit conversions (change 4 below) |
| `@:isVar` | accessor syntax (change 2 below) |
| `@:noReturn` | a `Never` result type |
| `@:hlNative`, `@:cNative` | typed native declarations |

What remains is attributes: `@name` or `@name(values)`, where `name` resolves to a declared annotation type, as the typed
annotations planned in [STRUCTS.md](STRUCTS.md) already do (`@:annotation struct Range { var min:Float; var max:Float; }`).
A misspelled or ill-typed attribute is a compile error, attributes resolve and complete like any other name, and
libraries define their own without compiler changes. The compiler's own attributes (`@pure`, `@unobservable`) are
declared the same way, in the standard library.

### 2. Accessors inline with the property

`var x(get, set):Int` plus separately named `get_x` and `set_x` methods, with `@:isVar` to request storage, becomes
`var x:Int { get => ...; set(v) => ... }`. The accessors sit with the declaration, and storage follows from use.

### 3. Raw-value enums

`enum abstract Color(Int) { var red = 1; }` becomes `enum Color : Int { red = 1; }`. Haxeon already gives these
`RawRepresentable` semantics, with checked conversion from declared constants and no implicit conversions; the syntax
says what they are.

### 4. Newtypes without implicit conversions

A Haxe abstract wraps a representation type and can declare implicit conversions both ways:
`abstract StableTypeId(Int) from Int to Int {}`. The compiler uses this shape for its identifiers (`CfgValueId`,
`StableTypeId`, `StableFieldId`, `WasmLocalRef`, `WasmGlobalRef`, `WasmFunctionRef`). `from Int` lets any `Int` (a loop
index, a count, a different identifier unwrapped by `to Int`) become an identifier without a mark at the call site, and
`to Int` lets arithmetic and comparisons silently operate on the raw value. The type documents intent but checks little.

In the new language a newtype has no implicit conversions:

```haxe
newtype StableTypeId(Int) {
	public static function of(raw:Int):StableTypeId;  // explicit way in
	public var raw(get):Int;                         // explicit way out
	// operations the type allows, declared like any method or operator
}
```

- **Construction and unwrapping are visible.** A call site that turns an `Int` into an identifier says so, which is
  where mistakes happen.
- **Operations are opt-in.** Equality and hashing come from conformances (`implements Hashable`); arithmetic exists only
  if declared, so adding two identifiers is an error rather than a meaningless number.
- **No runtime cost.** As today, the representation is the wrapped type: no box, no header, the same layout in structs
  and arrays.
- **Conversions that are wanted** (units such as `Meters` to `Float`) are still declared, but as named conversions,
  not silent ones.

This also simplifies the type system. Implicit conversions interact with overload-free call checking, generic
inference and `Null<T>`; [../reference/SEMANTIC_TYPE_CONTRACT.md](../reference/SEMANTIC_TYPE_CONTRACT.md) already limits
them deliberately, and newtypes remove the abstract case altogether. Abstracts with operator overloading over another
type's representation (Haxe's "abstract as a view") become a newtype plus declared operators.

### 5. One checked cast

Haxe has an unchecked `cast x` and a checked `cast(x, T)`. Only a checked `x as T` remains, and `untyped` is removed.

### 6. No `dynamic` methods

Reassignable methods conflict with static dispatch and with hot patching's own model of what may change. A field of
function type covers the remaining uses.

### 7. `let` and `var` for bindings

Haxe's `final` means two unrelated things: a binding assigned once (`final x = 1`, `final name:String`) and a class or
method that cannot be subclassed or overridden. Bindings use `let` (immutable) and `var` (mutable), as in Swift, and
`final` keeps only its inheritance meaning.

- **Not `let mut`.** Rust's `mut` belongs to its ownership model, beside `&mut` borrows. Without ownership it is a
  longer `var`. `mut` stays free for mutating value types in place, if mutating methods or in-out parameters arrive
  ([SCOPED_PLACES.md](SCOPED_PLACES.md)), so it keeps one meaning.
- **Immutability by warning, not by length.** The compiler warns when a `var` is never reassigned, as Swift does, which
  gives the habit Rust's longer form aims for without the noise.
- **Fields.** A `let` field is assigned once, in its initializer or the constructor, as Haxe's `final` fields are, and
  matches the immutable value types (`Color`, `Rect`).
- **Migration.** Haxe `var` keeps its meaning and Haxe `final` bindings become `let`; nothing else is rewritten.
- **Caveat.** In JavaScript and TypeScript `let` is mutable. Swift and Kotlin users read it as intended; TypeScript users
  adjust once.

Whether classes and methods are final by default, with `open` to allow overriding as in Kotlin and Swift, is a separate
open question; it matters more for static dispatch than the keyword choice does.

### Clashes to resolve

- **`T?` against optional parameters.** Haxe marks an optional parameter as `?x:Int`. Optional parameters become
  defaults (`x:Int = 0`) or `x:Int?`, and the prefix form goes away.
- **Postfix `?` against the ternary.** [LANGUAGE_ROADMAP.md](LANGUAGE_ROADMAP.md) plans `expr?` for `Result`, but
  `a ? b : c` exists. A parser can tell them apart by lookahead; a reader cannot easily. Either use a prefix keyword
  (`try expr`, as Swift and Zig do, distinct from `try`/`catch`) or drop the ternary, since `if` is already an
  expression. Dropping the ternary is preferred. This affects the current Haxeon plan and is decided there first.
- **String quotes.** Haxe interpolates single-quoted strings (`'$x'`) and not double-quoted ones. Either both
  interpolate or one quote style remains.

## What we would lose

- **The oracle.** Replaced by a written semantics and a conformance suite, which take sustained effort.
- **Haxe users and code.** Kept reachable through Haxe mode and module interoperation.
- **Familiarity.** A new language is unknown to developers and language models. Keeping Haxe-like syntax limits this.
- **Focus.** Syntax, language server, formatter, documentation and diagnostics for new constructs all need work.

## Preconditions

Not before:

- the Pragtical conversion works on Haxe-mode Haxeon;
- [ADR 0004](../adr/0004-runtime-library-and-backends.md) settles the runtime library, so that string and integer changes
  are made once in Haxeon source rather than per backend;
- the IR and the backends hold no Haxe-specific assumptions that a second front end would have to undo.

Until then, keep a list of Haxe semantics that cost us, with evidence from the work they cause, and design the new
language's semantics against that list.

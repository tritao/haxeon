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

### 2. Encoding-free strings (break)

- **Haxe:** encoding depends on the target; on HashLink strings are UTF-16 and `length` and `charAt` count UTF-16 units.
- **Haxeon today:** UTF-16 on HashLink; the Wasm backends carry UTF-16 coordinate translation to match.
- **Proposal:** the API exposes no encoding. Strings have opaque index values and explicit views over code points,
  graphemes and UTF-8 bytes, as Swift's do; there is no integer `charAt(i)` tied to a code-unit size. Each backend
  chooses its storage: UTF-8 on native and Wasm32, host strings on Wasm GC and on a JavaScript backend
  ([Targets that constrain the design](#targets-that-constrain-the-design)).
- **Why:** files, the network, C APIs and text rendering use UTF-8, while browsers use UTF-16. Every boundary pays a
  conversion today, and the coordinate translation exists only for compatibility. An encoding-free API lets each
  backend store what its boundary wants.

### 3. 64-bit `Int`, with explicitly sized types (break)

- **Haxe:** `Int` is 32-bit with wraparound; `Int64` is a separate abstract, slow on some targets.
- **Haxeon today:** the same, with work under way so that `Int64` does not box and lowers to native operations.
- **Proposal:** `Int` is 64-bit; `Int8` through `Int64` and the unsigned types are available for layouts and FFI.
- **Why:** sizes, offsets, timestamps and identifiers outgrow 32 bits, and two integer worlds complicate every API that
  touches them.
- **Depends on JavaScript output.** JavaScript has no 64-bit integer, so every integer operation there would pay for
  emulation. If a JavaScript backend becomes a first-class target, Haxe's original choice returns for its original
  reason: a 32-bit wrapping `Int` and an explicit `Int64`
  ([Targets that constrain the design](#targets-that-constrain-the-design)).

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
- **Haxeon today:** typed catch filters, and errors as values decided in [ERROR_MODEL.md](ERROR_MODEL.md):
  `Result<T, E>`, prefix `try` propagation and must-use results; exceptions remain for programming errors.
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
| 2. Encoding-free strings | No | Yes |
| 3. 64-bit `Int` | `Int64` work | Yes; reconsider if JavaScript is first-class |
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
- **`String`**: immutable, with opaque indices and explicit code point, grapheme and UTF-8 views; storage is the
  backend's choice (change 2). `StringBuf` becomes an ordinary library builder.
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
- `switch` as the pattern-matching form (change 8 below), enums with payloads, `?.` and `??`.
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

Rules that keep attributes declarative:

- Arguments are constant expressions of declared types, never code that runs; attributes are not decorators as in
  Python or TypeScript.
- An attribute applies only to the declaration, statement or parameter that follows it.
- Several attributes are written in sequence (`@a @b`), on one line or several.
- Use-site targets, as in Kotlin (`@field:x`, `@get:x`, `@return:x`), are added only when a case needs them; a module's
  attributes go on its `module` or `package` declaration.

Why `@`: Java, Kotlin, Swift, TypeScript, Python and Dart use it, Haxe already does, and migration is `@:x` to `@x`.
C#'s `[Name]` and C++'s `[[name]]` clash with array literals and comprehensions, which can start a statement in an
expression-oriented grammar (`[for x in xs { f(x) }]`). Rust's `#[name]` would blur `#`, which marks what the compiler
decides (change 16).

### 2. Accessors inline with the property

`var x(get, set):Int` plus separately named `get_x` and `set_x` methods, with `@:isVar` to request storage, becomes
`var x:Int { get => ...; set(v) => ... }`. The accessors sit with the declaration, and storage follows from use.

### 3. Raw-value enums

`enum abstract Color(Int) { var red = 1; }` becomes `enum Color:Int { red = 1; }`, with checked conversion from
declared constants and no implicit conversions; the syntax says what they are.

Adopted: [ENUM_MEMBERS.md](ENUM_MEMBERS.md#raw-value-enums) has the rules.

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
inference and `Null<T>`; [../internals/SEMANTIC_TYPE_CONTRACT.md](../internals/SEMANTIC_TYPE_CONTRACT.md) already limits
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

### 8. `switch` stays; captures, exhaustiveness and single-pattern tests change

Haxe's `switch` already has the semantics of Rust's `match`: it is an expression, cases never fall through, and it
matches enums with payloads, nested patterns, alternatives (`case A | B:`) and guards (`case x if x > 0:`). Renaming it
`match` with `P =>` arms would rewrite every switch for no semantic gain. Arm bodies stay statements up to the next
`case`; Rust needs commas and braces because its arms are expressions.

- **Explicit captures.** In Haxe a bare lowercase name in a pattern binds a new variable, so a misspelled constant or a
  name that matches an existing variable silently becomes a catch-all. Haxeon's compatibility gaps include pattern
  captures that share a name with a function or variable for this reason. Bindings use `let`, as in Swift:
  `case Some(let x):` binds, and `case Some(limit):` compares with `limit`.
- **Always exhaustive.** Every `switch` is exhaustive, with `case _:` as the only explicit opt-out; `default` is removed
  so there is one spelling. Adding an enum case then fails every match that does not handle it, which is what lets
  enums and `Result` evolve safely.
- **`if let` and `let ... else`.** Testing one pattern no longer needs a full `switch`, which matters with `T?` and
  `Result`, and needs no new keyword:

  ```haxe
  if let Some(user) = lookup(id) { ... }
  let Ok(config) = load(path) else return Err(...);
  ```

  A `let` whose pattern can fail must have an `else`, and that branch must leave the scope (`return`, `throw`, `break`,
  `continue`), which the compiler checks through `Never`. This is Rust's `let ... else`; it covers the cases a `Result`
  operator cannot express. Optionals often need neither form, since `T?` narrows after a null test.
- **Patterns over named types.** Haxe's structure patterns (`case {name: n}`) and extractor patterns
  (`case _.length => 3`) depend on anonymous structures, which change 5 removes. Patterns destructure structs and tuples
  by field (`case Rect(x: 0, width: let w):`), and extractors become guards.

### 9. Integer division yields an integer

In Haxe `5 / 2` is the `Float` `2.5`, a JavaScript inheritance, and integer division is written `Std.int(a / b)`. On
integers `/` truncates toward zero, and `%` takes the sign of the dividend; both are specified for every backend. Code
that wants a float converts an operand first. This changes meaning silently, so the Haxe-mode translator rewrites each
integer `/` as an explicit float division.

### 10. Named arguments and default values

Haxe has neither named arguments nor defaults beyond constants, but it lets a call skip optional arguments by matching
their types. Calls may name arguments (`f(width: 10, height: 20)`), parameters take defaults (`x:Int = 0`), and
skipping by type goes away. This also settles optional parameters against `T?` (see the clashes below) and gives
structs a memberwise initializer: `Rect(x: 0, y: 0, width: 10, height: 10)`.
The part that keeps every Haxe call valid (named arguments, expression defaults, memberwise initializers and `with`)
lands as a Haxeon extension: [NAMED_ARGUMENTS.md](NAMED_ARGUMENTS.md). Removing skip-by-type stays here.

### 11. Declared extensions in place of `using`

`using` turns every static function of a module into methods wherever the module is imported. Extensions are declared
once and imported by name: `extension String { function words():Array<String> ... }`. They share the form of
conformance extensions (change 6), so the language has one extension mechanism.

### 12. Ranges

Haxe's `0...n` excludes `n`, which reads as inclusive to anyone coming from Swift, Ruby or mathematics, and it has no
inclusive form, step or reverse. Ranges are `0..<n` (exclusive) and `0...n` (inclusive), as in Swift; `stride` and
`reversed` are library functions.

### 13. Parentheses when mixing bitwise operators

Haxe places `&`, `|` and `^` at one precedence level, above comparisons. Binding tighter than comparisons is kept; mixing
the three without parentheses (`a | b & c`, which Haxe evaluates left to right) is an error.

### 14. Tuples and destructuring

With value tuples (change 5): `let (min, max) = bounds(xs);`, `for (key, value) in map { ... }`, and functions that return
`(Int, String)`.

### 15. Trailing closures

When a call's last argument is a function, it may follow the parentheses:
`new TrackedScope("panel") { ... }`, and likewise `forEach`, `withLock` and test blocks. This gives most of what result
builders would have given the UI ([UI_LANGUAGE_FEATURES.md](UI_LANGUAGE_FEATURES.md)) without a builder transform.

### 16. Structured conditional compilation

Haxe's `#if` works on tokens like a preprocessor: it can wrap part of an expression, code in an inactive branch may not
even parse, tools see one configuration, and conditions test string defines (`-D foo`), so a misspelled define is just
false. The spelling stays; the mechanism follows Swift's `#if`:

```haxe
#if target == Target.wasmGc
function hostString(s:String):JsString { ... }
function fromHost(s:JsString):String { ... }
#elseif target.hasThreads
...
#end
```

- **Whole units only.** Branches hold complete declarations, statements, fields or `case` arms.
- **Every branch parses.** Inactive branches are parsed and formatted, so code for other targets cannot rot silently.
- **Typed conditions.** Conditions read the target profile and typed compile options; string defines become typed
  options, and an unknown or misspelled condition is an error.
- **Checking.** The active branch is type-checked and inactive branches only parsed; parity builds on each target check
  the rest. Checking inactive branches against every target's declarations is a possible later step.
- **Constant expressions.** `#cfg(...)` is a compile-time `Bool`: in `if #cfg(target.hasThreads) { ... } else { ... }` both
  branches are type-checked and the inactive one is folded away. Prefer it when both paths compile everywhere.

`#` marks what the compiler decides (later also `#file`, `#line`), and `@` stays for attributes that describe a
declaration (change 1). A `@cfg` attribute, as in Rust, was considered: it gives the same guarantees, but it puts "does
not exist on this target" in the same form as "is pure", and it must be repeated on each item where `#if` groups them.
Most Haxe `#if` uses already wrap whole declarations or statements, so migration is mechanical.

### 17. No parentheses around conditions; braces always

`if`, `while`, `for`, `switch` and `catch` take their condition or header without parentheses, and their bodies always
take braces, as in Swift, Rust and Go:

```haxe
if ready { start(); } else { wait(); }
while queue.notEmpty { process(queue.pop()); }
for item in items { render(item); }
switch phase { case Idle: ...; case Running(let p): ... }
if let Some(user) = lookup(id) { greet(user); }
try { load(); } catch e:IoError { report(e); }
```

- **Why.** Mandatory braces remove dangling `else` and the indented-but-unguarded statement ("goto fail"). With braces
  required, parentheses around the condition carry nothing, and headers such as `for item in items` and
  `if let Some(x) = e` read better without them.
- **Short conditional expressions get longer.** `if (a) 1 else 2` becomes `if a { 1 } else { 2 }`. This matters because
  dropping the ternary is preferred (see the clashes below), leaving `if` as the only conditional expression; Rust
  accepts the same cost.
- **No trailing closures in condition position.** In `if items.any { it > 0 } { ... }` the parser cannot tell which
  brace opens the body. As in Swift (trailing closures) and Rust (struct literals), a trailing closure there is an
  error: pass the closure in parentheses or parenthesize the call.
- **One-line early exits get longer.** `if (x == null) return;` becomes `if x == null { return; }`; `let ... else` and
  `T?` narrowing cover most of them.
- **Unchanged.** Calls, declarations, lambdas, casts and grouping parentheses in expressions.
- **Migration.** Mechanical: remove the parentheses and add braces where missing.

### Smaller changes

- **`package` inferred from the file path.** Haxe requires it to match the directory, so declaring it is redundant.
- **Enum cases resolved by expected type.** Haxe brings every constructor of an imported enum into scope, where names
  collide. A case resolves from the expected type (`red` where a `Color` is expected) or is qualified (`Color.red`);
  constructors are not imported globally.
- **Arrow lambdas only.** `x -> expr` and `(a, b) -> { ... }` replace the anonymous `function (x) ...` expression;
  `function` remains for declarations.
- **Constraints with `&`.** `T:Hashable & Diffable` in place of `T:(Hashable, Diffable)`.
- **No call-site `inline f()`.** Inlining is the optimizer's decision, or a declaration attribute.

Kept as they are: array and map comprehensions (written `[for x in xs { f(x) }]` under change 17), a required `override`, no C-style `for (;;)`,
and `??=`, `?.` and `??`.

### Clashes to resolve

- **`T?` against optional parameters.** Haxe marks an optional parameter as `?x:Int`. Optional parameters become
  defaults (`x:Int = 0`) or `x:Int?`, and the prefix form goes away.
- **The ternary.** `if` is already an expression, so `a ? b : c` is redundant; dropping it is preferred. It no longer
  blocks errors as values: Haxeon chose prefix `try` for propagation ([ERROR_MODEL.md](ERROR_MODEL.md)), not a
  postfix `?`.
- **String quotes.** Haxe interpolates single-quoted strings (`'$x'`) and not double-quoted ones. Either both
  interpolate or one quote style remains.

## Targets that constrain the design

### What Haxe's targets decided

Many of the Haxe decisions changed above were made so that Haxe could compile to JavaScript, Flash, PHP, Python, Lua,
Java, C# and C++, and had to fit what all of them could express:

| Haxe decision | Target reason |
|---|---|
| 32-bit `Int`, `Int64` as a library abstract | JavaScript bitwise operations, Flash and Java `int` are 32-bit; JavaScript had no 64-bit integer |
| `Float` only 64-bit | JavaScript `number` |
| String encoding left to the target | JavaScript, Java, C# and Flash use UTF-16; PHP, Python and Lua differ. HashLink followed JavaScript and Flash |
| Null everywhere, `Null<T>` for basic types | Dynamic targets allow null everywhere; static targets cannot make basic types null |
| Anonymous structures, structural typing | JavaScript object literals and JSON map onto them directly |
| `Dynamic`, `Reflect` | Natural on dynamic targets and needed for untyped target APIs |
| Abstracts with implicit conversions | Zero-cost wrappers over native target types, and APIs that take several types |
| `untyped`, `__js__`, `@:native`, externs | Escape hatches into each target language |
| `dynamic` methods | Function-valued properties on JavaScript and Flash |
| `Iterator` as a structural typedef | Any JavaScript object with `hasNext` and `next` iterates without interface dispatch |
| `Map` selecting `IntMap`, `StringMap` or `ObjectMap` | Each maps to the target's native map; object keys need per-target identity |
| Throwing any value | JavaScript throws any value |
| ECMAScript syntax | Haxe came from the ActionScript compiler world |
| Macros | Generated code adapts to each target |

What the changes remove were Haxe's interop strengths on dynamic targets. Haxeon targets runtimes it controls
(HashLink, Wasm32, Wasm GC, possibly C), so most of those reasons no longer apply.

### What still constrains us

- **The JavaScript boundary on Wasm GC.** Browser strings are UTF-16 and 64-bit integers cross as `BigInt`. The
  encoding-free string API (change 2) lets Wasm GC hold host strings; 64-bit values crossing to JavaScript need cheap
  bindings or 32-bit types at the boundary.
- **Typed bindings in place of `Dynamic`.** JavaScript calls, JSON and scripting go through bindings generated from Web
  IDL or TypeScript declarations, as C and C++ go through generated header bindings, and an explicit variant type for
  data. This is the cost of changes 4 and 5.
- **Wasm GC is the tightest backend.** It has no interior pointers, no raw memory and no arrays inside structs. New
  types are designed against it first: `Span<T>` is an array reference with offset and length, fixed arrays inside
  structs flatten into fields or move to a separate array, and value types flatten as they do today.
- **The C ABI.** Sized integers, `T?` as a nullable pointer and C-layout structs match C. Layouts stay explicit
  (`Flat`, `Portable` in [STRUCTS.md](STRUCTS.md)) so that a C backend inherits them.
- **Hot patching.** Final-by-default classes and static dispatch let calls be inlined and devirtualized, so every
  backend's patching needs dispatch tables or invalidation of dependent code for a patched method to take effect.

### Specify what Haxe left open

Haxe left some behaviour unspecified so that each target could use its native form: evaluation order in some cases,
integer overflow on JavaScript, `Map` iteration order, float formatting, `Std.int` at the edges and static
initialization order. Haxeon aims for identical results on every backend, enforced by parity tests, and owns every
runtime, so the new language specifies them: strict left-to-right evaluation, wrapping integers, `Map` iteration in
insertion order (or explicitly unordered but deterministic), shortest round-trip float formatting (Ryu is already in
the standard library), and a defined initialization order.

### If JavaScript output is kept

Haxeon has no JavaScript backend today. Keeping one possible puts pressure on three decisions:

- **`Int`.** JavaScript has no 64-bit integer. `BigInt` is correct and slow; pairs of 32-bit halves, as Haxe's `Int64`,
  turn every operation into several and usually allocate; doubles are wrong beyond 2^53. A 64-bit `Int` would make
  every loop counter pay. If JavaScript is first-class, `Int` stays 32-bit and wrapping (`|0` in JavaScript) with an
  explicit `Int64`; if it is secondary, `Int` stays 64-bit and the JavaScript output is slower (change 3).
- **Strings.** JavaScript engines optimize only native strings, and the DOM takes them. The encoding-free API
  (change 2) lets JavaScript store native strings.
- **Value types.** Structs become objects or scalars. Immutable structs share a reference safely, so their copies are
  free; mutable structs copy on assignment, which allocates. Arrays of structs become parallel typed arrays or arrays of
  objects, and `Span<T>` an array with offset and length. Semantics hold; flat-memory performance does not. This favours
  immutable structs by default, as the UI value types already are.

The rest erases cleanly: non-null types, `Result`, enums, conformances, newtypes, `let` and `var`, `switch`,
`let ... else`, attributes and modules are compile-time features. Sized integers up to 32 bits use `|0`, `>>>0` and
typed arrays; `Float32` uses `Math.fround`. JavaScript `Map` iterates in insertion order, though `Hashable` keys still
need our own hash map since JavaScript compares keys by identity. Number formatting is already shortest round-trip.
Hot patching is simplest there, since functions can be replaced.

JavaScript adds the most restricted target profile ([ADR 0003](../adr/0003-compiler-architecture.md)): no native
memory, no C or C++ bindings and no shared-memory threads except through Wasm, so packages built on them (`gpu`,
`audio`, native SDKs) are unavailable.

A JavaScript backend earns its place through bundle size, startup, readable output for debugging, embedding in existing
JavaScript and TypeScript applications or npm packages, and older browsers. Running applications in a browser alone is
covered by Wasm GC, which every major browser ships, and needs only the string decision above.

Decisions that help JavaScript and are right anyway are taken now: the encoding-free string API and immutable structs
by default. `Int` is decided explicitly once JavaScript's role is known. New types are designed against the two most
constrained targets, Wasm GC and JavaScript.

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

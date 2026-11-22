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

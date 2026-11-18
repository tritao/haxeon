# 6. Whether the compiler's source may require Haxeon

Date: 2026-11-18

## Status

Proposed. Nothing is decided; this records the question, what it would buy and cost, and the conditions for deciding.

ADR 0003 §12 is about which compiler *builds* the shipped worker. This ADR is about the *source*: whether it may stop
compiling with stock Haxe, so that it can use Haxeon-only language and library features.

## Context

The compiler's source compiles with both the pinned stock Haxe (`.tools/haxe`) and Haxeon:

- **Stock Haxe builds** the development tools (`haxeon dev tool-path`, `ToolArtifacts`), the test driver, and the seed of
  the bootstrap (`scripts/bootstrap-compiler.sh`, `HaxeonBuild bootstrap`).
- **Haxeon builds** the checked-in release bootstrap (`bootstrap/compiler.hl`, ADR 0003 §12) and, in the self-hosting
  check, itself to a fixed point.
- **The cost of keeping both:** code forks by build (`#if haxeon` in seven files, among them `HlWriter` and
  `SemanticAssembly`), general-purpose code lives in the portable root (`lib/haxeon-io`), the Haxeon stdlib is out of the
  compiler's reach (ADR 0003 §12), and code is written to the common subset, including where Haxeon is stricter than Haxe
  (null narrowing through a `Bool` temporary or a map read).

The question came up from compiler performance (2026-11-18): could Haxeon-only features such as structs and bitfields give
the compiler native-like memory behaviour? An allocation census of the compiler compiling itself (Haxeon-built, release,
4.99 GB allocated) answers part of it:

| Allocated as | Share |
|---|---:|
| array storage | 34% |
| untyped buffers (`Int`/`Float` array storage, string characters, map index arrays) | 27.5% |
| map storage | 13% |
| `String` objects | 6% |
| all of the compiler's own record types (`SourceSpan`, `IrInstruction`, `Token`, `Located`, ...) | about 15% |

Most of the memory is containers: a new map or array per function per pass, operand arrays per instruction, maps
regrowing from small sizes, and strings built as keys. That is fixed by data layout that plain Haxe already expresses: ids
instead of objects, tables indexed by id, reusable per-function contexts, interned types and symbols. Value types address
the records, the smaller part, and only once arrays hold them inline: today a struct is stored inline in fields but boxed
as an array element, local, parameter or return (`docs/design/STRUCTS.md`).

## What requiring Haxeon would buy

- **Language features in the compiler:** structs (with inline `Array<S>` once it exists), `Hashable` structs as map keys
  (a `(block, slot)` key without building a string), payload-free enums as scalar tags, closed flags, fixed arrays, struct
  bitfields when they exist.
- **The Haxeon stdlib:** the runtime library and typed maps. Allocation regions (ADR 0004 §6) do not need this: that ADR
  already reaches them from the stock-built compiler through `@:hlNative`, and they are built on the fork's owner pages
  (`hl_gc_owner_live_count`, `hl_gc_owner_release`); the per-thread current owner and the stdlib `Region` are not yet
  implemented.
- **One source:** no `#if haxeon` forks, no common-subset workarounds, no `lib/haxeon-io` for portability's sake.
- **Dogfooding:** compiler performance work drives the language and runtime features users get.

## What it would cost

- **Bootstrap without stock Haxe.** The checked-in release bootstrap becomes the only seed: every source change that
  needs a newer compiler needs the seed refreshed first, as rustc's stage0. Refreshing must be routine and pinned by hash
  (ADR 0003 §12 leaves this open), and a miscompile that breaks the compiler must be recoverable from the previous seed.
- **An independent oracle.** Today a stock-built compiler can be compared with the Haxeon-built one. Without it, the
  self-hosting fixed point (stage 2 builds stage 3 byte for byte) catches nondeterminism but not a miscompile that
  reproduces itself. Differential program tests against stock Haxe still check what the compiler produces; they do not
  check the compiler.
- **Tools and tests.** The development tools and the test driver move to Haxeon builds, cached like `tool-path`. Their
  build time is the Haxeon compiler's: 24 s for the server against stock Haxe's 15 s (2026-11-17), less with the compile
  server's incremental rebuilds.

## Decision criteria

Decide when all of these hold, measured, not before:

1. **A feature the compiler needs and plain Haxe cannot express efficiently** exists and is implemented: inline `Array<S>`
   for structs on HashLink, or `Hashable` struct keys in maps, with a measured gain on the compiler's own workload over the
   plain-Haxe data layout.
2. **The seed is routine:** pinned by hash and fetched (or rebuilt), refreshed by one command, with a documented recovery
   from a broken seed.
3. **The oracle is replaced:** the self-hosting fixed point in CI, plus a check that the compiler built by the previous seed
   and by itself produce the same output for the program suites.
4. **The development loop does not regress:** tool and test-driver builds through the compile server are no slower than
   with stock Haxe today.

Until then, compiler performance work stays in plain Haxe (data layout, ids, reusable contexts, `abstract` over `Int` for
packed fields), so it helps both builds and does not depend on this decision.

## Consequences

- If accepted: the `#if haxeon` forks and the portable-root rule end, the stdlib and value types become available to the
  compiler, and stock Haxe remains only as the reference for the language's semantics in the program tests.
- If rejected or deferred: the compiler keeps to the common subset; Haxeon-only features reach users first and the
  compiler only through plain-Haxe equivalents.
- Either way, inline struct arrays and struct bitfields are language work worth doing for users.

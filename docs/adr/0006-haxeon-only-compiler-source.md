# 6. Whether the compiler's source may require Haxeon

Date: 2026-11-18

## Status

Accepted as the direction (2026-11-19): the compiler's source will require Haxeon. The switch is staged: the decision
criteria below are now the gates of the migration, and the source keeps compiling with stock Haxe until all of them hold.

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

## Decision

The compiler's source moves to Haxeon, because the long-term design of the compiler needs what only Haxeon gives it:
ADR 0003's query engine keeps every phase's output, and an output that is ids and inline values (decision 14 there) is
what makes a large retained session affordable. Plain Haxe can pack a field into an `abstract` over `Int`, but not a
record with an object in it, such as a source span (a file and a range), which is what the compiler's records are made of.

What plain Haxe can do was done first, measured on the compiler's own sources (2026-11-18 and -19): interned names (one
string per identifier) and slim spans (48 to 24 bytes, with reference and generated data in subclasses). A span packed
into an integer was ruled out: it needs a process-wide file table and an explicit release protocol in the compile server,
since the span would no longer keep its file alive. With a struct, a span is `{file, start, end}` inline in the node that
has it, and the file keeps today's lifetime.

## Migration gates

The switch happens when all of these hold, measured, not before:

1. **Structs the compiler can use** exist on HashLink, with a measured gain on the compiler's own workload over the
   plain-Haxe data layout:
   - a struct passed as a local, parameter or return value is not boxed (today it is, so a span struct would allocate
     more than the span object it replaces);
   - inline `Array<S>`;
   - `Hashable` struct keys in maps.
2. **The seed is routine:** pinned by hash and fetched (or rebuilt), refreshed by one command, with a documented recovery
   from a broken seed.
3. **The oracle is replaced:** the self-hosting fixed point in CI, plus a check that the compiler built by the previous seed
   and by itself produce the same output for the program suites.
4. **The development loop does not regress:** tool and test-driver builds through the compile server are no slower than
   with stock Haxe today.

Until then, compiler performance work stays in plain Haxe (data layout, ids, reusable contexts, `abstract` over `Int` for
packed fields), so it helps both builds. New compiler code is written so that the switch is mechanical: records that will
become structs are immutable and compared by value, never by identity.

Order: gate 1 is language and runtime work and comes first; gates 2 and 3 are build work and can go in parallel; gate 4 is
measured last. The first compiler records to become structs are `SourceSpan`, the IR operand, and the interned symbol and
name ids of ADR 0003 decision 5.

## Consequences

- The `#if haxeon` forks and the portable-root rule end, the stdlib and value types become available to the
  compiler, and stock Haxe remains only as the reference for the language's semantics in the program tests.
- Until the gates hold, the compiler keeps to the common subset, and stock Haxe remains its bootstrap seed and oracle.
- Unboxed struct locals and parameters, inline struct arrays and struct bitfields are language work users get as well.

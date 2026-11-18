# Compiler data layout

Status: proposed 2026-11-18. Two steps done (below); the rest is a plan.

The compiler should run close to what a native compiler written for speed would: little allocation per function compiled,
few hash lookups, data that is read in order. This note says where its memory goes and the layout that fixes it. It is
plain Haxe throughout, so it helps the stock-built and the Haxeon-built compiler alike (ADR 0006 says when Haxeon-only
features would be considered).

## Where the memory goes

The compiler compiling itself (Haxeon-built, release, frozen input) allocates 5.05 GB. `hlprof-live` with `--sources
alloc` and `report --alloc [--types]` (see `docs/reference/PROFILING.md`) splits it:

| Allocated as | Share | Mostly |
|---|---:|---|
| new arrays | 24% | a fresh array per function per pass; operand and instruction arrays per IR node |
| array growth | 10% | `push` outgrowing an array that could have been sized or reused |
| map storage | 22% | a fresh map per function per pass, grown from seven entries; string-keyed and int-keyed alike |
| strings | 14% | keys built by concatenation: type texts (`IrTypeIdentity`, `typeKey`, `SemanticSignature`), names |
| the compiler's own records | about 15% | `SourceSpan`, `IrInstruction`, `CfgInstruction`, `Token`, `Located`, AST and typed nodes |

Records are the smaller part. Containers are most of it: how many are made, how they grow and what they are keyed by.
No single site is above 3%.

## The layout

1. **Ids, and tables indexed by id.** Blocks, values, registers and locals are small integers within a function. A side
   table about them is an array indexed by id, sized once, not a `Map<Int, ...>`: no hashing, no growth, no boxing.
   Classes that own such tables expose questions (`successorsOf`, `immediateDominator`), never the tables. *Done for
   `IrGraph` (`0064b0f61`): -3.1% bytes.*
2. **Reusable per-function contexts.** A pass or lowering stage keeps its working tables as fields and clears them
   between functions without shrinking them. In steady state compiling a function allocates its output and little else.
   *Done for `HlRegisterAllocation`'s liveness sets (`cf53851e4`): -6.6% bytes.* Next: `IrNonNullFacts`,
   `IrReachabilityWalk`, `HlLower.lowerFunction`'s per-function maps, `IrGenerator.lowerOperands`.
3. **Operand pools.** An instruction's operands, a block's instructions and a phi's inputs are ranges in one array per
   function, not an array each. This is the IR's own representation, so it changes with the IR core (step 6).
4. **Interned types and symbols.** A type or symbol gets an id once per session; maps keyed by it become tables, and no
   key text is built per lookup. First `HlSymbolTable.internType`, then `SemanticSignature` in `IrGenerator.lowerType`,
   then `IrEnumEscapeReach` and `RuntimeAbi`. This is ADR 0003 M3's integer identities, done where the census says.
   *Interned types.* `IrType` is an enum built with literals everywhere, so equal types are different values and cannot
   carry an id. `IrTypeMap<V>` keys a table by a type's structure instead: it hashes a type by walking it (constructor,
   name characters, children) and compares candidates with `IrTypeIdentity.same`, so a lookup builds no text and
   allocates nothing; only an insertion grows the table. Keys that are text today become `IrTypeMap`s. Text identity
   (`IrTypeIdentity.text` and `id`) stays where it is persisted or must be the same in both builds of the compiler:
   symbol-state codecs, digests, runtime type discriminators. `HlSymbolTable` keeps its text-keyed `typeIndices`, which
   it persists, and answers lookups through an `IrTypeMap` index over it that is part of its copy-on-write state and is
   dropped when `renameTypes` rewrites the keys. A table of dense type ids (`IrTypeMap<Int>` handing out numbers) is the
   next step once consumers want arrays indexed by type.
5. **Packed small fields.** Flags and small enums in one `Int`, behind an `abstract` with inline accessors: free in both
   builds. Struct bitfields are language work (`STRUCTS.md`) the compiler would use only under ADR 0006.
6. **The IR core in columns.** Instructions as rows of parallel `Int` columns (opcode, type id, operand range) with the
   operand pool, values and blocks as ids, side tables per pass reused (1 to 4). This touches every pass, so it gets its
   own design note, with a migration that lets passes move one at a time behind the current API.
7. **Regions for what is left** (ADR 0004 §6): per-stage temporaries allocated in a region the GC releases without
   marking the heap, once the above has made outputs and temporaries easy to tell apart.

Rejected: per-object structs as the first step (records are 15%, and struct array elements are still boxed), arenas
released without a liveness check (ADR 0004 §6), and a faster array growth factor (tried; fails the UI memory rule,
`STRUCTS.md`).

## How each step is checked

On a frozen copy of the compiler's sources, the compiler before and after the change compile it and must write the same
bytes. Allocated bytes (`HL_GC_PROFILE=1`, exactly reproducible) and main-thread instructions (`perf stat --per-thread -e
cpu_core/instructions/u` with `HL_GC_MARK_SERIAL=1` on the performance cores, reproducible to 0.03%) are reported in the
commit. Then the tests for the code touched: the full test driver for IR passes, parity for the Wasm backend.

Progress so far: 5,582 MB to 5,054 MB allocated (-9.5%), main-thread instructions 115.2G to 105.8G (-8.2%).

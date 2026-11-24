# Compiler data layout

Status: proposed 2026-11-18. Two steps done (below); the rest is a plan, revised 2026-11-20 (direct SSA, census).

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

The allocation census of 2026-11-20 (`HAXEON_COMPILER_ALLOC_CENSUS`, same input, after the steps below) agrees: 3.60 GiB in
81.8 million allocations; array storage 40%, untyped buffers 22%, maps 12%, `String` 5%, the compiler's records about
15%. By the innermost compiler frame the IR pipeline leads: `SsaBuilder` 7.6%, `HlLower` 7.2%, `Parser` 4.5%,
`CfgBuilder` 4.3%, `IrInliner` 4.3%, `IrGenerator` 3.4%, then a tail where 40 files reach 79%. Every function is built
twice, as a CFG over named locals (1.36 million `CfgInstruction`s, each in a `Located`) and then as SSA.

What stays alive is much smaller than what is allocated. With one arena per phase (ADR 0004 section 6), the
data each phase made that is still reachable when the compile ends is 283 MB in all: parse and semantic 83, typing 11,
IR generation 61, IR assembly 51, HashLink lowering and encoding 77. Peak resident memory (1.92 GB) is collector slack
over a live set of 0.3 to 0.55 GB, so the peak follows allocation volume and the collection trigger, not the size of the
retained structures. Each phase's survivors are spread over 95 to 100% of its group's pages, so releasing a phase's
pages frees almost nothing yet: arenas wait until outputs and scratch are allocated apart (step 9).

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
   function, not an array each. This is the IR's own representation, so it changes with the IR core (step 7).
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
   next step once consumers want arrays indexed by type: `INTEGER_IDENTITIES.md`, "Types".
5. **Packed small fields.** Flags and small enums in one `Int`, behind an `abstract` with inline accessors: free in both
   builds. Struct bitfields are language work (`STRUCTS.md`) the compiler would use only under ADR 0006.
6. **SSA built during IR generation.** `IrGenerator` reads and writes locals through the builder, which places phis
   as it goes (Braun et al., "Simple and Efficient Construction of SSA Form"): blocks are sealed once their
   predecessors are known, a read in an unsealed block makes an incomplete phi, and trivial phis are removed. The CFG
   form over named locals, its verifier, liveness and the dominance-frontier phi placement go. Design in
   `DIRECT_SSA.md`.
7. **The IR core in columns.** Instructions as rows of parallel `Int` columns (opcode, type id, operand range) with the
   operand pool, values and blocks as ids, side tables per pass reused (1 to 4). This touches every pass, so it has its
   own design note, `IR_CORE_COLUMNS.md`, with a migration that lets passes move one at a time behind one API.
8. **Tokens as a table.** The lexer's tokens as rows of a per-file table, spans made only for the nodes that keep them
   (`TOKEN_TABLE.md`).
9. **Arenas** (ADR 0004 §6): data with one end of life allocated in an arena and released as soon as it is dead, at a
   known point and in bulk, rather than when the collector next runs. Two conditions, which the syntax-region pilot
   missed (its survivors were on nearly every page): an arena holds only what dies together, and its release is checked
   and falls back to the collector when something still points in. The candidates: units of work (a class typed, a batch
   of functions lowered), whose temporaries are 85% of what they allocate, 1.5 GB in all; the front end of a one-shot
   build (syntax and typed trees), released after IR generation once what the IR keeps of it (files, spans, names)
   lives outside it; and a build's temporaries in the compile server, once what the session retains and what a build
   discards are apart. Reused scratch (steps 3 and 7) removes the tables, not the rest. The fork releases an arena
   without a collection. Design, measurements and order: `ARENAS.md`.

Flat records (step 7) are written so the source still builds with stock Haxe: a record is declared once as a struct
under `#if haxeon` and as a final class otherwise, in one package, immutable and compared by `equals`, never by identity,
so both builds behave the same and only their layout differs (proposed amendment to [ADR 0006](../adr/0006-haxeon-only-compiler-source.md)).

Rejected: per-object structs as the first step (records are 15%, and struct array elements are still boxed), arenas
released without a liveness check (ADR 0004 §6), and a faster array growth factor (tried; fails the UI memory rule,
`STRUCTS.md`).

## How each step is checked

On a frozen copy of the compiler's sources, the compiler before and after the change compile it and must write the same
bytes. Allocated bytes (`HL_GC_PROFILE=1`, exactly reproducible) and main-thread instructions (`perf stat --per-thread -e
cpu_core/instructions/u` with `HL_GC_MARK_SERIAL=1` on the performance cores, reproducible to 0.03%) are reported in the
commit. Then the tests for the code touched: the full test driver for IR passes, parity for the Wasm backend.

Progress so far: 5,582 MB to 5,054 MB allocated (-9.5%), main-thread instructions 115.2G to 105.8G (-8.2%).

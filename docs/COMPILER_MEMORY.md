# Compiler worker memory

Status: census (2026-11-09), no fixes made. `materia/app`, plain `build --compiler-only`, the persistent compiler worker, default GC
settings (`HL_GC_MARK_THRESHOLD=0.4`, set by the launcher). Tools: `HAXEON_COMPILER_MEMORY_LOG`, `HAXEON_COMPILER_HEAP_DUMP(_ON)` and
`HAXEON_COMPILER_CENSUS` in the worker (`CompilerMemoryLog`, `CompilerMemoryCensus`), `scripts/hl-heap-tally.c` and
`scripts/hl-heap-names.py` for the dumps.

## What the numbers are

| | cold build | repeated no-op | after an edit |
|---|---|---|---|
| process peak during the build (ps, 1 s) | 6.6-7.1 GB | 6.6-7.5 GB | 8.9-9.2 GB |
| GC page memory after a forced major GC | 6.10 GB | 6.17-6.24 GB | 7.93 GB |
| of which live blocks (heap dump) | 3.73 GB | - | 4.43 GB |
| space in pages that hold no live block | 2.76 GB (43%) | - | 4.07 GB (48%) |
| allocated during the build | 33.8 GB | 1.5 GB | 14.0 GB |

Three separate things make up the footprint:

1. **Live data: 3.7 GB after a cold build, 4.4 GB after an edit.**
2. **Page space that holds no live block: 2.8 GB, 4.1 GB after an edit.** The collector does not move blocks; a page is returned only
   when it is empty. Scan pages are 66% used after a cold build, pointer-free pages 46%, raw pages 18%. Releasing 2.4 GB of live data
   (the owner census below) freed only 0.8 GB of pages. Memory that was once used for transient objects stays resident.
3. **Slack before a collection starts.** With `HL_GC_MARK_THRESHOLD=0.4` the heap grows 40% past the last live size before marking;
   the edit build ends at 8.5 GB before its major collection and 7.9 GB after it.

## Live data by owner

Released one at a time in the order shown, with a memory dump and a tally by live bytes after each. A step removes what only that owner
kept alive after the earlier steps; shared data lands on the first owner released. The remaining 1.36 GB is the floor: source texts,
type and semantic registries, the compiler's own code and statics, and what this list did not release.

| released (cumulative order) | live GB removed | notes |
|---|---|---|
| cached compile result | 0.000 | shares everything with the snapshot and the assembler |
| pipeline snapshot (final IR, module) | 0.011 | idem |
| encoded module bytes + writer cache | 0.159 | 100 MB module bytes kept for the reuse shortcut + encoded functions |
| lowered function cache | 0.000 | its code and requests are also held by the assembler (see next) |
| **last assembler** (HL functions, symbol tables, lowered cache) | **0.816** | the HL module: ~3M opcodes, their debug records, 3M recorded requests (0.10 GB) |
| inline cache | 0.133 | |
| object cache | 0.001 | |
| last typed program, semantic program | 0.081 | |
| typed functions of modules | 0.250 | |
| IR functions of modules | 0.188 | |
| canonical declarations of modules | 0.106 | |
| semantic models of modules | 0.000 | |
| **tokens and syntax trees of modules** | **0.625** | 3354 modules: 3.35M tokens, 1.3M expressions |
| reachability, declaration owners | 0.004 | |

## Live data by type (cold build)

| type | GB | blocks |
|---|---|---|
| anonymous-structure records `{column,end,endColumn,endLine,...}` | 0.672 | 4.26M |
| pointer-free blocks (string bytes, byte buffers, int arrays) | 0.737 | 8.1M |
| arrays (`varray`) | 0.585 | 7.7M |
| `SourceSpan` | 0.235 | 4.9M |
| `String` | 0.180 | 7.5M |
| `Token` | 0.107 | 3.35M |
| IR: `IrInstruction`, `Located`, `IrValue`, `SourceLocation`, `IrBlock`, `SourceProvenance`, `IrTerminator`, `IrType` | 0.37 | ~11M |
| `HlSymbolRequest` (lowering requests of the reuse cache) | 0.098 | 3.0M |
| `HlInstruction` | 0.072 | 3.0M |
| typed trees: `TypedExpression`, `TypedExpressionKind`, `TypedStatement` | 0.12 | 2.7M |

The anonymous-structure records are Haxe `typedef` structures. In HashLink each is a virtual object with its own field table, about
158 bytes against ~50 for a class of the same fields. The 4.26M here are most likely the HL debug records: `HlDebugLocation` (one per opcode of
each lowered function) and `HlOpcodeSourceSpan` (a second copy per opcode, kept by the debug metadata cache). Both typedefs begin with
the same field names and the tally names a virtual type by them, so it cannot tell the two apart; the 3.0M `HlInstruction` blocks fit
about one record per opcode for each.

An edit adds 0.69 GB of live data over the cold state: pointer-free +0.32 (probably encoded function bytes and module bytes; the
tally does not say which), arrays +0.09, AST nodes +0.02 and small amounts elsewhere. Pages grow by 2.0 GB, so fragmentation takes the larger share.

## Fixes, ranked by edit-build peak saved

Estimates are from the census and the GC runs; none is implemented.

| # | fix | saves (edit peak) | cost / risk |
|---|---|---|---|
| 1 | **Lower `HL_GC_MARK_THRESHOLD`** (measured: 0.4 → 0.2) | **2.1 GB** (9.22 → 7.15); 0.1 → 6.54 | GC time on the edit build 4.8 → 7.7 s (+2.9 s), on a cold build 10.8 → 27.9 s (+17 s). A threshold that depends on the build (cold 0.4, warm 0.2) needs a runtime setting; the process reads it at start |
| 2 | **Store the HL debug records compactly**: one record per distinct location instead of one per opcode, or per-function arrays; drop the second copy (`HlOpcodeSourceSpan`) in the debug cache and keep the encoded payload | 0.4-0.6 GB live, ~0.8 GB peak | contained in `HlLower`, `HlDebugMetadataCache`, `HlWriter`; byte-identical output |
| 3 | **Keep lowered functions compactly**: the reuse cache and the retained module hold the HL code as objects (~0.8 GB); the encoded form is ~0.1 GB. Cache encoded function bytes plus the relocation list and rewrite bytes when linking; check whether `context.assembler` needs to be retained for plain builds at all (a plain build starts a fresh assembler) | 0.5-0.7 GB live | larger change in `HlLink`/`HlWriter`; the writer already encodes per function |
| 4 | **Drop tokens (and recovered/last-good copies) of modules after they are typed**, in non-editor sessions | 0.3-0.5 GB live | the editor needs them; sessions would need a flag; re-lexing on demand |
| 5 | Retain one generation of the encoded function cache and module bytes, not two (the edit build's pointer-free growth) | ~0.3 GB | `HlWriterCache`, `CompilerSession.encodedModule` |
| 6 | Fewer transient objects in the IR passes (the edit build allocates 14.0 GB) | slack and fragmentation | this is the pass work in WARM_REBUILD_REUSE.md (B); every pass that stops rebuilding unchanged functions helps |
| 7 | Compact the 0.9 GB of `SourceSpan` + `Token` + AST spans (flyweights, no `file` pointer per span) | 0.2-0.3 GB live | parser and AST wide |

To reach an edit peak under ~8 GB: 1 alone reaches ~7.2 GB at the cost above; 2 + 3 + 5 together are estimated at -1.5 to -1.8 GB
(about 7.3 GB) with no GC time cost, and they also lower what a warm session holds between builds.

## Method notes

- `ps` peaks are sampled once a second and vary with the machine's load by a few hundred MB between identical runs.
- The page figures are the collector's `pages_total_memory`; the live figures are the sum of block sizes in the dump. Blocks are
  classified by the first word (the type pointer); pointer-free pages have no type, so their bytes are one row.
- The dump format and the type table are those of the HashLink in `vendor/hashlink` (`gc.c` `hl_gc_dump_memory`), and types are named from
  the worker's bytecode (`~/.cache/haxeon/compiler/<version>.hl`).
- An `earlyoom` SIGTERM at 10% available memory ended the worker several times during the measurements for this work, in builds with
  and without any of the new caches.

## Order of work and open items (dev-71, 2026-11-09)

Structural fixes first, each its own commit with byte-identical output, the suite, and cold/no-op/edit peaks: (a) fix 2, compact HL debug
records; (b) fix 5, one generation of encoded function and module bytes; (c) fix 3, lowered functions cached as encoded bytes plus
relocations. Then re-measure; a lower GC threshold is considered only if the edit peak is still above ~8 GB, and then as a per-build
setting made by the compiler through a runtime call in our HashLink (a global 0.2 is rejected: +17 s GC on a cold build).

Done:
- (a) `HlDebugLocation` is a class and the opcode source-span section is encoded from each function's locations, so the second per-opcode
  copy (`HlOpcodeSourceSpan` and the span cache) is gone. app: cold 789.5M -> 783.2M objects; edit peak 8.93 -> 8.31 GB.

Deferred (open items):
- Fix 4, dropping tokens and syntax trees of typed modules, needs the editor/build session split (ADR 0003 option 9).
- Fix 7, compacting `SourceSpan`, `Token` and AST spans, is parser-wide.
- Fix 6, fewer transient objects, comes with the pass work (M2).


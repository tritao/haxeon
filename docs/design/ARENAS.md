# Arenas

Status: proposed (`COMPILER_DATA_LAYOUT.md` step 9, ADR 0004 §6). The runtime part is in the fork (below); the compiler
uses none yet. Measured on the frozen self-compile input.

This is region-based memory management with a checked release. We call a region an **arena** at every layer: the fork's
API (`hl_gc_arena_*`, std primitives `gc_arena_*`), its diagnostics (`HL_GC_ARENA_*`), and the compiler's `Arena`.

## Problem

The compiler compiling itself peaks at 1.82 GB resident; stock Haxe compiling the same sources to HL peaks at 531 MB. The
live data is not the difference: 0.3 to 0.55 GB is live (`COMPILER_DATA_LAYOUT.md`). The peak is what is allocated
between two collections plus space the next phase cannot reuse:

| Time | Event | Resident |
|---:|---|---:|
| 1.1 s | front end starts | 0.13 GB |
| 4.0 s | collection 1 (1 GB allocated since start) | 1.11 GB |
| 6.6 s | front end done (syntax released) | 1.31 GB |
| 8.7 s | collection 2, during the IR passes | 1.48 GB |
| 11.0 s | IR done | 1.47 GB |
| 13.1 s | backend done | 1.79 GB |
| 13.3 s | collection 3, peak | 1.82 GB |

Each collection frees a lot, yet the heap keeps growing: freed blocks sit in part-full pages of the size classes the last
phase used, and the next phase allocates other sizes. Two measurements show that shrinking the live set does not move the
peak while the collection schedule stays the same:

- dropping the canonical AST and the import cache with the syntax (they were held to the end): peak 1.82 GB, unchanged;
- dropping the typed program right after the IR tables are assembled, so collection 2 frees it: peak 1.82 GB, unchanged.

Collecting more often would lower the peak but is ruled out: one-shot compiles collect after every gigabyte on purpose
(`ProcessMemory`). What lowers the peak without more collections is allocation the collector never sees: temporaries of a
unit of work placed in pages of their own and recycled in bulk when the unit ends.

## Decision

An **arena** is a set of pages that a thread allocates into while the arena is current. A unit of work runs with its own
arena current; what it returns is placed outside on purpose; when it ends, the arena is released: checked for pointers
into it and, if there are none, its pages are reused by the next arena at once and what it allocated leaves the count
that starts the next collection. If something still points in, the release falls back: the pages join the collector's,
and the references are reported. Correctness never depends on an arena, only memory does.

Arenas nest. Each unit names where its outputs go: the enclosing unit's arena, a stage's output arena, the session arena,
or the global one. "Outside" is always an explicit target, never "the parent", because the inliner's units are recursive
(a callee's inlined form is computed inside its caller's unit but belongs to the stage).

## Arenas by lifetime

| Arena | Lives for | Holds |
|---|---|---|
| global | the process | interned names (`NameTable`, `IrSymbol` table), type ids, source files |
| session | the compile server's session | module states and their incremental records, the type registry, the inline memo |
| build | one compile | the program IR, its tables, the output |
| phase | the front end, until IR generation | tokens, syntax, canonical declarations, semantic models, typed program, typer scopes |
| unit | one class typed, one function lowered | everything the unit allocates except its outputs |

## How placement is expressed

No new expression syntax: it would need `#if haxeon` at every allocation site and break the stock-Haxe build. Two ways
instead, both plain Haxe:

1. **The current arena, scoped by a call.** `Arena.within(arena, () -> work())` makes `arena` current on the thread while
   `work` runs, so everything its callees allocate follows; the previous arena is current again afterwards. Outputs go
   elsewhere explicitly: their construction is scoped in the target (`Arena.within(target, () -> finish())`), or they are
   copied out at the unit's finish. `within` releases a unit arena from its own frame, which existed while `work` ran
   (below, "Soundness").
2. **A home on long-lived types.** `@:arena(global) class IrSymbol` makes instances go to that arena wherever they are
   created. The HL lowering honours it by setting the type's home when the module loads (`hl_gc_arena_set_home`); stock
   Haxe ignores the metadata.

Under stock Haxe, or off HashLink, `Arena.within` just calls the function. Safety stays in the runtime: the checked
release, the fallback, and diagnostics naming each escape by holder.

## Measured units

Units, with what each allocated and what it would free (one group for all units of a stage, released once at the end of
the stage; "kept" is what was still reachable then):

| Unit | Units | Allocated | Kept | Would free | Kept as |
|---|---:|---:|---:|---:|---|
| type one class's method bodies (`ProgramTyper.typeClassMethods`) | 539 | 729 MB | 98 MB | 86% | typed bodies, `TypingOutput` records |
| generate one function's IR (`IrGenerator.generateFunction`) | 8,103 | 312 MB | 97 MB | 69% | the IR body; SSA scratch grown inside |
| inline one function (`IrInliner.run` loop body) | 8,628 | 411 MB | 63 MB | 85% | inlined bodies; memo and dependency tables filled inside |
| lower one function (`HlLower.lowerFunction`) | 8,237 | 344 MB | 50 MB | 85% | `HlFunction` (instructions, debug locations); interned HL types and strings; scratch grown inside |

These four units alone are 1.8 GB of the 3.1 GB the compile allocates, 1.5 GB of it temporaries. The largest single unit is
37 MB (an inliner unit, recursive); a function unit averages 40 to 50 KB, a class 1.4 MB.

## The front end as one arena

A group from the start of the build to the IR tables (1.9 GB allocated, 0.83 to 0.86 GB of pages held at release, all of
them kept in every row below, because what escaped is spread over every page):

| Released at | Live blocks | Escaped | Held by |
|---|---:|---:|---|
| syntax released, before the IR tables | 7.8 M | 290 MB | the typed program (still in use), canonical AST, everything below |
| backend done | 6.0 M | 227 MB | canonical AST lists of every module state; the typed program; the IR; session records |
| backend done, canonical AST and import cache dropped | 4.8 M | 188 MB | the typed program, from a dead register slot of `CompilationPipeline.compile` |
| transaction returned | 2.6 M | 101 MB | the final IR (bodies made during publication); names; session records |
| as above, IR generation, `NameTable` and one-shot records outside | 0.45 M | 19 MB | names the typer and IR keep, literals, symbol table, session records |

The **canonical-AST holder** the syntax pilot did not find: `releaseSyntax` clears `canonicalFunctions` and
`canonicalAllFunctions` but not `canonicalProgramFunctions`, `canonicalAliases`, `canonicalEnums`, `canonicalAbstracts`,
`canonicalInterfaces`, `canonicalClasses`, `canonicalNamespaceUses`, `canonicalFunctionNamespaceUses` or `canonicalCalls`,
and `ModuleAnalyzer.importedMembers` (an AST per imported module) survives `releaseLookupParses`. Cleared, no AST
node is reachable after the front end.

What later phases keep from the front end: the IR made during publication (49 MB: values, instructions, blocks,
`SourceLocation`, `SourceProvenance`); 46 MB of strings (names in instructions, value names, debug-binding identities,
literals, type names, symbol names; the lexer's `NameTable` is made inside whatever arena is current, and the typer's own
names are not interned); session records a one-shot compile never reads (`semanticDependencies`, fingerprints, purity and
no-return queries, invalidations); the type registry's entries. Not spans: IR keeps its own locations.

## Runtime (in the fork)

- **Arenas as a thread's current allocation target**, nested: `hl_gc_arena_enter` returns the arena it replaces and
  `hl_gc_arena_leave` restores it. An arena's blocks go to pages of its own (an owner class), with the thread's
  allocation buffers per class, so compiled code allocates inline into the current arena.
- **Homes**: `hl_gc_arena_set_home(type, arena)`, `hl_gc_arena_global()` for the collector's pages,
  `hl_gc_arena_set_home_of(value, arena)`. Inline allocation guards on the type's home, so a home set after compilation
  takes effect. Array and map storage grown inside an arena goes where the container is (`hl_gc_arena_owner_of`), so a
  table a unit only extends does not keep it.
- **Release without a collection** (`hl_gc_arena_free`). A pointer into an arena can only be in memory written since it
  was opened: heap pages written while it was open, the roots, and the stacks and registers. Every heap page is registered
  with a userfaultfd in asynchronous write-protect mode; `PAGEMAP_SCAN` returns the pages written since the last scan and
  protects them again; a log of scans lets nested and sequential arenas each read the writes since they opened. The words
  of those pages, the roots and the stacks are checked conservatively. Nothing found: the pages go to a pool (256 MB at
  most) that new pages of the same size and kind come from, and the arena's bytes leave the collection trigger. Something
  found, or writes not tracked for the arena's whole life: its pages join the collector's. Either way its owner class is
  free at once. `HL_GC_ARENA_TRACKING=0` turns tracking off (every release falls back).
- **Diagnostics**: `HL_GC_ARENA_CENSUS` prints each kept arena's references by holder (a block's type and offset, a root,
  a thread's stack); `HL_GC_ARENA_HOLDERS` the holder census of a collection-based release (`hl_gc_arena_release`).
- **Missing**: small-allocation packing (level 2). An arena takes a page per size class it uses, 0.3 to 0.8 MB for a
  small unit; recycled when it is released, but when one is kept those pages join the collector's part-full (an arena per
  lowered function, all kept: peak 3.5 GB). A path-to-root diagnostic (`HL_GC_ARENA_PATHS`) exists as a scratch patch.

Costs, on the self-compile with a 1.2 to 1.8 GB heap: a release takes 0.9 ms on average for a unit allocating 2 MB (max
9 ms), against 140 to 200 ms for a collection; finding written pages is most of it and grows with the heap's mapped size
(about 0.5 ms per 1.5 GB), not with the unit. Each 4 KB page first written after a scan takes a minor fault (about 1 us):
tracking added 0.4 to 0.9 s to a 14 s compile with an arena per class. So a unit should be several milliseconds of work:
a class, or a batch of functions, not one small function.

A measured experiment on the real compile: 539 units of 2 MB of temporaries each (maps, strings, arrays, objects, a number
returned), one per typed class. In arenas, 536 were released without a collection and the compile collected 3 times, as
without them; made without arenas, the same 1.1 GB of temporaries cost a 4th collection.

## Soundness

- A release reads every place a pointer into the arena can be: heap pages written since it opened (the kernel reports
  them, writes by native code and the kernel included), every root, and every thread's stack and registers with the world
  stopped. Pages created since are tracked from creation. If tracking fails, the arena falls back.
- The current thread's stack is read from the caller of `hl_gc_arena_free` up, with its callee-saved registers pushed by an
  entry stub (x86-64 Linux; elsewhere from the release's own frame, which can only keep more). Frames made after the
  unit's work returned reuse its stack, and slots they have not written still hold the unit's values; a release called
  from a frame that existed during the unit does not see them. That is why `within` releases from its own frame.
- The check is conservative: dead objects in written pages count. Copying outputs out with code that leaves dead outside
  copies pointing in (reflection's parameter arrays, an output enum whose arrays stay inside) keeps the arena. Outputs are
  built in their target, or are flat.
- Scratch tables reused across units must not hold a unit's values past its end: they are cleared at the end of the unit,
  not the start (`HlRegisterAllocation.slotsByType` did, and kept every lowering arena).
- Runtime caches written during a unit can keep it: 3 of the 539 synthetic arenas were kept by an array outside pointing to
  string bytes made inside.

## Order

0. **Prerequisites, no arena:** drop the canonical lists and the import cache with the syntax; in a one-shot compile drop
   the typed program after the IR tables and the incremental-only module records. Output identical, peak unchanged; the
   front-end arena needs them.
1. **Runtime:** done (above), except packing.
2. **First pilot: typing per class.** `Arena.within(unitArena, () -> typeClassMethods(...))`, with the typed bodies and
   `TypingOutput` built in the phase arena (homes for the typed-tree types, their arrays made in the target), the typer's
   names interned globally, and the typing session's tables extended outside. Measured today with outputs inside: every
   class unit is kept (25 to 50 references each: typed bodies, `TypingOutput`, session tables), at 1.3 ms a release.
   Expected effect once they release: what the front end allocates in the collector's view drops from 1.9 to 1.3 GB, so
   one collection fewer before the IR passes, and the IR passes start from a heap that never held those temporaries:
   roughly -0.2 to -0.3 GB of peak, to be measured.
3. **HL lowering per batch of functions:** instructions and debug locations flat or built in the build arena (an
   instruction's argument arrays too), HL types and strings interned there (the symbol table's methods run in its arena),
   `fieldSlots` filled outside. A sampled prototype with only the symbol table and finish moved out still kept every unit
   through those arrays and tables.
4. **The inliner stage per function**, on IR bodies once `IR_CORE_COLUMNS.md` step 2 runs the stage on them (`finish`
   copies flat columns into the stage's arena), and IR generation per function.
5. **The front end as a phase arena**, once its escapes are near zero, released after the IR tables.
6. **The compile server:** a build's temporaries in a build arena, what the session keeps in the session arena.

## How success is measured

On the frozen input, against the compiler before the change: peak resident memory (`/usr/bin/time -f "%e s %M kB"`), wall
time, and the number of collections (`compile-gcs` in the driver's allocation phases, `HL_GC_TIMELINE`) with the one-shot
trigger unchanged: a change that lowers the peak by collecting more often does not count. Output bytes identical. Each
arena's release reports zero references (`HL_GC_ARENA_CENSUS`); a fallback is a bug to fix, not a cost to accept.

Rejected: releasing without the check (ADR 0004 §6); a lower collection trigger (excluded by the goal); a release with a
full collection per unit; reflection-based copy-out (its temporaries keep the arena).

# Allocation regions

Status: proposed, design only (`COMPILER_DATA_LAYOUT.md` step 9, ADR 0004 §6). Measured on the frozen self-compile input at
`e91e0dc89`.

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

A **region** is a set of pages that a thread allocates into while the region is current. A unit of work runs with its own
region current; what it returns is placed outside on purpose; when it ends, the region is released: checked for pointers
into it and, if there are none, its pages are reused by the next unit at once. If something still points in, the release
falls back: the pages become ordinary collector pages and the escape is reported. Correctness never depends on a region,
only memory does.

Regions nest. Each unit names where its outputs go: the enclosing unit's region, a stage's output region, the session
region, or the global region (interned names). "Outside" is always an explicit target, never "the parent", because the
inliner's units are recursive (a callee's inlined form is computed inside its caller's unit but belongs to the stage).

## What goes where

| Region | Lives for | Holds |
|---|---|---|
| global | the process | interned names (`NameTable`, `IrSymbol` table), source files |
| session | the compile server's session | module states and their incremental records, the type registry, the inline memo |
| build | one build | the IR program, the HL code, tables built once per build |
| front end | parse to IR tables | tokens, syntax, canonical declarations, semantic models, typed program, typer scopes |
| unit | one function or class | everything the unit allocates except its outputs |

Units, with what each allocated and what it would free (per-unit groups, released once at the end of the stage; "kept" is
what was still reachable then):

| Unit | Units | Allocated | Kept | Would free | Kept as |
|---|---:|---:|---:|---:|---|
| type one class's method bodies (`ProgramTyper.typeClassMethods`) | 539 | 729 MB | 98 MB | 86% | typed bodies, `TypingOutput` records |
| generate one function's IR (`IrGenerator.generateFunction`) | 8,103 | 312 MB | 97 MB | 69% | the IR body; SSA scratch grown inside |
| inline one function (`IrInliner.run` loop body) | 8,628 | 411 MB | 63 MB | 85% | inlined bodies; memo and dependency tables filled inside |
| lower one function (`HlLower.lowerFunction`) | 8,237 | 344 MB | 50 MB | 85% | `HlFunction` (instructions, debug locations); interned HL types and strings; scratch grown inside |

These four units alone are 1.8 GB of the 3.1 GB the compile allocates, 1.5 GB of it temporaries. The largest single unit is
37 MB (an inliner unit, recursive); a function unit averages 40 to 50 KB, a class 1.4 MB.

A single unit released alone (sampled every 400th function, each released with a collection) kept all of its 0.5 to 3 MB
of pages: its outputs and the global tables it extended are spread over every size class it used. A unit frees only once
its outputs are placed outside; with page-granular release one escaped block keeps its page.

## The front end as one region

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

The **typed program** stays reachable through the backend although every field naming it is nulled: the HL register that
held `frontend.typedProgram` in `CompilationPipeline.compile` is a stack slot that keeps its value until the frame returns,
and the stack is scanned conservatively. This is general: a region released while a long-lived frame holds a dead slot
into it falls back. Units therefore run in a frame of their own that returns only the output.

What later phases keep from the front end, at the end of the build, before moving anything:

- **IR made during publication:** values, instructions, blocks, `SourceLocation` and `SourceProvenance` (49 MB). IR
  generation runs inside the front end today; it moves to the build region (or becomes per-unit with outputs there).
- **Names and text:** 46 MB of strings: field and method names in instructions, value names, debug-binding identities,
  string literals, type names in `IrType`, symbol names. Identifiers from the lexer are already interned (`NameTable`, per
  thread) but the table and its strings are made inside whatever region is current; names the typer builds are not interned.
- **Session records** a one-shot compile never reads: `semanticDependencies`, fingerprints, purity and no-return queries,
  typing warnings, default-argument sources, invalidations, `regenerated`; the module states themselves; `TypeMethod`,
  `TypeField` and `TypeDescriptor` of the type registry.
- **Not spans:** IR keeps its own locations; 15 `SourceSpan`s escaped. Source files are made before the front end.

To free fully: the canonical lists and the import cache dropped with the syntax; the typed program dropped after the IR
tables in a frame that returns; IR generation into the build region; names interned into the global region (`NameTable`,
`IrSymbol`, the typer's member and accessor names, `Names.of` of `INTERNED_NAMES.md`); literals into the IR body's pool;
session records into the session region (or not kept by a one-shot compile).

## Outputs placed outside

- **Copy at finish.** A unit builds into scratch and copies the result once into the target region. `IrBodyBuilder.finish`
  is that point for IR bodies (`IR_CORE_COLUMNS.md`): its columns are `Int` arrays, so the copy is the output. Its pools
  (string literals, provenance objects, floats) are copied or made in the target region too. `HlLower` already copies its
  instruction and location scratch at the end, but the instructions are enum values and the locations objects made during
  the unit; they become flat (encoded instructions, location ids) or are made in the target region.
- **Interning.** Names and symbols are made once, in the global region, by the table that interns them.
- **Tables a unit extends.** Symbol tables, memo tables and scratch arrays that grow inside a unit grow in their owner's
  region: the table enters its region around the growth, or is sized before the units run.

## Runtime

What the fork has (`gc.c`): allocation groups as a thread's current allocation owner (`hl_gc_group_enter`, `leave`,
`release`, std prims `gc_group_*`), pages per group (16 owner classes and a shared overflow class), the thread-local
allocation buffer per owner class, checked release (a full collection, then every page without a live block is freed;
the rest stays as collector pages), and diagnostics: `HL_GC_REGION_CENSUS` (what escaped, by type; pages before and kept)
and `HL_GC_REGION_HOLDERS` (pointers into the group, by holder and target type).

What is missing, in the order needed:

1. **Release without a collection** (ADR 0004 §6 level 3): look for pointers into the region only in non-region pages
   written while it was current (write tracking of the incremental collector, `gc_write_tracking.c`), the globals, and the
   stack frames older than the unit's. Cost in proportion to what the unit wrote outside. A full collection per function is
   not affordable: a level-1 release of the front end took 0.7 to 1 s with the census.
2. **Region pages recycled**, not returned: a released region's pages go to a pool the next unit takes them from. Owner
   classes are recycled with them; a class per function would exhaust the 16.
3. **Region allocation outside the collection trigger:** bytes allocated in a region that is released do not count
   toward the next collection. Without this, regions change nothing in the schedule.
4. **Bump allocation in region pages** (level 2): a small unit uses one page per size class today (0.3 to 0.8 MB at
   least); packed, a 40 KB unit uses one page. Needs an object-start bitmap for the fallback.
5. **A path diagnostic:** `HL_GC_REGION_PATHS=1|TYPE` walks from the roots and prints the field path to each block that
   keeps a region alive. Written for these measurements (scratch patch); the holders census alone could not find the
   canonical-AST holder because it names only the last hop.

## Both builds

The compiler reaches regions through a small `compiler.core.Region` (`run`, `outside(target, work)`, `release`) declared
with `@:hlNative` over the fork's std primitives, so the stock-Haxe-built compiler on the fork VM gets them as well. On
other targets each call is a no-op scope: `run` calls the work, `outside` calls it in place. Output placement (copy at
finish, interning) is plain Haxe and behaves the same in both builds, so the output bytes do not depend on regions.

## Order

0. **Prerequisites, no region:** drop the canonical lists and the import cache with the syntax; in a one-shot compile drop
   the typed program after the IR tables and the incremental-only module records. Measured: output identical, peak
   unchanged, live at the end lower. These are what the front-end region needs; alone they do not lower the peak.
1. **Runtime:** items 1 to 3 above, checked against a full collection in check mode across the test driver.
2. **First pilot: the inliner stage per function**, on IR bodies once `IR_CORE_COLUMNS.md` step 2 runs the stage on them:
   the unit is one function's inlining and cleanup chain, the output the body `finish` copies into the stage's region,
   the memo and dependency tables in the stage's region. 345 MB of temporaries, all allocated after collection 2.
3. **HL lowering per function:** instructions and debug locations made flat or in the build region at finish, HL types and
   strings interned into the build region. 290 MB of temporaries, also after collection 2.
4. **Typing per class and IR generation per function:** 630 MB and 210 MB of temporaries in the front end.
5. **The front end as a region**, once its escapes are near zero (they are 0.45 M blocks after the prerequisites and the
   moves above): released after the IR tables, its 0.85 GB of pages reused by the IR passes and backend.
6. **The compile server:** a build's temporaries in a build region, what the session keeps in the session region.

Expected effect, from the timeline: after collection 2 the compile allocates about 1 GB and the heap grows 0.34 GB to the
peak. Steps 2 and 3 take about 0.64 GB of that allocation out of the collector's view, so the heap should stay near its
size at collection 2 (about 1.45 GB) and collection 3 should not run: roughly -0.35 GB of peak. Steps 4 and 5 act on the
front end and on the base the IR passes start from; with all of them the estimate is about 1 GB. Stock Haxe's 531 MB also
needs the front end's own live set smaller (tokens as a table, step 8; interned names).

## How success is measured

On the frozen input, against the compiler before the change: peak resident memory (`/usr/bin/time -f "%e s %M kB"`), wall
time, and the number of collections (`compile-gcs` in the driver's allocation phases, `HL_GC_TIMELINE`) with the one-shot
trigger unchanged: a change that lowers the peak by collecting more often does not count. Output bytes identical. Each
region's release reports zero escapes in check mode (`HL_GC_REGION_CENSUS`); a fallback is a bug to fix, not a cost to
accept.

Rejected: releasing without the check (ADR 0004 §6); a lower collection trigger (excluded by the goal); level-1 releases
per function (a full collection each).

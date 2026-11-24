# Arenas

Status: the runtime is in the fork (below); the typing pilot, which typed each class in an arena of its own behind
`--typing-arenas`, stopped, and the option is gone. Measured on the frozen self-compile input.

This is region-based memory management with a checked release. We call a region an **arena** at every layer: the fork's
API (`hl_gc_arena_*`, std primitives `gc_arena_*`), its diagnostics (`HL_GC_ARENA_*`), and the compiler's `Arena`.

Two kinds of arena exist, on purpose with different names. `runtime.memory.NativeArena` (with `NativeSpan` and `RawPtr`,
the "Native" family) bump-allocates flat records in unmanaged memory; its `reset` and `dispose` are unchecked, and a
`RawPtr` kept past them dangles, which is the caller's bug. `compiler.core.Arena`, this note's subject, holds any object
the collector manages, and its release is checked: it never frees what is still referenced.

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

## Long-term goal: no collections in a one-shot compile

A one-shot compile should end without a collection: every piece of memory has a known release point (global and
session data at exit, build data at the end of the build, phase data at the end of its phase, unit data at the end of
its unit), and the collector is a safety net, not the mechanism. A collection in a normal one-shot compile then means
something escaped, and the diagnostics name it; the compile server and language service still collect, since their
session data changes over time.

Why not by allocating less alone: with a byte-count trigger the peak is the last collection's survivors plus up to a
trigger's worth of allocation, and where the trigger fires relative to the phases decides it. Crossing below a trigger
step removed a collection that ran mid-backend and raised the peak, because the later phases had been reusing what it
freed. Allocating less is always right; the schedule must be deliberate.

The path, each step useful alone:

1. **Collections at phase boundaries.** At the end of a phase its data is dead and the live set is smallest, so a
   collection there is cheapest and frees the most. A one-shot compile collects at a boundary when enough was allocated
   since the last collection (not more often than the trigger would), the byte trigger stays as a safety net for large
   inputs, and the peak becomes predictable: live data at a boundary plus the largest phase's allocation.
2. **Ownership by lifetime.** Each phase owns its data and drops it when it ends; the one-shot special cases fold into
   that (`TODO.md`).
3. **Flat structures in native arenas per phase** (the token table, IR columns, HL output): each replaces part of a
   boundary collection with a reset.
4. **Checked arenas for the object graphs left,** with the escape check in CI.
5. **Zero collections** in a one-shot compile, held by the performance guard.

Measured by deterministic numbers: allocation and live data at the phase boundaries gate; resident peak, an outcome of
the schedule, is reported and gated loosely.

## The design in layers

Arenas are the third of four layers, each taking what the one above leaves, in the order they pay:

1. **No garbage made.** Ids across lifetimes instead of spelled text (interned names, type and symbol ids); scratch
   reused by an owner of the right lifetime and cleared at the unit's end; keys and messages built only when used;
   results copied out at their exact size. This is the main lever: it lowers allocation, peak and time on every target,
   with no runtime support.
2. **Flat data in flat storage.** IR columns where passes read (`IR_CORE_COLUMNS.md`), the token table, HL output as a
   code stream with line columns, value arrays: one array in place of many small objects leaves less to collect and fewer
   pointers to escape. Ordinary arrays by default; a `NativeArena` only for flat data with an explicit end that no session
   cache keeps, since where flat data lives barely changes the peak and reuse gives the gain.
3. **Checked arenas for object graphs,** in coarse units (a class typed, a batch of functions lowered), with outputs
   placed outside by the data rules and the checked release as the safety net.
4. **The collector** for the rest, and the fallback of every release.

The compiler stays plain Haxe and builds with stock Haxe (`Arena.within` and type homes are no-ops there), and no layer's
correctness depends on the code placing data right: a mistake costs memory, reported by holder and site.

## Flat data and handles

Flat tables (layer 2) refer to each other by handle, not pointer, so a record that names another stays flat. Kept to
what the compiler needs:

- **Typed ids.** Each table has its id type, an abstract over `Int` (`TokenId`, `IrValueId`, `HlRegId`); a table is
  indexed only by its own. Ids are dense and slots are never reused within the table's lifetime, so an id cannot come to
  name something else. This is the data rule "ids across lifetimes" made a type.
- **Flat allocation is typed.** `NativeArena.alloc<T:Flat>` rejects a type with managed references at compile time
  (today it throws at run time).
- **One column type.** `NativeColumn<T:Flat>`: growable, zero-filled, indexed by its id type, copied out at its exact
  size; callers index it and never hold a `RawPtr`. Its storage is the one place with a dual declaration (`RawPtr` on
  Haxeon, `hl.Bytes` under stock Haxe).
- **Reset is checked in debug builds.** A `NativeArena` counts its resets; a column remembers the count it was made
  under and a debug build checks it on access, so use after `reset()` fails instead of reading another unit's data.
  Release builds do not check.

Not now: per-slot generational handles. They serve tables whose slots are freed one by one and reused while others
still refer to them (the compile server's module records, users' entity worlds); a one-shot compile frees whole tables.
They are added when such a table moves to flat storage.

The first user is the first native-arena pilot (the token table is the likely one); the pieces are built as it needs
them, not ahead of it.

## Arenas by lifetime

| Arena | Lives for | Holds |
|---|---|---|
| global | the process | interned names (`NameTable`, `IrSymbol` table), type ids, source files |
| session | the compile server's session | module states and their incremental records, the type registry, the inline memo |
| build | one compile | the program IR, its tables, the output |
| phase | the front end, until IR generation | tokens, syntax, canonical declarations, semantic models, typed program, typer scopes |
| unit | one class typed, one function lowered | everything the unit allocates except its outputs |

## Data rules for arenas

1. **Ids across lifetimes, pointers within one.** A structure refers to data of a shorter life by id or name, never by
   pointer.
2. **Build, then finish.** A unit's outputs are constructed in the arena they belong to (the phase's, the build's), or
   copied out once at the unit's finish; nothing the unit leaves outside points into it.
3. **Every long-lived structure has a home arena** and stores only data of its lifetime or longer.
4. **Caches live in the arena of what they hold**: a cache keyed by syntax computes its entries outside the arena of the
   work asking.
5. **Scratch storage grows in its owner's arena** and is cleared at the end of the unit, not the start: a table kept for
   reuse must not hold the last unit's values past it.
6. **Long-lived kinds have type homes in the global arena**: names, `IrSymbol`, type ids, source files. A name made inside
   a unit is interned (`GlobalNames.of`) before a session table keeps it.

## How placement is expressed

No new expression syntax: it would need `#if haxeon` at every allocation site and break the stock-Haxe build. Two ways
instead, both plain Haxe:

1. **The current arena, scoped by a call.** `Arena.within(arena, () -> work())` makes `arena` current on the thread while
   `work` runs, so everything its callees allocate follows; the previous arena is current again afterwards. Outputs go
   elsewhere explicitly: their construction is scoped in the target (`Arena.within(target, () -> finish())`), or they are
   copied out at the unit's finish. `within` releases a unit arena from its own frame, which existed while `work` ran
   (below, "Soundness").
2. **A home on long-lived types.** `@:arena(global) class IrSymbol` makes instances go to that arena wherever they are
   created. The HL lowering is to honour it by setting the type's home when the module loads (`hl_gc_arena_set_home`, in
   the fork); stock Haxe ignores the metadata. Not done yet: the typing pilot needs no home, as its long-lived values are
   names (interned) and outputs (copied out).

`Arena.unit(work, ?publish, ?onKept)` runs `work` in a fresh arena, copies its result out into the arena current before
(`hl_gc_arena_copy`), lets `publish` put what else it handed out where it belongs, and releases the arena from its own
frame. `Arena.toGlobal(value)` copies a value out of the current arena into the collector's pages.

Under stock Haxe, or off HashLink, `Arena.within` just calls the function. Safety stays in the runtime: the checked
release, the fallback, and diagnostics naming each escape by holder.

## The typing pilot

`ProgramTyper.typeClassMethods` per class ran in `Arena.unit` with `--typing-arenas`: the typed methods, the units'
`TypingOutput`s and the shared units typed with them were copied out at the finish; function, specialization, anonymous
type, dynamic-structure and generic-enum-use names are interned; the default-argument resolution cache is made outside.
The session's tables hold typed values made outside the arena: a unit's records are classes (`UnitAnswers`,
`UnitAnonymousUses`, `UnitSources`) instead of maps stored in maps, as are the runtime dependency targets
(`RuntimeTargets`) and a specialization's key-path constants (`KeyPathConstants`, kept through `KeyPathState`); the
program's anonymous type registry keeps a copy of each type it registers; a literal structure, once closed, leaves the
table of open ones for a table of closed types by provisional name, its closed type made outside (`MonomorphFrames`).

Measured on main at 5b198e899 (allocation 2.58 GB):

| Mode | Released | Kept | Evacuated | Release time | Peak | Wall | Collections |
|---|---:|---:|---:|---:|---:|---:|---:|
| off | | | | | 1.586 GB | 13.3 to 13.5 s | 2 |
| `--typing-arenas` | 477 to 479 of 539 | 60 to 62 | 16 to 17 (50 KB) | 0.29 s | 1.592 GB | 14.5 to 14.7 s | 2 |
| `--typing-arenas=strict` | 468 to 472 | 67 to 71 | none | | | | |

Output identical in every mode. The counts move by a few between runs: a stale word of an older frame can point into
an arena's recycled pages and keep it. Releasing the typing temporaries does not pay today: the peak is set later, by
the IR passes and the backend, and the collections fall where they did, so the option stays off. (Before the copy and
evacuation kept to known layouts, 539 arenas released, but by rewriting words of untyped blocks that only their use made
pointers, which a release must never do.) The escape check is to build the compiler with Haxeon, compile it again plainly
and with `--typing-arenas=check` and `HL_GC_ARENA_SITES=1`, and require that no arena is kept (`HL arena reference` lines
name each reference by holder field and allocation site) and that the two outputs are identical. The script that did it,
`scripts/check-typing-arenas.sh`, was removed when the pilot stopped, and the option with it; take both from git history
to revive the pilot. The data rules above stay in the typer.

What `strict` still names, largest first: normalized abstract constructors aliased in the declaration type table (a
fresh normalized copy per call, `CallResolver.typeAbstractConstruction`, which another track is changing); typed
expressions and their kinds held by tables of inline constant values; the anonymous types that `DeclarationIndex`
resolves for the session's declaration types; typing contexts left in a context stack; flow-fact tables. Each is a
table of the session holding values made inside a unit, for the same kind of change as above.

A class unit's allocation by kind (539 units, 554 MB of arena blocks at their release): compiler classes 12%, anonymous
records 6%, enums 5%, `String` objects 9% and their bytes 13%, containers held by compiler objects 21%, loose containers
(locals, temporaries) 29%, other untyped blocks 6%.

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
  free at once. Tracking exists on 64-bit Linux only; `HL_GC_ARENA_TRACKING=0` turns it off (every release falls back),
  and `hl_gc_arena_tracking_available()` says whether releases are checked.
- **Diagnostics**: `HL_GC_ARENA_CENSUS` prints each kept arena's references by holder (a block's type and offset, a root,
  a thread's stack); `HL_GC_ARENA_HOLDERS` the holder census of a collection-based release (`hl_gc_arena_release`).
- **Copy and evacuation**: `hl_gc_arena_copy(value, arena, target)` copies what a value reaches inside an arena to a
  target, sharing and cycles kept, no collection while it runs. `hl_gc_arena_set_evacuation(true)` makes a release copy
  out what typed fields outside the arena reach in it, each to the field's arena, rewrite the fields, and release.
  Neither ever rewrites a word that is not known to be a pointer: only an object's pointer fields (by its type), an enum
  constructor's pointer parameters, a closure's bound value, an array's storage and, when the element type is a
  pointer, its elements, and the words a registered layout names for an untyped block reached through a field of a
  registered abstract type (`hl_gc_arena_register_layout`; `hl_gc_arena_map_layout` for the std maps, which the
  runtime library registers for its `map_*` types). A block of no known layout is not copied and keeps the arena; a word
  of an untyped block, a root, a pinned value, a stack or register word keeps it too, never being rewritten. A typed
  block's words count as references only where its layout has a pointer, as the collector reads them.
- **Allocation sites**: `HL_GC_ARENA_SITES` records the call stack of every block allocated in an arena (through the
  locked path), so a kept arena's report names where each referenced block was made, and holders by field.
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
2. **Typing per class:** tried behind `--typing-arenas` (above): 477 of 539 classes released, 470 without evacuation;
   peak unchanged, wall +1.1 s. Removed: the typing temporaries are not what sets the peak.
3. **HL lowering per batch of functions:** instructions and debug locations flat or built in the build arena (an
   instruction's argument arrays too), HL types and strings interned there (the symbol table's methods run in its arena),
   `fieldSlots` filled outside. A sampled prototype with only the symbol table and finish moved out still kept every unit
   through those arrays and tables.
4. **The inliner stage per function**, on IR bodies once `IR_CORE_COLUMNS.md` step 2 runs the stage on them (`finish`
   copies flat columns into the stage's arena), and IR generation per function.
5. **The front end as a phase arena**, once its escapes are near zero, released after the IR tables.
6. **The compile server:** a build's temporaries in a build arena, what the session keeps in the session arena.

## How the design got here

Each change followed a measurement that contradicted an assumption; the goal (bulk freeing without more collections, a
lower peak) stayed:

| Assumed | Measured | Became |
|---|---|---|
| releasing dead data lowers the peak | peak unchanged: it follows garbage between collections, not the live set | stop making garbage; return short-lived pages at once |
| one region for the front end | released nothing: escapes on every page | smaller units, outputs placed outside |
| release as a plain reset | Haxe has no lifetimes; any store can point in, and an unchecked reset corrupts the heap | a checked release over written pages, about 1 ms against 140 to 200 ms for a collection |
| an arena per function | too small: releases outweighed the work | classes or batches of functions |
| outputs placed outside suffice | shared tables kept most classes; evacuating them released all, but rewrote words of blocks without a layout, which is unsound | evacuation only along known layouts; maps of maps as records, whose layout is known; shared tables in the session arena |
| typer-checked scoped types for a plain reset | 72% of a class unit's temporaries are strings and containers | dropped; inferred escape analysis kept as a later option |
| a `NativeArena` for the compiler's flat data | reuse gave the gain, native storage about 0.1% more | reuse with ordinary arrays |
| IR columns for every pass | reads twice as fast, rewrites slower | columns where passes read; rewriting passes wait |
| "region", "group" | ambiguous with collector terms; an `Arena` already existed for flat records | `Arena` (managed, checked) and `NativeArena` (flat, unchecked) |

Considered and not planned: explicit ownership of containers (it needs non-escape annotations across the compiler and the
standard library), a precise stack (the units met no stack references once `within` releases from its own frame), a
moving generational collector (a large VM project that collects more often by design).

## Open decisions

1. **The cost of the check.** Write tracking and releases add time to typing. Once layers 1 and 2 have shrunk what the
   units allocate, measure again and choose: checked releases as they are; checked in CI and debug builds and unchecked in
   release builds of the compiler; or an inferred escape analysis (per-function summaries of escaping parameters, beside
   the purity and receiver-effect inference) that places proven-local allocations in arenas released without a check.
2. **Portability.** Page tracking needs Linux (`userfaultfd`, `PAGEMAP_SCAN`), and the exact stack read x86-64 Linux;
   elsewhere every release falls back. Checked arenas on every target need a software write barrier (card marking on
   pointer stores), with page tracking kept as Linux's faster path.
3. **Evacuation** rewrites only words a block's layout names as pointers; any other word that looks like an address keeps
   the arena. Whether it stays once the code places everything right is decided by what `strict` still keeps.

## How success is measured

On the frozen input, against the compiler before the change: peak resident memory (`/usr/bin/time -f "%e s %M kB"`), wall
time, and the number of collections (`compile-gcs` in the driver's allocation phases, `HL_GC_TIMELINE`) with the one-shot
trigger unchanged: a change that lowers the peak by collecting more often does not count. Output bytes identical. Each
arena's release reports zero references (`HL_GC_ARENA_CENSUS`); a fallback is a bug to fix, not a cost to accept.

Rejected: releasing without the check (ADR 0004 §6); a lower collection trigger (excluded by the goal); a release with a
full collection per unit; reflection-based copy-out (its temporaries keep the arena).

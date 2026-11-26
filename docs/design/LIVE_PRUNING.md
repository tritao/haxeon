# Live builds prune like one-shot builds (design note)

Status: designed 2026-11-26, not started; the open questions are decided (end of the note). Decided by the user: a live
HashLink build keeps what a one-shot build keeps, by the same roots and the same walk (reflection, `@:keep`, the reflectable
set), so a live session is no more forgiving than a normal build. It lands with module sections slice 4
([MODULE_SECTIONS.md](MODULE_SECTIONS.md), section 4), with the reach set as an engine summary
([QUERY_ENGINE.md](QUERY_ENGINE.md), "Whole-program steps") and a live counterpart of `--check-reuse`.

**Today.** A live build skips the early prune (`FrontendCompilation.runIrPipeline` passes `pruneFromEntry` and
`walkFromEntry` false when `livePatching`) and the plain backend's prune (`HashLinkBackendSession`, `HlPlainBuild.reachable`).
The server runs every pass on, lowers, encodes and keeps every function of every loaded module, because the host may call
any function by id and a reachability change must not move the dense layout ([REACHABILITY_WALK.md](REACHABILITY_WALK.md),
"Live and hot-reload builds").

## Measured

The first live build of `haxeon run --watch` on perf-guard's two live apps (`scripts/perf-guard.py`, live part), the server
built ahead of time, with a local switch (not committed) that turned the early prune on for live builds and rooted the
host's entry points. Live data from `HAXEON_PEAK_CENSUS=write-done`; main-thread instructions with perf attached to the
worker (perf-guard's `ThreadCounter`), two runs each, without the census.

| UI template app (305 sources, 6,090 typed functions) | Unpruned (today) | Pruned | Change |
|---|---|---|---|
| Functions after the prune (`runtime-surface`) / into the inliner | 7,290 / 8,152 | 4,031 / 4,694 | −45% / −42% |
| Server live data after the build | 364.0 MB | 301.9 MB | −62 MB (−17%) |
| of which per-function IR and backend state (below) | 197 MB | 135 MB | −31% |
| First build, main thread | 20.97G instructions, 5.9–6.0 s | 17.87G, 4.8–4.9 s | −15%, −18% |
| Recording `<output>.live.state` (idle, off the edit's path) | 1.10 s | 0.71 s | −35% |

| Small project (`tests/perf/live-project`) | Unpruned | Pruned |
|---|---|---|
| Functions | about 258 | about 20 (238 pruned) |
| Live data / first build | 8.9 MB / 0.71G, 0.19–0.20 s | 6.3 MB / 0.52–0.61G, 0.17 s |

The pruned live program is the one-shot program: a one-shot build of the template app keeps 4,698 functions at
`backend-start` (`--no-early-prune`: 7,984).

Where the UI app's 364 MB are (census root paths, unpruned → pruned): the stage memos (`IrStageMemos`) 66 → 43, the final IR
kept as the build's result 50 → 31, `HlWriterCache` 31 → 19, `IrInlineCache` 24 → 14, the backend session's assembler and
published functions 10 → 6, the published ABI and encoded module 4 → 3, IR generation 12 → 19 (it now holds the unreached
functions' IR alone instead of sharing it with the final program). That is the **per-function share: 197 MB, 54%**. The
frontend's state does not change with the prune: the semantic program 54, modules 43 (tokens 18, ASTs 12), the last typed
program 27, declaration facts 9, FFI 5. `IrBody` blocks fall from 960 k (86 MB) to 547 k (49 MB). What the prune does not
save is what unreached functions still cost before it: typing, IR generation and the six assembly stages ahead of the prune
point (the walk itself is cheap: 29 ms for the dispatch walk and 16 ms for the prune on the cold UI build).

Edits with the prune forced on: perf-guard's body and signature edits patch on both apps; a body edit that makes a pruned
function of its own file reached patches (the assembler adds a function the module has no slot for); a body edit that
reaches `StringTools.hex`, pruned and from a file no function of the module came from, is refused by the runtime ("Patch
debug file is not present in module", `hlpatch.c`) and reloads. Without the entry points in the roots the host fails at
start ("Missing live entry point `Main.start`"). These two are the gaps the design closes; the others below are found by
reading `PatchPlanner` and the assembler.

## Roots, and how they change across edits

The roots are the plain build's (`IrProgramAssembler.assemble`, `IrEntryPrune.walk`), plus the host's:

- **Entry** (`main` or the build's entry) and **static initializers**: `__init` and every class's initializer parts, so the
  init order is `StaticInitializationOrder` over every class, as in a one-shot build; an edit changes it only by changing
  the classes or their initializers.
- **Exports** (`CompilerRequest.exports`, `Expose` retention) and **`@:keep` / `@:expose`** (`IrFunction.retention`).
- **Live host entry points.** `start`, `tick`, `saveState`, `restoreState`, `close` and, when declared, `liveRelease` and
  `liveRebuild` of the entry class (`tools.LiveEntryPoints`). The CLI puts them in the live request's `exports`; the
  compiler learns no host names.
- **Native callbacks and `toString`** for dynamic stringification, as the walk adds them now.

Edges are the type-aware walk's ([REACHABILITY_WALK.md](REACHABILITY_WALK.md)): direct calls and closures; method calls
over created classes and their created subclasses; **interface dispatch** to created implementors only; typed operations to
their provider rows; dynamic sites (equality, compare, hash, `Std.string`, reflective field access) over every created type.
Reflective field access keeps every method of a created class (`keepCreatedClassMethods`). A method named by a reached call
on a class nothing creates keeps a declaration stub (`declarationOnly`, an `Unreachable` body). **The reflectable set** is
every typed class and anonymous type (`reflectableObjectsFrom`): their layouts and class values stay, their methods only by
the walk. Haxeon has no name-based class lookup yet (`Type.resolveClass` and `createInstance` on a class value are E1009),
so no root comes from names; when class values land ([TYPE_VALUES.md](TYPE_VALUES.md)), a lookup by name is a dynamic site over the reflectable set, the same
for plain and live builds. `noteMethodLookup` stays a check: a pass that reads a method table reads the reach summary's
key for the entry, so its dependency is recorded instead of watched.

An edit changes the reach set only through contributions: a function's new body (a new call, a new creation site, a new
dynamic site), a declaration's `@:keep`, the request's exports, a class added or removed. A new creation site is the edit
with the widest effect: it reaches that class's methods at every reached method, interface and dynamic site.

## Incremental reachability on the engine

The walk is a summary over per-function contributions, the shape QUERY_ENGINE.md gives whole-program steps:

- **Contribution** of a function: what the walk reads of it now (`IrWalkSummary`: callees, method selectors, interface
  calls, created types, typed operations, dynamic sites), a computed kind keyed by function symbol over the prune-point
  stage's output. It is made of the function alone, so `QuerySummary.holds` keeps it while that input is unchanged. The
  roots are one more contributor.
- **The walk** is a computed memo whose reads are the contributions of the functions it reached and the tables it read
  (objects, hierarchy, implementors). Any changed read reruns it whole over held contributions, which is linear in edges and
  cheap; a worklist delta is not worth its removal case. Its value is the reached set, published as a `QuerySummary`
  keyed by function symbol, so a later stage reads `has(fn)` and only functions whose membership flips run again.
- **On the stage driver** (QUERY_ENGINE.md, "Per-access costs and the stage driver"): the prune is the driver's input filter
  for the stages after it. It replaces the prune walk's `IrWalkRecord` (engine slice 3) and serves plain and live builds
  alike; the plain backend's second prune (`HlPlainBuild.reachable`) goes when it removes nothing under check mode.
- **Live delta.** The build also gives `firstReached = reached − published`: functions the running module has no code for.
  They are lowered and carried whatever their regeneration says.

## What a patch must add, and where

| Added by an edit | Today (dense, append-only) | On sections (slice 4) |
|---|---|---|
| A function first reached | appended into `HL_PATCH_FUNCTION_RESERVE`; works when its file is in the module | in its module's section; the patch linker appends a new key |
| A function of a file the module never had | refused: the debug-file table is fixed | the section carries its own debug files |
| A class first created, a closure environment | appended type (`ObjectAdded`) | owned type in its section |
| A method first reached on a class the module has | added method if it overrides nothing, else `ObjectMethodDispatchChanged`: reload | none: the layout keeps every declared method (below) |
| A constructor leaving the reach set | `FunctionRemoved(X.new)`: reload | none: the key keeps its slot (below) |
| A native first called | reload (natives sit before every slot) | appended by `(lib, name)` |
| A global or a class first used | live modules lay out every global and class (a plain build trims them, `IrReachability.trimTables`) | same: the layout rule |
| An interface or enum first reached | laid out from the whole program in both builds | same |

Two rules make the layout independent of the reach set, so a reach change never needs a reload:

- **Layouts from declarations.** A live module keeps every class, global and enum of the typed program, as it does now, and
  a prototype slot for every declared method; an unreached method's slot holds a declaration stub, as `declarationOnly`
  does now, so reaching it later replaces a body and moves no slot. Plain builds keep trimming them (see open questions).
- **The published set only grows within a module identity.** A function leaving the reach set is not lowered or carried
  again; its key keeps its slot and last code, as a removed function does today and as slice 4's "a key a replaced section
  no longer defines" does. The planner's `FunctionRemoved` then means a removed declaration, never a pruned one.

On sections a module's section holds its reached functions, its owned types and globals; a module with no reached function
and nothing owned in the layout writes no section. A reach change re-encodes only the sections whose reached functions
changed.

## Unreached modules

They are parsed, typed and IR-generated as now (the typer has no demand side), and their functions run through the stages
before the prune point. The server keeps their tokens, ASTs, typed bodies, semantic declarations, the IR generation memo and
those stages' memos and contributions, so an edit that reaches them costs no retyping. It keeps nothing after the prune
point: no final IR, inline cache, lowering, `HlFunction` or writer cache. Generating IR on demand from the walk
(REACHABILITY_WALK.md 3b) would drop the IR generation and early-stage share too; that is a later slice.

## Live `--check-reuse`

Today `--check-reuse` skips live builds. With the prune, a live build in check mode also builds the same tree from a fresh
state with the same options and roots (pruned, not live), and checks:

1. **Program equality.** The reached set and every reached function's final IR equal the fresh build's; on sections, every
   section's digest equals the fresh build's (the running module's retained keys are runtime state, not program).
2. **First reach is carried.** Every function in `reached − published` is in the patch, lowered; every import of the patch
   resolves to a key the patch or the published module defines (the patch linker's missing-import error, run on the
   compiler side).
3. **No pruned reach.** No reached function calls a key that is neither reached nor published (`IrEntryPrune.checkRemoved`
   over the live program).

The driver's live program runs and perf-guard's live part gain edits that reach a pruned standard-library function, create
a class with an override, and call a new native.

## Failure modes

- **Reflection reaching an unlowered function at run time** gives the one-shot build's behavior: a field not in the
  program is absent (`Reflect.field` is null) and a stub aborts (`__unreachable`). A retained published function is still
  callable by a closure the app holds from before, as a removed function is today.
- **A host entry point missing from the roots** fails at start; rooting them in the request is part of slice 1.
- **A patch without a first-reached function** cannot link (sections) or calls an empty slot (dense); check 2 catches it.
- **A reload cause from the reach set alone** (dispatch, removed constructor, new native, new debug file) is a bug under
  the two layout rules; the planner reports the cause, and the edits above cover each.

## Live state persistence and rehydration

`CompilerSession.recordLiveState` writes the assembler's published functions, slots, stable ids and ABI
(`HlAssemblerStateCodec`); pruned, that is the reached-ever set, smaller and faster to write (measured above). The reach set
itself is not persisted: a resumed session's first build walks again from the sources, and its `firstReached` is against the
resumed published set (`SessionState.rehydrationBaseline` holds those functions), so a function first reached while the
server was down is carried by the first patch. On sections the state shrinks to the semantic baseline and section digests
(MODULE_SECTIONS.md, section 4); `firstReached` is then against the keys of the acknowledged sections.

## Slices

Each is checked by the byte-identical self-compile, `--check-reuse`, the edit replay, the warm-equals-fresh mains, the
ci-tier hot-reload suite and perf-guard's live part (first build, edits and server live data).

| # | Slice | Size (est.) | Extra checks | Depends on |
|---|---|---|---|---|
| 1 | Host entry points in the live request's `exports`; live builds run the prune walk without pruning and report its counts | +80 | the driver's live runs report the reach; a host started with a pruned module starts | — |
| 2 | The reach set as an engine summary over per-function contributions, for plain builds; `IrWalkRecord` of the prune walk goes | −200 / +300 | `--check-reuse` recomputes contributions and the walk | engine slice 3 (or beside it) |
| 3 | Live prune on sections: layouts from declarations, the growing published set, `firstReached` carried, planner causes narrowed, live `--check-reuse` | −150 / +450 compiler, +60 fork | the new live edits; the patch mains; an Android watch run | 1, 2, MODULE_SECTIONS slice 4 |
| 4 | Remove the unpruned live path: the live builds' skip of the prune, the driver's unpruned live run, `--no-early-prune` | −150 | — | 3, two pushes |
| 5 | IR generation on demand from the walk (REACHABILITY_WALK.md 3b) | not estimated | live data of unreached modules | 3 |

Slice 3 is one change with slice 4 of module sections, as decided: a dense interim would need the debug-file, native and
dispatch fixes that sections remove.

## Decided

Decided by the user on 2026-11-26:

- **Plain layouts.** Plain builds keep trimming unreached methods; only live layouts keep declared-method stubs. A plain
  module pays no size or startup for the live rule, and the live check compares programs and sections, not layouts.
- **Retained functions.** No extra bound: a reload (a new module identity) resets the published set and is the bound.
- **Where `firstReached` is lowered.** A function first reached many edits after it was generated is lowered from its held
  stage memos. The live `--check-reuse` verifies that its lowering equals a fresh build's: check 1 compares the reached
  functions' lowering, not only their final IR.

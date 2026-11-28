# Warm rebuild reuse

Status: in use. A warm build reuses the lowering, the verification and the IR stages already moved onto bodies; moving the
rest of the passes is the query engine's work ([QUERY_ENGINE.md](QUERY_ENGINE.md), [IR_PASS_INVENTORY.md](IR_PASS_INVENTORY.md)).
The open items are at the end.

A warm build is a build in a compiler session that has built before: the compile server, the language server, or a
`haxeon build` that reuses its worker. The rule is ADR 0003 decision 10: a warm build's output is the bytes a fresh compiler
makes from the same sources, and its work is proportional to the edit.

## What a warm build reuses

- **Typing:** only what changed is typed again (`LAZY_DECLARATION_TYPING.md`); a unit not typed again keeps its records,
  anonymous types included.
- **The whole pipeline, when nothing it reads changed:** `PipelineSnapshot` holds everything the IR pipeline read (the typed
  functions' IR, the program tables, the environment). When the snapshot and the lowering environment both equal the last
  build's, the build keeps the last final IR and the last module bytes, and only writes them (`reused: ir+module`).
- **IR stages on bodies:** each per-function stage keeps what it made of each function in the session's query database, with
  the facts it read (`IrStageQueries`, `IrStageFacts`), and reuses it while the function and the facts are unchanged. The session caching model is in
  [IR_CORE_COLUMNS.md](IR_CORE_COLUMNS.md#session-caching-model).
- **Whole-program walks:** every kept walk is a kind of the session's database (`IrWalkMemo`), whose memo of its result
  reads keys of the kind: the program's tables, what its caller gave it (roots, settings, root types) and the role of each
  function as one key, and per function its signature and its summary. A build reuses the result while none of the keys the
  walk read changed: a function it did not reach adds nothing through its body. The type-aware walks summarize a function as
  `IrWalkSummary`, the HashLink plain build's walk and table trim as `IrBodyEdges` (`HlFunctionQueries.plainReach`); the enum
  escape reaches follow no function's edges and give the closures and map stores they read as inputs.
- **Steps over the final IR:** what the HashLink backend's whole-program steps read of each function alone (its ABI signature,
  the natives its rows call, its field stores, its form with shared runtime calls, the enums it may box) is a kind of the
  database kept while the function is the same object (`HlFunctionQueries`).
- **Inlining:** `IrInlineCache` keeps each inlined function with everything its result depended on.
- **Lowering (HashLink):** a function is lowered with its requests to the symbol tables recorded (`HlLoweredFunction`).
  What lowering made of each function is a kind of the session's database (`HlFunctionQueries.lowered`), whose reads are the
  facts lowering read. A function whose IR is the same and whose facts hold is kept as the build that lowered it made it (`HlLink.relocate`, `HlCode.relocations`), and a build whose metadata
  tables and function layout are the last build's extends the last build's tables (`HlLoweredTables`), so a kept function
  asks nothing. The module is written as sections that name entries by key, so cold and warm output are equal without
  making the tables what a cold build's order would ([MODULE_SECTIONS.md](MODULE_SECTIONS.md), section 3). What lowering
  reads about other entities goes through `HlLoweringView`, which reads each as a fact of the database, and a changed answer
  lowers the function again. A live build keeps its append-only tables and trusts every lowered function it is not told to regenerate.
- **Verification:** a function stays verified while it and what the verifier read about the rest of the program
  (`IrVerifyStage`, facts of the session's database) are unchanged.
- **Positions:** an IR location counts from its anchor (`SourceAnchor`, `SourceLocation`), the member declaration it lies in
  (a method, a field, an enum constructor) or else the whole file: its offsets and lines are distances from the anchor's start,
  its columns the file's, and it names no file hash. So lines moved above a declaration change no function, and code the
  inliner copied keeps its callee's anchor, so moving the callee changes none of its callers. Lowered code keeps its
  locations so (`HlDebugLocation`); writing the module places each anchor in the build's sources (`SourceAnchors`, from the
  parse of each file, `SourceFile.declareAnchors`): the line tables, the opcode spans and the snapshots they name. A section
  is kept while what it reads, its functions' anchors among them, reads the same (`HlSectionCache`), and a build reuses the last module only while its sources are the same (`CompilationContext.sourcesKey`). A function whose code
  holds a line as a value, the `haxe.PosInfos` a call passes, does change. Names the generator gives its own locals are
  numbered within the function (`IrLocalsBuilder.internalName`), not taken from offsets. A live module keeps the code of
  functions an edit removed; their anchors are placed where the session last placed them (`SourceAnchorHistory`). A live
  build that renames lambdas to follow an edit (`LambdaAlignment`) lowers the renamed functions and the code reaching their
  slots again, without patching them (`HlModuleAssembler.renamed`).

A failed or rejected build leaves every cache as the last successful build left it: a build works on a copy of the
`SessionState` it started from, and what its units read is written in a transaction of the session's query database that only
the build taken commits ([QUERY_ENGINE.md](QUERY_ENGINE.md), "Results computed outside the engine").

## Typing: recorded reads

A typed unit (a function body, a field initializer `Class.__init.x`, a shared unit: a specialization or an inline constant) is
typed again exactly when something it read changed. The typer records what each unit reads; nothing is inferred from syntax,
and no edge between declarations is kept by hand.

- **Facts.** What a unit can read is a fact: an aspect of a declaration or of the program, by name
  (`DeclarationFacts`). The aspects are a function's signature and its body, a type's shape (what a reference to it means:
  kind, type parameters and constraints, base and interfaces, metadata, and for a value type its fields), a class's members
  (its fields, and its methods by name and kind; an enum's constructors), one enum constructor (its index and parameters), a field's initializer, a callee's purity and
  never-returns answers, a source file's snapshot (a default argument copied from it), every declaration of a kind (for code
  that searches them all), and a unit (what a unit read, for the units whose result others take: an inferred declaration, a
  specialization, an inline constant).
- **Prints.** When a module's canonical declarations are made again, each part is compared with the one it replaces
  (`DeclarationPrints`, `CanonicalComparison`): the canonical forms, where names are resolved, with positions as lines
  where code copied into a reader carries them. A body whose text, line and scope (the names every module sees, the
  module's imports and declarations) are unchanged is the same without being walked. A fact also names the facts its
  meaning goes through: the shapes of the typedefs and abstracts its declaration names, which a type naming them expands. A
  class, interface or enum is named, not expanded: its readers read what they use of it themselves. So a typedef edit reaches
  the readers of every signature naming it, and an enum constructor added does not reach the callers of a function whose
  signature names the enum. A function reads the members of every type its own signature names.
- **Revisions.** Every build has a revision. A fact keeps the revision its print last changed at; a unit keeps the
  revision it was typed at and the facts it read. A unit is current while no fact it read, or that one of those goes
  through, changed after it was typed, with the latest change of each fact found once per build (facts that go through each
  other are one component). Invalidation checks only the units that may have read a fact changed since the last check
  (`DeclarationFacts.unitsReading`): the facts log their changes, and each module has a Bloom filter of what its units read
  (`ReadFilter`), so the units of the modules whose filter may hold a change are checked, and a unit that read one leads to
  the units reading it; so are the units the last check found changed, of which one no build types again (an initializer
  whose field is gone) stays changed. A filter only grows, so it holds every record a rollback can restore; the filters are built again once
  they took twice the reads they were built with. A build whose modules were not all in the last check, or whose changes the
  log no longer reaches, checks every unit. A build in which no fact changed checks nothing.
- **Purity and never-returns answers** are kept with the session (`ProgramPurity`), as the greatest fixpoint over each
  walked function's dependencies, and brought up to date in proportion to the edit: the functions of the modules made again
  and those that read a changed fact are walked again, and when what one depends on comes out otherwise the fixpoint is
  settled again over the functions that can reach it. Only the answers that moved move their facts (`FactAspect.Purity`,
  `FactAspect.NoReturn`). `--check-reuse` compares them, and what each function was found to depend on, with
  `PurityInference.infer` run anew.
- **Where reads are recorded.** At the typer's lookups: the declaration tables (`DeclarationIndex`, the signature tables),
  name resolution, the declaration types (`DeclarationTypes`), purity and never-returns answers, inline constants and
  default arguments. A cached answer is recorded on every use, not only when it is computed. A read outside a unit (program
  set-up) records nothing.
- **Coarse rule, as reads.** An inferred declaration's signature names its own unit, so a reader is typed again when
  anything the declaration read changed (`LAZY_DECLARATION_TYPING.md`, "Coarse rule first"). A caller of a generic
  function reads the specialization's unit, so it is typed again, and requests the specialization again, when the generic
  body or anything the specialization read changed. A generated helper (an equality, hash, enum method or interface
  adapter, a `Flags` or raw-value enum member, a copy from `Dynamic` to a structure) is a unit as well, recording what
  making it read, and the code asking for it reads its unit (`TypingSession.requestHelper`): a helper is made only from
  requests, so an edit to a declaration it is made from (an enum constructor added under a `Type.enumEq`) types its requesters
  again, which ask for it again. A helper asked for again from the same origin is the last build's while none of its reads
  changed, when typing it made nothing but its function and the helpers it asked for (`UnitReads.standalone`,
  `TypingSession.keptHelper`): those it calls stay with it through the prune, and a function typed to the object its module
  holds keeps its IR. A wire codec serves every root reaching its type, so its requester reads the wire shapes the codecs
  are made from itself.
- **Soundness.** A missing read keeps a stale body: `--check-reuse` and the edit replay (`tests/integration/test-edit-replay.py`)
  are the checks. A failed build may move a print, never a unit's record; prints only move forward, so the units typed
  before it are typed again.

## Rules

- A shared generated artifact's attributes are a function of its subject, never of the code that asked for it.
- No name contains a counter the process keeps across builds; temporaries are numbered per function.
- A shared artifact is ordered by a stable key (its name), never by creation or map order.
- Code that may change what a warm build reuses needs a warm-equals-fresh case.

## Checks

- `--check-reuse` computes every reused result again and compares, naming what differs.
- `tests/compiler/WarmRebuildReuseMain.hx`: a warm build after each kind of edit equals a fresh build, and a build with no
  edit reuses everything.
- The checked suite builds every program a third time (`Main --warm-edit`): it appends a function nothing reaches, then a
  kept one, then moves both inside the file, rebuilding in one session each time; every rebuild must equal a fresh build.
- The program-case runner builds every program as a live build and as a plain build (`Main --plain`), since only plain
  builds prune.

## Open items

- **A shared helper's origin** is its first requester's ([HELPER_OWNERSHIP.md](HELPER_OWNERSHIP.md)).
- **Live builds are not pruned.** A live host can call any function by id, and a patch cannot add or drop functions and
  class-table entries. Pruning them needs a rule for host-called functions (the live protocol on the entry class: `start`,
  `tick`, `close`, `saveState`, `restoreState`, `liveRelease`, `liveRebuild`), keeping every constructor, every function the
  running module holds, and each class's `__liveinit` with its class without making it a root. Functions a live build
  drops are settled: they keep their slots, since a patch cannot remove one, but once the patch that guards them applies
  no stored closure reaches them, so the session keeps their signatures and lowered code and not their IR ([live patching internals](../internals/LIVE_PATCHING.md#what-a-patch-can-add)). Retired functions an adapter serves stay whole, since stored closures still call them.
- **Pruning is per class, not per method.** A reachable class keeps all its methods, because its class table is built from
  the method list; a method can leave only once its slot is derived after pruning.
- **A new constant, global or function relinks the functions after it.** The tables and the function layout are dense
  and ordered by first use, so one entry early in lowering order shifts the indices of later functions, which are
  relinked and encoded again, and the build asks every request of fresh tables (`HlLinkRecord` keeps the tables only
  when nothing moves). This is the cost of output equal to a cold build: an index a cold build gives depends on
  everything before it, so no stable assignment for kept functions can match it, and the shifted functions' code does
  change. What can shrink is the cost per shifted function: patching the cached encoding at its index operands (a
  relocation list per encoded function) would skip the rewrite (`HlLink.rewrite`) and the encode, but HashLink's
  variable-length indices still force encoding a function whose operand widths change, and the validator and the debug
  sections read the rewritten `HlFunction`. Not done: it is a writer and encoding-cache change for a constant factor on
  one kind of edit.
- **A live patch leaves the lines of the functions it keeps.** A function whose declaration only moved is not patched, so
  the running module keeps the line table it loaded: a stack trace through it names the line the function had then, until
  the module reloads (the module written out is right). The patch would need a section that replaces the line table and opcode
  spans of a kept function, and the HashLink fork's loader (`hlpatch.c`) to swap `hl_function.debug` and its spans in place.
- **Names the typer and parser give temporaries carry offsets** (`$compound:`, `$null-coalesce:`, `$downcast:`, `$diff:`,
  `$constructor-test:`). They reach the IR only as the name of a phi, where a temporary is assigned on more than one path; such a
  function still changes when text above it moves. Numbering them within the function, as the generator's locals are
  (`IrLocalsBuilder.internalName`), would remove that; it touches the parser and five typer sites.
- **The inliner does not memoize functions in call cycles** whose inlining depends on the walk order; they are inlined
  again on every build.
- **A value-array shape's pass visits every function** to learn it is not selected, about 95 bytes per function per shape
  (`ValueArrayLoweringSelectionMain` bounds it at 128). Indexing functions by the element shapes they mention would let a
  shape's pass walk only those.
- **Worker memory** after the reuse caches is tracked in TODO.md ("Session memory after the IR columns chain").

## Decided against

- **Fusing the four binding walks of `BodyTyper.typeFunction`** (`ScopedEscapeChecker`, `LexicalStorageAnalysis`,
  `AssignedDeclarations`, `MapEscapeAnalysis`): they differ in traversal, not only in what they observe
  (`rejectDirect` walks sub-expressions itself; `MapEscapeAnalysis` does not report a collection receiver as a use). Fusing
  three of them would save about 1% of a cold build at the risk of changing escape decisions. Revisit when typing becomes
  passes on the query engine.
- **A minimum array capacity of 4 in the stock-Haxe-built worker:** 5% fewer allocations but no measurable build time.
  Revisit when the worker is built by Haxeon (ADR 0003 decision 12) and uses its own array policy.

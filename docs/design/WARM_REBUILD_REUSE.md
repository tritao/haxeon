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
- **IR stages on bodies:** each stage moved onto IR bodies keeps what it made of each function, with the facts it read
  (`IrStageMemo`), and reuses it while the function and the facts are unchanged. The session caching model is in
  [IR_CORE_COLUMNS.md](IR_CORE_COLUMNS.md#session-caching-model).
- **Whole-program walks:** every kept walk keeps its result with what it read in one record (`IrWalkRecord`): copies of
  the program's tables, what its caller gave it (roots, settings, root types), the functions whose declarations it read,
  and the summary of each function it reached. A build reuses the result while the tables and the given inputs are the
  same and each changed function declares the same and, when it was reached, has a summary with the same edges; any
  other change walks again. The type-aware walks summarize a function as `IrWalkSummary`, the HashLink plain build's
  walk and table trim as `IrBodyEdges`; the enum escape reaches follow no function's edges and give the closures and
  map stores they read as inputs, and keep each answer about a supported callable with their results.
- **Inlining:** `IrInlineCache` keeps each inlined function with everything its result depended on.
- **Lowering (HashLink):** a function is lowered with relocations instead of table indices (`HlLoweredFunction`); a link step
  assigns the indices in the order a cold lowering would, so cold and warm output are equal by construction.
  `HlLoweredCache` keeps the last plain build's lowered functions by name. A build whose metadata tables and function
  layout are the last build's keeps the last build's tables as well (`HlLinkRecord`): a function kept at its position
  asks nothing, and what a changed function first asks must be what it first asked last build, except that a String,
  integer, float or String constant only it asked for, which no other entry names, may give way to a new one at the same
  index; anything else lowers again with fresh tables. What lowering reads about other entities goes
  through `HlLoweringView`, which records each answer, and a changed answer lowers the function again. A live build keeps
  its append-only tables and trusts every lowered function it is not told to regenerate.
- **Verification:** a function stays verified while it and what the verifier read about the rest of the program
  (`IrVerifyMemo`) are unchanged.
- **Source hashes:** a function kept across an edit of its file is given the file's current content hash
  (`IrSourceRehash`), so its debug spans name a snapshot the module has.

A failed or rejected build leaves every cache as the last successful build left it: a build works on a copy of the
`SessionState` it started from.

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
  through, changed after it was typed: invalidation checks each unit's reads, with the latest change of each fact found
  once per build (facts that go through each other are one component), and keeps no reverse index to rebuild. A build in
  which no fact changed checks nothing.
- **Where reads are recorded.** At the typer's lookups: the declaration tables (`DeclarationIndex`, the signature tables),
  name resolution, the declaration types (`DeclarationTypes`), purity and never-returns answers, inline constants and
  default arguments. A cached answer is recorded on every use, not only when it is computed. A read outside a unit (program
  set-up) records nothing.
- **Coarse rule, as reads.** An inferred declaration's signature names its own unit, so a reader is typed again when
  anything the declaration read changed (`LAZY_DECLARATION_TYPING.md`, "Coarse rule first"). A caller of a generic
  function reads the specialization's unit, so it is typed again, and requests the specialization again, when the generic
  body or anything the specialization read changed.
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
  no stored closure reaches them, so the session keeps their signatures and lowered code and not their IR (`LIVE_PATCHING.md`,
  "What a patch can add"). Retired functions an adapter serves stay whole, since stored closures still call them.
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
- **Positions are absolute.** IR provenance and debug locations carry byte offsets in the file, so a comment at the top of
  a file lowers every function after it again. Positions relative to the declaration, made absolute when the debug section
  is encoded, would confine an edit to its function; it changes the IR codec, `HlLower`, the debug section and the patch
  format.
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

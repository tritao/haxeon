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
- **Inlining:** `IrInlineCache` keeps each inlined function with everything its result depended on.
- **Lowering (HashLink):** a function is lowered with relocations instead of table indices (`HlLoweredFunction`); a link step
  assigns the indices in the order a cold lowering would, so cold and warm output are equal by construction.
  `HlLoweredCache` keeps the last plain build's lowered functions by name. What lowering reads about other entities goes
  through `HlLoweringView`, which records each answer, and a changed answer lowers the function again. A live build keeps
  its append-only tables and trusts every lowered function it is not told to regenerate.
- **Verification:** a function stays verified while it and what the verifier read about the rest of the program
  (`IrVerifyMemo`) are unchanged.
- **Source hashes:** a function kept across an edit of its file is given the file's current content hash
  (`IrSourceRehash`), so its debug spans name a snapshot the module has.

A failed or rejected build leaves every cache as the last successful build left it: a build works on a copy of the
`SessionState` it started from.

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
  running module holds, and each class's `__liveinit` with its class without making it a root.
- **Pruning is per class, not per method.** A reachable class keeps all its methods, because its class table is built from
  the method list; a method can leave only once its slot is derived after pruning.
- **A new constant or global relinks the functions after it.** The tables are dense and ordered by first use, so one entry
  early in lowering order shifts the indices of later functions, which are relinked and encoded again. Patching the cached
  encoding at its index operands would skip relowering and validation; HashLink's variable-length indices still force
  encoding a function whose length changes.
- **Positions are absolute.** IR provenance and debug locations carry byte offsets in the file, so a comment at the top of
  a file lowers every function after it again. Positions relative to the declaration, made absolute when the debug section
  is encoded, would confine an edit to its function; it changes the IR codec, `HlLower`, the debug section and the patch
  format.
- **The frontend can run twice** when typing asks for a runtime module the graph lacks
  ([FRONTEND_RESTART.md](FRONTEND_RESTART.md)).
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

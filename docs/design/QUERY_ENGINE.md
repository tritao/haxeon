# Query engine (design note)

Status: steps 1 and 2 are done and step 3 is under way. The engine core is in `compiler.query`. Each session's database holds
the build inputs (step 2, `BuildInputs`) and, as a kind of its own, the facts typed units read: the typer records its reads in
the engine's frames, and a unit's reads are verified by the engine (step 3, slice 3a). What each unit read is a result of that
kind, written in a transaction the taken build commits (slice 3b). The IR stages, lowering and encoding still keep results
through their own mechanisms; "Steps 4 onward" lists them, what each becomes, and the order they move in. ADR 0003
decisions 1, 10 and 14 are the requirements; this note is how. The pass framework (M2) is built on this engine.

## Why now

A one-string edit of the compiler's own sources takes about 7 s in the compile server, against 1.3 s for a no-op. Typing is
already incremental (5% of the edit); the IR passes rerun over all ~8,200 functions (66%), with no stage above 0.6 s
(`IR_PASS_INVENTORY.md`, "Edit time"). The gain is one mechanism applied to every stage, not a faster stage.

Today each reuse path has its own cache and rule: the typer's recorded reads (`WARM_REBUILD_REUSE.md`), the inline
cache's dependency lists, the verifier memo, `HlLoweringView`, the program-level no-op shortcut, the pipeline snapshot. The
identity-keyed stage cache tried on 2026-11-18 never hit, because each build makes fresh table objects. The engine
replaces them with one rule.

## Model

A **session database** holds memos. A memo is the result of one query:

```
Memo
  key          QueryKey           // kind + interned key id
  value        the output         // owned (ADR 0003 decision 14)
  digest       Digest             // structural, of the value
  verifiedAt   Revision           // last revision at which the memo was known current
  changedAt    Revision           // last revision at which its digest changed
  reads        Array<Int>         // what the computation read, in order: kind index << 24 | key, one Int each
```

A read is one Int (`QueryRead`): a database holds at most 256 kinds and a kind at most 2^24 keys, and the first kind's reads
are its keys. A memo's reads are compared through the digest each dependency has now, not one recorded beside the read: the
dependency's `changedAt` says whether it changed after the reader was verified. A computation records each read once, in the
order of its first read.

- **Inputs** are memos set from outside, never computed: a module's source text, the compile options that change
  output (`CompileOptions.key()`), the target profile, and the compiler's own identity. Setting an input to a value with
  a different digest starts a new revision.
- **Derived queries** are functions `(context, key) -> value`. A query reads anything only through `context.read(kind,
  key)`, which records the read. Reading a static, a global table or another query's object directly is a bug, caught by
  check mode (below).
- **Keys** are typed per kind and interned to dense ids, as `IrSymbol` interns names. A key is never a concatenated
  string on a hot path.
- **Kinds are classes** (`QueryKindBase`, `QueryKind<V>`, `RecordedQueryKind`), not interfaces: HashLink calls an interface
  method by name, a class method through its table, and verification calls a kind's `changedAt` once per read.
- **Recorded kinds** hold results a stage computes outside the engine, in its own order, as the typer types units
  (`RecordedQueryKind`, below).

## Evaluation

`get(key)` at revision `R`, red-green as in rustc and salsa:

1. A memo with `verifiedAt == R` is current: return it.
2. Otherwise **try to verify** it: for each recorded read in order, bring that dependency up to date (recursively) and
   compare its digest with the one recorded. If none changed, set `verifiedAt = R` and return the memo without running
   anything. Most of an edit build should end here.
3. Otherwise **recompute**, recording reads afresh. If the new digest equals the old one, keep `changedAt` (**early
   cutoff**): readers of this memo verify in step 2 without recomputing.

Reads are checked in recorded order, so a dependency that would only be read after a changed one is never brought up to
date needlessly.

**Digests** are 64-bit hashes with two independent 32-bit halves, as `SourceFile` does. A digest match is trusted in
normal builds; check mode compares whole values. A kind digests its values one of two ways:

- **By content** (`QueryKind.derived`, every input): the value type feeds its parts. Values that are interned (types,
  symbols) digest by id. This is what early cutoff needs.
- **By computation** (`QueryKind.computed`): the kind, the key and the digests of the reads, in order. It costs nothing
  and is sound, since a computation is a function of its reads, but a recomputed value always counts as changed, so its
  readers get no early cutoff.

IR functions are digested by computation. Measured on the compiler's own sources (2026-11-19): the full encoding of all
8,538 functions at the scalar replacement stage (`IrFunctionStateCodec.encode`, which `IrFunctionDigest` hashes) is
98.5 MB and takes 3.1 s to make and 0.4 s to hash, while the pass itself takes 30 ms. A content digest per function per
pass would cost a hundred times the work it saves. `IrFunctionDigest` stays for inputs set once per build where a
function is new, for check mode, and for tests.

## Results computed outside the engine

The typer does not compute a unit on demand: `ProgramTyper` types the selected units in declaration order, merges each
output at its slot, and types an inferred declaration where it is first needed (`LAZY_DECLARATION_TYPING.md`). Until it is
driven by the engine (step 3, later slices), its units are results of a **recorded kind**:

- **Recording.** A stage opens a frame (`QueryDatabase.beginRecording`), reads through `QueryDatabase.record`, and takes the
  reads when it closes the frame. Frames nest, as a unit typed inside another does; each records its own reads once, and
  the frame below keeps recording each read once after an inner one closes.
- **No digest of its own.** A recorded result changed when it changed itself or when anything it read changed,
  transitively. That is the typer's coarse rule: a reader of an inferred declaration is typed again whenever anything the
  declaration's unit read changed. Readers get no early cutoff through it until the declaration's type is a memo digested
  by content (step 3, slice 3c).
- **Components, not cycles.** Units read each other: two unannotated functions that call each other, two generic functions
  whose specializations call each other. The stage settles such a cycle itself (the `DeclarationTypes` rule reports it once
  and fails the members), so the engine treats results that read each other as one component (Tarjan's algorithm, without
  recursion, since chains of units can be long), all of which changed when the latest of them did.
- **Partial reads.** A kind can say that a read sees only a part of what it names: a declaration that names a class reads
  only its kind (interface, class, enum), not its shape (`RecordedQueryKind.partialChange`). The facts make this a rule of
  the edge rather than a read of an input of its own, because whether a type is expanded (a typedef or an abstract) is
  learned while the prints are compared, in module order, after the declarations naming it have recorded what they go
  through.
- **Results and transactions.** A recorded kind holds each key's result (`RecordedResult`: the revision it was computed at and
  its reads), which a build writes as it goes (`RecordedQueryKind.write`) and reads back at once. A result describes what the
  build's state holds (a unit's record, the typed body in its module), so a build that is not taken must not leave its results
  behind. Each write keeps what undoes it: the database commits a build's writes when its state is taken
  (`QueryDatabase.commit`, `Compiler.adoptCandidate`), and returns to the commit a state was taken at (`rollBack`) when a build
  starts from that state (`SessionState.copyForCandidate`) or the compiler returns to it (a rejected or retracted publication).
  What undoes a commit is kept while a state before it can be returned to: the state the last build replaced and the
  publications' snapshots (`keepRollbackTo`). Computed memos take no part: a memo is a function of its reads, whichever build
  made it.
- **Revisions.** A build starts a revision of its own (`QueryDatabase.newRevision`), since prints move while it runs and a
  unit is current when nothing it read changed after the revision it was typed at. Input changes advance the **input
  revision** besides; a result reused whole (`Compiler.compile`'s no-op result) is current while the input revision is.

**Cycles.** The engine keeps the stack of active queries. A query that reads one already on the stack is a cycle: the engine
reports it with the stack's kinds and keys. A query kind may declare a cycle result (the `DeclarationTypes` rule: report
the cycle once, then the members are failed); otherwise a cycle is an internal error.

## Determinism

A query's value must be a function of its recorded reads. The rules that make this hold:

- **No unrecorded state.** Statics that hold program or target state were removed in M1; `@:processWide` statics are
  caches whose answers never change (interning tables). Interned ids may index tables but must never decide the order of
  anything a query outputs (`IR_SYMBOLS.md`).
- **No hash-order output.** A query iterates in program order or sorts; map iteration order is never observable.
- **Owned outputs.** A value may hold values, interned ids and other queries' values, never its computation's scratch or
  another query's internals (ADR 0003 decision 14). This is also what lets a memo outlive the build that made it.

## Whole-program steps

Some stages need the whole program: pass summaries, reachability, link. Each is a query whose value is small and whose
reads are per-function **contributions**, themselves queries. A summary's digest decides whether the per-function
rewrites that read it rerun. A rewrite reads only the summary fields it uses, per key (a closure type, a candidate), so one
new key does not rerun every function (`IR_PASS_INVENTORY.md`, Interface, rule 2).

Fixpoint passes (`IrScalarArguments`, `IrNullableScalarFlow`, `IrOptionalScalarFlow`) record their candidacy reads as
engine reads. An edit re-decides the changed functions and the readers of any candidacy that flips (ADR 0003 decision 4).

## Lifetime and memory

- The database lives with the session (compile server, language server). A one-shot compile uses the same engine with
  nothing retained after the build.
- **Sweep.** After each build, memos not verified in that revision and not reachable from a root (the build's outputs,
  the language server's open documents) are dropped. Memory is reported per build: the worker's resident size after a warm
  build (ADR 0003, Consequences).
- **Scratch regions** (ADR 0004 section 6) come per query kind once that kind's outputs are proven owned and release is
  cheap.

## Check mode

`--check-reuse` keeps its meaning (ADR 0003 decision 10), with one implementation: every memo reused at step 2 is also
recomputed, and the two values are compared structurally. A difference names the kind, the key, and the first differing
part. The per-cache checks (pipeline snapshot, verifier memo, lowering reuse) are deleted as their caches move onto the
engine.

## Concurrency

The first engine is single-threaded. Keys and values are immutable and reads are explicit, so evaluating independent
queries on several threads (parse already can, `--parse-threads`) is a later step, opt-in like parsing.

## Steps

Each step is byte-identical on the self-compile and the program suites, and keeps the warm-versus-cold tests passing.

1. **Engine core**, with unit tests on synthetic queries: reuse without recompute, early cutoff, cycles, sweep, check
   mode. No compiler stage uses it yet.
2. **Inputs** (done): module sources, the embedded texts a module's parse read, the options key, the target profile, and the
   rest of what a build reads from its request (defines, source roots, exported functions, FFI interfaces), as `BuildInputs`
   on the session's database. They replace the compiler's hand-kept source generation: a compile whose input revision is
   the last build's returns that build's result.
3. **`DeclarationTypes` on the engine.** Its reads become engine reads, and its `DeclarationType` edges, which became `Unit`
   reads, become recorded dependencies. This proves the engine on the typer's existing rule. In slices:
   - **3a (done): reads and their verification on the engine.** The facts are the database's first kind
     (`DeclarationFacts extends RecordedQueryKind`), so a fact's id is its read. The typer's `DeclarationReads` and the
     purity inference's dependency memo record in the engine's frames, and a unit's reads, the facts' dependencies and the
     kind rule are verified by the engine's walk. Unit records stayed in `ModuleState.unitReads` until 3b, so a rejected
     build's records rolled back with its modules.
   - **3b (done): unit records in the database.** What a unit read is its `Unit` fact's result (`UnitReads`, with the module
     whose state holds the unit's body), written in the build's transaction and committed when the build is taken, so
     rollback no longer needs module copies of the records; `ModuleState.unitReads` and `placeUnit` are gone. Invalidation
     walks the results of the build's modules in fact order. The specialization rule (a specialization is kept only while a
     unit that stays asks for it) is reachability over the results from the build's roots, the units of its modules typed or
     kept in it (`FrontendCompilation.reachedSpecializations`); the prune sweeps an unreached specialization's body and its
     record together. Design changes from the plan:
     - The records are not swept by the engine's own sweep (memos neither verified nor reached are dropped). A record of a
       module outside the build must stay while that module's state keeps the bodies it describes, or the module would come
       back with bodies nothing checks. The engine sweeps records once the database holds a unit's typed body with its record
       (a later slice of this step), so that the two go together.
     - Rollback is an undo log in the recorded kind, not a write buffer committed at the end: a build reads its own writes at
       no cost, and one mechanism serves a build that was not taken (its open writes are undone when the next build starts)
       and a publication the host rejected or retracted after its build was taken (its commits are undone).
     - A record keeps its unit's module: invalidation and the specialization rule look up the typed body through it, which
       the per-module maps gave before.
   - **3c: declaration types digested by content** (large: `DeclarationTypeTable`, `ProgramTyper`, `SemanticAssembly`). An
     inferred declaration's type becomes a memo digested by its type (`SemanticSignature.type`, as
     `ModuleState.declarationTypeDigests` holds it now), read by its readers instead of the unit. An edit that leaves the
     type equal stops at it: early cutoff, which is `LAZY_DECLARATION_TYPING.md`'s slice 6. It needs the selection to grow
     while typing runs: a reader is typed again only once a declaration it read typed to another digest. The seeds
     (`seedField`, `seedFunctions`, `ModuleState.inferredSignatures`) become the memos' values.
   - **3d: prints as queries over the sources** (large; with M4c). `DeclarationPrints` compares canonical forms module by
     module; as derived queries over the `sources` inputs, a print's facts would be computed on demand, and naming a type
     would read an input of its own, the type's kind, instead of the partial-read rule.
4. **Every other reuse mechanism, in pipeline order from the front** (below). A stage gets reuse only if its input is the
   same memo as last build, so the chain starts at IR generation's per-function cache (`ModuleState.irFunctions`) and each
   stage moves after the ones before it, deleting its own mechanism in the same change: per-function rewrites as computed
   queries, whole-program stages as summaries over per-function contributions, the fixpoints and the inliner where the
   chain reaches them, then lowering (M4b). The front-end caches follow with 3c and 3d (M4c).

Measures for every step: self-compile cold (no more than 2% slower while stages are being moved), the compile server's
body, signature and blank-line edits and no-op (perf-guard), and the worker's resident memory after a warm build.

## Steps 4 onward: one reuse mechanism

Measured on the compiler's own sources (2026-11-25, main-thread instructions in the compile server): a body edit costs 2.44G,
a signature edit 18.5G (typing 4.9G, IR generation 1.9G, IR passes 2.9G, inliner 2.2G, HashLink lowering 3.7G, metadata
0.55G, encode and write 1.1G), a blank-line edit 7.6G (inliner 2.1G, lowering 2.6G). On the signature edit about 950
functions changed, yet whole-program walks read 9,753 (value-array rewrite), 9,151 (encode bodies) and 6,111 (inliner).

### Inventory

Everything below keeps results across builds outside the engine. Lines are the file's, or the part of it named.

| Mechanism | Lines | Keyed on; kept until | Read by | Becomes |
|---|---|---|---|---|
| `IrStageMemo`, `IrStageMemos`, `IrStageEntry` | 526 (the file, with `IrLineage` and the contribution memos) | stage and function slot; input version, fact reads, output, summary, helper requests; dropped when the stage's last run did not use it | `IrFunctionStages.run`, the ~25 `IrFunctionPass` stages | a computed kind per stage, keyed by function symbol |
| `IrLineage`, `IrFunctionVersions`, `IrFunctionSlots`, `ModuleState.irVersions` | (above), 17, 95 | slot → function object and version; a version is never given twice; slots swept when cells exceed twice the functions | every stage (`settle`, `versionOf`), `IrStage` | a memo's identity and `changedAt`; `settle`'s equality check becomes early cutoff by `IrFunctionStateEquality.same` |
| `IrFacts`, `IrFactReader`, `IrAnswerSource` | 275, 85 | space, kind, key text → value or answer, and a print; dropped when unread a build | passes, `IrVerifyMemo`, `HlLoweringView` | derived kinds digested by value (the prints are digests) |
| Contribution memos, `lastResult`/`keepResult`, kept helpers (in `IrStageMemo.hx`) | (above) | function version → contribution; whole-program results checked by `holds`; helpers by name for one build | ~12 passes (`IrTypeAwareWalk.SUMMARIES`, `IrClosedEnumTagAbi.ESCAPES`, `IrScalarArguments.CLOSURE_NAMES`, ...) | contribution queries, summary queries over them, helpers as derived queries by name |
| `IrWalkRecord` with `IrWalkSummary`, `IrBodyEdges` comparison | 209 | copies of six program tables, given inputs, read functions and their summaries; one per walk | `IrTypeAwareWalk.runKept`, `IrEntryPrune`, `IrEnumEscapeReach`, `IrScalarArguments`, `IrNullableScalarFlow`, `HlPlainBuild.reachable` | summary queries; tables read as table results |
| Reuse code inside passes | ~750 lines naming the above in 49 files; est. 1,000–1,400 with the code around them | — | — | query declarations (est. a third of it); fact reads stay as engine reads |
| `IrGeneratedFunctions` (structure printers, initializers) | 95 | key and identity of the input objects; swept when untouched | `FrontendCompilation`, `IrProgramAssembler` | derived query per generated function |
| `objectCache`, `canonicalObjectCache` (`SessionState`) | ~40 in `FrontendCompilation` | class name; while the declaration is unchanged | frontend, walks' table copies | table results: an equal table is last build's object |
| `IrFunctionMemo` and its users: `irTypeMentions`, `irCalls`, `staticReferences`, `HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo` | 46; 41 (`HlFunctionSummaries`), ~12, ~25 | `IrFunction` identity; one build past last use | frontend, `StaticInitializationOrder`, `RuntimeAbi`, `IrReachability`, `HlLower`, `IrNonNullFields` | contribution queries |
| `IrSourceRehash`, `irSources` | 130 | function → file hashes its locations name | frontend | gone with relative positions (the hash is added at encode), else a derived query |
| `IrVerifyMemo` | 190 | function name → function and answer facts | `IrVerifier` | computed query per function |
| `IrInlineCache` and the inliner's memo plumbing | ~170, ~100 | name → original body, instrumented form, published form, object facts, positional prints; maps replaced per run | `IrInliner`, `Compiler` (published) | inlined form per function; a call cycle is one component query; `published` moves to the live state |
| `PipelineSnapshot` | 157 | tables' encoding, functions' identity, environment text; last plain build | `CompilationPipeline`, backends | the root query (final IR, module) verifies; deleted with its check |
| `HlLoweredCache`, `HlLoweredFunction`, `HlLoweringView` facts | 83, 45, 162 | name and lowering environment; the build's entries; facts never swept | `HlLower` | computed query per function: relocatable code, reading object facts as engine reads |
| Link and replay: `HlRequestKeys`, `HlRequestAnswers`, `HlSymbolRequest`, `HlLink`, `HlLinkRecord`/`HlKeptTables`, parts of `HlSymbolTable` and `HlLower` | 196, 66, 102, 120, 251, ~150, ~290 | request numbers (grow only); last build's tables with each position's first requests | `HlLower` | module sections ([MODULE_SECTIONS.md](MODULE_SECTIONS.md)) |
| `HlDebugMetadataCache` | 66 | stable id; one generation | `HlLower`, assembler | per-function query |
| `HlWriterCache` | 216 | `HlFunction` identity (encodings, validation marks, span groups), all dropped when the debug-file list changes; compressed sections by kind | `HlWriter`, `HlValidator`, `CompilerSession` | per-function encode query (~120 lines go); the compressed-section memo stays |
| Wasm module reuse (`WasmBackendSession.encoded`) | ~30 of 181 | identity of the final IR and options | Wasm backend | the root query |
| **Stays:** `HlModuleAssembler`, `HlFunctionCache`, `HlSymbolTable`'s published prefix, `hl/persistence`, Wasm `patchState` | 1,041, 286, —, 933 | published slots and stable ids | live patching | not caches: the running module's state, an input to the next patch; with module sections the slots move to the loader and these shrink to the semantic baseline (MODULE_SECTIONS.md, 4) |
| **Stays here:** frontend prints and canonical forms, `semanticProgram`, `programFacts`, `lastTypedProgram`, `ReachabilityCache`; interning tables | — | — | — | step 3c/3d and M4c; COMPILER_FOUNDATIONS item 4 |

`HlcBackendSession` keeps nothing. The compiler's no-op result is already the engine's (step 2).

### Stable output indices

Superseded by per-module sections with load-time linking ([MODULE_SECTIONS.md](MODULE_SECTIONS.md)): no global indices
in the output, so nothing shifts. The measurement below still holds; the ranges design is not pursued.

On the signature edit no table was kept (`HlLinkRecord` fits only when nothing moves): 7,922 functions with unchanged IR were
linked again, 5,501 of them with moved indices, and 938 lowered fresh. The body edit kept the tables and its 8,857 functions
in place, at no cost. What exists only to reproduce a cold build's first-use numbering, about 1,000 lines:

- `HlRequestAnswers` (66), `HlLinkRecord` and `HlKeptTables` (251): replaying requests in program order rebuilds first-use
  tables; kept tables with leaf replacement.
- `HlSymbolTable.shareFrom`, `replaceLeaf`, `truncate`, `lengths`/`sameLengths`, `typesName`, `stringConstantAt` (~150).
- In `HlLower`: the recording in every `intern*` and `record` (~70), the kept-tables and link branches of
  `lowerProgramWithNatives`, the kept String constants, `settleKept`, `settleTables`, `slotNames`, `verifyLinking`,
  `sameReplayTable` (~220).
- The answers half of `HlRequestKeys` and `HlLoweredFunction`, and `HlSymbolRequest`'s answer payloads (~150);
  `HlLink.link`'s request checks (~40).

**A stable order alone does not delete the relink.** In a dense table any deterministic order moves every entry after an
inserted one; ordering by module and declaration changes which entries move, not how many. It does make the tables a function
of the set of entries rather than of lowering order, so the replay above goes. To delete the relink and the re-encode
too, the order needs slack:

- **Ranges.** Functions by module in program order, then declaration order, generated ones after their owner. Every other
  entry (type, global, int, float, String) belongs to the first module in program order that uses it, and is sorted within
  that module's range by its key (a type by its canonical key, never a process-local type id). Each range has a capacity
  that is a function of its count alone (for example rounded up with headroom), so a cold build makes the same holes.
  An edit moves only the entries of the ranges it overflows, and the entries that change owner.
- **Linking.** Lowering emits entry keys (what `HlRequestKeys` numbers today), and a per-function link resolves them; a
  function that reads no moved range keeps its code and encoding. Which ranges a function reads is a contribution.
- **Cold build.** One link over every function, since a range's layout is known only once all functions are lowered (est.
  under 1% of a cold self-compile); filler entries in the holes (est. a few percent of the tables). Measure cold runtime
  for locality.
- **HashLink fork loader.** It already reserves patch slots past `nfunctions` (`functions_capacity`, `functions_indexes`
  filled with -1); holes inside the range need it to accept absent findexes, and typed tables need fillers (`void` types
  and globals) or a marker the loader skips.
- **Live patching.** Live builds keep their append-only published prefix (`HlFunctionCache`, `HlSymbolTable`); a module's
  first publication takes the cold layout, and a patch may later fill holes instead of appending.
- **Debug info.** Function identities use stable ids, not findexes. The debug-file table is still first-use dense: a new
  file drops every encoding in `HlWriterCache`; sort files by path, with the same slack rule if new modules are frequent.
- **Operand widths.** Unmoved indices keep their widths; a range that overflows across a width boundary re-encodes its users.

Expected on the signature edit: the 0.75G link and most of the re-encoding of the 5,501 moved functions (write is 1.14G
there against 0.11G on the body edit), about 1.5G (estimate). Nothing on the body edit, which keeps its tables already.

### Order

Each slice is checked by `--check-reuse` on the self-compile (engine check mode, which replaces the slice's own check), the
edit replay, the warm-equals-fresh mains, the byte-identical self-compile, perf-guard, and the Wasm warm tests where IR stages
change (they run for Wasm too). Savings are estimates from the profile above (body / signature / blank-line edit, G).

| # | Slice | Size (est. lines) | Deletes | Expected | Depends on |
|---|---|---|---|---|---|
| A | Relative positions (in progress elsewhere) | — | `IrSourceRehash` (likely) | blank-line edit: most of the inliner and lowering 4.7G | — |
| B | Module sections and load-time linking ([MODULE_SECTIONS.md](MODULE_SECTIONS.md), its slices 1–5) | −3,300 / +1,200, fork +650 net | link and replay, published slots and stable ids, symbol persistence | 0.1 / 1.4 / 0 | A; checks also ci-tier debug-metadata and hot-reload, self-compile oracle takes a new base |
| 1 | Engine for per-function stages: a computed kind keyed by function symbol with equality cutoff, contributions and summaries with per-key reads, sweep of computed memos | +400 | — | none; verifying the memos must keep the body edit at today's cost (`IrLineage.start` alone is 2.4% of it) | — |
| 2 | IR generation, generated functions, object tables as results | −450 / +250 | `IrFunctionVersions`, `IrGeneratedFunctions`, `objectCache` maps, `IrLineage.start`, frontend `IrFunctionMemo` users | 0.1 / 0.1 / 0.1 | 1 |
| 3 | Assembly stages before the encode point | −2,000 / +500 | `IrStageMemo`, `IrLineage`, `IrFacts`, `IrFactReader`, `IrFunctionSlots`, `IrWalkRecord`, contribution memos, memo paths of `IrFunctionStages` and `IrStage` | 0.05 / 0.4 / 0.05 | 2 |
| 4 | Stages after the encode point, then the fixpoints (candidacy reads, ADR 0003 decision 4) | −400 / +250 | their whole-program rereads | 0.2 / 1.2 / 0.2 | 3 |
| 5 | Inliner | −300 / +150 | `IrInlineCache` except `published`, inliner memo | 0.05 / 1.2 / rest after A | 4 |
| 6 | Verification and final-IR summaries | −450 / +100 | `IrVerifyMemo`, `IrFunctionMemo`, `HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo`, plain-build reach record | 0.1 / 0.3 / 0.05 | 5 |
| 7 | Lowering, debug metadata and encoding as queries; root query | −850 / +300 | `HlLoweredCache`, `HlLoweredFunction`, `HlLoweringView` facts, `HlDebugMetadataCache`, `HlWriterCache` encodings, `PipelineSnapshot`, Wasm module reuse | small; no-op must stay at 0.29 s | B, 6 |

B touches only `hl/` and can land beside 1–3. The largest part of the signature edit, typing and IR generation (6.8G), is
step 3c's and the frontend's, not this plan's. Estimated together: the body edit from 2.44G to about 1.9G, the signature
edit from 18.5G to about 13.8G.

**Net lines (estimate):** about 5,450 deleted and 2,350 added in `src/`, about 3,100 fewer, plus the test mains of
deleted mechanisms (`IrVerifyMemoMain`, `WarmStageFactsMain`, `StaticNullCheckReuseMain`, `InlinerSession`,
`HlWriterCacheMain`, about 450 lines) rewritten as engine checks of about half that.

## Prior art

- salsa (rust-analyzer): revisions, red-green verification, early cutoff, durability.
- rustc's query system: dep-graph with fingerprints, recorded reads, cycle errors.
- Swift's request evaluator: requests with cycle detection and cached results.

## Open questions

- **Granularity of typing queries.** Per function body, as today's units; whether generic specializations are separate
  queries (they are shared units today) follows generic typing stage 2 (`GENERIC_TYPING_ONCE.md`).
- **Durability.** Standard-library inputs rarely change; salsa's durability levels let a build skip verifying them. Worth
  measuring once the engine holds the typer.
- **Persistence.** Out of scope (ADR 0003 decision 1).

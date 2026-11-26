# Query engine (design note)

Status: steps 1 and 2 are done and step 3 is under way. The engine core is in `compiler.query`. Each session's database holds
the build inputs (step 2, `BuildInputs`) and, as a kind of its own, the facts typed units read: the typer records its reads in
the engine's frames, and a unit's reads are verified by the engine (step 3, slice 3a). What each unit read is a result of that
kind, written in a transaction the taken build commits (slice 3b). The IR stages, lowering and encoding still keep results
through their own mechanisms; "Steps 4 onward" lists them, what each becomes, and the order they move in. Its slices 1 and 2
are done: the engine has the kinds they move onto (`ComputedQueryKind`, `QuerySummary`), and IR generation, the functions the
frontend generates, the program's objects and what the frontend reads of each IR function are results in the database. Slice 3
is under way: every per-function stage runs on the engine's stage driver, its facts a kind of the database, and the lineage of
versions is gone ("Slice 3 as built"); the whole-program memos of the stages before the encode point are next. ADR 0003 decisions 1,
10 and 14 are the requirements; this note is how. The pass framework (M2) is built on this engine.

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
- **Kinds are classes** (`QueryKindBase`, `QueryKind<V>`, `RecordedQueryKind`, `ComputedQueryKind<V>`, `QuerySummary`), not
  interfaces: HashLink calls an interface
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
- **By equality** (`ComputedQueryKind`), for values too large to digest: a value computed again is compared with the one kept
  by the kind's `same`, and an equal one keeps the kept object and the revision it changed at. It costs a comparison only
  where a key was computed again, and readers get early cutoff. It replaced digesting by computation (the kind, the key and
  the reads' digests), which cost nothing but counted every recomputed value as changed, so its readers had no cutoff.

IR functions are cut off by equality (`IrFunctionStateEquality.same`, which the stage driver compares, `IrFunctionStages.run`). Measured on the compiler's own sources (2026-11-19): the full encoding of all
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
  made it. But an undone result takes back the older revision it changed at, against which a memo computed over the undone
  one would verify, so a rollback that undid anything drops the memos computed after the commit it returns to
  (`forgetComputedAfter`).
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

The engine's summary is `QuerySummary`: which keys some contributor names, each contribution an array of keys (a computed
memo, so one that held is the same array). A stage gives every contributor's contribution in each run between `open` and
`close`; a contribution that is the array kept costs one comparison, a changed one is applied key by key, and a contributor
not given is retracted at `close`. A contribution made of its contributor's input alone is kept without being made while that
input has not changed since it was given (`holds`). A reader reads one key's presence (`has`), or the whole set (`keys`), which changes with
any key; only a key that appears or goes changes. A walk over the program (reachability, `IrWalkRecord` today) is a computed
memo whose reads are the contributions of the functions it reached and the tables it read, verified like any other.

Fixpoint passes (`IrScalarArguments`, `IrNullableScalarFlow`, `IrOptionalScalarFlow`) record their candidacy reads as
engine reads. An edit re-decides the changed functions and the readers of any candidacy that flips (ADR 0003 decision 4).

## Lifetime and memory

- The database lives with the session (compile server, language server). A one-shot compile uses the same engine with
  nothing retained after the build.
- **Sweep.** After a build that brought up to date everything it keeps, the memos of the computed kinds it used that it did
  not verify since it began (`QueryDatabase.buildRevision`, not the latest revision, which inputs set during a build move)
  are dropped (`QueryDatabase.sweep`, run when the build is taken, `Compiler.adoptCandidate`); a kind the build did not use,
  as a stage that did not run, keeps its memos, and so does a kind that gained no memo since its last sweep, which holds no
  more than that sweep left (no-op and body edits add no key). Roots that keep memos a build did not use (the language
  server's open documents) come with their first user. Memory is reported per build: the worker's resident size after a warm
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
| `IrStageMemo`, `IrStageMemos`, `IrStageEntry` | 526 (the file, with `IrLineage` and the contribution memos) | stage and function slot; input version, fact reads, output, summary, helper requests; dropped when the stage's last run did not use it | `IrFunctionStages.run`, the ~25 `IrFunctionPass` stages | a computed kind per stage, keyed by function symbol; done for every per-function stage (slice 3), the inliner keeps `IrStageMemo` until slice 5 |
| ~~`IrLineage`, `IrFunctionSlots`~~ | (above), 95 | slot → function object and version; a version is never given twice; slots swept when cells exceed twice the functions | every stage (`settle`, `versionOf`), `IrStage` | done (slice 3): a version is the function object's own number (`IrFunction.version`), settling is early cutoff in the stages' kinds |
| `IrFacts`, `IrFactReader`, `IrAnswerSource` | 275, 85 | space, kind, key text → value or answer, and a print; dropped when unread a build | passes, `IrVerifyMemo`, `HlLoweringView` | derived kinds digested by value (the prints are digests); the passes' facts are done (slice 3: `IrStageFacts`, `IrFactReader` reads it); `IrFacts` stays for the inliner (slice 5), verification (6) and lowering (7) |
| Contribution memos, `lastResult`/`keepResult`, kept helpers (in `IrStageMemo.hx`) | (above) | function version → contribution; whole-program results checked by `holds`; helpers by name for one build | ~12 passes (`IrTypeAwareWalk.SUMMARIES`, `IrClosedEnumTagAbi.ESCAPES`, `IrScalarArguments.CLOSURE_NAMES`, ...) | contribution queries, summary queries over them, helpers as derived queries by name; helpers done (slice 3, a kind put by name), the rest left ("Slice 3 as built") |
| `IrWalkRecord` with `IrWalkSummary`, `IrBodyEdges` comparison | 209 | copies of six program tables, given inputs, read functions and their summaries; one per walk | `IrTypeAwareWalk.runKept`, `IrEntryPrune`, `IrEnumEscapeReach`, `IrScalarArguments`, `IrNullableScalarFlow`, `HlPlainBuild.reachable` | summary queries; tables read as table results |
| Reuse code inside passes | ~750 lines naming the above in 49 files; est. 1,000–1,400 with the code around them | — | — | query declarations (est. a third of it); fact reads stay as engine reads |
| ~~`IrGeneratedFunctions` (structure printers, initializers)~~ | 95 | key and identity of the input objects; swept when untouched | `FrontendCompilation`, `IrProgramAssembler` | done (slice 2): results in the generation kind with their reads |
| ~~`objectCache`, `canonicalObjectCache` (`SessionState`)~~ | ~40 in `FrontendCompilation` | class name; while the declaration is unchanged | frontend, walks' table copies | done (slice 2): objects by name in a computed kind, one made the same is last build's; the object set stays state (below) |
| `IrFunctionMemo` and its users: ~~`irTypeMentions`, `irCalls`, `staticReferences`~~, `HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo` | 46; 41 (`HlFunctionSummaries`), ~12, ~25 | `IrFunction` identity; one build past last use | frontend, `StaticInitializationOrder`, `RuntimeAbi`, `IrReachability`, `HlLower`, `IrNonNullFields` | contribution queries; the frontend's three are (slice 2) |
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
| 1 | **Done** (below): engine for per-function stages: a computed kind keyed by function symbol with equality cutoff, contributions and summaries with per-key reads, sweep of computed memos | +400 | `QueryKind.computed` | none; verifying the memos must keep the body edit at today's cost (`IrLineage.start` alone is 2.4% of it) | — |
| 2 | **Done** (below): IR generation, generated functions, object tables as results | −450 / +250; built −437 / +527 | `IrFunctionVersions`, `IrGeneratedFunctions`, `canonicalObjectCache` (`objectCache` stays as the object set), the INPUT settling of `IrLineage.start`, frontend `IrFunctionMemo` users | 0.1 / 0.1 / 0.1; built 0.03 / 0.02 / not measured (no-op 0.03) | 1 |
| 3 | Assembly stages before the encode point; first part **done** (below): the stage driver for every per-function stage, facts as a kind, the lineage gone | −2,000 / +500; first part built −~700 / +~650 (below) | `IrStageMemo`, `IrLineage`, `IrFacts`, `IrFactReader`, `IrFunctionSlots`, `IrWalkRecord`, contribution memos, memo paths of `IrFunctionStages` and `IrStage`; first part: `IrLineage`, `IrFunctionSlots`, the stage memos of the per-function stages, the memo paths of `IrFunctionStages` and `IrStage` | 0.05 / 0.4 / 0.05; first part: body edit −0.7%, no-op 0, signature edit +0.5% | 2 |
| 4 | Stages after the encode point, then the fixpoints (candidacy reads, ADR 0003 decision 4) | −400 / +250 | their whole-program rereads | 0.2 / 1.2 / 0.2 | 3 |
| 5 | Inliner | −300 / +150 | `IrInlineCache` except `published`, inliner memo | 0.05 / 1.2 / rest after A | 4 |
| 6 | Verification and final-IR summaries | −450 / +100 | `IrVerifyMemo`, `IrFunctionMemo`, `HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo`, plain-build reach record | 0.1 / 0.3 / 0.05 | 5 |
| 7 | Lowering, debug metadata and encoding as queries; root query | −850 / +300 | `HlLoweredCache`, `HlLoweredFunction`, `HlLoweringView` facts, `HlDebugMetadataCache`, `HlWriterCache` encodings, `PipelineSnapshot`, Wasm module reuse | small; no-op must stay at 0.29 s | B, 6 |

B touches only `hl/` and can land beside 1–3. The largest part of the signature edit, typing and IR generation (6.8G), is
step 3c's and the frontend's, not this plan's. Estimated together: the body edit from 2.44G to about 1.9G, the signature
edit from 18.5G to about 13.8G.

### Slice 1 as built

Two kinds in `compiler.query`, tested on synthetic queries in `QueryEngineMain`; no stage uses them yet.

**`ComputedQueryKind<V>`** (`new(name, same, ?compute, ?keyName)`): values per Int key, cut off by equality (Digests,
above). Computed on demand when the kind has `compute` (`get`), or by a stage in its own run:

```
if (kind.current(db, key))           // held: nothing it read changed since it was verified
    out = kind.value(key);            // check mode: kind.begin(db, key); kind.check(db, key, rewrite())
else {
    kind.begin(db, key);              // a frame records what the rewrite reads through the database
    out = kind.end(db, key, rewrite()); // the kept object when `same`, else the new one, changed now
}
```

The rewrite reads its input as `previous.get(db, key)`, and what else it depends on through the database: summary keys,
facts. A stage without a memo of its own (what `IrLineage.settle` did with its outputs) writes them with `begin`/`end`, reading
only its input, which gives the identity and the change revision settling gives. `get` of a key its stage has not computed
or verified in the revision is an error, and to a verification such a key counts as changed. Keys are any dense Int: the
plan keys by function symbol (`IrSymbol` ids), and the columns are sized by the largest key a kind holds, which slice 2
measures against slots (`IrFunctionSlots`, dense per session).

**`QuerySummary`** (Whole-program steps, above): `open`, `contribute(db, contributor, keys)`, `close`; `has(db, key)` and
`keys(db)` after `close`. Reading while open and giving a contributor twice in a run are errors; a run a stopped build left
open is started again. `--check-reuse` counts the keys again from the contributions at `close`. Today's contribution memos
(`summarize`, `IrContributionMemo` per version) map onto a computed kind per contribution whose arrays feed a summary; a
whole-program step's state, which `prepare` computes now and `fact` answers from, becomes reads of summary keys, so a rewrite
records the keys it depends on instead of a fact print.

Design decisions:

- **Equality, not a digest by computation**, which `QueryKind.computed` did and which is gone with `QueryKindBase.feedDigest`:
  it gave readers no cutoff, and IR functions are too large to digest by content (Digests, above).
- **Columns and one pool of reads.** A memo is columns by key (value, verified, changed, computed revisions, where its reads
  start in the kind's Int pool, how many), not an object with an array of reads, and the base kind holds the verified and
  changed columns so a verification answers a read of a key verified in the revision inline (`changeIfVerified`). On
  HashLink an element of an `Array<Null<Array<Int>>>` costs about 75 instructions (it is cast on each read) and the call to
  `changedAt` about 20. The pool's garbage (runs a memo replaced) is compacted at a sweep, or when it passes half the pool
  with no verification of the kind under way.
- **No frame, no handler, no allocation on a held key.** A verification marks the key busy, stamped with the revision, which
  catches a cycle through recorded reads; a computation that throws ends the build, whose frames the next build drops and
  whose marks expire with the revision.
- **Rollback drops what was computed after the commit** (Results and transactions, above): found while writing the tests; a
  memo over a recorded result a rollback undid verified against the older revision the undone result took back.
- **Sweep** per kind and from the build's first revision (Lifetime and memory, above).

Measured (main-thread instructions, a synthetic warm build of 25 stages over 8,500 functions, compiled by Haxeon, every key
held): today's `IrFunctionStages.run` with `IrLineage` and `IrStageMemo`, for a stage that leaves every function alone and
reads no fact, costs 421 per function and stage (89.5M a build). The engine costs 226 per key with one read (its input) and
318 with two (its input and a summary key), before the stage driver's own loop. Slice 3 measures its driver against today's;
should the held path cost more, a stage visits only the keys whose reads changed ("Per-access costs and the stage driver", below,
measures both drivers with their loops).

Left for slice 3: helpers by name (`IrStageMemos.helper`) as computed keys of interned names; a summary's contributors per key,
if a step needs which functions name a key and not only whether one does.

### Slice 2 as built

IR generation, the functions the frontend and the assembler generate, the program's objects and what the frontend reads of each
IR function are results in the session's database (`SessionState`), each keyed by the symbol of a name (`IrSymbol`):

| Kind | Holds | Made by | Reads |
|---|---|---|---|
| `irGeneration` | every function the assembly starts from | the generator (`publishFunctions`, `generatePendingIr`); `IrLineage.start` puts the assembler's own | a printer its object, a boot function its inputs |
| `irObjects` | each object of the typed program | `publishObjects` | — |
| `initializerInputs` | the typed fields each boot function (probe, method binding, part) is made from | `bootFunction`, for `IrProgramAssembler.staticInitializersFrom` | — |
| `irTypeMentions`, `irCalls`, `staticReferences` | what `retainedFromPrevious`, the helper retention and the static initialization order read of a function | computed on demand | the function in `irGeneration` |

Deleted: `IrFunctionVersions` with `ModuleState.irVersions`, `SessionState.irVersions`, `IrPipelineContext.generatedVersion` and
the callback that read them; the INPUT stage memo of `IrLineage.start`, which settled the assembler's functions by equality;
`IrGeneratedFunctions` with `SessionState.structurePrinters`, `initializerFunctions` and `keepStructureObjects`;
`canonicalObjectCache`; the search for the module that held a helper before; the frontend's three `IrFunctionMemo` users and
their per-build swaps. Lines in `src/`: 437 deleted and 527 added, against the estimated −450 / +250. Of the added, 91 are the
engine's (below), about 100 the assembly order (below, not in the plan), and the rest the kinds' declarations and the two
results computed with their reads (`structurePrinter`, `bootFunction`), which the estimate left out.

Engine additions: `ComputedQueryKind.put` (a value a stage makes from what it is given, reading nothing through the database:
the kept one when `same`, so an equal value is the same object downstream), `kept` (the memo's value, brought up to date or
not), `clear` (a compile that keeps no session lets the memos go with the IR, `SessionState.releaseGeneratedIr`),
`QueryDatabase.advance` and `QueryRead.extend`. The sweep runs when a build is taken (`Compiler.adoptCandidate`).

Design changes from the plan, with the reasons:

- **Keys are symbols, not slots.** A self-compile interns 21,974 symbols for the 9,705 functions it generates, so a kind's
  columns (about 36 bytes a key) take about 1.2 MB, against 0.5 MB by slot; with their values the kinds add about 2.8 MB to a
  self-compile's live tables (`live_bytes_tables`, +1.2%). A slot is given to another name once freed, which would make every
  kind drop the keys the lineage frees; a symbol is never given again, and slice 3's stages key by symbols too.
- **`IrLineage.start` stays, reduced.** It puts the input into `irGeneration` and numbers each function by identity: a version
  names one object, and an equal function is now the same object. The cells and versions go with the lineage in slice 3. Its
  cost (settling the frontend's functions by equality) had already gone with `IrGeneratedFunctions` (240ee8a5c).
- **The object set stays state.** `objectCache` also held the objects an earlier build made for a function it typed (closure
  environments), which a function not typed again still names: a set a candidate copies and a rejected build must not change, so
  it stays, as `SessionState.objects`. What was a cache in it, an equal object being the one kept, is `irObjects`, now for every
  object and not only structures. `canonicalObjectCache` was remade from the typed classes every build: it is the build's.
- **`__init` is made every build** and put, so one made the same is last build's. It is made from names alone, which
  `IrGeneratedFunctions` joined into its key; interning such a key would grow the symbol table with every change to the
  initialization order.
- **A put of a key read in the revision starts a revision of its own** (`advance`; not an input's revision, which would make the
  next build miss the no-op result): `retainedFromPrevious` reads functions before typing, which the generator may then change.
- **`regenerated` stays relative to the state the build started from**: the module's own IR, or the database's for a helper
  another module held. The list of changed functions is against what was published.
- **Identity is checked typed, at the caller.** An `==` on the kind's type parameter is a dynamic comparison (it cost 2.4% of a
  body edit inside `put`), so `put` compares with `same` only, and the frontend's readers, which put the module's function
  before reading what it contributes, first check `kept(key) == fn` themselves (`FrontendCompilation.generated`,
  `IrLineage.start`). Even so a contribution read through the engine costs more than the `IrFunctionMemo` lookup it replaced:
  the generic code's closures for `same` and the casts of its columns. Since made concrete ("Per-access costs and the stage
  driver", below): the kind is `@:generic`, and `put` checks identity itself.
- **The order of the assembly's input is a result** (`AssemblyOrder`): sorting the names of all functions every build was most
  of collecting them, about 1.9% of a body edit, and the order is a function of the names alone. It is kept and taken while the
  program has the same names, checked by symbol id; a name two modules hold (a helper the module that asked for it first held
  before, about 20 of them warm) is the owner's copy, as before. This was not in the plan; it pays for the engine's overhead
  above.
- **A kind that gained no memo since its last sweep is not swept**: it holds no more than that sweep left, and no-op and body
  edits add no key, so they scan nothing.
- **The engine runs under the Haxe interpreter too** (`haxe --run` in the HXI tests), whose `resize` fills an `Array<Int>` with
  null: the columns are lengthened with zeros (`QueryRead.extend`).

Measured with perf-guard on one machine against origin/main (main-thread instructions of the compile server, and the
self-compile): the no-op rebuild 0.834G → 0.804G (−3.7%), the body edit 2.328G → 2.296G (−1.3%), the signature edit 18.37G →
18.34G (−0.1%); allocation of the no-op 85.0 → 82.1 MB and of the body edit 242.6 → 239.6 MB; the server's live data 787.0 →
788.2 MB. The self-compile: 50.46G → 50.50G instructions (+0.1%), live tables 243.4 → 246.2 MB (the kinds' columns, released
with the IR before the passes), live IR 237.8 → 237.6 MB, backend 267.0 → 266.7 MB. Without the assembly order the body edit was
+0.2% and the no-op +0.7%; the blank-line edit is not measured by perf-guard.

### Per-access costs and the stage driver

Before slice 3 moves the per-function stages, the engine's accesses were measured where a stage meets them, in code Haxeon
compiles (`benchmarks/query-stages`: `StageCostMain` and `measure.py`, main-thread instructions counted as perf-guard counts
them). About 9,000 functions go through 25 stages in warm builds, today's driver (`IrFunctionStages.run` with `IrLineage`,
`IrStageMemo` and `IrFacts`, its loops and `IrLineage.start` included) against the engine's (below), in four cases: every
function held, reading only its input; held, each rewrite having read one or three whole-program facts (today an `IrFacts`
fact, on the engine a summary key); and every function rewritten because a fact it read changed, to a function equal to the one
kept (early cutoff). Instructions per function and stage of a warm build:

| Case | Today's driver | Engine, slice 2 | Engine now |
|---|---|---|---|
| held, no facts | 376 | 396 | 240 |
| held, 1 fact | 483 | 1,139 | 413 |
| held, 3 facts | 555 | 1,323 | 537 |
| cutoff | 2,987 | 4,476 | 2,421 |

The slice-2 column keeps each contribution as slice 1 planned, a computed memo per function verified and then given. Per access,
in instructions per key (the first row is the loop the others are measured beyond):

| Access | Slice 2 | Now |
|---|---|---|
| new revision, then `put` of the object the key holds | 468 | 92 |
| `current` of a held key reading its input | 354 | 203 |
| `current` of a held key reading its input and a summary key | 446 | 265 |
| `contribute` of the array given last run | 225 | 240 |
| keeping a contribution: its memo's `current` and `contribute` (slice 2), `holds` (now) | 643 | 109 |
| computing a key again to an equal value: `begin`, a read of its input, `end` | 2,367 | 949 |
| `has` in a recording frame | 196 | 123 |

Where it went, from the HashLink code of the compiled engine:

- **The erased kind.** Every `ComputedQueryKind<V>` shared one body with `V` erased: a value was read through the any-array
  accessor (a call) and cast at the caller, `same` was called through an adapter that casts both arguments before calling the
  closure, and `==` on `V` was a dynamic comparison. The kind is `@:generic` now, which Haxeon makes per type argument as Haxe
  does (it took constrained classes only before): values are a typed column, `same` is called directly, and `put` and `end` find
  the object the key holds by identity before calling it. The readers that compared identity themselves to spare the dynamic
  comparison (`FrontendCompilation.generated`, `IrLineage.start`) put directly.
- **Arrays of arrays.** An element of an `Array<Array<Int>>` is checked on each read (`__array_check_cast`, a call). The
  database kept one array of reads per frame, allocated by every computation: the frames are now one stack of Ints, five per
  frame, over one buffer of reads, from which a computed kind copies what a computation read into its pool. A computation
  allocates nothing of the engine's.
- **Summary reads by call.** A read of a summary key went through `changedAt`, a method call per read. A summary is settled
  between its runs (`QueryKindBase.settled`): its change column holds every key's change, which a verification reads inline as it
  reads a key verified in the revision.
- **Marks on every verification.** `current` marked the key busy and counted the kind's verifications (which keep its pool in
  place) for every key. It does so only once a read needs a call: a read answered inline cannot come back to the key.
- **A memo per contribution.** Keeping a held function's contribution cost a verification and a `contribute`, more than the
  rewrite's own memo. A contribution made of the function alone needs no memo: `QuerySummary.holds` keeps it while the stage's
  input for that key has not changed since it was given, two Int columns and an inline read.
- **The recorded kind's walk** (`RecordedQueryKind.latestChange`, the typer's facts) read the reads of the node on top of its path
  from an array of arrays at every step; they are copied into one buffer of Ints as the node is entered.

Profiled on the body edit (the compile server built ahead of time, perf over four edits), the engine took 2.30% of the compile
thread and takes 2.07% now. Its computed kinds, which slice 2's users read (`irGeneration` and `irObjects` put by the frontend,
`irTypeMentions` and `irCalls` read by `retainedFromPrevious` and the helper retention), went from about 1.2% to 0.8%; the casts,
any-array reads and boxing that were about a fifth of their cost are gone, and what is left is `current` and the comparison of
an IR made again equal (`put` calling `IrFunctionStateEquality.same`). The rest is the typer's walk over its facts (1.2%), whose
cost is the walk itself.

On the compiler's own sources (perf-guard, one machine, against origin/main): the no-op rebuild 0.802G → 0.790G instructions
(−1.4%), the body edit 2.309G → 2.282G to 2.297G over two runs (−1.2% to −0.5%), the signature edit 18.31G → 18.22G (−0.5%),
the cold self-compile 50.54G → 50.22G (−0.6%); allocation and live data unchanged. A cold check of the small project on the VM
costs 0.5% more (10.78G → 10.83G): the kind's copies per value type are more code to compile at startup.

**The rule for slice 3.** A stage moves onto the engine only when its held path costs no more than today's, measured in the case
above nearest to its reads per function, and the body edit and no-op do not get slower. A stage whose held path cannot beat
today's (one whose rewrites read many keys) does not verify every key: it visits only the keys whose reads changed, the keys its
input changed in the revision and the readers of the summary keys that changed, and keeps the others as they are. The engine has
neither list yet (per kind the keys changed in a revision, per summary key its readers); they come with the first stage that needs
them.

**The stage driver.** Each stage is a `ComputedQueryKind<IrFunction>` keyed by function symbol, whose input is the stage before's
kind (the first stage's is `irGeneration`):

```
summary.open(db);                                   // a stage with a whole-program step
for (fn in functions)
    if (!summary.holds(db, key(fn), input))           // a contribution made of the function alone
        summary.contribute(db, key(fn), pass.contribution(fn));
summary.close(db);
for (index in 0...functions.length) {
    var key = key(functions[index]);
    if (kind.current(db, key))
        output[index] = kind.value(key);              // check mode: begin, then check against the rewrite
    else {
        kind.begin(db, key);
        output[index] = kind.end(db, key, pass.rewrite(input.get(db, key), db));
    }
}
```

- What a rewrite reads besides its input is a summary key (`has`) or a key of another kind, read through the database, never a
  string and never a fact print: `prepare`'s whole-program state becomes the summary, `fact` becomes reads of its keys. A
  contribution that reads more than its function is a computed kind of its own, given with `contribute`.
- A rewrite that leaves a function alone returns its input: `end` keeps it by identity, without `same`. One that makes an equal
  function is cut off by `same` (`IrFunctionStateEquality.same`, which `IrLineage.settle` compares today), which gives it the
  kept object and its change revision: the lineage's versions become `changes`.
- The held path calls `current` and `value` and nothing else: no closure, no allocation, no interface, no handler.
- Helpers a rewrite asks for are keys of interned names (slice 1, "Left for slice 3"), added in program order by `finish` as now.
- `--check-reuse` computes every held key again and compares it (`check`), and makes every contribution `holds` kept and
  compares it with the one given.

**Net lines (estimate):** about 5,450 deleted and 2,350 added in `src/`, about 3,100 fewer, plus the test mains of
deleted mechanisms (`IrVerifyMemoMain`, `WarmStageFactsMain`, `StaticNullCheckReuseMain`, `InlinerSession`,
`HlWriterCacheMain`, about 450 lines) rewritten as engine checks of about half that.

### Slice 3 as built (first part)

Every per-function stage runs on the stage driver (`IrFunctionStages.run`), before the encode point and past it, in the assembly
list and the target list: one driver, so the stages past the encode point moved with it.

- **Kinds.** Each stage is an `IrStageQueries`: a `ComputedQueryKind<IrFunction>` of the session's database keyed by the number
  of the function's name, with the version of the function its memo was made from, the stage's summary of it and the helpers its
  rewrite asked for, as columns beside it. A held function costs `current` and `value`, with an Int compare before them and the
  replay of its requests when it asked for any; a function computed again is `begin`, the rewrite, `end`.
- **Facts.** What a rewrite reads besides its function is one kind of the database, `IrStageFacts`: a fact is a stage's space, a
  kind and a key, interned to a dense id once per reader and run; its value is computed by the stage's pass at most once per run
  (`IrFactSource.fact`), and changes when the value does. A rewrite reads it through `IrFactReader.read`, a read of the memo being
  computed, so `current` verifies it inline once the run has computed it. The prints of `IrFacts` are the kind's change revisions.
- **Versions.** A version is the function object's own number (`IrFunction.version`, given when it is made). The lineage gave
  each object one version and never gave a version twice, so the number is what it was; the cells, the slots
  (`IrFunctionSlots`), the shared name index and `settle` are gone. The contribution memos, `lastResult` and the walk records that
  key on versions are unchanged.
- **Settling.** Before the encode point a function made again the same is the object kept: by the stage's `end` (`same`), and,
  after a stage without a memo, by a `put` of each function it made into that stage's kind (`IrStageMemos.settle`); what a stage's
  `finish` added is put the same way. Past the encode point nothing is compared, as before (`IrStageMemos.bodies`).
- **Helpers by name** (`IrStageMemos.helper`, the enum dispatch's boxes, views and unboxes) are a kind put by the helper's name and
  swept with the build.
- **Check mode** computes every held key again in a frame it then drops (`ComputedQueryKind.cancel`) and compares it, its
  summary and its requests.

Design changes from the plan, with the reasons:

- **The input is checked by identity, not read through the previous stage's kind.** Between two per-function stages there are
  stages without a memo (11 before the encode point) that may replace a function; with the input as a read, each of them would
  need a kind holding every function, put every build. The version of the object a memo was made from says the same at the cost
  of one Int compare, and an equal function made again is the kept object, by the cutoff of the stage that made it.
- **A computation of another input is not compared** (`ComputedQueryKind.endChanged`): what a stage makes of another function is
  all but never the one it kept, and comparing it cost a signature edit 4% of its instructions and 17% more allocation (one side
  encoded to compare with the other). Only a function computed again from the same input, because a fact it read changed, is
  compared, as `IrStageMemo` did.
- **Facts as a kind, not as summary keys.** The passes' whole-program steps (`prepare`) stay as they are and their facts are read
  per key; turning each step into contributions is per pass work that the kind does not need for reuse. Summaries come where a
  whole-program memo moves (below).
- **Keys are the numbers of function names** (`IrSymbol.functionKey`), not symbol ids: a self-compile interns about 22,000
  symbols for about 9,700 functions, and the columns of about 40 stage kinds by symbol (with two more columns each than now) held
  38 MB more live data than the memos they replace; by function name, 13 MB. `IrFunctionIndex` indexes by the same numbers, so
  a pass that looks functions up by name makes no table of names (the lineage's shared index is gone).
- **The mapping overstated what this slice deletes.** `IrStageMemo` and `IrFacts` serve the inliner (slice 5), `IrFacts` and
  `IrAnswerSource` also verification (6) and lowering (7); the contribution memos, `lastResult` and `IrWalkRecord` serve the stages
  past the encode point too (4). They stay until those slices; the inliner records its facts through `IrFactRecorder`.

Measured, main-thread instructions per function and stage of a warm build (`benchmarks/query-stages`, 9,000 functions and 25
stages; the driver it replaced built from origin/main, the driver as built from this change, on one machine). The bare engine loop
both builds carry (`engine`) costs 240 and 256 for a held key in the two builds, though its code did not change: about 16 of each
difference below is the build, not the driver.

| Case | Before | Driver | Engine loop, before / after |
|---|---|---|---|
| held, no facts | 373 | 397 | 240 / 256 |
| held, 1 fact | 479 | 505 | 413 / 438 |
| held, 3 facts | 552 | 654 | 537 / 572 |
| cutoff | 2,984 | 2,584 | 2,421 / 2,486 |

So the held path meets the cost rule within the build's variance with up to one fact, and not with three: each fact read is a read
of the verification loop (about 75 instructions, against 36 for a print compared). The stages read a fact for some functions, not
three for each, and on the compiler's own sources the edits do not get slower (perf-guard, one machine, against origin/main): the
no-op rebuild 0.794G → 0.794G instructions, the body edit 2.286G → 2.270G (−0.7%), the signature edit 18.22G → 18.31G (+0.5%);
allocation of the body edit 237.9 → 234.3 MB, of the signature edit 992 → 1,013 MB; the server's live data 785 → 797 MB. The
self-compile is byte-identical, warm builds equal fresh ones with and without `--check-reuse`, the edit replay and the test
driver pass.

Lines in `src/`: 1,121 deleted and 1,163 added, about 180 of each a rename (`lineage` to `stageMemos`); the deleted mechanism is
about 700 lines (`IrLineage`, `IrFunctionSlots`, the stage memo paths of `IrFunctionStages`, `IrStage` and `IrFactReader`, the
shared name index), the added engine code about 650 (`IrStageFacts`, `IrStageQueries`, the driver, `IrFactRecorder`).

**Left for slice 3**, the whole-program memos of the stages before the encode point, each a summary over per-function
contributions with the stage's facts read as its keys (est. −450 / +250):

- the walks of `dispatch-walk` and `entry-prune` (`IrTypeAwareWalk.runKept`, `referenced`, `IrWalkRecord`, the `SUMMARIES`
  contribution memo), about 200 lines;
- the enum dispatch's kept encodings and escape reach (`IrEnumDynamicDispatch.ENCODINGS`, `IrEnumEscapeReach`), about 120;
- the per-function contribution memos read before the encode point (`IrGenericOwnerErasure` and `IrTypedInterfaceDispatch`
  `REQUESTS`, `IrEnumRuntimeSpecializations.MENTIONS`, `IrInlineEnumEligibility.USES`), about 100;
- the held path of a rewrite that read several facts, which the cost rule does not let cost more than the prints did: a stage
  then visits only the keys whose reads changed, with per fact the keys that read it and per run the facts that changed (the
  engine has neither list yet; est. +150 in `IrStageFacts` and the driver).

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

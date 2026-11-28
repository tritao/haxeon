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
The prune's walk is the first such step that plain and live builds share ([LIVE_PRUNING.md](LIVE_PRUNING.md)).

Fixpoint passes (`IrScalarArguments`, `IrNullableScalarFlow`, `IrOptionalScalarFlow`) record their candidacy reads as
engine reads. An edit re-decides the changed functions and the readers of any candidacy that flips (ADR 0003 decision 4).

The frontend's purity fixpoint is kept outside the engine, with reverse edges of its own (`ProgramPurity`). The engine
verifies a memo by walking its reads, so finding the few results that read a change still visits every result; a greatest
fixpoint over cycles is not a memo's value either, since the engine takes results that read each other as one component
that changed together. So the session keeps what each walked function depends on with the reverse of those edges, the facts
log their changes (`DeclarationFacts.changesSince`), and a Bloom filter per module (`ReadFilter`) finds the functions that
read a change. The unit invalidation finds the units to check the same way (`DeclarationFacts.unitsReading`).

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
     purity inference's walks (`ProgramPurity`) record in the engine's frames, and a unit's reads, the facts' dependencies and
     the kind rule are verified by the engine's walk. Unit records stayed in `ModuleState.unitReads` until 3b, so a rejected
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
   - **3e: the typer's per-build state as results** (accepted, [TYPER_STATE.md](TYPER_STATE.md)): the registries and key
     maps `TypingSession` rebuilds every build as summaries over per-unit contributions; the no-op floor's typer part.
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
| `IrStageMemo`, `IrStageMemos`, `IrStageEntry` | 526 (the file, with `IrLineage` and the contribution memos) | stage and function slot; input version, fact reads, output, summary, helper requests; dropped when the stage's last run did not use it | `IrFunctionStages.run`, the ~25 `IrFunctionPass` stages | a computed kind per stage, keyed by function symbol; done for every per-function stage (slice 3) and the inliner (slice 5) |
| ~~`IrLineage`, `IrFunctionSlots`~~ | (above), 95 | slot → function object and version; a version is never given twice; slots swept when cells exceed twice the functions | every stage (`settle`, `versionOf`), `IrStage` | done (slice 3): a version is the function object's own number (`IrFunction.version`), settling is early cutoff in the stages' kinds |
| ~~`IrFacts`, `IrFactReader`, `IrAnswerSource`~~ | 275, 85 | space, kind, key text → value or answer, and a print; dropped when unread a build | passes, `IrVerifyMemo`, `HlLoweringView` | derived kinds digested by value (the prints are digests); the passes' facts are done (slice 3: `IrStageFacts`, `IrFactReader` reads it), the inliner's (slice 5); verification's (slice 6); lowering's (slice 7), with which `IrFacts` and `IrAnswerSource` went |
| Contribution memos, `lastResult`/`keepResult`, kept helpers (in `IrStageMemos.hx`) | (above) | function version → contribution; whole-program results checked by `holds`; helpers by name for one build | ~12 passes (`IrClosedEnumTagAbi.ESCAPES`, `IrScalarArguments.CLOSURE_NAMES`, ...) | contribution queries, summary queries over them, helpers as derived queries by name; helpers done (slice 3, a kind put by name), the requests and enum mentions done (summaries, slice 3), the walk summaries done (`IrWalkMemo`), the enum dispatch's encodings a kind by type id; `lastResult` and the memos the choices and escape reaches read done (slice 4, steps); the inliner's done (slice 5: its call edges a step's summaries, its forms a kind); the array types and the value array lane check done ("The value array rewrite as built"); left: the runtime needs, closure uses, initialization calls and stores (4), the verifier's (6) |
| `IrWalkRecord` with `IrWalkSummary`, `IrBodyEdges` comparison | 209 | copies of six program tables, given inputs, read functions and their summaries; one per walk | `IrTypeAwareWalk.runKept`, `IrEntryPrune`, `IrEnumEscapeReach`, `IrScalarArguments`, `IrNullableScalarFlow`, `HlPlainBuild.reachable` | a kind per walk (`IrWalkMemo`); done for the walks before the encode point (slice 3), past it (slice 4, steps) and the plain build's (slice 6); the record is gone |
| Reuse code inside passes | ~750 lines naming the above in 49 files; est. 1,000–1,400 with the code around them | — | — | query declarations (est. a third of it); fact reads stay as engine reads |
| ~~`IrGeneratedFunctions` (structure printers, initializers)~~ | 95 | key and identity of the input objects; swept when untouched | `FrontendCompilation`, `IrProgramAssembler` | done (slice 2): results in the generation kind with their reads |
| ~~`objectCache`, `canonicalObjectCache` (`SessionState`)~~ | ~40 in `FrontendCompilation` | class name; while the declaration is unchanged | frontend, walks' table copies | done (slice 2): objects by name in a computed kind, one made the same is last build's; the object set stays state (below) |
| ~~`IrFunctionMemo` and its users: `irTypeMentions`, `irCalls`, `staticReferences`, `HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo`~~ | 46; 41 (`HlFunctionSummaries`), ~12, ~25 | `IrFunction` identity; one build past last use | frontend, `StaticInitializationOrder`, `RuntimeAbi`, `IrReachability`, `HlLower`, `IrNonNullFields` | contribution queries; the frontend's three are (slice 2), the backend's (slice 6: `IrFunctionValues`, `HlFunctionQueries`) |
| `IrSourceRehash`, `irSources` | 130 | function → file hashes its locations name | frontend | gone with relative positions (the hash is added at encode), else a derived query |
| ~~`IrVerifyMemo`~~ | 190 | function name → function and answer facts | `IrVerifier` | computed query per function; done (slice 6: a stage of the driver, `IrVerifyStage`) |
| `IrInlineCache` and the inliner's memo plumbing | ~170, ~100 | name → original body, instrumented form, published form, object facts, positional prints; maps replaced per run | `IrInliner`, `Compiler` (published) | inlined form per function; done (slice 5: a kind of forms, the components a step, the original bodies gone); `published`, the instrumented forms and the positional prints stay, live state |
| `PipelineSnapshot` | 157 | tables' encoding, functions' identity, environment text; last plain build | `CompilationPipeline`, backends | the root query (final IR, module); done (slice 7): the tables and program facts compared by their parts, not encoded, the encodings kept as `--check-reuse`'s check; stays a value of the state, which a rollback returns to ("Slice 7 as built") |
| ~~`HlLoweredCache`, `HlLoweredFunction`, `HlLoweringView` facts~~ | 83, 45, 162 | name and lowering environment; the build's entries; facts never swept | `HlLower` | computed query per function: relocatable code, reading object facts as engine reads; done (slice 7: `HlFunctionQueries.lowered`) |
| Link and replay: `HlRequestKeys`, `HlRequestAnswers`, `HlSymbolRequest`, `HlLink`, `HlLinkRecord`/`HlKeptTables`, parts of `HlSymbolTable` and `HlLower` | 196, 66, 102, 120, 251, ~150, ~290 | request numbers (grow only); last build's tables with each position's first requests | `HlLower` | module sections ([MODULE_SECTIONS.md](MODULE_SECTIONS.md)) |
| `HlDebugMetadataCache`, `HlWriterCache` | — | — | — | deleted with the dense build path (MODULE_SECTIONS.md, slice 4d); the section memo (`HlSectionCache`) keeps the validation marks (`HlValidationMarks`) |
| ~~Wasm module reuse (`WasmBackendSession.encoded`)~~ | ~30 of 181 | identity of the final IR and options | Wasm backend | the root query; deleted (slice 7): the pipeline's reuse of the module already covered it |
| **Stays:** `HlModuleAssembler`, `HlFunctionCache`, `HlSymbolTable`'s published prefix, `hl/persistence`, Wasm `patchState` | 1,041, 286, —, 933 | published slots | live patching | not caches: the running module's state, an input to the next patch; the loader mints stable ids (MODULE_SECTIONS.md, slice 4d), and these shrink further to the semantic baseline (MODULE_SECTIONS.md, 4) |
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
| 3 | Assembly stages before the encode point; **done** (below, two parts): the stage driver for every per-function stage, facts as a kind, the lineage gone; held keys visited only when their facts changed; the walks, requests and mentions before the encode point on the engine | −2,000 / +500; first part built −~700 / +~650 (below) | `IrStageMemo`, `IrLineage`, `IrFacts`, `IrFactReader`, `IrFunctionSlots`, `IrWalkRecord`, contribution memos, memo paths of `IrFunctionStages` and `IrStage`; first part: `IrLineage`, `IrFunctionSlots`, the stage memos of the per-function stages, the memo paths of `IrFunctionStages` and `IrStage` | 0.05 / 0.4 / 0.05; first part: body edit −0.7%, no-op 0, signature edit +0.5% | 2 |
| 4 | Stages after the encode point, then the fixpoints (candidacy reads, ADR 0003 decision 4); two parts built (below) | −400 / +250; built −401 / +508 and −53 / +257 | their whole-program rereads | 0.2 / 1.2 / 0.2; built 0.11 / 0 / not measured and 0.02 / 0.39 / not measured | 3 |
| 5 | Inliner; **done** (below) | −300 / +150; built −739 / +545 | `IrInlineCache` except `published`, inliner memo | 0.05 / 1.2 / rest after A; built 0.06 / 0.06 / not measured | 4 |
| 6 | Verification and final-IR summaries; **done** (below) | −450 / +100; built −754 / +861 | `IrVerifyMemo`, `IrFunctionMemo`, `HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo`, plain-build reach record | 0.1 / 0.3 / 0.05; built 0.04 / 0.06 / not measured | 5 |
| 7 | Lowering, debug metadata and encoding as queries; root query; **done** (below): lowering, Wasm module reuse, then the root query after typer piece 4 | −850 / +300; built −519 / +373 | `HlLoweredCache`, `HlLoweredFunction`, `HlLoweringView` facts, `HlDebugMetadataCache`, `HlWriterCache` encodings, `PipelineSnapshot`, Wasm module reuse | small; no-op must stay at 0.29 s; built 0 / 0 / not measured, no-op 0, body edit allocation −1.5% | B, 6 |

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
  object and not only structures. (The set went later: each function keeps the objects it made in its module, and the program's
  objects are its owners', [TYPER_STATE.md](TYPER_STATE.md), "Objects by owner".) `canonicalObjectCache` was remade from the typed classes every build: it is the build's.
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
input changed in the revision and the readers of the summary keys that changed, and keeps the others as they are. Every stage
does so for its facts since slice 3 (the second part, below: per fact its readers, per run the facts that changed).

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
- **Parts.** A stage that runs once per part of the program (the value array rewrite and scalar lowering, once per element type)
  is one kind, each part's functions keyed apart (`IrStageQueries.part`, `partKey`): a database holds at most 256 kinds, and a kind
  per element type let a program with many element types fail to compile (`ManyValueArrayElementsMain`, 300 of them). What the
  stages derive, what their `finish` adds and what the stages without a memo make are one kind each the same way (`ir-derived`,
  `ir-derived-bodies`, `ir-added`, `ir-settled`), each stage a part: they hold few functions, and a kind per stage had columns as
  long as the program's.
- **Helpers by name** (`IrStageMemos.helper`, the enum dispatch's boxes, views and unboxes) are a kind put by the helper's name and
  swept with the build; it keeps a helper as made, without comparing it (whether one made again is the same is settled where the
  stage adds it).
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
no-op rebuild 0.794G → 0.795G instructions, the body edit 2.286G → 2.273G (−0.6%), the signature edit 18.26G → 18.35G (+0.5%);
allocation of the body edit 237.8 → 234.4 MB, of the signature edit 992 → 1,013 MB (+2%, in the two stages whose `finish` adds
about 200 helpers on that edit, each compared with what the stage added last build; not yet traced further); the server's live
data 785 → 791 MB. The
self-compile is byte-identical, warm builds equal fresh ones with and without `--check-reuse`, the edit replay and the test
driver pass.

Lines in `src/`: 1,121 deleted and 1,163 added, about 180 of each a rename (`lineage` to `stageMemos`); the deleted mechanism is
about 700 lines (`IrLineage`, `IrFunctionSlots`, the stage memo paths of `IrFunctionStages`, `IrStage` and `IrFactReader`, the
shared name index), the added engine code about 650 (`IrStageFacts`, `IrStageQueries`, the driver, `IrFactRecorder`).

### Slice 3 as built (second part)

The whole-program memos of the stages before the encode point, and the held path of a rewrite that read several facts.

- **Visiting only the keys whose facts changed.** `IrStageFacts` keeps, per fact, the keys of its stage's kind whose memos read it
  (an edge list per fact, recorded from a memo's reads when it is computed, `IrStageQueries.readersOf`). A run brings the facts its
  memos read up to date before its loop and marks the readers of those that changed (`markReaders`); a key made from the same
  function, whose memo was verified in the stage's last run and is not marked, is taken as verified (`ComputedQueryKind.hold`)
  without reading its reads. A memo that read anything but facts is always verified. A changed fact's list is dropped as its
  readers are marked, the readers computed again give it again, and the lists are compacted (without repeats or keys whose memo
  is gone) once they outgrow what they held. `--check-reuse` still computes every held key again.
- **Requests and mentions as summaries.** What the erasure and the method references (erasure requests), the typed interface
  dispatch (interface requests) and the enum runtime specializations (enum mentions) read of every function is a `QuerySummary`
  (`IrContributionSummary`): a function contributes the items it names, each interned to a key by its text, and keeps its
  contribution while it is the same object (`QuerySummary.holdsFrom`, by `IrFunction.version`); the step reads the items some
  function names. The interface dispatch and the enum mentions also run past the encode point; each place has a summary of its
  own, so both moved.
- **Walks as kinds.** The dispatch walk, the entry prune's walk, the enum dispatch's dropped equalities and escape reach and the
  tag lowering's called equalities are each an `IrWalkMemo`: what the walk reads is settled once per build into change revisions
  (key 0: what its caller gives it, the program's tables, `IrWalkTables`, and its functions' names, order and declarations; a key
  per function for its edges, `IrWalkSummary`, compared only where the function is not the object it was), and the memo of its
  result holds while none of the keys its walk read changed since it was verified. Walks at different places share the summary of
  a function they are given as the same object, as the summary memo by version did (a summary per walk held 28 MB more).
  `--check-reuse` walks a held memo again and compares, and reads each summary a walk reads again from its function: the edit
  replay found a walk that took its own summary of the function it held for the one it was given, which a walk done again
  did not show.
- **The enum dispatch's helper names** by type (`ENCODINGS`, a whole-program result) are a kind by type id
  (`IrStageMemos.typeEncoding`), swept with the build.

Design changes from the plan, with the reasons:

- **A walk's memo is not a computed kind.** Its reads are keys of its own kind, verified against that kind's change column, not
  recorded in a database frame: the walk is the kind's only reader, its result types differ per walk (a `@:generic` kind per
  result type would be three more copies of the kind's code), and the reads it records (one per function it follows) need no
  frame.
- **Declarations are one key, not a key per function.** A walk reads every function's declaration and the set and order of the
  functions, so any of them changing changes its result in general; a key per function would cost a read per function at every
  verification for nothing.
- **The mapping was wrong about `IrInlineEnumEligibility.USES`**: it is read by the inline enum lowering, past the encode point,
  and stays with the stages there (slice 4). `IrEnumEscapeReach.STORES` (the closures and map stores a reach is given) stays too:
  the reaches past the encode point read it, and the one before reads its logs as given inputs.
- **`IrWalkRecord` stays** for the walks past the encode point (`IrScalarArguments`, `IrNullableScalarFlow`,
  `IrClosedEnumTagAbi`, `IrInlineEnumEligibility`) and `HlPlainBuild`; its table copies and declaration comparison moved into
  `IrWalkTables`, which both use.

Found on the way: the driver's settling of what a stage's `finish` added (the `ir-added` put) told the added functions from the
stage's own by their place in the list, but the enum dispatch and the tag lowering drop functions in `finish`, which moves the
rest: each function rewritten in the build after the first one dropped was compared with what was put last build, frozen by then,
which encoded it. That was the signature edit's 2% more allocation of the first part (in those two stages, 22 and 16 MB against 5
and 7); a function is now the stage's own when its kind holds it for its name (`IrStageQueries.keeps`).

Measured, the stage benchmark (instructions per function and stage of a warm build, one machine):

| Case | Before the stage driver | First part | Now | Engine loop |
|---|---|---|---|---|
| held, no facts | 373 | 392 | 360 | 240 |
| held, 1 fact | 479 | 492 | 393 | 413 |
| held, 3 facts | 552 | 628 | 394 | 537 |
| cutoff | 2,984 | 2,543 | 2,949 | 2,422 |

(The first column is the first part's measurement, "Slice 3 as built (first part)"; the others are this machine's builds of the first
part and of this one.) A held key now costs the same whatever it read, below the bare engine loop that verifies each read.

The cutoff case pays for recording each computed key's readers again. On the compiler's own sources (perf-guard, one machine,
against origin/main): the no-op rebuild 0.80G → 0.78G instructions, the body edit 2.28G → 2.23G (−2.2%), the signature edit
18.36G → 18.33G (−0.2%; 18.20G before the walks moved, which read the summaries of the functions that changed at each walk);
allocation of the signature edit 1,013 → 1,002 MB; the server's live data 754 → 761 MB (the facts'
readers and the walks' columns). The self-compile is byte-identical, warm builds equal fresh ones with and without
`--check-reuse`, the edit replay and the test driver pass.

Lines in `src/`: 433 deleted and 905 added, of which about 110 moved (the table comparison, from `IrWalkRecord` to
`IrWalkTables`), against the estimated −450 / +250 and +150: the visiting is about 180 lines, the summaries about 100 with their
interning, the walks' kind about 200. Less was deleted than estimated because the walks past the encode point keep the record,
the contribution memos and `lastResult` (slice 4), and the moved steps' callers still build what the walks are given. What the moved memos left behind (`IrContributionMemo`, `lastResult`, `IrWalkRecord`, the
remaining contribution keys) serves the stages past the encode point and goes with slice 4.

### Slice 4 as built (first part)

The whole-program steps past the encode point that chose from what every function gives them, and the escape reaches, are steps of
the session's database: the kind of the walks (`IrWalkMemo`), whose summary of a function is now a type of the step's own (`S`,
compared by the step's `same`). The edge walks share `IrWalkSummary` as before (`IrStageMemos.walk`); a step reads a summary of its
own (`IrStageMemos.step`), read again only of a function that is not the object it was, and its result holds while none of the
keys it read changed.

| Step | Its summary of a function |
|---|---|
| the closed tag ABI's choice | what the function lets escape (`IrTagEscapeRecord`), now with the types its kind lets escape |
| the scalar ABI's choice | the function when it may be a candidate, else the functions it takes as closures (`IrScalarChoiceRead`) |
| the nullable scalar flow's choice | the function, read for the functions that may be a candidate |
| the inline enum eligibility | what the function lets escape or keeps in value form (`IrInlineEnumUses`) |
| the enum dispatch's reflection reach (before the encode point) | its closures and map stores |
| the escape reaches of the closed tags and the eligibility | none (walks given their roots) |

Deleted: `IrStageMemos.lastResult` and `keepResult`; the contribution memos `ESCAPES`, `STORES`, `CLOSURE_NAMES` and `USES`; the
`IrWalkRecord` paths of every step but the plain build's reach.

Design changes from the plan, with the reasons:

- **A step is the walks' kind, not a kind of its own.** A choice reads each function's declaration and a summary of it as a walk
  does; what differs is the type of the summary, so the kind takes it as a parameter. A summary that is the whole function (a
  possible candidate) is the function object itself, so a function made again counts as changed and `--check-reuse` still
  compares summaries.
- **The enum dispatch's reach reads every function's stores.** It read only the functions its summaries marked as making a closure
  or storing into a map, which are exactly those whose stores are not empty, so the marker flag goes.
- **What the walks compare of an object** (`IrObjectTools.sameShape`) now includes native layouts and scalar storage, which the
  eligibility's layouts read.
- **Not a lever of reuse:** whether an enum's payload reaches a native layout walked every path of every enum at each use; it is
  now a fixpoint over the declarations, found once per eligibility (most of the eligibility's cost on the signature edit).

Found on the way, by the edit replay: a generic method's specialization that only a deleted function called stayed in a warm
build (the specializations kept are worked out from the units' records before the prune drops a removed function's record), while a
fresh build did not make it; a source function its module no longer declares is no root of them now.

Measured on the compiler's own sources (perf-guard, one machine, against origin/main): the no-op rebuild 0.780G → 0.780G
instructions, the body edit 2.232G → 2.121G (−5.0%; the inline enum lowering 33 → 7 ms), the signature edit 18.31G → 18.32G;
allocation of the body edit 233 → 221 MB, of the signature edit 1,002 → 999 MB; the server's live data 798 → 799 MB. The stage
benchmark is unchanged (its driver is not touched). The self-compile is byte-identical, warm builds equal fresh ones with and
without `--check-reuse`, the edit replay and the test driver pass.

The signature edit does not move: every step reads the declarations as one key, which such an edit changes, so each decides again;
what the native payload fixpoint saved went to deciding again what the held body edit now skips. On it, the eligibility's layouts
(`IrInlineEnumLayout.shape`, the lane layouts of each enum) are about 2% of the edit, and are a function of the enums and value
objects alone.

Left for slice 4: the contribution memos the runtime needs, the array types, the closure uses and the initialization calls and
stores read (each a whole-program step past the encode point whose result also rewrites functions or sets the pass's state), the
verifier's (slice 6) and the inliner's (slice 5), so `IrContributionMemo` stays; `IrWalkRecord` for the plain build's reach
(`HlPlainBuild`, slice 6, beside module sections); the fixpoints' candidacy reads (an edit deciding again only the changed
functions and the readers of a candidacy that flips) and a key per declaration, without which a signature edit decides every step
again.

### Slice 4 as built (second part)

What the walks and steps read of each function's declaration, and the inline enum layouts.

- **A key per signature.** A walk's or step's kind (`IrWalkMemo`) keeps in key 0 what every walk reads of every function, its
  place, retention and provider row (`IrWalkTables.sameRole`), and gives the function whose name's number is `k` two keys: its
  summary (`2k + 1`) and its signature, the types of its arguments and result (`2k + 2`, `IrWalkTables.sameSignature`), read where
  a walk reads them (`IrWalkMemo.signature`): the type-aware walk's roots, the method signatures an escape reach follows, the host
  signatures and callee arguments the closed tag choice reads, and the method and host signatures the inline enum eligibility
  reads. An edit of a signature alone decides again only the walks and steps that read it.
- **The nullable scalar choice reads of every function whether it may be a candidate** (`IrNullableCandidateRead`). It read the
  functions the stage's summaries named, which their signatures decide; with the signature out of key 0, a function that became a
  candidate would not have been read.
- **The inline enum lanes are a kind** (`IrStageMemos.inlineEnumLanes`, one per layout configuration, keyed by the enum's type
  id): an enum's cases laid out (`IrValueLaneLayout.shape`) with the objects the layout consulted by name
  (`IrObjectTable.consulted`), taken while the enum has as many cases and each name gives an object of the same shape, or none, as
  then (`IrInlineEnumLanes.holds`). The planner's cheap part (the case objects, payload copies and nested shapes) is made as
  before, so what it adds to the program is the same; the lowering's planner after the eligibility takes the lanes the
  eligibility laid out in the same build. `--check-reuse` lays them out again and compares.

Design changes from the plan, with the reasons:

- **Retention and provider rows stay one key.** The type-aware walk indexes every function's provider row and the reference walks
  mark every function that is not only reachable, so a key per function for them would be a read of every function by every walk.
- **The fixpoints' candidacy reads are not split yet.** Once the walks hold and the lanes are kept, what the choices still decide
  again on the signature edit is small: the inline enum eligibility (it reads every method's signature, the edited constructor's
  among them) about 0.4% of the edit, the closed tag choice 0.1%, the nullable scalar choice under 0.1%; the scalar ABI choice
  now holds. Deciding again only a changed function and the readers of a candidacy that flips would save at most that, against
  a fixpoint per pass whose removal order and side outputs (the nullable flow's helpers) must stay those of a cold build.
- **The contribution memos stay** (the runtime needs, array types, closure uses, initialization calls and stores, ~40–80 lines
  each): they are per function version already, so on the signature edit their cost is reading the changed functions, about 0.2%
  each at most; `IrContributionMemo` also serves the inliner (slice 5) and the verifier (6).

Measured, the signature edit's main thread sampled (perf over the compile server built ahead of time, one machine), inclusive
shares before and after:

| Step | Before | After |
|---|---|---|
| the type-aware walks walked again (dispatch walk, entry prune) | 1.71% | held |
| inline enum lowering stage | 2.95% | 1.28% |
| its eligibility (decision and lanes) | 2.52% | 0.80% |
| its lanes (`IrInlineEnumLayout.shape`) | 1.87% | 0.07% |
| scalar ABI choice | 0.26% | 0.07% (held) |
| closed tag choice | 0.32% | 0.35% |
| nullable scalar choice | 0.10% | 0.10% |
| summaries of the changed functions read by the walks and steps (`IrWalkMemo.settle`) | 1.51% | 1.63% |

On the compiler's own sources (perf-guard, one machine, against origin/main): the signature edit 18.36G → 17.97G instructions
(−2.1%), the body edit 2.142G → 2.126G (−0.7%; the lowering's planner takes kept lanes), the no-op rebuild 0.785G → 0.782G;
allocation of the signature edit 991 → 958 MB; the server's live data 799 → 802 MB (the kept lanes and the walks' second key per
function). The stage benchmark is unchanged (its driver is not touched). The self-compile is byte-identical, warm builds equal
fresh ones with and without `--check-reuse`, the edit replay and the test driver pass.

Left for slice 4: the fixpoints' candidacy reads and the contribution memos above, should a later profile make them worth it.

### Columns by slot

The engine's per-key columns cost what the kinds hold, not the key space (slices 3 and 4 had added about 18 MB to the live data of
a UI app's compile server, columns of about 40 stage kinds as long as the numbers of function names, many of them sparse).

- **A slot per key.** A `ComputedQueryKind` gives a key a slot the first time it is asked for (`slotFor`) and gives it back when
  its memo is dropped: its columns (the value, the revisions it was verified, changed and computed at, where its reads start, its
  key) are by slot, and only the slot is by key. A read of the kind records the slot, so a verification reads a key verified in
  the revision inline as before; a memo that read a key whose slot went to another key reads that key's change, made after it was
  verified, and does not hold. The stage driver looks a function's slot up once per stage and runs on it (`current`, `hold`,
  `value`, `begin`, `end` take slots); a stage reserves its functions' slots before it asks for them, so the columns are as long
  as the functions it runs on. `IrStageQueries`' columns are by the same slots, and those most stages leave empty (summaries,
  visits, requests) stay empty until a slot has one.
- **Fewer columns.** The busy marks are gone: a key being computed or verified is one with a frame on the database's stack (a
  verification that needs a call enters one, as `QueryKind`'s does). A memo's reads are one run in the pool after their count,
  and a memo that read nothing points at the empty run. A walk keeps one mark per function for the reads it records, and tells
  the functions the program lost from the old and new orders, not from a stamp per function.
- **Shared kinds in maps.** The kinds of the few functions each stage derives, adds or settles (`ir-derived`, `ir-added`,
  `ir-settled`) key a stage's functions by a map (`IrStageQueries.sharedKey`), not by an array as long as the names.
- **One empty contribution.** A function that names nothing contributes the summary's one empty array.

Not done, with the reasons:

- **The stage kinds keep a slot map, not a shared one.** Their functions are most of the program's, so a map shared by the
  stages would save its 4 bytes per name per stage, at the cost of every stage's columns as long as the union of what they hold
  and slots that no stage can give back alone.
- **Revisions stay Ints.** A session's revisions are not bounded: a narrower column would wrap within a long session. The
  column that tells rollbacks what was computed after a commit stays too: without it, a rollback would drop every memo
  verified since, which is every stage memo of the build a rejected publication undid.

Measured, a heap census of the UI app's live session (perf-guard's growth session, at the last build's write, one machine,
against origin/main): live data 468.8 → 458.0 MB (−10.8 MB), by owner:

| Owner | Before | After |
|---|---|---|
| `ComputedQueryKind<IrFunction>` | 11.5 MB | 9.1 MB |
| `IrStageQueries` | 6.6 MB | 2.8 MB |
| `IrWalkMemo` | 4.9 MB | 3.6 MB |
| `QuerySummary` | 3.4 MB | 1.3 MB |
| the other computed kinds (initializer inputs, static references, calls, type mentions) | 2.0 MB | 1.0 MB |

What is left is about 32 bytes per function and stage kind (the value, four revisions or positions, the key and the input
version) and the walks' columns by function. On the compiler's own sources (perf-guard): the server's live data 802.6 → 790.0 MB,
the no-op rebuild 0.786G → 0.784G instructions, the body edit 2.146G → 2.122G (−1.1%), the signature edit 18.00G → 17.95G; the cold
self-compile allocates 2,659 → 2,604 MB. A cold small-project build allocates 70.95 → 69.32 MB on the VM and 44.53 → 42.62 MB ahead
of time (the columns are reserved once, not grown by half again). The stage benchmark, instructions per function and stage of a
warm build:

| Case | Before | After |
|---|---|---|
| held, no facts | 360 | 354 |
| held, 1 fact | 393 | 385 |
| held, 3 facts | 394 | 385 |
| cutoff | 2,949 | 2,970 |

The cutoff case costs 0.7% more, not traced further (a frame scan in place of the busy column was most of it before it was
inlined). The self-compile is
byte-identical, warm builds equal fresh ones with and without `--check-reuse`, the edit replay and the test driver pass.

### Slice 5 as built

The inliner's memo is a kind of the session's database, and its whole-program walk a step of it.

- **Forms.** What the inliner made of a function is a key of `IrInlineQueries.forms`, a `ComputedQueryKind<IrInlinedForm>` keyed
  by the number of the function's name: the inlined form a caller splices (no body when no caller may), with, as columns by the
  kind's slot, the version of the function the memo was made from (`IrFunction.version`) and the function's cleaned form. A memo
  holds while it was made from the same function object and nothing it read changed. A caller that splices a callee reads the
  callee's key: a callee inlined again to the same form (`IrInlinedForm.same`: neither may be spliced, or both may and their bodies
  are the same) keeps the form kept and the revision it changed at, so its callers hold (early cutoff). This replaces the entries
  (`IrStageMemo`, `IrStageEntry`), the output versions and the memo of forms by output version.
- **What a caller reads of a callee before its form**, its component and whether it may be spliced at all with the parameter types
  a call binds (`IrInlineCallee`), is a kind of its own (`IrInlineQueries.callees`), put for every function each build. As facts by
  name, each was worked out again once per build for every memo verified, its name looked up; the screen of what may be spliced,
  by name and size, is worked out once per source with its calls (`IrCallEdges.candidate`).
- **Facts.** The rest of what an inlining reads is facts of the stage's space of `IrStageFacts`, read as the per-function stages
  read theirs: the settings, the objects it consulted, the sources copy elision read of callees, and, for a form that depends on
  where the walk made it, a fact never the same, so its memo never holds.
- **Verification order.** The inliner brings the callees whose forms a memo read up to date before it verifies the memo
  (`IrInliner.holds`): the verification then reads each of their keys inline, verified or computed in the revision, and a callee
  computed again to the same form holds the caller. The engine never verifies a key of the kind on its own, which would skip the
  version the memo was made from. A memo that read of a function the program no longer has does not hold, and the columns of a memo
  the database dropped (swept, or rolled back) are not read: a function that leaves the program for a build and comes back as the
  same object is inlined again.
- **Components.** The call graph's strongly connected components are a step of the database (`IrWalkMemo`, `inliner-components`)
  whose summary of a function is what its source calls (`IrCallEdges`, compared by its calls alone), kept while the program's
  functions and objects and each function's calls are as they were: where every build walked the call graph and resolved its method
  calls, an edit that changes no call keeps them. A component is named by the lowest number of a name among its members, so the
  functions are numbered in program order and no longer sorted by name. Each function's parameter types are interned once for its
  summary (`IrCallEdges.parameters`). This replaces the memos of call edges and parameters by version.
- **What the cache kept.** `IrInlineCache.originals` (each source's frozen body, kept while the source was the same object) is gone:
  the source keeps its own frozen body. The object facts' values moved to `IrInlineQueries`. The cache keeps what the last
  successful compile published (`published`, `instrumented`) and the frontend's positional prints.
- **Check mode** inlines every held function again in a frame it then drops, and compares what the memo holds: the form a caller
  reads and the cleaned form.

`IrFacts` keeps the answer facts of verification and lowering (slices 6 and 7); what served only the inliner went: `IrFactRecorder`,
prints of values an `IrFactSource` works out, interning and the shared lists of reads.

Design changes from the plan, with the reasons:

- **The plan's saving on the signature edit was already made.** It was estimated when the inliner read 6,111 functions on that edit.
  Since slices 3 and 4 the stages before it give it the objects they kept, and it inlines again the 955 functions whose sources the
  edit changed and 3 callers whose callees' forms changed, before this slice as after (counted per build): a signature edit that
  changes an inlined function already inlined again only its callers. What is left of the inliner on that edit (7% of it) is the
  inlining, forwarding and cleanup of those functions, which reuse does not remove. The slice's gains are the held path and the walk
  of the call graph that every build made.
- **No component query.** The plan made a call cycle one query. Functions of one component never splice each other, so each keeps a
  memo of its own; the components are one step for the program.
- **The input is checked by version, not read**, as the stage driver checks it: the inliner's input is the output of stages without
  a memo, and a kind holding it would be put for every function each build.
- **A form no caller may splice is kept without its body**, also when the build checks its reuse, so `--check-reuse` compares the
  cleaned form, which is what such a memo holds of the function. A memo with the source's body as such a form (an inlining that left
  its source as it was) compared that body as a value: on the signature edit, 552 callers were inlined again for callees whose
  source changed, none of which they could splice.
- **`published` stays in the cache**, with the instrumented forms: it is what the next patch is computed against, live state for
  module sections (slice B) and the root query (7).

Measured, the stage benchmark's inliner case (`benchmarks/query-stages`, instructions per function of a warm build, 9,000 functions,
three splices each; the stage driver's cases are unchanged):

| Case | Before | After |
|---|---|---|
| held | 7,393 | 3,531 |
| cutoff | 52,627 | 47,938 |

On the compiler's own sources (perf-guard, one machine, against origin/main): the body edit 1.952G → 1.890G instructions (−3.2%;
the inliner from 6.2% of the edit's compile thread to 3.2%; the walk of the call graph, now kept, was 2.6%), the signature edit 17.34G
→ 17.28G (−0.4%), the no-op rebuild unchanged (0.755G to 0.767G over runs before, 0.754G to 0.761G after; the inliner does not run
on it); allocation of the body edit 220.4 → 212.2 MB, of the signature edit 968.3 → 961.2 MB; the server's live data 803.7 → 800.9
MB. The UI app's live session (census at the last build's write) 482.8 → 479.8 MB, the small project's 12.06 → 11.95 MB. A cold
small-project build allocates 70.54 → 70.33 MB on the VM and 43.35 → 43.19 MB ahead of time, and costs the same ahead of time
(1.546G → 1.547G instructions) and 0.2% more on the VM (11.25G → 11.27G, the check 10.84G → 10.86G): the two kinds are two more
copies of the kind's code to compile at startup. The self-compile is byte-identical, warm builds equal fresh ones with and without
`--check-reuse`, the edit replay and the test driver pass; the edit replay found the dropped memo's columns above, which a function
leaving the program and coming back now tests (`InlinerSourceIdentityMain`).

Lines in `src/`: 739 deleted and 545 added, against the estimated −300 / +150; about 400 of each are the inliner's own code moved or
rewritten around the new memo. The deleted mechanism is about 450 lines (the entries and their memo, `IrFactRecorder` and the rest of
`IrFacts` that served the inliner, the output versions, the forms', calls' and parameters' memos, the original bodies), the added
engine code about 250 (`IrInlineQueries`, `IrInlineCallee`, the verification order, the components' step).

### The value array rewrite as built

The value array rewrite (`IrValueArrayProgramRewrite`, a target stage) ran each element type's rewrite, its scalar lowering and the
allocation lowering on the stage driver already; what read every function each build were its whole-program parts, outside the
engine:

- the array types each function names, from which the element types are found: a contribution memo by version (`ARRAY_TYPES`);
- the check that no ordinary array operation addresses an array of inline value lanes: a contribution memo by version holding a
  print of the program's value classes, inline enums and reference natives, compared as text for every function
  (`CHECKED_VALUE_ARRAYS`);
- per element type, a map of every function by name for the place methods to specialize from, and a second of their versions;
- per element type, a scan of every function's name for the element's boundary helpers (the scalar lowering);
- the encodings before and after, which marked every function read.

Now:

- **Array types as a summary.** Each function contributes the ids of the types it names that hold an array or an iterator
  (`IrContributionSummary`, `array-types`), kept while it is the same object (`holdsFrom`); the element types are found from the
  ids some function names and the program's tables.
- **The check is part of the allocation lowering.** `IrArrayFactoryPass` checks each function it lowers against the lane tables
  (`IrValueArrayLanes`), which it reads as a fact (their print interned, `IrStageFacts`): a held function is not read, and a change
  of the tables marks every reader. `IrVerifier.verifyValueArraysLowered` stays for a program checked whole.
- **Place methods find their source by name's number** (`IrFunctionIndex` over the rewrite's input), indexed only when a method is
  asked for, and keep the version of the function they specialized (`originVersions`), which their derived memo is made from.
- **The scalar lowering looks among what the element's rewrite generated** for the element's boundary helpers.
- **Encoding reads only a function without a body.**

Deleted: `ARRAY_TYPES` and `CHECKED_VALUE_ARRAYS` with their memos, the index's map of original functions, the map of versions.

Found on the way: the 425 ms the profile gave the stage on the signature edit were mostly not the stage's. That edit's one
collection (about 350 to 390 ms of marking, on the main thread in the measured session) started in the allocation lowering's loop;
the stage's own work on that edit is 30 to 60 ms, nearly all of it on the functions that changed.

Measured, the stage benchmark's value array case (`benchmarks/query-stages`, instructions per function of a warm build, 9,000
functions, a tenth of which allocate and take an array of a value object; `edit` gives a tenth of the others and a tenth of the
array users as equal copies; the stage driver's cases are unchanged):

| Case | Before | After |
|---|---|---|
| held | 2,685 | 1,154 |
| edit | 7,268 | 5,779 |

On the compiler's own sources (perf-guard, one machine, against origin/main): the body edit 1.518G → 1.495G instructions (−1.5%;
the stage 15 → 7 ms, reading 9,448 → 240 functions), the signature edit 16.93G → 16.91G (the stage reads 9,753 → 1,482 functions),
the no-op rebuild unchanged (0.580G); allocation of the body edit 177.0 → 172.9 MB (the stage 7 → 3 MB), of the signature edit
933.6 → 927.8 MB, of the late body edit 196.1 → 191.8 MB; the server's live data 790.9 → 790.2 MB. The UI app's live session
(census at the last build's write) 369.2 → 369.0 MB, the small project's 9.0 → 8.9 MB; a cold small-project build allocates and
costs the same (11.35G → 11.33G instructions on the VM, 1.540G → 1.533G ahead of time). The
self-compile is byte-identical, warm builds equal fresh ones with and without `--check-reuse`, the edit replay and the test driver
pass.

Left, each about 1 ms per element type and build: the resolution of the helpers each element's rewrite generates
(`IrEnumTagLowering.resolveGenerated`, whose escape rewrite indexes the program's functions, objects and adapters) runs on the helpers
made fresh before their derived memos keep last build's; a held helper needs the adapters its resolution added, so skipping it
needs those adapters replayed as requests. And the element's layout and registries are made every build.

### Slice 6 as built

Verification and the HashLink backend's steps over the final IR are on the session's database.

- **Verification is a per-function stage** (`IrVerifyStage`, run by the stage driver, `IrFunctionStages.run`): the check of a
  function is the memo of the stage's kind, and its reads are facts of the verifier's space of `IrStageFacts`, one per table entry
  a check reads (`IrVerifyProgram`: a signature, an object, an interface, an enum, a global, a scalar function, a carrier slot, a
  physical value, a closure cast) and one for what the inline enum check reads besides the function. The program-level checks run in
  full every build (`IrVerifier.prepare`). A fact's value is a number that keeps while its answer is the same part by part as the
  one it was last worked out from, and changes otherwise (`IrVerifyAnswers`, by fact, the session's; `IrFactSource.factOf` gives a
  source the value it had): no text of an answer is made. A held function is taken without reading its facts when none changed
  since the stage's last run, as every stage's is. A compile that keeps no session verifies everything and records nothing.
- **What a step reads of one final function is a kind of the database** (`IrFunctionValues`, by the number of the function's name):
  the ABI text of a function (`RuntimeAbi.describe`), the runtime natives its rows call (`HlLower.discoverRuntimeNatives`), its field
  stores (`IrNonNullFields`), its form with the shared runtime calls (`IrSharedRuntimeCalls`), each held while the function is the
  same object (`IrFunction.version`). Nothing reads such a value through the database, so the kind keeps three columns by key, the
  value, the version and the last revision it was asked for, which its sweep reads; a rollback leaves them, as a value is right for
  its function whichever build made it. The enums a function may need boxed descriptors of are a summary
  (`IrContributionSummary`, `hl-enum-uses`).
- **The runtime ABI's declarations** (objects, interfaces, enums) keep their text while each is the same object
  (`RuntimeAbiTexts`), and a table equal to the last description's is that table, found without building a map.
- **The plain build's walk and trim are a step** (`HlFunctionQueries.plainReach`, an `IrWalkMemo` whose summary of a function is
  `IrBodyEdges`), whose names a build takes while no key it read changed: the tables, the entry, each function's role, the summaries
  and signatures of the functions it reached. A function in blocks names itself in its edges, which then equal only its own.
- **A walk makes a function's summary the first time a walk reads it** (`IrWalkMemo.summary`), not as it settles: a function no walk
  reached has none, so the walks keep no summaries of unreached functions, and a function given as another object is compared
  only when a walk read the old one.
- **A compile that keeps no session keeps none of it**: the backend is given no queries (`HashLinkBackendSession.assemble`), and the
  stage memos are off as before, so the one-shot compile walks, describes and verifies without recording.

The HashLink steps' kinds are one object the session state's copies share (`HlFunctionQueries`, `SessionState.hlFunctions`), which
the backend gives the assembler and the lowering (`HlModuleAssembler.queries`); `HlLoweredCache` keeps only the lowered functions,
their requests and facts, the tables and the sections.

Deleted: `IrVerifyMemo` (and `Compiler.verifyMemo`, `SessionState.verifyMemo`, `IrPipelineContext.verifyMemo`), `IrFunctionMemo`,
`HlFunctionSummaries`, `IrFieldStoreMemo`, `IrSharedCallsMemo`, `IrWalkRecord`; `IrVerifyMemoMain` is `IrVerifyStageMain`, the same
cases on the stage.

Design changes from the plan, with the reasons:

- **The verifier is a stage of the driver, not a query of its own.** A check reads facts and gives back its function, which is
  what the driver's kind holds; its held path and its marking of the readers of changed facts are the per-function stages'.
- **A function made again equal is checked again.** The memo compared a new function with the one it accepted
  (`IrFunctionStateEquality.same`) and skipped it when equal; the stage verifies a function the inliner made again, which reads the
  function once, as the comparison did.
- **The non-null fields are not a step.** Holding the table while no contribution changed (an `IrWalkMemo` over the field stores)
  saved about 0.02G on the body edit, but the step's columns and the table it kept added about 1 MB of live data to the server; the
  contributions are kept and the table is combined every build.
- **`IrFunctionValues` is not a computed kind.** Its first version kept the values in a `ComputedQueryKind`, whose revisions and
  reads columns nothing used: 0.3 MB of live data per kind more than the lean columns. Its sweep runs only when a key gained a value
  since the last one; one that ran every build cost the no-op 8M instructions.
- **Piece 4 of the typer's per-build state is not part of this slice.** Its tables are the publication's (`SessionState.objects`,
  `irObjects`) and the frontend's prune, which no step over the final IR reads: they first meet the backend's in lowering's object
  facts (`HlLoweringView`), slice 7.

Measured on the compiler's own sources (perf-guard, one machine, against origin/main measured the same way): the no-op rebuild
0.529G → 0.528G instructions, the body edit 1.460G → 1.417G (−2.9%), the signature edit 16.743G → 16.687G (−0.3%); allocation of the
body edit 165.2 → 164.6 MB, of the signature edit 859.2 → 852.8 MB, of the late body edit 183.9 → 177.7 MB; the server's live data
705.7 → 704.9 MB. The cold self-compile, which now keeps nothing of these steps: 51.48G → 51.27G instructions, allocation 2,270 →
2,245 MB, live data at the backend 258.4 → 247.7 MB, the tables and IR unchanged. The UI app's live session (census at the last
build's write) 304.9 → 304.8 MB, the small project's unchanged (7.9 MB). A cold small-project build costs 0.1% more on the VM
(11.43G → 11.44G instructions, the check 11.04G → 11.05G: more classes to compile at startup) and the same ahead of time (1.552G →
1.548G), allocating within 0.2%. The self-compile is byte-identical, warm builds equal fresh ones with and without
`--check-reuse`, the edit replay and the test driver pass.

The plan's estimate was not reached: the body edit's 0.1G assumed the verifier memo and the identity maps cost more than they did.
What a held function cost them was a few lookups each; what is left of the steps on that edit is their whole-program part, the
non-null fields' combination and the plain program's copy among it.

Lines in `src/`: 754 deleted and 861 added, against the estimated −450 / +100: the verifier's split into the program's part and the
function's (`IrVerifier.prepare`, `IrVerifyProgram`, about 150 lines moved), the stage and its answers (about 120), the kinds over the
final IR and their holder (about 160), and the runtime ABI's kept texts (about 80, beyond the plan).

### Slice 7 as built

What a plain build's lowering made of each function is a kind of the session's database, and the facts lowering reads are facts of
the database like the stages'. Of the plan's list, the debug metadata cache and the writer's encodings were gone already, with the
dense build path (MODULE_SECTIONS.md, slice 4d). The root query, built after typer piece 4, compares the pipeline's inputs by their
parts (below).

- **Lowered functions.** `HlFunctionQueries.lowered` is a `ComputedQueryKind<HlLoweredFunction>` keyed by the number of the
  function's name: the function's code with the requests it made and the answers they got. A memo holds while the function is
  the IR it was lowered from, or equal to it (`IrFunctionStateEquality.same`, which then replaces the source in the memo,
  `ComputedQueryKind.replace`), and every fact it read has the value it read; a held function is then relocated into the build's
  tables as before (`HlLink.relocate`, now of its requests alone). Nothing reads a memo through the database, so a lowering made
  again is not compared (`endChanged`). Memos of functions a plain build no longer has go with the engine's sweep, where the cache
  was replaced by each build's entries. The request numbers (`HlRequestKeys`) are the session's with the kind.
- **Facts.** What lowering reads about the program (an object type, a dispatch function's typed-interface key, a class's non-null
  fields) is a fact of lowering's space of `IrStageFacts`, read through the database into the memo being computed
  (`HlLoweringView`), whose value keeps while its answer is the same part by part as the one it was last worked out from
  (`HlLoweringAnswers`), as verification's are. The settings a function is lowered with (field reserve, development metadata) are
  a fact every memo reads, where the cache dropped its entries when they changed; the tables a build extends carry them too
  (`HlLoweredTables.fits`). With the last reader gone, `IrFacts` and `IrAnswerSource` went.
- **What stays outside the database.** The tables the last plain build relocated into and its sections are the backend session's
  (`HashLinkBackendSession.loweredTables`, `sections`), which follow the candidate as the cache did. A live build's published
  functions are the running module's state and follow the assembler (`HlPublishedFunctions`, the cache's live half, with the
  live sections).
- **Wasm module reuse** went: a build whose pipeline inputs are the last one's takes the last module whole already
  (`BackendSession.reuse`), so the session's memo of the module by IR identity only ever held for the build that checks its reuse,
  where it made the check compare the module with itself. The session keeps the last bytes, which say whether a build changed the
  module.

Not done, with the reasons:

- **The section memo stays as it is** (`HlSectionCache`): it is one result per section already, kept while what its encoding read
  reads the same and checked by `--check-reuse`; as a kind its reads would be the same comparisons, not engine reads.
- **The lowered functions are not visited by changed fact.** Every held function is verified (`current`, its facts read inline once
  computed in the run), not skipped by the readers of the facts that changed as the stage driver does: on the body edit the held
  path costs what the cache's did.

Measured on the compiler's own sources (perf-guard `--only=incremental`, origin/main and this change built in two worktrees and run
back to back on one machine): the no-op rebuild 0.770G → 0.767G instructions, the body edit 2.013G → 2.013G (over ten body edits in
one session after the first, 2.0096G to 2.0104G → 2.0063G to 2.0072G), the signature edit 19.624G → 19.621G; allocation of the body edit 236.5 → 232.9 MB (−1.5%), of the late body edit 250.2 → 246.5 MB, of the signature
edit 1,069.5 → 1,066.2 MB (no map of the entries by name per build, no list of facts per function); the server's live data 893.3 → 893.2 MB; a cold small-project build the same (11.34G → 11.33G on the VM, 1.467G → 1.463G ahead
of time). The self-compile is
byte-identical, warm builds equal fresh ones with and without `--check-reuse`, the edit replay and the test driver pass.

Lines in `src/`: 519 deleted and 373 added, against the estimated −850 / +300: the estimate counted the debug metadata and writer
caches, which slice 4d deleted, and `PipelineSnapshot`, which stays.

#### The root query

`PipelineSnapshot` decides from the pipeline's inputs whether a plain build reuses the last final IR and module, the no-op among
them. It made those inputs comparable by encoding them: the canonical encoding of the program's tables (1.2 MB on the compiler's
own sources, 18 ms of every build) and a text of the generator's program facts (`ProgramFacts.inputState`, 165,000 characters,
4 to 5 ms), 24 ms of the compile server's main thread in all (wall, VM, measured around `FrontendCompilation.inputsOf`), while
comparing them cost under 0.3 ms. Now the inputs are the values themselves and are compared by their parts:

- **Tables.** The snapshot keeps copies of the arrays the build gave the pipeline (the passes add to the arrays they are given) and
  compares each entry with the one at its place (`IrDeclarationEquality`, which now also compares natives, C natives and static
  fields, and an enum's recursion as the encoding writes it). The objects are the program's, kept by name with cutoff
  (`SessionState.irObjects`), so the 3,164 objects of a no-op are the same objects and compare by identity; the other tables are a
  few hundred entries, made again each build.
- **Program facts.** `ProgramFacts.difference` compares two builds' facts map by map without rendering them; an interface contract
  is the typed program's object while its module is kept, and one made again compares as it renders.
- **Check mode.** `--check-reuse` holds the comparison to the encodings: inputs it found equal must encode and render the same
  (`PipelineSnapshot.checkEqualInputs`), for the reused build and for the frontend run afresh, so a part the encoding writes and the
  comparison misses is found. A miss now names the entry that differs (`program tables: object Foo`, `generator facts: classBases`).

The root is a value of the state the build made (`SessionState.pipelineSnapshot`), not a memo of the session's database. A build
that fails after the pipeline ran must leave the session as it was, and the next build of the earlier sources reuses the earlier
module (`WasmBackendSessionMain`): the snapshot follows the state back, and is compared by content with what the earlier build
read. As a memo, its reads would be inputs the failed build had already put again, changed after the root was verified, which no
rollback takes back: the next build would miss. Making the tables memos of their own buys nothing here either: the objects are
already, and comparing the rest costs what cutting them off would.

Not done: the tables are still made every build (`IrProgramAssembler.interfacesFrom`, `enumsFrom`, `staticFieldsFrom`, the natives)
before they are compared, and `objectsFrom` still runs (piece 4, "Not built").

Measured on the compiler's own sources (perf-guard `--only=incremental`, origin/main and this change built in two worktrees and run
back to back on one machine, three pairs): the no-op rebuild 0.717G to 0.733G → 0.629G instructions (−13%), the body edit 1.964G to
1.979G → 1.875G (−4.8%: a build that misses made the same inputs), the signature edit 19.61G to 19.65G → 19.54G (−0.4%); allocation
of the no-op 81.6 → 70.2 MB, of the first no-op 126.4 → 115.0 MB, of the body edit 230.5 → 219.2 MB, of the late body edit 244.3 →
233.0 MB; the server's live data 889.2 → 888.7 MB in two pairs (one run of this change measured 903.2 MB, its census 13 MB higher
from the first no-op on, which the other two did not repeat). The cold self-compile keeps no session and makes no inputs: within
0.2%, byte-identical. The small project's builds and checks and the live sessions are unchanged (within 0.8%, all lower or equal).

Lines in `src/`: 20 deleted and 250 added: the comparisons by parts (`ProgramFacts.difference` about 110 lines, the table entries
about 100) and the check that holds them to the encodings.

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

# Compile-server memory: keep what decides, recompute the rest

Status: proposed; measured again (below), steps 1 to 3 built and step 4 in part ("As built", at the end).

## Where the live data is

When this note was proposed, the live UI session (perf-guard `--only=live --live-owners`) held 461 MB of live blocks at the last
edit's `write-done`; live pruning (MODULE_SECTIONS.md, "As built in slice 4c") took that to 369 MB. The census is now taken at
`request-done` (step 1), once the build's result and its response are gone: 359.9 MB. The build itself held only 9 MB the
session does not keep, as the final IR its result carries is the inline cache's too (`IrInlineCache.published`).

By first retention path at the last edit's `request-done`. The paths are breadth-first, so a block several owners hold is charged
to the one nearest the roots:

| Path | MB | What it is |
|---|---|---|
| `SessionState.modules` | 68.8 | typed functions 23.6, token tables 17.8, ASTs 11.9, declaration state |
| `SessionState.inlineCache` | 48.2 | the final IR (`IrInlineCache.published`), which the lowered functions and the assembler also name |
| `SessionState.queries` | 39.3 | IR memos by kind 22.1, the walk memo 15.4 |
| `SessionState.irGeneration` | 36.0 | IR generation's memo per function |
| `SessionState.semanticProgram` | 34.9 | signatures 17.6, the declaration index 9.8, lifecycle 2.7 |
| `CompilerPublication` | 24.4 | the acknowledged publications' snapshots and ABIs |
| `CompilerSession.encodedModule` | 23.8 | the written module's `HlCode`: functions 15.5, relocations 5.2 |
| `SessionState.stageMemos` | 20.4 | stage facts 10.6, contributions 3.7, inline queries 3.7 |
| `SessionState.backend` | 12.7 | the assembler (published functions, section memo, symbol tables) |
| `SessionState.declarationFacts` | 10.6 | |
| `Compiler.ffi` | 6.2 | the FFI interface models (`HxiInterface`, documentation 2.0) |
| `SessionState.purity` | 4.5 | |
| the rest | 30 | the last typed program, types, the published ABI, type mentions, the function map, globals |

First paths overstate what an owner keeps alone. Released one at a time at the last edit's `request-done`, with a census after
each (a local diagnostic, not committed), what each kept alone:

| Released | MB alone | |
|---|---|---|
| `CompilerSession.encodedModule` | 0.0 | its `HlCode` is the cached compile result's too |
| `Compiler.cachedCompileResult` (then) | 1.0 | the module's own tables; its functions, relocations and IR are the assembler's and the inline cache's |
| the publications' assemblers' function caches (`HlFunctionCache`) | 11.9 | |
| their section memos, published entries and maps | 2.3 | |
| their type registries | 1.4 | |
| their objects, inline caches, reachability, owners, backend rest | 1.3 | |
| their typed and semantic programs and published ABIs | 1.9 | |
| their modules | 2.5 | the edited module's old states and each snapshot's module map |
| the publications' ABIs | 3.0 | |
| the rest of the publications | 0.1 | |

So step 2 as written frees about 1 MB, not 34: the module's object graph is the published functions the next build reuses.
Step 3's share is 24.4 MB, of which the function caches are half.

### By source package

The UI session's live data split by the package of the source each part comes from. The census has no source, so this is an
attribution by proxy: per module, its tokens, typed functions and IR instructions, and per function of the final IR, its
instructions (a local diagnostic over `SessionState.modules` and the final program). The frontend's module state (tokens, ASTs,
declaration state) is split by tokens, typed functions by IR instructions, declarations (semantic program, facts, purity,
types, ABI) by typed functions, the per-function IR and backend state (inline cache, IR generation, stage memos, query memos,
backend, module) by final-IR instructions, publications by final functions, and the FFI models go to NativeKit.

| Package | Modules | Source | Tokens | Typed functions | Final functions | MB (approx.) | Of 359.9 MB |
|---|---|---|---|---|---|---|---|
| haxeon-ui (`packages/ui`) | 210 | 2.0 MB | 244 k | 3,032 | 2,408 | 176 | 49% |
| NativeKit bindings (`NativeKit.hx` and the other generated binding modules) | 14 | 2.35 MB | 245 k | 2,330 | 660 | 59 | 16% |
| standard library | 80 | 0.23 MB | 34 k | 641 | 748 | 42 | 12% |
| generated functions with no module (structure printers, runtime helpers) | — | — | — | — | 1,103 | 38 | 11% |
| platform, editor, gpu packages | 91 | 0.29 MB | 31 k | 399 | 379 | 22 | 6% |
| the app (user code) | 1 | 4 KB | 0.7 k | 23 | 22 | 1 | 0.2% |

About 21 MB (the function map, globals, the session's own records) is not attributed. NativeKit's bindings are as many tokens
as all of haxeon-ui and reach few functions: their 59 MB are frontend state (tokens, ASTs, declarations) for code the program
mostly does not run, which step 4's token-table and syntax eviction and a lighter binding form address.

## How comparable systems handle this

rustc's incremental mode serializes its dependency graph and query results to disk between runs and loads them lazily: the
disk is its cache because it is a one-shot process. rust-analyzer (salsa) keeps results in memory, evicts syntax trees and
some query results under LRU limits and recomputes them on demand, and marks library inputs as rarely changing so they are
barely revalidated. Roslyn holds syntax trees and text so they can be recovered: weakly referenced, spilled to memory-mapped
temporary storage, re-parsed when gone. gopls keeps compact per-package summaries and drops function bodies it does not need.
Sorbet keeps everything in memory but compactly (interned ids, flat arenas). The common rule: keep what decides whether
something changed, and the final outputs; drop large intermediate forms and recompute them; use disk mainly to survive
restarts.

## The rule here

The server keeps, per unit, what deciding reuse needs (inputs, digests, recorded reads) and the final output in its most
compact form. A larger form it can recompute from those is a cache the engine may drop: recomputing it gives the same value,
which warm-equals-cold already checks.

## Steps, in order

1. **Measure what is retained, not what a build holds.** Take the gated census after the build's result is released (or
   attribute the build's own working set separately), so the metric and each step below measure memory kept between edits.
2. **Final outputs as bytes.** `encodedModule` keeps the written module's `HlCode` graph (34 MB); patches need the section
   bytes and the lowered form only of functions being replaced. Keep the bytes; rebuild a function's object form on demand.
   `HlFunction`s held for unchanged functions go the same way.
3. **Publications share, not copy.** The acknowledged publications and the pending one (46 MB) hold state the current session
   also holds; as with the symbol tables' strings and globals, they keep a view or a difference, not their own copies.
4. **Recomputable intermediates are evictable.** The final IR of a function whose lowered output is kept (77 MB), its typed
   body once its IR is kept (24 MB), a module's token table after parsing (18 MB): each is dropped after the build that made
   it, or under an LRU bound, and recomputed when a later edit needs it. The engine knows which memos read which, so dropping
   a value keeps its digest and reads; a reader that finds it gone recomputes it. The edit replay and `--check-reuse` cover a
   recomputed value equal to the dropped one; the stage benchmark and perf-guard cover the cost of recomputing.
   **Package code is a tier of its own.** In the UI session about 99% of the live data is package code (the UI library 49%,
   NativeKit's bindings 16%, stdlib 12%, generated functions 11%, platform/editor/gpu 6%), the app's own code about 1 MB. A
   package's sources change rarely, so the server keeps for them only what other code and the output need: declarations and
   signatures (to type the code that uses them), final section bytes, digests (to notice a change) and the small inlinable
   forms the inliner reads; their tokens, ASTs, typed bodies and intermediate IR are evicted after the build that made them.
   Unreached package declarations keep their declaration, not their front-end state: NativeKit's 14 binding modules have as
   many tokens as the whole UI library but reach 660 functions. A package is validated by its files' digests once per build,
   as rust-analyzer's durable inputs are. An edit to a package file still hot-reloads: that package's intermediates are
   recomputed, so the first patch after it is slower, and warm-equals-cold covers that the recomputed values are the ones
   evicted. The tier is the eviction policy, not a second mode: the user's own sources keep everything, as now. Which roots are
   packages comes from the project's package roots (`PackageSourceRoot`), the stdlib included.
5. **Narrow columns.** The pointer-free blocks are the largest type in the census (188 MB of the 461 at `write-done` before
   slice 4c): the IR body rows, HashLink opcode arrays and token tables store every value as 32 bits. Per column, a value range
   that fits gets 8 or 16 bits (opcode kinds and flags, register and local indices), yes/no columns become bitsets, positions
   deltas, with a wide form for the function that needs it. Bool fields in objects are not worth packing: objects are 20–36
   bytes and the collector rounds an allocation to its size class. First measure each large column's value range and what it
   keeps alone; build only the columns where the narrow form saves. Also here: positions as a column of the body's rows instead
   of a `Located` object per instruction and terminator (475k objects), and interning repeated strings, spans and provenance.
6. **Disk, for restarts only.** Persisting the engine's state across server restarts (rustc's model) is a separate feature
   with a format of its own; restarts are rare next to edits. Not planned now. Package section bytes cached on disk by content
   digest, shared across projects and restarts, is where disk pays first, once the package tier exists.

Spilling live objects to disk to save memory is not planned: reading a function's IR back costs about what recomputing it
does (about a millisecond), and the large stable data (section bytes) is already compact after step 2.

## Expected

From the table: steps 2 and 3 about 50–70 MB, step 4 about 100–120 MB, so the UI session from 461 MB to roughly 280–320 MB,
and the compiler's own session by a similar share. Estimates; each step is measured with the census gate and must keep every
edit as fast (`perf-guard --only=incremental`, `--only=live` edit times).

Built, steps 2 and 3 took 15 MB (377.4 → 362.4 MB at `request-done`), not 50–70: the first-path figures they were estimated from
charge shared blocks to the owner nearest the roots. Step 4's figures above are first paths too, at `write-done`; what each
intermediate keeps alone is to be measured the same way before it is built.

## Open questions

- Step 4's policy: drop after every build (simplest, a body edit then recomputes the few functions the inliner reads from
  callers), or an LRU bound (keeps recent ones, a knob to tune). Measure the first; add the bound only if edits slow down. Built
  the first; no edit slowed down ("As built", step 4).
- Whether step 1 changes the gate's baseline enough to re-record it: yes, by 9 MB, re-recorded with the reason.
- Order of the package tier and the narrow columns: the tier first, since it removes most of what narrowing would shrink;
  narrow what is left, measured after the tier.

## As built

### Step 1: the census measures what is kept between edits

The compile server marks `request-done` once a compile's response is out and its result released, before the collection
between requests (`CompilerServer`), and perf-guard's live census is taken there (`measure_live_growth`), so the gated live data
is what the session keeps from one edit to the next. The incremental part's census stays at `write-done`: its builds are read
from the server's log as each response arrives, before the server has settled. The baselines moved with the measure, not with
the compiler: the UI session 386.40 → 377.38 MB and the small project 9.33 → 9.12 MB (perf-guard's bytes; 359.9 and 8.7 MB in
the census's MiB).

### Step 2: the session keeps the written module as bytes

`CompilerSession` keeps the bytes it wrote and their build id, keyed by the bytes object (a reused build's artifact carries the
same one), not the module's `HlCode`; and a compiler that tracks publications keeps no compile result (`Compiler.rememberCompile`),
since none of its builds is ever answered from one. So between edits a live session holds the module's sections and no object
graph of it: the UI session 377.38 → 376.33 MB, the small project 9.12 → 9.02 MB. Far less than the 34 MB the first-path table
suggested, as the module's functions and relocations are the published functions the next build reuses
(`HlModuleAssembler.published`, the section memo).

Nothing is rebuilt on demand, as nothing between builds asks for the object form. A plain session still holds the last module
through its reuse snapshot (`PipelineSnapshot`) and cached result, which hand it back for a build of the same inputs. The
published `HlFunction`s stay objects: every build's module is made of them, and the section memo keeps a section while its
functions are the same objects (`HlSectionWriter.unchanged`); holding them as bytes would mean writing kept sections without
their functions, which step 4's eviction can take up.

### Step 3: publications share what the current state holds

Each publication kept to take back holds the state its build started from (`PendingPublication.snapshot`), a whole
`SessionState` the compiler returns to on a refusal or a retraction. Copies share what a build does not change; what they did
not share, at the last edit (released one part at a time, as above): 24.4 MB over the three acknowledged publications.

- **The rewritten functions.** Half of it was each state's own copy of about 260 functions: those whose runtime calls go through
  a shared helper (`IrSharedRuntimeCalls`), rewritten afresh by every live build, as only a plain build gave the rewrite its
  memo. A live build now keeps it with the published functions (`HlModuleAssembler.published`), so a function that is the same
  object keeps the form the last build gave it, and every state holds the same one: publications 24.4 → 14.1 MB, the UI
  session 376.33 → 365.95 MB.
- **The ABI descriptions and the type registry.** Each build described its runtime ABI afresh, and each state copied the type
  registry's tables. A description now takes the previous one's table wherever it has the same entries
  (`RuntimeAbi.describe`, `previous`), so a body edit's description is the last one's but for what moved; and the registry's
  copies share their tables until one changes, a compatible redeclaration keeping the registered descriptor
  (`TypeRegistry.copy`, `declareClass`): the UI session 365.95 → 362.39 MB.
- **What is left** (10.1 MB over the three publications, released one part at a time): the edited modules' old states 2.5
  (a body edit of the app's one file writes about 40 modules, `Main` and 39 of haxeon-ui and the platform package, not traced
  yet, and each written module is a copy with its own tables); the typed and semantic programs 1.9; the
  function cache's tables 1.2, the section memo 1.2 and the published entries' map 1.0, each a map over every function or
  section that a build copies once it changes one entry; types, objects, reachability, owners and the inline cache's own maps
  about 2. These are the history a refusal returns to, plus whole-table copies of small changes; a table that keeps each
  entry's history, as the query database's rollback log does, would make them differences, and is the next cut if they grow.

### Step 4: package code keeps less

What each intermediate keeps alone, released one at a time at the last edit's `request-done` of the UI session (a local
diagnostic, as for step 0; every module, of which the app's own is one): the token tables 14.7 MB, the modules' syntax trees
10.1 (their canonical declarations 0.9 more), the stage memos 27.6, of them the walks and contribution summaries 16.2, the
per-stage function memos 9.5, the inliner's memo 0.9 and the stage facts 0.5; the typed functions with the last typed program's
list 6.1; the generated IR and its memo 0.9; the final IR the inline cache holds 0.1, as the stage memos and the assembler hold
the same functions. So the 77 MB of final IR the first paths charged to the inline cache are not the inline cache's: what is
kept alone is the frontend's state and the stage memos' intermediate forms, about 40 MB, not 100–120.

**The tier.** A module is package code (`ModuleState.packageCode`) when it is the standard library's, a dependency's, or an
FFI module projected from an interface (which a session never changes). The project's dependencies are named by the CLI:
`CompilerInputs.dependencyRoots`, every source root of a package other than the root package and the FFI projections of their
imports, which `CompilerProvider` passes as `--dependency-root=`. Most packages do not scope their roots (`scopeSourceRoots`),
so `PackageSourceRoot` alone does not tell them apart from the project's own roots; a request without the flag keeps
everything, as before. The tier decides what is kept, never what is built.

- **Tokens.** A module of package code keeps no token table after its parse in a session without semantic models
  (`ModuleAnalyzer.parse`): nothing in the compile server reads it again, and an edit of the file parses it anew. A semantic
  model made later lexes the file again (`ModuleState.keptTokens`). The UI session 362.70 → 344.35 MB, the small project
  9.02 → 8.60 MB (the standard library's tokens).
- **Typed bodies.** A function of package code that a build types and lowers to IR lets go of its typed body once the build's
  IR is assembled (`FrontendCompilation.releaseTypedBodies`), in place, so every holder (the module, the last typed program, a
  class's methods, the publications' snapshots) lets go of it. Nothing reads a typed body once its function has IR: a later
  build keeps the IR until the function is typed again, and typing it again (an edit of its file, or a read that changed) makes
  a new body from the canonical declaration. The released functions are new in the build that releases them, so no state kept
  from before it shares them. Generated helpers keep theirs, as a build can take a helper as it is into the program it walks
  (`TypingSession.keptHelper`). Measured alone this is 20.3 MB, three times what releasing the modules' maps showed: the typed
  functions are also held by class tables and the snapshots. `--check-reuse` covers it as it covers every kept result: the
  frontend and the live build run afresh must give the same IR (`checkFrontendReuse`, `checkLiveAfresh`), which a build that
  read a released body would not. The UI session 344.25 → 322.96 MB, the small project 8.60 → 8.07 MB; an edit of a package's
  file (perf-guard's live package edit) patches in about the time it did, as its module's functions are typed again either way.
- **Policy.** Both are dropped after the build that made them, with no bound: no edit got slower, so no LRU bound was added.
- **What is left**, released one part at a time as above (the syntax trees of package code, after the token change; the rest
  over the whole program):
  - *Syntax trees* 10.2 MB, of which the function bodies 5.6. With the typer-state pieces 1, 2 and 5 built (TYPER_STATE.md), no
    typer state reads a tree; the frontend still does, every build: the module graph parses again any module of the reused
    reachability whose tree is gone (`FrontendCompilation`, `parseReached`), and the names every module sees are kept by the parse
    object they were made from (`ModuleNames.madeFrom`); and when they are remade, the static-extension table, the initialization
    order, a module's resolution after a module came or went, and every module's canonicalization after the alias universe moves.
    The first two need a module's summary that outlives its tree before the tree can go.
    The bodies are read only to make the canonical declarations again, which a change of the names every module resolves
    against (a type added anywhere) does for every module: dropping them means parsing every package file again on such an
    edit, a latency cost on an edit of the app's own code, for 1.6% of the session. Not built; it pairs with making the
    canonical declarations independent of that universe.
  - *The IR stages' intermediate forms* 9.3 MB: what each per-function stage but the last made of each function. The stage
    driver runs each stage over the whole program and verifies a memo by the version of the function it is given, so a stage
    whose memo misses needs the object the stage before it made; dropping those means recomputing a function's earlier stages
    on demand inside a later stage's run, which the driver cannot do yet (the passes prepare whole-program state per run).
  - *The walks and contribution summaries* 16.2 MB: what decides whether a walk is reused, kept by the rule; narrower forms are
    step 5's.
  - *The final IR the inline cache holds* 0.1, *the generated IR and its memo* 0.9, *the canonical declarations* 0.9 and *the
    inliner's memo* 0.9: not worth a mechanism each.

### Step 5: narrow columns, measured first

What the pointer-free arrays hold, from a census that also reads each `Int` array's values (a local diagnostic, not committed):
per owner field, the bytes, the length against the capacity, the value range, and what the array would take at the narrowest
width its values fit (8, 16 or 32 bits, per array, so a wide function keeps its width), and the bytes of blocks whose content
another block of the same type repeats. At the last edit's `request-done` on the UI session (346.0 MB live):

| | MB |
|---|---|
| `Int` arrays, header and storage | 83.8 |
| the same at their exact length | 64.0 |
| the same at the narrowest width per array | 38.2 |
| of the 83.8, `IrBody`'s columns | 44.6 (32.5 exact, 19.2 narrow) |
| `TokenTable`'s columns | 10.1 (6.7 exact, 3.8 narrow; step 4 drops the packages') |

- **Capacity, not width, was the first cut.** An array made at a size (`copy`, `map`, `concat`, a column a builder copies at
  its length) got half its size again as headroom from the runtime (`hl_alloc_array`), though most are never grown: a frozen
  body's columns never are. It now gets the size asked for (at least 4), and growth keeps adding half (`hl_array_reserve`).
  The UI session 346.0 → 323.5 MB at `request-done` (perf-guard 362.70 → 339.21 MB), the small project 9.02 → 8.60 MB, the
  compiler's own session (the incremental part) 792.7 → 705.8 MB; a compile's output is byte-identical.
- **Width is the next 13 MB of `IrBody`, and needs a storage it cannot use yet.** Every row and value column fits 16 bits in
  all but a handful of functions (rows to 3,941, operands to 4,810, values to 3,440, opcodes to 71), so 8 or 16 bits per body
  would halve them. But the language has no narrow integer storage the compiler's own code can read at array speed: `Bytes`
  reads 16 bits as two checked byte reads, and the compiler builds with stock Haxe too. A typed narrow array (a value array of
  `UInt8`/`UInt16` lowered to `MemoryLoad` of that size) comes first; then the frozen body's columns move to it at `freeze`,
  where nothing edits them again.
- **Headers are as large as the data in small bodies.** A body has 26 columns, each an array header and a storage block
  (about 50 bytes before any element), and a median body has a few dozen rows: per body, about 1.3 KB of the columns is
  headers. Packing a frozen body's row columns into one block is the larger cut than width alone, with the same prerequisite.
- **Duplicates are spread thin.** Equal blocks of the same type add up (equal `Int` arrays 35 MB, mostly short and empty
  columns; equal strings 7.7 MB), but no owner holds more than 2 MB of repeated strings, and whole bodies are not repeated:
  equal columns are different functions' equal shapes (a straight-line body's links). Interning would need a table for each.

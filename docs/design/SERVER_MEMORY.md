# Compile-server memory: keep what decides, recompute the rest

Status: proposed; measured again (below) and steps 1 to 3 built ("As built", at the end).

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
5. **Disk, for restarts only.** Persisting the engine's state across server restarts (rustc's model) is a separate feature
   with a format of its own; restarts are rare next to edits. Not planned now.

Spilling live objects to disk to save memory is not planned: reading a function's IR back costs about what recomputing it
does (about a millisecond), and the large stable data (section bytes) is already compact after step 2.

## Expected

From the table: steps 2 and 3 about 50–70 MB, step 4 about 100–120 MB, so the UI session from 461 MB to roughly 280–320 MB,
and the compiler's own session by a similar share. Estimates; each step is measured with the census gate and must keep every
edit as fast (`perf-guard --only=incremental`, `--only=live` edit times).

## Open questions

- Step 4's policy: drop after every build (simplest, a body edit then recomputes the few functions the inliner reads from
  callers), or an LRU bound (keeps recent ones, a knob to tune). Measure the first; add the bound only if edits slow down.
- Whether step 1 changes the gate's baseline enough to re-record it (likely yes, with the reason).

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

# Query engine (design note)

Status: proposed design for ADR 0003 M4a (the engine core), 2026-11-19. ADR 0003 decisions 1, 10 and 14 are the
requirements; this note is how. It replaces the per-pass reuse mechanism sketched in `IR_PASS_INVENTORY.md` (Interface),
whose rules it keeps: the pass framework (M2) is built on this engine.

## Why now

A one-string edit of the compiler's own sources takes about 7 s in the compile server, against 1.3 s for a no-op. Typing is
already incremental (5% of the edit); the IR passes rerun over all ~8,200 functions (66%), with no stage above 0.6 s
(`IR_PASS_INVENTORY.md`, "Edit time"). The gain is one mechanism applied to every stage, not a faster stage.

Today each reuse path has its own cache and rule: the typer's semantic edges and `DeclarationTypes` reads, the inline
cache's dependency lists, the verifier memo, `LoweringView`, the program-level no-op shortcut, the pipeline snapshot. The
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
  reads        Array<{key, digest}>   // what the computation read, in order, with the digest it saw
```

- **Inputs** are memos set from outside, never computed: a module's source text, the compile options that change
  output (`CompileOptions.key()`), the target profile, and the compiler's own identity. Setting an input to a value with
  a different digest starts a new revision.
- **Derived queries** are functions `(context, key) -> value`. A query reads anything only through `context.read(kind,
  key)`, which records the read. Reading a static, a global table or another query's object directly is a bug, caught by
  check mode (below).
- **Keys** are typed per kind and interned to dense ids, as `IrSymbol` interns names. A key is never a concatenated
  string on a hot path.

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
2. **Inputs:** module sources, the options key, the target profile.
3. **`DeclarationTypes` on the engine:** its `recordRead` becomes engine reads, and its `DeclarationType` edges become
   recorded dependencies. This proves the engine on the typer's existing rule.
4. **The passes (M2), in pipeline order from the front.** A pass gets reuse only if the function it is given is the
   same object or digest as last build, and an unported whole-program stage before it makes new objects every build,
   so every function would look changed. The chain therefore starts where objects are kept today, IR generation's
   per-function cache (`ModuleState.irFunctions`), and each stage is ported after the ones before it: per-function
   rewrites as computed queries, whole-program stages (pruning, dispatch walks) as summaries over per-function
   contributions. The inventory's order by edit cost decides nothing until the chain reaches a pass. Measure the
   compile server's one-string edit and no-op at each step.
5. **The fixpoints, then the inliner,** where the chain reaches them.
6. **Lowering and assembly (M4b),** then the front-end caches (M4c).

Measures for every step: self-compile cold (no more than 2% slower while stages are being moved), the compile server's
one-string edit (7 s at the start) and no-op (1.3 s), and the worker's resident memory after a warm build.

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

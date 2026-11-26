# Compile-server memory: keep what decides, recompute the rest

Status: proposed.

## Where the live data is

The live UI session (perf-guard `--only=live --live-owners`, the census at the last edit's `write-done`) holds 461 MB of live
blocks. By first retention path:

| Path | MB | What it is |
|---|---|---|
| the build's `IrProgram` (stack) | 77 | every function's final IR: `IrBody` and what it owns is 89 MB over 18k bodies, one per function |
| `SessionState.modules` | 69 | per module: typed functions 24, token tables 18, ASTs, declaration state |
| `SessionState.queries` (`QueryDatabase`) | 55 | the engine's memos and columns |
| `CompilerPublication` | 46 | acknowledged publications 35, the pending one 12 |
| `SessionState.semanticProgram` | 35 | declarations, signatures, the declaration index |
| `CompilerSession.encodedModule` | 34 | the last module's `HlCode` object graph, kept after it is written |
| `SessionState.stageMemos` | 27 | IR stage memos and summaries |
| `SessionState.irGeneration` | 23 | IR generation's memo per function |
| `SessionState.backend` | 18 | lowered functions (`HlFunction` 24 MB by owner) and the assembler |

The census is taken at `write-done`, inside the build, so it also counts what only the build holds: the stack path is
first-reached, and most of its IR is the same IR the memos keep.

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

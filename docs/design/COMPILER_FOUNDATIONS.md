# Compiler foundations after the latency work

Status: proposed 2026-11-25, for review. It ranks the structural changes the warm-build latency work pointed at, and links
the notes that already design parts of them. Nothing here is started except where it says so.

Between 2026-11-23 and 2026-11-25 a warm body edit of the compiler's own sources went from 3.41G to about 2.5G main-thread
instructions, and from about 1.15 s to 0.75 s, through many local cuts. The cuts kept finding the same few causes. Fixing
those causes is worth more than the next local cut.

## What the latency work found

- **Warm-equals-fresh broke three times, each time in a different cache's own retention rule.**
  - Helpers were typed as units of their first requester, which replaced that function's recorded reads.
  - A generic specialization was kept after its last caller was gone.
  - A type that changed kind (interface to class) did not retype the units that only name it.

  None was a wrong computation. Each was a cached result kept without a recorded reason to keep it. The fixed perf-guard
  edits never hit them; the edit replay over real history caught the last two.
- **Every stage grew its own reuse.** Stage memos, lineage, `IrFacts`, `IrWalkRecord`, contribution memos, the
  frontend's unit reads, the HashLink link and lowering caches. Each answers "what did this read, and does it still
  hold", each was written by hand, and their records went from 15 types to 9 in one consolidation. The query engine
  ([QUERY_ENGINE.md](QUERY_ENGINE.md)) was designed as the single answer. It holds the build inputs and the typer's recorded
  reads (steps 2 and 3a); no IR stage reads through it yet.
- **What is left of a body edit is mostly work that does not scale with the edit.**
  - About 600 functions the frontend and assembler rebuild every build, and then compare.
  - Object tables made fresh each build, so kept records compare them structurally.
  - The dense HashLink indices, which shift after any new function and relink about 2,800 functions on a signature
    edit (about 10% of it).
- **Process-wide tables only grow.** `IrSymbol` and `IrTypeIds` are never compacted, and lambda names are renumbered on
  edits, so a long-lived server grows with its history.
- **A slowdown reached `main` unmeasured.** A body-edit regression of 4% was pushed because perf-guard was a local habit,
  not a gate.

## 1. Everything kept has a recorded reason

**Rule:** a warm build keeps a result only through a recorded dependency that a fresh build would also follow. A cache
needs no retention rule of its own. A result is kept when every read it recorded still holds, and dropped when nothing
that is kept or new reads it any more.

- **Reads:** a unit records each fact it reads: a declaration's signature, a member, a type's shape and, as of the kind
  bug, a named type's kind. Naming a type is a read of its kind.
- **Reach:** a shared or generated result (a specialization, a helper, an anonymous-type printer) is kept while some kept
  or new unit records a use of it. That is a reverse edge, computed from the units' records, never by scanning the program.
- **Generated code:** artifacts that are rebuilt every build today (the `__string` printers, `__init` parts) become
  results with recorded inputs, so they are kept like any other unit. This removes most of what is left of
  `IrLineage.start` (about 2.4% of a body edit).
- **Checks:** `--check-reuse` already compares every kept result with a fresh one. The edit replay (`test-edit-replay.py`)
  is the test that finds these bugs, because it edits the way people do. It belongs in CI over a longer slice of history
  than the local default (item 5).

Both retention rules found this week fit the engine's model. Naming a type reads its kind is a partial read of the type's
fact now, and a read of an input of its own once prints are queries (QUERY_ENGINE.md, step 3d). A specialization kept while a
unit that stays asks for it is the sweep's reachability from the build's roots, once unit records are memos of the database
(step 3b).

This is [WARM_REBUILD_REUSE.md](WARM_REBUILD_REUSE.md)'s rule ("output is the bytes a fresh compiler makes") made
structural instead of checked case by case. Most of it falls out of item 2. Before then, each new cache is reviewed
against it.

## 2. One reuse engine

Finish [QUERY_ENGINE.md](QUERY_ENGINE.md): memos with recorded reads, early cutoff and check mode, in every stage, with
the per-stage mechanisms folded into it. The note's order still holds: inputs, `DeclarationTypes` on the engine, the
passes in pipeline order, the fixpoints and the inliner, lowering and assembly, the front-end caches. Lessons from this
week:

- **Keys must be ids.** Each per-name lookup cost a hash. Slots, symbols and type ids
  ([INTEGER_IDENTITIES.md](INTEGER_IDENTITIES.md)) are the keys the engine needs.
- **Reuse code must not dispatch dynamically.** `IrFunctionPass` and `IrFactSource` as interfaces cost about 3.9% of a
  body edit in by-name dispatch on HashLink. The engine's query and memo types are classes.
- **Whole-program steps are summaries over per-function contributions**, as the passes' `summarize` now does. A step
  that reads only some functions marks them in their summaries.
- **Tables are results too.** A stage that makes the same object table as last build returns last build's table, so
  every comparison downstream is an identity check.

This is the largest item and the one that keeps paying: a new pass is incremental by default, and item 1's bugs stop
being possible.

## 3. Stable output indices

HashLink's function, global, string and type indices are dense and given in first-use order. A cold build's index
therefore depends on everything before it. A warm build that adds one function must renumber, relink and re-encode
everything after it, to match the cold build byte for byte (WARM_REBUILD_REUSE.md, "A new constant, global or function
relinks the functions after it").

The clean fix changes the cold build, not the warm one: give indices by a stable key (module, then declaration order, with
generated functions after their owner). Warm and cold then agree without renumbering, and the relink cost disappears
instead of being optimized.

**Costs and questions:**
- **Output layout:** it changes once, so the self-compile oracle takes a new base.
- **Live patching:** it already keeps slots for dropped functions; the two numbering rules must agree.
- **Debug sections and the HashLink fork's loader:** they must not assume first-use order.
- **Locality:** the order must not hurt it in the JIT or AOT outputs. Measure cold runtime.
- **Variable-length operands:** HashLink's operand widths still change when an index crosses a width boundary. With
  stable indices that is rare, not every edit.

Design it alongside item 2's lowering step, since both change how lowering is kept.

## 4. Lifetimes of process-wide tables

Decide how the interning tables (`IrSymbol`, `IrTypeIds`, and the next families in INTEGER_IDENTITIES.md) end. They only
grow, which is right inside a build and wrong for a server that stays up for days.

**Options:**
- **Epochs:** a table generation per session restart.
- **Compaction at a quiet request boundary:** the server already collects there.
- **Keying generated names stably:** names stop changing on edits, so growth is bounded by the program.

**Measured** on 2026-11-25 over 40 real commits replayed in one server (07b95ac10's tree):
- **Only two tables grow:** `IrSymbol` and `IrTypeIds`. The other `@:processWide` tables are per thread, bounded, or
  unused.
- **No-op builds, body edits and undone edits add nothing.** No generated name carries a counter kept across builds.
- **Growth follows distinct declaration states:** about 51 symbols and 61 types per commit. After 40 commits the final
  tree used 97% of the symbols and 90% of the types. That is about 40 KB of dead entries per commit, and about 2–10 MB
  for a working day, against about 800 MB of live data.
- **What dies is content that really changed:** anonymous-type spellings, specialization keys that spell types in full,
  removed functions, and lambdas whose captures changed. The text dominates: dead names average about 740 characters.

So stable names do not bound the growth. The choice is **compaction at a quiet request boundary**, run only once the
table passes a size trigger (for example 1.5× the last build's live set). It keeps the id slots and releases only the
name text and the by-name entry, which frees about 95% of the bytes. It needs one rule: a released id is never given to
another name. It is not urgent at these sizes; settle it with the bodies-only session work
([TODO.md](../../TODO.md)), since both decide what the server holds.

Two naming fixes are worth doing regardless, since they cut bytes and needless work:
- **`$try` cells:** they are named by their absolute file offset (`Parser.parseTryExpression`). An edit above a `try`
  renames its cell and lowers that function again. Number them within their function instead.
- **Names that spell whole types:** a fixed-length digest would cut the dead bytes by about 80%. The generators are
  `SemanticSignature.anonymousTypeName`, `GeneratedNames.specializationKey`, the shared array helpers and
  `$iteration-adapter`.

## 5. Gates in CI

perf-guard's incremental part and the edit replay run in CI on changes to compiler code. That way a regression is caught
whoever pushes, and a cost taken on purpose is written as `--raise=METRIC=REASON`. In progress: see
[DEVELOPMENT.md](../DEVELOPMENT.md), "Performance guard".

## Smaller, related

- **Positions relative to their declaration** (WARM_REBUILD_REUSE.md, open items): a comment at the top of a file
  currently lowers every function after it again. This belongs with item 3, since both change what lowering keys on.
- **Structures of another layout are copied on conversion from Dynamic, where Haxe aliases them through virtual views**
  (LANGUAGE_SUPPORT.md). Exact semantics there would need a view representation for structural subtyping. It is a
  language-representation question, not a reuse one; keep it separate.
- **Type ids step 5, declarations by id** (INTEGER_IDENTITIES.md): only if profiles show structural type work growing
  again. About 1.7% now.

## Order

1. **Now:** item 5, the CI gates. Then item 1's two open bugs (the specialization's reach and the named type's kind), as
   recorded reads, with replay cases.
2. **Next track:** item 2, from QUERY_ENGINE.md step 2, with item 3 designed in when the engine reaches lowering.
3. **Before the bodies-only memory work:** item 4.

## Open questions

- Should the edit replay in CI also run with the AOT server, which is the server users run on Linux?
- For item 3, does any tool read HashLink indices expecting first-use order? Candidates: the debugger, the profiler, live
  patch history.
- For item 2, which per-stage mechanism goes first? `IrFacts` and the stage memos are the closest to the engine's model.

# Direct SSA: build SSA while generating IR

Status: done (22d0bcd95): the IR generator builds SSA directly, and the CFG stage is deleted. `COMPILER_DATA_LAYOUT.md`
step 6.

## Problem

`IrGenerator` lowers a function twice. It first emits a CFG over named locals (`CfgBuilder`: `LoadLocal`, `StoreLocal`,
`CfgValue`s that live in one block), then `SsaBuilder` turns that into SSA: it rebuilds the graph, computes dominators,
dominance frontiers and liveness over bit sets, places pruned phis and renames along the dominator tree. The CFG is
thrown away. On the compiler compiling itself, `CfgBuilder` and `SsaBuilder` are 12% of all allocated bytes (1.36 million
`CfgInstruction`s, each in its own `Located`, then the same again as `IrInstruction`s), and the work in between is
whole-function analysis done only to discover what the generator knew while emitting.

## Decision

The generator emits SSA directly, with the algorithm of Braun et al., "Simple and Efficient Construction of Static Single
Assignment Form" (CC 2013), the one Cranelift's frontend uses.

1. **One builder, `IrBuilder`, replaces `CfgBuilder`.** Its API is the same (`load`, `store`, `createBlock`, `select`,
   `jump`, `branch`, `beginTry`, the instruction helpers), but it emits `IrInstruction`s over `IrValue`s into `IrBlock`s.
   `load(name)` reads the local's current value; `store(name, value)` makes `value` the local's current value. Nothing is
   emitted for either.
2. **Locals are numbered** per function the first time the builder sees a name (the CFG half of
   `INTEGER_IDENTITIES.md` stage 2); the per-block current values are arrays indexed by that number, reused across
   functions.
3. **Predecessors are recorded as terminators are emitted** (`jump`, `branch`, `switchOn`, `jumpFrom`), and a try's
   handler gets the block that begins the try as its predecessor, as `SsaBuilder` gave it: the protected body starts a new
   block, so the handler sees the locals as they were when the try began (locals written inside a try and read after it are
   cells, `StorageRequirements`).
4. **Sealing.** A block is sealed when it is selected, unless it was created open (`createOpenBlock`): loop headers and
   continue targets, which get back edges after their body. The generator seals an open block when its last edge is in
   (`seal`). An edge into a sealed block is an internal error, so a missing `createOpenBlock` cannot go unnoticed. A read
   in an unsealed block makes an incomplete phi, completed when the block is sealed.
5. **Phis are kept apart while the function is built** (a block's phis can appear after its instructions, when a later
   read reaches it) and placed at the start of their blocks when the function is finished.
6. **Finishing.** Blocks unreachable from the entry are emptied, as before, and their phi operands dropped. Trivial phis
   (all operands one value, or the phi itself) are replaced until none is left, and phis no instruction uses, directly or
   through other phis, are removed. Every operand is then rewritten through the replacements once. A read that reaches a
   reachable entry with no definition is the existing "used before definition" internal error.
7. **Debug bindings** are recorded at each store of a source local and for each phi of one that survives finishing.
8. **The iterator replacement runs on SSA** (`IrIteratorReplacement`, was `CfgIteratorReplacement`). Its eligibility
   reads the SSA web of an iterator (its `IteratorNew`s and the phis between them, used only by `hasNext` and `next`), and
   the array and position it introduces are placed with the same variable machinery over the finished, sealed blocks
   (SSA reconstruction, the same algorithm).
9. **Deleted:** `Cfg`, `CfgBuilder`, `CfgVerifier`, `SsaBuilder`, `SsaScratch`, `CfgIteratorReplacement`. `IrVerifier`
   checks the result, as it checks every pass's.

## What changes in the output

Phi placement and value numbering. Braun's algorithm with trivial and dead phi removal gives minimal, pruned SSA for the
reducible graphs the generator makes, the same set of phis as `SsaBuilder`'s pruned placement up to which value a phi
input names, but values are numbered in emission order, phi inputs are in predecessor order and debug bindings in
emission order. So the compiler's output is not byte-identical across this change; the checks are the program suites.

## Checks

The full test driver, the self-hosting fixed point, Wasm parity, the ci debug-metadata and hot-reload suites, the SSA
and loop-bound unit tests ported to the builder. Allocated bytes, main-thread instructions and peak memory on the frozen
input, and the output's size, in the commit. Later byte-identity checks use the new output as their baseline.

## Decided while implementing

- **The builder is `IrLocalsBuilder`, not a second `IrBuilder`.** `IrBuilder` already builds SSA helpers with explicit phis
  for the IR passes (about 460 uses). Merging the two into one builder, with locals as an option, is a follow-up.
- **Which blocks are open was found, not guessed.** The old builder was instrumented to report every block that got an
  edge after it was selected, over the self-compile and the full test driver: loop condition checks, do-while bodies,
  shared case bodies, the generated sort and comprehension loops, the enum-keyed map loop, 18 sites. They are made with
  `createOpenBlock`. An edge into a sealed block is accepted while no read has looked through its predecessors, since no
  answer depended on them yet; after that it is an internal error, never a silent miscompile.
- **The iterator replacement runs inside `finish`, before phis are placed,** because its rule is about locals (each
  creation stored once into one local, no copies), which SSA values alone do not say: an SSA value can be shared by two
  locals after `var b = a`.
- **One phi provenance per block** instead of one per phi.
- **A join reads its predecessors before it makes a phi.** A lookup through a sealed block with several predecessors
  collects their values first and makes a phi only when they differ, so the trivial phis the plain algorithm makes and then
  removes are never made. A lookup that comes back to a join while it is still collecting is on a cycle; the join gets its
  phi then, and the phi is completed and checked for triviality once the collection ends (the marker variant in Braun et
  al.).

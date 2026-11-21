# The IR core in columns

Status: accepted (`COMPILER_DATA_LAYOUT.md` step 7). The user chose a full migration to bodies edited in place, with a
checkpoint once the inliner stage runs on bodies, where steps 4 to 6 of the migration are decided on measurements.
Migration step 1 (`IrBody` beside the IR, round trip under `--check-ir-body`) is done. Depends on the ADR 0006 decision
about how flat records are declared; see "Both builds".

## Problem

A function's IR is a graph of small objects. Each instruction is an `IrInstruction` enum value wrapped in a `Located` (the
instruction and its provenance); each value an `IrValue` object (id, name, type); calls, phis and enum constructions carry
operand arrays; each block an `IrBlock` with an array of instructions. A pass that changes one instruction makes a new
one, a new array for its block and a new function, and most passes then build their own tables indexed by value id beside
it. Live, the IR costs about 133 bytes per instruction (the census at the self-compile's second collection: 103 MB of IR
records and their arrays for 777k instructions), and every analysis repeats a walk over objects to recover what a column
would give directly (a value's definition, its type, its uses).

## Proposal

1. **A function body is a table.** One `IrBody` per function holds rows of instructions in parallel `Int` columns:
   opcode, output value id, operand range in one operand pool, one auxiliary field (a constant, a type or symbol id, an
   index into a pool), a provenance id, and the links that order rows within their block. Values are typed ids
   (`IrValueId`): a value's type is a column indexed by value id, its defining row another, and its debug name a column
   only debug output reads.
2. **Types and symbols are ids.** Types are dense ids from one `IrTypeIds` per program, given where the generator lowers a
   type, field and function names interned `IrSymbol` ids. Comparing two types or two names is comparing two integers.
3. **Passes edit bodies in place.** A pass changes rows, operands and links of a body it owns; nothing is copied per
   edit. `IrBodyBuilder` makes new bodies: the generator's, inlined copies, and compactions. A pass that only reads keeps
   its tables in `IrPassScratch`.
4. **The codec writes columns.** `IrFunctionStateCodec` writes and reads the columns as they are, instead of walking
   values and instructions.

## Why in place

The first prototype rewrote bodies as `IrFunctionRewrite` rewrites objects: a pass that changed anything built a new body.
Measured on the inliner's cleanup chain over the self-compile's 8,628 functions, each pass on the same input, results
compared with the object passes' (no difference):

| Pass | Objects | New body per change | Edited in place |
|---|---:|---:|---:|
| constant branches | 61 ms / 20.0 MB | 92 ms / 41.1 MB | 46 ms / 10.4 MB |
| dead pure values | 105 ms / 10.0 MB | 310 ms / 56.1 MB | 45 ms / 0.8 MB |
| jump threading | 64 ms / 9.2 MB | 124 ms / 53.0 MB | 55 ms / 10.2 MB |

Rebuilt, columns lose to objects; edited in place they win, and what the in-place versions still allocated was their
analyses' maps. Over the final program (647k rows) a read walk takes 17 ms on bodies and 54 ms on objects, and the
columns take 42.6 MB, about 0.4 of the objects.

Columns only for the backends (encode after the last pass, the passes on objects) were rejected: the encode (about
0.3 s and 68 MB, after the last collection) costs what HlLower's walks would save, and the objects stay alive for the
caches, so both forms are kept for good. Removing `IrBody` keeps the IR's size and the per-edit records.

## Both builds

The body is written once, behind `IrBody`'s inline accessors with private columns, so every pass reads
`body.opcode(row)`, `body.operand(row, index)`, `body.valueType(value)` whatever the storage. The storage is the only
thing that differs:

- **Stock Haxe:** parallel `Array<Int>` columns (`hl.types.ArrayBytes` on HashLink: flat, no per-row object).
- **Haxeon:** the same, until inline `Array<S>` exists (ADR 0006 gate 1); then a row may become a struct in one array if
  measuring shows it pays (rows read together, one bounds check), or the columns `NativeColumn`s (`ARENAS.md`).

This is the dual declaration the proposed ADR 0006 amendment describes, confined to the package that declares the storage;
passes never see `#if haxeon`.

## Migration

One conversion at a time: objects are encoded into bodies at one point of the pipeline, everything after it reads and
edits bodies, and each step moves that point upstream. A pass moved alone, with a conversion on each side, would pay an
encode and a decode per call. Each step leaves the output byte-identical, so the self-compile is the check between steps.

1. `IrBody` beside the current IR, with conversions both ways; the verifier checks a round trip on every function
   (`--check-ir-body`, off by default: it copies every function). *Done.* Then bodies become editable, with the layout and
   freeze checks, and the cleanup passes (constant branches, dead pure values, jump threading, unreachable blocks) get
   in-place versions, checked against the object passes in `IrBodyMain`.
2. and 3. **The inliner stage runs on bodies, and HlLower reads them.** The encode moves to the inliner stage's entry:
   inlining, `IrLoadStoreForwarding`, `IrScalarReplacement`, `IrStrengthReduction`, the cleanup chain, `IrGraph` and
   `IrNonNullFacts` on bodies, the stage's caches holding frozen bodies. Taken together so that HlLower's walks pay for
   the encode. *Checkpoint: allocation, peak, wall and instructions against the object pipeline decide steps 4 to 6.*
   *The inliner stage runs on bodies*: a function is encoded when it is first inlined, inlining splices and expands callees
   in place, the stage's passes edit that body, and it is decoded once at the stage's exit (back to its source when nothing
   changed it). The memo holds frozen bodies; in a compile that keeps a session the cache also holds each source's frozen
   body while the source is the same object. Until the object passes are gone, a pass that numbers new values as its object
   version did takes them from `IrBody.newValueAt` (strength reduction after load-store forwarding), which may reuse the id of
   a value no row or binding names any more.
   *HlLower reads the bodies*: nothing is decoded at the stage's exit. Each function of `program.functions` is its frozen body
   (`IrFunction.ofBody`; a function the stage left as it was keeps its source object and gets its source body), and its blocks
   and bindings are decoded from the body the first time something reads them, once: the verifier when verification is on, the
   reports, instrumentation, the Wasm backends, the session's comparisons of functions. A function made after the stage, or
   one without a body, is encoded once when a body reader asks for it (`IrFunction.bodyIn`). On the HashLink path the readers
   are bodies: the plain build's reachability walk and table trim, the shared runtime calls (a copy of a body with its call
   symbols replaced, `IrBodyBuilder.copyWithAuxes`), the runtime enum descriptors, natives discovery, function identities, and
   HlLower itself (edge blocks on a copy, `PhiEdges.splitBody`; non-null facts with `IrNonNullFacts.analyzeBody`; exact
   types, scalar value locals and phi moves on rows). The loop proofs of inline value-array reads (`IrLoopBounds`) still read
   objects, decoding the few functions that have such reads.
4. The program-level passes, from the last back to the first, each moving the conversion before it; `IrBuilder` emits
   rows.
5. The generator and `IrLocalsBuilder` emit bodies, with types given ids where they are lowered: no conversion is left.
   The codec writes bodies.
6. The Wasm lowerings read bodies (until then they decode, off the self-compile's path); `IrInstruction`, `Located`
   instructions, `IrValue`, `IrBlock` and `IrFunctionRewrite` go.

## Checks

Allocated bytes, main-thread instructions and peak memory on the frozen input at each step, as for the other steps; the
full test driver and Wasm parity when a pass moves; the ci debug-metadata and hot-reload suites when HlLower or the inliner
moves; the self-hosting fixed point at the end. The verifier checks a body's layout (below) and that no frozen body
changed; an edit to a frozen body is an internal error at the edit.

## Decisions

Inventory: 60 instruction kinds and 7 terminator kinds. Payloads besides values are names (fields, methods, types,
globals, C natives, call targets), `IrType`s (`TypeValue`, intrinsics), `Int`, `Float`, `String` and `Bool` constants,
block ids (phi inputs, try blocks, branch targets) and two int arrays (`StaticDataAddress` bytes, `Switch` targets).

- **Rows.** Columns `opcode`, `output` (value id or none), `operandStart` and `operandEnd` (a range in the operand pool),
  `aux`, `provenance`, and `previous` and `next` (the row's neighbours in its block, -1 at the ends). No result type
  column: every result is a value, and a value's type is a value column.
- **Rows never move.** An edit that removes a row unlinks it (its output loses its defining row); one that inserts rows
  appends them to the columns and links them where they go, so a block's rows are a linked list in the columns, in order
  when the body was just built or compacted. Every walk follows the links (`firstRow`, `nextRow`), never a range of row
  numbers. This is Cranelift's layout; it was preferred to tombstones in row ranges with blocks as chains of segments,
  which make every walk skip tombstones and step across segments.
- **Operands** change in place when their count stays or shrinks; a row that needs more (a phi gaining inputs) moves its
  run, and its int-pool run, to the end of the pools. Runs left behind are garbage until compaction.
- **Opcodes.** One per instruction kind, one per `IrIntrinsic` operation (its type goes in `aux`), one per terminator
  kind, terminators last, so a row is a terminator when its opcode is at least `Unreachable`.
- **Terminators are rows**: the last row of a block, when its opcode is a terminator. Successor walks go through
  `successorCount` and `successor`, which read `aux`.
- **The auxiliary column** holds what fits in an `Int`: a constant (`ConstInt`, `ConstBool`, sizes, a `Jump` target), a
  type id, a symbol id (`MethodCall` packs its terminal-receiver flag in the low bit), an index into the body's float or
  string pool, or the start of a run in the body's int pool for wider payloads: phi predecessor blocks (one per operand),
  static data bytes, try blocks, `MakeEnum` and `EnumField` pairs, branch and switch targets. `IrBody` lists the meaning
  per opcode.
- **Names are `IrSymbol` ids**, process-wide interned. String literals are not names and stay in a per-body pool.
- **Types are ids** from one `IrTypeIds` per program; the body holds the table it was made with. Until the generator emits
  bodies, the encoder gives the ids; then the generator gives them where it lowers a type, and HlLower maps a type id to
  its HashLink type through a table instead of a structural lookup per register.
- **Floats** in a per-body `Float` pool, which keeps their bits (`-0.0`, NaN payloads).
- **Blocks** have ids independent of position, a first and a last row, and an order (the layout), edited by splicing:
  removing a block unlinks it from the order and its rows from the body.
- **Values** are `IrValueId`s, an abstract over `Int`, dense and never reused: a value a pass adds takes `valueLimit()`.
  Columns by value id: type id (-1 for an id no value has), name, and defining row (-1 for arguments). The arguments are
  a column of value ids; the header (name, kind, result type id, inline hint, retention) stays as fields.
- **Replacing all uses** of a value goes through an alias column: `alias(v) = w`, and reads of operands resolve through
  it until the pass that made aliases sweeps them into the operand pool and the debug bindings (one linear walk of
  ints). This is the inliner's and the scalar passes' value substitution.
- **Ownership.** A body reachable from a cache (the inliner's memo and its cleaned and published forms, HlLower's cache,
  the codec) is frozen; editing a frozen body is an internal error, and a pass that would change one changes a copy
  (`thaw`). The copy-on-write sharing of `IrFunctionRewrite` moves from blocks to functions.
- **Compaction** rebuilds a body without unlinked rows or garbage runs, its rows in block order. It runs when a body is
  frozen and when the garbage passes half of its rows, never per edit.
- **Provenance** is an id into a per-body pool of `SourceProvenance` objects, consecutive rows with the same object
  sharing one entry; inlined rows keep their callee's provenance, its pool entries appended to the caller's. Making
  locations program-wide ids is a later step, once the backends read bodies.
- **Debug bindings** are columns of their own (identity, name, path, scope start and end, value id); only debug output
  reads them. A binding whose value a pass dropped keeps its id, which no new value may take, so one id never names two
  values.
- **What an edit costs.** Unlinking a row, changing an operand, a target or a constant, dropping phi inputs: constant or
  linear in the row's operands, no allocation. Inserting rows or inputs: appends to the columns. Splitting a block:
  relinking at the split plus a new block in the order. Against objects: a new enum value and `Located` per changed row,
  a new array per changed block, a new function.
- **Restructuring passes.** The inliner splices a straight-line callee by appending its rows, values renumbered through an
  int table, and linking them in place of the call row, whose output becomes an alias of the callee's result; a callee
  with blocks splits the caller's block after the call (the tail's rows relinked into a new block), appends the callee's
  blocks with ids renumbered, turns returns into jumps to the tail and the result into a phi at the tail's start.
  Load-store forwarding and scalar replacement unlink loads and dead stores and alias their outputs; new phis where values
  meet come from `IrSsaVariables`, which links them at a block's start.
- **Layout check.** The verifier checks each body it verifies: every linked row belongs to one block and is reached once,
  `previous` mirrors `next`, a terminator only last, operand and int-pool runs inside their pools, a defining row for
  every linked output and none for an unlinked one, no aliases left after a pass.

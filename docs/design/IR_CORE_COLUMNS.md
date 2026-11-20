# The IR core in columns

Status: proposed, design only (`COMPILER_DATA_LAYOUT.md` step 7). Depends on the ADR 0006 decision about how flat records
are declared; see "Both builds" below.

## Problem

A function's IR is a graph of small objects. Each instruction is an `IrInstruction` enum value wrapped in a `Located` (the
instruction and its provenance); each value an `IrValue` object (id, name, type); calls, phis and enum constructions carry
operand arrays; each block an `IrBlock` with an array of instructions. A pass that changes one instruction rebuilds the
block's array and usually the function (`IrFunctionRewrite`), and most passes then build their own tables indexed by value
id beside it. After direct SSA and the reusable side tables, the IR's own representation is the largest part left in the
middle of the compiler: `IrBlock.new` alone is about 1% of all allocated bytes, the state codec walking values another 1%,
and every analysis repeats a walk over objects to recover what a column would give directly (a value's definition, its
type, its uses).

## Proposal

1. **A function body is a table.** One `IrBody` per function holds rows of instructions in parallel `Int` columns:
   opcode, result type id, operand start and count in one operand pool, one auxiliary field (a constant index, a field or
   symbol id, a constructor index), and a provenance id. Blocks are ranges of rows plus a terminator row. Values are ids:
   a value's type is a column indexed by value id, its defining row another, and its debug name a side table only debug
   output reads.
2. **Types and symbols are ids.** Result types are dense ids from one `IrTypeMap<Int>` per program (step 4), field and
   function names the interned symbol ids of ADR 0003 decision 5. Comparing two types or two names is comparing two
   integers.
3. **Passes edit through a builder.** A pass that rewrites appends rows to a new body (the same builder `IrLocalsBuilder`
   and `IrBuilder` become), keeping the operand pool and side columns it does not change. A pass that only reads, as the
   analyses do, reads the columns and keeps its tables in `IrPassScratch`.
4. **The codec writes columns.** `IrFunctionStateCodec` writes and reads the columns as they are, instead of walking
   values and instructions.

## Both builds

The body is written once, behind an `abstract IrBody` with inline accessors, so every pass reads `body.opcode(row)`,
`body.operand(row, index)`, `body.type(value)` whatever the storage. The storage is the only thing that differs:

- **Stock Haxe:** parallel `Array<Int>` columns (`hl.types.ArrayBytes` on HashLink: flat, no per-row object).
- **Haxeon:** the same, until inline `Array<S>` exists (ADR 0006 gate 1); then a row may become a struct in one array if
  measuring shows it pays (rows read together, one bounds check).

This is the dual declaration the proposed ADR 0006 amendment describes, confined to the package that declares the storage;
passes never see `#if haxeon`.

## Migration

Each step leaves the output byte-identical, so the self-compile is the check between steps:

1. `IrBody` beside the current IR, with conversions both ways; `IrVerifier` checks a round trip on every function.
2. The read-only analyses move to the column API first: `IrGraph`, `IrNonNullFacts`, `IrExactTypeFacts`,
   `IrDeadPureValues`, `IrLoopBounds`.
3. The generator emits a body; the current IR is made from it for the passes not yet moved.
4. The rewriting passes move one at a time, in pipeline order, each taking and returning bodies.
5. The backends (`HlLower`, the Wasm lowering) read bodies; the codec writes them.
6. `IrInstruction`, `Located` instructions and `IrValue` objects go.

## Checks

Allocated bytes, main-thread instructions and peak memory on the frozen input at each step, as for the other steps; the full
test driver and Wasm parity when a pass moves; the self-hosting fixed point at the end.

## Open questions

- Whether the terminator is a row or a block column: a row keeps one decoder; columns make successor walks cheaper.
- Whether constants live in the auxiliary column (an index into a per-program pool) or in their own column per kind.
- How much of `IrFunctionRewrite`'s copy-on-write sharing survives, given that a body is cheap to copy as columns.

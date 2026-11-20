# The IR core in columns

Status: proposed (`COMPILER_DATA_LAYOUT.md` step 7); migration step 1 done: `IrBody` exists beside the IR and the
verifier checks its round trip under `--check-ir-body`. Depends on the ADR 0006 decision about how flat records are
declared; see "Both builds" below.

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
   opcode, output value id, operand start in one operand pool, one auxiliary field (a constant, a type or symbol id, an
   index into a pool), and a provenance id. Blocks are ranges of rows ending in a terminator row. Values are ids:
   a value's type is a column indexed by value id, its defining row another, and its debug name a side table only debug
   output reads.
2. **Types and symbols are ids.** Types are dense ids from one `IrTypeIds` per program (an `IrTypeMap<Int>`, step 4),
   field and function names interned `IrSymbol` ids. Comparing two types or two names is comparing two integers.
3. **Passes edit through a builder.** A pass that rewrites appends rows to a new body (the same builder `IrLocalsBuilder`
   and `IrBuilder` become), keeping the operand pool and side columns it does not change. A pass that only reads, as the
   analyses do, reads the columns and keeps its tables in `IrPassScratch`.
4. **The codec writes columns.** `IrFunctionStateCodec` writes and reads the columns as they are, instead of walking
   values and instructions.

## Both builds

The body is written once, behind `IrBody`'s inline accessors with private columns, so every pass reads
`body.opcode(row)`, `body.operand(row, index)`, `body.valueType(value)` whatever the storage. The storage is the only
thing that differs:

- **Stock Haxe:** parallel `Array<Int>` columns (`hl.types.ArrayBytes` on HashLink: flat, no per-row object).
- **Haxeon:** the same, until inline `Array<S>` exists (ADR 0006 gate 1); then a row may become a struct in one array if
  measuring shows it pays (rows read together, one bounds check).

This is the dual declaration the proposed ADR 0006 amendment describes, confined to the package that declares the storage;
passes never see `#if haxeon`.

## Migration

The IR is migrated by pipeline segment, not by pass: while the IR is made as objects, a pass moved alone would pay an
encode and a decode on every call and make the compiler slower until the end. A segment converts once at its entry and
once at its exit, and runs on bodies in between. Each step leaves the output byte-identical, so the self-compile is the
check between steps:

1. `IrBody` beside the current IR, with conversions both ways; the verifier checks a round trip on every function
   (`--check-ir-body`, off by default: it copies every function).
2. The inliner stage runs on bodies throughout: `IrInliner`'s per-function pipeline (inlining, `IrLoadStoreForwarding`,
   `IrScalarReplacement`, `IrStrengthReduction`) and its cleanup chain (constant branches, `IrScalarRefPromotion`,
   `IrDeadPureValues`, `IrReceiverCheckElision`, `IrJumpThreading`, with `IrGraph` and `IrNonNullFacts`), converting
   once at its entry and exit, so the step is a measured win on its own.
3. The segment widens: the stages before and after the inliner, then the generator emitting bodies and the backends
   (`HlLower`, the Wasm lowering) reading them, until no conversion is left; the codec writes bodies.
4. `IrInstruction`, `Located` instructions and `IrValue` objects go.

## Checks

Allocated bytes, main-thread instructions and peak memory on the frozen input at each step, as for the other steps; the full
test driver and Wasm parity when a pass moves; the self-hosting fixed point at the end.

## Decisions

Inventory: 60 instruction kinds and 7 terminator kinds. Payloads besides values are names (fields, methods, types,
globals, C natives, call targets), `IrType`s (`TypeValue`, intrinsics), `Int`, `Float`, `String` and `Bool` constants,
block ids (phi inputs, try blocks, branch targets) and two int arrays (`StaticDataAddress` bytes, `Switch` targets).

- **Rows.** Columns `opcode`, `output` (value id or -1), `operandStart` (one entry more than rows, so a row's operands
  end where the next row's start), `aux` and `provenance`. No result type column: every result is a value, and a value's
  type is a value column.
- **Opcodes.** One per instruction kind, one per `IrIntrinsic` operation (its type goes in `aux`), one per terminator
  kind, terminators last, so a row is a terminator when its opcode is at least `Unreachable`.
- **Terminators are rows.** The last row of a block, when its opcode is a terminator: one decoder, one provenance column,
  and blocks under construction need no marker. Successor walks go through `successorCount` and `successor`, which read
  `aux`.
- **The auxiliary column** holds what fits in an `Int`: a constant (`ConstInt`, `ConstBool`, sizes, a `Jump` target), a
  type id, a symbol id (`MethodCall` packs its terminal-receiver flag in the low bit), an index into the body's float or
  string pool, or the start of a run in the body's int pool for wider payloads: phi predecessor blocks (one per operand),
  static data bytes, try blocks, `MakeEnum` and `EnumField` pairs, branch and switch targets. `IrBody` lists the meaning
  per opcode.
- **Names are `IrSymbol` ids**, process-wide interned: comparing two names is comparing two integers, and a call target
  already is one. String literals are not names and stay in a per-body pool, so a session does not intern every literal.
- **Types are ids** from one `IrTypeIds` per program (an `IrTypeMap<Int>` and the types by id); the body holds the table
  it was encoded with.
- **Floats** in a per-body `Float` pool, which keeps their bits (`-0.0`, NaN payloads).
- **Blocks** are ranges of rows in function order: a column of block ids (ids stay independent of position) and one of
  first rows with one entry more. Phis are ordinary rows at the start of their block.
- **Values** are columns indexed by value id: type id (-1 for an id no value has), name, and defining row (-1 for
  arguments). The arguments are a column of value ids; the header (name, kind, result type id, inline hint, retention)
  stays as fields.
- **Provenance** is an id into a per-body pool of `SourceProvenance` objects, consecutive rows with the same object
  sharing one entry. Making locations program-wide ids is a later step, once the backends read bodies.
- **Debug bindings** are columns of their own (identity, name, path, scope start and end, value id); only debug output
  reads them. A binding whose value a pass dropped keeps its id, which no new value may take (`IrFunction.nextValueId`,
  checked by the verifier), so one id never names two values.
- **Editing.** A body is immutable once built. A pass that rewrites builds a new body with `IrBodyBuilder`: it copies the
  rows it keeps (a block is a few array copies), appends the ones it changes, and replaces operand uses through a value
  substitution as rows are copied; values it adds take the next ids. A function nothing changed keeps its body, so the
  copy-on-write sharing of `IrFunctionRewrite` survives at the level of the function, not of the block. A pass that only
  reads keeps its tables, sized by `rowCount` or `valueLimit`, in `IrPassScratch`.

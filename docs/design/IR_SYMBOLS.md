# IR symbols

Status: proposed. Step 1 of the integer identities in `COMPILER_DATA_LAYOUT.md`; the identity side is ADR 0003 §5 (M3).

The IR names what it calls by string: `Call(output, functionName, arguments)`, `StaticClosure`, `InstanceClosure`. Every
pass that needs the callee looks the name up in a map built for it, so the IR passes, assembly and HashLink lowering hash
names throughout. This note replaces those names with interned symbols that carry a dense integer id.

## Decisions

1. **A reference is an `IrSymbol`:** a final class with `id:Int` and `name:String`, made only by a symbol table, one per
   name. Two references to the same function are the same object, so they compare by identity and index arrays by `id`.
   The name is the symbol's rendered identity today; M3 replaces it with a structured identity (kind, owner, member, type
   arguments) without changing the id or any pass that only uses the id.
2. **The compilation session owns the table** (`IrSymbols`). IR outlives a single compile (the inline cache, incremental
   reuse, the function state codec), so ids must hold for the session. Not a process-wide table, which would be shared
   mutable state, and not one per program, which would break reused IR.
3. **Builders reach the table through what they already hold:** the generator's facts, `IrPipelineContext.symbols` for
   passes, `IrProgram.symbols` for code that works on a program. No thread-local or static "current table".
4. **A symbol exists before its definition.** A call may name a runtime native or a helper a later pass generates;
   interning the name gives it an id either way. The program finds a definition by symbol id (`functionOf(symbol)`), an
   array.
5. **Text stays at the boundaries**, where it must be stable across sessions and builds: the IR and symbol-state codecs
   write the name and intern it on reading, the patch planner and HashLink's symbol table key by name, and diagnostics
   and debug output print it.
6. **Passes that match on a name** (`IrExactTypeFacts.TEST`, the `__map_` family) compare a well-known symbol interned
   once with the table, or read `name` while the family waits for its M3 identity. Prefix tests disappear family by family
   with M3, as ADR 0003 plans.

## Migration

1. **Table.** `IrSymbols` and `IrSymbol`; the session creates the table and hands it to the generator, the pipeline
   context and the program.
2. **Payloads.** `Call`, `StaticClosure` and `InstanceClosure` carry an `IrSymbol`. Creation sites intern, matches read
   `name` or compare a well-known symbol. This step changes no behaviour: the codec writes names, and the compiler
   compiling itself must write the same bytes. It is the large step (about 1,500 sites in about 90 files), done in one
   change because the payload type cannot be half changed.
3. **Definitions by id.** `IrFunction` carries its symbol; the program keeps its functions in an array by symbol id.
4. **Consumers.** The passes that look callees up by name move to arrays by id, one per change, each measured:
   `IrInliner`, `IrTypeAwareWalkState`, `IrReachabilityWalk`, `HlLower`'s function table, the verifier.
5. **Then the next families**, as `COMPILER_DATA_LAYOUT.md` orders them: objects, fields, typer bindings.

## Checks

Each step: the compiler compiling itself writes the same bytes before and after; allocated bytes and main-thread
instructions are measured on the frozen input; the full test driver for step 2, which touches every pass, and targeted
tests for the others. Parity runs once, at the end of step 2, because the Wasm backends match on call names too.

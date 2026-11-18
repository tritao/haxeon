# IR symbols

Status: proposed. Step 1 of the integer identities in `COMPILER_DATA_LAYOUT.md`; the identity side is ADR 0003 §5 (M3).

The IR names what it calls by string: `Call(output, functionName, arguments)`, `StaticClosure`, `InstanceClosure`. Every
pass that needs the callee looks the name up in a map built for it, so the IR passes, assembly and HashLink lowering hash
names throughout. This note replaces those names with interned symbols that carry a dense integer id.

## Decisions

1. **A reference is an `IrSymbol`:** a final class with `id:Int` and `name:String`, one per name, made only by
   `IrSymbol.of`. Two references to the same function are the same object, so they compare by identity and index arrays
   by `id`; `toString` gives the name, so messages that print an instruction still read. The name is the symbol's
   rendered identity today; M3 replaces it with a structured identity (kind, owner, member, type arguments) without
   changing ids or any pass that only uses them.
2. **The table is process-wide and only grows** (`@:processWide`, under a lock). One object per name has to hold for
   every piece of IR that can meet in a program: the session's caches, decoded IR, IR that tests and tools build without a
   session. With a table per session or per program, IR from two tables would mix and identity would silently fail. A name
   always denotes the same symbol, so sharing the table between compiles carries no state from one into the other.
3. **Ids never order output.** They are given in the order names are first seen in the process, so a server's ids differ
   from a one-shot compile's. Tables are indexed by id; anything written is iterated in program order. Building a call
   needs nothing but `IrSymbol.of(name)`, so no table is threaded through the builders.
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

1. **Table.** `IrSymbol` and its process-wide interning.
2. **Payloads.** `Call`, `StaticClosure` and `InstanceClosure` carry an `IrSymbol`. Creation sites intern with `IrSymbol.of`, matches read
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

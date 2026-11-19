# Integer identities across the compiler

Status: proposed 2026-11-19. The id side of ADR 0003 M3 for the whole compiler. `IR_SYMBOLS.md` (callees in the IR) and
`COMPILER_DATA_LAYOUT.md` step 4 (interned types) are its first two families; this note covers the rest and orders the
migration. The query engine's keys (`QUERY_ENGINE.md`, "Keys are typed per kind and interned to dense ids") are these ids.

## Problem

String-keyed maps are the largest cost after the compiler's own code: about 16% of a cold self-compile's cycles, spread
over about 80 classes, none above 1.2%. Since strings cache their map hash (HashLink fork `36197c5`), what remains is the
lookup itself: a hash cell, an entry, the key's characters, each a likely cache miss. Faster maps cannot remove that; fewer
lookups can. A lookup by a dense id is an array read.

The hottest callers (profile of 2026-11-19, before the hash cache), by what they key on:

| Caller | Keyed by |
|---|---|
| `Scope.resolveLocal` (since scanned, `cbb753353`) | local name |
| `IrProgramIndex.isObjectSubtype`, `IrObjectTable.get` | object name |
| `TypingSession.closureWritableNames` (since skipped, `98ec81399`) | binding key `name@offset` |
| `SemanticAssembly.run`, `visibleTypeAliases` | qualified declaration name |
| `DeclarationIndex.resolveNamedType`, `AliasTable.get` | qualified or bare type name |
| `MemberAccess.classField`, `findMethods` | class name, then member name |
| `IrFunctionIndex.new`, `FrontendCompilation.publishFunctions` | function name |
| `SsaBuilder.slotFor`, `CfgVerifier.local` | CFG local name |
| `LexicalStorageAnalysis.declared`, `FlowFacts.resolve` | binding key, binding id text |
| `HlSymbolTable.internString`, `HlLower.requireFunction` | string constant, function name |

## Families

Each family gets one kind of id, one interner and one owner. Two scopes exist:

- **Global** identities name the same thing in every build and every piece of IR that can meet in a process: functions,
  objects, declarations. They are interned in a process-wide table that only grows, under a lock, like `IrSymbol`
  (`IR_SYMBOLS.md`, decision 2). A name always denotes the same id, so sharing the table between compiles carries no state
  from one to another. The tables grow with the names a process has seen; a compile server's growth is reported with its
  resident memory.
- **Local** identities exist only within one function: CFG locals, bindings, SSA values, blocks, registers, labels. They
  are numbered densely by the stage that creates them, from 0 per function, and side tables about them are arrays reused
  across functions (`COMPILER_DATA_LAYOUT.md` steps 1 and 2).

| Family | Scope | Id | Made by | Today |
|---|---|---|---|---|
| Functions | global | `IrSymbol` | `IrSymbol.of` | calls carry it; definitions and consumers still by name |
| Objects (IR classes and records) | global | `IrSymbol` of the object's name | `IrSymbol.of` | by name |
| Types | global | `IrTypeMap` key, then a dense type id | `IrTypeMap` | structural map; no dense id yet |
| Declarations (classes, enums, abstracts, typedefs) | global | `DeclarationId` | a process-wide interner of qualified paths | by qualified name |
| Members | per declaration | index into the declaration's member list | declaration indexing | by member name |
| Bindings (a local's declaration) | local | dense `Int` per function body | `BindingWalker` | `name@offset` strings |
| CFG locals | local | dense `Int` per function | `CfgBuilder` | names (`LoadLocal(_, name)`) |
| SSA values, blocks, registers, labels | local | dense `Int` | their stages | done |

## Rules

1. **Ids never order output.** Global ids are given in the order a process first sees a name, so a server's differ from a
   one-shot compile's. Tables are indexed by id; anything written, listed or iterated for output goes in program order or
   is sorted by name.
2. **Text stays at the boundaries:** codecs and the IR state digest, HashLink's symbol and patch tables, diagnostics,
   debug output, and the names the generated program itself carries (reflection, class names). Each keeps reading the
   identity's name.
3. **Outputs hold ids, not names** (ADR 0003 decision 14), once a family has its id; a query's output then stays valid
   across builds as long as the id's name does.
4. **One family at a time, each byte-identical.** A family's payload type changes in one step, since it cannot be half
   changed; its consumers then move from maps to arrays one per change, each measured.
5. **Plain Haxe.** Ids are `Int`s or final classes holding one, so both builds of the compiler gain (ADR 0006 is not
   needed). Where a type wraps an id, it is an `abstract` over `Int` with inline accessors, so it costs nothing.

## Migration

Ordered by measured cost and by what each step unblocks. Every stage: the compiler compiling itself writes the same
bytes; allocation and main-thread instructions and cycles on the frozen input are in the commit; targeted tests for the
code touched; Wasm parity when a stage touches the typer or a pass the Wasm backends share.

1. **IR definitions by symbol id** (`IR_SYMBOLS.md` steps 3 and 4). `IrFunction` and `IrObject` carry their symbol; the
   program keeps functions and objects in arrays by id. Consumers move: `IrProgramIndex`, `IrObjectTable`,
   `IrFunctionIndex`, `HlLower.requireFunction`, `FrontendCompilation.publishFunctions`, the inliner, the reachability
   walks.
2. **Function-local names as numbers.** `CfgBuilder` numbers locals and the CFG carries the number (`LoadLocal(_, local)`),
   so `SsaBuilder.slotFor` and `CfgVerifier.local` index arrays and `SsaBuilder`'s slot map goes. `BindingWalker` numbers
   bindings per body, and `LexicalStorageAnalysis`, `BindingStoragePlan`, `FlowFacts` and the scope's binding ids key
   by that number; the `name@offset` text stays only where a diagnostic or a cell class name needs it.
3. **Declarations.** A `DeclarationId` interner over qualified paths; the typer's declaration tables (`classDecls` and
   its siblings, `DeclarationIndex`, `AliasTable`, `SemanticAssembly`'s visible sets) become arrays by id. Lookups that
   start from source text (a type name in an annotation) resolve the text to an id once, at the name's resolution.
4. **Members by index.** A declaration's members are a list, and `MemberAccess` finds a member by name once per call
   site, then holds its index.
5. **Dense type ids**, once consumers want arrays indexed by type (`COMPILER_DATA_LAYOUT.md` step 4).
6. **`CompilerType` carrying ids.** `TInstance(kind, name, arguments)` carries a name today, which every typer stage
   hashes. Carrying a `DeclarationId` touches every type match in the typer; it is its own design step after 3, sequenced
   with the typer's move onto the query engine (`QUERY_ENGINE.md` step 3).

Stages 1 and 2 are independent and can go in either order; 3 comes before 4 and 6.

## What it does not change

The generated program, its symbol names, debug information and patches; the IR and symbol-state codecs' formats; how
diagnostics read. Structured identities for generated entities (ADR 0003 decision 5: a kind plus typed fields instead of
a `$generic:` name) are the other half of M3; they replace a family's name text behind the same id, so they can follow
each family without touching its consumers again.

## Open questions

- **Declaration renames in a session.** A renamed class gets a new id; the old one stays in the table, unused. Whether a
  server should ever compact its tables is a question for when growth is measured.
- **Thread safety.** The global interners take a lock, as `IrSymbol` does. Parsing on several threads (`--parse-threads`)
  interns names per thread already (`NameTable`); if declaration interning shows up under contention, it can take the
  same per-thread front.

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
| `IrLocalsBuilder.load`/`store`, `IrSsaVariables.variable` | local name |
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
| Types | global | `IrTypeIds` id | `IrTypeIds.id` | bodies hold ids from one process-wide table; see "Types" below |
| Declarations (classes, enums, abstracts, typedefs) | global | `DeclarationId` | a process-wide interner of qualified paths | by qualified name |
| Members | per declaration | index into the declaration's member list | declaration indexing | by member name |
| Bindings (a local's declaration) | local | dense `Int` per function body | `BindingWalker` | `name@offset` strings |
| Locals while IR is generated | local | dense `Int` per function | `IrSsaVariables` | names, numbered at first use |
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
2. **Function-local names as numbers.** The IR generator reads and writes locals by name (`IrLocalsBuilder.load`,
   `store`), and `IrSsaVariables` numbers each name at its first use; the generator would pass the binding's number
   instead, so no local is looked up by name. `BindingWalker` numbers
   bindings per body, and `LexicalStorageAnalysis`, `BindingStoragePlan`, `FlowFacts` and the scope's binding ids key
   by that number; the `name@offset` text stays only where a diagnostic or a cell class name needs it.
3. **Declarations.** A `DeclarationId` interner over qualified paths; the typer's declaration tables (`classDecls` and
   its siblings, `DeclarationIndex`, `AliasTable`, `SemanticAssembly`'s visible sets) become arrays by id. Lookups that
   start from source text (a type name in an annotation) resolve the text to an id once, at the name's resolution.
4. **Members by index.** A declaration's members are a list, and `MemberAccess` finds a member by name once per call
   site, then holds its index.
5. **Type ids** for every consumer that has one, in the steps of "Types" below.
6. **`CompilerType` carrying ids.** `TInstance(kind, name, arguments)` carries a name today, which every typer stage
   hashes. Carrying a `DeclarationId` touches every type match in the typer; it is its own design step after 3, sequenced
   with the typer's move onto the query engine (`QUERY_ENGINE.md` step 3).

Stages 1 and 2 are independent and can go in either order; 3 comes before 4 and 6.

## Types

Status: steps 1 to 3 landed 2026-11-24. This settles the "canonical IR types" question: types get ids, not interned values.

**What it is worth.** Sampled on the frozen input before step 1, the work done on an `IrType`'s structure (hashing and
probing `IrTypeMap`, `IrTypeIdentity.same` and `sameList`, the `TypeKey` and `HlSymbolTable.typeKey` texts) was 2.9% of a
cold compile, 3.0% of a signature edit and 3.0% of a body edit. Writing object field type names in `CanonicalIrCodec`
(another 2.9% of a body edit) is text a digest needs, which no identity removes. The callers were few: HashLink lowering
looking up each register's type twice (`HlSymbolTable.internType`, `HlRequestKeys`), the reachability edges building a
`TypeKey` text per value, `IrBodyBuilder` numbering the types of a function it encodes, and `IrWalkRecord` comparing the
type lists a kept walk was given.

**Representation: ids only.** The `IrType` enum stays the form code builds and matches; the identity is an `Int` from
`IrTypeIds`. Interned enum values cannot be the identity: in Haxeon a payload enum value has no reference identity (`==`
on one is declared value equality and needs `Equatable`, `__reference_equal` takes no enum, and inline enum lowering may
store a value unboxed), so equal canonical instances could not be told apart from equal copies. A class wrapper holding
an id and the shape would have identity but turns every match into `switch type.shape`: about 150 files and 600
construction sites, for at most the 3% above. With ids only, nothing that builds or matches a type changes. Bodies
already hold their types as ids (`IR_CORE_COLUMNS.md`), and the hot consumers read types from bodies, so they key by the
id they already have: an array read instead of a structural hash. A type that never enters a body keeps the structural
`IrTypeMap`, which stays for that.

**Construction.** Ids are given where a type enters a body, as today (`IrBodyBuilder`, a pass's `typeId`); no
construction site goes through a pool. The table keeps the instance it was first given and hands it back for the id, so
the types read from bodies are shared. That instance is the table's own: its parts are interned first and it is rebuilt
from their instances, its argument list a copy, so a caller that changes a list it passed cannot change a key, and a
type's parts have ids too.

**Lifetime and threads.** Before step 2 the session's inline cache owned the table every program body used
(`IrInlineCache.types`), and private builders made their own (`IrPassScratch`, `HlLowerScratch`, `HlcModule`, tests), so
an id meant something only with its table: a cache by id had to check the table, and bodies made with another table were
refused (`IrFunction.bodyIn`, `IrStage.checkTables`, `IrInliner.sameTypeIds`). Step 2 made the table process-wide, as
`IrSymbol` is: ids only grow and always denote the same type, interning takes a lock (the compile and census threads both
encode), and `type(id)` reads the id's array without one. A server then keeps ids across builds with nothing to translate. It
grows by one entry per distinct type the process has seen; an edit that renumbers lambdas adds new names and so new
types. Like `IrSymbol` it is never compacted, and its growth shows in the server's live data.

**Output independence.** Ids are given in the order types are first seen, which differs between a one-shot compile and a
server and changes with interning order, so rule 1 applies: ids index tables and never order output. What is written
stays derived from the structure: names and keys from `IrTypeIdentity.text` and `TypeKey`, persisted types through
`IrTypeCodec` (no codec writes a type id), runtime type discriminators from `IrTypeIdentity.id` (a hash of the text), and
HashLink type indices from `HlSymbolTable` in the order lowering asks, which is program order; a cache by id only
remembers an answer. The self-compile's bytes are the check for each step.

**Steps.** Each lands alone and keeps the self-compile byte-identical.

1. *Consumers of bodies key by the body's ids* (done): HashLink lowering keeps, per type id, a register type's HashLink
   index and request number (`HlLower.internTypeId`); the reachability edges deduplicate the types values mention by
   id instead of by `TypeKey` text. Three files. Body edit -2.2% and signature edit -2.3% main-thread instructions, cold
   allocation -2.2%, one-shot self-compile -0.66% instructions.
2. *One process-wide table* (done). `IrTypeIds` is static like `IrSymbol` and owns its instances; `IrBody.types`, the
   table parameters, the table checks and the private tables are gone, and `IrFunction.bodyIn(types)` is
   `encodedBody()`. 49 compiler files and 19 tests, most of them a parameter removed. Two changes from the plan, both
   for speed: reads are one array read, not `IrSymbol`'s chunks (an array that is replaced by a longer copy when full,
   under the lock; the second indirection of chunks cost 0.6% of a one-shot self-compile), and the types without parts
   have fixed first ids, so most lookups take neither the lock nor a hash. One-shot self-compile -0.08% instructions;
   no-op -0.6%, body edit -0.5%, signature edit -0.3% main-thread instructions; allocation and server live data
   unchanged (the session's table was already kept for the session).
3. *Server caches by id* (done). `HlSymbolTable.typeIndex` is an array by id, shared and copied with `typeIndices` in the
   table's copy-on-write groups, so a server's next build keeps it, and dropped by `renameTypes`; `HlRequestKeys.types`,
   `references` and `typeKeys` are arrays by id, and type requests name their type by id (`TypeOf`, `RefTo`), so step
   1's per-lowering arrays are gone; `IrSharedRuntimeCalls` keeps a call by its function type's id. Seven files. One
   change from the plan: `RuntimeAbi.writeKey` stays, since the types it writes are declarations' (object fields,
   signatures), which have no id, and finding one is a structural hash that costs what writing the text does; it moves
   with step 5. Body edit -1.3% and signature edit -0.2% main-thread instructions, allocation -0.3%.
4. *Kept records by id.* The escape reach's stores and `IrWalkRecord`'s given types as id lists, so a kept walk
   compares integers (`IrTypeIdentity.sameList` was 1.1% of a body edit), with `IrTypeAwareWalk` and `IrVerifyMemo`.
   About six files.
5. *Declarations by id* (`IrValue.type`, function results, object fields), only if a profile after step 4 still
   shows structural type work: it is the IR core's declaration side and touches most passes.

Separately from ids, the copies of type equality (`IrVerifier.sameType`, `HlModuleAssembler.sameType`, `Type.enumEq`
on IR types) can become `IrTypeIdentity.same`.

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

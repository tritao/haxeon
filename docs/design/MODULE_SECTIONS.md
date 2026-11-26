# Module sections and load-time linking (design note)

Status: designed 2026-11-25; the open questions are decided (section 9). Slices 1, 2 and 3 have landed (section 8): the
fork's loader links sections, every plain HashLink build writes them (slice 2b made them the default and removed the dense
plain path, "As built in slice 2b"), every reader of modules reads them, and a warm build keeps every section whose encoding
would read the same and its functions as they were lowered, with no link or replay (section 3, "As built in slice 3a", "As
built in slice 3b"). Slice 4 is planned in four parts (section 8, "Slice 4 plan"); 4a has landed: the fork links patches made
of sections ("As built in slice 4a"). Live builds stay on HLB 8 until 4b. The user's decision: per-module sections and
load-time linking replace "stable output indices" ([COMPILER_FOUNDATIONS.md](COMPILER_FOUNDATIONS.md) item 3,
[QUERY_ENGINE.md](QUERY_ENGINE.md) row B). Plain output needs the fork's VM: stock HashLink does not read HLB 9, which the
user accepted.

**Problem.** HashLink's function, type, global, string and constant tables are dense and numbered in first-use order, so a
cold build's index depends on everything lowered before it. A warm build that adds an entry renumbers, relinks and
re-encodes everything after it (QUERY_ENGINE.md, "Stable output indices": 7,922 unchanged functions relinked on a
signature edit). A stable order still shifts dense indices, and slack ranges are a capacity rule leaking into the format.

**Decision.** The compiler writes one section per module with module-local tables. A section names what it uses from other
modules by key, never by global index. The fork's loader links the sections at load time into the dense `hl_code` the JIT,
runtime and debugger already use. A warm build re-encodes only the modules that changed. Nothing global shifts, because
the compiler no longer has global indices.

## Measured inputs

Taken from the compiler-server module (`out/self-hosting/entry-compiler.tools.CompilerServer.hl`, a 2026-11-17 build of
27.9 MB from before LZ4). A scratch harness linked against the fork's `libhl.a` read it; the harness is not committed.

| | |
|---|---|
| Tables | 7,860 functions, 8,848 types (6,190 function types, 1,847 objects, 79 enums, 293 refs, 11 virtuals), 10,260 globals (8,018 of them literal constants), 17,806 strings (572 KB), 335 natives, 469 debug files |
| Load | `hl_code_read` takes 80 ms (best of 5). `hl … --version` takes 1.0 s wall, and almost all of it is the JIT |
| Sections | 458. Each function is assigned to the source file of its first opcode, which approximates its module |
| Cross-section references | 16,010 imports: 3,713 functions, 6,783 natives, 1,242 globals, 4,272 nominal types. The largest section has 216 |
| Duplication if each section holds its own copy | Literal constants 12,742 vs 8,018 (×1.59). Direct type references 23,523 vs 8,848 (×2.7), of which 18,455 are structural |
| Simulated link | Inserting about 11.5 k export keys and looking up 16 k imports, 47 k structural type keys and 12.7 k constants takes 7–9 ms. Remapping 2.3 M operands takes 2 ms |

## 1. Format (HLB 9)

The file has a header (`HLB`, version 9, flags), then a section directory, then the sections, then the program record:

- **Section directory.** For each section: its module path, byte offset, length and a content digest (the patch and the
  reuse key).
- **Program record.** The entry function's key and the section that holds the boot code (see 3).

The order of the sections is fixed: modules in path order (`StaticInitializationOrder.compareModules`), then the shared
section. A section's bytes depend only on its own module's lowered code and definitions, and on the keys of what it imports.

**A section** holds the following parts. Indices inside a section are local, and its tables are ordered by first use in
declaration order.

- **Names:** a UTF-8 pool. A key is a pair of (module path, member) indices into the pool.
- **Imports:**
  - functions, by key, with the function type the importer expects;
  - globals, by key, with their expected type;
  - nominal types, by key and kind;
  - natives, by `(lib, name)` with their type.
- **Types.** One local table with three kinds of entry:
  - **Owned nominal definitions:** the module's classes, enums, interfaces (virtuals with their nominal identity, HLB 8)
    and closure environments. They are exported under their name.
  - **Structural shapes:** function, ref, null, packed and abstract-by-name types, whose children are local type
    indices.
  - **Shared definitions:** anonymous-structure objects keyed by `SemanticSignature.anonymousTypeName`, and the String
    object. Every section that uses one defines it.
- **Globals:**
  - owned globals (statics, class value globals, enum constant caches), exported by key;
  - literal constants, keyed by their content (the `constants` entry: type and field values).
- **Ints, floats, bytes and strings:** local tables, deduplicated per section.
- **Functions:** owned functions in declaration order, each exported by key, followed by its type, registers, opcodes and
  debug rows.
  - The local function-index space is the imports, then the natives, then the owned functions, so the existing operand
    encoding stays as it is.
  - The debug rows hold positions relative to the declaration (slice A), with the declaration's anchor in the function
    record.
- **Debug:** local debug files, opcode source spans by local function index, and source snapshots by content hash. The
  section has no function-identity table, because a function's key is its identity and display names are derived from it.

**Versioning.** HLB 9 is the sectioned format. Each section carries its own `kind:version`, and the debug sub-sections
keep their per-kind versions (`docs/internals/HLB_DEBUG_SECTIONS.md`). The VM keeps the dense reader for HLB ≤ 8, for
stock-Haxe bytecode (≤ 5) and older bootstraps. HLB 6 to 8 are already fork-only, so stock HashLink loses nothing.

**Type identity across modules.** Types are unified when the module loads:

- A nominal type has one owning section. Every other section imports it.
- A structural type is hash-consed bottom-up on (kind, global ids of its children). These types are acyclic except
  through nominal types, so one pass in table order resolves them.
- A shared definition is kept from the first section that defines it. Every later definition must be equal after
  mapping, or the load fails (see 2).

No process-local type id appears in a key: keys are text, as INTEGER_IDENTITIES.md rule 2 already requires for
HashLink's tables.

A recursive anonymous type (`typedef Node = {next:Node}`) refers to itself through structural types, which would make
them cyclic. Such a virtual or object is a shared definition, keyed by its anonymous type name, so the cycle passes
through a keyed entry as it passes through a nominal type, and the structural types stay acyclic.

**Deduplication.** The loader deduplicates strings and literal-constant globals by content, and ints, floats and bytes by
value. The runtime therefore holds one global per literal, as it does today.

**Not imports.** Field indices (`OField`, `OSetField`) and prototype slots (`OCallMethod`) stay as numbers. They are
layout facts that lowering already records as reads (`HlLoweringView`), not table positions.

### Encoding

Decided with slice 1, where the text above leaves it open. Numbers are HashLink's index encoding (`uindex`) unless said
otherwise; a text is its UTF-8 length then its bytes; a string table is HLB 8's (the byte size as an i32, the
NUL-terminated strings, then each length).

- **Header.** `HLB`, the byte 9, flags (bit 0: debug information), the section count.
- **Directory.** For each section: its module path (a text, unique and not empty), its offset and length (i32, from the
  start of the section area), and its digest (8 bytes, the compiler's 64-bit reuse key, which the loader does not read).
- **Program record**, right after the directory: the entry function's key, two texts. The section area follows it and
  runs to the end of the file. The record comes before the sections so the file reads front to back, and offsets count
  from the area so they do not depend on the record. It names no boot section: the entry's key names its module.
- **A section** starts with its kind, version and flags. Kind 1 version 1 is a module's code; flag bit 0 marks an LZ4
  payload (the decoded size, then one LZ4 block, as for debug sections), so import keys and duplicated literals compress.
  The payload:
  1. Counts: names, function imports, global imports, type imports, natives, types, owned globals, functions, ints,
     floats, strings, bytes, constants, debug files.
  2. The names, a string table: module paths, members, native libraries and names.
  3. The interface. Function and global imports (module, member, expected local type), type imports (module, member, kind
     byte), natives (lib, name, local type). One head per local type: its role (structural, owned or shared), its kind byte
     and, for an owned or shared type, its key member. One head per owned global and per function: its member and local
     type. The loader reads every section's interface before any body.
  4. The body. Ints (i32), floats (f64), strings (a string table), bytes (each a length and its bytes), debug files (a
     string table), the type bodies in HLB 8's encoding with local indices, the constants (local type, field count, field
     values), then each function's registers, opcodes, debug lines and assignments as HLB 8 has them, with local indices.
- **Index spaces.** Types: the type imports, then the type table. Globals: the global imports, the owned globals, then
  the constants. Functions: the function imports, the natives, then the owned functions.
- **Roles.** A structural type refers only to structural entries before it, but to any import or definition. Owned types
  are objects, structs, enums, enum tags and virtuals; shared definitions are objects, structs, virtuals and enums, and
  their key's module is empty. A type definition refers only to imported or owned globals (a class value, an enum's
  constant caches), never to a constant; a constant refers only to the constants before it.
- **Natives** are keyed by (lib, name). Every section that declares one must give it the same type.
- **Numbering**, which the compiler's static link (slice 2) reproduces: owned and shared types in section order, then the
  structural ones in order of first appearance; functions in section and declaration order, then the natives in order of
  first declaration; owned globals, then the distinct constants in order of first appearance; strings, ints, floats,
  bytes and debug files in order of first appearance.
- **Names and identities.** A function's key member is its name in the linked code (`function_names`): members are
  qualified declaration paths, readable alone. Its stable id is its findex until the loader mints ids (slice 4).
- **Debug.** Each function carries its lines and assignments as in HLB 8, with section-local files. After its functions a
  section has its debug sub-sections: a count, then each as HLB 8's debug sections are (kind, version, flags, size,
  payload), never compressed on their own since the section's LZ4 covers them. Slice 2 writes two, in development builds:
  the opcode source spans of its functions (kind 2 version 2, the function numbered by its index among the section's
  functions) and source snapshots (kind 3 version 1). A file's snapshot is in its module's section, else in the first
  section whose code shows it. There is no function-identity sub-section: a function's identity is its key. The loader
  checks the sub-sections and steps over them; tools read them through the static link (section 5).

**What slice 2 writes** (`HlSectionWriter`):

- **Sections.** One per module of the build that owns anything, named by the module's path (`ModuleState.name`, never the
  file's path, which can be absolute), in `compareModules` order, then the shared section `$shared`, which no module path
  can be. Sections are LZ4-compressed (fast level) where the natives are; the Haxe interpreter stores them as they are.
- **Homes** were taken from the dense module the lowering makes: a function went with the module of the file most of its
  positions count from, a type with its first method or the first function whose registers hold it, a global with its
  first user. Slice 3a replaced these first-user rules with homes by declaration (section 3, "As built in slice 3a").
- **Keys.** Functions by their names (`HlCode.functionNames`); objects, structs and enums by their names, interfaces by
  their nominal identity, an enum tag as `enum-tag:` and its enum's name; globals by their symbol names
  (`HlCode.globalNames`), a class value as `$class:` and its type's name.
- **Numbering.** The build numbers its functions as the loader will (`HlSectionOutput.linkedIndices`): `.functions`, the
  build's stable ids (a function's linked index) and its `.hli` use it. A native no section declares is left out.

**Measured with slice 2** on the compiler's release self-compile (11,651 functions; one performance core):

- 567 sections; `$shared` is the largest, 0.41 MB of 9.17 MB stored, 0.22 MB compressed.
- Size: 5.30 MB with LZ4 sections, 9.17 MB stored, against 6.13 MB for HLB 8 (whose identities, about 0.37 MB, are
  compressed). Uncompressed, the section names (import keys and owned members, text) take 2.73 MB; instructions shrink from
  3.67 MB to 3.36 MB with local indices.
- Load: starting the compiler (load, link, JIT) takes 4.517 G instructions against 4.367 G (+3.4%); stored sections take
  4.496 G, so LZ4 costs about 21 M. Wall 0.94 s against 0.90 s.
- The static link of the file takes 1.1 s on node (the debugger) and well under a second on HashLink.

## 2. Loader

`hl_code_link(data, size, &error)` in `vendor/hashlink/src/link.c`. It returns the same `hl_code` that `hl_code_read`
builds, so `hl_module_alloc`, `hl_module_init`, the JIT, `hl_module_init_aot`, the debugger and the profiler do not
change. `hl_code_read` dispatches to it on the version byte, so `main.c`, `hlruntime.c`, plugins and `hldump` read both
formats without a change of their own.

As built, the steps below run in three passes over the sections: the interfaces (step 2, and natives), then per section
its imports, literals and types (steps 3 and 4) followed by the import type checks of step 5, then per section its
constants and functions (step 5).

1. **Directory.** Read the counts of every section and size the global arrays and hash tables.
2. **Exports.** Give each owned function a findex in section order, with natives after all functions, deduplicated by
   `(lib, name)`. Give owned globals and owned nominal types their slots. All of these go into open-addressed tables
   keyed by name (about 30 k entries for the compiler).
3. **Per-section maps.** Build a local-to-global array per table:
   - imports are resolved by lookup;
   - structural types are hash-consed;
   - shared definitions are checked for equality;
   - strings and constants are deduplicated by content.
4. **Types.** Fill the `hl_type`s through the maps. Object fields, `super`, prototypes and bindings resolve the same way.
5. **Functions.** Read opcodes as `hl_read_opcode` does, but map each table operand through its section's map. A
   per-opcode schema names which operands are table references, as `HlOpcodeSchema` does on the compiler side. Then
   check each import's expected type against the definition's: after unification this is a pointer compare.
6. **Debug.** Deduplicate debug files by path and remap the per-opcode file indices. Fill `function_names` from the keys.
   The loader also gives each key a stable id (see 4).

**Cost.** Linear in entries plus operands. Estimated at about 10–15 ms for the compiler (simulated 9–11 ms), against
80 ms to read and about 1 s to JIT. Measured with slice 1 on a synthetic image of the server's size (`code_link --bench`:
458 sections, 16,010 imports, 7,860 functions, 904 k opcodes where the server has 760 k, 2.34 M operands; a performance
core of a loaded machine):
238 M instructions and 72 M cycles a link, against 183 M instructions and 91 M cycles to read the 27.9 MB dense file. The
first link in a process takes 58–88 ms of wall time and the first dense read 78–99 ms, both mostly page faults. The link
replaces the read rather than adding to it. An AOT image is linked by the compiler (see 5), so it costs nothing at load. While
loaded, the link state (the key tables, about 1–2 MB, an estimate) is kept only by modules that accept patches.

**Failures.** Each is a load error that names the section (module), the key, and the other section involved where there
is one:

- a malformed section (bounds or counts);
- a missing import: "`a.B` imports function `c.D.f`, which no section defines";
- a duplicate export;
- a conflicting shared definition;
- an import whose type differs from the definition's;
- a missing entry function.

None of these can come from a correct compiler. The compiler-side linker (see 5) runs the same checks under
`--check-reuse` and in the tests.

## 3. Compiler side

- **Ownership.** Each `IrFunction` gets its home module from the declaration it is generated from (as built: from its name,
  below):
  - methods, lambdas, `$dispatch:`, `$generic` and similar functions go to the module of the declaration they serve;
  - unowned generated functions (`$anon` printers: 512 of 7,860; shared runtime helpers) go to one shared section.
- **Lowering.** Lowering becomes relocatable. `HlLower` interns into a per-function reference table of keys; the request
  keys `HlLoweredFunction` already records are that table. It no longer interns into a global `HlSymbolTable`.
  `HlSymbolTable` keeps only object layout and type construction, and builds a section's type definitions.
- **Section writer.** `HlSectionWriter` merges the reference tables of a module's functions, in declaration order, into
  the section's tables, and encodes each function with a local remap. This is the operand walk the writer already does.
- **The engine's view (QUERY_ENGINE.md slice 7).** `ModuleSection(module)` is a computed query. It reads that module's
  per-function lowering memos, its type and global definitions and its debug memos. Its value is the bytes, digested by
  content. The file is the root query: directory, sections and program record, reused section by section. Early cutoff
  happens at the section: a body edit that lowers to the same code stops there.
- **Cold build.** The same queries, all computed. Warm and cold give the same bytes by construction, so no replay is needed.
- **Boot code.** It goes in the shared section, as a small whole-program query over the program's init order:
  - The `__init` boot functions (`IrProgramAssembler.staticInitializersFrom`) call each class's `__init__` and
    initializer parts through imports, in `StaticInitializationOrder`.
  - The entry function calls `__init`, then `main`.
  - Reflection registration is code in those functions, and class value globals are exported by their owners, so no
    separate whole-program table is needed.
  - Initializer parts are bounded parts today, which can mix classes. Making them per class and moving them to their
    owning modules keeps a static-initializer edit inside its module. Until then such an edit re-encodes the shared section.

### As built in slice 3a

- **Homes by declaration** (`HlSectionWriter.declaringModule`). A name is its declaration's identity, so a home is found
  from the name alone, against the frontend's index of declared types (`DeclarationOwners`) and the build's module paths:
  the first `:`-separated part of the name, before its type arguments, layout or a lambda's place (`[<{(#@`), whose
  longest dotted prefix names a declared type or a module decides. `pkg.Type.method`, `$lambda:pkg.Type.method:...`,
  `$generic:pkg.Type.method[...]<...>`, `$generic:$owner:pkg.Map[...]<...>.get`, `$dispatch:pkg.Type.method`,
  `$nullable-scalar:arguments:pkg.Type.method`, `$lambda-env:...` and `$cell:...` types and `pkg.Mod$fields.x` all go with
  the module of what they serve. Nothing else is read, so no edit moves an entry from one section to another unless it
  moves a declaration. Types: a class, enum or interface by its name, an enum tag with its enum; globals: a class value or
  enum constant cache with its type, a static by its name; a source snapshot with the module of its file. `$anon:` printers
  (decision 2), runtime helpers (`__array_push_ref$shared:...`), boot functions and the `$dynamic-structure:` and
  `$enum-*` helpers named by digest or number serve no declaration and go to `$shared`. The IR carries no home field: the
  name already is one, and the IR stages stay as they are.
  - On the compiler's release self-compile: 584 sections; `$shared` holds 1,155 of 11,844 functions (700 printers, 349
    runtime helpers, the 20 initializer parts, the rest generated helpers named by digest) and 702 globals (the printers'
    class values), and no nominal type.
- **The section memo** (`HlSectionCache`, kept with the lowered functions in `HlLoweredCache.sections`, so it follows the
  candidate build). Per section path it keeps the bytes, their digest, the dense tables the encoding named and what the
  encoding read (`HlSectionReads`): its functions by identity with their names and the places of their anchors, its owned
  types and globals, its snapshots, and for each entry it names what that entry is in the dense module, its key and its
  home. A warm build reads those again from the new module (`HlSectionWriter.readInputs`, a pass over the section's tables,
  not its code) and keeps the section when they read the same; otherwise it encodes it, and keeps the old bytes when they
  come out equal, which is the early cutoff. Homes are memoized by name while the declarations and module paths are the
  same (a check of a few thousand entries a build), and validation marks follow the function objects as the dense writer's
  do. `--check-reuse` encodes every kept section again and requires the same bytes.
  - Slice 7 takes it over as is: a section is one computed result keyed by module, its value the bytes, its reads the
    values above (a computed kind per stage, not per section), and the file the root that reuses section by section.
- **Signature edits.** A plain build relinked every function whose dense indices moved (`HlLink`), into new function
  objects, so the memo encoded their sections again although most came out the same: on the self-compile's signature
  edit 503 of 522 sections were encoded and 14 changed. Slice 3b keeps those functions the same objects.
- **Measured** (the compile server on the frozen self-compile input, main-thread instructions, release, perf-guard's
  edits), `--module-sections` against dense HLB 8: the body edit 2.209 G against 2.291 G (slice 2a: 4.257 G), one section
  of 522 encoded; the no-op 0.784 G against 0.798 G (the backend does not run); the signature edit 19.06 G against
  18.35 G (slice 2a: 19.29 G). The output is 4.36 MB against 5.09 MB.
- **Loader.** Keys and strings are hashed eight bytes a step and once per key, and structural types are read in one pass:
  a link of the compiler's release module (5.26 MB against 6.20 MB dense) takes 324 M instructions instead of 357 M,
  against 202 M to read the dense module, and starting the compiler (load, link, JIT) 4.519 G against 4.404 G dense
  (+2.6%, was +3.4%). What is left is the opcode reading with its remap (+24 M), LZ4 (22 M), the key and string tables and
  structural interning.

### As built in slice 3b

- **Functions kept as they were lowered** (`HlCode.relocations`, `HlRelocations`). A sectioned build keeps each function whose
  IR is the one an earlier build lowered, and whose facts and positions (fields, slots) still hold, as the very object that
  build made, with that build's indices: its references are its requests (`HlLoweredFunction.keys`), and its code names each
  by the answer it got (`answers`). `HlLink.relocate` asks them of this build's tables, and only when an answer differs says
  where the entry is now (`HlRemap`); nothing is rewritten, and nothing makes the tables what a cold build's order would. The
  section writer maps each index a function's code uses through that to the section's (`HlLoweredFunction.uses`, what the
  code names in the order the encoding meets it, made once per function). The design's per-function reference table is
  these requests; local positions in it would have meant rewriting every function once more when it is lowered.
- **Tables extend** (`HlLoweredTables`). A build with the last one's metadata and function layout extends that build's tables
  and keeps its answers, so a kept function asks nothing and its indices are the same: a run of such builds (`chain`) never
  changes an entry once made, and an entry no function names any more stays until a build starts a new run (another
  metadata or layout, as a signature edit makes).
- **The memo in section terms.** A section's reads are its own inputs (`readOwn`: its functions, their names, their anchors'
  line and file, with opcode spans also offset and hash, and its snapshots) and what it names (`readNamed`: the section index
  of everything each function names, then the entries of its tables in the section's indices, with their keys and homes),
  none of which depends on how the dense tables are numbered. A section of the same run whose functions are the same objects
  with the same indices, whose imported functions have the same types and whose own inputs read the same is kept without
  being collected (`unchanged`); else it is collected and kept when both read the same; else it is encoded, and kept as the
  same bytes when they come out equal. A function lowered again to the same code up to the indices it names and its anchors
  (`HlFunctionEquality.difference` without `indexed`, then its locations as the section encodes them) reads the same, so a
  signature edit encodes only the sections whose bytes change.
- **`--check-reuse`** encodes every kept section again, compares the build's sections with those of a build lowered afresh
  (their dense tables are numbered as each build asked for entries, so the dense modules are not compared), and checks that
  each freshly lowered function's answers are what the tables answer, in place of the replay check (`verifyLinking`).
- **Measured** (as for slice 3a), `--module-sections` against dense HLB 8: the body edit 2.183 G against 2.238 G (slice 3a:
  2.209 G against 2.291 G) and back 2.079 G against 2.220 G, one section of 522 encoded; the signature edit 17.73 G against
  18.30 G (slice 3a: 19.06 G against 18.35 G), 14 sections encoded and 14 changed. A cold sectioned build is byte-identical to slice 3a's, and the dense path to
  the one before.
- **Left for after slice 2b.** The dense path still linked and replayed, so that a warm HLB 8 build was byte-identical to a
  cold one. Slice 2b deleted it (below).

### As built in slice 2b

- **The default.** Every plain HashLink build writes sections: the session's (`HashLinkBackendSession`, whenever the build is
  not live), the CLI's one-shot build, `haxeon run` and the stateless `HlBackend`, which has no modules and so writes one
  shared section. A live build writes dense HLB 8 until slice 4. With no dense plain path left, `--module-sections`,
  `CompileOptions.moduleSections`, `HlModuleAssembler.moduleSections`, the test driver's `--module-sections` and the
  `driver-sections` suite went rather than being inverted (`driver-checked` runs the same builds). Plain output needs the
  fork's VM; the fork still reads HLB 8 and stock-Haxe bytecode.
- **One lowering switch.** `HlLower` is relocatable in an assembly that does not trust its cache: it records each function's
  requests and keeps the functions as lowered (`HlCode.relocations`). A live build, which trusts its cache, and a lowering by
  itself (`HlLower.lower`, what tests write as HLB 8) are not. `HlWriter.encode` refuses a relocatable module, so whatever
  writes a plain build takes its bytes through `BackendArtifacts.hashLinkBytes` (the REPL, the language service, the tests that
  compared or ran a plain build's dense encoding).
- **Deleted**, about −650 lines of compiler: `HlLinkRecord` and `HlKeptTables`, `HlLink.link`, the kept-table branches of
  `HlLower.lowerProgramWithNatives` (the recorded String constants, `settleKept`, `settleTables`, the retry with fresh tables),
  `verifyLinking` and `sameReplayTable`, `HlSymbolTable.replaceLeaf`, `truncate`, `clear`, `typesName` and
  `stringConstantAt`, and the interning flags of `HlRequestKeys`. `HlLoweredCache.tables` is now the extended tables
  (`HlLoweredTables`).
- **Kept for slice 4.** Live builds still assemble on a published layout: the trusted lowered cache (`HlModuleAssembler.livePatching`,
  `published`), `HlSymbolTable`'s published prefix and `fork`/`shareFrom`/`writable` groups (which the extended tables also
  use), `HlFunctionCache` slots and stable ids, the dense `HlWriter` with `HlWriterCache`, `HlPatchWriter`/`HlPatchReader`,
  the persistence codecs and `HlRuntimeIdentity`'s id maps. They go when live patches are made of sections. `HlRemap`,
  `HlRequestAnswers` and `HlLink.relocate`/`rewritten` stay: they are how a kept function is found in a build's tables.
- **Bases.** The checked-in compiler (`bootstrap/compiler.hl`) is a module of sections, refreshed to the fixed point of these
  sources (5.29 MB against 5.75 MB for its last dense refresh), so it needs the fork's VM (`bootstrap-loads` checks it loads).
  The self-compile oracle compares HLB 9 bytes.

## 4. Live patching

- **Patch format.** A patch (HLP 12) holds:
  - the base and target revisions;
  - the sections it replaces, in the same encoding as HLB 9;
  - the sections it removes;
  - renames: `X → X~retired<rev>` for a moved signature (`HlModuleAssembler.moveChangedSignatures`), so the old slot keeps
    its closures and its adapter;
  - guards, migrations and source snapshots, as in HLP 11 but keyed by name.

  The prefix hashes, the symbols section, stable-id relocations and the added-functions list go
  (`HlPatchWriter.hash*`, `hlpatch.c` `hash_*_prefix`).
- **Patch loader.** It links the new sections against the live module's link state, as follows:
  - **Functions:** an existing key keeps its slot and goes through `hl_module_redirect_slot`, and a new key appends into
    `HL_PATCH_FUNCTION_RESERVE`.
  - **New natives** append the same way. Today they force a reload, because they sit before every slot.
  - **Types and globals:** the same, within the type and global reserves.
  - **A nominal type redefined** is accepted only under today's rules: reserved fields filled
    (`stage_patch_object_fields`), and nothing else. Anything more is refused, as `PatchPlanner` would have planned.
  - **Unchanged functions are not JIT-compiled again.** If a function's linked opcodes and registers equal the live ones,
    it keeps its live code.
  - **A key a replaced section no longer defines** keeps its slot and its last code, subject to the guard check. This
    replaces the compiler's frozen bodies (`HlFunctionCache.vacate`).
- **Migrating the published numbering.** No migration in place. Bumping `HlRuntimeIdentity.VERSION` makes the first
  build after the change a full reload, through today's version-mismatch path.
  - From then on the slots belong to the loader. The compiler keeps the semantic baseline: the ABI descriptor for
    `PatchPlanner`, retired names, adapters and guards. It also keeps the digests of the sections the runtime acknowledged.
  - Stable function ids are minted by the loader per key, once for each live module. HLD3 reports them as it does now.
    The compiler stops minting them (`HlFunctionCache.nextStableId`).
- **What the fork needs.** The link state kept on `hl_module` for patchable modules, section linking against it,
  rename records and section removal. Staging, guards, migrations and atomic publication stay as they are.
- **Pruned live builds.** Slice 4 also makes live builds prune as one-shot builds do: sections hold the reached functions,
  layouts follow declarations, and a patch carries every function first reached ([LIVE_PRUNING.md](LIVE_PRUNING.md)).

## 5. Consumers of the format

| Consumer | Change |
|---|---|
| VM loader (`code.c`, `main.c`, `hlruntime.c`) | `hl_code_link` for HLB 9. The dense reader stays |
| JIT, `module.c`, `debugger.c`, `prof.c`, hlprof, `jit_gdb.c` | None: they read the linked `hl_code`. Function names come from keys |
| hashlink-debugger (`hld/Module.hx`) | Reads the `.hl` file itself (`format.hl.Reader`), and a runtime module's bytes through `debug_hlb`. Done in slice 2: `Module.load` links an HLB 9 file with `HlStaticLink` (it imports only `haxe`, so it runs on JavaScript) and reads the dense module, with identities, spans and snapshots |
| HLD3 protocol, DAP | Unchanged fields. The findex is the runtime's, and the stable id is minted by the loader |
| Patch loader (`hlpatch.c`) | HLP 12 (see 4) |
| AOT (`HlcImage`, `HlcModule`, `native/aot/hlc_main.c`) | Gets its indices from a compiler-side link (`HlStaticLink`: the loader's algorithm in Haxe, one pass in a cold build) and keeps writing a dense image. Slice 2 leaves it on the dense module the lowering still makes; it moves to the static link when that module goes (slice 3) |
| Stock HL/C (`hl2c`) | Not in use. It could read a statically linked HLB 8 if ever needed |
| `HlModuleReader`, `haxeon dev hl-stat`, `scripts/report-binary-size.py`, `vendor/hashlink/tools/hldump.c` | Read sections. Table statistics come from `HlStaticLink`. Done in slice 2: `HlModuleReader` reads an HLB 9 file through `HlStaticLink.linkWithParts`, with the bytes of each part of the sections; `hl-stat --link OUT` writes the linked HLB 8 module; a sectioned build's size census (`HAXEON_IR_CENSUS=1`) gives those parts, which the report accounts for; hldump reads HLB 9 through the loader |
| Sidecars | `.functions`, compared by the self-compile oracle and the edit replay, is written from `HlStaticLink`'s numbering or dropped for keys. `.hli` shrinks to module id and revision. Android HXR (`haxeon_jni.c`, `AndroidWatch`) addresses the entry by key. In slice 2 a sectioned build writes `.functions` and `.hli` in the loader's numbering (`HlSectionOutput.linkedIndices`); HXR watches live builds, which stay dense until slice 4 |
| Persistence (`hl/persistence`) | `HlSymbolStateCodec`, `HlTypeDefStateCodec` and `HlFunctionCacheStateCodec` go. `HlAssemblerStateCodec` keeps the semantic baseline and the section digests |
| Tests | The self-compile oracle takes a new base once, and stays byte-identical cold vs warm. These are rewritten: `HlModuleRoundTripMain`, `HlWriterCacheMain`, `DebugMetadataMain`, `test-hlb-debug-sections.sh`, the HLB cases in `TestMain`, and the patch mains that build HLP by hand (`PatchOpcodeTests`, `AddedFunctionLayoutMain` and the rest of the 20 files under `tests/` that import these classes). The ci-tier debug-metadata and hot-reload suites run unchanged |
| Wasm | None |

## 6. Deletion and addition (estimates)

| Goes or shrinks (compiler) | Lines |
|---|---|
| Link and replay: `HlRequestAnswers`, `HlLinkRecord`/`HlKeptTables`, `HlLink` (its remap becomes `HlStaticLink`), the answer halves of `HlRequestKeys` and `HlSymbolRequest` | −550 |
| `HlLower`: kept tables, `settleKept`, `settleTables`, `slotNames`, `verifyLinking`, `sameReplayTable`, the recording in `intern*`, the stable-id helpers | −320 |
| `HlSymbolTable`: published prefix, `fork`/`shareFrom`/`writable` groups, `replaceLeaf`, `truncate`, lengths, `typesName`, `stringConstantAt`, state export | −500 of 1,235 |
| `HlFunctionCache` (slots, stable ids, frozen bodies), `HlModuleAssembler` (slot layout, native and slot-move reloads, `startFresh`, `discardPublishedSymbols`, `callersOfMoved`, state) | −250, −400 |
| `HlWriterCache` prefix and debug-file invalidation; persistence codecs; `HlPatchWriter`/`HlPatchReader` symbols, hashes and relocations; `HlRuntimeIdentity` id maps | −150, −550, −500, −60 |
| **Compiler total** | **about −3,300** |

Added to the compiler: the section model and writer (+450), `HlStaticLink` (+300), home modules on IR functions (+60), the
shared section and boot query (+100), HLP 12 sections (+120), section reading in `HlModuleReader` (+150). That is about
**+1,200**. Added to the fork: `link.c` (+650) and patch linking with the live link state (+450). About 450 lines leave
`hlpatch.c`: prefix hashes, the symbols section, relocations and added functions. Net over the compiler and the fork:
**about −2,200 + 650 ≈ −1,550 lines**. Rewritten tests are not counted.

## 7. Effects (estimates, from the 2026-11-25 profile in QUERY_ENGINE.md)

- **Signature edit (18.5G).** The relink (0.75G) goes. The re-encode drops from every function to the modules of the
  ~950 changed ones, est. 150 sections or ~2,500 functions, which saves ~0.7G of the 1.1G. Total ~1.4–1.5G, as much as
  the slack design saved, without fillers or a capacity rule.
- **Body edit (2.44G).** It keeps its tables already. Encoding one section instead of checking every function saves
  ~0.05–0.1G, and dropping the request recording in every `intern*` saves a little more.
- **Blank-line edit (7.6G).** Most of the saving belongs to slice A. Sections add only that the edited module alone
  re-encodes its debug rows.
- **Output size.** The duplicated literal constants (+4.7 k entries, about +0.35 MB of text), local structural types
  (about +0.15 MB) and import keys (about +0.4 MB) add about +0.9 MB. Local operands get smaller: most index operands fit
  one byte instead of two, saving about −0.3 MB. Net about +0.6 MB on 27.9 MB (+2%), or about +10% of the non-debug part.
- **Load.** Linking adds 10–15 ms (+1% of JIT startup). AOT is unchanged.
- **Cold build.** Neutral or slightly faster: there is no global interning, and the module writer does the same operand
  walk. Measure cold runtime for locality, since function order changes from first use to module order.

## 8. Slices

Every slice is checked by: the byte-identical self-compile, `--check-reuse`, the edit replay, the warm-equals-fresh mains,
and perf-guard, including startup.

| # | Slice | Size (est.) | Extra checks | Depends on |
|---|---|---|---|---|
| A | Positions relative to their declaration (in progress elsewhere) | — | — | — |
| 1 | Fork: `link.c` and the HLB 9 reader beside the dense one. C tests on hand-built two-section modules cover every failure mode, plus `hldump`. Landed: `tests/native/code_link.c` (the `code-link` suite) | +1,500 C (+1,400 C tests) | fork tests; existing suites untouched (the compiler still writes HLB 8) | — |
| 2 | Compiler: home modules, `HlSectionWriter`, `HlStaticLink`. Plain builds write HLB 9; live builds stay on HLB 8. AOT, `hl-stat` and the binary-size report link statically. **Split.** 2a landed: the writer, the static link, the readers (`HlModuleReader`, hl-stat, the size report, the debugger) and the check that the VM's link equals the static link (`code_link --compare`, the `module-sections` suite, then a `driver-sections` suite), with sections behind the typed option `--module-sections`. 2b landed: plain builds write sections, the option is gone, link and replay are deleted, the self-compile oracle and the checked-in bootstrap took their new base (section 3, "As built in slice 2b") | +1,100 / −150 | the self-compile takes its new base. New validation: the VM's link equals `HlStaticLink`'s. The ci debug-metadata suite | 1, A |
| 3 | Plain warm builds without link and replay. One memo per module section, then folded into engine slice 7. **Split.** 3a landed: homes by declaration and the section memo (section 3, "As built in slice 3a"). 3b landed: functions kept as lowered, tables extended, the memo in section terms (section 3, "As built in slice 3b"); link and replay went with dense plain builds in 2b | −1,000 / +150 | `--check-reuse` | 2 |
| 4 | Live patching on sections: HLP 12, the patch linker, loader stable ids, slots and codecs removed, HXR | −2,100 / +500 compiler, −450 / +450 fork | the ci hot-reload suite, the patch mains, `NominalInterfacePatchMain`, an Android watch run; with live pruning ([LIVE_PRUNING.md](LIVE_PRUNING.md) slice 3) | 3 |
| 5 | Per-class initializer parts in their owning modules. The compiler no longer writes HLB 8 for live builds | −50 / +100 | edit replay on a static-initializer edit | 4 |

Slice 3 can land before engine slices 1–6. Slice 7 then turns its per-section memo into the `ModuleSection` query.

### Slice 4 plan

Slice 4 lands in four parts, each green on its own. A part keeps what it replaces working until a later part removes it,
and nothing stays for compatibility once its replacement has landed.

| Part | What | Checks |
|---|---|---|
| 4a | **Fork: patches made of sections.** The loader keeps the link state of a module it loads to patch (`hl_code_read_patchable`): the key tables, the literal, structural-type and constant tables, and a digest of each function's linked code. HLP 12 carries replaced sections in the HLB 9 encoding, removed section paths, renames, and guards and migrations by key. The patch linker (`hl_module_link_patch`) links the sections against the link state into the runtime's patch, so validation, staging, guards, migrations and the commit stay as they are: a known key keeps its slot, a new key takes the next one, a function whose linked code has the running one's digest is not compiled again, and a redefined class may only fill reserved slots. New debug files are appended. The loader mints stable ids (a function's slot, which a rename keeps). HLI 4 is the module id and revision alone; hosts find a function's id by name (`hl_runtime_module_function_id`). The link state is committed with the patch and restored when the patch fails. HLB 8 and HLP 11 still read, so the compiler does not change | `code-link` gains the patch cases: a body edit, added functions and classes, reserved slots, renames, guards, every refusal, and a refused patch followed by one that applies |
| 4b | **Compiler: live builds on sections.** A live build writes HLB 9 (its functions with identity relocations), and a patch is the sections whose digests differ from the acknowledged build's, with renames, guards and migrations by key (HLP 12). The `.hli` is HLI 4; the live host, the debugger tests and Android HXR address functions by name. `HlRuntimeIdentity.VERSION` moves, so the first build after the change reloads | the ci hot-reload and debug-metadata suites, vscode-debug, the patch mains, `NominalInterfacePatchMain`, the edit replay, an Android watch run |
| 4c | **Live pruning** ([LIVE_PRUNING.md](LIVE_PRUNING.md) slice 3): layouts from declarations (declared-method stubs in live layouts only), the published set grows within a module identity, `firstReached` is carried, natives a patch adds are appended by `(lib, name)`, the planner's reach-only causes go, and the live `--check-reuse` builds the same tree fresh and compares sections, first-reach coverage and imports | the new live edits in the driver and perf-guard's live part |
| 4d | **Deletions** (section 3, "Kept for slice 4"), each checked with a grep that includes `tests/`: the dense whole-module `HlWriter` encoding and `HlWriterCache`, HLP 11 (`HlPatchWriter`'s hashes, symbols and relocations, `HlPatchReader`), the published prefix of `HlSymbolTable` where nothing else uses it, `HlFunctionCache` slots and stable ids, the persistence codecs the section digests replace, `HlRuntimeIdentity`'s id maps; in the fork, HLP 11 and HLI 2 and 3 | the suites of 4b |

In 4a a patch that adds a native is refused by the patch linker, as the planner already plans a reload for it.

**What 4b touches**, found while building 4a:

- `HlSectionWriter` writes only a relocatable module (`HlCode.relocations`). A live module's functions keep the indices of
  the append-only live tables, which never renumber within a module identity, so its relocations are the identity: each
  function's index and type as they are, no moves, and one `chain` per module identity (a fresh layout starts another). The
  section memo then keeps every unchanged section without collecting it, as a plain warm build does.
- `HashLinkBackendSession.assemble`: the live branch takes the sections path (today `sections` stays null for live and
  `BackendArtifacts.hashLinkBytes` falls back to the dense `HlWriter` with the session's `HlWriterCache`). The patch is the
  sections whose bytes differ from the acknowledged build's (the section cache's digests per path), replacing
  `HlPatchWriter.encode(...)` and its prefix counts.
- Keys for what HLP 11 numbers: renames from `HlModuleAssembler.moveChangedSignatures` and `renameLambdas` (the home module is
  `HlSectionWriter.declaringModule` of the name); guards from `assembly.guards` by name; migrations from the `__liveinit`
  functions and their classes by name. Reserved-slot fills need nothing: the section's class names the slot.
- The `.hli` becomes HLI 4 (`HlRuntimeIdentity.encode`), and every consumer of stable ids from the compiler goes through
  names. Done first (4b step 1): the live host finds its entry points by name (`Runtime.functionId`, the `function_id`
  native), and `.live.json` no longer lists function ids. Then (4b step 2) every build's `.hli` is HLI 4, the module id, the
  revision and the initializer's name: on a dense HLB 8 live module the loader takes the ids from its identity section, so
  this held before sections. The runtime tests that build HLB 8 modules and HLP 11 patches by hand bind their ids with HLI 3
  (`tests/DenseRuntimeIdentity.hx`) until 4d. Left: Android HXR (`native/android/cpp/haxeon_jni.c`,
  `src/tools/AndroidWatch.hx`), `CompilerDriver`'s `functionIds.get("main")` and the REPL's.
- A function's runtime index is the loader's (`HlSectionOutput.linkedIndices`), not the live layout's: the `.functions`
  sidecar and the debugger tests that read slots take the linked numbering, as plain builds already do.

### As built in slice 4a

- **The link state** (`hl_code.link_state`, link.c). `hl_code_read_patchable` keeps it; `hl_code_read` and plain `hl` do
  not, so a plain program pays nothing. It holds the key entries with their texts copied, the open-addressed literal,
  debug-file, structural-type and constant tables over the module's arrays, the bytes blob, and per slot a 64-bit digest of the
  function's linked code (type, registers, opcodes with mapped operands; not its lines). The module frees it.
- **HLP 12** (`hl_patch_read`): the module id and revisions, then the replaced sections (path, byte size, a section in the
  HLB 9 encoding), the removed section paths, renames (module, from, to), guards (module, member, description) and migrations
  (the class's key, then the function's). Removed sections need nothing at run time: their keys keep their slots.
- **The patch linker** (`hl_module_link_patch`) runs the loader's three passes over the patch's sections against the link
  state, with every addition staged after the module's tables: a key the module has keeps its slot (functions, globals,
  owned types), a new function key takes the next slot and the stable id the loader mints for it (the slot), a new global
  is a null slot after the module's, a literal, structural type or constant the module lacks takes the next index, and a new
  debug file follows the module's. A redefined class must equal the running one after mapping, except that a reserved slot
  (an unnamed Dynamic field) may be named and typed, which becomes an object-field fill. A function whose code has its slot's
  digest is left out of the patch. The result fills the same `hl_patch` HLP 11 is read into, so validation, staging, the
  guard scan, migrations and the commit are unchanged; prefix hashes are not checked for it. Spans come from the section's
  opcode-span sub-section and, for any opcode it leaves out, from the line table; snapshots from its snapshot sub-section.
- **Commit and rollback** (`hl_link_patch_end`). The tentative entries are dropped when the patch fails (from the
  refusal, the guard scan or `hl_patch_free`), and the renames undone; when it applies, new keys and renamed members are
  copied into the state, structural types that name strings are hashed again from the committed types, constants move to
  `more_constants` and the digests of the compiled slots are replaced.
- **Refusals** name the section and the key: a missing import, a function key of another type (a changed signature must
  rename the old slot), a class redefined otherwise than by reserved slots, an added enum, a new native, a new bytes literal,
  a constant of a new type, a type reserve exhausted.
- **Runtime** (hlruntime.c): `hl_runtime_module_load` reads with the link state and takes HLI 4 (`HLI`, 4, module id,
  revision, the initializer's name), with the stable ids the loader gave; `hl_runtime_module_function_id` finds a function's id
  by name; `hl_runtime_module_apply_hlp` links an HLP 12 patch before it resolves stable ids, and reports a refusal's message.
- **Tests**: `tests/native/code_link.c` (the `code-link` suite) loads a two-section module patchable and applies a body
  edit (one function compiled), an unchanged section (none), an added function in a new debug file, an added class, a
  reserved-slot field, a rename with its caller, a guard by key, and each refusal, every refusal leaving the module and the
  link state as they were; and the same through the runtime with an HLI 4 identity.

## 9. Decided

Decided by the user on 2026-11-25:

1. **Import keys are text** (module, member) pairs. They are robust and need no collision rule. Their size, about
   +0.4 MB on the compiler against 0.13 MB for 64-bit hashes, shrinks under the LZ4 compression a section can carry.
2. **Unowned generated functions** (`$anon` printers, shared helpers) go in **one shared section**. A new anonymous type
   re-encodes it, about 600 functions, est. 0.05G, which is small. A section per printer would add about 512 directory
   entries for little gain.
3. **A JIT cache by section digest** across full reloads is **out of scope**. It comes later, with the deferred lazy JIT.

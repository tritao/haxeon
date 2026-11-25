# Module sections and load-time linking (design note)

Status: designed 2026-11-25, not started; the open questions are decided (section 9). The user's decision: per-module
sections and load-time linking replace "stable output indices" ([COMPILER_FOUNDATIONS.md](COMPILER_FOUNDATIONS.md) item 3,
[QUERY_ENGINE.md](QUERY_ENGINE.md) row B).

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

**Deduplication.** The loader deduplicates strings and literal-constant globals by content, and ints, floats and bytes by
value. The runtime therefore holds one global per literal, as it does today.

**Not imports.** Field indices (`OField`, `OSetField`) and prototype slots (`OCallMethod`) stay as numbers. They are
layout facts that lowering already records as reads (`HlLoweringView`), not table positions.

## 2. Loader

`hl_code_link(data, size, &error)` in a new `vendor/hashlink/src/link.c`. It returns the same `hl_code` that
`hl_code_read` builds, so `hl_module_alloc`, `hl_module_init`, the JIT, `hl_module_init_aot`, the debugger and the profiler
do not change. `main.c` and `hlruntime.c` dispatch to it on the version byte.

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
80 ms to read and about 1 s to JIT. An AOT image is linked by the compiler (see 5), so it costs nothing at load. While
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

- **Ownership.** Each `IrFunction` gets its home module from the declaration it is generated from:
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

## 5. Consumers of the format

| Consumer | Change |
|---|---|
| VM loader (`code.c`, `main.c`, `hlruntime.c`) | `hl_code_link` for HLB 9. The dense reader stays |
| JIT, `module.c`, `debugger.c`, `prof.c`, hlprof, `jit_gdb.c` | None: they read the linked `hl_code`. Function names come from keys |
| HLD3 protocol, DAP | Unchanged fields. The findex is the runtime's, and the stable id is minted by the loader |
| Patch loader (`hlpatch.c`) | HLP 12 (see 4) |
| AOT (`HlcImage`, `HlcModule`, `native/aot/hlc_main.c`) | Gets its indices from a compiler-side link (`HlStaticLink`: the loader's algorithm in Haxe, one pass in a cold build) and keeps writing a dense image |
| Stock HL/C (`hl2c`) | Not in use. It could read a statically linked HLB 8 if ever needed |
| `HlModuleReader`, `haxeon dev hl-stat`, `scripts/report-binary-size.py`, `vendor/hashlink/tools/hldump.c` | Read sections. Table statistics come from `HlStaticLink` |
| Sidecars | `.functions`, compared by the self-compile oracle and the edit replay, is written from `HlStaticLink`'s numbering or dropped for keys. `.hli` shrinks to module id and revision. Android HXR (`haxeon_jni.c`, `AndroidWatch`) addresses the entry by key |
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
| 1 | Fork: `link.c` and the HLB 9 reader beside the dense one. C tests on hand-built two-section modules cover every failure mode, plus `hldump` | +700 C | fork tests; existing suites untouched (the compiler still writes HLB 8) | — |
| 2 | Compiler: home modules, `HlSectionWriter`, `HlStaticLink`. Plain builds write HLB 9; live builds stay on HLB 8. AOT, `hl-stat` and the binary-size report link statically | +1,100 / −150 | the self-compile takes its new base. New validation: the loader's linked-table digest (behind a flag) equals `HlStaticLink`'s. The ci debug-metadata suite | 1, A |
| 3 | Plain warm builds without link and replay. One memo per module section, then folded into engine slice 7 | −1,000 / +150 | `--check-reuse` | 2 |
| 4 | Live patching on sections: HLP 12, the patch linker, loader stable ids, slots and codecs removed, HXR | −2,100 / +500 compiler, −450 / +450 fork | the ci hot-reload suite, the patch mains, `NominalInterfacePatchMain`, an Android watch run | 3 |
| 5 | Per-class initializer parts in their owning modules. The compiler no longer writes HLB 8 for live builds | −50 / +100 | edit replay on a static-initializer edit | 4 |

Slice 3 can land before engine slices 1–6. Slice 7 then turns its per-section memo into the `ModuleSection` query.

## 9. Decided

Decided by the user on 2026-11-25:

1. **Import keys are text** (module, member) pairs. They are robust and need no collision rule. Their size, about
   +0.4 MB on the compiler against 0.13 MB for 64-bit hashes, shrinks under the LZ4 compression a section can carry.
2. **Unowned generated functions** (`$anon` printers, shared helpers) go in **one shared section**. A new anonymous type
   re-encodes it, about 600 functions, est. 0.05G, which is small. A section per printer would add about 512 directory
   entries for little gain.
3. **A JIT cache by section digest** across full reloads is **out of scope**. It comes later, with the deferred lazy JIT.

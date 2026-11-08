# 3. Compiler architecture: one dependency model, explicit layers, structured identities

Date: 2026-11-08

## Status

Proposed. Nothing here is implemented yet. The work under way, `docs/WARM_REBUILD_REUSE.md` (branch `warm-rebuild-reuse`),
is the first step of the migration (M0 below) and is designed to fit this record.

The decisions do not carry the same confidence, and the migration treats them differently:

- **Committed:** one dependency model (1), explicit layers with target configuration as an input (2, 3), passes as a
  summary plus a local rewrite (4), structured identities for generated entities (5), declared compiler-known runtime
  modules (6), one path identity (7), the incremental-equals-fresh invariant and its check mode (10). Each removes
  mechanisms we have today, and mature incremental compilers (Roslyn, rust-analyzer, Swift's request evaluator) have
  converged on each.
- **Options that must prove themselves:** shared layout decisions across backends (8) and one compiler session shared by
  the language server and builds (9). Each gets a measured go/no-go before any migration.
- **Direction, not scheduled:** separate compilation by package (11). The committed decisions are what make it possible.

## Context

The pipeline is a classic one and its bones are good: lexer, parser, type checker, immutable SSA IR, then the HashLink
backend and two Wasm backends (linear memory, Wasm GC). Live patching sits beside standard HashLink bytecode (HLI, HLP),
so generated `.hl` files stay ordinary. The language server runs the same compiler code as the build. Modules keep their
artifacts, and the rule that an incremental result must equal a fresh compile is held and tested
(`TypedMetadataMergeMain`).

Incrementality grew one stage at a time, and each stage has its own mechanism. An inventory on 2026-11-08 found more than
twenty retained caches. Some record precise dependencies:

- kinded semantic edges per declaration (`ModuleState.semanticDependencies`: Signature, Body, Layout, Initializer,
  InlineConstant);
- the purity and no-return answers each typed function relied on, compared against fresh inference;
- default-argument source snapshots and key-path uses;
- the inliner's memo, which records the callee bodies and objects each result consulted (`IrInliner.hx` `IrInlineCache`).

Others invalidate coarsely, each by its own rule:

- `CompilerSession.reset()` throws the whole compiler away when a configuration, a manifest or a lazily loaded module's
  structural-declaration token changes, or when a module is shadowed (`CompilerSession.hx:93-128`).
- `cachedSemanticProgram` and `lastTypedProgram` are dropped on any signature or structural change, and the
  reachability cache on any structural change (`FrontendCompilation.hx:88-178`).
- An edited module retypes all of its own functions (`ModuleSemanticSnapshot`).
- Plain builds relower every function: lowered functions carry absolute table indices, so only live patching, with
  append-only tables, reuses them (`BackendAssembly.hx:74`).
- `HlWriterCache` clears when the debug-file list changes, and `LanguageService.configure` clears all its indexes.

Fingerprints are raw printed signatures and source slices compared as strings, not hashes.

Every warm-build bug fixed on 2026-11-08 was a disagreement between two of these mechanisms.

- Re-reading a generated template counted as an edit, which turned off semantic reuse.
- The non-reuse typer path dropped generic specializations that the prune then retired.
- Package discovery resolves symbolic links (`fullPath`) while the language server's workspace does not
  (`absolutePath`), so a workspace opened through a link owned no sources.

Each fix was correct. The cost is the edges between mechanisms, and each new stage adds edges.

Four further structural problems sit next to incrementality.

1. **Target decisions leak into the shared IR stage.**
   - `FrontendCompilation` binds target facts into `IrGenerator` statics before generation (`bindHeaderlessValueClasses`,
     `bindNativeStringFastPaths`, `bindNativeReflectionDispatch` and others, `FrontendCompilation.hx:186-192`), and
     `IrInliner.packedValueFields` is a static.
   - `IrProgramAssembler.assemble` takes a value-lane target. Inline-enum lowering and value-array rewriting derive pointer
     widths from it (`IrInlineEnumLowering.hx:11-15`, `FrontendCompilation.hx:640`).
   - The scalar ABI passes run in a different order per target (`FrontendCompilation.hx:643-657`).
   - The Wasm module builders run IR passes again (`IrValueInterfaceBoxes`, `IrCheckedDynamicCasts`, `IrScalarReplacement`).

   The IR is called canonical, but in practice the pipeline mixes target-independent IR, whole-program representation
   decisions and target lowering.
2. **Representation decisions are made inside rewrites.** Whether an enum is stored inline, which closures and arguments
   are scalar, which value-array shapes exist and which helpers are needed are decided inside the passes that also rewrite
   bodies. So rewrites read other functions, some passes rebuild the whole program (`IrInlineEnumLowering` remaps every
   declaration; `IrScalarArguments` scans every call site), and helpers have to be owned by name. After the
   2026-11-08 merge, six new passes added 54M allocated objects to every warm `app` build.
3. **Generated entities are identified by encoded names.** There are more than twenty-five prefixes (`$generic:`,
   `$generic-method-reference:`, `$value$equality:`, `$wire:`, `$json:`, `$inline-enum-global:<len>:<name>:<field>`,
   `$scalar-arguments:`, `$value-array:…`, `$typed-interface-entry:`…). They are parsed back into structure in more than
   twenty places, from `GenericOwnerErasure` and `IrTypedInterfaceDispatch` to `HlLower`, `WasmScalarAbi` (a long
   `startsWith` exclusion chain) and `WasmTypedInterfaceTables` (a length-prefixed parser).
4. **The compiler discovers its own runtime library while typing.** Typing records runtime targets as it meets them
   (`Reflect`, `haxeon.DynamicOps`, `Std`, `DynamicObject`, `haxeon.collections.HashMap`, `runtime.FloatBits`,
   `haxe.Int64`, the reactive classes). `FrontendCompilation` then loads those modules and continues the front end. A
   module that changes a representation (the specialized map) must be seeded up front, or the build fails. Runtime
   classes and natives are also named in a dozen places (`RuntimeType`, `PlatformAbi`, `ArrayLibrary`, `IrGenerator`,
   `IrProgramAssembler`, `WireCodecGenerator`).

The written design has not kept up. `ARCHITECTURE.md` is 67 lines and says nothing about what a pass may read, where
representation decisions live or how invalidation works. Many sessions work on the compiler in parallel, and each does
what is locally reasonable.

## Decision

### 1. One dependency model

Every derived artifact is the result of a query over explicit inputs. The inputs are source texts, configuration and the
target profile. The derived artifacts are:

- parse and declarations per module;
- signatures, typed bodies and specializations per function;
- IR per function, and program summaries;
- lowered functions, and the linked module.

A query records what it read through one read interface. On the next build it is reused while every recorded read still
gives the same answer, and recomputed otherwise.

- There is one engine and one invalidation rule. Each existing cache becomes a query or is deleted. The precise recorders
  we already have (semantic edges, purity and no-return answers, inline-cache dependencies, `LoweringView` in
  `WARM_REBUILD_REUSE.md`) become reads in this model.
- A coarse reset is allowed only where an input really is global (a different target, a different compiler), and it is
  a named input of the queries, not a separate path.
- Answers are compared by value: a structural digest where comparing the whole value would be expensive. Raw source
  slices stop being fingerprints.
- Lifetime: a query database lives with a compiler session. Persisting it on disk is not part of this record
  (`.live.state` stays as it is).

### 2. Explicit layers

Each layer reads only the layers above it, through queries:

1. **Syntax:** tokens and AST per module.
2. **Declarations and signatures:** the semantic model. This is what other modules may depend on, and later the package
   interface (11).
3. **Typed bodies:** per function, including generated typed helpers (equality, wire, JSON).
4. **Target-independent IR:** per function, with no target parameters.
5. **Program summaries:** all representation decisions, computed from layer 4 and the target profile. Examples: inline
   enum storage, value layouts, value-array shapes, scalar argument and closure ABIs, interface slot assignment, the
   helper set, method resolution tables.
6. **Target IR:** per-function rewrites that read only their function, the summaries and declared reads such as callee
   signatures, or callee bodies for the inliner.
7. **Backend lowering:** per function, relocatable (`WARM_REBUILD_REUSE.md` design A), for HashLink and each Wasm backend.
8. **Link:** assigns indices and writes the module or the patch.

The Wasm builders stop running IR passes themselves: whatever they need runs in layer 6 for their target.

### 3. The target profile is an input

There is one `TargetProfile` value: backend, pointer width, value-lane target, native ABI, reflection dispatch, packed
fields, live patching. It is passed explicitly and read through the query interface. It replaces the `IrGenerator.bind*`
statics, `IrInliner.packedValueFields` and the scattered `isWasmTarget()` checks. Layer 4 does not read it; layers 5–8
do.

### 4. Passes are a summary plus a local rewrite

A pass declares:

- an optional **summary step**, which computes a small, comparable decision structure from per-function contributions;
- a **local rewrite**, which maps one function to one function.

A rewrite that changes nothing returns the same object (the framework asserts this in check mode). Generated helpers are a
function of the summary: the helper set is derived from it, so a helper exists exactly while something needs it.

A pass that really needs a fixpoint over all functions, such as `IrStaticNullChecks`, `IrOptionalScalarFlow` and
`IrNullableScalarFlow` today, states why. Its fixpoint becomes a summary computed incrementally from per-function
contributions.

### 5. Structured identities for generated entities

A generated function, object or global carries a structured identity: a kind plus typed fields (owner, member, type
arguments, shape, operation), defined once in the IR. Passes and backends match on the structure.

The string name is rendered once, at link time, for symbol tables and debug output, and is never parsed. Owner and member
names (`Owner.member`) are fields, not split strings. This also gives helpers their owner without a name lookup
(`DeclarationOwners`).

### 6. Compiler-known runtime modules are declared

A single declaration names every runtime module and class the compiler may introduce, and the natives it may call. It
records which modules affect representation; those are always part of the program. Typing records which of these each
function uses, as a dependency, but never adds a module that changes a representation. So the front end runs once, and
the restart and continuation code is deleted.

Modules that are only called (`DynamicOps`, `Reflect`, the reactive runtime) are loaded on first use like any other
dependency. If loading them is cheap enough, they are loaded up front.

### 7. One path identity

A source file has one identity: its canonical path, with symbolic links resolved, computed at the input boundary. It also
keeps the spelling it was given, for diagnostics and editor URIs. Build sessions, project discovery, module loading and
the language server all key files by the identity and display the spelling. `ModulePath.fromFile` takes the identity.

### 8. Shared layout decisions across backends (option)

Today object layout, enum representation and interface tables are derived separately by `HlSymbolTable`, `WasmLayout`,
`WasmGcTypePlan`, `HlTypedInterfaceTables` and `WasmTypedInterfaceTables`. Physical layout is target-specific and stays
in each backend.

The decisions that are not target-specific, such as interface slot assignment and which enums are boxed, are candidates
for layer 5. Go/no-go: move interface slot assignment and compare code size and duplication; keep it only if both
backends get simpler.

### 9. One session for the language server and builds (option)

The language server keeps up to three `Compiler` instances of its own (`LanguageService.configurationCompilers`). Build
sessions keep another (`CompilerSession`). With one query database per configuration they could be the same session:
the editor would warm the build, and memory would hold one copy.

Go/no-go after decision 1 lands: measure memory and latency with an editor and a watch build open on `app`.

### 10. Incremental equals fresh, enforced

The invariant stays absolute: an incremental result equals a fresh compile, byte for byte for module output.

- A check mode (`HAXEON_CHECK_REUSE=1`) recomputes every reused query and fails, naming the query and the difference.
- The compiler tests run warm-versus-cold byte comparisons for edits to a body, a signature, a generic specialization, an
  added or removed function, and an added constant.
- Before a migration step merges, check mode is run once on warm `app` builds.

The check mode is a test aid, never a fallback.

### 11. Separate compilation by package (direction)

With layers 2 and 5 explicit, a package can be compiled against the stored interface of its dependencies: their
signatures plus the summaries they export. It is then linked. This is the Roslyn model, and it bounds both cold and warm
cost by package. It is not scheduled. Decisions 1–7 are designed so that it needs no further restructuring.

## Migration

Each step is its own series of commits. Every commit keeps the full driver suite green and the warm-equals-cold tests
passing. Unported code keeps running whole-program, so the pipeline is correct at every step. Old forms are deleted when
their last user is ported; there are no compatibility aliases.

- **M0 (in progress, `WARM_REBUILD_REUSE.md`):**
  - merged passes return unchanged functions;
  - the program-level no-op shortcut;
  - relocatable HashLink lowering with a link step, `LoweringView` as the only way lowering sees other entities, and the
    check mode;
  - per-function verification;
  - live patching ported onto the same relocatables.
- **M1 Target profile (3):** replace the generator and inliner statics and the target branches with `TargetProfile`.
  Small, and it unblocks M2.
- **M2 Pass framework (4):**
  - define the pass interface and the summaries;
  - inventory the ~25 passes as already local, local plus a summary, or genuinely global;
  - move them in order of edit-case cost;
  - move the Wasm builders' own IR passes into layer 6.
- **M3 Structured identities (5):** one prefix family at a time, together with the pass that owns it in M2. Delete each
  name parser with its family.
- **M4 One dependency engine (1):**
  - move the front-end caches (`cachedSemanticProgram`, `lastTypedProgram`, reachability, canonical contributions,
    `objectCache`) and `CompilerSession.reset()` onto queries;
  - replace raw-string fingerprints;
  - delete the coarse paths.
- **M5 Runtime declaration and path identity (6, 7):** the runtime declaration deletes the front-end restart and
  continuation. Path identity is independent and can go earlier.
- **M6 Options (8, 9):** each with its measured go/no-go.
- **Later: separate compilation (11).**

After each step `ARCHITECTURE.md` gets a short section for what landed: layers, what a pass may read, the query rules.
This record is not where the current state lives.

## Consequences

- **One rule to learn.** A contributor learns one rule for incremental work: read through the query interface. New
  passes are cheap by construction: a pass that rebuilds every function or reads undeclared state fails check mode, not a
  profile weeks later.
- **Cost proportional to the change.** Warm cost should become proportional to the change at every layer, not just in
  typing. The measure is `app` warm builds after a one-line edit (357M objects on 2026-11-08), together with the cold
  build.
- **Upfront work.** The pass interface, summaries and structured identities come before the edit-case win from caching
  individual passes. The plan in `WARM_REBUILD_REUSE.md` (step 4) is reordered to match.
- **Memory.** Retained queries cost memory. Each migration step reports the compiler worker's resident memory after a
  warm `app` build.
- **Rejected alternatives:**
  - **More per-stage caches** (the original step 4 of `WARM_REBUILD_REUSE.md`) gives faster wins on the passes ported
    first, but adds a cache and an invalidation rule per pass. That is the source of the bugs described above.
  - **A rewrite** would lose the parts that work (typer, live patching, the existing precise recorders) and stall
    language and backend work.

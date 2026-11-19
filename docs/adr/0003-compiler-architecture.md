# 3. Compiler architecture: one dependency model, explicit layers, structured identities

Date: 2026-11-08

## Status

Accepted. Migration steps M0 and M1 have landed; M2 onward is pending. Amended 2026-11-19: the dependency engine (1)
comes before the pass framework (4), and a query owns its output (14); see Migration. What landed is described in
`docs/ARCHITECTURE.md` ("Warm builds: what landed"), which is where the current state lives; this record keeps the
decisions.

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
- the purity and no-return answers each typed function relied on, compared against fresh inference (purity) and the
  current `@:noReturn` declarations;
- default-argument source snapshots and key-path uses;
- the inliner's memo, which records the callee bodies and objects each result consulted (`IrInliner.hx` `IrInlineCache`).

Others invalidate coarsely, each by its own rule:

- `CompilerSession.reset()` throws the whole compiler away when the configuration changes or a lazily loaded module's file
  is gone. A typedef, enum or abstract that changes shape does not: its fingerprint (`ModuleChangeAnalyzer`) invalidates
  what depends on it, as a class's does.
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
   - Beyond target flags, `IrGenerator` keeps about twenty static maps of whole-program state (`valueClasses`,
     `classBases`, `genericOwnerOrigins`, `observableClasses`, `inlineValueObjects`, `generatedObjects`… at
     `IrGenerator.hx:54-73`). Later passes read some of them, such as `observableClassFieldCount` in
     `IrProgramAssembler`. They are not part of `IrProgram`, so a memoized result that reads them goes stale without any
     recorded read.
   - `IrProgramAssembler.assemble` takes a value-lane target. Inline-enum lowering and value-array rewriting derive pointer
     widths from it (`IrInlineEnumLowering.hx:11-15`, `FrontendCompilation.hx:640`).
   - The scalar ABI passes run in a different order per target (`FrontendCompilation.hx:643-657`).
   - The Wasm module builders run IR passes again (`IrValueInterfaceBoxes`, `IrCheckedDynamicCasts`, `IrScalarReplacement`).

   The IR is called canonical, but in practice the pipeline mixes target-independent IR, whole-program representation
   decisions and target lowering.
2. **Representation decisions are made inside rewrites.** Whether an enum is stored inline, which closures and arguments
   are scalar, which value-array shapes exist and which helpers are needed are decided inside the passes that also rewrite
   bodies. So rewrites read other functions, every pass scans the whole program, and helpers have to be owned by name.
   After the 2026-11-08 merge, six new passes added 54M allocated objects to every warm `app` build. A per-pass probe
   found that only `IrInlineEnumLowering` (and, in a small way, `IrStaticNullChecks`) returned new but equal functions.
   That was fixed in `fc02b21d` (−36M on a warm no-op). The rest of the cost is scanning, which no per-function fix
   removes.
   - The pipeline is not linear. Passes call other passes: inline-enum lowering reruns typed-interface dispatch, scalar
     closures rerun interface boxing and checked casts, and scalar arguments and value arrays run phi scalarization and
     scalar replacement inside their loops.
   - Several passes push objects or functions into the shared input arrays in place (`IrValueInterfaceBoxes`,
     `IrOptionalScalarFlow`, `IrTypedInterfaceDispatch.generate`, `GenericOwnerErasure.generate`, `ObjectReflection`).
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
  `../design/WARM_REBUILD_REUSE.md`) become reads in this model.
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
7. **Backend lowering:** per function, relocatable (`../design/WARM_REBUILD_REUSE.md` design A), for HashLink and each Wasm backend.
8. **Link:** assigns indices and writes the module or the patch.

The Wasm builders stop running IR passes themselves: whatever they need runs in layer 6 for their target. A pass that
today calls another pass inside it becomes explicit stages in layer 6, ordered by the summaries they need. Repeating a
stage is allowed; hiding one inside another is not.

### 3. The target profile is an input

There is one `TargetProfile` value: backend, pointer width, value-lane target, native ABI, reflection dispatch, packed
fields, live patching. It is passed explicitly and read through the query interface. It replaces the `IrGenerator.bind*`
statics, `IrInliner.packedValueFields` and the scattered `isWasmTarget()` checks. Layer 4 does not read it; layers 5–8
do.

The rest of the static program state in `IrGenerator` goes the same way. What generation needs from the typed program
(value classes, class bases, generic owners and origins, observable classes and field bits, typed interface contracts)
becomes an explicit generation context: a query over layer 3, passed in and read through the query interface. What later
passes need from it becomes part of `IrProgram` or a summary. No compiler stage keeps program state in statics.

### 4. Passes are a summary plus a local rewrite

A pass declares:

- an optional **summary step**, which computes a small, comparable decision structure from per-function contributions;
- a **local rewrite**, which maps one function to one function.

A rewrite that changes nothing returns the same object (the framework asserts this in check mode). Generated helpers are a
function of the summary: the helper set is derived from it, so a helper exists exactly while something needs it.

A pass that changes tables (objects, interfaces, enums, statics, natives) lists them, and the changes are part of its
summary, not a side effect on shared arrays.

Three passes are true fixpoints: `IrScalarArguments`, `IrNullableScalarFlow` and `IrOptionalScalarFlow`. All three prune
candidates, starting from the largest set and removing what fails. Their summary is computed incrementally over the
dependency cone of the changed functions:

1. reset the cone;
2. rerun the removal with everything else fixed;
3. repeat for the readers of any candidacy that flipped.

If no candidacy flips, the cost is the changed function alone. A pass whose cone turns out to be the whole program says
so and stays whole-program.

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

- A check mode (`--check-reuse`) recomputes every reused query and fails, naming the query and the difference.
- The compiler tests run warm-versus-cold byte comparisons for edits to a body, a signature, a generic specialization, an
  added or removed function, and an added constant.
- Before a migration step merges, check mode is run once on warm `app` builds.

The check mode is a test aid, never a fallback.

### 11. Separate compilation by package (direction)

With layers 2 and 5 explicit, a package can be compiled against the stored interface of its dependencies: their
signatures plus the summaries they export. It is then linked. This is the Roslyn model, and it bounds both cold and warm
cost by package. It is not scheduled. Decisions 1–7 are designed so that it needs no further restructuring. The design is in ADR 0005.

### 12. The compiler worker is built by Haxeon (direction, added 2026-11-09)

Today the compiler worker is built with stock Haxe and its standard library (`build.hxml`, `-cp src`). Self-hosting is
tested in CI, but the worker that ships is not self-hosted. That costs us three things:

- **Forks.** Code forks by build: the `#if haxeon` paths in `HlWriter`, and the GC setter declared by hand through
  `@:hlNative` for the stock build.
- **Unreachable stdlib.** The worker cannot use the Haxeon stdlib: not `runtime.memory.Arena`, not allocation regions
  (ADR 0004, 6), not the shared runtime library.
- **Workarounds.** General-purpose code the compiler needs has to live in a portable source root that both builds read
  (`lib/haxeon-io`, for byte sinks and segmented bytes).

Building the worker with Haxeon removes the forks, and stdlib improvements then reach the compiler directly.

Go/no-go, measured against the stock-Haxe worker on the `app` builds (cold, no-op, edit) and the full driver suite:

- worker build time;
- compile time and peak memory;
- test parity.

Until then, shared general-purpose code stays in the portable root, never in `#if` forks.

Measured 2026-11-17 (compile server, release mode, the compiler's own sources in place of `app`, whose build compiles native
packages in another checkout): the Haxeon-built server starts in 1.00 s against 1.02 s, compiles cold in 22 s against 28-30 s
(one-shot 28.2 s against 37.7 s), rebuilds a no-op or one-line edit in 7 s against 10 s, peaks at 2.06 GB against 2.35 GB, and
passes the program cases cold and warm. It loses on its own build: the pinned Haxe builds the server in 14.8 s, the Haxeon-built
compiler in 24.4 s (21.8 s at a 0.8 GC threshold).

**Tool artifacts build in release mode (decided and implemented 2026-11-17).** What decides the mode is the artifact's role,
said once in `HaxeonBuild` (`TOOL_BUILD_MODE`): a tool artifact (the checked-in bootstrap compiler now; the compile server, CLI and language server when
Haxeon builds them) is a release build, so a Haxeon-built worker inherits it. A release module keeps minimal symbols inline,
the function identities (stack-trace and profiler names) and the line table, about 2 MB of the server's 7 MB; development
mode adds source snapshots, opcode spans and live metadata (the bootstrap is 27 MB). Conditions:

- a release-built compiler's crash traces name functions and lines (they do: `CompilerArguments.parse
  (compiler/tools/CompilerArguments.hx:119)`);
- the self-hosting check reaches its fixed point in release mode, so release-only code generation is exercised by the compiler
  compiling itself; development metadata stays covered by the live builds of the program cases;
- nothing reads development metadata from the compiler's own bytecode (live patching and the language server act on the programs
  it builds, not on it).

The release bootstrap is 5.97 MB (development: 27.2 MB); it converges in one self-host stage and rebuilds itself identically,
and `scripts/check-self-hosting.hx` builds the compiler and its ten entry points in release mode.

**Separate symbol files: deferred.** They would move about 2 MB of 7 out of the module, at the cost of the VM, the profiler and
crash reports finding a sidecar matched to the module (`.hl.build-id` would key it), and of traces without it showing bare
indices. They are for a distribution need, end-user, mobile or Wasm downloads symbolicated offline, as `--debug-info=inline |
separate | none`; development metadata is the first candidate for a sidecar if development builds' load time ever matters.

**Compressed debug sections (decided 2026-11-17, queued).** A debug-section header flag says its payload is LZ4 HC compressed;
the VM decompresses it at load, or on first use for sections only traces and the profiler read. The function identities come
first (the compile server's 1.15 MB section is 234 KB, decoded in 0.4 ms), then the development sections (source snapshots and
opcode spans, most of a development module's size). The compressor is a native of the HashLink runtime over the LZ4 the fork
vendors (one file), so the stock-built and the Haxeon-built compiler write the same bytes. Measured alternatives on the same
section: LZ4 fast 286 KB, zlib -9 (miniz's format) 195 KB decoded in 5 ms, zstd -19 168 KB (a large new dependency, kept for a
distribution need). Deduplicating the section's strings first (a path table, names over a string table) gains only 22 KB after
compression, so the section keeps its format. HashLink's per-instruction line table is part of the bytecode format, not a
section, and stays as it is.

**To decide separately:** the bootstrap binary in git adds its whole size to the history at every refresh. Pinning it by hash
and fetching it, as `.tools/haxe` is, or building it from the pinned Haxe on first use, would end that.

### 13. Reachability with explicit providers; whole-program work runs on the reachable program (added 2026-11-11)

Two attempts on 2026-11-10 failed for the same reason: some dependencies are not edges in the IR.

- **Pruning before the passes was unsound.** Typing generates per-type helpers, such as dynamic equality for an enum. Nothing
  calls them until a later pass builds the dispatcher over all types, so an early walk pruned them, and programs comparing
  values dynamically failed at run time.
- **Seeding the runtime modules up front de-optimized unrelated code.** The program-wide enum and closure classification
  looks at every function present, including unused helpers that take `Dynamic`.

Decision:

1. **Providers.** Every generator of a type-dispatched helper declares what it provides as a (type, operation) pair in
   one provider table on the program. Operations include dynamic equality, hash, compare, `toString`, dynamic enum test,
   reflection field access, boxing and interface dispatch. The knowledge lives with the generator, never in a list of
   names in the walker.
2. **A type-aware walk** (rapid type analysis). The walk follows explicit edges: calls, closures, dispatch over the
   subtypes of *created* types, and provider edges. A provider (T, op) is reachable when T is created and op is used at a
   reachable dynamic site.
   - A use of a helper that does not exist yet is a typed operation in the instruction that carries its subject type
     (e.g. `Intrinsic(EnumDynamicBox(T))`), not a name and not a side table of requests. The walk derives the provider
     edge from the operation.
   - Roots: the entry, static initializers, `@:keep`/`@:expose`, reflection by Wasm's rules, native callbacks, and
     declared live-host entries.
   - There is one walker (`IrReachability`) for every target.
3. **It runs once, after IR generation and before the passes.** Passes, classifications and the verifier see the
   reachable program. Dispatchers are built from reachable providers only.
4. **Invariant, enforced in check mode.** A pass may only introduce calls to functions that are reachable or that it
   creates. A violation names the pass and the call, so a missed edge is a test failure, never a miscompile.
5. **Single frontend pass.** The declared runtime modules (decision 6) are always part of the program on the targets that
   can host them. Typing records uses and never adds a module, so the restart and its continuation are deleted. Unused
   runtime code is gone before any classification, and it is absent from the output. Compiler intrinsics are always
   registered by the compiler itself.
6. **Tests.**
   - Program cases build and run both live and plain.
   - A standing test runs programs pruned and unpruned and requires equal behavior.

Migration, each step separately gated:

1. Provider inventory and table (no behavior change).
2. The type-aware walk, compared with the conservative walk on the program corpus.
3. Prune before the passes, with the invariant.
4. Single frontend pass.
5. Later: live-build pruning with declared host roots, and per-method pruning.

### 14. A query owns its output (added 2026-11-19)

A query's output holds only values, interned ids (symbols, names, types) and other queries' outputs. It never points into
data its computation made for its own use, nor into another query's working data. Everything else a computation allocates
is scratch and dies with it.

- **Why.** The session keeps every output (1), so what an output reaches is what the session costs. Measured on the
  compiler's own sources (2026-11-19, the allocation-group census of ADR 0004 section 6): releasing the syntax freed none
  of its 265 MB of pages, because typed code, IR and a rewritten AST built from the parse still pointed into it: positions,
  names and shared subtrees. Sharing a subtree saves a copy but ties two lifetimes together.
- **Scratch is a region.** Once outputs are owned, a computation's scratch can run in an allocation region released when
  the query ends (ADR 0004 section 6). That is only cheap with ADR 0004's level 3 release, without a full collection,
  so regions follow the queries that prove their outputs own nothing else.
- **Values.** Positions, operands and ids are values. With ADR 0006 they become structs; until then they are slim
  immutable objects, compared by value.
- **Check mode** (10) may verify the rule: a released region with live blocks names the query.

## Migration

Each step is its own series of commits. Every commit keeps the full driver suite green and the warm-equals-cold tests
passing. Unported code keeps running whole-program, so the pipeline is correct at every step. Old forms are deleted when
their last user is ported; there are no compatibility aliases.

- **M0 (landed, `../design/WARM_REBUILD_REUSE.md`):**
  - merged passes return unchanged functions;
  - the program-level no-op shortcut;
  - relocatable HashLink lowering with a link step, `LoweringView` as the only way lowering sees other entities, and the
    check mode;
  - per-function verification;
  - live patching ported onto the same relocatables.
- **M1 Target profile and generation context (3), landed 2026-11-09:** replace the target branches and every static that holds program or
  target state (`IrGenerator`'s maps and flags, `IrInliner.packedValueFields`) with `TargetProfile` and an explicit
  generation context. It unblocks M2: until then, any memoized pass result can silently depend on unrecorded state.
  The M0 program-level shortcut must include this state in its input digest until M1 lands.
Order amended 2026-11-19: the engine core comes first, and the pass framework is built on it. M2's interface already
records every read with a digest of its answer, which is the engine. Built for passes alone, it would be one more
mechanism next to the typer's recorded reads (`DeclarationTypes`, semantic edges) and the backend's `LoweringView`,
which M4 would then have to merge. The passes are where an edit's time goes (66% of a one-string edit of the compiler,
`IR_PASS_INVENTORY.md`), so they are the first client of the engine, not a separate design.

- **M4a Engine core (1, 10, 14), [`QUERY_ENGINE.md`](../design/QUERY_ENGINE.md):**
  - the database: query kinds, keys, revisions, recorded reads with answer digests, early cutoff, cycle detection;
  - check mode for every query (10);
  - the existing `DeclarationTypes` query and its recorded reads become the first query kind on it.
- **M2 Pass framework (4), on the engine:** a pass's contribution, summary and rewrite are query kinds, and the view is
  the engine's read interface:
  - inventory the ~25 passes as already local, local plus a summary, or genuinely global (`IR_PASS_INVENTORY.md`);
  - move them in order of edit-case cost;
  - move the Wasm builders' own IR passes into layer 6.
- **M4b Lowering and the rest of assembly as queries:** IR generation and table assembly per function and per
  declaration, and the relocatable lowering of M0 moved onto the engine, with link as the only whole-program step
  (decision 2, layers 4 to 8).
- **M3 Structured identities (5):** one prefix family at a time, together with the pass that owns it in M2. Delete each
  name parser with its family. Identities are interned ids, so outputs hold ids, not names (14).
- **M4c Front-end caches:**
  - move the front-end caches (`cachedSemanticProgram`, `lastTypedProgram`, reachability, canonical contributions,
    `objectCache`) and `CompilerSession.reset()` onto queries;
  - replace raw-string fingerprints;
  - delete the coarse paths.
- **Regions (14):** per-query scratch regions, one query kind at a time, after ADR 0004's level 3 release.
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
  individual passes. The plan in `../design/WARM_REBUILD_REUSE.md` (step 4) is reordered to match.
- **Memory.** Retained queries cost memory. Each migration step reports the compiler worker's resident memory after a
  warm `app` build.
- **Rejected alternatives:**
  - **More per-stage caches** (the original step 4 of `../design/WARM_REBUILD_REUSE.md`) gives faster wins on the passes ported
    first, but adds a cache and an invalidation rule per pass. That is the source of the bugs described above.
  - **The pass framework before the engine** (the original order): a recorded-read mechanism for passes alone, which
    M4 would then replace. Rejected 2026-11-19.
  - **A rewrite** would lose the parts that work (typer, live patching, the existing precise recorders) and stall
    language and backend work.

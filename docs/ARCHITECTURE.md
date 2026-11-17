# Architecture

## 🧭 What Haxeon is

Haxeon is both a focused Haxe-compatible language implementation and a live
execution environment built on a patchable HashLink runtime.

For the initial application load, the compiler emits a standard HashLink
bytecode module—the same format normally stored in a `.hl` file. Compatible
edits become compact Haxeon patch data containing only changed function bodies
and the symbol additions they require. The runtime validates and JIT-compiles
the entire patch privately before publishing it as one atomic transaction.

Haxeon is not currently a drop-in replacement for the complete Haxe compiler.
Language and standard-library coverage are still expanding, and edits that
change the live module's structure may require a reload.

## 🏗️ How it works

```text
Haxe-compatible source
        │
        ▼
 Lexer → Parser → Type checker
        │
        ▼
 Immutable SSA IR
        │
        ▼
 HashLink lowering and assembly
        │
        ├── Initial build ──→ HashLink bytecode module (.hl)
        │                      + Haxeon identity manifest
        │
        └── Compatible edit → Haxeon patch
                               │
                               └── validate → stage → commit
```

The implementation uses three short format names:

- **HLB** is the standard serialized HashLink bytecode format. Its bytes begin
  with the `HLB` signature and are normally written as a `.hl` file.
- **HLI** is Haxeon's companion identity manifest. It binds a module identity
  and stable Haxeon function IDs to the function slots in an initial HLB module.
- **HLP** is Haxeon's versioned patch protocol. It carries validated symbol
  additions and replacement function bodies between incremental builds and the
  live runtime.

HLI and HLP are Haxeon-specific data formats; neither changes the standard HLB
module, so generated `.hl` files remain compatible with ordinary HashLink.

The frontend is divided into parsing, declaration and type checking, and IR
generation. Modules retain their source, tokens, syntax trees, typed trees,
dependencies, diagnostics, and generated IR. Body and signature fingerprints
allow Haxeon to reuse unaffected artifacts and propagate invalidation only where
required.

IR values are immutable SSA definitions. Assignments create new values, while
condition joins and mutable loop headers receive explicit, predecessor-complete
phi nodes. The HashLink backend eliminates those phis on incoming edges with
parallel-copy snapshots, emits real `OLabel` block markers, and leaves no SSA
constructs in the serialized bytecode module or patch.

The same canonical IR can also be emitted as experimental `wasm32` or `wasm-gc`;
see [`reference/WASM_BACKEND.md`](reference/WASM_BACKEND.md) for the representation
boundary, linear-memory and collector contracts, GC target, and test commands.

## Compiler packages and layering

`compiler.core` (`src/compiler/core`) is the bottom of the compiler: source files and spans (`Source`), diagnostics
(`Diagnostic`, `AmbiguousName`), qualified names, provider operations (`Provides`), preallocated arrays, request cancellation
(`CancellationToken`, `CancellationError`) and the allocation and IR pass meters. Every other compiler package may import it, and it
imports nothing else from the compiler.

The other compiler packages depend in one direction: `core` <- `syntax` <- the front end (`types`, `semantic`, `modules`, `runtime`
and `ffi`, which import each other) <- `ir` <- `abi` <- the backends <- `compilation` and the root `Compiler` <- `service` and
`tools`. The backends are `compiler.hl`, the one home of HashLink (lowering in `compiler.hl.lower`, then the bytecode model, writer,
incremental assembly, patches and persistence), and `compiler.backend.wasm`; both implement `compiler.backend.Backend` and neither
imports the other. A name the IR and a backend both use, such as `IrProgramAssembler.LIVE_INITIALIZER` or
`IrReceiverCheck.CHECK_FIELD`, is declared in `ir` and read by the backend. Which value places can live in registers is
answered in `ir` (`IrScalarValuePlaces`): `IrScalarArguments` and HashLink lowering (`HlScalarValueLocals`) both ask it, so `ir`
no longer imports HashLink lowering. The exceptions that remain: `ir` imports
`runtime` and `ffi` and is imported by `runtime`, `ffi`, `modules.ModuleState` and `semantic.SemanticAssembly`;
`semantic.SemanticAssembly` and `modules.CodeIdentityTable` import `compilation.CompilationContext`, which refers back to the root
`Compiler`; `runtime.CompilerIntrinsics` also names types declared beside the root `Compiler`; and
`syntax.Parser` calls `types.analysis.FinalLocalChecker` and `BindingWalker`.

`compiler.formatter` and `compiler.documentation` sit beside this chain. The formatter imports only `core` and `syntax`, and
`service` uses it. Documentation imports `core`, `syntax` and `modules`, and `ffi`, `service` and `tools` use it.

## Source map

Entry points, in `src/`:

| File | What it is |
|---|---|
| `Main.hx` | The command-line compiler that produces a complete HashLink module. The test driver compiles its program cases with it. |
| `LspMain.hx` | The Language Server Protocol server, over stdio. |
| `EditorServiceMain.hx` | A JSON-lines language service for a Pragtical host process. |
| `FfiImportMain.hx` | The C and C++ header importer, which writes HXI. |
| `FfiAuditMain.hx` | The cross-target C ABI auditor. |
| `LintMain.hx` | The lint rules that need the compiler's analysis (`haxeon lint --only unbound-local`, `module-namespace` or `throw-non-exception`, `tools.TypedLint`), through the language service. |

The project CLI (`tools.HaxeonCli`), the compiler CLI (`compiler.tools.HaxeonCompiler`) and the build workflow
(`build.HaxeonBuild`) are started by main class, through `scripts/haxeon` and the tool cache
([DEVELOPMENT.md](DEVELOPMENT.md#prebuilt-tools-haxeon-dev-tool-path)).

Folders of `src/`:

| Folder | Holds |
|---|---|
| `compiler/` | The compiler. Its packages are in the next table. |
| `build/` | The build and bootstrap workflow (`HaxeonBuild`), project builds (`HaxeonProjectBuild`), build plans and the artifact cache, the client of the compiler worker, and the native CMake build. |
| `project/` | `haxeon.json` manifests, package resolution, the lockfile, and source acquisition from paths, git, haxelib and the registry. |
| `tools/` | The project CLI (`HaxeonCli`), the live host, the Android build and patch commands, lint, the heap inspector, and `tools/dev`: the `haxeon dev` commands for this checkout. |
| `runtime/` | The host side of a reload domain: loaded modules and plugins, patch sets, the plugin lifecycle, and the native call API. |
| `editor/` | Editor adapters: the JSON-lines protocol, the LSP server's pieces (`lsp/`) and the profiler view (`profiler/`). |
| `profiler/` | The profiler session: capture decoding, symbolization and aggregation. |

Packages of `src/compiler/`, bottom layer first:

| Package | Holds |
|---|---|
| `core` | Sources and spans, diagnostics, qualified names, cancellation, meters. |
| `syntax` | Lexer, parser, AST, conditional compilation. |
| `types` | Types, the typed AST, typing of declarations and bodies (`typing/`), and checks over typed code (`analysis/`). |
| `semantic` | Module analysis, declaration owners, aliases, dependency scanning, invalidation, generic specialization. |
| `modules` | Per-module state, the module graph, source loading, the code identity table. |
| `runtime` | What the compiler knows about the runtime: the native registry, intrinsics, runtime shapes and types. |
| `ffi` | C and C++ header import through clang, HXI, projections, the C header emitter. |
| `ir` | The SSA IR, `IrGenerator`, the whole-program passes and `IrPipeline`, the inliner, the verifier, the IR codec. |
| `abi` | Descriptions of every runtime-visible declaration (`RuntimeAbi`) and `PatchPlanner`, which decides whether an edit can patch or needs a reload. |
| `hl` | HashLink: lowering (`lower/`), the bytecode model and writer, incremental assembly (`incremental/`), patches (`patch/`). |
| `backend` | The `Backend` interface, `BackendTargets` (the one parse of a target name), the linear-memory contract, and `wasm/`: the Wasm backend, with `linear/` for `wasm32` and `gc/` for `wasm-gc`. |
| `compilation` | One build: `CompilationPipeline`, `FrontendCompilation`, the backend sessions (`HashLinkBackendSession`, `WasmBackendSession`), and the candidate and publication transactions. |
| root | `Compiler`, the session that holds the last successful build, and `Frontend`, a stateless path from source text to IR. |
| `service` | The language service, the REPL, and the import lints. |
| `tools` | The compiler CLI and driver, the compiler worker (`CompilerServer`, `CompilerSession`) and its wire format (`CompilerServerProtocol`, shared with its clients), the memory and allocation censuses, `BootstrapStatus`. |
| `formatter`, `documentation` | The source formatter; documentation comments and the Haxe XML writer. |

The rest of the repository:

| Path | Holds |
|---|---|
| `stdlib/` | The standard library the compiler builds programs against: Haxe's own files and the `haxeon.*` packages. |
| `lib/haxeon-io/` | The `haxeon.io` classes, a class path of the compiler (`common.hxml`). |
| `native/` | C sources: the runtime compiled into the HashLink VM (`runtime/`), the runtime linked into every `wasm32` module (`wasm/`), and code both share. |
| `vendor/` | Pinned dependencies: the HashLink fork with the patchable runtime and JIT, the HashLink debugger, libffi, NativeKit, utest, and the vendored `format` library. |
| `bootstrap/` | The checked-in compiler, `compiler.hl`. |
| `packages/` | Optional native integration libraries (UI, GPU, audio, platform and others); see [`packages/README.md`](../packages/README.md). |
| `android/`, `extensions/vscode/` | The Android host (Gradle) and the VS Code extension. |
| `tests/`, `benchmarks/` | Test suites, listed in `tests/suites.txt`, and benchmarks. |
| `scripts/`, `cmake/` | Launchers and wrappers; the native build and the pinned tool bootstrap. |

## The backend session

The target name is parsed once into a `BackendTarget` (`compiler.backend.BackendTargets.parse`): by `Compiler.configure` from the
`target` define, which keeps it as `Compiler.backendTarget`, and at the command line's edge (`CompilerArguments`, `CompilerSession`).
Everything after that switches on the enum; nothing compares target strings.

A compilation session has one backend, `Compiler.backend` (`compiler.compilation.BackendSession`), chosen by the target. The pipeline
gives the final IR to `backend.assemble`, and the result's `BackendArtifact` is `CompileResult.artifact`: a HashLink build's module,
function indices, stable function ids, runtime identity (HLI) and patch (HLP), or a Wasm build's module. Callers that know the backend
read it with `BackendArtifacts.hashLink` or `BackendArtifacts.wasm`.

- `HashLinkBackendSession` owns the assembler of the last successful build (layout, stable ids, revisions) and the lowered-function
  cache. It plans and assembles the module and encodes the patch; a plain build writes what the entry reaches (`HlPlainBuild`).
- `WasmBackendSession` runs the Wasm backend on the final IR during the build; a Wasm build runs no HashLink assembly. It owns the
  module it built last (a build whose IR and options are the ones that module was built from gets the same bytes) and the Wasm patch
  state (`patchBase`, `patch`), which keeps its own identities for now. The request's Wasm options reach it through
  `Compiler.backendOptions`. A Wasm build is revision 1 of a fresh module; the driver acknowledges it when it writes it.

The session follows the candidate like the other caches: a build works on `forCandidate()`, the compiler adopts it with the candidate,
and a failed or rejected build (the snapshot, a refused publication) puts the previous one back. `HlBackend`, the stateless HashLink
`Backend` the tests use, is a plain build with no session (`HlPlainBuild.assemble`), so those tests run the shipped assembler.

## Where the IR pass order lives

`compiler.ir.IrPipeline` holds the order of the whole-program IR passes as two named stage lists. `assembly` runs inside
`IrProgramAssembler.assemble`, from the generated functions and the declaration tables to the finished program (the runtime surface and
the entry function are its `runtime-surface` stage). `target` runs from `FrontendCompilation.run` after the frontend has recorded its
positional and live metadata, from the closed enum tag ABI to the inliner and the frontend verifier. A stage wraps an existing pass as it is;
target differences are the stages a target enables, read from `IrPipelineContext` (the `TargetProfile`, the value-array lane target,
live patching and development metadata), not branches at the call sites. The Wasm backend runs its passes before the module builder
as two stage lists, `WasmBackend.logical` and `WasmBackend.erased`, around the GC model's capture of value-array lane shapes. The
module builders still run the rest interleaved with the module they build: the boundary scalar ABI, closure escapes and adapters,
field flattening and the scalar ABI rewrite hand their state to the builder, so they are not separable stages yet.

To add a pass, add a stage at its place in the list: `when` names the targets or inputs it runs for, `measured` gives it a line in the
pass allocation report under the stage name, and `checksPrune` makes the early prune's check mode (`--check-reuse`) hold after
it. The lists are built once; running one costs a predicate and a call per stage.

## Warm builds: what landed (M0 and M1 of ADR 0003)

The current plan and the measurements are in [`design/WARM_REBUILD_REUSE.md`](design/WARM_REBUILD_REUSE.md) and
[`reports/2026-11-compiler-memory.md`](reports/2026-11-compiler-memory.md). This section is the short record.

### Layers of a plain build

A plain build goes from the typed program to IR (`IrGenerator`), then the whole-program IR passes and `IrInliner`, then
verification, then HashLink lowering (`HlLower`), then the writer. Each stage keeps what the next build can reuse:

- **Pipeline shortcut.** When the typed-function IR, the canonical tables and the environment text (target, defines,
  `ProgramFacts.inputState`) equal the last plain build's, the final IR and the module bytes are reused (`reused: ir+module`).
  A miss says why (`--timings`).
- **Per-function verification.** `IrVerifier` reads the rest of the program only through `IrVerifyTable`s. `IrVerifyMemo` records what
  each accepted function read, so a build verifies the functions that changed and the ones whose reads changed.
- **Relocatable lowering.** `HlLower` records, for every function, the requests it made to the symbol tables and the facts it read about
  object types (through `HlLoweringView`, the only way lowering sees another entity). `HlLink` replays them against the next build's tables
  and gives the function its indices, so a function whose IR and facts are unchanged is linked, not lowered again.
  `HlLoweredCache` holds the entries.
- **Live patching** uses the same cache with trust instead of replay: append-only tables and stable slots keep a kept function's operands
  valid, so an entry not named in `regenerated` is kept as it is (`HlModuleAssembler.livePatching`).

### What generation reads

- `TargetProfile` (`HashLink` or `Wasm`): `packedValueFields`, `headerlessValueClasses`, `dynamicObjectLiterals`, `nativeArrayChecks`,
  `nativeStringFastPaths`, `nativeReflectionDispatch`. Immutable; `key()` is part of every cache key that depends on the target.
- `ProgramFacts.of(typed)`: enum constructor counts, value classes, class bases, generic owners, equatable and observable facts, interface
  contracts. Derived on every build.
- `IrGenerator` is an instance over `(facts, profile)`, with `withObjects(objects)` giving it the program's object tables as input and a
  fresh `FunctionScratch` per function. No generator state outlives a build. Left static on purpose: the `HAXEON_*` switches, a debug-location
  memo, and the Wasm caches (a follow-up).

### Session caches and the commit point

Everything a build owns is one `SessionState`: the modules, the types, the generic specializations, the inline cache, the pipeline
snapshot, the backend with its lowered cache, the reachability cache and the declaration owners. A build works on
`state.copyForCandidate()` and `adoptCandidate` makes that copy the compiler's state; the state it was copied from is the snapshot a
pending publication keeps, so a rejected or retracted build puts it back with one assignment. A failed build leaves the state alone.
`validate` and the REPL run on such a copy and drop it. The verify memo is shared between copies because an acceptance holds only
while its reads do.

### Check mode

`--check-reuse` recomputes what a build reused and fails, naming the function, when the two differ: the shortcut is re-run, every
linked function is compared with a fresh lowering, the final IR is verified in full after the memoized run, and in a live build every kept
function is lowered again (`HlFunctionEquality`: type, slot, registers, opcodes with labels compared one to one, debug data). Functions
frozen on purpose (retired by a signature change, or dropped from the program) are skipped. The full driver suite and `test-hot-reload` pass
with it. It is a test aid, never a fallback.

The performance rules for compiler code are in [DEVELOPMENT.md](DEVELOPMENT.md#performance-rules-for-compiler-code).

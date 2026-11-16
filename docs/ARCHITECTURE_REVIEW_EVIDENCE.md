# Haxeon architecture review: evidence (2026-11-16)

Supporting detail for [ARCHITECTURE_REVIEW.md](ARCHITECTURE_REVIEW.md): each reviewer's evidence, cost statement and proposal as reported, plus the things reviewers judged odd but justified. Line numbers refer to the tree between `23800dca` and `c6cfd889`. Apart from the claims listed under Verification in the main report, these are reviewer claims that were not independently confirmed.

## Cross-cutting (whole repo)

### Wasm builds run a full HashLink assembly that is thrown away; the Backend seam is not on the production HL path

Architecture; severity high, effort L, risk medium.

**Evidence.** src/compiler/compilation/BackendAssembly.hx:101-111 ("Compilation sessions retain a HashLink assembly even when the requested artifact is Wasm": ir.copy() + IrScalarClosures.rewrite + IrEnumTagLowering.escapes), :156-171 (HlModuleAssembler.assemble always runs), then src/compiler/tools/CompilerDriver.hx:67-86 runs WasmBackend on result.ir. isWasmTarget() is consulted at 21 sites (FrontendCompilation 9, BackendAssembly 8). Compiler.hx session fields are HL-typed (assembler:HlModuleAssembler, loweredCache:HlLoweredCache; CompileResult.module:HlCode at Compiler.hx:108). interface Backend (src/compiler/backend/Backend.hx:47) has 2 implementations; HlBackend (src/compiler/backend/hl/HlBackend.hx, 25 lines) has 0 references in src and is only used by tests/compiler/*Main.hx; the only src user of the interface is CompilerDriver.hx:84.

**Cost.** Every Wasm compile pays an IR copy, two extra rewrites, HL lowering and HL encoding for bytes nobody reads; an HL-lowering limitation or bug fails a Wasm build; Wasm incremental reuse lives outside the session (CompilerSession.wasmModule keyed by JSON of options) instead of in the transaction, so Wasm does not get candidate/rollback semantics. The ROADMAP statement "each backend owns its encoding, stable symbol tables and ABI validation" is not true of the code, and the 21 isWasmTarget branches will keep growing.

**Proposal.** Make the target a session-level backend object: move HL assembly/patch planning (BackendAssembly.assemble body, assembler, loweredCache, publishedAbi-by-HL) behind a session backend interface with an HL implementation and a Wasm implementation (which owns its module cache and WasmPatchState). CompilationPipeline calls backend.assemble(ir, changes); CompileResult carries a backend artifact instead of HlCode. Then delete the Wasm branch in BackendAssembly and fold HlBackend into the HL implementation's stateless entry (tests keep a one-line helper).

### IR pass pipeline is split between IrProgramAssembler.assemble and the tail of FrontendCompilation.run

Architecture; severity high, effort M, risk medium.

**Evidence.** src/compiler/ir/IrProgramAssembler.hx:574-1166 runs ~12 metered passes (enum-dynamic-dispatch ... nullable-scalar-fields, lines 648-775); src/compiler/compilation/FrontendCompilation.hx:768-855 runs the rest (value-array-rewrite, value-constructors, scalar-arguments, scalar-closures, scalar-replacement, nullable-scalar-flow, inliner, verifier, entry prune). FrontendCompilation.run is one 866-line function (lines 82-948) with 33 timing/allocation sample points; it is the #1 churn file in src (31 of last 500 commits), IrProgramAssembler #2 (28), and they are the top co-change pair (10 shared commits). IrProgramAssembler (1384 lines) also holds typed->IR declaration lowering (objectsFrom :336, enumsFrom :302, staticInitializersFrom :98). ir imports upward for metering: IrProgramAssembler uses compiler.compilation.IrPassMeter 12 times.

**Cost.** Nobody can read the pass order in one place; a pass-ordering change needs edits in two packages (visible in the co-change data); a class named Frontend* owns IR optimisation, verification and reuse snapshots, so the function keeps growing and every pipeline change conflicts with every invalidation change in the same 866-line body.

**Proposal.** Introduce compiler/ir/pipeline/IrPipeline.hx that owns the ordered pass list (name, run, enabled-predicate on TargetProfile/live) and is the single caller of IrPassMeter; IrProgramAssembler keeps only typed->IR declaration building; FrontendCompilation.run is cut into parse/semantic, type, generate, and a call to IrPipeline.run, each returning its own timing record. Move IrPassMeter and AllocationMeter (47 and 61 lines, no compiler imports) to a leaf package so ir/hl/types stop importing compilation.

### TypingSession is a 55-map shared blackboard with a body-context stack and order-dependent counters

Architecture; severity high, effort L, risk high.

**Evidence.** src/compiler/types/typing/TypingSession.hx:51-158 and :352-455 declare ~55 public mutable maps/arrays (lambdaCache, anonymousTypes, wireCodecRequests, valueEqualityRequests, hashRequests, flagsRequests, keyPathDefinitions, inlineConstants, noReturnFunctions ...), a context stack bodyContexts (:85) read through currentContext (:160), and numbering counters functionAdapterCounts (:154), substrCounts (:156), lambdaVariants (:80). 40 direct write sites into session.* from 19 typer files. Typer.hx:19-37 builds one BodyTyper/session for the whole program.

**Cost.** This, not the 30 static vars, is what blocks ROADMAP B "parallel parse and type work with deterministic assembly": two function bodies cannot be typed concurrently because requests, anonymous-type registration and the context stack are shared, and generated-helper names depend on the order bodies are typed (counters). It also makes incremental reasoning harder: which unit registered what is reconstructed after the fact (recordAnonymousUse via bodyContexts[1]).

**Proposal.** Split the session into (1) an immutable program view (decls, relations, representation, externals) and (2) a per-unit TypingOutput record (requests, anonymous uses, lambda cache entries, dependencies, counters scoped by unit name). BodyTyper writes only to the current unit's output; ProgramTyper merges outputs in sorted unit order. That gives deterministic assembly today and makes per-unit typing a pure function of (view, unit) when parallelism is wanted. Do it before the Pragtical measurement only if the measurement asks for it, but stop adding new session-level maps now.

### Body typer split into 5 classes wired back together with 42 callback typedefs

Overengineering; severity medium, effort M, risk medium.

**Evidence.** 42 `typedef *Callback` in src/compiler/types/typing (CallResolver 11, ExpressionTyper 10, ClosureTyper 10, StatementTyper 7); BodyTyper.hx:76-220 constructs them with 62 closures that only forward to this.* (e.g. :116-125, :127-139, :141-155). Each callback has exactly one implementation (the BodyTyper method); `new ExpressionTyper/CallResolver/StatementTyper/ClosureTyper` each occur once (BodyTyper.hx:86-140). The classes are not independent: ExpressionTyper co-changes with BodyTyper in 9/12, CallResolver 8/11, StatementTyper 7/10 commits; BodyTyper additionally needs 8 @:allow grants (BodyTyper.hx:48-55). Sizes: BodyTyper 2858, ExpressionTyper 2589, CallResolver 2403 lines.

**Cost.** Every recursive typeExpression call goes ExpressionTyper -> closure -> BodyTyper.typeExpression -> ExpressionTyper (an extra dynamic call per AST node in the hottest loop of a compiler whose profile is flat and allocation-bound); adding one cross-cutting helper means a typedef, a constructor parameter, a field and a closure; go-to-definition lands on a typedef. The split gives file-size relief but no isolation.

**Proposal.** Replace the callback typedefs with one small interface (e.g. BodyTyping with typeExpression, coerce, lowerType, arrayElementType, typedMember, findFieldType, ...) implemented by BodyTyper and passed once to each collaborator, or simply give collaborators a `final body:BodyTyper` reference inside the package. Keep the file split; delete the 42 typedefs and the 62 forwarding closures.

### HashLink backend code lives in three packages with an ir<->hl import cycle; Wasm lives in one

Organization; severity medium, effort M, risk low.

**Evidence.** compiler/hl (26 files, 6.6k lines: bytecode model, writer, validator, incremental assembler, patch, persistence), compiler/ir/hl (7 files, 2.6k lines: HlLower 2220 lines, HlLoweringView, PhiEdges...), compiler/backend/hl (1 file, 25 lines). ir -> hl: 14 imports in 2 files (src/compiler/ir/hl/HlLower.hx:4-28, HlDebugMetadataCache.hx:3-4); hl -> ir: 27 imports in 9 files, and HlModuleAssembler imports compiler.ir.hl.HlLower/HlDebugMetadataCache (src/compiler/hl/incremental/HlModuleAssembler.hx:9,26) and calls HlLower.* statics (:580, :803-822). The ir package also names the Wasm backend directly: src/compiler/ir/IrVerifier.hx:1363 (WasmFlattenValueFields.CHECK_FIELD), src/compiler/ir/IrOpportunityCensus.hx:42-67.

**Cost.** The package named `ir` cannot be read or tested as the target-neutral layer the ROADMAP describes; HL lowering changes (22 commits on HlLower) land in the busiest directory (ir: 108 flat files, touched by 133/500 commits); new contributors look for the HL backend under backend/ and find a 25-line adapter.

**Proposal.** Move compiler/ir/hl/* to compiler/backend/hl/ (or compiler/hl/lower/) so the dependency is one-way backend->ir; keep compiler/hl as the bytecode-format package or nest it as backend/hl/format. Move the Wasm check field constant into an ir-level constant the Wasm backend references, and move IrOpportunityCensus.reportWasm into backend/wasm.

### Runtime intrinsics are identified by string literals repeated across registry, typer ABI and three backends

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/compiler/backend/wasm/gc/WasmGcRepresentation.hx:2233-3773 lowerRuntimeCall is a single 1540-line method with 82 sequential top-level `if (name == "...")` tests over 94 distinct names, many with 2-3 aliases (e.g. :2870 `"__bytes_get_i32" || "getI32"`). 87 of those 94 literals also appear in backend/wasm/linear or shared wasm files, 64 in compiler/runtime|ir|types|semantic. One name, `__bytes_get_i32`, is spelled in 6 places: CompilerIntrinsics.hx:36 (PURE list) and :85 (definition), PlatformAbi.hx:70, WasmGcRepresentation.hx:2870, WasmGcModuleBuilder.hx:825, WasmLinearRuntime.hx:554.

**Cost.** Adding or renaming an intrinsic is a grep across 5-6 files with no compiler help; a typo in one backend is a silent fallthrough to UseDefault rather than an error; the GC backend does up to 82 string compares per runtime call lowered; the purity list (CompilerIntrinsics.PURE) can drift from the definitions it annotates.

**Proposal.** Define intrinsics once as an enum abstract (or a table of records: id, symbol, aliases, signature, pure) in compiler/runtime; NativeRegistry resolves a call's name to the id once. Backends switch on the id (exhaustiveness-checked) and lowerRuntimeCall becomes a dispatch to per-family methods (bytes, math, reflect, struct, string) of ~100 lines each.

### God functions: four 800-1500-line switch/if bodies concentrate most of the churn

Organization; severity medium, effort M, risk low.

**Evidence.** WasmFunctionLower.lowerInstruction: 1466 lines (src/compiler/backend/wasm/WasmFunctionLower.hx:944-2409; the file is also the only src file indented with 2 spaces, 152 space-indented vs 3 tab lines, so the formatter contract is not applied to it). WasmGcRepresentation.lowerRuntimeCall: 1540 lines (class is 7383 lines, 167 methods, 167 fields/locals at member level). IrGenerator.lowerExpressionAt: 1378 lines (src/compiler/ir/IrGenerator.hx:1932), lowerStatements 647 lines (:447). HxiHaxeEmitter.sourceRaw: 859 lines (src/compiler/ffi/HxiHaxeEmitter.hx:409). SemanticAssembly.run: 804 lines (src/compiler/semantic/SemanticAssembly.hx:43) with 10 parameters. HlLower.lowerFunction: 639 lines (:722). Overall 341 functions >= 100 lines in src.

**Cost.** These are exactly the files with the highest churn (IrGenerator 20, HlLower 22, WasmFunctionLower 16 commits in 500), so every feature edits the same giant function: large diffs, hard review, and in self-hosted builds one changed body means retyping/relowering a 1.4k-line function. Local variables of the huge function act as implicit shared state between unrelated cases.

**Proposal.** Mechanical extraction, one family per method, keeping the dispatching switch: IrGenerator.lowerExpressionAt -> lowerCall/lowerField/lowerSwitch/lowerLiteral...; WasmFunctionLower.lowerInstruction -> per-instruction-group methods and reformat the file to tabs; SemanticAssembly.run and FrontendCompilation.run -> phase methods returning a result record. No behaviour change, do it file by file.

### Leaf utilities placed in high-level packages create upward imports and the compiler-root grab bag

Organization; severity medium, effort S, risk low.

**Evidence.** compiler.service.CancellationToken (39 lines, no compiler imports) is imported by semantic (SemanticAssembly.hx:13, SemanticIndex.hx:19, SemanticWorkspace.hx:12), modules (ModuleReachability.hx:5), compilation (5 files) and Compiler.hx:29. compiler.compilation.AllocationMeter (61 lines) is imported by types (ProgramTyper.hx:4, TypingMetrics.hx:3), ir (HlLower.hx:30) and hl (HlModuleAssembler.hx:27). compiler.semantic.LambdaName (76 lines) is imported by abi (3 files) and hl. syntax/Parser.hx:700 and :1425 call compiler.types.analysis.FinalLocalChecker/BindingWalker; 13 of 24 files in types/analysis (2173 lines incl. PurityInference 986) import only syntax.Ast, no type model. compiler.ffi.NativeLayout is imported by 5 typer files and semantic while itself importing types. The package root mixes the top orchestrator Compiler.hx (1156 lines; its typedefs CompileResult/FfiInterfaceSource/NativeFunction/ReachabilityCache are imported by ffi, runtime, compilation) with bottom primitives Source (used by 93 files), Diagnostic (47), Provides (40), QualifiedName (16).

**Cost.** These few files are what turn a layered graph into 18 mutual package pairs, so no subpackage can be compiled, tested or reasoned about without the whole compiler; `service` (LSP-facing) appears as a dependency of semantic analysis.

**Proposal.** Create compiler/core (or compiler/base) for Source, Diagnostic, QualifiedName, Provides, Arrays, CancellationToken, AllocationMeter, IrPassMeter; move the AST-only analyses to compiler/syntax/analysis (or compiler/semantic); move LambdaName next to abi's naming code; move CompileResult/AnalysisResult/Ffi* typedefs out of Compiler.hx into compilation/ and ffi/. Pure moves plus import rewrites.

### CompilationContext is a 50-method forwarding facade over Compiler, and Compiler still carries the FFI registry

Overengineering; severity low, effort M, risk medium.

**Evidence.** src/compiler/compilation/CompilationContext.hx: 281 lines, 50 functions, 53 `owner.` forwards, 10 get/set properties that proxy Compiler fields (:53-62), with Compiler granting @:allow to it and to both transactions (Compiler.hx:236-238). Compiler <-> compilation is a mutual dependency (7 imports one way, 14 the other). Compiler.hx:444-625 (~180 lines, 18 functions, 9 ffi* fields at the class head) implements HXI interface/projection registration, composition and ABI caches inline.

**Cost.** The "narrow, typed access" comment is no longer true: the facade exposes nearly all session state, so it adds a hop without restricting anything, and every new piece of session state needs a field in Compiler, a copy in createCandidate/adoptCandidate/snapshot and a forwarder here (four places to forget one; a missed copy is a rollback bug).

**Proposal.** Extract the build-scoped state (modules, graph, caches, assembler, publishedAbi, pipelineSnapshot, verifyMemo ...) into one SessionState class with copy()/adopt() so candidate/snapshot logic is one method; pass SessionState to the pipeline directly and delete the forwarders. Move the FFI block into compiler/ffi/FfiRegistry owned by the session. Unfinished-seam caveat: keep the transaction classes as they are.

### JSON field readers and small filesystem helpers are re-implemented per file

Organization; severity low, effort S, risk low.

**Evidence.** `requiredString` is defined as a private static in 14 files and `optionalString` in 8 (src/project/PackageManifest.hx:315, PackageLockfile.hx:127, RegistryIndex.hx:171, FfiManifest.hx:165, HaxelibSourceAcquirer.hx:123, PackageSourceCodec.hx:53, src/tools/HaxeonCli.hx:1446, src/editor/lsp/LspProtocol.hx:1533, src/editor/LanguageServiceProtocol.hx:185, src/compiler/ffi/HxiProjectionProfile.hx:200, src/compiler/backend/MemoryContract.hx:85 ...); `ensureDirectory` in 11 files (6 byte-identical: RegistrySourceAcquirer.hx:81, GitSourceAcquirer.hx:75, RegistryPublisher.hx:80, HaxelibSourceAcquirer.hx:137, AndroidBuild.hx:108, ...). Exact-duplicate static bodies overall: 23 groups, ~405 lines (also expectedFunctionType x3 and anonymousField x3 and copyMap x4 inside types/typing; nextId x4 across ir and backend/wasm).

**Cost.** Low but real: error wording for malformed manifests differs per file, and fixes (e.g. a path-in-message improvement) have to be repeated; the typer duplicates are a symptom of the callback split above.

**Proposal.** One `project.JsonFields` (required/optional string, int, array, with a path-aware error) used by project, tools and editor; one `Directories.ensure` (src/build/execution/Directories.hx already exists) used by the 11 sites; fold the typer triplicates into TypingSession/TypeRepresentation statics.

### Entry points and names that mislead: src/Main.hx, two `runtime` and two `tools` packages, hand-maintained TestCatalog

Organization; severity low, effort S, risk low.

**Evidence.** src/Main.hx (125 lines, build.hxml `-main Main`) is documented as "Command-line compiler entry point" but is the test-suite driver (--batch, --warm-edit, --no-early-prune; Main.hx:22-63), while the real entry is compiler.tools.HaxeonCompiler -> CompilerDriver and tools.HaxeonCli (1590 lines, 57 static functions). src/runtime (19 files, host/live-module API) vs src/compiler/runtime (8 files, intrinsic registry), linked by compiler/tools/CompilerSession.hx:20 importing runtime.LiveRefusal; src/tools (CLI) vs src/compiler/tools (driver/server/session). project <-> build is a cycle (build->project 15 imports, project->build 6: build.Target and build.execution.ProcessRunner). tests/driver/TestCatalog.hx lists 279 test-main names by hand (285 commits in history; 54 of the last 500 commits touch it) although tests/compiler has 239 *Main.hx files that could be discovered.

**Cost.** Navigation cost and merge conflicts on TestCatalog in roughly one commit out of nine; a test file that is not registered silently never runs.

**Proposal.** Rename src/Main.hx to tests-oriented `ProgramSuiteMain` (or move under src/tools/dev); rename compiler/runtime to compiler/intrinsics and compiler/tools to compiler/driver; move build.Target and ProcessRunner to a shared leaf used by project and build; have TestCatalog discover tests/<suite>/*Main.hx by directory with an explicit exclusion list.

### Small dead or speculative pieces

Overengineering; severity low, effort S, risk low.

**Evidence.** src/compiler/runtime/wasm/WasmRuntimeContract.hx (13 lines) has 0 references in src, tests, scripts or packages. src/project/ProjectManifest.hx (5 lines, "compatibility alias for callers that still use the v1 project name") has 0 references anywhere. BackendTarget.Wasm64 (src/compiler/backend/Backend.hx:11) is accepted by CompilerDriver.hx:55 and described in WasmTarget.hx:35 but WasmBackend.compileInternal throws "not implemented yet" (docs/WASM_BACKEND.md:264 says the same). WasmBackend.compilePatch/compilePatchBase (WasmBackend.hx:23-58) are called only from tests/compiler/WasmBackendMain.hx and WasmTypeIdPlanMain.hx. 33 distinct HAXEON_* environment switches are read at 49 sites in 31 files via Sys.getEnv, 11 of them not mentioned in docs/scripts/tests (e.g. HAXEON_COMPILER_CENSUS_STEPS, HAXEON_INSTRUMENT_INCLUDE).

**Cost.** Minor: dead files mislead readers; wasm64 on the CLI produces a late throw instead of an argument error; scattered getEnv reads (three are evaluated in static initialisers: IrInliner.hx:202, IrLoadStoreForwarding.hx:16, IrStrengthReduction.hx:9, while Main.hx:38 mutates the environment per batch request) make per-request configuration in a persistent compiler server unreliable.

**Proposal.** Delete WasmRuntimeContract.hx and ProjectManifest.hx; reject wasm64 in CompilerArguments until implemented (keep the enum case); gather the HAXEON_* reads into one CompilerSwitches record built per request and passed through CompilationContext, documented in one table. Leave the Wasm patch API: it is the seam for Wasm live patching.

### Leave alone

- Parallel gc/ and linear/ Wasm file sets (src/compiler/backend/wasm/gc/WasmGc*.hx vs linear/WasmLinear*.hx: DynamicArrays, ValueArrays, Reflection, ClosureAdapters, EnumStringTable, LaneStorage, ModuleBuilder, Representation): two genuinely different memory models behind WasmRepresentation; only sameHeapType/sameBitSet-sized helpers are duplicated. Do not merge.
- Static sentinel arrays that look like shared mutable state but are identity markers or append-only memo tables: src/compiler/ir/IrOperands.hx:22-24 (noInputs/matchedInputs), IrDeadPureValues.hx:15, IrEnumDynamicDispatch.hx:10, DeclarationIndex.hx:204, TypingSession.hx:239, CfgBuilder.hx:26 (operandNames), Lexer.hx:315 (operators intern table). They avoid allocation in hot loops; they only need attention if threads are actually introduced.
- Single-entry static caches IrProgramIndex.cached (src/compiler/ir/IrProgramIndex.hx:16) and IrMethodResolution.cached (:15): validated against the program on every use (`matches(program)`), they removed quadratic scans. Fine for a single-threaded pipeline.
- The transaction/candidate machinery (src/compiler/compilation/CompilationTransaction.hx, AnalysisTransaction.hx, CompilerPublication.hx, Compiler.createCandidate/adoptCandidate at Compiler.hx:978-1010): looks heavy but is what makes failed builds and rejected publications roll back atomically; ROADMAP B depends on it.
- HAXEON_CHECK_REUSE paths that recompute what was reused (9 getEnv sites, e.g. BackendAssembly.hx:179-193, IrEntryPrune.watch at IrEntryPrune.hx:84-100): deliberate check mode documented in docs/ARCHITECTURE.md, not dead parallel code.
- Codec/equality pairs that must be edited together (src/compiler/ir/codec/IrFunctionStateCodec.hx and IrFunctionStateEquality.hx, 14 commits each; src/compiler/hl/HlFunctionEquality.hx; hl/persistence/*StateCodec.hx): they back persisted assembler state and reuse checks; the co-change with IrFunction.hx is inherent to an enum IR.
- Alias files with the same basename in packages/ui/haxe/haxeon/ui/widgets/text (Utf8Offset, Utf16Offset, TextRange, TextOffsetMap, GraphemePosition, CodepointOffset: 4-11 line typedefs to haxeon.editor.*) and the two CodeIdentityTable files (stdlib/haxeon/build/CodeIdentityTable.hx is the runtime-side table the compiler rewrites; src/compiler/modules/CodeIdentityTable.hx generates it). Not duplication.
- Two ProgramFacts types (src/compiler/semantic/ProgramFacts.hx, a 13-line typedef of purity/no-return answers, and src/compiler/ir/ProgramFacts.hx, 311 lines of generation facts): different concepts; a rename of the semantic one would help, merging would not.
- Files referenced only from tests or scripts and intentionally kept: src/compiler/ir/IrInterpreter.hx (1017 lines, differential oracle for IR tests), src/compiler/service/Repl.hx, src/runtime/RuntimeDomain.hx and LoadedPlugin.hx (host API exercised by tests/tooling/PluginMain.hx), src/tools/Android*.hx and src/compiler/tools/BootstrapStatus.hx (script entry points), src/EditorServiceMain.hx, LspMain.hx, FfiAuditMain.hx.
- src/compiler/ffi at 11.8k lines with a 3081-line HxiHaxeEmitter is large but self-contained (only NativeLayout/HxiAbi leak into the typer); it has low churn (9 of 500 commits) and is not worth restructuring now beyond splitting sourceRaw.

## IR (`src/compiler/ir`)

### The pass pipeline has no owner: ordering is spread over six files with target branches and repeated rescans

Architecture; severity high, effort L, risk medium.

**Evidence.** src/compiler/ir/IrProgramAssembler.hx:574-1164 (`assemble`, 591 lines, 16 parameters, 37 null checks on optional tables) runs about 20 passes inline. src/compiler/compilation/FrontendCompilation.hx:803-856 runs 10 more, with `if (context.isWasmTarget())` / `if (!context.isWasmTarget())` branches that duplicate the sequence (lines 810-824). Further pass calls are in src/compiler/compilation/BackendAssembly.hx:108-122, src/compiler/backend/wasm/WasmBackend.hx:75-80, src/compiler/backend/wasm/WasmScalarClosureEscapes.hx:50-84 and src/compiler/backend/wasm/linear/WasmLinearModuleBuilder.hx:124-206. `IrEnumTagLowering.escapes` is called at 5 sites (IrProgramAssembler.hx:1161, FrontendCompilation.hx:831, BackendAssembly.hx:110, WasmScalarClosureEscapes.hx:84, WasmLinearModuleBuilder.hx:149). `IrValueInterfaceBoxes.rewrite` and `IrCheckedDynamicCasts.rewrite` are re-run on late helper batches at 4 sites (IrProgramAssembler.hx:697 and 766, WasmScalarClosureEscapes.hx:50-51, WasmLinearModuleBuilder.hx:137-138). Pass signatures differ: `rewrite(program):Void`, `rewrite(functions, objects):Array`, `new X(objects).rewrite(...)`, and passes that push into the input array (`IrTypedInterfaceDispatch.generate`, detected by a length comparison at IrProgramAssembler.hx:692-698). The `Pass<C,S>` interface in docs/IR_PASS_INVENTORY.md is marked 'proposal, no code'.

**Cost.** Correctness depends on where a helper generator is inserted; docs/ENUM_PASS_PHASE_ORDER.md says so itself. Adding or moving a pass means editing up to 6 files and re-deriving which rescans cover it. The measured edit-build cost (71% of IR-assembly allocations in passes that do not notice only 625 of 34,000 functions changed, per docs/IR_PASS_INVENTORY.md) cannot be fixed per pass while there is no single place to hang caching or check mode. The HashLink and Wasm orders can drift apart silently.

**Proposal.** Land the inventory's 'framework commit' as a pure move first. Add one `compiler.ir.IrPipeline` holding an ordered list of named stages per target (HashLink plain, HashLink live, Wasm32, WasmGc). Each stage is `(IrProgram, PassContext) -> IrProgram`, where the context carries profile, facts, tables, meter and check hooks. Have `assemble`, the FrontendCompilation.hx:803-856 block and the BackendAssembly/Wasm tail call it. Metering (`IrPassMeter.measure`), the `IrEntryPrune.checkRemoved` hook and the enum-escape resolution boundary become properties of the stage list instead of hand-placed calls. Unported passes run as opaque stages, as the inventory's rule 6 already says.

### IrGenerator is a 4,272-line class with two functions of about 650 and 1,190 lines that hold every feature's lowering

Organization; severity high, effort L, risk medium.

**Evidence.** src/compiler/ir/IrGenerator.hx: `lowerStatements` is lines 447-1094 and `lowerExpressionAt` is lines 1932-3123. The same class holds map ABI lowering (1131-1320), flat/FFI record loads and stores (1417-1836), optional-field places (1448-1745), the observable/reactive runtime with hard-coded class names (106-108, 3772-3893), an insertion sort emitted as IR (`lowerArraySort`, 3124-3310), switch pattern lowering (3353-3578), `lowerType` (3656) and value-array indexOf/remove (4167-4253). It is the most-churned file in the scope: 96 of the last 400 commits that touch src/compiler/ir.

**Cost.** Every Haxe-parity fix (the top roadmap priority) lands in the same two giant switches. Review and merge conflicts concentrate there, and so does self-compile time for one class. Library-specific knowledge (haxeon.reactive.*) sits in the core lowering, so a library change means a compiler-core change. Finding the lowering of one construct means scrolling a 1,200-line switch.

**Proposal.** Keep IrGenerator as the per-function driver (scratch state, `generateFunction`, the statement/expression dispatch) and move feature groups into collaborator classes that take the generator and builder: `IrMapLowering`, `IrFlatValueLowering`, `IrOptionalPlaceLowering`, `IrObservableLowering`, `IrSwitchLowering`, `IrArrayLowering` (sort, indexOf, remove), with `lowerType` in an `IrTypeLowering` that IrProgramAssembler also uses. Make each `case` of the two big switches a one-line call. This is mechanical and can go one group per commit, each checked by self-hosted hash equality.

### IR type equality has five implementations, and `Std.string(type)` is used as identity although the code documents it as runtime-dependent

Architecture; severity medium, effort M, risk low.

**Evidence.** The canonical one is src/compiler/ir/IrTypeIdentity.hx:26-40 (`same`), with only 10 call sites. Its header (lines 5-10) states that `Std.string` prints arrays differently under stock Haxe and Haxeon. The others: `IrVerifier.sameType` (src/compiler/ir/IrVerifier.hx:1626-1672, 95 call sites across ir and the Wasm backend, falls back to `Type.enumEq`); `CfgVerifier.sameType` (src/compiler/ir/cfg/CfgVerifier.hx:489); `IrGenerator.sameIrType` (src/compiler/ir/IrGenerator.hx:1373); `HlModuleAssembler.sameType`, which compares `Std.string` text (src/compiler/hl/incremental/HlModuleAssembler.hx:411); and 78 raw `Type.enumEq` comparisons in src/compiler/ir. `Std.string(type)` builds names or keys at src/compiler/ir/IrNullableScalarFlow.hx:279, IrCheckedDynamicCasts.hx:47, IrEnumEscapeReach.hx:57 and 69, IrStaticNullChecks.hx:124, IrInliner.hx:411 (object fingerprint), codec/IrFunctionStateCodec.hx:460 and cfg/CfgIteratorReplacement.hx:95. `IrTypeTools.erase` compares with `Std.string` at src/compiler/ir/IrTypeTools.hx:40, one line after using `IrTypeIdentity.same`.

**Cost.** For any type containing `Function([...])`, a stock-built and a Haxeon-built compiler can produce different helper names, map keys and fingerprints. That undermines the self-hosting equality checks and differential testing the project relies on. A new IrType constructor must be taught to up to 5 equality functions. `Type.enumEq` and `Std.string` are reflective and allocate, on paths the ARCHITECTURE performance rules try to keep allocation-free. Semantic checks route through the verifier class for a non-verification purpose.

**Proposal.** Make `IrTypeIdentity.same` and `IrTypeIdentity.text` the only equality and text. Turn `IrVerifier.sameType` into a forwarding inline and then replace its 95 uses mechanically. Delete the CfgVerifier, IrGenerator and HlModuleAssembler copies. Replace the 8 `Std.string(type)` name/key sites with `IrTypeIdentity.text`. Add a grep check to scripts/ that fails on `Std.string(` applied to an IrType and on `Type.enumEq(` in src/compiler/ir.

### Target-neutral IR code depends on the HashLink and Wasm backends, and HashLink lowering lives inside the ir package

Architecture; severity medium, effort M, risk low.

**Evidence.** src/compiler/ir/IrScalarArguments.hx:139 and 175 instantiate `compiler.ir.hl.HlScalarValueLocals` and `HlLoweringView` to decide the scalar ABI, and this pass also runs for Wasm (FrontendCompilation.hx:814). src/compiler/ir/IrVerifier.hx:1363 special-cases `compiler.backend.wasm.WasmFlattenValueFields.CHECK_FIELD`; IrVerifier.hx:581-890 and 1238-1256 hard-code the `IrHlScalarRef` ADDRESS/LOAD/STORE helper names. src/compiler/ir/IrProgramAssembler.hx:169 reads `compiler.hl.incremental.HlModuleAssembler.LIVE_INITIALIZER`. src/compiler/ir/IrOpportunityCensus.hx:12-67 calls `HlWriter` and `WasmEncoder`. The ir package imports `compiler.compilation` (IrPassMeter, 14 references; AllocationMeter at hl/HlLower.hx:30). src/compiler/ir/hl/ (7 files, 2,598 lines) and src/compiler/hl/incremental import each other (HlLower.hx:13 and 27; HlLink, HlLoweredCache, HlLoweredFunction and HlModuleAssembler import compiler.ir.hl). `PhiEdges`, a generic edge splitter, sits in ir/hl but is used by src/compiler/backend/wasm/WasmFlattenValueFields.hx:11. The Wasm backend lives entirely in src/compiler/backend/wasm, and src/compiler/backend/hl/HlBackend.hx is a 25-line wrapper. Target identity is passed four ways: `TargetProfile` (HashLink|Wasm), `IrValueLaneTarget` (HashLink|Wasm32|WasmGc), `BackendTarget`, and bare values (`pointerBits` at FrontendCompilation.hx:807, `!context.isWasmTarget()` at 828).

**Cost.** The roadmap rule 'each backend owns its encoding' is not enforceable. A third target (the C target that TargetProfile.hx:3 anticipates) has no clean seam. A change to HashLink local-slot lowering silently changes which functions get the scalar ABI on Wasm. The ir <-> hl.incremental cycle prevents testing or compiling the IR layer without the HashLink container code. Readers looking for 'the HashLink backend' must search three packages.

**Proposal.** (1) Move src/compiler/ir/hl/* to src/compiler/backend/hl/ next to HlBackend, and move `PhiEdges` to src/compiler/ir/cfg or the ir root. (2) Extract the eligibility predicate `IrScalarArguments` needs from `HlScalarValueLocals` into a neutral `IrScalarValuePlaces` analysis that both IrScalarArguments and HlLower consume. (3) Declare `CHECK_FIELD` and `LIVE_INITIALIZER` in ir (the backend reads them, not the reverse). (4) Split the HashLink and Wasm size reporters out of IrOpportunityCensus into their backends. (5) Move IrPassMeter/AllocationMeter below ir, or inject them via the pipeline context. (6) Fold `IrValueLaneTarget` and pointer width into `TargetProfile` so passes take one descriptor.

### IrInliner.run is really the function optimizer, change detector and report driver; IrInlineCache is the session's IR cache

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/compiler/ir/IrInliner.hx:438-513 (`run`) does: source stabilization (440); inlining; `IrJumpThreading`/`IrReceiverCheckElision`/`IrDeadPureValues` (456); `IrInstrumentation.apply` (467); byte-level comparison against the previously published function to compute `changed`/`relocated` for patching (471-493); and `IrOpportunityCensus.report` plus `IrAllocationReport.report` (500-501). `inlinedVersion` also runs `IrScalarReplacement`, `IrLoadStoreForwarding` and `IrStrengthReduction` (571-575). Six passes have IrInliner as their only src caller (IrJumpThreading, IrStrengthReduction, IrDeadPureValues, IrCopyElision, IrLoadStoreForwarding, IrReceiverCheckElision). `IrInlineCache` (IrInliner.hx:43-177) also holds the static-null-check cache (line 57, passed to `assemble` at FrontendCompilation.hx:770) and lambda positional fingerprints (70-92, used at FrontendCompilation.hx:785-786), neither related to inlining. Generic utilities `IrInliner.remap` (1153) and `IrInliner.substitute` (972) have 11 and 4 external users.

**Cost.** With `HAXEON_INLINE=0` the 'inliner' must still run, because publication diffing and cleanup live in it (see the comment at FrontendCompilation.hx:832). That is surprising and couples hot-reload patch selection to an optimization. The inventory's last port step ('IrInliner last ... why 625 changed functions cost 31M') cannot be answered while per-build setup, optimization and publication are one measured span. Unrelated caches share one `copy()` (lines 149-176) that must be kept in step by hand for transaction rollback.

**Proposal.** Split into three units without changing behaviour. (a) `IrInliner`: inlining and its memo only. (b) `IrFunctionOptimizer`: the per-function sequence (scalar replacement, load/store forwarding, strength reduction, dead values, receiver checks, jump threading) with the `cleaned` memo. (c) `IrPublication`: `published`/`publishedBytes`/`relocated` and the changed-set computation, called by FrontendCompilation. Rename `IrInlineCache` to `IrSessionCache`, composed of those three plus the static-check and positional-fingerprint caches, each with its own `copy()`. Move `remap`/`substitute` to an `IrRemap` class next to `IrOperands`. Call the census and allocation reports from the pipeline, not from the inliner.

### Process-global single-entry caches and a global check-mode side channel under a compiler that is meant to be a persistent service

Architecture; severity medium, effort M, risk low.

**Evidence.** `IrProgramIndex.cached` (src/compiler/ir/IrProgramIndex.hx:16) is validated only by program identity and three array lengths (lines 55-59). Passes replace functions without changing length: `program.functions[index] = declarationStub(fn)` at src/compiler/ir/IrEntryPrune.hx:57, a same-length map at FrontendCompilation.hx:826-829, IrInliner.hx:499. `IrProgramIndex.of(program).func(name)` is then read by the Wasm backend (src/compiler/backend/wasm/WasmModuleSupport.hx:283, WasmFunctionLower.hx:2783 and 2818). `IrMethodResolution.cached` (src/compiler/ir/IrMethodResolution.hx:15) is a second single-entry global keyed by object-array contents. `IrEntryPrune.watched`/`prunedMethods` (src/compiler/ir/IrEntryPrune.hx:84-87) are set at IrProgramAssembler.hx:681 and cleared at 1162 with no try/finally, and read from `IrProgramIndex.findMethod` (IrProgramIndex.hx:120) and `IrFunctionIndex.get`. `IrPassMeter` is all static (src/compiler/compilation/IrPassMeter.hx:8-10). Option statics are read from the environment at class init: `IrInliner.enabled` (IrInliner.hx:202), `IrLoadStoreForwarding.enabled` (:16), `IrStrengthReduction.enabled` (:9); the IrInliner.hx:199-201 comment asks for three places to be kept in step by hand.

**Cost.** A single-entry cache thrashes when two programs alternate. The pipeline already does this: `assemble` builds 3 temporary IrPrograms (IrProgramAssembler.hx:610, 634, 717), and Wasm builds keep `logical` and `flattened` programs side by side. Length-only validation can hand a backend a function object that a later pass replaced. An exception inside `assemble` under HAXEON_CHECK_REUSE leaves `watched` set, so the next build in the same worker throws spurious 'early prune' errors. All of it rules out the roadmap's 'parallel parse and type work' reaching IR, and concurrent candidate builds (unsaved-edit validation against a forked snapshot), without first finding every static.

**Proposal.** Give builds an explicit `IrAnalyses` holder, owned by the pipeline context, that hands out `IrProgramIndex`, `IrMethodResolution` and the object table for the current program and is invalidated by the stage that replaces functions or objects (a version counter bumped on assignment, not a length heuristic). Delete both `static var cached`. Move the prune watch into that context so it dies with the build. Move the three `enabled` flags and `HAXEON_CHECK_REUSE` (read at 5 sites in ir) into one immutable `IrOptions` read once and included in `TargetProfile.key()`-style cache keys.

### IrProgramAssembler does three jobs; about 570 of its lines are a hand-written runtime-native table keyed by name prefixes

Organization; severity medium, effort M, risk low.

**Evidence.** src/compiler/ir/IrProgramAssembler.hx (1,384 lines). (1) Lines 34-572 lower typed declarations to IrObject/IrInterface/IrEnum/IrNative/initializers; the file has 20 references to compiler.types. (2) Lines 574-777 are the pass pipeline. (3) Lines 778-1141 plus `ensureArrayRuntime` (1167-1372) detect the runtime surface by string tests on call names: 15 `needs*` booleans, `StringTools.startsWith(name, "__array_")`, `"__map_"`, and parsing an operand count out of the name at line 961 (`Std.parseInt(name.substr("__string_concat".length))`). Then 59 `program.natives.push({...})` literals follow. The same names are matched again in src/compiler/runtime/NativeRegistry.hx:157, src/compiler/backend/wasm/linear/WasmLinearArrays.hx:1224-1282, src/compiler/backend/wasm/gc/WasmGcModuleBuilder.hx:802-837 and src/compiler/ir/IrInterpreter.hx:469. The 'input program' is constructed three times with the same 7 assignments (609-619, 634-641, 717-724).

**Cost.** Adding a runtime native (the roadmap lists file handles, List, Vector, Lambda, Type.getClass) means editing an if-chain, a declaration literal and each backend's name switch, with nothing checking they agree. A name typo yields a missing native at link time rather than a compile error. This is the second most-churned file in the scope (74 of the last 400 commits), and the three unrelated responsibilities collide in it.

**Proposal.** Split into `IrDeclarations` (the typed-to-IR `*From` functions, the only part that needs compiler.types), the pipeline (see the first finding) and `IrRuntimeSurface`. For the last one, replace the if-chain and 59 literals with one table in compiler.runtime, next to NativeRegistry: name or prefix rule, library, symbol, argument and result types. The assembler filters it by the calls it sees, and the Wasm builders and interpreter consult it instead of repeating name lists. Build the input IrProgram once. This is also the natural home for the 'native roles' that docs/IR_PASS_INVENTORY.md lists as a1 debt.

### The pre-SSA CFG duplicates the whole instruction set, verifier and builder for one producer and one consumer

Overengineering; severity medium, effort L, risk medium.

**Evidence.** src/compiler/ir/cfg/Cfg.hx:27-88: `CfgInstruction` repeats 58 `IrInstruction` constructors field for field, adding only `LoadLocal`/`StoreLocal` and lacking `Phi`/`ClassId`. `CfgValue` (id, type) differs from `IrValue` only by the missing name. `CfgTerminator` repeats `IrTerminator`. src/compiler/ir/cfg/CfgVerifier.hx (538 lines) re-implements the per-instruction type rules of IrVerifier, including its own `sameType` (489) and `isReference` (533), and runs on every generated function (SsaBuilder.hx:56) before IrVerifier checks the SSA again. src/compiler/ir/cfg/SsaBuilder.hx:489-680 is a roughly 190-line one-to-one constructor translation. CfgBuilder (86 public methods) and IrBuilder (52) share 46 method names. There is one producer (IrGenerator through CfgBuilder) and one consumer (`SsaBuilder.build`, called only at IrGenerator.hx:250).

**Cost.** A new instruction or intrinsic must be added to Ir.hx, Cfg.hx, both builders, both verifiers, the SsaBuilder translation and CfgIteratorReplacement before any pass or backend sees it. The inventory doc records 1,056 IrBuilder and 623 CfgBuilder call sites shifting when a method is added. Verification rules can diverge between the two verifiers. Every function pays two full verifications on a cold build, where compile speed is a stated priority.

**Proposal.** Define `enum CfgInstruction { LoadLocal(output, name); StoreLocal(name, value); Op(instruction:IrInstruction); }` over `IrValue`. SsaBuilder then renames operands with the existing generic remap (IrInliner.remap, 1153) instead of the 190-line switch. Reduce CfgVerifier to what is CFG-specific (locals declared and typed, terminators present, definitions before uses) and leave the type rules to IrVerifier. Have CfgBuilder delegate value construction to IrBuilder's emitters. Do it behind self-hosted hash equality; the generated IR should be identical.

### Every pass rebuilds its own name maps: four index classes plus about 34 ad-hoc maps

Architecture; severity medium, effort M, risk low.

**Evidence.** Index classes with overlapping content: `IrProgramIndex` (functions, objects, interfaces, subtypes; src/compiler/ir/IrProgramIndex.hx), `IrMethodResolution` (objects, children, method tables; IrMethodResolution.hx:15-35), `IrObjectTable` (objects, children, with read recording; IrObjectTable.hx) and `IrFunctionIndex` (functions with prune check; IrFunctionIndex.hx), plus `IrVerifyTable`. IrInliner builds its own objects and subclasses maps again (IrInliner.hx:301-311) next to an IrObjectTable and an IrMethodResolution. `[for (object in objects) object.name => object]` appears 25 times in 23 ir files (for example IrValueInterfaceBoxes, IrTypedInterfaceDispatch, IrCheckedDynamicCasts, IrOverrideBridges, GenericOwnerErasure twice, ObjectReflection twice). Function-name maps are built 9 more times. `IrObjectTable.of(...)` is constructed at 18 sites. docs/IR_PASS_INVENTORY.md finding 2 measures a floor of about 3.4M allocated objects per pass for five passes that change a handful of functions and suspects exactly this (`IrCheckedDynamicCasts.rewrite` builds `known` from every function name).

**Cost.** This is a direct compile-speed cost on every build (the inventory attributes 17.1M objects, 14% of an edit build's IR assembly, to five such passes). Lookup semantics are inconsistent: IrProgramIndex keeps the first object and the last function with a given name (IrProgramIndex.hx:44-52), and only some lookups record reads or check the prune. Reuse and invalidation therefore have to be reasoned about per pass.

**Proposal.** One `IrTables` value per program state (objects by name, children, interfaces, functions by name), built once by the pipeline and passed to stages. A stage that changes a table returns a new `IrTables`. Read recording (IrObjectTable.consulted, IrVerifyTable) and the prune check (IrFunctionIndex) become optional wrappers over it. IrMethodResolution and the subtype/implementor memo of IrProgramIndex become lazily computed members. This is step 0 of the inventory's port order and needs no pass interface.

### IR is immutable by convention only, and the assembler mutates cached functions in place

Architecture; severity medium, effort S, risk low.

**Evidence.** docs/ARCHITECTURE.md says 'IR values are immutable SSA definitions', and src/compiler/ir/IrInliner.hx:182-184 says 'The pass never mutates a function it was given: cached IR is shared between compiles and transaction snapshots'. But `IrBlock.instructions` is a mutable Array and `terminator` is a `var` (src/compiler/ir/Ir.hx:179-188). src/compiler/ir/IrProgramAssembler.hx:856-863 rewrites `Call` to `CNativeCall` with `block.instructions[index] = ...` over every function in `allFunctions`, including the per-module cached functions that copy-on-write passes returned untouched. The side effect is acknowledged in a cache comment (IrInliner.hx:67-68: 'Assembly rewrites calls to C natives inside the functions, so a different set of C natives starts over'). `IrProgram.copy()` (Ir.hx:377-393) shares objects, interfaces, enums and block arrays. `IrFunction.withBlocks` carries a leftover assertion whose message is truncated: `throw 'DEBUG empty withBlocks on '` (src/compiler/ir/IrFunction.hx:134-135).

**Cost.** A cached function's content depends on which builds it has been through. A function typed once and reused keeps a `CNativeCall` (or lacks one) according to an earlier build's C-native set, and a rolled-back candidate build has already mutated IR shared with the published snapshot. That is the class of bug HAXEON_CHECK_REUSE exists to catch, and other caches need special cases for it (the positional fingerprint reset at IrInliner.hx:76-80).

**Proposal.** Do the C-native rewrite through `IrFunctionRewrite.instructions` (src/compiler/ir/IrFunctionRewrite.hx:18), which returns the same object when nothing changes and a copy otherwise. Better, have IrGenerator emit `CNativeCall` for every C native (it already does for `TCNativeCall`, IrGenerator.hx:2260) so the assembler step disappears. Then remove the positional-fingerprint special case. Expose `IrBlock.instructions` as `haxe.ds.ReadOnlyArray` outside builders, so the three intentional in-place sites (IrInliner.hx:978 and 1146, IrLoadStoreForwarding.hx:144, all on private clones) are the only ones that compile. Fix the `withBlocks` message to include `this.name`.

### src/compiler/ir is one flat directory of 111 files where families are distinguished only by name prefix

Organization; severity low, effort M, risk low.

**Evidence.** `ls src/compiler/ir` shows 111 .hx files at the root; only cfg/ (6), codec/ (7) and hl/ (7) are split out. Families by prefix: IrValueArray* 14 files / 3,144 lines; IrInlineEnum* 9 / 1,565; IrEnum* 6 / 1,676 plus IrClosedEnumTagAbi 324; IrOptional* and IrNullable* 6 / 2,691; IrScalar* 5 / 2,333; IrValueLane* 3 / 535. Diagnostics and reports (IrOpportunityCensus 481, IrAllocationReport 366, IrReachabilityReport 28, IrInstrumentation 247) and the test-only `IrInterpreter` (1,017 lines, 0 references from src, 57 test files) sit beside the core model. Naming is inconsistent: `ObjectReflection`, `GenericOwnerErasure`, `ProgramFacts`, `TargetProfile`, `TypeKey` and `DebugNames` lack the Ir prefix. Five files are under 15 lines (IrReferenceIdentity 6, IrReceiverCheck 6, DebugNames 12, IrFieldStorage 13, hl/HlMissingEntity 12).

**Cost.** A newcomer cannot tell the core model (about 10 files) from lowering, analyses, representation passes, optimizations and tooling. That is the first thing needed to work on the pass port order in docs/IR_PASS_INVENTORY.md. Ownership boundaries between the two drivers named in that doc are by filename convention only.

**Proposal.** Use sub-packages that match the pipeline phases: `ir/` (Ir, IrFunction, IrBuilder, IrOperands, IrGraph, IrTypeIdentity, IrTypeTools, TypeKey, IrProviders), `ir/lower/` (IrGenerator and its collaborators, ProgramFacts, declarations), `ir/analysis/` (reachability, type-aware walk, non-null facts, loop bounds, method resolution, escape reach), `ir/repr/enums/`, `ir/repr/valuearray/`, `ir/repr/optional/`, `ir/repr/scalar/`, `ir/dispatch/`, `ir/opt/` (inliner, load/store forwarding, strength reduction, dead values, jump threading, copy elision, scalar replacement), `ir/verify/`, `ir/report/` (census, allocation report, instrumentation) and `ir/interp/`. A pure move with import updates, done one family at a time.

### Two reachability walkers coexist while IrReachability still documents itself as 'the one walker'

Architecture; severity low, effort M, risk medium.

**Evidence.** src/compiler/ir/IrReachability.hx:9-17 ('The one walker: the Wasm builders use it ... and HashLink prunes with it too'; 439 lines; `IrReachabilityWalk` at 252-423 implements rapid type analysis). src/compiler/ir/IrTypeAwareWalk.hx (486 lines) is a second rapid-type-analysis walk with its own created-type set and dispatch edges. `IrEntryPrune.run` (src/compiler/ir/IrEntryPrune.hx:46-73) uses the second to decide and the first's `prune` to apply. BackendAssembly.hx:117-120 and both Wasm builders (WasmGcModuleBuilder.hx:89-103, WasmLinearModuleBuilder.hx:259-295) still use the first. Only the 'has instances' rule is shared (src/compiler/ir/IrConstructed.hx). The migration switch `HAXEON_EARLY_PRUNE` is documented for deletion (IrEntryPrune.hx:23-28, docs/REACHABILITY_WALK.md 'Removal').

**Cost.** A plain HashLink build is walked by both (early prune with IrTypeAwareWalk, final trim with IrReachabilityWalk), so a new edge kind (a new intrinsic or dynamic site) must be taught to two walkers or the prune and the final trim disagree. That was the failure mode the 2026-11-10 check at IrProgramAssembler.hx:679 was added for.

**Proposal.** This is a tracked transition, so the change is to finish it rather than redesign. Once the 3b items in docs/REACHABILITY_WALK.md land, make `IrReachabilityWalk` a configuration of `IrTypeAwareWalk` (roots plus `keepLiveClasses`), keep `IrReachability` only for `prune`/`trimTables`/`natives`, and delete `HAXEON_EARLY_PRUNE`. Until then, fix the IrReachability header so it stops claiming to be the only walker, and add a check-mode assertion that the final walk's reached set is a subset of the early walk's.

### Leave alone

- src/compiler/ir/IrInterpreter.hx (1,017 lines, no src callers): the reference interpreter used by 57 test files as the IR semantics oracle. It is not dead code; at most move it to an ir/interp package.
- src/compiler/ir/IrClassIds.hx, `IrInstruction.ClassId` and `IrProgram.classIds` (Ir.hx:134-138, 353-357): no producer yet, and HlLower throws on it (hl/HlLower.hx:852). This is the landed step 1 of docs/INTERFACE_VALUES.md (dense class ids for interface dispatch), an unfinished seam the roadmap needs.
- src/compiler/ir/IrLoopBounds.hx: used only by IrOpportunityCensus and tests. docs/BOUNDS_CHECK_ELIMINATION.md records that the bounds-check pass was rejected by measurement and that the analysis is kept on purpose for the census and its proof tests.
- src/compiler/ir/IrOperands.hx:22-24 (`noInputs`/`matchedInputs` shared static arrays used as sentinels, plus `count`/`at` duplicating `inputs`): odd-looking, but it implements the allocation rules in docs/ARCHITECTURE.md ('give the helper count/at') and was measured.
- src/compiler/ir/IrFunctionRewrite.hx and the 'unchanged returns the same object' rule: the identity-preserving copy-on-write is what the inline memo, verify memo and lowered cache key on. Do not 'simplify' passes into always rebuilding functions.
- src/compiler/ir/IrVerifyTable.hx and IrVerifyMemo.hx (the verifier reads the program only through recording tables) and `IrObjectTable.consulted`: the indirection looks like a forwarding layer, but it is the per-function dependency recording that makes warm verification and inlining incremental.
- src/compiler/ir/codec/IrFunctionStateEquality.hx (447 lines) alongside IrFunctionStateCodec: a structural comparison separate from encode-and-compare, kept deliberately to avoid materializing serialized graphs (IrInliner.hx:130-133).
- src/compiler/ir/IrFunction.hx `IrFunctionKind` with many specific cases (EnumEquality, EnumTagAdapter, ClosureAdapter, ValueArraySlot and others) and the `provides` view: this is the declared-role model replacing name parsing (docs/IR_PASS_INVENTORY.md marker migration). The remaining `$prefix:` string markers (122 startsWith/endsWith sites in ir) are tracked there family by family and should follow that plan, not an ad-hoc cleanup.
- src/compiler/ir/IrInlineEnumRequests.hx, the five `IrEnumTagLowering.escapes` rescans and `HAXEON_EARLY_PRUNE`: documented transitional mechanisms with stated deletion conditions (docs/ENUM_PASS_PHASE_ORDER.md, docs/REACHABILITY_WALK.md). Remove them with those migrations, not before.
- src/compiler/ir/TargetProfile.hx: capability flags plus a `kind`, immutable with `key()`. It is the right shape; `portable` is used by Frontend.compile for backend-less tests. Extend it (see the target-descriptor finding) rather than replace it.
- src/compiler/ir/IrGraph.hx lazy dominators and the SsaBuilder/IrInliner dense-id arrays instead of string maps: these follow the documented performance rules ('hash a name once').
- The static `HAXEON_*` switches and `HlLower.lastDebugLocation` (hl/HlLower.hx:1369) are called out in docs/ARCHITECTURE.md as 'left static on purpose'. They are fine as worker-identity switches today; they only need to move when builds become concurrent.

## Backends (`src/compiler/backend`, `hl`, `abi`)

### The Backend interface is not the real seam: HashLink production bypasses it and Wasm builds still run the full HashLink assembly

Architecture; severity high, effort L, risk medium.

**Evidence.** src/compiler/backend/Backend.hx:45-47 declares `Backend.compile`. HlBackend (src/compiler/backend/hl/HlBackend.hx:12-24) has 0 users in src and 29 in tests; production HashLink goes src/compiler/compilation/BackendAssembly.hx:94-220 -> HlModuleAssembler.assemble -> HlLower.lowerStableMeasured (src/compiler/hl/incremental/HlModuleAssembler.hx:889). The only variable typed `Backend` is src/compiler/tools/CompilerDriver.hx:83 and it always holds a WasmBackend. For a Wasm target BackendAssembly still copies the IR, rewrites it and runs `candidateAssembler.assemble` unconditionally (BackendAssembly.hx:102-111, 170), with 6 `isWasmTarget()` branches in that file and 8 more in FrontendCompilation.hx (742-836, 1516); the Wasm module is then produced separately in the driver (CompilerDriver.hx:68-87). BackendOptions (Backend.hx:16-33) has 13 fields, 10 of them Wasm-only. HlBackend skips the reachability pruning that the production path does at BackendAssembly.hx:112-126.

**Cost.** Every Wasm build pays for a whole-program HashLink lowering whose output is discarded. The 29 test programs that go through HlBackend exercise a pipeline that differs from the shipped one (no pruning, no assembler, no lowered cache), so they can pass while production differs. Target choice is expressed as scattered `isWasmTarget()` booleans rather than one dispatch point, so a new target or a per-target cache means touching the frontend, BackendAssembly and the driver.

**Proposal.** Make the seam match reality. Give the compilation context one target-backend object selected once, with two operations the pipeline calls: prepare target IR (the passes now guarded by isWasmTarget) and assemble (incremental HashLink assembly, or Wasm module build). Move the Wasm call out of CompilerDriver into that dispatch and skip HlModuleAssembler for Wasm targets (or make the retained HashLink copy an explicit opt-in if something needs it). Reimplement HlBackend on top of the production assembler path so tests cover it, and split BackendOptions into shared fields plus a Wasm options struct.

### Shared Wasm lowering downcasts to the concrete GC and linear representations 22 times

Architecture; severity high, effort M, risk medium.

**Evidence.** src/compiler/backend/wasm/WasmRepresentation.hx:27-76 defines four interfaces meant to hide the reference model. src/compiler/backend/wasm/WasmFunctionLower.hx has 22 `Std.isOfType(context.representation.values, ...)` sites: 10+ against WasmGcRepresentation (lines 318, 335, 596, 602, 957, 1220, 1376, 1380, 1722, 2058, 2088, 2251, 2305) and the rest against WasmLinearRepresentation (204, 327, 717, 964, 1399, 2197). They call members that are not on any interface (`scalarExceptionWrapper`, `scalarLocal`, `hasScalarCall`, `scalarCall`, `scalarSignature`) and pick opcodes inline (`RefIsNull` vs `I32Eqz` at 1376 and 1722, `RefEq` vs `I32Eq` at 2110). The shared core also imports gc/linear classes directly (WasmFunctionLower.hx:16-17, 27-28; WasmFunctionLowerContext.hx:8) and runs `WasmGcLocalCompaction` at line 336; linear imports gc (linear/WasmLinearModuleBuilder.hx:11 for WasmGcRoots).

**Cost.** The interface does not tell you what a representation must provide; the real contract is the union of the interface and 22 type tests inside a 1,466-line `lowerInstruction`. A third model (Wasm64/Linear64 is already declared) or a change to either existing one requires auditing every downcast, and a missed one silently falls into the other model's instruction sequence.

**Proposal.** Promote the downcast uses into interface members: null test, reference equality, scalar local/scalar call hooks, exception wrapper, post-lowering local compaction and function signature override. Where the two models genuinely differ in algorithm, return `UseDefault` from one of them as the interfaces already allow. Move WasmSafepoint/WasmGcRoots (used by both models) out of gc/ into the shared package so shared code no longer imports gc/ or linear/.

### The Haxe runtime library is hand-emitted as Wasm instructions twice, once per reference model

Architecture; severity high, effort L, risk high.

**Evidence.** Distinct runtime intrinsic name literals (`__x` and `runtime.X`): 282 in src/compiler/backend/wasm/gc, 265 in src/compiler/backend/wasm/linear, 239 common to both; HashLink lowering (src/compiler/ir/hl) names only 25 because it calls the C runtime. Parallel emitters exist for the same semantics: gc/WasmGcRepresentation.hx `stringSplit` (167 lines), `stringCompare` (120), `int64Parse` (112), `dynamicEnumString` (236) versus linear/WasmLinearRuntime.hx `addStringSplit` (186), `addStringCompareFull` (98), `addInt64Parse` (151), `emitEnumString` (203); plus WasmGcDynamicArrays.hx (1,073) vs WasmLinearDynamicArrays.hx (1,210), WasmGcValueArrays vs WasmLinearValueArrays, WasmGcClosureAdapters vs WasmLinearClosureAdapters, WasmGcEnumStringTable vs WasmLinearEnumStringTable, WasmGcReflection vs WasmLinearReflection. docs/WASM_LINEAR_RUNTIME.md states the linear side is about 8,600 lines kept in step with about 4,800 lines of C by hand; only the allocator and sweep have moved to C (stdlib/haxeon/wasm/linear-runtime.wasm is 1,570 bytes). The two largest files changed in 71 and 63 commits in the last 60 days.

**Cost.** Each Haxe-semantics fix in string, Int64, array, map or enum-to-string behaviour must be made in three places (C for HashLink, and two instruction emitters), which works directly against the parity priority. The existing C-runtime plan covers wasm32 only; the wasm-gc copy, which the browser editor uses by default, has no convergence path.

**Proposal.** Keep the documented C-runtime direction for wasm32, and add a plan for the model-independent part of the GC copy: implement the operations that do not depend on object representation (string compare/split/case, Int64 parse/format, number formatting, enum string building) once, either as Haxe stdlib code compiled through the normal pipeline (as the docs already do for Regex and MemoryFileSystem) or as one emitter parameterised over a small accessor interface (load char, length, allocate string). Start with the 239 shared names and migrate by family.

### The HashLink backend is spread over three packages with import cycles, and compiler.ir imports backend classes

Organization; severity medium, effort M, risk low.

**Evidence.** Lowering is in src/compiler/ir/hl (7 files, 2,598 lines; HlLower.hx is 2,220 lines / 105 KB), encoding/assembly/patch/persistence in src/compiler/hl (26 files), and the adapter in src/compiler/backend/hl (1 file, 25 lines); Wasm is entirely under src/compiler/backend/wasm. Cycles: HlModuleAssembler imports compiler.ir.hl.HlLower (HlModuleAssembler.hx:9) while HlLower takes HlSymbolTable/HlLoweredCache/HlLoweredFunction from compiler.hl.incremental (src/compiler/ir/hl/HlLower.hx:97, 118-121); HlLoweredFunction.hx:4, HlLink.hx:6 and HlLoweredCache.hx:3 import compiler.ir.hl types. IR-layer code reaches into backends: src/compiler/ir/IrProgramAssembler.hx:169 (HlModuleAssembler.LIVE_INITIALIZER), src/compiler/ir/IrVerifier.hx:1363 (WasmFlattenValueFields.CHECK_FIELD), src/compiler/ir/IrOpportunityCensus.hx:12-67 (HlCode, HlWriter, WasmModule, WasmEncoder). A Wasm pass imports a HashLink-named package: src/compiler/backend/wasm/WasmFlattenValueFields.hx:11 (compiler.ir.hl.PhiEdges). `HlSymbolTable` (src/compiler/hl/incremental/HlSymbolTable.hx:291-590) is not only a table: it lowers IrType/IrObject/IrInterface to HashLink type definitions.

**Cost.** There is no single place to look for the HashLink backend, the package names do not say which direction dependencies run, and the IR package cannot be built or reasoned about without both backends. Shared helpers (PhiEdges) end up named after one backend.

**Proposal.** Move src/compiler/ir/hl and src/compiler/hl under src/compiler/backend/hl with subpackages lower/, encode/, incremental/, patch/, persistence/. Move PhiEdges to compiler.ir. Move the two shared constants (LIVE_INITIALIZER, CHECK_FIELD) to an IR-level names module that both sides import, and move IrOpportunityCensus.reportHashLink/reportWasm next to the respective writers.

### The patch-or-reload decision is made in three places and re-parses string-encoded ABI descriptors

Architecture; severity medium, effort M, risk medium.

**Evidence.** Stage 1: PatchPlanner.plan (src/compiler/abi/PatchPlanner.hx:68-108) with two boolean capability flags whose doc comment (51-66) describes HlModuleAssembler behaviour. Stage 2: HlModuleAssembler.planObjects (src/compiler/hl/incremental/HlModuleAssembler.hx:574-604) adds AbiChange reasons. Stage 3: HlModuleAssembler.assemble adds free-text `layoutReasons` for natives, dispatch natives, slot moves and globals (lines 800-866, 898-901). BackendAssembly merges the three forms afterwards (src/compiler/compilation/BackendAssembly.hx:140-149, 172-175, 203-205) and the patch is suppressed by a third condition `assembly.requiresReload`. RuntimeAbi.describe builds each object as one string `kind=..;base=..;fields=..;methods=..` (src/compiler/abi/RuntimeAbi.hx:41-43) and PatchPlanner splits it back on `;`, `,` and `:` to recover structure (`frame` 121-131, `addMethodFunctions` 147-156). Generated-type detection uses literal name prefixes (PatchPlanner.hx:172-177) beside LambdaName.ENVIRONMENT_PREFIX (line 87, and HlModuleAssembler.hx:586).

**Cost.** Nobody can answer 'will this edit patch or reload?' from one function, which is the core user-visible behaviour of hot reload. A field, method or type name containing `;`, `,` or `:` (generic and function type texts contain commas and colons) can be mis-split by the descriptor parser. The roadmap rule that backends never infer semantics from names is bent by the prefix checks.

**Proposal.** Make RuntimeAbiDescriptor structured for objects (kind, base, interfaces, fields[], methods[{name, function}]) and keep the string only as the comparison/persistence key, so `frame` and `dispatchedFunctions` read fields rather than parse. Have the assembler return all of its reasons as AbiChange values (replace `layoutReasons:Array<String>`), and let one function in compiler.abi combine planner and assembler reasons into the final decision. Carry an `isGenerated`/kind flag on IrObject in the descriptor instead of matching `$lambda-env:` style prefixes.

### HlModuleAssembler is a 952-line object that mixes policy, IR synthesis, layout planning, state persistence and timing

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/compiler/hl/incremental/HlModuleAssembler.hx: persisted state export/import (237-292), lambda renaming (307-328), signature-move policy (337-375), synthesis of new IR adapter functions with IrBuilder including default-value and widening rules (383-444), drop guards (451-500), object field/method patch planning (574-711), and a 206-line `assemble` (746-952) with four separate 'restart with a fresh layout' paths (793, 803, 813, 837, 850). It has 8 public mutable configuration fields set by the caller after construction (166-183) and throws when two of them disagree (876-877). HlAssemblyResult carries 9 timing/allocation fields beside the module (66-111). It changed in 51 commits in the last 60 days.

**Cost.** The Haxe-semantics-sensitive part (what a signature adapter may widen, which defaults are literal) is hidden inside a package named for bytecode encoding, where it will not be found when the same rules change in the frontend. The repeated fresh-layout restarts are order-dependent and easy to break when adding a new reload cause.

**Proposal.** Split into: (a) SignatureAdapters in compiler.abi or compiler.ir (pure IR in, IR out); (b) HlObjectPatchPlan (planObjects and helpers) returning reasons plus HlObjectLayout; (c) a slot-layout step that computes natives/dispatch/slots once and reports all layout reasons before a single fresh-layout decision; (d) the remaining assembler holding state and calling HlLower. Pass configuration as one immutable options value to `assemble`.

### Long positional parameter lists on the two central backend entry points

Architecture; severity medium, effort S, risk low.

**Evidence.** HlLower.lowerStableMeasured takes 14 positional parameters, 5 of them Bool (src/compiler/ir/hl/HlLower.hx:118-121); call sites are `lowerStableMeasured(program, new HlSymbolTable(), indices, null, null, null, null, 0, false)` (src/compiler/backend/hl/HlBackend.hx:21) and a 14-argument call ending `..., false, liveCache, irVerified, livePatching, name -> ...` (HlModuleAssembler.hx:889-891). HlPatchWriter.encode takes 16 parameters (src/compiler/hl/patch/HlPatchWriter.hx:29-34); its one production caller passes `assembly.baseInts, assembly.baseFloats, assembly.baseStrings, assembly.baseTypes, null, assembly.addedFunctions, assembly.baseGlobals, assembly.objectLayout, [...], namedGlobals()` (src/compiler/compilation/BackendAssembly.hx:205-213), nine of which are fields of the HlAssemblyResult it already holds. WasmBackend.developmentOptions copies 13 option fields by hand (src/compiler/backend/wasm/WasmBackend.hx:63-70).

**Cost.** Adjacent Int and Bool arguments of the same type (four symbol bases, `recordLowering`/`irVerified`/`trustCache`) can be swapped without a type error, and a wrong base silently produces a patch whose symbol hashes mismatch at runtime. A new BackendOptions field is silently dropped from Wasm patch builds unless developmentOptions is also edited.

**Proposal.** Introduce `HlLowerOptions` and `HlPatchRequest` structures (or have HlPatchWriter.encode accept the HlAssemblyResult plus moduleId, stable ids and guards). Replace developmentOptions with a structural copy that overrides one field.

### Runtime calls are dispatched through very long name-comparison chains inside giant functions

Organization; severity medium, effort M, risk low.

**Evidence.** WasmGcRepresentation.lowerRuntimeCall is 1,539 lines (src/compiler/backend/wasm/gc/WasmGcRepresentation.hx:2233 onward) built as sequential `if (name == "...")` blocks, each re-validating argument types inline; the file has 102 name-comparison sites and 167 methods in 7,410 lines. WasmLinearRuntime.hx has 117 such sites and 132 methods in 4,833 lines. WasmFunctionLower.lowerInstruction is 1,466 lines. Three classes implement lowerRuntimeCall (WasmGcRepresentation.hx:2233, WasmGcInterop.hx:75, WasmLinearRepresentation.hx:780) and WasmFunctionLower consults them in sequence (2296-2314).

**Cost.** Finding where an intrinsic is lowered for a given model means searching three files and reading an if-chain; a name handled in two places resolves by order. Every runtime call lowered on wasm-gc walks the chain with string comparisons, which costs compile time on call-heavy programs. Files of this size are also slow for the self-hosted compiler and for review.

**Proposal.** Register intrinsics in a per-model table built once (name -> handler with a declared signature that is checked generically), split by family into files that already exist as a pattern (strings, bytes input/output, Int64, arrays, maps, enum strings). Keep `lowerRuntimeCall` as a table lookup. Split lowerInstruction by instruction family (calls, closures, aggregates, control) into helper classes sharing WasmFunctionLowerContext.

### Per-module state held in static variables in the Wasm linear runtime and module support

Architecture; severity medium, effort S, risk low.

**Evidence.** src/compiler/backend/wasm/linear/WasmLinearRuntime.hx:21-25 keeps `runtimeErrorsThrow`, `runtimeNeutral`, `pendingExceptionFlag`, `pendingExceptionValue` as statics assigned in `register` (40-46) and read later by `runtimeFailure` (49-70) while emitting code. src/compiler/backend/wasm/WasmModuleSupport.hx:161-162 caches `hostCNativeProgram`/`hostCNatives` statically keyed by the last program. WasmLinearModuleBuilder.hx:479-480 and WasmCryptoRuntime.hx:9-10 cache runtime bytes statically. HlLower has `static var lastDebugLocation` (src/compiler/ir/hl/HlLower.hx:1369) and `skippedKeptTotal` (93). ARCHITECTURE.md lists the Wasm caches as a known follow-up.

**Cost.** The compiler is a persistent service that compiles speculative candidates and may compile for different options in one process; an emitter called after another module's `register` uses that module's exception mode and global indices. It also blocks the roadmap item on parallel work, and the static program-keyed cache retains a whole IrProgram between builds.

**Proposal.** Move the four WasmLinearRuntime fields onto WasmLinearContext (which `register` already receives and which already holds pendingExceptionFlag/Value) and pass the context to `runtimeFailure`. Hang the host C-native index on the module builder. Keep the read-only runtime byte caches.

### Wasm patch support is a parallel mechanism with no production caller

Overengineering; severity medium, effort S, risk low.

**Evidence.** WasmBackend.compilePatchBase/compilePatch (src/compiler/backend/wasm/WasmBackend.hx:23-59) and WasmPatch.readManifest/readTableManifest/plan/identities (src/compiler/backend/wasm/WasmPatch.hx:44, 99, 119, 139) are called only from tests (tests/compiler/WasmBackendMain.hx, WasmTypeIdPlanMain.hx); in src only `WasmPatch.manifest` and `tableManifest` are used, to write two custom sections (gc/WasmGcModuleBuilder.hx:355-356, linear/WasmLinearModuleBuilder.hx:591-592). A 'patch' is the whole module recompiled with a filtered manifest (WasmBackend.hx:31-36, 50). Function identity is an FNV hash of the name (WasmPatch.hx:149-156), unrelated to the HashLink stable ids with tombstones (HlFunctionCache). `patchChanged` is threaded through both module builders for this. The target check lists an impossible `[HashLink, HashLink]` case (WasmBackend.hx:39). ROADMAP.md section C plans hot reload on HashLink only.

**Cost.** A second identity scheme and manifest format to keep correct with no consumer that would reveal a mistake; name-hash identities do not survive the lambda renames the HashLink path handles, so the design would need rework before use anyway. It adds a parameter and a branch to both module builders.

**Proposal.** Either mark it explicitly as an experiment in docs/WASM_BACKEND.md and keep only the custom-section writer, or remove compilePatch/compilePatchBase, the readers and `patchChanged` until a host consumes them. If Wasm hot reload becomes a goal, derive identities from the same stable-id source as HashLink.

### Declared but unimplemented or unused surface: Wasm64, WasmRuntimeAbi, PatchDecision.Reject

Overengineering; severity low, effort S, risk low.

**Evidence.** `Wasm64` (src/compiler/backend/Backend.hx:11) and `Linear64` (src/compiler/backend/wasm/WasmTarget.hx:9, 35-43) are accepted by the CLI (src/compiler/tools/CompilerDriver.hx:55) and by Compiler.isWasmTarget (src/compiler/Compiler.hx:1129) but WasmBackend.compileInternal throws for them (WasmBackend.hx:85); docs/WASM_BACKEND.md:264 confirms. WasmRuntimeAbi (src/compiler/backend/wasm/WasmRuntimeAbi.hx, 76 lines, 21-case enum) has 0 users in src and one test call (tests/compiler/WasmBackendMain.hx:277). `PatchDecision.Reject` (src/compiler/abi/PatchPlanner.hx:47) is never constructed; it is only matched at PatchPlanner.hx:184, BackendAssembly.hx:145 and HlModuleAssembler.hx:752. WasmTargetConfig carries `simd` and `threads`, false for every target (WasmTarget.hx:19-20).

**Cost.** A user who passes `--target wasm64` gets the whole frontend and the HashLink assembly run before a late throw. Dead enum cases force handling at three match sites and suggest behaviour that does not exist.

**Proposal.** Reject wasm64 at argument parsing with a diagnostic and drop the enum cases until implemented; delete WasmRuntimeAbi and its test line; remove `Reject` (or produce it where the code now throws strings); drop `simd`/`threads` from the config.

### HlTypeDef is serialized or walked by five independent switch statements

Architecture; severity low, effort S, risk low.

**Evidence.** HLB writer `writeType` (src/compiler/hl/HlWriter.hx:495-540), HLP writer `writeType`/`writeObjectType` (src/compiler/hl/patch/HlPatchWriter.hx:518-580), HLP type-table hash `hashTypes` (HlPatchWriter.hx:429-510, about 80 lines of per-field hashing), HLP reader `readType` (src/compiler/hl/patch/HlPatchReader.hx:209-235) and the session-state codec (src/compiler/hl/persistence/HlTypeDefStateCodec.hx, 277 lines). The HLB and HLP object encodings are documented as identical ('As an HLB file has them', HlPatchWriter.hx:545) but are separate code.

**Cost.** Adding a type kind or a field to an object type (recent examples in the version notes: interface cache fields, EnumTag) needs five coordinated edits; missing the hash walker yields patches the runtime rejects as stale, and missing the state codec corrupts resumed sessions.

**Proposal.** Have HlPatchWriter reuse HlWriter's type encoder for the kinds a patch allows (it already reuses HlWriter.encodeIndex and encodeFunction), and compute `hashTypes` over those encoded bytes instead of a parallel walk, if the runtime's hash definition allows; otherwise generate both from one field visitor on HlTypeDef.

### Leave alone

- src/compiler/hl/HlFunctionEquality.hx (410 lines) looks like test code in the production tree, but it is the comparison behind HAXEON_CHECK_REUSE described in docs/ARCHITECTURE.md (check mode); it is what makes the lowered-function reuse and trust-cache paths verifiable. Leave it.
- The four HashLink caches (HlFunctionCache for IR functions/slots/stable ids, HlLoweredCache for relocatable lowered functions, HlWriterCache for encoded bytes, HlDebugMetadataCache) look redundant but each sits at a different pipeline stage with a different validity rule (docs/ARCHITECTURE.md 'Layers of a plain build'). Do not merge them.
- HlLink/HlSymbolRequest/HlLoweringView (src/compiler/hl/incremental/HlLink.hx, HlSymbolRequest.hx, src/compiler/ir/hl/HlLoweringView.hx): the request-recording indirection around every symbol-table access is what lets an unchanged function be linked instead of lowered again; it is not a forwarding layer.
- src/compiler/backend/wasm/WasmRuntimeLinker.hx (275 lines) links a runtime module of only 1,570 bytes today. It is an unfinished seam with a written plan (docs/WASM_LINEAR_RUNTIME.md: allocator and sweep done, the rest to follow), not overengineering.
- src/compiler/hl/patch/HlPatchReader.hx has no production caller in the compiler (9 test users, and src/runtime/PatchSet.hx refers to its index format). It is the executable specification of HLP that the writer is tested against; keep it.
- WasmEncoder validates every module before encoding (src/compiler/backend/wasm/WasmEncoder.hx:30 -> WasmValidator, 953 lines). This costs compile time but catches emitter bugs in hand-assembled instruction sequences before a browser does; keep while the runtime is hand-emitted.
- The explicit CFG dispatcher fallback beside structured lowering (WasmCfgAnalysis, WasmStructurer, WasmFunctionLower.lowerDispatcher) is two code paths for one job, but docs/WASM_BACKEND.md:131-133 and 259-260 state it is the correctness fallback for irreducible CFGs and exception handlers.
- src/compiler/abi is separate from src/compiler/hl even though HashLink is its main consumer: RuntimeAbi/PatchPlanner are also used by WasmPatch, Compiler.hx, CompilerPublication and editor/LanguageServiceProtocol, and they describe IR-level ABI, not bytecode. The compiler.semantic.LambdaName import there (5 files) is the one shared naming convention and is the right owner.
- HlSymbolTable copy/fork with copy-on-write (src/compiler/hl/incremental/HlSymbolTable.hx:66-110) and the append-only discipline look heavy, but candidate builds must not disturb the published tables and live patching depends on stable indices.
- Retired names and signature-move adapters (src/compiler/abi/RetiredName.hx, HlModuleAssembler.moveChangedSignatures) look like a workaround, but keeping the old slot alive for closures already created by the running program is required for safe patching; the behaviour should stay even if the code moves.
- The Wasm patch module being a full self-contained module rather than a delta (WasmBackend.hx:31-36) is deliberate so the same encoder and validator check its runtime dependencies.

## Type system and semantic analysis (`src/compiler/types`, `semantic`)

### Local type inference is syntactic look-ahead plus speculative re-typing; there are no unification variables

Architecture; severity high, effort L, risk high.

**Evidence.** `CompilerType` (src/compiler/types/Type.hx:20-58) has no monomorph/type-variable constructor; grep for monomorph/unify in types/ and semantic/ returns nothing. Inference is spread over four pre-passes that pattern-match the untyped AST: `SignatureInference.hx` (716 lines), `FieldInference.hx` (477), `BodyTyper.inferBodyLocalTypes`/`constrain*` (BodyTyper.hx:1009-1143, fixed-point loop) and `expectedInitializerType`/`pushedElementType`/`storedIn`/`knownExpressionType` (BodyTyper.hx:552-947). `speculativeValueType` (BodyTyper.hx:700-719) calls the real `typeExpression` on a scratch `Scope` and turns any exception into null (`catch (_:Dynamic)`); `declareSpeculative` (733) does the same. The only guard against side effects is `containsLambda` (702, 721).

**Cost.** Each Haxe inference case (`var a = []` later pushed, `var m = new Map()`, null initializers, inferred returns) needs its own AST pattern, so parity with Haxe's inference grows case by case and each new statement form must be added to several hand-written walkers (pushedElementType alone enumerates If/While/ForIn/Try/Defer/Switch). Speculative typing runs against the shared `TypingSession` with no rollback, so requests it records (purity queries, helper/specialization requests, anonymous types) stay behind, and statements after such a declaration are typed more than once. `catch (_:Dynamic)` also hides internal compiler errors as 'could not infer'.

**Proposal.** Add an inference variable to `CompilerType` (e.g. `TMono(ref)`), bind it in `TypeRelations` assignability/`coerce`, and let `var a = []` produce `TArray(TMono)` resolved at first use, with a post-body pass that defaults or rejects unbound variables. Migrate one case at a time (empty array literal first), deleting the matching look-ahead walker each time; keep `SignatureInference` only for what must be known before bodies are typed. Until then, make `speculativeValueType` catch `CompileError` only.

### BodyTyper is a hub wiring five sub-typers through 71 closures over a 53-field mutable TypingSession

Architecture; severity high, effort L, risk medium.

**Evidence.** `BodyTyper` constructor (src/compiler/types/typing/BodyTyper.hx:78-160) passes 71 `function(...)` closures to `ExpressionTyper`, `CallResolver`, `StatementTyper`, `ClosureTyper`, `GenericInstantiation`, `InlineConstantResolver`; these files declare 42 `*Callback` typedefs (CallResolver 11, ExpressionTyper 10, ClosureTyper 10, StatementTyper 7, ...). The same operations (`typeExpression`, `coerce`, `lowerType`, `arrayElementType`, `findFieldType`) are re-declared as separate callback types per consumer (CallResolver.hx:32-42, ExpressionTyper.hx:49-58). BodyTyper still has 160 functions in 2859 lines and opens its privates to 8 classes via `@:allow` (BodyTyper.hx:48-55). `TypingSession.hx` exposes 53 public fields, 42 of them `Map`s; `session.` is used 182 times in CallResolver, 126 in BodyTyper, 100 in ProgramTyper. Helper statics are duplicated: `fail` in 13 files, `sameType` in 4, `isArray`/`isMap`/`isIterator`/`unwrapNullable`/`isNullable`/`enumName` in 2-3 each (e.g. BodyTyper.hx:2790-2857 vs CallResolver.hx:1181-1674).

**Cost.** The split into files does not reduce coupling: every sub-typer can call back into every other through the hub, so behaviour cannot be read or tested per file, and adding one cross-cutting operation means a new typedef, a constructor parameter, a field and a closure at the wiring site. Any code can write any session map, so ownership of state such as `inlineConstantsInProgress` or `enumAbstractConstantOwner` is by convention. This file set had 105 commits to BodyTyper alone in three months, so the wiring cost is paid constantly.

**Proposal.** Replace the closures with one shared interface (or pass the `BodyTyper` itself typed as a narrow `TypingCore` interface with typeExpression/coerce/lowerType/findFieldType/arrayElementType) held by every sub-typer; delete the per-consumer callback typedefs. Move the duplicated type predicates to static functions on one `TypeShapes` class next to `TypeRelations` and a single `TypingErrors.fail`. Group `TypingSession` fields into owned sub-objects (helper requests, inline constants, key paths, incremental query records) with methods instead of public maps.

### Hand-written AstFunction copies drop isInline / isExtern / metadata on 4 of 9 sites

Architecture; severity high, effort S, risk low.

**Evidence.** `AstFunction` has 13 fields (src/compiler/syntax/Ast.hx:292-313). Nine sites rebuild it field by field; four omit `isExtern`, `isInline` and `metadata`: `SignatureInference.withResult` (types/SignatureInference.hx:402-414, used for every function whose return type is inferred, 392/399), `SignatureInference.replaceArguments` (695-706), `SemanticProgram.withOwnerTypeParameters` (semantic/SemanticProgram.hx:261-281, feeds `signatures` for all abstract methods) and the abstract-method copy in `SemanticAssembly.run` (semantic/SemanticAssembly.hx:303-315). `SemanticAssembly.hx:389-402` omits `isInline` only. `BodyTyper.typeFunction` then reads the flags from that node: `isInline: fn.isInline == true`, `isKept: hasFunctionMetadata(fn, "keep")`, `isExposed: ...` (typing/BodyTyper.hx:340-342), and `PurityAnnotations.hasPureAnnotation` reads `fn.metadata` from `signatures` (analysis/PurityAnnotations.hx:29-34). The only test (tests/compiler/TyperBoundaryMain.hx:45-54) uses explicit `:Int` results. `SemanticProgram.replaceBodies` uses the opposite technique, `Reflect.copy` + `Reflect.setField` on final typedef fields (SemanticProgram.hx:93-99, 178-204). Not executed; established by reading.

**Cost.** A function or method with an inferred return type, or with an inferred argument, appears to lose `inline`, `@:keep`, `@:expose` and `@:pure`; abstract methods (commonly `inline` in Haxe) lose them through the signature table. Every new `AstFunction` field must be added in nine places, and missing one is silent. The Reflect variant bypasses `final` and the type checker, and depends on dynamic field access in the self-hosted compiler.

**Proposal.** Add one helper in `compiler.syntax` (e.g. `AstCopy.functionWith(fn, {?name, ?arguments, ?result, ?statements, ?typeParameters, ?span, ?metadata})`) that copies every field, and use it at all nine sites and in `replaceBodies`/`withBody`/`copyWithMethods` instead of Reflect. Add a typer test with `inline`/`@:keep` functions that have inferred return types and an inline abstract method.

### Typing aborts on the first error, and the language service compensates with a second approximate typer

Architecture; severity medium, effort L, risk medium.

**Evidence.** All typer errors are `throw new CompileError(...)` through 13 private `fail` helpers (e.g. typing/BodyTyper.hx:2854, types/DeclarationIndex.hx:1162); 633 call sites pass one of 30 `"E1xxx"` string literals, with no central code list in scope. The only catch around typing is compilation/FrontendCompilation.hx:231-238, which stores that one diagnostic and rethrows. Because no typed program exists after an error, `SemanticIndex.indexRecoveredSyntax` and its helpers (semantic/SemanticIndex.hx:251-565, about 315 lines) walk the raw AST and guess types (`recoveredExpressionType`, `recoveredType`: literals and named types, everything else `TDynamic`), called from service/LanguageService.hx:327.

**Cost.** The editor shows one type error per build, and hover/completion/navigation fall back to guessed types for the whole module as soon as one function has an error. The recovered indexer is a parallel implementation of scoping and member binding that must be kept in step with the real typer. The roadmap item D ('editing recovers through last-good snapshots') stays dependent on this fallback.

**Proposal.** Give `TypingSession` a diagnostics sink and make the function the unit of recovery: `ProgramTyper` catches `CompileError` per `typeFunction`/field initializer, records it, and emits the function with an error body (or omits it) so the rest of the program is still typed; the build fails afterwards if the sink is non-empty. Then `indexRecoveredSyntax` only needs to cover functions that failed. Put the 30 codes in one enum abstract so messages and codes are listed in one place.

### types/ and semantic/ depend on each other; semantic/ mixes three unrelated concerns

Architecture; severity medium, effort M, risk low.

**Evidence.** types -> semantic: 27 imports in 18 files (`SemanticSignature` in 13 files incl. types/KeyPathType.hx:19 and types/AbstractConversionGraph.hx; `SemanticProgram` in Typer/ProgramTyper/TypingSession; `ModuleCanonicalizer.astTypeName` at types/DeclarationIndex.hx:843; `AliasTable` in types/FieldInference.hx:3; `LambdaName` in typing/TypingSession.hx:521). semantic -> types: 28 imports (`DeclarationIndex`, `SignatureInference`, `FieldInference`, `TypeRelations`, `TypedAst`, and `types.analysis.PurityInference` from semantic/SemanticAssembly.hx:536-542). The 23 files in semantic/ fall into: (a) typer inputs with no module/service dependency: `SemanticProgram`, `SemanticSignature`, `DeclarationLifecycle`, `GenericSpecializationPolicy/Registry`, `ProgramFacts`, `LambdaName`, `AliasTable`; (b) incremental assembly depending on `compiler.modules`/`compilation`/`service`: `SemanticAssembly`, `ModuleAnalyzer`, `ModuleChangeAnalyzer`, `ModuleCanonicalizer`, `DependencyScanner`, `SemanticDependencyCollector`, `Invalidation`, `DeclarationOwners`; (c) language-service index: `SemanticIndex`, `SemanticWorkspace`, `SemanticModel`.

**Cost.** There is no layer order to rely on: a change to the type spelling (`SemanticSignature.type`, required instead of `Std.string` by Type.hx:50-56) lives outside the package that defines `CompilerType`, and the typer transitively shares a package with code that imports `CancellationToken` and `ModuleState`. The folder name gives no hint whether a file is part of the type system, the incremental build, or the editor index, which is the first thing a reader needs to know.

**Proposal.** Move group (a) into `compiler.types` (`SemanticSignature` -> `types/TypeSignature`, `SemanticProgram` next to `DeclarationIndex`), and `astTypeName` to `compiler.syntax`. Split the rest into `compiler.assembly` (or `incremental`) for group (b) and `compiler.index` for group (c). Resulting order: syntax -> types -> assembly -> index/service, with no back edges.

### ProgramTyper.typeProgramMeasured is a 430-line method with nine parallel helper-request queues and 16 cache branches

Architecture; severity medium, effort M, risk medium.

**Evidence.** typing/ProgramTyper.hx:44-473 is one method. `cachedMetadata == null`/`!= null` is tested 16 times in it. Generated helpers use nine request maps on the session (`wireCodecRequests`, `jsonCodecRequests`, `valueEqualityRequests`, `enumEqualityRequests`, `enumMethodRequests`, `enumInterfaceAdapters`, `hashRequests`, `flagsRequests`, `rawRepresentableRequests`; typing/TypingSession.hx:113-134) plus `keyPathDefinitions`, generic owner requests, closure functions and enum representations. The fixed point is hand-rolled: `requestCount()` sums 13 counters (339-343), the loop calls eight `generate` functions with four different signatures (351-386; e.g. `HashGenerator.generate(session, typer)`, `ValueEqualityGenerator.generate(session, compare)`, `FlagsGenerator.generate(session, typer, generated)`, `WireCodecGenerator.generate(session, classes, enums)`), then seven copy-pasted sort-and-append blocks (387-417). `HashGenerator.generate` rebuilds its whole `generated` map on every iteration (typing/HashGenerator.hx:27-28). Timing/allocation sampling is interleaved throughout (46-47, 119-126, 236-238, 418-470).

**Cost.** Adding a helper kind touches the session, the counter sum, the loop and the ordering block; forgetting the counter makes the fixed point stop early and the helper is silently missing from the program. The cached-metadata path and the fresh path are interleaved statement by statement, which is where incremental-vs-clean differences come from. Generators that restart from scratch each iteration do repeated work on large programs.

**Proposal.** Define one `HelperGenerator` interface (`pending():Int`, `generate(sink)`), register the generators in a fixed array, and replace the loop and the seven ordering blocks with one drain that runs until no generator reports pending work, emitting in registry order then name order. Split the method into `typeDeclarations` (fresh) / `reuseDeclarations` (cached), `typeBodies`, `drainGenerated`, `assemble`, with a small phase-timer object instead of 20 local timestamp variables.

### IR generation and the driver depend on typer implementation classes for naming contracts

Architecture; severity medium, effort S, risk low.

**Evidence.** Outside types/: `compiler.types.typing.EnumRuntimeType` is used at 14 sites (ir/IrGenerator.hx:1264,1945,1947,3686; ir/IrEnumDynamicDispatch.hx, ir/IrInlineEnumEligibility.hx, ir/IrEnumRuntimeSpecializations.hx; compilation/FrontendCompilation.hx:1372), `EnumEqualityGenerator.equalsName` at ir/IrGenerator.hx:3823,4198, `ValueEqualityGenerator.equalsName` twice, `CallResolver.nullableMapValue` at ir/IrGenerator.hx:1134, `KeyPathTyping.LITERAL_PREFIX` at FrontendCompilation.hx:995,1180, `RuntimeDependencyTracker.TYPE_ORIGIN_PREFIX` at 1525-1526. `HashGenerator` is imported by ir/IrGenerator.hx:11, ir/ProgramFacts.hx:9 and ir/IrOptionalScalarFlow.hx:7 with no `HashGenerator.` use found by grep. Related: syntax/Parser.hx:700 and 1425 call `compiler.types.analysis.FinalLocalChecker`/`BindingWalker`, an upward dependency from syntax to types.

**Cost.** The generated-name scheme (`$hash...`, enum runtime names, key-path literal prefix) is a contract between typer, IR and the incremental driver, but it is defined inside the classes that generate bodies, so IR imports a 2400-line resolver to reach one static. ROADMAP says backends must not infer semantics from names; the same discipline is not visible at the typer/IR boundary because the names have no single owner.

**Proposal.** Collect the shared name functions and prefixes into one small module in `compiler.types` (e.g. `GeneratedNames`: enum runtime name/declaration, equals/hash names, key-path literal prefix, type-origin prefix) and move `nullableMapValue` to `TypeRelations`; IR and `FrontendCompilation` import only that. Move `FinalLocalChecker`, `BindingWalker`, `FreeVariables` and `AstScan` (AST-only) to `compiler.syntax` so the parser no longer imports types.

### SemanticAssembly.run is one 806-line static function doing canonicalization, invalidation and purity drift

Organization; severity medium, effort M, risk medium.

**Evidence.** semantic/SemanticAssembly.hx:43-848: one `static function run` with 10 parameters, 41 top-level local declarations and 123 `for` loops; it assembles the canonical program from module ASTs (about 55-470), re-runs `PurityInference`/`NoReturnInference` and compares with cached answers (530-545), and computes the invalidation set and reasons. It has a single caller (compilation/FrontendCompilation.hx:166). The file's remaining 250 lines are small static helpers.

**Cost.** The function that decides what gets retyped on an edit, which is the core of incremental correctness, cannot be unit-tested in parts: canonicalization cannot be exercised without a `CompilationContext`, and the invalidation rules cannot be exercised without canonicalizing. Locals from the first phase stay in scope for 700 lines, so it is hard to see which inputs a given invalidation rule actually reads.

**Proposal.** Split into three steps with explicit data between them: `CanonicalProgramBuilder.build(modules, names) -> {program, owners, generatedByModule, genericOrigins, reverseCalls}`, `ProgramFactsDrift.compute(program, cached) -> {facts, driftedFunctions}`, and `InvalidationSelector.select(changes, graph, drift) -> {selected, invalidations}`; `run` becomes the 30-line composition and keeps the timing fields.

### types/analysis is mostly pre-typing AST passes, and several root files are not type-system code

Organization; severity low, effort S, risk low.

**Evidence.** 17 of 24 files in types/analysis/ import neither `CompilerType` nor `TypedAst` (e.g. `PurityInference.hx` 986 lines, `BindingWalker.hx` 341, `LexicalStorageAnalysis.hx` 198, `NoReturnInference.hx` 147); the 7 typed ones are `Scope`, `FlowFacts`, `FlowAnalysis`, `ClosureEffects`, `ControlFlow`, `BindingStoragePlan`, `ClosureConversion`. In types/ root, `TypeRegistry.hx` (209 lines) is the persistent stable-id and class-layout compatibility registry for reloads (serialized to `Bytes`, used by Compiler.hx:286, `CompilationPipeline`, `CompilerPublication`, `ModuleChangeAnalyzer`), not a registry of `CompilerType`s; `NativeTypeDescriptor.hx` + `NativeTypeDescriptorCodec.hx` (882 lines, SHA-256 and byte codec) are an output format used by ExpressionTyper, TypedProgramAssembler and tools/CompilerDriver. Two different `ProgramFacts` exist: semantic/ProgramFacts.hx (purity typedef) and ir/ProgramFacts.hx (class), forcing `compiler.ir.ProgramFacts.of(...)` to be written fully qualified at FrontendCompilation.hx:213.

**Cost.** A reader looking for flow typing has to pick 7 files out of 24; the name `TypeRegistry` suggests the place where types are registered and sits beside `DeclarationIndex`, which actually is that place. The two `ProgramFacts` are passed through the same function and are easy to confuse.

**Proposal.** Split `types/analysis` into `types/flow` (the 7 typed files) and `types/prepass` or `syntax/analysis` (AST-only). Rename `TypeRegistry` to `StableTypeIds`/`ClassLayoutRegistry` and move it next to `compiler.modules`; move `NativeTypeDescriptor*` to `compiler.ffi` or `compiler.runtime`. Rename `semantic.ProgramFacts` to `EffectFacts`.

### Small unused or single-purpose surfaces: DeclarationLifecycle per-declaration state, Typer.typeSelected, AnonymousTypeRegistry instances

Overengineering; severity low, effort S, risk low.

**Evidence.** `DeclarationLifecycle` (semantic/DeclarationLifecycle.hx, 68 lines) keeps a stage per declaration with a position map, but production code only calls `advanceAll` (SemanticProgram.hx:52,58; ProgramTyper.hx:421,426) and `requireAtLeast` (ProgramTyper.hx:48); `stage(id)` is called only from tests/compiler/SemanticProgramMain.hx and `snapshot()` has no caller, so all declarations always share one stage. `SemanticProgram.analyzeThrough` with a stage below `SignatureTyped` is test-only too. `Typer.typeSelected` (types/Typer.hx:26-28) has no caller in src/ or tests/; `Typer.typeAnalyzed` is called only by one test. `AnonymousTypeRegistry` (typing/AnonymousTypeRegistry.hx, 72 lines) holds only the session and is constructed ad hoc at 9 sites (`new AnonymousTypeRegistry(session).register(...)` in KeyPathRuntime, KeyPathOperations x3, ValueEqualityGenerator x2, HashGenerator x2, ConversionResolver) besides the instance BodyTyper keeps.

**Cost.** Minor: `advanceAll` walks every declaration four times per build to move a value that is the same for all of them, and the per-declaration API suggests a partial-typing capability (some declarations body-typed, others not) that the typer does not have, which matters when reading the code for the parallel-typing roadmap item.

**Proposal.** Reduce `DeclarationLifecycle` to a single program-level stage field on `SemanticProgram` (keep the ordered-transition check) until per-declaration stages are actually driven by the typer; remove `Typer.typeSelected`; make anonymous-type registration a method on `TypingSession` (`session.registerAnonymous(type)`) and delete the wrapper class.

### Leave alone

- `ProgramFacts` handed from `SemanticAssembly` to the typer (src/compiler/semantic/ProgramFacts.hx, ProgramTyper.hx:128-134): looks like an extra parameter, but it guarantees the purity/no-return answers bodies are typed against are the same ones the next build's drift check compares with.
- Per-function query records on the session (`purityQueries`, `noReturnQueries`, `keyPathUses`, `inlineConstantDependencies`, `defaultArgumentSources`; typing/TypingSession.hx:411-441): they are the dependency edges that let an unchanged body be retyped when an answer it relied on changes.
- Arrays kept beside maps (`DeclarationIndex.enumAbstractList`/`aliasList` at types/DeclarationIndex.hx:66-69, `DeclarationLifecycle.ids`/`current`, `TypingSession.enumsInFile`): follows the documented rule that map iteration is a dynamic call per element in the stock-Haxe worker (docs/ARCHITECTURE.md, performance rules).
- Sorting names with `Reflect.compare` before emitting generated functions (ProgramTyper.hx:387-417, HashGenerator.hx:55-57 and similar): required for deterministic output and the byte-identical self-hosting check.
- Per-body counters instead of one global counter (`functionAdapterCounts`, `substrCounts`; TypingSession.hx:150-157) and lambda cache keyed by position and captures (`lambdaCache`/`lambdaVariants`, 78-82): names must not depend on how many other functions were typed in this build, or incremental and clean builds diverge.
- `TAnonymous` sharing its `fields` array to represent recursive typedefs, and the rule to spell types with `SemanticSignature.type` rather than `Std.string` (types/Type.hx:46-58, `OpenStructure` in DeclarationIndex.hx:47-57): intentional cyclic value; do not replace with structural copies.
- `anonymousUnits` / `keepAnonymousUnits` / `RetainedFromPrevious` (TypingSession.hx:88-104, ProgramTyper.hx:475-530, typing/RetainedFromPrevious.hx): carries generated classes and anonymous types for code that was not retyped; removing it breaks warm builds.
- String literals built as `'$' + 'cell:'` (e.g. BodyTyper.hx:282, 553): avoids Haxe string interpolation of `$name` inside single quotes; not an oversight.
- `Typer.hx` re-exporting `TyperPhaseMetrics`/`MeasuredTypedProgram` as typedefs (types/Typer.hx:13-14): keeps `compiler.types.typing` out of the imports of Compiler/CompilationPipeline.
- `DeclarationIndex.abstractDeclaration` synthesizing an `AstAbstract` view for enum abstracts (DeclarationIndex.hx:74-96): one lookup path for conversions and methods of both abstract forms.
- `#if haxeon` / `#elseif hl` allocation sampling in `SemanticAssembly.run` (SemanticAssembly.hx:47-51): the two compilers expose different GC APIs; needed while both build the worker.
- Semantic vs physical type pairs in `TypeRepresentation` (typing/TypeRepresentation.hx:24-28, 64ff): the dual result is the documented generic-specialization design (docs/GENERIC_SPECIALIZATION.md), not accidental duplication, even though it places representation choices in the typer.

## Frontend, driver and compiler service

### Compiler session state is enumerated by hand in five places, and validate() uses a second, cold fork path

Architecture; severity high, effort M, risk medium.

**Evidence.** src/compiler/Compiler.hx: snapshot() 953-976, createCandidate() 978-1005, adoptCandidate() 1007-1028, restore() 1039-1057, plus the CompilerSnapshot typedef in src/compiler/compilation/CompilerPublication.hx:13-34. Each lists the same ~14 fields. They already disagree: adoptCandidate takes candidate.genericSpecializations (1026) but CompilerSnapshot has no such field and restore() does not put it back, so rejectPublication/retractPublication (409-430) keep the rejected build's registry. A second mechanism, fork() (804-817), is used by validate() (784) and compileExpressionInt() (798): it re-registers every module from text with candidate.update(state.source.path, state.source.text), giving fresh ModuleStates with no tokens, AST, typed or IR caches, then runs a full compile() including backend assembly and patch encoding. fork() also drops explicit module names: update() re-derives the name with ModulePath.fromFile(path) (685), although refreshLoadedSource (708) exists precisely because lazily loaded modules have absolute paths.

**Cost.** Every new cache (pipelineSnapshot, loweredCache, reachabilityCache and declarationOwners were each added this way) needs five coordinated edits; missing one silently leaks state from a failed or rejected build. LanguageService.validate (service/LanguageService.hx:347, reached from editor/LanguageServiceProtocol.hx:104) pays a cold whole-program build per unsaved-edit validation. That is the opposite of roadmap gate B ("shared snapshots and one-pass commit/rollback remain").

**Proposal.** Move the build-owned state into one SessionState object (modules, types, object caches, typed program, semantic program, ABI, inline/pipeline/lowered/reachability caches, declarationOwners, genericSpecializations, assembler). Give it copyForCandidate(), and make the Compiler hold a single reference, so adopt and restore become one assignment and the snapshot is that object. Reimplement validate() as createCandidate + FrontendCompilation.run(lowerToIr=false) without adopt, then delete fork().

### FrontendCompilation.run is one ~830-line function that also owns the IR pass pipeline

Architecture; severity high, effort L, risk medium.

**Evidence.** src/compiler/compilation/FrontendCompilation.hx:82-910 is a single static function with 11 parameters that recurses into itself to restart (603). It does module graph and reachability (107-162), semantic assembly (166), typing (189-238), per-module typed/IR cache publication and pruning (239-582), IR table assembly (658-755), and the target-specific IR pass order: value-array rewrite, constructors, phi scalarization, scalar arguments/closures, scalar replacement, nullable flow, inliner, verifier (768-857). It contains 15 AllocationMeter.sample() and 18 Sys.time() calls, 9 isWasmTarget() branches, and builds the 32-field FrontendResult twice (627-657 and 879-909). The class doc says "frontend", but the Wasm and HashLink pass orders differ only here (810-824).

**Cost.** The pass order, which is the thing that changes when a backend or a pass is added, is buried in a frontend function under timing boilerplate, and part of it is also in IrProgramAssembler.assemble. Dozens of locals stay live across phases, so reuse and invalidation changes are high-risk. No phase can be unit-tested or parallelised alone (roadmap B: parallel parse and type work).

**Proposal.** Split run() into phase functions over an explicit per-build record: resolveGraph, assembleSemantics, typeProgram, publishModuleArtifacts, assembleIrInputs. Move lines 768-857 into an IrPipeline class in compiler.ir with one run(ir, profile, options) whose target differences come from TargetProfile. Record timings and allocation through one phase-scope helper instead of paired locals, and build FrontendResult once.

### The build driver is HashLink-centric: Wasm builds still run a full HashLink assembly, and the Wasm backend runs outside the Compiler

Architecture; severity high, effort L, risk high.

**Evidence.** src/compiler/compilation/BackendAssembly.hx:101-113: "Compilation sessions retain a HashLink assembly even when the requested artifact is Wasm". It copies the IR, runs IrScalarClosures and IrEnumTagLowering.escapes, then candidateAssembler.assemble (170). CompileResult.module is HlCode (Compiler.hx:109), and Compiler owns assembler:HlModuleAssembler (283), loweredCache and publishedAbi. The real Wasm encode happens later in the tools layer (src/compiler/tools/CompilerDriver.hx:68-86) from result.ir. There are 8 isWasmTarget() branches in BackendAssembly and 9 in FrontendCompilation. The target is a define string decoded separately in Compiler.hx:1118-1131, CompilationContext.hx:116-121, CompilerDriver.hx:52-57 and 323-346, CompilerSession.hx:76-94, and six comparisons in CompilerArguments.hx:95-114; the "wasmgc" | "wasm-gc" alias is repeated at each.

**Cost.** Each Wasm compile pays for an IR copy plus HashLink lowering and assembly it discards, which works against the compile-speed priority. A Wasm-only construct must also lower to HashLink or be special-cased. Adding a target means touching about ten string switches, and missing one gives silently wrong ABI or layout choices (nativeLayoutTarget and valueArrayTarget must agree).

**Proposal.** Parse the target once into the existing BackendTarget enum (compiler.backend.Backend) at CompilerArguments, and carry it on Compiler in place of defines.get("target"). Put a backend-session interface behind Compiler (assemble(ir, changes) -> artifact + ABI) with HashLink and Wasm implementations, so BackendAssembly is the HashLink one and Wasm builds skip it. Make CompileResult.module optional or backend-typed. First confirm what the Wasm path still reads from the HashLink assembly (functionIds and runtimeIdentity are used in the result) and supply those from the IR.

### CompilerSession resets the whole session on typedef/enum/abstract edits, a correctness workaround outside the compiler

Architecture; severity high, effort M, risk medium.

**Evidence.** src/compiler/tools/CompilerSession.hx:121-158 and 332-367. Before each request it re-lexes the old and new text of every changed manifest file and every lazily loaded module (ConditionalCompilation + Lexer), compares the token text of top-level typedef/enum/abstract declarations, and calls reset() on any difference. The comment says: "A typedef/enum/abstract edit can change an unchanged class's field ABI. Rebuild that semantic graph until transitive shape invalidation is complete." Only CompilerSession has this guard; LanguageService (service/LanguageService.hx:225-236) and AndroidBuild/AndroidReload call Compiler.update directly without it.

**Cost.** Any edit to a typedef, enum or abstract costs a cold whole-program compile and discards live-patch history, forcing a reload in a watch session. The same edit through the language service or the JSON-lines protocol's compile takes the incremental path the guard says is not yet correct, so the two front ends can disagree. ROADMAP gate B lists typed dependency invalidation as done, yet the guard is still there.

**Proposal.** Move the decision into the compiler. Either finish alias/enum/abstract shape invalidation (ModuleState already has aliasFingerprints, enumFingerprints and abstractFingerprints) or, as an interim, have Compiler detect a structural fingerprint change during parse and invalidate dependents itself. Then delete hasStructuralDeclaration/structuralDeclarations and the two pre-scan loops. Add a warm-edit test that changes a typedef's shape and compares bytes with a fresh build, as Main --warm-edit already does for functions.

### Source-to-AST preparation is hand-assembled at seven sites with different defines; LanguageService parses defines differently from Compiler

Architecture; severity medium, effort S, risk low.

**Evidence.** ConditionalCompilation.process + new Lexer + new Parser is repeated in semantic/ModuleAnalyzer.hx:373, service/LanguageService.hx:321-323 and 1790-1791, tools/CompilerSession.hx:336-338, formatter/Formatter.hx:32-33, service/ImportOrder.hx:40 and tools/BootstrapStatus.hx. LanguageService keeps its own editorDefines, built as [for (define in defines) define => "1"] (LanguageService.hx:276), while Compiler.defineMap (Compiler.hx:732-740) splits "name=value". The LSP passes targetDefines, which include "target=hl" (editor/lsp/ProjectWorkspace.hx:442), so the recovery parse and workspace-symbol parse see a define literally named "target=hl" with value "1". Formatter and ImportOrder always pass no defines.

**Cost.** When a file has a syntax error, the recovered AST and its diagnostics are computed under different conditional-compilation results than the compiler's own parse, so `#if target == ...` branches and valued defines flip. That gives wrong recovered symbols and diagnostics in exactly the last-good/recovery path gate D relies on. Any change to the preprocessing step must be repeated seven times.

**Proposal.** Add one syntax-level entry, e.g. SourceParser.parse(file, defines, recovering) returning {tokens, program, conditionalDefines, diagnostics}, and use it at all sites. Expose the compiler's active define map read-only (Compiler.defines is private) and delete LanguageService.editorDefines.

### CompileMetrics is a flat 62-field record spelled out in five places

Overengineering; severity medium, effort S, risk low.

**Evidence.** The typedef in src/compiler/Compiler.hx:137-210 has 62 fields, 44 of them *Ms:Float. A full zero-filled literal sits in the cached-result path (Compiler.hx:845-907) and a full literal in compilation/CompilationPipeline.hx:182-238. They are fed by the 32-field FrontendResult built twice (FrontendCompilation.hx:627-657, 879-909) and the BackendAssemblyResult timing fields. The only reader of nearly all the Ms fields is one string concatenation, CompilerDriver.phaseReport (tools/CompilerDriver.hx:264-288). Outside it, .metrics. accesses in src and tests touch about 15 fields, mostly counts. The record already has a generic allocationPhases:Array<PhaseAllocation> channel for the same kind of data.

**Cost.** Adding or renaming one timed phase means editing the typedef, two or three literals, the FrontendResult pair and the report string. The 62-line zero literal in Compiler.compile is noise in the most central method of the class.

**Proposal.** Keep the counts and reuse fields as named fields; replace the 44 timing fields with phases:Array<{name:String, ms:Float}>, or extend PhaseAllocation with ms. Fill it from a phase-scope helper and have phaseReport iterate it; the cached-result path then returns an empty list.

### src/Main.hx is the test-program compiler, wired differently from the product path

Organization; severity medium, effort M, risk medium.

**Evidence.** src/Main.hx:8 documents itself as the "Command-line compiler entry point", but its users are the test driver (tests/driver/TestRunner.hx:54-72 `Main --batch`, scripts/test-driver.sh:25) and build.hxml. The real CLI is compiler.tools.HaxeonCompiler -> CompilerDriver (tools/HaxeonCompiler.hx). Main.newCompiler (81-89) never calls configure(), so the program compiles with an empty define map, whereas CompilerSession adds CompilerDriver.targetDefines (haxeon, target=hl, hl, sys, target.sys, target.threaded; CompilerDriver.hx:323-346). It also bypasses CompilerSession (no publication tracking, no source manifest) and writes with HlWriter.encode directly. Main carries its own test modes (--warm-edit 91-124, --no-early-prune, and an env reset per batch request at 29 and 41).

**Cost.** The tests/programs suite, the main language-parity signal, runs under different defines and wiring than `haxeon build`, so `#if hl`/`#if sys`/`#if target.threaded` code and driver-level behaviour are not covered by it. The name hides that it is a harness. The two CLIs can drift.

**Proposal.** Rename and move it (e.g. tests/driver/ProgramCompilerMain or tools.dev) and have it build a CompilerRequest and go through CompilerSession/CompilerDriver with a plain or live flag. Keep --batch and --warm-edit as harness modes on top. If full driver output is too slow for the suite, at least share a single function that creates and configures the Compiler (target defines, stdlib root, intrinsics); that same setup is repeated in Main.hx:81-89, CompilerSession.hx:165-188, LanguageService.hx:220-223 and 259-262, and tools/AndroidBuild.hx:71-76.

### Compiler embeds the FFI registry: 9 fields and about 180 lines unrelated to compilation state

Architecture; severity medium, effort S, risk low.

**Evidence.** src/compiler/Compiler.hx fields 289-297 (ffiInterfaceSources, ffiInterfaceModels, ffiProjectionSources, ffiProjectionProfiles, ffiProjectionPaths, ffiProjectionCache, ffiSourceOrigins, ffiCompositionCache, ffiAbiCache) and methods 443-623 (registerFfiInterface, registerFfiProjection, refreshFfiProjection, ffiSourceOrigin, ffiAbi, ffiComposition, buildFfiComposition, collectFfiDependency, ffiDeclarationName, ffiConfigurationSnapshot), plus FfiConfiguration and three typedefs at 60-96 and the eight copy loops in the constructor (354-376). The file mentions ffi/Ffi 111 times. The sibling concern, natives, is already a separate NativeRegistry with clone() (src/compiler/runtime/NativeRegistry.hx).

**Cost.** Compiler.hx is harder to read as the transactional core. The clone constructor copies the eight FFI maps by hand, and ffiSourceOrigins is not among them, so a candidate or fork has no FFI source origins. FFI composition and caching cannot be tested without a Compiler.

**Proposal.** Extract compiler.ffi.FfiRegistry, owning the nine maps, register/compose/abi/cNatives/sourceOrigin and a clone(). Compiler keeps `final ffi:FfiRegistry`, the two public add* methods with the compiledOnce freeze check, and the update() call for projected modules via a callback.

### CompilationContext is a wide forwarding layer, and compilation/semantic/modules/service form import cycles

Architecture; severity medium, effort M, risk low.

**Evidence.** src/compiler/compilation/CompilationContext.hx (281 lines) is documented as "Narrow, typed access", but it exposes 10 get/set properties and about 30 one-line forwarders to Compiler privates through @:allow (Compiler.hx:236-238). That includes writable assembler, publishedAbi, compiledOnce, cachedSemanticProgram and pipelineSnapshot, plus static pass-throughs mapIsEmpty/copyIndices/explicitFunctionSignatures (209-218). explicitFunctionSignatures has no caller other than the forwarder (Compiler.hx:1059, CompilationContext.hx:214), and FrontendCompilation has its own explicitSignature (1426). Package dependencies loop: compiler.semantic.SemanticAssembly and compiler.modules.CodeIdentityTable import compiler.compilation.CompilationContext while compilation imports both packages. compiler.service.CancellationToken is imported by 9 lower-layer files (compilation x5, Compiler, modules/ModuleReachability, semantic x3). CompilationPipeline.hx:3-57 still carries about 55 imports from when it was split out of Compiler, most unused in its 240 lines.

**Cost.** The context does not narrow anything, since every phase can mutate every piece of compiler state. So it adds a hop without making the candidate's read and write sets visible, which is what parallel typing and one-pass commit need. The cycles mean modules and semantic cannot be compiled or tested without the driver.

**Proposal.** Once session state is one object (first finding), pass it directly and delete the property forwarders. Keep on the context only derived per-build services: ModuleAnalyzer, target profile, parse metering. Move CancellationToken/CancellationError to the compiler root package, where Diagnostic already lives. Give SemanticAssembly and CodeIdentityTable a small interface (writableState, parse, addTypeDependencies, identitySalt) declared in modules. Delete the dead explicitFunctionSignatures pair and prune CompilationPipeline's imports.

### Debug and check switches are process-global state read mid-pipeline

Architecture; severity medium, effort S, risk low.

**Evidence.** HAXEON_CHECK_REUSE is read with Sys.getEnv at four sites per build (FrontendCompilation.hx:708 and 762, CompilationPipeline.hx:108, BackendAssembly.hx:180). HAXEON_EXPLAIN_INVALIDATION is read at CompilationPipeline.hx:154 and HAXEON_IDENTITY_GRAPH at modules/CodeIdentityTable.hx:51. Across src/compiler there are 35 getEnv("HAXEON_*") reads of 21 names. IrPassMeter keeps static order/bytes/counts (compilation/IrPassMeter.hx:8-10), reset inside FrontendCompilation (768) and read by CompilerDriver (194). BackendAssembly.liveFieldReserve is a public static var (BackendAssembly.hx:40) mutated by tests/runtime/LiveObjectLayoutMain.hx:34-37. Main.batch has to restore HAXEON_EARLY_PRUNE with Sys.putEnv between requests (src/Main.hx:29, 41, 60).

**Cost.** One process hosts several compilers: LanguageService keeps up to 3 (LanguageService.hx:205, 268), CompilerServer serves many requests, and the batch test worker serves many programs. Process-wide switches and meters therefore leak between builds, as the putEnv reset shows, and they are not part of the configuration identity that keys caches. Static meters also block the planned parallel work.

**Proposal.** Read the switches once into an immutable CompilerOptions/DebugOptions value at Compiler construction (checkReuse, explainInvalidation, earlyPrune, identityGraphPath, liveFieldReserve). Pass it through the context and include the relevant ones in environmentKey. Make IrPassMeter an instance owned by the build and returned in the metrics.

### Package names in scope do not say what they hold; several files are dead or test-only

Organization; severity low, effort S, risk low.

**Evidence.** compiler/tools/ mixes the product build service (CompilerArguments, CompilerRequest, CompilerDriver 371 lines, CompilerSession 368, CompilerServer 314, SourceManifestLoader) with diagnostics (CompilerMemoryCensus, CompilerMemoryLog, AllocationCensus) and one-offs (GenerateValueLaneRuntime, WholeNumber). The "persistent compiler service" of the roadmap is therefore in tools/, while compiler/service/ holds the language service plus lint helpers ImportOrder/UnusedImports, whose only production user is src/tools/LintCommand.hx. compiler/runtime/ (compiler-side knowledge of runtime contracts) sits next to src/runtime/ (the actual runtime API). Dead or near-dead: runtime/wasm/WasmRuntimeContract.hx has zero references anywhere in src, tests or packages; tools/BootstrapStatus.hx (295 lines) measures bootstrap readiness and is referenced only by scripts/bootstrap-status.sh and docs/DEVELOPMENT.md, although ROADMAP gate E records self-hosting as done; service/Repl.hx plus Compiler.compileExpressionInt (798-802) are used only by tests/tooling/ReplMain.hx; service/SourceFormatter.hx is a 10-line "compatibility facade" with one production caller (LanguageService.hx:575). AllocationMeter/IrPassMeter live in compilation/ while the other meters are in tools/.

**Cost.** Navigation: a newcomer looking for the build service, the language service or the runtime contract opens the wrong folder. Dead files are still compiled into the self-hosted compiler and reformatted in tree-wide sweeps (the last BootstrapStatus commit is "Sort imports across the tree").

**Proposal.** Rename compiler/tools -> compiler/driver (Arguments, Request, Driver, Session, Server, SourceManifestLoader) and gather the meters and censuses in compiler/diagnostics. Move ImportOrder/UnusedImports to a lint package or beside LintCommand. Rename compiler/runtime to something like compiler/runtimecontract, or fold it into abi. Delete WasmRuntimeContract. Delete BootstrapStatus and its script, or confirm someone still runs it. Have LanguageService call Formatter directly and point the tests at it. Keep Repl only if a REPL is planned; otherwise move it to tests.

### ModuleState is a 57-field mutable record shared by every phase, and its commit steps are duplicated

Architecture; severity low, effort M, risk medium.

**Evidence.** src/compiler/modules/ModuleState.hx declares 57 public vars covering five phases: source/tokens/AST in three generations (current, recovered, lastGood); 10 fingerprint maps; typed-function caches with 5 side tables; IR caches; and 15 canonical* fields. copy() lists them by hand (150-207). I checked it is complete today (only `source` goes through the constructor), but map fields are deep-copied and canonical* arrays are shared by reference, a convention that exists only in that method. Writers are spread over compilation/, semantic/ (3 files) and tools/. The last-good promotion block is duplicated in compilation/AnalysisTransaction.hx:44-52 and compilation/CompilationPipeline.hx:139-149, and the copy-failed-diagnostics-back block in CompilationTransaction.hx:48-55 and AnalysisTransaction.hx:71-80.

**Cost.** Copy-on-write correctness (writableState) depends on every new field being added to copy() with the right depth; a missed or shallow-copied field corrupts the rollback snapshot with no test failing immediately. Copying 20+ maps per touched module is part of the candidateSetup and publication cost. Nothing says which phase owns which field.

**Proposal.** Group the fields into per-phase immutable-by-replacement records (ParsedModule, ModuleFingerprints, TypedModuleCache, IrModuleCache, CanonicalModule), so copy() becomes five reference copies and a phase replaces its own record. Move markLastGood() onto ModuleState and the diagnostic copy-back into one shared helper used by both transactions.

### Leave alone

- src/compiler/Frontend.hx (22 lines, a stateless source -> IR helper): it has no production caller, but tests use Frontend.compile/compileFile 403 times. Keep it as the unit-test entry.
- src/compiler/formatter/FormatScanner.hx is a second, lossless lexer beside syntax/Lexer.hx. This is deliberate (the header says the compiler lexer discards trivia and stays lean on the hot path), and it is made safe by Formatter.format parsing first (formatter/Formatter.hx:32-33) and TokenPreservation.verify re-lexing input and output with the real Lexer. One caveat: its keyword table has 35 entries against the Lexer's 36 (`defer` is missing), so sharing that one table would be worthwhile.
- Lambda numbering with an undo journal inside the parser (src/compiler/syntax/Parser.hx:25-78, 525-630): it looks like identity logic in the wrong layer, but the `<member>#<ordinal>` names are purely positional, must survive speculative-parse rewinds, and are what PatchPlanner/LambdaAlignment compare. syntax/ imports nothing from semantic, types or ir.
- Compiler.verifyMemo is shared with candidates rather than copied (src/compiler/Compiler.hx:268, 992-993). This is intentional and documented: an acceptance is valid only while the reads it recorded still hold, so a failed build cannot leave a wrong entry.
- CompilerPublication (src/compiler/compilation/CompilerPublication.hx): a small explicit state machine (Untracked/Ready/Pending) with a retractable history of 3. It has one implementation, but it is the reload-safety core for gate C and for --strict-live refusals; do not fold it into Compiler.
- HAXEON_CHECK_REUSE recomputation paths (FrontendCompilation.hx:708-716 and 838-852, BackendAssembly.hx:180-194, CompilationPipeline.hx:108-117) look like parallel code paths, but they are a test oracle for the reuse caches (docs/ARCHITECTURE.md "Check mode"). Keep the behaviour; only how the switch is read should change.
- CompilerSession.read() reads each file twice and compares (src/compiler/tools/CompilerSession.hx:311-327). It guards against mid-write reads from editors, where timestamp resolution is not reliable. The per-request requestSources cache makes every consumer see the same bytes.
- CompilerDriver publishes the patch and stamp before the full module on live edits (deferFullModule, src/compiler/tools/CompilerDriver.hx:61-63 and 142-145), writes via .tmp + replaceFile with a 50-attempt retry (309-321), and writes the .live.full marker last. The ordering is the host protocol, and the retry is for Windows file locking.
- ModuleGraph.initializationOrder uses a hand-written binary heap (src/compiler/modules/ModuleGraph.hx:103-133). It gives a deterministic lexicographic topological order without re-sorting the ready set, and assembly order must not depend on map iteration.
- src/compiler/Arrays.hx and tools/WholeNumber.hx: tiny helpers that look like stdlib gaps but encode measured performance and precision rules (preallocated arrays per the performance rules in docs/ARCHITECTURE.md; byte counters above 2^31).
- AllocationMeter's three #if branches (src/compiler/compilation/AllocationMeter.hx:21-45) and the #if (hl && !haxeon) native stubs in LspMain/CompilerServer: these are needed while the compiler must build with both official Haxe and Haxeon (self-hosting gate E).
- LanguageService keeps up to 3 Compilers keyed by scope and FFI configuration (src/compiler/service/LanguageService.hx:251-273). FFI models and typed declarations are frozen per configuration, so switching projects would otherwise rebuild everything. The LRU of 3 is a bounded, explicit trade-off.

## FFI and tools (`src/compiler/ffi`, `src/tools`, `lib`)

### HxiHaxeEmitter is a 3,081-line god class: source printer, IR native builder, naming policy and ABI descriptor encoder in one, with a planner it only half uses

Architecture; severity high, effort L, risk medium.

**Evidence.** src/compiler/ffi/HxiHaxeEmitter.hx is 26% of the package. sourceRaw spans lines 409-1269 (860 lines, one function); emitOutputWrapper 1776-2046 (270 lines, 19 parameters at 1776-1779); cNatives 174-378 builds IrCNative (imports compiler.ir.Ir at lines 10-12) inside a class named 'HaxeEmitter'. HxiProjectionPlanner produces HaxeProjectionModel (enums/structures/handles/callbacks/functions) but the emitter re-walks plan.source.declarations and looks plan entries up by linear search: Lambda.find(plan.handles/callbacks/enums/structures ...) at lines 567, 591, 682, 695, 711, 761, 828, 874; only plan.enums (546) and plan.functions (1142) are iterated directly. cNatives ignores the plan entirely and re-derives its own 'directed' set (lines 196-224). Dependencies are circular: the planner calls HxiHaxeEmitter 23 times, HxiProjectionProfileValidator 98 times, CxxProjection 14 times (grep -c 'HxiHaxeEmitter\.'), mostly for the naming functions at lines 2295-2490.

**Cost.** Any new projection feature (a new wrapper kind, a Wasm-specific shape, a Pragtical-driven binding need) means editing an 860-line function whose state is ~25 local maps and 7 'usesX' flags. The Haxe source and the IrCNative list are computed by two independent walks that must agree on which functions are supported and on the descriptor string; a divergence yields a generated extern whose native record is missing or has a different signature. Lambda.find per declaration is quadratic on large headers and runs on every compiler start with FFI interfaces.

**Proposal.** Split along the seams that already exist: (a) HxiNaming (lines 51-170 and 2295-2490: identifier validation, projected names, enum prefixing) with no emitter dependency, so planner/validator/CxxProjection depend on it rather than on the emitter; (b) HxiAbiDescriptor (abiDescriptor/aggregateDescriptor/fieldDescriptors/project/irType, lines 2491-2605 and 2826-3081); (c) HxiCNatives for the IrCNative builder, driven from the same plan; (d) the emitter proper, split per declaration kind (structs, handles, enums, callbacks, function wrappers) and iterating plan.* instead of model.declarations. Make the plan carry the supported/unsupported decision and the signature string once so both outputs read it.

### The offline Clang importer (4.9k lines) lives inside the compiler package and is fingerprinted and interpreted with the whole compiler source tree

Architecture; severity high, effort M, risk low.

**Evidence.** Importer-only files (CHeaderImporter, CxxHeaderImporter, CxxProjection, CxxThunkGenerator, CxxAbiLowerer, CxxSubsetValidator, CxxModel, CxxTypeTools, Clang*.hx x5, ProcessOutputCapture, HxiWriter, HxiAudit) total 4,942 of 11,790 lines; grep shows their only outside users are src/FfiImportMain.hx and src/FfiAuditMain.hx (nothing in Compiler.hx, typer, IR or backends). src/build/provider/FfiProvider.hx:19-36 runs them as scripts/haxeon-ffi-import = `haxe common.hxml --run FfiImportMain` (eval interpreter) and adds every compiler source root as an action input (line 36-37); build/execution/ActionFingerprint.hx:171-190 recursively digests directory inputs. src has 588 .hx files / 168,748 lines. ProcessOutputCapture.hx:38-42 has an eval-only branch that cannot honour timeouts.

**Cost.** Every FFI import action's fingerprint covers all 588 compiler files, so any edit to the typer or a backend invalidates and re-runs every header import in every project (clang + interpreted importer), which works against the incremental-build priority exactly when dogfooding the compiler against Pragtical packages. The interpreted run pays eval start-up and loses subprocess timeouts. In the tree, readers cannot tell which half of compiler/ffi the compiler actually links.

**Proposal.** Move the importer side to its own package and root-level folder (e.g. src/ffiimport/ or src/tools/ffi/ with package tools.ffi), leaving compiler.ffi as the HXI consumer only (Hxi*, NativeLayout, NativeCallPlan). Have FfiProvider depend on a prebuilt importer artifact (the same tools.dev.ToolArtifacts mechanism the CLI already uses for HL-bytecode tools) or at least on the importer's own roots plus compiler/ffi, not on all of src. Move CHeaderEmitter (IrNative to hl.h header, used only by compiler/tools/CompilerDriver.hx) next to the HL backend or driver, since it is not FFI import.

### The C importer duplicates the Clang AST helpers the C++ importer shares, and the two copies have diverged

Architecture; severity medium, effort M, risk medium.

**Evidence.** ClangAstTools.hx (194 lines) is used by CxxHeaderImporter and ClangFrontend only (grep 'ClangAstTools' has no hit in CHeaderImporter.hx). CHeaderImporter.hx re-implements field (1057), children (943), sourceSpan (607), sourceFile (632), sourceRange (819), locationPath (830), hasAnnotation (761), isUserDeclaration (1068), pathKey (1079), declarationLocation (1082), constantValue (948), plus its own static caches sourceCache/sourceFiles (lines 25-26). The copies differ in behaviour: ClangAstTools.isUserDeclaration (101-122) resolves spelling locations and rejects includedFrom declarations without a file; CHeaderImporter.isUserDeclaration (1068-1077) only prefix-matches currentFile. Roots also differ: C uses the header's directory only (CHeaderImporter.hx:60), C++ adds every --include directory (CxxHeaderImporter.hx:56-58).

**Cost.** A fix to header-ownership or source-span logic lands in one importer only; the same header imported as C and as C++ can select a different declaration set. About 250 of CHeaderImporter's 1,093 lines are duplicate plumbing, and the process-wide static caches make a long-lived host (LSP/build session) keep stale header bytes.

**Proposal.** Make CHeaderImporter use ClangAstTools for all node/location/annotation helpers and delete its private copies, deciding explicitly (with a test) which isUserDeclaration and root policy is correct for both languages. Move the source cache into an instance owned by one import run.

### Importer entry points take 10-17 positional parameters, and the CLI/manifest merge is a 170-line main with silently ignored options

Organization; severity medium, effort S, risk low.

**Evidence.** CxxHeaderImporter.importHeader has 17 positional parameters (CxxHeaderImporter.hx:40-43); CHeaderImporter has three entry points that all forward to importHeaderModel with 10 (CHeaderImporter.hx:28-41); HxiAudit.audit/canonical take 9 (HxiAudit.hx:21, 65). FfiImportMain.hx:16-33 declares 22 locals in one var statement merging manifest defaults with flags, and calls the importer at 124-126 with four adjacent Bool arguments (trivialValues, cxxLifetimes, cxxVirtual, cxxThunksPath != null). `--std=` and the manifest `standard` are parsed (line 44, 23) but never passed to the C importer, which hard-codes standard: "c11" (CHeaderImporter.hx:49). Comments at FfiImportMain.hx:141 and 148 name an option '--haxe-out' that does not exist (the flag is --haxe-output-dir). A ClangInvocationOptions typedef already exists for the frontend but stops at ClangFrontend.run.

**Cost.** Swapping two adjacent Bool or Null<String> arguments compiles cleanly and produces a wrong binding; tests/compiler/CxxHeaderImporterMain.hx has 27 such positional call sites to keep in sync. A user setting --std=c17 for a C header gets c11 with no diagnostic. Adding one importer option touches the manifest class, the main, the importer signature and all tests.

**Proposal.** Introduce one FfiImportOptions structure (header, target, language, standard, clang, includes, defines, compileCommands, library, interfaceName, dependencies, excludedHeaders, cxx:{profile, trivialValues, lifetimes, virtualDispatch, thunks, selections, ownership}). Build it in one place from project.FfiManifest plus flag overrides, validate it there (the cross-option checks at FfiImportMain.hx:97-121), and pass it to both importers and HxiAudit. Either pass `standard` to the C frontend or reject --std for C.

### FFI interface registry (9 maps, ~180 lines) is implemented inline in Compiler.hx, and interfaces are parsed twice

Architecture; severity medium, effort M, risk low.

**Evidence.** src/compiler/Compiler.hx:289-297 declares nine ffi* fields (sources, models, projection sources/profiles/paths, projection cache, source origins, composition cache, ABI cache); lines 443-621 implement registration, dependency composition (buildFfiComposition/collectFfiDependency 575-614), cycle detection, projection refresh and origin lookup. Every HxiProjection entry point therefore takes the same loose tuple (model, omitted, visibleDeclarations, abi, profile): 8 signatures with '?omitted:Map<String, Bool>, ?visibleDeclarations' in compiler/ffi. FfiConfiguration's constructor calls HxiInterfaceOrder.dependenciesFirst, which runs HxiParser.parse on every interface (HxiInterfaceOrder.hx:22) only to read names and dependencies; registerFfiInterface then parses the same text again (Compiler.hx:479). HxiInterfaceOrder imports compiler.Compiler.FfiInterfaceSource (line 3), so compiler.ffi depends back on Compiler. The 'declaration name' switch is copy-pasted in 6 places (Compiler.hx:618, HxiHaxeEmitter.hx:53, HxiAudit.hx:165, CxxAbiLowerer.hx:403, HxiAbi.hx:287, HxiSemantics.hx:195).

**Cost.** Compiler.hx (1,156 lines) owns FFI caching rules it should only consume; the composition tuple is threaded by hand through every call, so a caller that forgets `omitted` silently emits duplicate declarations from a dependency. Double parsing costs time on every compiler construction and candidate rebuild (FfiConfiguration is rebuilt per snapshot). Adding a constructor to HxiDeclaration means editing six identical switches.

**Proposal.** Extract compiler.ffi.FfiRegistry owning the nine maps, composition and ABI caches, exposing register/projections/cNatives/sourceOrigin; Compiler keeps one field and the two freeze checks. Give it a composed-interface value (model + omitted + visible declarations + abi + profile) that HxiProjection takes as one argument. Let the registry keep the parsed model from ordering so text is parsed once, move FfiInterfaceSource into compiler.ffi, and put a single `name` accessor in HxiModel.

### The native-call descriptor wire format uses unnamed numeric type codes shared by string convention between the emitter and three backends

Architecture; severity medium, effort M, risk medium.

**Evidence.** Codes 0-15 are assigned as literals in HxiHaxeEmitter.project (lines 2491-2605, e.g. `code: sign == Unsigned ? 8 : 7`, `unsigned ? 2 : 1`), tested as literals 36 times in the same file (`element.code == 11`, `element.code == 1 || element.code == 2` at ~952/968, irType switch 3070-3080, scalarLetter/scalarAccess 2721-2783 on string forms "1".."14"). The same table is re-declared in src/compiler/backend/wasm/WasmCAbi.hx:21-32 ('as HxiHaxeEmitter writes them') and HlLower.hx:1874-1880 decides UTF-8 results with `StringTools.startsWith(result, "13") || startsWith(result, "14")` on the text after '>'. The format ('{size;align;codes}', ',' and '>') is assembled in abiDescriptor/aggregateDescriptor (2826-2890) and re-parsed with split in singleScalarCode (2713-2718). No file defines the codes by name.

**Cost.** The ABI contract between generated Haxe source, IrCNative.signature, the HL lowering, both Wasm backends and the C runtime exists only as matching integer literals. Adding a scalar kind or renumbering requires finding every literal by hand; a prefix test like startsWith("13") breaks silently if a code 130+ or a differently ordered descriptor is introduced. This is the kind of drift that shows up as target-specific miscompiles (HL right, Wasm wrong).

**Proposal.** Define the codes once as an enum abstract (e.g. compiler.ir.CNativeScalar with Void, I8, U8, ... Pointer, Bytes, Utf8, Bool) with helpers (size, isWide, wasmLetter) and one encoder/decoder for the descriptor string. Use it in HxiHaxeEmitter, WasmCAbi and HlLower, and replace the string-prefix check with a decoded result kind (ideally carried as a field on IrCNative rather than re-parsed from the signature).

### HaxeonCli keeps a second, legacy build path with its own haxeon.json parser for wasm32 and Android

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/tools/HaxeonCli.hx build() is lines 623-848. Host projects go through HaxeonProjectBuild.build (line 693); everything else falls to line 782 onward, which calls loadConfig (1377-1425), a private re-parse of haxeon.json into a ProjectConfig typedef (line 33) that duplicates fields project/PackageManifest.hx:172-181 already parses (entry, sources, sourceRoots, target, defines, outputDir, android), with different rules: loadConfig requires 'entry' and a non-empty 'sources' list (1389, 1406) while PackageManifest treats entry as optional and 'sources' as legacy. That path then shells out to `haxe --run compiler.tools.HaxeonCompiler` with only roots/defines/sources (803-822): no packages, no FFI recipes, no plan. The guard `targetInfo.equals(Target.detectHost()) && Target.parse(project.manifest.target).equals(Target.detectHost())` is repeated 5 times in the function. The file also carries its own JSON field helpers (1446-1476), one of 8+ copies of requiredString/optionalString/stringArray across src/project and src/tools.

**Cost.** A project that builds for host with packages and FFI cannot build for wasm32 through the CLI with the same manifest semantics; a manifest valid for host ('sourceRoots' only) is rejected for wasm ('must list at least one source'). Wasm32/Wasm GC are first-class roadmap targets, and every manifest feature has to be added twice or silently does not apply off-host. The 227-line build() mixes option validation, profiling env set-up, host build, Android packaging and launch.

**Proposal.** Delete loadConfig/ProjectConfig and read everything from project.manifest (already resolved at line 633). Route wasm32 and the Android HLB compile through the structured build (BuildPlanner/HaxeonProjectBuild with a target), keeping only packaging/launch per target in the CLI. Compute `structuredHost` once. Split build() into parse/validate, per-target build, and launch; move Android packaging helpers (939-1068) to a tools.android module beside AndroidBuild/Patch/Reload.

### Run-a-process-and-capture is reimplemented at least seven times, some with the classic pipe deadlock

Architecture; severity medium, effort S, risk low.

**Evidence.** compiler/ffi/ProcessOutputCapture.hx (265 lines, threaded, stderr cap, timeout, three compile-time variants); build/execution/ProcessRunner.capture (209); build/native/HostCommand.output (13-20); tools/HaxeonCli.capture (1021-1028); tools/dev/FormatCommand.execute and quiet (232-262); tools/dev/SuiteRunner.capture (422-428); tools/dev/ToolArtifacts.runForwardingToStderr (138-154); plus tools/HeapInspector.hx:94. HaxeonCli.capture reads stdout to EOF and only then stderr on one thread (1023-1025), and SuiteRunner.capture/FormatCommand.execute/HostCommand.output never drain stderr, so a child that writes more than a pipe buffer to stderr blocks forever. The one robust implementation sits in compiler.ffi, where only the Clang code can reach it.

**Cost.** Each copy has a different failure mode (deadlock on large stderr, no timeout, lost exit status). The FFI package owns generic infrastructure unrelated to FFI, so tools/build code cannot use it without importing compiler.ffi. Self-hosting needs each variant ported separately (check-self-hosting.sh:71 already lists tools.HaxeonCli as blocked on sys.io.Process differences).

**Proposal.** Move ProcessOutputCapture out of compiler.ffi into a neutral package (e.g. build.execution or a small `host` package) as the single capture primitive, and replace the six ad hoc helpers with it (keeping ProcessRunner.run for streamed, environment-controlled execution). That also leaves exactly one place to adapt for the Haxeon stdlib's Process API.

### Sixteen entry points are spread over four locations with no rule, and the FFI tools are not CLI subcommands

Organization; severity low, effort S, risk low.

**Evidence.** grep 'static function main' in src: root (Main, LspMain, EditorServiceMain, FfiImportMain, FfiAuditMain), compiler/tools (HaxeonCompiler, CompilerServer, BootstrapStatus, GenerateValueLaneRuntime), build (HaxeonBuild), tools (HaxeonCli, LiveHost, AndroidBuild, AndroidPatch, AndroidReload, FormatterTokenGuard). src/tools is flat apart from dev/: three Android mains, the live host, CLI subcommand modules (LintCommand, HeapInspector, IdentityPath) and CLI-private helpers (SourceFiles, RuntimeLibrary, DirectoryWatcher, ProfileCapture, WatchRun) share one directory. HaxeonCli dispatches 19 subcommands (lines 132-151) but has none for ffi import/audit; those exist only as scripts/haxeon-ffi-import and scripts/haxeon-ffi-audit wrappers around root-level mains, each with its own hand-written `--x=` parser (FfiImportMain.hx:34-91, FfiAuditMain.hx:25-49) while HaxeonCli uses `--x value` parsers (1070-1300).

**Cost.** Finding 'what binaries does this repo produce' requires a grep; FfiProvider.hx:19-34 needs a Windows-specific branch because the importer is a script rather than a subcommand of an existing tool; option syntax differs between `haxeon` and `haxeon-ffi-import`.

**Proposal.** Group by product: tools/cli (HaxeonCli + its command and helper modules), tools/android, tools/live, tools/dev, and tools/ffi holding the two FFI mains as package-qualified classes. Expose them as `haxeon ffi import|audit` (thin delegation) so FfiProvider can invoke one launcher on every OS. Keep root-level mains to the long-lived services (Main, LspMain, EditorServiceMain).

### Dead or single-valued projection abstractions: unused facade methods, an unused dispatch case, a two-case 'strategy' enum

Overengineering; severity low, effort S, risk low.

**Evidence.** HxiHaxeEmitter.emit (line 378) has zero callers (grep 'HxiHaxeEmitter\.emit\b' matches only emitModules calls). HxiProjection.hx is a 43-line forwarding facade: validateProfile, plan and cNatives each forward one call; `plan` has one caller, a test (tests/compiler/HxiAbiMain.hx:86), and `source` is called only from tests (60+ sites) while production uses `modules` (Compiler.hx:524). NativeDispatch.IndirectPointer (NativeCallPlan.hx:10) is never constructed or matched anywhere in src. ProjectedOutputStrategy (HaxeProjectionModel.hx:83-88) has two cases, NoOutputWrapper and OutputValues, and duplicates the adjacent Bool hasOutputParameters (HxiProjectionPlanner.hx:179); the emitter's NoOutputWrapper branch can only throw (HxiHaxeEmitter.hx:1218). `typedef HxiFunctionAbi = NativeCallPlan` (HxiNativeSignature.hx:12) gives one record two names used interchangeably. sourceRaw selects output with a stringly-typed moduleKind ("all"/"functions"/"types"/"constants", lines 409, 420-422).

**Cost.** Small individually, but they make the planner/emitter boundary look more designed than it is and add branches a reader must rule out; the string moduleKind is compared in six places with no exhaustiveness check.

**Proposal.** Delete HxiHaxeEmitter.emit and NativeDispatch.IndirectPointer; drop ProjectedOutputStrategy in favour of hasOutputParameters; pick one name for NativeCallPlan/HxiFunctionAbi; make moduleKind an enum. Keep HxiProjection only if it becomes the real boundary (taking the composed-interface value proposed above); otherwise let Compiler call the planner/emitter directly and move `source` to a test helper.

### docs/C_HEADER_FFI.md is 891 lines under four headings and opens with the C++ path

Organization; severity low, effort S, risk low.

**Evidence.** grep '^#' docs/C_HEADER_FFI.md finds only: line 1 '# C header FFI import', line 3 '## C++ direct-call import (CXX_ABI_V1)', line 851 '## Native call runtime', line 865 '## UTF-8 strings' (the other '#' lines are C macros in code blocks). Lines 3-850 are one section covering C++ profiles, thunks, ownership, then the C importer's annotations (hxi:handle at 281, hxi:enum at 757, hxi:retained at 828), .hxmap profiles, audit and descriptors. The document describing the default C workflow begins with the opt-in C++ one, and no section documents the HXI grammar or the numeric descriptor codes.

**Cost.** The only reference for the HXI annotations and projection profiles cannot be navigated or linked by topic; contributors binding C libraries for Pragtical must read 280 lines of C++ material first.

**Proposal.** Reorder and add headings: Overview and pipeline (header -> HXI -> projection -> cNative), C import and annotations, HXI format, projection profiles (.hxmap), audit, project manifest recipes, C++ import (profiles, lifetimes, virtual, thunks, views), runtime/descriptor reference. Consider splitting C++ into docs/CXX_HEADER_FFI.md.

### Leave alone

- lib/haxeon-io (2 classes, 249 lines, its own class-path root): looks like an over-separated package, but it was introduced deliberately on 2026-11-09 (commits 76aeba68, b7f3eb6f) as a root both the stock-Haxe build and the Haxeon build compile, registered beside the stdlib by src/compiler/modules/ModuleSourceLoader.hx:40-47 and centralised in src/build/CompilerSources.hx and common.hxml. Leave it; only revisit if no consumer outside src/compiler (currently HlWriter, HlCode, CompilerSession) appears.
- HXI as an intermediate text artifact between the Clang importer and the compiler (HxiWriter -> .hxi file -> HxiParser): looks like a redundant serialise/parse round trip, but it is what lets the compiler consume FFI interfaces with no Clang dependency, lets the audit tool diff ABIs across targets (src/compiler/ffi/HxiAudit.hx), and gives the build a cacheable, checked-in artifact.
- src/compiler/ffi/NativeLayout.hx depending on compiler.types (Type, TypedAst) and being imported by eight typer files: it is the bridge from HXI ABI to typed native layouts, so the two-way reference between ffi and typing here is the intended seam, unlike HxiInterfaceOrder's import of Compiler.
- ProcessOutputCapture's three compile-time variants (#if haxeon / eval / threaded, src/compiler/ffi/ProcessOutputCapture.hx:38-45): odd-looking, but each exists for a real constraint (Haxeon stdlib Process API, eval stalling on two-thread pipe reads). Keep the variants when relocating it.
- ClangFrontend invoking clang more than once per header (AST dump, record layouts, generated layout/vtable probes at src/compiler/ffi/ClangFrontend.hx:59-146): needed because record and vtable layouts are not in the JSON AST; not a duplicated mechanism.
- CxxSubsetValidator + CxxAbiLowerer + CxxModel as a separate C++ model lowered to HXI rather than extending the C importer: the C++ path has genuinely different semantics (mangled symbols, lifetimes, virtual dispatch, thunks) and still ends in ordinary HXI, so the extra model is justified.
- NativeDispatch cases CxxVirtual/CxxConstructor/CxxDestructor in the otherwise language-neutral NativeCallPlan.hx: they have real producers (CxxAbiLowerer.hx:117-128) and consumers (CxxProjection.hx:111, 200, 236, 256); only IndirectPointer is dead.
- src/tools/dev (DevCommand, SuiteRunner, SuiteManifest, ToolArtifacts, FormatCommand) living in the shipped CLI as `haxeon dev`: repo-development tooling inside the user CLI looks misplaced, but it replaces shell scripts with code both compilers build and is isolated in its own subpackage with one dispatch line (HaxeonCli.hx:150).
- FfiProvider.clangTarget (src/build/provider/FfiProvider.hx:54-71) mapping build.Target to Clang triples separately from HxiAbi.forTarget: the two operate on different vocabularies (build targets vs triples recorded in HXI files) and the mapping is small and single-sourced.

## Build, project, editor and LSP

### Three persistent-compiler front doors with separate compiler instances and wire formats

Architecture; severity high, effort L, risk high.

**Evidence.** (a) Build and hot reload: src/build/execution/CompilerClient.hx:45-152 spawns a per-project worker (compiler.tools.CompilerServer, `new CompilerSession()` at src/compiler/tools/CompilerServer.hx:48) and sends length-prefixed JSON carrying CLI argument strings (CompilerClient.hx:126). (b) LSP: src/editor/lsp/LspProtocol.hx:116-117 creates its own in-process `new LanguageService()`; its 40-method switch (LspProtocol.hx:139-188) has no compile/patch method. (c) JSON-lines: src/editor/LanguageServiceProtocol.hx:29-31 creates a third LanguageService with compile/acknowledge/reject/reconnect (lines 62-101); its only consumers are src/EditorServiceMain.hx and tests/tooling/ProtocolMain.hx, and scripts/ has haxeon-lsp but no launcher for it. Hot-reload publication therefore exists twice: RPC acknowledge/reject in (c), and files (.live.json, .live.full, .live.refused via runtime.LiveRefusal and tools.LiveHost) in (a).

**Cost.** An editor session plus `haxeon run --watch --live` types the same project in two processes; the CompilerClient.hx:101-103 comment puts one resident compiler at about 1.5 GB live for an app. Diagnostics and completion come from a different snapshot than the patches, which ROADMAP's "Definition of Pragtical-ready" rules out. Any change to publication or refusal semantics has to be made in both handshakes. Roadmap item B ("shared snapshots") has no single owner to land in.

**Proposal.** Make one per-project service process the owner of the Compiler: extend CompilerServer to host LanguageService queries alongside compile requests. Turn LspProtocol and LanguageServiceProtocol into thin adapters that connect to it, in-process for tests and over the socket otherwise. Keep one publication handshake (acknowledge/reject) and have LiveHost use it instead of the .live.refused file. As a first step, define the worker request and response types in one module imported by both CompilerClient and CompilerServer.

### LSP and build translate a haxeon.json project into compiler inputs independently, and the LSP version is incomplete

Architecture; severity high, effort M, risk medium.

**Evidence.** Build path: src/build/provider/CompilerProvider.hx:24-72 emits --root, --package-root scoping (lines 34-41, from manifest.scopeSourceRoots and unscopedSourceRoots), checked-in FFI interfaces and projections, generated FFI import interfaces and projections under the build layout (lines 49-61), manifest plus extra defines, and haxeon-inline (lines 67-70). Editor path: src/editor/lsp/ProjectWorkspace.hx:399-444 builds its own HaxeProjectConfiguration from roots, value.ffiInterfaces/ffiProjections and manifest.defines plus CompilerDriver.targetDefines. It never reads resolvedPackage.ffiImports, scopeSourceRoots or inlineEnabled (grep: `scopeSourceRoots|package-root` matches only CompilerArguments.hx; ProjectWorkspace does not match). It resolves through ProjectDiscovery.discover, which is `new PackageResolver(new PathSourceAcquirer())` (src/project/ProjectDiscovery.hx:8); PathSourceAcquirer.hx:17-18 throws for Git, Registry and Haxelib sources, whereas the CLI uses ProjectSourceAcquirer plus the lockfile (src/tools/HaxeonCli.hx:1317). The `"host" ? "hl"` target mapping is repeated at CompilerProvider.hx:25, ProjectWorkspace.hx:442 and HaxeonCli.hx:812.

**Cost.** By reading (not executed): a project with a git, registry or haxelib dependency gets no LSP configuration at all, only an entry in `errors`. Projects with generated FFI imports or scoped package roots are typed differently in the editor than in the build, giving false or missing diagnostics. Every new manifest field that affects compilation must be wired in two places, and nothing fails when one is forgotten.

**Proposal.** Add a single function, for example `project.CompilerInputs.of(project, layout)`, that returns roots, package roots, FFI interface and projection paths, defines and target. CompilerProvider renders it to arguments and ProjectWorkspace feeds it to LanguageService.configure. Have the LSP resolve with ProjectSourceAcquirer and the lockfile in a no-network mode instead of PathSourceAcquirer.

### BuildPlan is only half the source of truth; lowering goes back to the project and re-derives identities by string convention

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/build/lowering/PlanLowerer.hx:41-52 iterates project.packages (not plan artifacts) and picks the provider from the manifest. The same "has native code / which provider" decision is also in BuildPlanner.hx:47 and NativeTargetSupport.hx:13-15. BuildPlanner.hx:100-105 writes four `cmake.*` details, one of them JSON-stringified into a string map; `grep 'details.get'` shows no reader, and NativeCMakeProvider re-reads resolvedPackage.manifest.native.cmake. Artifact.details is Map<String,String> with magic keys (source, ffi, language, standard, name, library). Action ids are rebuilt by string in several files: 'ffi-import:'+key at PlanLowerer.hx:37, NativeSourcesProvider.hx (~39) and NativeCMakeProvider.hx (~186); 'native-compile:' in both native providers; WorkspaceBuild.hx:123 finds the compile action with `startsWith(id.key(), "compile-project:")`. FFI thunk compile and link is implemented twice (NativeSourcesProvider.hx:28-90, NativeCMakeProvider.hx:164-208), and the thunk path 'ffi/$name/$name-thunks.cpp' is spelled in both BuildPlanner.hx (~64) and NativeCMakeProvider.hx (~178).

**Cost.** `--plan` and `--explain` print details the build does not use, so the plan can diverge from what executes. Renaming an action id prefix silently breaks dependency wiring in another file. A new artifact kind or provider needs coordinated edits in planner, lowerer and each provider, with only throw-at-runtime checks.

**Proposal.** Give artifacts typed payloads (an enum per kind carrying the manifest data lowering needs) instead of a string map. Have PlanLowerer dispatch per artifact and return ActionIds through the existing artifactActions map; that map should be the only way to find another artifact's action, removing string reconstruction and the prefix match. Extract thunk compile and link into one helper used by both native providers.

### Speculative values and seams in the build model that nothing uses

Overengineering; severity medium, effort S, risk low.

**Evidence.** BuildIntent (src/build/BuildIntent.hx) has 5 values; every caller passes Build (3 src sites, 4 test sites). `intent == Check` (BuildPlanner.hx:124) yields a Diagnostics artifact that PlanLowerer.hx:73-78 rejects with 'No build provider'. ArtifactKind.HashLinkPatch is never constructed. ArtifactKind.Executable is constructed only in tests/tooling/BuildSystemMain.hx:300-301 and imported unused at BuildPlanner.hx:4. TargetLayout.hashLinkPatchPath (TargetLayout.hx:31) and BuildPlanner.module (BuildPlanner.hx:24) have 0 callers. NativeArtifactDemand.None and .Both have 0 uses; .Static is used once, in a test. ExecutionBackend (execution/ExecutionBackend.hx) has 1 implementation, and its factory reads HAXEON_EXECUTOR and accepts only "native"; 3 src sites bypass it with `new Executor` (HaxeonBuild.hx:44 and 214, HaxeonCli.hx:547). project/ProjectManifest.hx is a typedef alias with 0 users. build/native/NativeLibrary.hx is a 13-line holder with one caller, and its name collides with runtime.NativeLibrary.

**Cost.** Readers have to work out which enum cases are live. Switches over ArtifactKind carry dead arms (Artifact.kindName, PlanLowerer default). The backend seam suggests a remote or alternate executor that the fingerprint and cache code is not designed for.

**Proposal.** Delete BuildIntent (or reduce it to what `haxeon check` will need, when it exists), HashLinkPatch, Executable, hashLinkPatchPath, BuildPlanner.module, ProjectManifest, ExecutionBackend with its factory and HAXEON_EXECUTOR, and build.native.NativeLibrary. Collapse NativeArtifactDemand to the Shared/Static cases actually requested. Re-add a case when a provider for it lands.

### Long positional and boolean parameter lists on the build entry points

Architecture; severity medium, effort S, risk low.

**Evidence.** HaxeonProjectBuild.build takes 15 positional parameters, 7 of them Bool (src/build/HaxeonProjectBuild.hx:33-35). Callers look like `build(project, home, output, [], jobs, false, false, false, 0.0, false, false, false, instrument, session)` (src/tools/HaxeonCli.hx:887; also 691 and 761). LoweringContext's constructor has 12 optional positionals (lowering/LoweringContext.hx:35-37), called as `new LoweringContext(environment, null, null, null, home, [], false, true)` (WorkspaceBuild.hx:115) and with 12 arguments at HaxeonProjectBuild.hx:46-47. ExecutionAction has 10, ending in three Bools plus an array (execution/ExecutionAction.hx:33-34), called as `..., true, true, ninja)` and `..., true, false, false, [...]` (NativeCMakeProvider.hx:~155, FfiProvider.hx:51).

**Cost.** Two adjacent Bools swapped (selfHosted/sharedNative/live, or fingerprintDependencies/alwaysRun/jobserverClient) compile cleanly and change caching or live behaviour silently. Each new build flag (instrument, developmentMetadata and nativeCache are recent) grows every call site.

**Proposal.** Replace these with option structs with defaults: a `ProjectBuildOptions` for build(), named fields or a builder for LoweringContext, and an `ActionPolicy` for ExecutionAction's flags. This is a mechanical refactor covered by tests/tooling/BuildSystemMain.hx.

### build and project import each other; workspace manifest and Target live on the wrong side

Architecture; severity medium, effort M, risk low.

**Evidence.** project imports build in 6 places: build.Target in PackageManifest.hx:3, PackageCompatibility.hx:3 and PackageResolver.hx:3; build.execution.ProcessRunner in GitSourceAcquirer.hx:3, HaxelibSourceAcquirer.hx:3 and RegistrySourceAcquirer.hx:3. build imports project in 15 places (BuildPlanner, PlanLowerer, the providers and others), and build/BuildEnvironment.hx:113 stores a project.PackageManifest.InstrumentManifest. build/WorkspaceManifest.hx (111 lines) is a JSON manifest parser placed in build/ while every other manifest parser is in project/. PackageManifest.workspace (PackageManifest.hx:113, resolved in PackageResolver.hx:36-48) is a different "workspace" concept (package members) under the same name. ProcessRunner.capture is also used by build/Target.hx:61, so Target pulls in the execution layer.

**Cost.** Neither package can be compiled, tested or reasoned about alone. The LSP imports project.ProjectDiscovery and so drags in build.execution. Two meanings of "workspace" will confuse users and code once Pragtical becomes a multi-project workspace.

**Proposal.** Move Target, with its OS/arch/ABI enums, and a minimal process-capture helper into a leaf package that both import, so project no longer depends on build. Move WorkspaceManifest to project/ and rename one of the two concepts, for example package `members` versus build `workspace`.

### `runtime` names three unrelated things, and src/runtime mixes host API, C ABI bridge and strays

Organization; severity medium, effort M, risk medium.

**Evidence.** src/runtime/*.hx and stdlib/runtime/*.hx both declare `package runtime`. The self-host compile passes both roots (src/build/HaxeonBuild.hx:152-153, `--root=src --root=stdlib`), so one package is split across two trees. src/compiler/runtime is a third, compiler-side `compiler.runtime`. Inside src/runtime: (1) the live-module host: Runtime.hx (371 lines), LoadedModule, PatchSet, RuntimeDomain, the Plugin types and RuntimeStateEnvelope; (2) a C ABI bridge: NativeLibrary, NativeFunction, NativeType, NativeCallApi and NativeCallError, imported outside the folder only by tests/runtime; (3) ThreadName, imported by build/execution (2 files), compiler/ffi, compiler/tools, editor/lsp, editor/profiler and tools, so a host-runtime package is a dependency of the compiler and the build; (4) LiveRefusal, a file-protocol record imported by src/compiler/tools/CompilerSession.hx:20 and tools/LiveHost.hx:5.

**Cost.** A new file in either runtime folder can shadow or collide with the other when both roots are compiled. "Runtime" in a review or stack trace is ambiguous between the stdlib support code, the embedding API and the compiler's runtime descriptors. The compiler depends on the embedding package for a 40-line record and a thread-name helper.

**Proposal.** Rename src/runtime to a host-specific package such as `haxeon.host`, keeping only the live-module API there. Move the C ABI bridge next to the FFI code or into a `nativecall` subpackage. Move ThreadName to a shared util package and LiveRefusal beside tools.LivePublication, or into the compiler's publication module. Do not let stdlib/runtime and src/runtime share a package name.

### CompilerClient is a 507-line static class with five jobs and an untyped protocol duplicated on the server

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/build/execution/CompilerClient.hx holds worker version fingerprinting (29-43), connect/spawn/request (45-152) including a shell launch string (92-112) and a Windows `start /b` variant (295-318), keepalive pings (160-203), artifact compile with a mutex (234-260), one-shot fallback (266-289), session directory permissions (320-347), LRU and memory-budget retirement that reads /proc (363-440), and stale-file cleanup (460-473). Request shapes are built inline at lines 126, 189 and 494 and read as Dynamic at src/compiler/tools/CompilerServer.hx:79-91. The state file (port, token, pid, idleSeconds) is written at CompilerServer.hx:53-58 and parsed as Dynamic three times in the client (178, 208, 419). Fallback is nested three deep in CompilerProvider.hx:116-121 (worker, then compiled one-shot, then interpreter).

**Cost.** A protocol change such as a new request kind or state field has no compiler-checked contract; a typo degrades to "Compiler session unavailable; using one-shot compilation" (line 149), which hides the error behind a slow build. Retirement policy cannot be tested without spawning workers. The file sits in build/execution although it is the client half of compiler/tools/CompilerServer.

**Proposal.** Split it into WorkerProtocol (typed request, response and state typedefs plus encode/decode, imported by both client and server), WorkerRegistry (state files, markUsed, retirement, stale cleanup; pure enough to unit-test) and WorkerLauncher (platform spawn). Keep CompilerClient.run as a short orchestration over them.

### Two mechanisms for sharing a CMake tree, selected by nested ternaries in one provider

Architecture; severity medium, effort M, risk medium.

**Evidence.** src/build/native/NativeCMakeProvider.hx:28-98 is one `var` statement that computes paths for three modes: per-package tree, workspace-shared tree (`context.sharedNative`, keyed by sharedName(source, target) under TargetLayout.sharedCMakeRoot, deduped by ActionMerge) and NativeCache (`context.nativeCache`, keyed by a SHA of source, target, profile, home and compilers, with a cross-process lock and a publish step). `sharedNative` and `cached` are referenced 16 times in the file. legacyOutput alone is a three-way nested ternary (lines 46-56). WorkspaceBuild.hx:132-140 must know the shared layout through NativeCMakeProvider.sharedOutputDirectory to build library paths. The workspace mode has no lock; the cache mode does.

**Cost.** Each CMake change (RPATH flags at lines 77-81 apply only when cached; instrumented builds opt out of the cache) has to be reasoned about in three modes. Workspace builds and project builds of the same package compile it twice, in different trees. Workspace builds from two worktrees can race where project builds cannot.

**Proposal.** Make the workspace build use NativeCache trees: same key, lock and publish into each project's native directory. Then delete `sharedNative`, sharedCMakeRoot, sharedName, sharedOutputDirectory and the ActionMerge.dedupe call, leaving two modes (cached, or per-package when the cache is off) behind a small `CMakeTree` value computed once.

### LspProtocol is a 1,562-line class that owns every LSP feature and hosts the profiler

Organization; severity medium, effort M, risk low.

**Evidence.** src/editor/lsp/LspProtocol.hx has one 40-case method switch (139-188), about 25 mutable fields including 4 mutexes and 10 state maps for diagnostics, semantic-token snapshots and refresh bookkeeping (78-114), and around 110 functions spanning document sync, push and pull diagnostics, semantic tokens with deltas, hierarchies, formatting, rename and JSON helpers. It also constructs editor.profiler.ProfilerService (line 81) and routes nine `haxeon.profiler.*` executeCommand names to it (345-353, 361-370). src/profiler is imported by nothing in src except editor/profiler/ProfilerService.hx, so the realtime profiler is reachable only through a running language server (extensions/vscode/src/profilerPanel.ts drives it through the LanguageClient). requiredString and requiredInt are re-implemented in LspProtocol.hx:1533-1545, LanguageServiceProtocol.hx:185-197 and ProfilerService.hx:442.

**Cost.** Any LSP feature change touches the file that also holds locking for diagnostics and token caches, so review and merge conflicts concentrate there. Profiling an app requires starting a compiler and language server for the workspace, and a profiler bug can take down the language server process.

**Proposal.** Split by feature into handler classes that receive (service, documents, workspace): LspDiagnostics (push, pull and refresh state), LspSemanticTokens (snapshots), LspNavigation and LspEditing. LspProtocol keeps parse, dispatch and lifecycle. Register the profiler as a separate command provider on the dispatcher; longer term give it its own stdio endpoint so the VS Code panel can run without the language server. Share one JSON-field helper.

### Small mechanisms copied instead of shared: library-path env, JSON field readers, process capture

Organization; severity low, effort S, risk low.

**Evidence.** Runtime library path (PATH / LD_LIBRARY_PATH / DYLD_LIBRARY_PATH = out + hashlink dir + existing) is assembled in 6 src sites: HaxeonBuild.hx:180-188, provider/CompilerProvider.hx:137-152, WorkspaceBuild.hx:117-143, execution/CompilerClient.hx:75-80 and 297-301, and tools/HaxeonCli.hx:1488, plus tests/driver/TestRunner.hx:535; the order differs from scripts/haxeon, which puts the hashlink dir first. JSON field validation in src/project is 17 private static helpers across 7 files (requiredString in PackageLockfile:127, FfiManifest:165, PackageManifest:315, HaxelibSourceAcquirer:123, PackageSourceCodec:53 and RegistryIndex:171, plus optionalString, stringArray, optionalBool and stringMap variants with differing signatures), while build/WorkspaceManifest.hx:73-94 uses unchecked `Reflect.field` typed casts for tags and inputs. Process launching: the ProcessRunner.hx:14 doc says it is "the only build-layer boundary that starts external processes", but there are 12 other launch sites in 5 other build files: BuildEnvironment.hx:93, native/HostCommand.hx:14, JobServer.hx:40 and 44, ArtifactCache.hx:146 and CompilerClient.hx (7 sites: 92, 241, 310, 324, 330 and the worker launches). ProcessRunner.capture, HostCommand.text and ToolchainInfo.isClang are three versions of "run and read stdout".

**Cost.** A fix to library search order, or support for a new platform variable, has to be found in 6 places. Manifest error messages differ per file, and the workspace file accepts wrong types silently. The Windows getenv/putenv hazard documented at ProcessRunner.hx:22-27 is not respected by launch sites that bypass it.

**Proposal.** Add `HashLinkPath.runtimeLibraryEnvironment(home)` returning variable and value, and use it at all 6 sites. Add one `project.JsonFields` reader (required/optional string, bool, array and map, with a path for messages) used by all manifest parsers including WorkspaceManifest. Route short captures through one helper, either HostCommand or ProcessRunner.capture, and correct the doc comment.

### Misplaced and misleadingly named files in build/ and project/

Organization; severity low, effort S, risk low.

**Evidence.** src/build/HaxeonBuild.hx (233 lines) is the repo's own bootstrap/test/doctor driver (it runs `haxe ... driver.TestDriver` and converges bootstrap stages at lines 48-93), yet it sits beside the user-facing project build system while repo tooling lives in src/tools/dev (DevCommand, SuiteRunner, ToolArtifacts). It wraps every command in a one-action ExecutionPlan with a counter-based ActionId (203-219) and has its own recursive .hx collector (157-175), duplicating PackageResolver.collect and CompilerSources. src/project/FfiManifest.hx declares FfiImportManifest and ResolvedFfiImport but no FfiManifest; `class FfiManifest` is declared in src/project/PackageManifest.hx:46, so `project.FfiManifest.X` and `project.PackageManifest.FfiManifest` both exist. project/ProjectDiscovery.hx is documented as a "Compatibility facade" but is the path-only resolver the LSP and 9 test sites actually use.

**Cost.** Newcomers looking for how `haxeon build` works land in HaxeonBuild, which is unrelated. Imports of FfiManifest are easy to get wrong. "Compatibility" comments invite deletion of code that is live.

**Proposal.** Move HaxeonBuild to src/tools/dev (for example dev.BootstrapCommand); this means updating scripts/bootstrap-compiler.sh, scripts/test-driver.sh, SuiteRunner.hx:151 and check-self-hosting.sh:72. Rename project/FfiManifest.hx to FfiImportManifest.hx, or move the nested FfiManifest class and rename it PackageFfiSection. Rename ProjectDiscovery to say what it is (local, offline resolution) and drop the "compatibility" wording.

### Leave alone

- Dual scheduler and process paths behind `#if (target.threaded && !eval)` (src/build/execution/Executor.hx:38-42, executeWaves 46-171 vs executeQueued 177-269; ProcessRunner.hx): the build code also runs under the official Haxe interpreter (`haxe common.hxml --run build.HaxeonBuild` in scripts/bootstrap-compiler.sh, and the interpreted Windows CLI), which has no usable threads. Both paths are needed.
- RuntimeDomain, Plugin, ReloadablePlugin, LoadedPlugin and RuntimeStateEnvelope (src/runtime) have no production caller today (only tests/runtime and tests/tooling; LiveHost does its own reload). They are the reload-domain and state-migration seam that ROADMAP section C and Next items 3-4 depend on, so this is an unfinished seam, not overengineering.
- SourceAcquirer interface with 5 implementations (Path, Git, Haxelib, Registry and the dispatching ProjectSourceAcquirer in src/project): a real seam. Tests inject single acquirers (tests/tooling/BuildSystemMain.hx:1129, 1158) and the LSP deliberately uses the path-only one to avoid network access.
- The LanguageServiceProtocol JSON-lines adapter (src/editor/LanguageServiceProtocol.hx, src/EditorServiceMain.hx) has only a test consumer, but it is the intended Pragtical host channel (it carries compile/acknowledge/reject/reconnect). Keep it until the service unification decides which protocol survives.
- RuntimeProvider's build action has no inputs and `alwaysRun=true` (src/build/provider/RuntimeProvider.hx:31-35), as does the CMake package build step: delegating staleness to CMake/Ninja is deliberate and documented; hashing HashLink's tree would cost more than the incremental build.
- PlanLowerer makes the compile action depend only on FFI interface actions, not on native libraries (src/build/lowering/PlanLowerer.hx:57-67), and CompilerProvider passes fingerprintDependencies=false: intentional, so the Haxe compile overlaps long native builds. Whatever runs the module waits on the whole project instead (WorkspaceBuild.withTests).
- ProcessRunner.environmentValue copying strings under a launch mutex (src/build/execution/ProcessRunner.hx:22-41): looks paranoid, but it guards a real HashLink-on-Windows use-after-free between Sys.getEnv and Sys.putEnv.
- BuildSession pinning the worker version for a whole watch session even if compiler sources change (src/build/BuildSession.hx:37-42, 55-63): intentional, because the running app's patch history belongs to that worker.
- NativeCache.canonical shelling out to `cmake -P haxeon-real-path.cmake` and NativeCompilerCache's CCACHE_BASEDIR/NOHASHDIR/DEPEND handling (src/build/native/NativeCache.hx:47-63, NativeCompilerCache.hx): odd-looking, but each is justified by measured cross-worktree cache reuse and Windows path limits documented in the file headers.
- ProjectWorkspace's own .hxml and haxe.json parsing (src/editor/lsp/ProjectWorkspace.hx:335-394, 445-461): it is the only hxml reader in src, and it is needed so the LSP works on ordinary Haxe projects (Haxe-compat priority) that have no haxeon.json.
- LspMain.escapeControlCharacters and binaryStdio (src/LspMain.hx:58-83): workarounds for upstream Haxe's JSON printer and Windows text-mode stdio. They are required for a correct Content-Length-framed protocol.
- src/profiler is a pure HLDI client with no imports from the rest of src (only profiler.* internally) and is separate from editor/profiler (the LSP-facing service and view model). That layering is correct; only the hosting inside LspProtocol is questionable.

## Native runtime, stdlib and platform

### Haxe-named std types expose non-Haxe APIs (sys.io.Process, FileOutput), blocking self-hosted entry points

Architecture; severity high, effort M, risk medium.

**Fixed during the review by `028ce4fa`.** 

**Evidence.** stdlib/sys/io/Process.hx:8-31 is an `extern abstract Process` with static `run`/`spawn` and `readStdout()`/`readStderr()`; it has no constructor and no stdout/stderr/stdin streams. The repo's own code uses the Haxe API at 15 sites in 11 files under src (e.g. src/build/execution/ProcessRunner.hx:61, src/tools/HaxeonCli.hx:908) and the Haxeon API only under `#if haxeon` (src/compiler/ffi/ProcessOutputCapture.hx:37,113-115). scripts/check-self-hosting.sh (HEAD, entry_gaps list, lines ~69-75) records the consequence: tools.HaxeonCli and build.HaxeonBuild do not build because 'sys.io.Process has its own API, not Haxe's new Process(command, arguments)'; LspMain because 'sys.io.FileOutput is not a haxe.io.Output'; CompilerServer because there is no sys.io.File.append. Haxeon-only types also sit inside Haxe namespaces: stdlib/sys/io/ChildProcess.hx, stdlib/sys/io/AtomicFile.hx, stdlib/haxe/io/StructBufferStorage.hx, stdlib/sys/thread/ThreadState.hx.

**Cost.** Four of the five known self-hosting entry gaps are stdlib API-shape gaps, not language gaps. Every Haxe program that spawns a process (Pragtical plugins, LSP clients) needs `#if haxeon` forks, which is the 'guard the compiled code' pattern the project wants to avoid. Readers cannot tell from the package which sys.io types are Haxe API.

**Proposal.** Make sys.io.Process a class with Haxe's surface (`new(cmd, ?args, ?detached)`, `stdout`/`stderr:haxe.io.Input`, `stdin:haxe.io.Output`, `exitCode(block)`, `getPid`, `kill`, `close`) built on the existing __process_spawn/__child_* primitives, which already stream. Make FileOutput/FileInput extend haxe.io.Output/Input and add File.append. Move the Haxeon-only extras (ChildProcess, AtomicFile, the blocking run/capture helper, StructBufferStorage) to haxeon.io / haxeon.sys, then delete the `#if haxeon` branch in ProcessOutputCapture and cut the entry_gaps list.

### Core language runtime compile-depends on the NativeKit UI submodule, which bootstrap never initializes

Architecture; severity high, effort S, risk low.

**Evidence.** native/runtime.c:65 unconditionally includes runtime/native_trace.c, whose line 5 is `#include <nativekit_trace.h>` (that header includes nativekit.h). CMakeLists.txt:73 adds vendor/nativekit/include to haxeon_runtime. cmake/Bootstrap.cmake:62 initializes only vendor/hashlink, vendor/hashlink-debugger, vendor/utest and vendor/libffi; no script, cmake file or doc runs `submodule update` for vendor/nativekit (grep over scripts, cmake, docs, CMakeLists). vendor/nativekit is 238 MB checked out. android/app/src/main/cpp/CMakeLists.txt:151-154 compiles the same native/runtime.c without that include path. native_trace.c was added 2026-10-26.

**Cost.** The library every compiled program and the compiler itself loads cannot be built from a bootstrap-initialized checkout unless the UI platform kit is also fetched. The dependency points the wrong way (language runtime to UI kit) for 75 lines of profiler glue, and it is one of the reasons the Android host list no longer matches.

**Proposal.** Move native_trace.c out of haxeon_runtime into a NativeKit-side unit (packages/platform or a small haxeon_nativekit_trace hdll loaded with NativeKit), calling the already public hl_prof_span_begin/end from hlprof.h. If it must stay, guard the include with a HAXEON_WITH_NATIVEKIT define set only when the submodule is present. Either way drop vendor/nativekit/include from CMakeLists.txt:73.

### Android host re-lists HashLink sources by hand and has fallen behind the fork (by inspection)

Architecture; severity high, effort M, risk low.

**Evidence.** android/app/src/main/cpp/CMakeLists.txt:91-95 builds libhl from src/gc.c + pcre + src/std/*.c, while vendor/hashlink/CMakeLists.txt:181-187 builds it from gc.c, prof.c, ryu/d2s.c, ryu/f2s.c and std. vendor/hashlink/src/std/buffer.c:24,33 calls d2s_buffered_n/f2s_buffered_n (defined only in src/ryu/d2s.c and f2s.c) and hl_prof_span_begin is defined in src/prof.c:756; neither file is in the Android list (grep for ryu|prof.c|nativekit in the Android CMake and build.gradle returns nothing). The VM and JIT lists at lines 114-146 duplicate the fork's lines 254-290 file by file. Additions the list missed: ryu (2026-09-27), prof.c (2026-10-23), nativekit include (2026-10-26). haxeon_jni.c was last changed 2026-09-10. .github/workflows has no Android job. I did not run the build, so the breakage is inferred from the source lists.

**Cost.** ROADMAP line 3 names Android as a HashLink target with live patching, but every fork change that adds a translation unit silently breaks the Android link, and nothing reports it. The 90 lines of libffi configuration at lines 14-88 are a second place where libffi's source list must track the pinned submodule.

**Proposal.** Have the fork's CMake export the embeddable pieces once (an option such as HL_EMBED_VM that defines static targets libhl and hlvm from its own source variables) and make the Android CMake `add_subdirectory(vendor/hashlink)` and link those targets instead of listing files. Add a compile-and-link-only NDK job to CI. Fix the nativekit include as in the previous finding.

### sys.io.File and sys.FileSystem call into a build-cache recorder that is activated by the program's own argv

Architecture; severity medium, effort S, risk low.

**Evidence.** stdlib/sys/io/File.hx:62-102 (9 call sites) and stdlib/sys/FileSystem.hx:100-142 (10 call sites) call haxeon.build.InputFiles. stdlib/haxeon/build/InputFiles.hx:38-55 decides recording by scanning Sys.args() for `--record-inputs=` on first use, and keeps 9 static fields plus a Mutex (lines 27-36). The module imports haxe.Json, haxe.crypto.Sha256 and sys.thread.Mutex (lines 3-8), so they become dependencies of every program that reads a file. Its doc comment names a specific external consumer ('CadKit's STEP import').

**Cost.** The std file layer depends on a build-tool feature (wrong direction). Any user program started with an argument beginning `--record-inputs=` silently starts hashing everything it reads and writes a file, which stock Haxe would never do. Every exists/read pays the hook and the reachable module graph grows, which matters for incremental compile and for Wasm module size.

**Proposal.** Replace the hard dependency with an observer seam owned by the file layer: one nullable static (for example `haxeon.io.FileObserver.current`) that File/FileSystem test and call. Move InputFiles (244 lines) to the build tooling (src/build or a lib/ package), have it install itself explicitly from the tools that want recording, and parse the flag there instead of inside std.

### vendor/format: 23k lines of vendored Haxe code with no consumer

Overengineering; severity medium, effort S, risk low.

**Check first:** two submodules use a `format` haxelib. 

**Evidence.** vendor/format holds 119 .hx files and 23,136 lines (28 format packages: swf, pdf, abc, mp3 and so on), committed directly (not a submodule) in c2c5b16b on 2026-09-23 together with scripts/inspect-hl-heap.py. That script no longer exists; its last commit, the same day, is 'Expose heap inspection through Haxeon capture CLI'. Grep over the whole repo outside vendor/ finds no `vendor/format`, no `format.hl.`, no `-lib format` and no `import format.`. The only locally modified file is format/hl/Reader.hx (vendor/format/README.haxeon.md); format/hl is 4 files and 932 lines.

**Cost.** 23k lines of unrelated third-party code (SWF, PDF, AGAL readers) ship in the tree, show up in searches and licence audits, and carry a local patch nobody exercises.

**Proposal.** Delete vendor/format. If a HashLink bytecode reader in Haxe is wanted again, keep only format/hl (4 files) beside the tool that uses it, or use the fork's own tools/hldump.c, which already reads the v7 format.

### haxeon_runtime mixes five roles in one library; host_state.c carries 15 primitives with no caller

Architecture; severity medium, effort M, risk medium.

**Evidence.** native/runtime.c:30-67 compiles into one translation unit: the language runtime for compiled programs (arrays.c 704, value_arrays.c 543, strings.c 476, maps.c 224), the embedding/host API used by src/runtime/Runtime.hx (module_runtime.c 191: load/patch/call_*), the libffi bridge (native_call.c 1,582, with `#include <ffi.h>` at runtime.c:23 and CMakeLists.txt:79-130 for static libffi), compiler-service utilities (host_state.c 475) and profiler glue. In host_state.c, 15 of the 16 __host_* primitives (file locks, private directories, loopback port, process identity, stop signals: lines 78-451) have no reference in any .hx or .hxi in the repo; `git log -S` finds each name only in the commits that added them (31f44859, 453305a9, 2026-10-08). Only __host_secure_random_token is used (src/compiler/tools/CompilerServer.hx:31). Domain files also leak: files.c:53-65 defines profile span/counter/frame and thread-name primitives, and files.c:260-266 the GC dumps.

**Cost.** Every program, including the smallest test, links libffi and the patch/host API. The Android and Windows build complexity for libffi is paid by the core runtime. About 430 lines of security-sensitive platform code (ACLs, signals, process termination) are maintained and compiled on three OSes with no in-repo user and no test.

**Proposal.** Either wire host_state.c to its intended consumer (the compiler server) or delete it; if an out-of-tree project uses it, move it to that project's hdll. Keep the unity build, but give it three umbrellas and libraries: haxeon_runtime (language core), haxeon_host (module_runtime plus host utilities, loaded only by embedders and the service) and haxeon_ffi (native_call plus libffi, loaded when a program declares FFI). Move the profile, thread and GC primitives out of files.c into system.c or a profile.c.

### Native binding contract is declared in three styles and hand-expanded per arity

Organization; severity medium, effort M, risk low.

**Evidence.** Implementations (HL_PRIM) live in the domain files but their DEFINE_PRIM signatures are collected in native/runtime/bindings.c (727 lines, 712 entries); regex.c and dir_watch.c instead keep 9 DEFINE_PRIMs inline. stdlib binds 59 natives straight to HashLink's "std" library (hl/Gc.hx 22, Sys.hx 8, Condition.hx 7 and others), while sockets.c:46-69 (11), processes.c:78-80 (3) and maps.c (49) are one-line forwarders to hl_* functions with the same signature. The seven FFI arity families (0..16) are X-macro generated for two (bindings.c:19-37 and 46-64) and written out line by line for the other five in both bindings.c (from line 65) and native_call.c:1460-1582. runtime.c:35-50 carries 15 forward prototypes because arrays.c is included before value_arrays.c.

**Cost.** Adding or changing one native means editing the C body, a signature line about 700 lines away in another file, the stdlib extern and often a `#if wasm` twin; the two C edits can disagree and are only caught when a module that references the native is loaded. Raising the FFI argument limit means editing roughly 170 hand-written lines consistently.

**Proposal.** Put each DEFINE_PRIM directly under its HL_PRIM (the HashLink convention, already used in regex.c and dir_watch.c) and delete bindings.c. Generate all seven arity families and the 12x10 typed-map primitives with one X-macro each. Bind stdlib directly to "std" where the wrapper adds nothing (socket send_char/listen/bind and similar) and keep wrappers only where they adapt (String marshalling, sockets init).

### Every FFI call resolves its target by three strcmp over a spin-locked linked list

Architecture; severity medium, effort M, risk medium.

**Evidence.** native/runtime/native_call.c:764-774: haxeon_native_call_cache_find takes a global atomic_flag spinlock (lines 756-762) and walks a singly linked list comparing library, symbol and signature strings per entry. It is called through haxeon_native_cached_resolve (line 968) from each invoke path (lines 1059, 1244, 1331, 1442). Before the lookup the callers copy or convert the name strings (haxeon_native_string, e.g. lines 1258-1259 for the virtual path). All arguments arrive as vdynamic (the `_DYN` lists in bindings.c:19-37 and 65 onward) and results are boxed with hl_alloc_dynamic (lines 394-411). src/compiler/ir/hl/HlLower.hx:253-255 selects these `native_*_invoke_$arity` primitives for C-native calls.

**Cost.** Call cost grows with the number of distinct native functions the process has touched, and the single spinlock is contended when several threads call natives. This is the path the UI, GPU and platform packages use for NativeKit, so it sits under the editor's frame loop, and boxing every scalar argument adds GC pressure there.

**Proposal.** Resolve once per call site: have lowering allocate a module global per FFI call site that holds the resolved haxeon_native_function abstract, and pass that handle to the invoke primitive, so the string-keyed lookup runs only on first use or after a library reload. As a smaller first step, replace the list with a hash table keyed on the three interned pointers and drop the per-call string copies.

### stdlib/ has become the home for frameworks, tooling and internals next to Haxe std

Organization; severity medium, effort M, risk medium.

**Evidence.** Besides the adapted Haxe std (haxe/, sys/, root), stdlib holds: haxeon/rpc (16 files, 1,154 lines) whose only consumer is tests/programs/rpc-lifecycle.hx (0 references in src or packages); haxeon/build (InputFiles 244, CodeIdentity) and haxeon/test/Shards.hx (154), which are build and test tooling; haxeon/wasm with four committed .wasm binaries, haxeon-host.js and .hxi/.hxmap files inside a source root; and a top-level package `runtime` (14 files: Regex 758, Ryu 338, MemoryFileSystem 263, memory/*) that has the same package name as src/runtime (19 files of host embedding API: Runtime, LoadedModule, PatchSet). check-self-hosting.sh compiles both with `--root=src --root=stdlib`, so the two merge into one package. Seven compiler marker interfaces (Observable, Equatable, Hashable, Diffable, Disposable, Flags, RawRepresentable: 2-4 lines each) sit in the root namespace and are recognized by bare name (e.g. src/compiler/ir/ProgramFacts.hx:206, src/compiler/types/typing/ProgramTyper.hx:739).

**Cost.** The 'matching standard library' a user program can reach has no clear boundary: an unused RPC stack and build tooling are discoverable from every program's source root. `runtime.*` means two unrelated things and reserves a common package name from user code, and generic root names such as Observable and Flags are claimed globally in a compiler meant to take existing Haxe code.

**Proposal.** Keep stdlib/ to Haxe std plus the compiler-coupled Haxeon core (wire codecs, reactive, markers). Move haxeon.rpc to packages/ (or delete it until it has a consumer), haxeon.build and haxeon.test to lib/ beside haxeon-io, and the Wasm host artifacts to a non-source directory such as native/wasm/dist. Rename the stdlib `runtime` package to `haxeon.internal` (updating the hard-coded names such as "runtime.Ryu.format" in WasmLinearRuntime.hx:4393 and WasmGcRepresentation.hx:2015). Consider moving the marker interfaces under `haxeon.` with root typedef aliases.

### utest lives in three places: a stdlib reimplementation, a mandatory submodule used only by a manual probe, and a single-use compiler metadata

Organization; severity low, effort S, risk low.

**Evidence.** stdlib/utest is a 312-line synchronous reimplementation (7 files) used by 3 test programs and 3 tooling mains. vendor/utest (upstream submodule) is referenced only by scripts/probe-utest-upstream.sh and tests/tooling/UtestUpstreamProbeMain.hx; the probe is not in tests/suites.txt and is mentioned only in docs/UTEST_UPSTREAM_COMPATIBILITY.md:11. Yet cmake/Bootstrap.cmake:62 initializes vendor/utest on every bootstrap. The compiler feature `@:discoverMethods` (src/compiler/semantic/SemanticAssembly.hx:1037-1046) has exactly one user, stdlib/utest/Test.hx:4. Haxe itself ships utest as a haxelib, not in std.

**Cost.** A test framework is on every program's std source root, where a real utest on the class path would collide with it. Bootstrap fetches a submodule that no build or automated test needs. None of the repo's own packages use this utest (0 references under packages/), so the subset is validated only by its own three programs.

**Proposal.** Move stdlib/utest to a package (packages/utest or lib/utest) that projects opt into. Drop vendor/utest from Bootstrap.cmake's init list; the probe script already checks for it and prints the init command. Keep @:discoverMethods as the documented stand-in for build macros, and note in the compiler that it is expected to be removed once macros exist.

### stdlib provenance and behaviour docs are stale; runtime symbols still carry the old project name

Organization; severity low, effort S, risk low.

**Evidence.** stdlib/README.md:3-4 calls the compiler 'realtime-haxe' and (the EReg paragraph) says patterns are treated literally. stdlib/UPSTREAM.md:16 says the same for EReg and line 14 says Math is 'limited to isNaN'. In fact stdlib/EReg.hx:44 is 'PCRE2-backed' with a 758-line Wasm engine (stdlib/runtime/Regex.hx) and stdlib/Math.hx is 179 lines. UPSTREAM.md:23 records a Printer.hx workaround 'which the EReg subset does not support', which is now obsolete. Three files with Haxe Foundation headers are missing from the ledger: haxe/Json.hx, haxe/io/BytesBuffer.hx, haxe/io/Encoding.hx (22 such files, 26 ledger rows). In C, HL_NAME is `realtime_` (native/runtime.c:4; 1,686 `realtime_` identifiers under native/) while native_call.c uses `haxeon_native_` (445) and the library is `haxeon_runtime`.

**Cost.** UPSTREAM.md is the licence-provenance record the README says must be kept; it now understates what was imported and misdescribes behaviour, so a reader checking Haxe parity gets wrong answers. Two symbol prefixes for one library make grep-based navigation and crash symbolization inconsistent.

**Proposal.** Regenerate the UPSTREAM.md rows from the files that carry the Haxe Foundation header (a small check script can fail when a headered file has no row), fix the EReg and Math descriptions, and restore the upstream regex in haxe/xml/Printer.hx. Rename the internal `realtime_` C helpers to `haxeon_` in one mechanical pass; the exported primitive prefix can change at the next bootstrap refresh, since the compiler and runtime are rebuilt together.

### Leave alone

- native/runtime.c as a single translation unit that #includes runtime/*.c: deliberate (comment at native/runtime.c:25-27), lets private static helpers be shared without a header and keeps one HDLL build command. Split it into more umbrellas if needed, not into per-file objects.
- native/runtime/value_lane_policy.h (814 lines of goto-style C): generated from compiler.ir.IrValueLaneRuntime by src/compiler/runtime/ValueLaneNativeSource.hx so HashLink and Wasm share one array-lane policy; tests/compiler/ValueLaneRuntimeMain.hx:14 fails when it is out of date. Do not hand-edit or 'clean up'.
- native/shared/sha256.h included by both native/runtime/sha256.c and native/wasm/crypto/sha256.c: a header-only implementation is the right way to share one algorithm between the HL and Wasm C runtimes.
- Committed .wasm runtimes in stdlib/haxeon/wasm (four files, 1.5-7 KB): they let Wasm builds work without clang, and scripts/build-wasm-runtime.sh --check verifies them against native/wasm sources. Their location is debatable (see the stdlib finding); committing them is justified.
- stdlib/runtime/Regex.hx (758 lines) alongside PCRE2 on HashLink, and stdlib/runtime/Ryu*.hx alongside the fork's C Ryu: Wasm has no PCRE2 or C runtime; the Regex engine documents its subset and throws at compile time on unsupported syntax rather than matching wrongly.
- The per-file `#if wasm` / `#if !wasm` split in stdlib (87 sites in 41 files) instead of per-target directories as in Haxe std: at this size one file per API with two bodies keeps the HL and Wasm signatures side by side; revisit only if a third target family appears.
- bootstrap/compiler.hl checked in (18.5 MB; 66 revisions costing about 108 MB packed out of a 1.1 GB .git): required so ordinary development and self-hosting need no official Haxe (docs/DEVELOPMENT.md:86). Keep it, but refresh sparingly since each refresh adds about 1.6 MB of history.
- The large HashLink fork (vendor/hashlink, 390 commits and about 29.5k inserted lines over upstream across 95 files): live patching, the AArch64 JIT, the non-moving type arena and the profiler are the product, and ROADMAP assigns them to the fork. The native runtime reaching into fork internals (struct _ereg, hl_socket, hl_runtime_*) is the intended boundary.
- vendor/libffi as a forked submodule built from source on Android and statically on Windows: the NDK ships no libffi and the fork carries a frame-record fix (6b714c93) the profiler needs.
- embed/ containing only haxeon.json and a README: it is a package manifest that re-exports src/compiler and src/runtime to host applications, not a missing implementation.
- stdlib/hl/{Abstract,Bytes,Gc}.hx as project-owned ABI façades rather than copies of Haxe's hl package: the compiler uses a smaller runtime ABI than official Haxe/HL (stdlib/README.md).
- lib/haxeon-io living outside stdlib: it must be on the class path of both the stock-Haxe build and the Haxeon build (common.hxml:3), which stdlib cannot be.

## `packages/ui`

### UiContext and BuildContext are god objects; the custom-paint cache is 12 parallel maps

Architecture; severity high, effort L, risk medium.

**Evidence.** haxe/haxeon/ui/core/UiContext.hx is 1,852 lines with 81 functions. submitFrame (starts line 480) is about 416 lines and render (943-1118) about 181. Lines 126-137 declare 12 parallel Map<Int,...> fields keyed by node id (customCanvases, customLists, customGeometries, customPaintKeys, customContentRevisions, customListHasCommands, customPaintBound, and five customComposite* maps); they are referenced 100 times and removed one by one at 1084-1099. 93 lines in the file are timing, allocation-probe, metrics or diagnosticStage bookkeeping, 44 of them inside submitFrame. The class also owns retention verification (330-440), accessibility bridge, window decorations, cursor, hit testing and input entry points. haxe/haxeon/ui/core/BuildContext.hx is 1,626 lines with 127 functions and holds style resolution, key scopes, selfUpdating builds (97-108), patches, retained edits (913-959), render scopes (113-119), dependency tracking (1382-1391) and command context.

**Cost.** Every frame-pipeline change touches a 416-line function where control flow is interleaved with probes. A custom-paint node costs up to 12 map lookups per frame, and a missed remove in one map leaves a stale binding. The two classes cannot be tested in isolation, which is why FrameworkSmoke reaches in with @:access.

**Proposal.** Extract a CustomPaintCache with one record object per node id (canvas, list, geometry, key, revision, bound flags, composite sub-record) in a single Map<Int, PaintEntry>. Move verifyRetention, fingerprints and checkUnannouncedEdits to a RetentionVerifier. Move timing and allocation bookkeeping to a FrameMetricsRecorder with begin/phase/end calls. Split submitFrame into named phases (decide reuse/patch, build, diff, native layout, collect). In BuildContext, separate identity and key scopes from the update scheduler.

### Two component models coexist; the new one is used by only two library widgets

Architecture; severity high, effort L, risk medium.

**Evidence.** Old mechanisms still live in the library: selfUpdating( in 8 widgets (TextField, PropertyEditor, Radio, Slider, ProgressBar, BinaryControl, Tabs, SelectionPopup); willEditRetained( at 13 sites in 5 files (ScrollView, Popup, Tooltip, MiddleEllipsisText, BuildContext); requestPatch( in 6 files; context.state( at 48 sites in 18 files; hoverRebuilds in 3 files; BuiltNode at core/RenderNode.hx:1105; SelfUpdatingBuild at core/BuildContext.hx:1481. The new model (core/RenderScope.hx, component/ScopeView.hx, BuildContext.mountComponent at line 1104) is implemented only by Button.hx:30, IconButton.hx:20 and TrackedScope. TrackedScope has 0 library users and 36 test sites. docs/adr/0002-reactive-ui-model.md is 1,702 lines, and its mapping table (292-308) says the old mechanisms are to be deleted after the remaining callers are ported. tests/haxeon carries ScopeLegacyCacheLifetimeMain and ScopeLegacyReplacementMain to cover the interaction of the two.

**Cost.** Core code must keep both models correct, and their interaction (ordering of announced edits, patches and scope updates) is where the ADR says recent work is being spent. New widgets have no single pattern to copy. The 345 UI commits since mid-October are largely this migration.

**Proposal.** Treat the migration as a bounded task with an explicit port list: the 8 selfUpdating widgets, the 4 willEditRetained widgets, then the context.state callers. Delete each old mechanism in the same commit as its last caller. If the migration is to be paused for compiler work, record that in the ADR and stop adding scope features until the port resumes, so the dual state does not grow.

### api.cpp is a 5,486-line translation unit with two largely duplicated frame render paths

Architecture; severity high, effort M, risk medium.

**Evidence.** src/api.cpp is 275 KB. Exported functions by family: text 23 (lines 3085-3497), layout 21 (2147-3040, including hit testing from 2399 and the mutation code from 2602), renderer 11, display list 5, font 4, image 3. It is not only an ABI shim: renderer_render_frame_impl spans 4017-4542 (525 lines) and nkui_layout_session_render_frame spans 4591-5470 (880 lines). After normalising whitespace and dropping short lines, 177 of the 316 distinct lines of the first also appear verbatim in the second (56%): path, image, glyph and surface resolution, PreparedPath/PreparedTexture creation, RenderSubmission, stats accumulation. Five global handle tables with separate mutexes sit at 478-487.

**Cost.** A fix to resource resolution, glyph binding or sealing has to be made twice, and the display-list path is exercised only by Showcase.hx overlay, tests/haxeon/Transaction.hx and the C++ smokes, so it can drift unnoticed. Any edit recompiles 275 KB. The incremental render-compile work planned in ARCHITECTURE_NOTES lands in the largest function in the package.

**Proposal.** Split api.cpp by family into api_resources.cpp (handle tables), api_text.cpp, api_layout_session.cpp (with hit testing in its own file) and api_renderer.cpp. Extract the shared frame frontend (command resource resolution, path/texture preparation, glyph binding, seal, submit) into one function in src/render/ that takes a plan source, and have both entry points call it.

### Package consumes about a quarter of repo activity but is absent from the roadmap; app-level kits have no consumer here

Organization; severity high, effort M, risk medium.

**Evidence.** git log --since=2026-10-15: 345 of 1,294 commits touch packages/ui. ROADMAP.md and docs/ARCHITECTURE.md contain no mention of the UI package; the roadmap goal is the Pragtical conversion. ADR 0002 (UI) is 1,702 of 2,705 ADR lines. The package brings 7 submodules (.gitmodules), two of them forks (clay exosuit-paragraph-layout, nanovg nativekit-path-builder), and its own CI job (.github/workflows/nativekit-packages.yml:21-40). Application kits with no importer outside the library and tests: docking 983 + widgets/docking 1,357; properties 1,197 + widgets/properties 849; settings 892 + widgets/settings 775; plotting 231 + 177; widgets/sidebar 315; lab 476 — about 7.25k lines. The showcase imports none of them. The only other in-repo consumer of haxeon-ui is examples/audio-lab/haxeon.json:15. The root compiler tests do depend on it: tests/compiler/FlagsMain.hx:21,47-50, tests/wasm/test-wasm-parity.sh:258,426,1196, tests/integration/test-gc-incremental.sh:86, tests/integration/test-nativekit-cxx-profile.sh:22-138.

**Cost.** UI work, and the language features it requests (docs/UI_LANGUAGE_FEATURES.md, struct and `implements Hashable/Observable`), compete directly with the Haxe-parity, incremental and self-hosting gates without being weighed in the roadmap. Compiler tests break when UI internals move. The app kits add about 7k lines of surface to migrate in the ADR 0002 port with no product in this repo using them.

**Proposal.** Decide and write down the package's role. Recommended: keep the engine (native, bindings, core, style, base widgets) in-repo as the large Haxeon dogfood and benchmark corpus, and add a ROADMAP section stating what UI work is allowed before the Pragtical gates. Move the application kits (docking, properties, settings, plotting, sidebar, lab) to a separate package or to the application repo that uses them. Replace the root tests' reach into packages/ui paths with small fixtures under tests/, or declare those files a stable test corpus.

### core depends upward on debug, widgets, component and editing

Architecture; severity medium, effort M, risk low.

**Evidence.** Real upward uses: core/UiContext.hx:5,34-41 imports 8 debug types (RenderCost, AccessibilityAudit, AllocationProbe, UiFrameMetrics, UiInspector, UiNodeSnapshot, UiStyleInvalidationMetrics); core/RenderNode.hx:7 imports debug.RenderCost; core/RenderScope.hx:4 and BuildContext.hx:1104,1224 use component.ScopeView; core/CommandRegistry.hx:5-6,302,313 and core/CommandContext.hx:3,8 use editing.EditHistory and EditorDocument; core/FrameworkErrorView.hx:8-10 uses widgets.KeyedView, layout.Column and text.Text; core/TextInputBridge.hx:12 uses widgets.text.TextInputWindow; semantics/Semantics.hx:3,50,68 uses widgets.text.Utf8Text. In addition, about 9 imports of widget modules have no reference to the bare type name in the file and appear dead: widgets.text.Text in core/RenderNode.hx:18, core/UiContext.hx:8, core/TextStyleOverride.hx:9, core/TextInputBridge.hx:9, theme/TextRoleStyle.hx:3, component/BoundText.hx:10; widgets.layout.Padding in style/StyleValue.hx:3 and style/StyleResolver.hx:3; widgets.controls.Button in theme/Theme.hx:5 (the only match is `case Button:` at 489, which looks like TextRole.Button).

**Cost.** There is no acyclic layer order, so core cannot be compiled or tested without widgets and debug. An edit to Text.hx or Button.hx becomes a dependency of RenderNode, UiContext, Theme and the style resolver, which widens invalidation for incremental builds and hot reload of a UI app — the capability the repo is built to demonstrate.

**Proposal.** Delete the dead imports. Move ScopeView into core (it is the core's mount contract). Move Utf8Text and TextInputWindow to a base text package below core, or into core. Have installHistoryCommands live in editing (taking a CommandRegistry) instead of CommandRegistry importing editing. Move FrameworkErrorView to widgets and inject it into core as a factory. Keep the metrics value types core needs in core and leave the inspector and audit in debug behind a hook.

### FrameworkSmoke.hx is a 7,457-line test with a 3,795-line run() function

Organization; severity medium, effort M, risk low.

**Evidence.** tests/haxeon/FrameworkSmoke.hx has 7,457 lines, 258 imports, 111 functions and 11 classes. run() starts at line 797 and is about 3,795 lines long, returning a numeric check id ('FAIL: FrameworkSmoke check N' at line 793). The next largest are commandHistoryValid (501 lines) and dockWorkspaceValid (447). 67 commits touch the file. It is the single entry point of the CI job (tools/test-haxeon-framework.sh:39,53).

**Cost.** A failure is identified by a number in a 3.8k-line function. Every UI change recompiles and reruns everything. One function shares locals across unrelated subsystems, so tests are order-dependent. It is also the largest single function the compiler has to type and lower in this package, which skews compile-time measurements.

**Proposal.** Split by subsystem (typography/style, events/focus, commands/history, docking, scroll, semantics, sidebar, text input) into separate entry points using the tests/<name>/haxeon.json pattern that 18 directories already follow. Keep a thin aggregate runner for CI.

### Three test harness styles; 18 scripts hand-assemble compiler command lines

Organization; severity medium, effort M, risk low.

**Evidence.** tools/ has 50 files, 28 of them test-*.sh. 18 scripts (17 test and benchmark scripts plus showcase.sh) pass --ffi-interface/--root lists by hand (e.g. tools/test-idle-reuse-parity.sh, test-component-model.sh with 12 --ffi-interface occurrences, test-value-snapshot-parity.sh), each repeating the platform/net/ui .hxi selection for hl versus wasm and, in several, the same inline memory.json contract. 27 scripts set LD_LIBRARY_PATH themselves. Project-based scripts are copies: test-tree-hover.sh, test-tree-selection.sh, test-key-chords.sh and test-tooltip-content.sh are identical after substituting the project name, as are test-activation.sh and test-search-picker.sh. tests/ mixes 20 top-level C++ files, 61 flat files in tests/haxeon (45 *Main fixtures), 18 haxeon.json project directories and 127 value-type fixtures.

**Cost.** Adding a source root or FFI interface to the package (as happened with editor and platform) means editing about 18 scripts. The scripts bypass haxeon.json, so the package's own project file is not what the tests exercise. Only test-haxeon-framework.sh runs in CI, so the rest decay silently.

**Proposal.** Add one tools/run-project.sh <test-name> to replace the 6+ identical scripts. Add one sourced helper (or a `haxeon build --project` target-matrix option) that yields the roots, FFI flags and memory contract for hl, wasm32 and wasm-gc, and have the parity scripts call it. Group tests/haxeon fixtures into subfolders by area (scope, retained, allocations).

### Feature code is split inconsistently between model packages and widgets/, with name collisions and forwarding shims

Organization; severity medium, effort M, risk low.

**Evidence.** Parallel folders: docking/ (13 files) and widgets/docking/ (6); properties/ (19) and widgets/properties/ (2); settings/ (7) and widgets/settings/ (2); plotting/ (4) and widgets/plotting/ (1). The split is not model versus view: properties/StructuredPropertyEditor.hx:6-12 imports Button, Checkbox, Column, Row, Text and TextField; widgets/sidebar/ holds SidebarModel next to SidebarHost. Two unrelated classes are named EditTransaction: editing/EditTransaction.hx (61 lines, undo grouping) and widgets/text/EditTransaction.hx (49 lines, a text mutation). widgets/text has 6 compatibility files that only forward to haxeon.editor: CodepointOffset, GraphemePosition, TextRange, Utf16Offset, Utf8Offset (4-line typedefs) and TextOffsetMap (an 11-line subclass). Commands live in core/ (Command, CommandRegistry, CommandContext, CommandParameters, CommandResult, Shortcut) while their widgets are in widgets/commands/.

**Cost.** Finding the code for one feature means looking in two trees, and the top-level folder does not tell you whether a package is headless. An import of EditTransaction resolves differently by package. The alias files hide that the types belong to packages/editor and add 6 modules to every build.

**Proposal.** Use one folder per feature (docking/, properties/, settings/, plotting/, sidebar/, commands/) containing both model and view, and keep widgets/ for generic controls. Rename widgets/text/EditTransaction to TextEditTransaction. Delete the 6 alias files and import haxeon.editor directly; no consumer outside this package exists in the repo.

### haxeon.ui.lab (ComponentLab) has no users; the showcase implements its own component explorer

Overengineering; severity low, effort S, risk low.

**Evidence.** haxe/haxeon/ui/lab/ has 3 files and 476 lines (ComponentLab.hx 430, ComponentStory, ComponentStoryRegistry). A word grep for ComponentLab, ComponentStory and ComponentStoryRegistry across the repo (hx, sh, txt, json) finds no reference outside the lab folder. README.md:61-69 advertises it as the reusable component browser shared by desktop hosts and screenshot runners. The showcase instead has examples/ui_showcase/UiExplorer.hx (824 lines), ExplorerCatalog.hx, ExplorerPage.hx, shell/CatalogSidebar.hx and testing/ExplorerVisualCases.hx, which do the same job.

**Cost.** 476 lines of widget-composing code that must be carried through the ADR 0002 port and kept compiling, with no test, and a README that points readers at an unused path.

**Proposal.** Either delete haxeon.ui.lab and the README section, or rebase the showcase explorer and its visual cases on ComponentStoryRegistry so there is one catalog definition. With no in-repo consumer, deletion is the cheaper choice.

### DesktopUiHost.open is one 650-line function built from closures over about 30 locals

Architecture; severity low, effort M, risk medium.

**Evidence.** haxe/haxeon/ui/host/DesktopUiHost.hx is 803 lines. open() runs from line 35 to about 684 and declares, as captured locals (40-73), the window, surface, event pump, three subscriptions, record path, fonts, runtime, session, event and frame histories, allocation census flag, loop timing struct, event and frame-request count maps, capture state, frame GC scheduler, profiler frame flag and scripted-input state, then defines the step and finish closures (626). The remaining static functions (684-803) are diagnostics writers. BrowserUiHost.hx is 333 lines and UiHostRuntime.hx (262) holds the shared part.

**Cost.** Window lifecycle, diagnostics recording, scripted input, profiling and GC scheduling cannot be changed or tested separately. Every captured local is a closure-environment field, so the host's hottest loop runs through captured variables. A large closure-heavy function is also the weakest shape for function-level live patching.

**Proposal.** Turn the locals into fields of a DesktopUiHostSession implementation class with methods (pump events, frame, finish), and move event/frame recording and scripted input into two small collaborator classes owned by it. UiHostRuntime stays as the part shared with the browser host.

### Reference docs are mixed with measurement logs; README sections do not match their content

Organization; severity low, effort S, risk low.

**Evidence.** docs/ is 5,530 lines. docs/VALUE_TYPES.md is 2,676 lines (183 KB, 72 headings) and opens with measurement corrections; RETAINED_SUBTREES.md is 756 lines; graphics-implementation-plan.md is 632. README.md is 539 lines with 10 headings; the '## Component Lab' section runs from line 61 to 248 and mostly documents the Clay bridge, the layout transaction format, measurement callbacks, grow weights and wrapping. docs/ARCHITECTURE_NOTES.md 'Next steps' is numbered 1, 2, 4 and refers to a 'current Codex session'.

**Cost.** There is no short current description of the layering for a new contributor or agent. The authoritative facts (transaction format, which mechanisms are legacy) are buried in dated logs, which makes mistakes like using a legacy mechanism in a new widget more likely.

**Proposal.** Reduce README to package integration plus a layer map with links. Move the layout bridge, custom paint and virtualization text into docs/LAYOUT.md and docs/RENDERING.md. Move dated measurement logs (VALUE_TYPES, RENDER_COST, LAYOUT_COST, text-editor-performance) into docs/history/, as the root docs/ already does.

### Leave alone

- bindings/nativekit-ui.hxi and bindings/nativekit-ui-wasm.hxi (2,125 lines each, differing in 22 lines): generated per ABI (portable-abi64 vs abi32) from bindings/nativekit_ui_import.h and checked by tools/check-hxi.sh and tools/update-haxeon-wasm-hxi.sh. Not hand duplication.
- tests/value-types/ (127 files, 757 lines): one tiny fixture per accepted or rejected value conversion (-raw-int, -to-string, ...), driven by tools/test-value-snapshot-parity.sh. The file count is the test matrix.
- Two source roots feeding one namespace (haxeon.json sourceRoots 'haxe' and 'bindings/haxe'): bindings/haxe/haxeon/ui holds the flat typed wrappers over the C ABI (Canvas, LayoutSession, Renderer), haxe/haxeon/ui/** the framework. The boundary is clean; only 43 framework imports touch nativekit.ffi.
- C symbols, library and CMake targets keep the nkui_/NativeKit names while the Haxe package is haxeon.ui: documented in packages/README.md and README.md:13-17 as a deliberate ABI-stability choice.
- Global handle tables with per-family mutexes in src/api.cpp:478-487: the normal implementation of opaque handles behind a C ABI. Split the file, but keep the tables.
- nkui_showcase_cube_* in src/api.cpp:1932-1946 and src/render/cube_surface_producer.cpp: compiled only under NKUI_ENABLE_SHOWCASE_PRODUCER, which CMakeLists.txt:479-481 sets only with NK_BUILD_EXAMPLES. It does not ship in the library.
- LayoutTransaction encode/decode bridge (bindings/haxe/haxeon/ui/LayoutTransaction.hx, LayoutSession.hx): ADR 0002 stage 2 measured and rejected the shared native node store, so the incremental transaction bridge is the chosen design.
- UiContext.verifyRetention / HAXEON_UI_VERIFY_RETENTION (core/UiContext.hx:199, 330-440): rebuilding from scratch and comparing is the safety net that makes retention and the ongoing migration safe. Move it out of UiContext, but do not remove it.
- Widget machinery is already shared and should not be merged further: Checkbox.hx and Toggle.hx are 12 lines over BinaryControl; Select and ComboBox share SelectionPopup; ListView, TreeView, VirtualGrid and SearchPicker share VirtualList / VirtualExtentIndex / VirtualViewport.
- examples/ui_c_api/showcase.cpp (1,151 lines in one translation unit): deliberately low-level single-file demonstration of the full C ABI lifecycle (examples/ui_c_api/README.md).
- Vendored clay and nanovg forks as private submodules: Clay types are kept out of the public headers (layout facade), and the forks carry small kernel fixes described in README.md:71-79.
- Static mutable state on the Haxe side is limited to identity counters and opt-in diagnostics (style/StyleSheet.hx:8, style/StyleProperty.hx:41, debug/RenderCost.hx:6-9). There is no global UI singleton; everything hangs off UiContext.

## Other packages

### check-hxi.sh regenerates the checked-in binding in place, so test runs hide ABI drift

Architecture; severity high, effort S, risk low.

**Evidence.** packages/credentials/tools/check-hxi.sh:8,25,28, packages/filesystem/tools/check-hxi.sh:8,28, packages/gpu/tools/check-hxi.sh:9,27,29, packages/audio/tools/check-hxi.sh:8,27,29 and packages/animation/native/tools/check-hxi.sh:6,18,21 all default --output to the tracked bindings/*.hxi and print 'check-hxi: wrote'. packages/audio/tools/test-haxeon.sh:11 (the CI 'audio' job, .github/workflows/nativekit-packages.yml:55) and packages/gpu/tools/test-haxeon.sh:14 call it with no argument. The platform scripts do it properly: packages/platform/tools/update-haxeon-hxi.sh:12-26 has a --check mode that writes to a temp file and cmp's. packages/platform/tools/test-haxe-bindings.sh:22-41 also cmp's the gpu abi64 binding, but generates the gpu abi32 binding (lines 43-59) and compares it to nothing.

**Cost.** For audio, a stale nativekit-audio.hxi passes CI: the test overwrites it and then compiles against the fresh copy, so drift between vendor/nativekit headers and the committed binding is never reported. Locally the script dirties the worktree as a side effect of running tests. Two naming conventions (check-hxi.sh writes; update-*-hxi.sh --check checks) mean a reader cannot tell which is safe.

**Proposal.** Give every binding one script with the platform contract: `update-hxi.sh [--check]`, where --check writes to mktemp and diffs. Have test scripts and CI call it with --check. Remove or rename the writing check-hxi.sh. Either check in a gpu -wasm.hxi and compare it, or drop the uncompared abi32 generation.

### gpu and platform tests bypass haxeon.json and hand-list source files

Architecture; severity high, effort M, risk medium.

**Evidence.** packages/gpu/tools/test-haxeon.sh:30-72 invokes `.tools/haxe/haxe common.hxml --run compiler.tools.HaxeonCompiler` with 23 gpu files and 17 platform files listed by hand, plus repeated --ffi-interface/--ffi-projection flags. packages/platform/tools/test-haxeon.sh:73-113 does the same, listing 25 of platform's 52 source files. packages/audio/tools/test-haxeon.sh:15-28 uses `find` instead and ignores its own packages/audio/tests/haxeon.json. Neither packages/gpu/tests nor packages/platform/tests has a haxeon.json. By contrast credentials, filesystem, editor, agentkit and animation run with `./scripts/haxeon run --project .../tests/haxeon.json` (packages/credentials/README.md:14). 4 in-scope scripts use the raw HaxeonCompiler entry (9 including ui).

**Cost.** The manifest (dependencies, ffi.interfaces, native.cmake) is the product's packaging story, but the two foundation packages are never built through it in tests. Manifest regressions in platform/gpu (for example nativekit-vulkan.hxi being absent from packages/platform/haxeon.json's ffi list while the script passes it at line 85) go unnoticed. Adding a source file means editing shell lists in several scripts. The compile runs through the stock-Haxe interpreter path, not the self-hosted or incremental compiler the roadmap cares about.

**Proposal.** Add packages/platform/tests/haxeon.json and packages/gpu/tests/haxeon.json that depend on the package manifests. Reduce each test-haxeon.sh to a native build plus `scripts/haxeon run --project` (keep the exit-code-42 check). Make audio's script use its existing tests/haxeon.json. Declare the vulkan interface in the platform manifest, or split it into an optional manifest.

### Six of nine packages have tests that nothing runs

Organization; severity high, effort S, risk low.

**Evidence.** .github/workflows/nativekit-packages.yml has three jobs: platform test-haxe-bindings.sh (line 19, covers platform and gpu), the ui framework test (line 42) and audio (line 55). .github/workflows/ci.yml and scripts/ contain no reference to packages/ (grep is empty). Unreferenced test projects: packages/agentkit/tests (410 lines), packages/agentkit-nativekit/tests (a 9-line compile check whose comment says the live test is in 'exosuit'), packages/animation/tests, packages/credentials/tests, packages/editor/tests (DocCheck.hx, 125 lines), packages/filesystem/tests.

**Cost.** These packages are compiled only by hand, yet they exercise exactly the semantics the roadmap is still changing (Observable, FFI projections, Int64, haxe.Json/Reflect in agentkit's JsonObject). A compiler change can break them silently. editor is covered only indirectly through ui. The filesystem and credentials FFI projections (@out_buffer/@inout shapes) have no regression gate at all.

**Proposal.** Add one CI job (or a scripts/test-packages.sh) that loops over packages/*/tests/haxeon.json and runs `scripts/haxeon build`. Run the headless ones (agentkit, editor; filesystem too, since it only needs its small native module) and build-only those that need devices or secrets. This depends on the manifest-based tests from the previous finding for platform and gpu.

### Base packages grant @:allow to upper-layer, example-app and out-of-repo classes

Architecture; severity medium, effort M, risk medium.

**Evidence.** packages/platform/src/haxeon/platform/event/EventPump.hx:19-20 and 66-67: `@:allow(ShowcaseDesktop)` and `@:allow(ShowcaseWeb)`, which are example apps at packages/ui/examples/ui_showcase/. packages/platform/src/haxeon/platform/GraphicsImageRef.hx:31: `@:allow(haxeon.gpu.Image, haxeon.gpu.RenderTarget, nativekit.scene.SceneRenderer)`; no `class RenderTarget` exists in packages/gpu, and nativekit.scene lives in the external Materia repo. GraphicsImageRef.hx:41 allows nativekit.scene.SceneRenderer again; line 69 allows haxeon.ui.GraphicsSurface. packages/editor/src/haxeon/editor/TextDocument.hx:7: `@:allow(haxeon.ui.widgets.text.TextEditorState)`, although packages/editor/README.md:3-5 states the package has no UI dependency.

**Cost.** The lowest layers encode knowledge of their consumers, including one class that does not exist and one in another repository. Any new consumer (a Pragtical view, a second renderer) must edit platform or editor to get access. The stated independence is true for imports but not for the API contract. Stale names are not diagnosed, so the list rots.

**Proposal.** Replace the friend lists with explicit, documented low-level entry points: for example a `haxeon.platform.internal`/`interop` module exposing `GraphicsImageRef.fromBorrowedHandle`/`nativeHandle` and an `EventPump.createDetached()` for hosts that own their loop, and a public `TextDocument.storage()` accessor in an `internal` subpackage. Delete the RenderTarget and Showcase* entries.

### Three native-provisioning conventions and three test layouts across nine packages

Organization; severity medium, effort M, risk low.

**Evidence.** Native library: (a) `native.cmake` inside the package manifest with a 4-line native/CMakeLists.txt: packages/credentials/haxeon.json:20-32, packages/filesystem/haxeon.json:20-32; (b) a separate provider package: packages/audio/native/haxeon.json (source '..', builds all of NativeKit via packages/audio/CMakeLists.txt), packages/animation/native/haxeon.json; (c) none: packages/platform/haxeon.json and packages/gpu/haxeon.json declare FFI but no native build, and scripts cmake vendor/nativekit by hand (packages/platform/tools/test-haxeon.sh:54-58, packages/gpu/tools/test-haxeon.sh:11-13). Tests: tests/src/<package path>/ plus manifest (credentials, filesystem, agentkit, editor); flat tests/*.hx plus manifest (audio, animation); flat with no manifest (platform, gpu). Import header: in the package's bindings/ (gpu, credentials, filesystem, platform) versus in vendor/nativekit/modules/audio/bindings (packages/audio/tools/check-hxi.sh:28). README.md is missing in filesystem and agentkit-nativekit; LICENSE exists only in gpu and platform.

**Cost.** A consumer cannot tell from a manifest whether depending on a package also yields its shared library. Depending on haxeon-platform or haxeon-gpu alone gives a program that compiles but has no libnativekit unless the app writes its own CMake (examples/audio-lab/haxeon.json:19-31 does exactly that). Every new package copies whichever neighbour the author looked at.

**Proposal.** Pick one convention and write it in packages/README.md: managed package plus optional sibling `native/` provider manifest (the audio/animation style, which allows shared providers), tests in `tests/` with a haxeon.json, import header in the package's `bindings/`. Add a platform native provider so platform and gpu are buildable from manifests. Migrate credentials and filesystem (2 files each).

### 13 near-identical ffi-audit wrapper scripts repeat the target matrix and flags

Overengineering; severity medium, effort M, risk low.

**Evidence.** The four-target abi64 list (`x86_64-linux-gnu`, `x86_64-w64-windows-gnu`, `x86_64-apple-darwin`, `arm64-apple-darwin`) is spelled out in 11 in-scope scripts (13 with ui): packages/{credentials,filesystem,gpu,audio}/tools/check-hxi.sh, packages/animation/native/tools/check-hxi.sh, packages/gpu/tools/benchmark.sh, and packages/platform/tools/{audit-haxeon-abi,audit-haxeon-net-abi,update-haxeon-vulkan-hxi,update-haxeon-net-hxi,test-haxe-bindings}.sh. The abi32 pair is in 4 more in scope (5 with ui). The credentials and filesystem check-hxi.sh files are 28 lines each and differ only in the module name. packages/platform/tools holds 10 scripts for 3 interfaces times 2 ABIs.

**Cost.** Adding a target (linux-arm64 is relevant: the repo already validates ARM64 HashLink) means editing more than 11 scripts, and a missed one silently audits fewer ABIs. The copies have already diverged in behaviour: some write, some check, some take --output.

**Proposal.** Move the invocation into one shared script (for example scripts/haxeon-ffi-binding) driven by data: interface name, library, import header, dependency hxi, profile. Ideally read these from a small `ffi.audit` block in the package's haxeon.json, with `--check` and `--abi32` modes. Per-package scripts become one-liners or disappear.

### haxeon.editor mixes a text-document model with 3D viewport lighting presets that nothing consumes

Organization; severity medium, effort S, risk low.

**Evidence.** packages/editor/src/haxeon/editor/ViewportLook.hx (145 lines: key/fill/rim lights, CAD edge colours, MSAA count, grid step in metres) sits next to TextDocument.hx (336) and TextOffsetMap.hx (945). grep for `ViewportLook` outside packages/editor returns nothing; the only user is packages/editor/tests/src/DocCheck.hx:41-55. The README (packages/editor/README.md:7-15) says it serves 'a documentation site's model viewer' and SceneKit, which 'remains in Materia' (packages/README.md:18). The name also collides conceptually with /home/joao/dev/haxeon/src/editor (package `editor`: LSP and profiler service, 3.7k lines), which is unrelated.

**Cost.** The package ui depends on for text editing carries CAD-viewer constants with zero in-repo callers. 'editor' means three different things here: the compiler's language service, a text buffer, and a 3D viewport. For the Pragtical work, which will lean on TextDocument/TextOffsetMap, the package's purpose is unclear and the directory name misleads greps.

**Proposal.** Move ViewportLook to the repo that uses it (Materia/SceneKit), or to a `haxeon-viewport` package if it must live here. Rename packages/editor to `text` (`haxeon.text.*`) so it is distinguishable from src/editor. Keep typedef shims for one release, as ui already does for these types.

### UI keeps seven compatibility shims over haxeon.editor types

Overengineering; severity low, effort S, risk low.

**Evidence.** packages/ui/haxe/haxeon/ui/widgets/text/{GraphemePosition,Utf16Offset,Utf8Offset,CodepointOffset,TextRange}.hx are 4-line typedefs ('Compatibility name for the editor core type'). TextOffsetMap.hx there is an 11-line subclass of haxeon.editor.TextOffsetMap that only forwards the constructor and `countCodepoints`. These were introduced when the model moved (commit b11cac26, 2026-10-05). UI itself already imports haxeon.editor.TextDocument directly in 9 places.

**Cost.** There are two names for each coordinate type, and the subclass shim is a distinct nominal type: a `haxeon.ui.widgets.text.TextOffsetMap` and a `haxeon.editor.TextOffsetMap` are not interchangeable in the upward direction. Every typedef is also one more module for the compiler to type on each UI build. This is an edge-of-scope item, since the files live in packages/ui.

**Proposal.** Have ui code import haxeon.editor types directly and delete the six shim files. If external apps still use the old names, keep only typedefs (turn the TextOffsetMap subclass into a typedef) with a removal date.

### Five packages have no in-repo consumer and their real tests live in other repositories

Architecture; severity medium, effort M, risk medium.

**Evidence.** grep for the package names in all haxeon.json files shows haxeon-credentials, haxeon-filesystem, haxeon-animation and haxeon-agentkit referenced only by their own tests (plus agentkit-nativekit for agentkit). agentkit-nativekit has no consumer at all. packages/agentkit-nativekit/tests/src/NativeTransportCheck.hx:3 and packages/agentkit/README.md:67-68 state the live test runs from 'Exosuit (scripts/test-agentkit-agents.py)'. Animation came 'from Materia' (commit 400f7ef0). ROADMAP.md mentions none of them; its gates are Pragtical conversion, reload and compile speed. packages/README.md's table omits credentials and filesystem entirely. Sizes: credentials has 38 lines of managed code across 11 files; filesystem has 193 managed lines across 12 files; animation carries 3 vendored submodules (cgltf, ozz-animation, stb) and 1.6k lines of C++.

**Cost.** The compiler repo carries an LLM agent runtime, a glTF/ozz C++ library and OS keychain bindings whose correctness is established elsewhere. Breakage caused by compiler changes is found in downstream repos. Repo clone and submodule surface grow, and the unlisted packages are undiscoverable. Nothing here blocks the roadmap, but each one is un-gated code that claims to be supported.

**Proposal.** Decide per package: (1) keep it as a compiler-conformance corpus, which means it must be in CI (see the test finding) and listed in packages/README.md; or (2) move application libraries (agentkit*, animation, and likely credentials) to the repos that consume and test them, depending on Haxeon by path. At minimum, add credentials and filesystem to the README table and state each package's owner and consumer.

### Magic numbers duplicate generated FFI constants in the thin wrappers

Architecture; severity low, effort S, risk low.

**Evidence.** packages/filesystem/src/haxeon/filesystem/FileSystemFile.hx:12 hardcodes `MAX_READ_BYTES = 262144`, although the binding exports `NK_FILESYSTEM_MAX_READ_BYTES` (packages/filesystem/bindings/nativekit-filesystem.hxi:5, projected into NativeKitFilesystemConstants per nativekit-filesystem.hxmap:7). packages/filesystem/tests/src/haxeon/filesystem/tests/FileSystemSmoke.hx:8 compares `get_kind() != 2` instead of FileSystemEntryKind. packages/agentkit-nativekit/src/haxeon/agent/nativekit/NativeKitHttpTransport.hx:39 uses `options.set_flags(1); // NK_HTTP_CLIENT_ALLOW_HTTP`. The same check()/nativeError helper pair is repeated in FileSystemRoot.hx:63-69 and FileSystemFile.hx:57-63, and inlined in FileSystemDirectory.hx:25-27,39-41.

**Cost.** The audited-binding pipeline exists to keep managed code in sync with the C headers; literal copies defeat it. If the vendor limit or flag value changes, the .hxi updates and the wrapper silently disagrees.

**Proposal.** Use the generated constants and enum abstracts (NativeKitFilesystemConstants, FileSystemEntryKind, the HTTP client flag constant). Share one `FileSystemError.check(status, op)` helper within the package.

### Leave alone

- Checked-in paired abi64 and abi32 bindings (packages/platform/bindings/nativekit.hxi and nativekit-wasm.hxi, 6,979 lines each; nativekit-net*.hxi; packages/audio/bindings/nativekit-audio*.hxi): they look like duplicates but differ in 254 and 42 lines of struct layouts and offsets. They are generated, audited artifacts for two ABI profiles and should stay separate and committed.
- Generated FFI modules stay in the `nativekit.ffi` namespace with `nk_*`/NativeKit names (all *.hxmap files, for example packages/credentials/bindings/nativekit-credentials.hxmap:3) while managed APIs are `haxeon.*`: packages/README.md documents this as a deliberate retention of the C ABI names.
- packages/filesystem is not a duplicate of stdlib/sys/FileSystem.hx: it is a root-confined, handle-based capability API (pinned root identity, in-root symlink rules, 256 KiB bounded positional reads, explicit invalid-UTF-8 names; packages/filesystem/bindings/nativekit-filesystem.hxi). stdlib sys.FileSystem is ambient-authority Haxe compatibility. Different contracts; do not merge.
- /home/joao/dev/haxeon/src/editor (package `editor`: LanguageServiceProtocol, lsp/, profiler/) and packages/editor (`haxeon.editor` text model) do not overlap in code. src/editor/lsp/DocumentStore.hx uses compiler.Source.SourceFile for LSP position mapping and must not depend on a runtime package. Only the naming is confusing.
- cmake/nativekit-module.cmake plus the 4-line packages/{credentials,filesystem}/native/CMakeLists.txt: building only the module directory instead of all of NativeKit is justified in the file header (it avoids about 65 libwebsockets configure checks and the WebView2 download) and by commit b22b38bc.
- Audio and resource cases inside platform's closed PlatformEvent enum and packages/platform/src/haxeon/platform/internal/event/AudioEventDecoder.hx: this looks like platform knowing about audio, but NativeKit has one event queue and one EventKind domain in the core header, so decoding has to happen where the queue is owned.
- agentkit's single-implementation interfaces (HttpTransport, ModelProvider, ToolPolicy in packages/agentkit/src/haxeon/agent): each has two real implementations or a documented second host. ModelProvider has AnthropicProvider and ScriptedProvider, ToolPolicy has SupervisedPolicy and FullAccessPolicy, and HttpTransport has the NativeKit implementation plus the test fake and a planned web fetch host. These are real seams, and they keep agentkit free of platform dependencies.
- The agentkit / agentkit-nativekit split (the second is only 217 source lines): it keeps haxeon-agentkit free of the haxeon-platform dependency so it can run headless and on the web.
- agentkit's JsonObject and JsonWriter (packages/agentkit/src/haxeon/agent/JsonObject.hx, JsonWriter.hx): they look like a reimplemented JSON layer but are thin wrappers over haxe.Json that confine Dynamic to one file, which suits a compiler whose Dynamic/Reflect support is still maturing.
- TextDocument's getters that read `revision` into an unused local (packages/editor/src/haxeon/editor/TextDocument.hx:22-80): these look like dead code but register the Observable dependency, so reads participate in reactive builds while the buffer itself is @:unobservable.
- The separate optional native provider packages (packages/audio/native/haxeon.json, packages/animation/native/haxeon.json): they let a UI plus audio application share one NativeKit shared library (examples/audio-lab) instead of each package linking its own.

## Tests, scripts and build system

### Named test mains are 277 separate stock-Haxe builds of the whole compiler (two thirds of driver time)

Architecture; severity high, effort M, risk medium.

**Evidence.** tests/driver/TestRunner.hx:236-252 (runHaxeMains) and :281-289 (compileMainStep) run one `haxe common.hxml -cp tests... -hl out/test-mains/<Main>.hl -main <Main>` per case. tests/driver/TestCatalog.hx lists 277 mains (232 in compilerMains from line 35, plus toolingMains and runtimeMains). out/test-mains holds 280 files of about 2.5 MB each, 692 MB in total. The one recorded gate run (out/gate/d0d554cd-quick-20261115-130125/driver-default.log) reports named cases 751258 ms, executable cases 146114 ms, program cases 207045 ms and custom cases 9221 ms, out of 1114 s for the driver. docs/TEST_SUITE_COST.md section 3 measured the compile at 89% of named-case CPU (median 5.5 s), rejected a `haxe --wait` server for byte-identity reasons, and left the single-module option with 'feasibility not yet checked'.

**Cost.** About 12.5 minutes of every driver run (quick, wave and ci all include it) goes to re-typing the same compiler sources 277 times. That is the main reason the full suite cannot be run locally. Each main also needs up to 485 MB to compile, which caps the job count. The executable cases add 43 interpreted `haxe --run` setups on the same pattern (TestRunner.hx:262-266).

**Proposal.** Generate a small number of shard entry points (for example 8 to 16, grouped by the existing directory and topic) whose main dispatches on argv[0] to the named main. Build each shard once through ToolArtifacts (src/tools/dev/ToolArtifacts.hx) and keep running every case as its own process: `hl shard.hl <MainName>`. One process per case keeps the isolation TEST_SUITE_COST.md worried about, so only static initializers are shared; check that on a sample first. Unlike a compile server, the shards stay deterministic fresh builds. Move the HaxeMain executable cases onto the same shards.

### No registration check outside tests/programs: 28 integration scripts, 12 hxml files and 2 compiler mains are run by nothing

Architecture; severity high, effort M, risk low.

**Evidence.** TestCatalog.validateProgramManifest (tests/driver/TestCatalog.hx:498-516) fails on an unlisted program; nothing equivalent exists for the other directories. `git grep` outside docs finds no reference to these tests/integration scripts: test-build-executor.sh, test-cli-cache.py, test-compiler-server.sh, test-condition.py, test-dap-{cli,exceptions,function-breakpoints,hot-reload,inline-config,interaction,logpoints,scopes,stepping,watchpoints}.sh, test-debug-metadata.sh, test-exception-stack.py, test-hlb-debug-sections.sh, test-hld3.sh, test-hxi-nativekit-scene.sh, test-json-parser.sh, test-native-cmake-libraries.sh, test-native-cmake-library.sh, test-nativekit-cxx-profile.sh, test-native-package-build.sh, test-profiler-census-sampling.sh, test-sha256-runtime.sh, test-ui-web-compiler-dependency.py, test-wasm-runtime-boundaries.sh. Unreferenced tests/hxml files: hldi-auth-test, hldi-client-test, profiler-{allocation-test,allocation-target,allocation-benchmark,backpressure-test,calibration-test,hot-reload-lsp-test,hot-reload-target,lsp-test,protocol-benchmark,view-model-test}; their mains in tests/profiler are referenced only by those hxml files. Unreferenced compiler mains: tests/compiler/ValueDynamicEqualityInterpreterMain.hx and WasmTypeIdPlanMain.hx. docs/JIT_REGISTER_ALLOCATION_PHASE0.md:51-52 already records test-dap-scopes.sh as an 'existing failure'.

**Cost.** Tests for the compiler server (roadmap B), DAP and HLD3 debugging, the build executor and the profiler LSP exist but protect nothing, and they rot unnoticed. Readers assume coverage that is not there. A new test file can be added and never run, with no signal.

**Proposal.** Add a registration check next to the program one: every tests/integration/test-*, tests/wasm/test-*, tests/hxml/*.hxml and tests/{compiler,runtime,tooling,profiler}/*Main.hx must be named in suites.txt, in TestCatalog, in another registered test, or in an explicit `tests/unregistered.txt` with a reason (manual, needs gdb or npx, known broken). Then triage the 28 scripts: register those that pass, list the manual ones with reasons, delete the dead ones.

### CI, `test.sh` (ci mode) and `gate.sh full` run three different sets of gates; three Wasm suites run twice in CI

Architecture; severity high, effort S, risk low.

**Evidence.** .github/workflows/ci.yml on the `test` platform runs tests/wasm/test-wasm-backend.sh, test-wasm-parity.sh and test-wasm-gc-wasmtime.sh as their own steps, then `scripts/test.sh`, whose ci mode runs the same three (tests/suites.txt: wasm-backend, wasm-parity, wasm-gc-wasmtime). CI then runs, outside the manifest: tests/integration/test-haxeon-cli.sh, `scripts/bootstrap-compiler.sh --self`, scripts/check-self-hosting.sh, tests/integration/test-gdb-hot-reload.sh (the only caller of test-hot-reload.sh) and tests/wasm/test-wasm-gc-chrome.sh. A grep of tests/suites.txt for self-hosting, bootstrap, haxeon-cli, gdb-hot, chrome or test-hot-reload returns nothing. scripts/test.sh:2 says 'The suites CI runs', and scripts/gate.sh describes `full` as 'wave and every suite scripts/test.sh runs'.

**Cost.** A local `gate.sh full` or `test.sh` pass does not include the self-hosting fixed point or the hot-reload test, two stated priorities, so those regressions show up only in CI. CI pays for both Wasm scripts (1029 and 1196 lines) twice on the main platform. The header comments mislead about what a green local run means.

**Proposal.** Make suites.txt the only list. Add self-hosting-fixed-point, bootstrap-self, haxeon-cli, hot-reload, gdb-hot-reload (requires=gdb) and wasm-gc-chrome (requires=chrome) as suites, using the existing `requires=` mechanism. Delete the three duplicate Wasm steps and the standalone steps from ci.yml so that non-Windows CI is tool setup plus `scripts/test.sh`.

### About 84 scripts hand-roll the root, HashLink path and library path preamble that scripts/lib/env.sh provides

Organization; severity medium, effort M, risk low.

**Evidence.** scripts/lib/env.sh defines haxeon_require_haxe, haxeon_require_hashlink, haxeon_export_library_path and haxeon_suite_out. 24 files under tests/ and scripts/ source it, and only 7 call haxeon_export_library_path. 92 files set LD_LIBRARY_PATH themselves; 84 of those do not source env.sh (60 in tests/integration, 13 in tests/bench, 7 in scripts). 134 files recompute the root with `$(cd "$(dirname ...)")`, under four names: root, root_dir, repo_dir, haxeon_root. The 'Missing checkout-built HashLink' check is written out 7 times (scripts/haxeon, haxeon-compiler.sh, test-driver.sh, hashlink-launch.sh, check-self-hosting.sh and others). The copies differ: tests/integration/test-profiler-wait.sh:22 exports only LD_LIBRARY_PATH, scripts/check-self-hosting.sh:24-27 switches on uname, and scripts/haxeon:49-50 exports both. Many write fixed paths under out/ (test-profiler-wait.sh:9 `out/profiler-wait-target.hl`) instead of haxeon_suite_out.

**Cost.** Any change to where the runtime lives or how libraries are found is an edit to about 90 files. Per-platform behaviour differs by script. Fixed out/ paths and fixed ports (24019, 24020 and 24030 in test-profiler-{reconnect,wait,pool-stall}.sh) are the reason about 48 suites in suites.txt have no lane or pool and run one after another.

**Proposal.** Extend env.sh into the single preamble (root, haxe, hl, library path, suite output, a `haxeon_tool MAIN` wrapper around tool-path, a free-port helper) and migrate tests/integration mechanically. Once the scripts write to haxeon_suite_out and take a port from the helper, put the 15 profiler suites and the python suites into pools.

### The Wasm test scripts are monoliths with hand-kept fixture lists and a 700-line JavaScript heredoc

Organization; severity medium, effort M, risk medium.

**Evidence.** tests/wasm/test-wasm-parity.sh is 1196 lines: a hand-maintained inline_cases array of about 85 names (lines 17-118), 70 haxeon_compile calls with per-fixture `--export=` lists (lines 135-480), and one `node - ... <<'JS'` heredoc from line 488 to about line 1192. tests/wasm/test-wasm-backend.sh is 1029 lines with 68 compile calls and 7 heredocs. Parallelism comes from a bash job pool in scripts/haxeon-compiler.sh:37-70, written around bash 3.2 limits. The HL side of the same program corpus is run by tests/driver/TestRunner.hx (runPrograms, lines 372-469) from the same expected-exits.tsv.

**Cost.** One program corpus has two unrelated runners (Haxe for HL, bash plus embedded JS for Wasm). Adding a Wasm census check means editing three distant places in one file. The embedded JS gets no formatter, linter or editor support, and its errors point at stdin line numbers. A failure in either script fails the whole suite, with no per-case filter such as the driver's `--test`. This is on the Wasm parity path that the Haxe-semantics priority depends on.

**Proposal.** Move the JS host into checked-in modules under tests/wasm/host/ (tests/runtime/run-equality-guard.js and wasm-arena-host.js already set the pattern). Move the fixture, exports, flags and inline-mode table into a data file beside expected-exits.tsv. Have the test driver run the generic 'every manifest program on wasm32 and wasm-gc' loop as another program-run mode, so it shares batching, per-case reporting and filtering. Keep bash only for the backend-specific checks.

### Seven Haxe mains exist only to shell out to bash scripts, because the driver catalog has no script case

Overengineering; severity medium, effort S, risk low.

**Evidence.** tests/runtime/{GcIncremental,GcAllocationPaths,GcOwnerPages,GcEmptyPages,GcMarkClaim,JitBoxedAllocation,JitInlineAllocation}Main.hx each consist of `Sys.command("bash", ["tests/integration/test-....sh"])`; GcIncrementalMain.hx is 7 lines in full. They are registered in TestCatalog.runtimeMains (tests/driver/TestCatalog.hx:307-320), so each is compiled by stock Haxe to out/test-mains and run to start a bash script. suites.txt can already run bash suites directly; these scripts are not listed there.

**Cost.** There are two ways to register a bash test, so an integration script can look unregistered when it is not, or the reverse. Each wrapper costs a Haxe compile to run one line. The Windows driver run (ci.yml `HaxeonBuild test 8`) executes mains that require bash. GcIncrementalMain was measured at 20 s inside the named phase (docs/TEST_SUITE_COST.md section 3).

**Proposal.** Delete the seven wrappers and list the scripts in tests/suites.txt in a `pool=gc` (their native builds already go to per-run temporary directories). If they must stay inside the driver for its sandbox, add a `Script(path)` CompileStep to TestCatalog instead of compiled forwarders.

### The DAP and HLD3 scripts build HashLink through a second path and overwrite the CMake-built runtime in out/

Architecture; severity medium, effort M, risk low.

**Evidence.** Ten scripts run `make -C vendor/hashlink ... libhl.so hl`: tests/integration/test-dap-{logpoints,interaction,exceptions,watchpoints,hot-reload,stepping,scopes,function-breakpoints}.sh, test-hld3.sh and test-hlb-debug-sections.sh. Eight of them then run `cc -shared -fPIC -DHL_NAME(n)=realtime_##n ... native/runtime.c ... -o "$repo_dir/out/haxeon_runtime.hdll"` (test-dap-stepping.sh:12-15). Everything else uses the CMake preset build in out/cmake/release/hashlink-runtime, found through scripts/hashlink-path.sh. 44 scripts under tests/integration, tests/bench and tests/wasm invoke the C compiler directly; tests/native has 41 .c files, while tests/native/CMakeLists.txt (50 lines) defines only two targets.

**Cost.** Running any DAP test by hand replaces out/haxeon_runtime.hdll with a build that has different flags, no pinned libffi and none of CMakeLists.txt's options, so later runs use a mismatched runtime without saying so. The Makefile path is untested and is a likely reason these scripts dropped out of the suites. Compiler flags for native probes are spread over 44 scripts and cannot follow presets such as frame pointers, the MSVC debug CRT or arm64.

**Proposal.** Port the ten scripts to scripts/build-native.sh and hashlink-path.sh, and have them write nothing under out/ except their suite directory. For native probes, add an EXCLUDE_FROM_ALL `haxeon-test-probes` target to tests/native/CMakeLists.txt that builds the probes used by registered suites, so flags come from the preset; keep ad hoc `cc` only for one-off bench experiments.

### The self-hosting fixed point is implemented twice, in bash and in Haxe, with different source sets

Architecture; severity medium, effort S, risk low.

**Evidence.** src/build/HaxeonBuild.hx:50-95 (bootstrap): seed through `haxe --run compiler.tools.HaxeonCompiler`, stages until byte-identical including `.functions`, sources from sourceManifest() over src, lib and stdlib (lines 161-167). scripts/check-self-hosting.sh:30-61: the same seed, stage 1, stage 2 and cmp in bash, with sources from `find src stdlib` (line 31) and then `src stdlib lib/haxeon-io` for the entry check (line 67). The argument list `--entry=compiler.tools.HaxeonCompiler --root=src --root=stdlib --sources-file=` appears in both (HaxeonBuild.hx:152-159, check-self-hosting.sh:33). The second half of check-self-hosting.sh (entry gaps at lines 63-98, equality guard at lines 100-119) is unrelated test logic. CI runs both, one after the other.

**Cost.** Two definitions of what the compiler's sources are (with and without lib/) can disagree about convergence. A change to compiler arguments or the manifest has to be made in two languages. The Windows job gets only the Haxe version. CI pays for the seed build under the Haxe interpreter twice.

**Proposal.** Keep one implementation in build.HaxeonBuild: add a `self-check` command that runs seed, stage 1 and stage 2 without touching bootstrap/compiler.hl, sharing bootstrap()'s loop and sourceManifest(). Reduce scripts/check-self-hosting.sh to a call to it. Move the entry-gap list and the equality guard into separate suites in suites.txt.

### Two content-hash caches for the same CLI, plus a fake `haxe` shim to reach one of them

Overengineering; severity medium, effort M, risk medium.

**Evidence.** scripts/haxeon:22-46 hashes every file under src, lib and .tools/haxe/std with sha256sum (3237 files here) on every invocation and builds out/haxeon-cli.hl. src/tools/dev/ToolArtifacts.hx:81-112 builds an equivalent key in Haxe and stores out/tools/<main>-<key>.hl. SuiteRunner resolves tools.HaxeonCli a second time through ToolArtifacts as HAXEON_TEST_CLI_HL (SuiteRunner.hx:150-153). Each `scripts/haxeon dev tool-path X` call (13 scripts) pays the bash hash and then the Haxe hash. scripts/test-cli-launcher.sh:13 matches argv against `--cwd X -cp Y --run tools.HaxeonCli` to redirect 13 scripts that hard-code `haxe --run tools.HaxeonCli` to the prebuilt CLI; SuiteRunner.hx:281 sets HAXEON_HAXE and HAXEON_REAL_HAXE for 18 suites marked `cli-launcher`. scripts/haxeon.ps1 has no cache and interprets the CLI every time.

**Cost.** Two fingerprint algorithms must stay equivalent, and two CLI binaries can be in play in one run. The shim silently stops matching when a script's argument order changes (test-compiler-embedding.sh:22 passes two -cp flags, so `$5 == --run` is false and the interpreter runs). Pin variables keep multiplying: HAXEON_MAIN_HL, HAXEON_COMPILER_HL, HAXEON_BUILD_HL, HAXEON_TEST_CLI_HL, HAXEON_HAXE, HAXEON_REAL_HAXE.

**Proposal.** Have integration scripts call one launcher, `scripts/haxeon` (or `haxeon_cli` from env.sh, which honours the pinned CLI), instead of `haxe --run tools.HaxeonCli`. Then delete test-cli-launcher.sh, the `cli-launcher` option and HAXEON_REAL_HAXE. Let scripts/haxeon skip its hash when the runner has exported a pinned CLI, so the fingerprint is computed once per run.

### Benchmarks are split across benchmarks/, tests/bench/, scripts/benchmark-* and tests/profiler with no rule

Organization; severity low, effort S, risk low.

**Evidence.** benchmarks/ holds BenchmarkMain.hx (480 lines, run by scripts/benchmark.sh), cross-lang/, interface-call-cost/ and interface-dispatch/generate.py. tests/bench/ (36 files) holds gc-owner, sha256, value-array-words, incremental-gc (C sources, run-*.sh, plot-*.py), bump-allocation, jit-regalloc, and typed-interface-dispatch.template.hx, whose driver is scripts/benchmark-typed-interface-dispatch.py:17. scripts/ has five more benchmark files (benchmark-compare.py, benchmark-incremental-project.py, benchmark-wasm32-gc.sh, measure-cold.sh, benchmark.sh). tests/profiler/Profiler{Protocol,Allocation}BenchmarkMain.hx with tests/hxml/profiler-*-benchmark.hxml are unreferenced. Interface dispatch is benchmarked in three places (benchmarks/interface-dispatch, benchmarks/interface-call-cost, tests/bench plus the scripts/ driver). No suite in suites.txt runs any of tests/bench.

**Cost.** A benchmark and its driver sit in different top-level directories. tests/bench is not a test category (nothing runs it), yet it inflates tests/. The roadmap says 'measure before optimizing', but there is no single place to find or add a measurement.

**Proposal.** Move tests/bench/* and the scripts/benchmark-*, measure-cold.sh and benchmark-compare.py drivers into benchmarks/<topic>/ (driver next to template), and leave scripts/benchmark.sh as the one entry point. Merge the three interface-dispatch benchmarks into benchmarks/interface-dispatch.

### CMake presets that the path table and scripts cannot find

Overengineering; severity low, effort S, risk low.

**Evidence.** CMakePresets.json defines dev, release, windows-msvc, windows-msvc-debug and macos-arm64, each with its own out/cmake/<name> binaryDir. cmake/hashlink-output-paths.txt maps only release and windows-msvc. scripts/hashlink-path.sh:5-8 and src/build/HashLinkPath.hx:9 hard-code those two names. scripts/build-native.sh:5 and build-native.ps1:4 accept HAXEON_CMAKE_PRESET, and docs/DEVELOPMENT.md:152-153 recommends it. Only tests/integration/test-hot-reload.sh:10 honours the variable when locating a target. CI's windows-msvc-debug step relies on the debug build landing where the release lookup points.

**Cost.** `HAXEON_CMAKE_PRESET=dev scripts/build-native.sh` builds a runtime that no launcher, test or tool will run; they keep using a stale release build, or fail with 'run scripts/build-native.sh first'. The preset to path mapping is kept in three places: the presets file, the txt file and two hard-coded switches.

**Proposal.** Either make hashlink-path.sh and HashLinkPath read HAXEON_CMAKE_PRESET (falling back to the platform default) and list every preset in hashlink-output-paths.txt, or delete the dev and macos-arm64 presets together with the environment variable. In both cases write the default-preset choice once, in the txt file, and have the bash and Haxe lookups read it.

### Leave alone

- tests/suites.txt with src/tools/dev/SuiteRunner.hx and SuiteManifest.hx: a plain-text manifest with groups, lanes, pools and `requires=`, replacing bash orchestration. scripts/test.sh, gate.sh and format.sh are 5 to 23 line wrappers on purpose, to stay within macOS bash 3.2. Keep and extend it; it is the right home for the fixes above.
- src/tools/dev/ToolArtifacts.hx: the content-hashed cache of stock-Haxe-built tools in out/tools, with atomic rename and age-based pruning. It looks heavy for a dev tool, but it is what stops every script rebuilding or interpreting the compiler (docs/TEST_SUITE_COST.md section 0).
- tests/driver/TestRunner.hx startProgram (lines 196-208): each case runs in a symlink-farm sandbox under out/cases. It looks odd, but it lets the live, plain and unpruned builds of one program run concurrently without colliding in out/.
- tests/driver/TestRunner.hx BatchCompilers (lines 58-110) and the three runs per program (live, plain, plain without early prune; runsOf at lines 331-369): deliberate. The triple run is the migration reference for IrEntryPrune and is documented as removable with the switch.
- tests/driver/TestRunner.hx warmEditKnownFailures (lines 164-166): an expected-failure list that fails once the cause is fixed. The entry_gaps list in scripts/check-self-hosting.sh:71-77 uses the same self-expiring pattern. Keep both.
- No Haxe compilation server for the named cases: tried and rejected with measurements because warm-server output is not byte-identical to a fresh build (docs/TEST_SUITE_COST.md section 3). Do not bring `--connect` back; shard binaries are the alternative.
- common.hxml (3 lines) as the single class-path list, read by scripts/haxeon, scripts/compiler-class-paths.sh, ToolArtifacts.commonClassPaths and tests/integration/test-external-tool-build.sh. build.hxml is a 3-line convenience on top of it. The indirection is intentional and guarded by the external-tool-build suite.
- cmake/hashlink-output-paths.txt read by both scripts/hashlink-path.sh and src/build/HashLinkPath.hx: a two-line data file shared by bash and Haxe so they cannot disagree, and it never selects the bootstrap VM. Keep the mechanism; only its preset coverage is incomplete.
- scripts/test-driver.sh copying hl, libhl and haxeon_runtime.hdll into a temporary directory before running the driver: needed because the driver rebuilds native libraries in out/ while running (src/build/RuntimeBuildSafety.hx, checked in HaxeonBuild.test). It is covered by the runtime-build-isolation suite.
- Three test directories that are not overlapping categories: tests/programs (591 exit-code programs, manifest-validated, shared by the HL and Wasm runs), tests/compiler (in-process compiler API tests) and tests/integration (process-level scripts). tests/hxml files are thin, uniform 4-line entry definitions. No merge is needed.
- tests/differential pairing `.official.hx` with `.realtime.hx`: the two files per case are the oracle design (ROADMAP section E). Only the old 'realtime' name is stale.
- `fresh-native` and HAXEON_NATIVE_READY in suites.txt and scripts/build-native.sh:9-11: they look like a hack, but they prevent concurrent cmake configure runs racing in one build tree while still letting two suites test the real native build.
- The Windows CI path calling `haxe --run build.HaxeonBuild test` directly instead of scripts/test.sh: the suites are bash and HaxeonBuild is the cross-platform entry point. The asymmetry is intended.

## Documentation

### Flat docs/ mixes references, proposals, experiment reports and handoffs with no index or status taxonomy

Organization; severity high, effort M, risk low.

**Evidence.** docs/ has 85 top-level .md files (18,118 lines) and no README or index; README.md:176-190 links 11 of them and then just 'docs/'. By my classification roughly 30 are references, 22 design or plan notes, 27 measurement or experiment reports and 6 handoffs. 29 perf, GC, JIT and investigation files total 6,207 lines, including rejected experiments at top level (BOUNDS_CHECK_ELIMINATION.md title 'rejected experiment', FASTA_PROFILE.md 'rejected experiments', OPTIMIZATION_NEXT_RESULTS.md:3-4 'failed their gates and were removed'). 23 top-level docs have zero inbound references from any .md, .hx, .sh, .py, .c or .yml file (e.g. BINARY_SIZE, RPC, JSON_WIRE, SEMANTIC_TYPE_CONTRACT, HLB_DEBUG_SECTIONS, JIT_REGISTER_ALLOCATION, PRAGTICAL_CONVERSION_PLAN). Only 26 of 85 carry a Status line. docs/history/ already exists as a convention but holds only 3 files.

**Cost.** A reader cannot tell which document is the current contract and which is a dated experiment; ALLOCATION_CENSUS.md (1,482 lines) sits beside CLI.md with equal standing. A reference such as SEMANTIC_TYPE_CONTRACT.md (untouched since 2026-09-08, 0 inbound links) is undiscoverable. Stale claims in reports get read as present truth.

**Proposal.** Split by document kind and add docs/README.md as the index: docs/reference/ (user and contract docs: CLI, LANGUAGE_SUPPORT, LIVE_PATCHING, WASM_BACKEND, C_HEADER_FFI, ANDROID, NATIVE_MEMORY, KEY_PATHS, ITERATION, PROFILING, MESSAGEPACK, RPC, the format specs), docs/design/ (live design notes and proposals, each with a mandatory 'Status: proposal | in progress | landed | superseded' first line), docs/reports/ (dated measurement and experiment reports, named YYYY-MM-topic, never edited after acceptance), docs/adr/ (unchanged), docs/history/ (superseded plans and handoffs). Keep ARCHITECTURE.md and DEVELOPMENT.md at docs/ top level. Update the links in README and ROADMAP and the 9 or so code and script references (STRUCTS.md has 10 inbound, REACHABILITY_WALK.md 9).

### ADR 0003/0004 status says 'nothing implemented' while ARCHITECTURE.md records M0 and M1 as landed

Organization; severity high, effort S, risk low.

**Evidence.** docs/adr/0003-compiler-architecture.md:7 'Proposed. Nothing here is implemented yet'; :321 'M0 (in progress ...)'; :328-329 M1 still lists 'IrInliner.packedValueFields' as a static to replace. docs/ARCHITECTURE.md:62 is headed 'Warm builds: what landed (M0 and M1 of ADR 0003)'; docs/WARM_REBUILD_REUSE.md:400 'M1: TargetProfile and ProgramFacts (landed 2026-11-09)'. Code agrees with ARCHITECTURE: src/compiler/ir/TargetProfile.hx:13-35 exists, src/compiler/ir/IrInliner.hx:571 and :848 read profile.packedValueFields, and HlLink, HlLoweredCache, IrVerifyMemo and src/compiler/Provides.hx (decision 13) exist. docs/adr/0004-runtime-library-and-backends.md:7 says 'Nothing here is implemented' (decision 5, deleting Wasm64, is indeed not done: wasm64 is still in Backend.hx, WasmTarget.hx and CompilerDriver.hx; README.md:141 and WASM_BACKEND.md:264 still describe it).

**Cost.** ADR 0003 is the organizing document for the compiler refactor (M0-M6), and 8 or more notes cite its milestones. A reader or agent starting from the ADR will plan work that is already done (M0, M1, parts of section 13) or not know which decisions are live.

**Proposal.** Change ADR 0003's status to 'Accepted; M0 and M1 landed (see ARCHITECTURE.md), M2+ pending' and add a one-line landed/pending marker per migration step. ADR 0003:349-350 already says current state lives in ARCHITECTURE.md, so keep the ADR to decisions plus a status table and nothing else. Do the same check for ADR 0004 and 0005 each time a step lands.

### Plan documents double as changelogs and their status headers contradict their bodies

Organization; severity medium, effort M, risk low.

**Evidence.** docs/WARM_REBUILD_REUSE.md:3 'Status: plan (step 1), not implemented. Branch warm-rebuild-reuse', yet :341-345 marks steps done, :400 'landed 2026-11-09', and 11 dated sections were appended between :426 and :549 (554 lines). ARCHITECTURE.md:64 points to it as 'the current plan'. docs/IR_PASS_INVENTORY.md:3 'Status: proposal, no code' while :13-25 has four checked [x] migration items describing landed code (typed enum box/view operations, declared adapter kinds). docs/PROVIDER_REQUESTS.md title says '(design note, no code)' while :3 says 'superseded ... implemented ... and then deleted'. docs/PROVIDER_INVENTORY.md:3 is pinned to 'branch warm-rebuild-reuse at a2e2ae45'. docs/STRUCTS.md (1,592 lines) is 'implementation in progress' with staged dated entries from :10. docs/adr/0002-reactive-ui-model.md has its Migration section spanning lines 309-1674 of 1,702.

**Cost.** The reader must read 500+ lines chronologically to learn the current state; the first line misleads. Design content that is still normative (e.g. the relocatable lowering contract) is buried under dated findings, which makes the next refactor step (M2 pass framework) harder to scope.

**Proposal.** For each landed plan: move the normative result into ARCHITECTURE.md or a docs/design/ note written in present tense, move the dated log to docs/history/<topic>-2026-11.md (the pattern already used for history/ir-pass-inventory-2026-11.md and history/structs-measurements-2026-11.md), and fix the status line. Start with WARM_REBUILD_REUSE.md, IR_PASS_INVENTORY.md, PROVIDER_REQUESTS.md and PROVIDER_INVENTORY.md; split ADR 0002's migration log out of the ADR.

### ARCHITECTURE.md does not describe the src/ layout or anything outside the compiler pipeline

Organization; severity medium, effort M, risk low.

**Evidence.** docs/ARCHITECTURE.md is 133 lines: :1-60 a pipeline overview (lexer, parser, type checker, SSA, HL lowering, the HLB/HLI/HLP names), :62-108 warm-build caches, :111-133 performance rules for compiler code. It names no directory. src/ holds 455 .hx files under compiler/ (17 subfolders: abi, backend, compilation, ffi, formatter, hl, ir, modules, semantic, service, syntax, types and others), 50 under build/, 25 under project/, 19 under runtime/, 20 under tools/, 8 under editor/, 6 under profiler/, plus 5 entry points. Only 2 docs mention src/build, src/project, src/editor, src/profiler or src/runtime at all (MAIN_COMPATIBILITY_HANDOFF.md, PROFILER-POSIX.md). The compiler service, LSP, build planner and executor, package resolver, stdlib/, packages/, native/ and embed/ are absent. The layer list lives only in ADR 0003 section 2, which is marked Proposed.

**Cost.** The document every review and new contributor is told to read first cannot answer 'where does X live' or 'which layer may import which'; layering (e.g. whether src/build may import compiler internals, or compiler/ir may import compiler/backend) is unstated, so violations cannot be judged against anything.

**Proposal.** Add a 'Source map' section to ARCHITECTURE.md: one row per top-level src/ folder and per src/compiler subfolder (purpose, entry type, allowed dependencies), the five entry points (Main, LspMain, EditorServiceMain, FfiImportMain, FfiAuditMain) and one line each for stdlib/, packages/, native/, vendor/hashlink, bootstrap/. Move 'Performance rules for compiler code' (:111-133) to DEVELOPMENT.md, where contributor rules already live.

### Haxe-compatibility gaps are tracked in four places that already disagree with each other and with the stdlib

Organization; severity medium, effort S, risk low.

**Evidence.** The same gap list appears in ROADMAP.md:38-41, docs/LANGUAGE_SUPPORT.md:84-96, docs/LANGUAGE_ROADMAP.md:214-217 and TODO.md:19-20 (Type.getClassName is in three of them). Mismatches found: (1) LANGUAGE_SUPPORT.md:19-21 says 'there is no identity-keyed map like Haxe's ObjectMap', but stdlib/haxe/ds/ObjectMap.hx exists (touched 2026-11-09) and STRUCTS.md:879 and GENERIC_SPECIALIZATION.md:156 document identity-keyed haxe.ds.ObjectMap. (2) ROADMAP.md:40 and LANGUAGE_SUPPORT.md:93 list haxe.ds.List as missing; stdlib/List.hx exists as 'typedef List<T> = Array<T>' (since 2026-09-07) and stdlib/haxe/ds has no List.hx, so the real gap is a real List under haxe.ds, which neither states. (3) ROADMAP.md:68-69 says structural class layout changes 'are classified as full-reload generations', while LIVE_PATCHING.md:224-314 documents field add, remove and reorder patching in place via reserved slots (src/compiler/compilation/BackendAssembly.hx:40 liveFieldReserve = 4).

**Cost.** These lists steer the top roadmap priority (Haxe parity for Pragtical). Each stdlib commit (three on 2026-11-15 alone) must update up to four files; when one is missed, work is planned against a gap that is closed or mis-stated, and users are told a feature is missing when it is not.

**Proposal.** Make LANGUAGE_SUPPORT.md 'Not yet supported' the single list. ROADMAP section A and LANGUAGE_ROADMAP 'Other Haxe compatibility gaps' link to it instead of restating items; TODO.md keeps only items with design content (enum abstracts as TAbstract, event signal, HTTP server, BLAKE3, shader generator) and drops the Type.getClassName line. Fix the three mismatches above; rewrite ROADMAP section C's layout bullet to say what still reloads (field type change, base or interface change, reserve exhausted).

### Format references carry old wire versions: PATCH_TRANSACTIONS says HLP 7, code is 11; HLB_DEBUG_SECTIONS says HLB 7, code is 8

Organization; severity medium, effort S, risk low.

**Evidence.** docs/PATCH_TRANSACTIONS.md:13 'HLP version 7 also validates content-addressed source snapshots'; src/compiler/hl/patch/HlPatchFormat.hx:6-7 'VERSION:Int = 11' ('11: virtual types carry stable nominal interface identities'). docs/HLB_DEBUG_SECTIONS.md:3 'HLB version 7 appends a versioned debug-section stream'; src/compiler/hl/HlCode.hx:5 'VERSION = 8'. Both docs were last committed 2026-09-07; so was HLD3_DEBUG_PROTOCOL.md. PATCH_TRANSACTIONS.md is one of the 11 documents README.md:184 links as 'Patch transactions in depth'; HLB_DEBUG_SECTIONS.md and HLD3_DEBUG_PROTOCOL.md have 0 inbound links.

**Cost.** These are the only prose specifications of the binary contracts between compiler, runtime and debugger. Four HLP revisions (8-11) are documented only in a code comment, so someone writing a reader or debugger from the document targets a format the runtime rejects as stale.

**Proposal.** Merge the three into one docs/reference/FORMATS.md (HLB sections, HLI, HLP, HLD3) with a version-history table per format, and add to the doc comment on HlPatchFormat.VERSION and HlCode.VERSION a line naming that file as the place to record each bump. Verify the section kind:version pairs (1:1, 2:2, 3:1) against vendor/hashlink/src/code.c while doing so; I did not check those.

### PRAGTICAL_CONVERSION_PLAN.md is a September plan that contradicts ROADMAP on the project's primary goal

Organization; severity medium, effort S, risk low.

**Evidence.** docs/PRAGTICAL_CONVERSION_PLAN.md (185 lines) was last committed 2026-09-05, the day after the first commit, and has 0 inbound links. :38 'larger than the current POC'; :49-50 'typed filters and uncaught-exception diagnostics remain before migration', but ROADMAP.md:33 lists 'exceptions with typed catch filters' as done; :52-53 defers 'arbitrary abstracts', but ROADMAP.md:30 lists abstracts with operators as done; :54 cites 'pragtical/scripts/lua/tests/languages/samples/052_haxe.hx', a path that does not exist in the repo; stages 1-3 (:67-98) describe work ROADMAP sections A-C mark done (non-moving type arena, atomic patches, closures with capture cells). ROADMAP.md:89-99 ('Next', 'Definition of Pragtical-ready') is the live plan and never references this file.

**Cost.** Two plans for the near-term goal with different stage definitions and exit gates; the one with the more specific file name is the stale one.

**Proposal.** Fold the still-useful parts (stage 4 plugin-first exit gate, the Plugin interface sketch, the 'no layer may become a second typechecker' rule at :27-33) into ROADMAP.md 'Next' and 'Definition of Pragtical-ready', then move the file to docs/history/pragtical-conversion-plan-2026-09.md.

### Six branch handoff notes for external consumers live as top-level docs

Organization; severity medium, effort S, risk low.

**Evidence.** MAIN_COMPATIBILITY_HANDOFF.md (192), WORLD_SCHEMA_FORWARDPORT_PLAN.md (389), WORLD_MAIN_SOURCE_INTEGRATION_HANDOFF.md (158), WORLD_INTEGER_DESCRIPTOR_HANDOFF.md (39), WORLD_RESOURCE_DESCRIPTOR_HANDOFF.md (39), WAMR_PROFILE_HANDOFF.md (114): 931 lines, every one with 0 inbound references. They describe review branches by name and hash ('overnight/compiler-world-forwardport-20261009 ... was not pushed or merged', MAIN_COMPATIBILITY_HANDOFF.md:5-13; 'feat/wamr-profile-20261011', WAMR_PROFILE_HANDOFF.md:3) and other projects' pins (World, Beartooth, Script). Neither branch is in 'git branch -a'. MAIN_COMPATIBILITY_HANDOFF.md's title is 'World compatibility forward-port handoff', which does not match its file name. Two of them contain durable API facts (typeInfo sourceKind/interfaces and MessagePackSchema.requireSourceFacts in WORLD_RESOURCE_DESCRIPTOR_HANDOFF.md; UInt32 default carriers in WORLD_INTEGER_DESCRIPTOR_HANDOFF.md).

**Cost.** Point-in-time merge logistics read as documentation of the current tree; the durable API facts inside them are not in MESSAGEPACK.md or STRUCTS.md, where a user would look.

**Proposal.** Move the API facts from the two descriptor handoffs into MESSAGEPACK.md and STRUCTS.md, then move all six to docs/history/ with dated names. Verify first whether the WAMR profile and fuel ABI landed on main (I did not check) and, if it did, document it in WASM_BACKEND.md.

### User-facing docs still present '@:value @:repr("C") class' as the native record form while STRUCTS.md says 'struct' replaces it

Organization; severity medium, effort S, risk low.

**Evidence.** docs/STRUCTS.md:2-3 'struct replaces both @:value class and @:value @:repr("C") class; their uses will be ported and the old forms removed'. stdlib/ and packages/ contain 0 .hx files using @:value and 20 files declaring a struct; 25 files under tests/ still use @:value, and the compiler accepts both (src/compiler/types/typing/ValueCopy.hx:46, ProgramTyper.hx:1184). README.md:78 advertises 'Fixed-layout @:value @:repr("C") records' and never mentions struct; docs/NATIVE_MEMORY.md:7-12 and docs/LANGUAGE_SUPPORT.md:120 teach the old form; TODO.md:59 specifies new generator output as '@:repr("C") records'.

**Cost.** The README and the native-memory reference teach a spelling the project's own libraries have fully left and that is scheduled for removal; new binding code (including the planned shader generator in TODO.md) gets written in the form about to be deleted.

**Proposal.** Update README.md:78, NATIVE_MEMORY.md, LANGUAGE_SUPPORT.md:120 and TODO.md:59 to the struct spelling, with one sentence in NATIVE_MEMORY.md that the @:value forms are deprecated pending removal. Extract a short 'Structs' user reference from the 1,592-line STRUCTS.md so the language feature has a document that is not an implementation log.

### CLI.md is 390 lines with one section heading and omits three dispatched commands

Organization; severity low, effort S, risk low.

**Evidence.** 'grep ^#' on docs/CLI.md returns only the title (line 1) and '## Workspace builds' (line 334); lines 2-333 are one unsectioned run covering init, dependencies, registry, build, run, watch, live, fmt, lint and packaging. src/tools/HaxeonCli.hx:132-151 dispatches 19 commands; 'haxeon heap', 'haxeon identity-path' and 'haxeon dev' have 0 mentions in CLI.md ('dev' is documented in DEVELOPMENT.md:18-83; heap and identity-path were not found in CLI.md).

**Cost.** The one document README names for the CLI cannot be linked by section (README.md:63 can only say 'see Project CLI' for the live entry-class contract) and gives no way to see which commands exist.

**Proposal.** Add one '##' section per command group (project and dependencies, build and run, watch and live, fmt and lint, package and publish, diagnostics: doctor, platforms, devices, heap, identity-path) with a command table at the top generated from or checked against HaxeonCli.usage(); link 'dev' to DEVELOPMENT.md.

### Docs reference agent names, gitignored evidence paths and other repos' scripts; file naming is inconsistent

Organization; severity low, effort S, risk low.

**Evidence.** 'dev-71' (an agent or session name) appears 19 times across 9 docs as the approver or addressee (e.g. WARM_REBUILD_REUSE.md:310 'Approved order and safety rules (dev-71)', :376 'Open questions for dev-71', REACHABILITY_WALK.md:3). 156 lines in docs/*.md cite paths under out/, which .gitignore:2 excludes (e.g. OPTIMIZATION_NEXT_RESULTS.md 'Raw local evidence is under out/optimization-next'). PROFILING.md:47 documents 'python scripts/run.py' from another repo (exosuit). DEVELOPMENT.md:3 is still headed 'Run the proof of concept'. Naming: PROFILER.md (design), PROFILING.md (usage) and PROFILER-POSIX.md, the only hyphenated name among 85 UPPER_SNAKE files; MAIN_COMPATIBILITY_HANDOFF.md's content is about World.

**Cost.** Approval provenance and evidence are unverifiable by anyone outside the session that wrote them; PROFILER versus PROFILING is a guaranteed wrong-file open.

**Proposal.** Replace 'dev-71' with 'approved <date>' or drop it; state in reports that out/ evidence is local and not retained (or commit the small result tables inline, as most already do). Rename to PROFILER_DESIGN.md, PROFILER_DESIGN_POSIX.md and PROFILING.md during the restructure, and retitle DEVELOPMENT.md:3.

### Leave alone

- docs/ARCHITECTURE.md 'Warm builds: what landed' (lines 62-108): dense and class-name heavy, but it is accurate. All 17 symbols and switches it names exist in src (IrVerifyMemo, HlLink, HlLoweredCache, HlLoweringView, TargetProfile with the six listed fields, ProgramFacts, CompilerSnapshot, HlFunctionEquality, HAXEON_CHECK_REUSE), and ADR 0003:349-350 designates this file as the home of current state. Extend it; do not replace it with the ADR.
- The 'design note, no code' documents FRONTEND_RESTART.md, INTERNED_NAMES.md and HELPER_OWNERSHIP.md look like dead proposals but are truthful and tied to the roadmap: the frontend restart still exists (src/compiler/compilation/FrontendCompilation.hx:601 and :1505), no interned Name type exists, and tests/driver/TestRunner.hx:166 (warmEditKnownFailures) references the helper-ownership note. Keep them as live design notes.
- docs/PROVIDER_REQUESTS.md is explicitly marked 'superseded ... kept for the reasoning' (line 3) and is cited by REACHABILITY_WALK.md. It belongs in docs/history rather than deletion, because it records why HelperRequest records were implemented and then removed.
- Rejected-experiment reports (BOUNDS_CHECK_ELIMINATION.md, FASTA_PROFILE.md, BYTES_ACCESS_PROFILE.md, JIT_ALLOCATION_INITIALIZATION.md, the GC experiments in GC_PROFILE.md): they record measured no-go decisions with gates and numbers, which stops the same optimization being retried. Relocate them to reports/; do not delete them.
- PROFILER.md versus PROFILING.md is an intentional design/usage split, stated at PROFILER.md:5-7 and PROFILING.md:3, with ADR 0001 for the decision. The split is sound; only the names are confusable.
- LANGUAGE_ROADMAP.md versus ROADMAP.md: these are different scopes by design (ROADMAP.md:7-9 delegates language features to LANGUAGE_ROADMAP and current support to LANGUAGE_SUPPORT). Keep the three-way split; only the duplicated gap list needs a single owner.
- TODO.md mentions other projects (Materia, Beartooth, NativeKit ADR numbers). It looks out of place, but it records concrete consumer-driven requirements with design constraints (event signal type, nk_http_server, BLAKE3, shader reflection generator) that appear nowhere else.
- ROADMAP.md:85 'ten paired programs' and the references to tests/fixtures/pragtical, tests/hxml/plugin-test.hxml and scripts/haxeon-lsp were all verified to exist and match (tests/differential has 10 .official/.realtime pairs).
- docs/history/ui-value-types-2026-11.md is 3,227 lines, the largest file in the scope. It is an archived checkpoint log already moved out of the live docs, so its size is harmless.
- README.md:38-44 (the stdout flushing paragraph at the top of Quick start) reads oddly placed, but that is prose and placement, not accuracy; it was not verified against the runtime and is not reported as a finding.
- NOTICE (6 lines) is consistent with README.md:199-203 and with stdlib/LICENSE and stdlib/UPSTREAM.md, which exist.

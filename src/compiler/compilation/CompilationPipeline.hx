package compiler.compilation;

import compiler.syntax.Ast;
import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstFunction;
import compiler.syntax.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.syntax.Lexer;
import compiler.syntax.Parser;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrGenerator;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.semantic.SemanticSignature;
import compiler.semantic.GenericSpecializationRegistry;
import compiler.semantic.SemanticProgram;
import compiler.types.TypedAst.TypedProgram;
import compiler.hl.HlCode;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.patch.HlPatchWriter;
import compiler.hl.persistence.HlRuntimeIdentity;
import compiler.hl.persistence.HlAssemblerStateCodec;
import haxe.io.Bytes;
import compiler.types.Type.CompilerType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.types.TypeRegistry;
import compiler.types.TypeRegistry.TypeCompatibility;
import compiler.service.CancellationToken;
import compiler.abi.RuntimeAbi;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.runtime.NativeRegistry;
import compiler.runtime.NativeRegistry.NativeDefinition;
import compiler.compilation.CompilerPublication.CompilerSnapshot;
import compiler.compilation.CompilerPublication.PublicationStatus;
import compiler.compilation.CompilerPublication.ReconnectDecision;
import compiler.compilation.CompilerPublication.ReconnectReason;
import compiler.modules.ModuleGraph;
import compiler.modules.ModulePath;
import compiler.modules.ModuleReachability;
import compiler.modules.ModuleState;
import compiler.modules.ModuleState.SemanticDependency;
import compiler.modules.ModuleState.SemanticDependencyKind;
import compiler.semantic.ModuleCanonicalizer;
import compiler.semantic.ModuleChangeAnalyzer;
import compiler.semantic.DependencyScanner;
import compiler.semantic.LambdaCollector;
import compiler.semantic.SemanticDependencyCollector;
import compiler.semantic.SemanticWorkspace;
import compiler.Compiler.CompileResult;

/** Executes the mutable frontend, IR, ABI-planning, and backend candidate phases. */
class CompilationPipeline {
	/**
	 * Writes why an incremental compile redid its work to the compiler's standard error (the worker's log): how many artifacts
	 * each kind of invalidation selected, a sample of them, and how many functions were retyped and regenerated. An edit that
	 * retypes far more than it should shows up here as one kind of invalidation with a large count. Enabled by
	 * `HAXEON_EXPLAIN_INVALIDATION`; see docs/PROFILING.md.
	 */
	static function explainInvalidation(invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>, retyped:Array<String>,
			regenerated:Array<String>):Void {
		var counts:Map<String, Int> = [];
		for (artifact in invalidations) {
			var reason = artifact.reasons[0],
				key = Std.string(reason.kind) + (reason.via == null ? "" : " via " + reason.via);
			counts.set(key, (counts.exists(key) ? counts.get(key) : 0) + 1);
		}
		Sys.stderr().writeString("invalidation: " + invalidations.length + " artifacts, retyped " + retyped.length + "\n");
		Sys.stderr().writeString("  regenerated " + regenerated.length + ": " + regenerated.slice(0, 6) + "\n");
		for (key => count in counts)
			Sys.stderr().writeString("  " + count + " " + key + "\n");
		for (artifact in invalidations.slice(0, 12))
			Sys.stderr().writeString("  e.g. " + artifact.artifact + " <- " + artifact.reasons[0].kind + " " + artifact.reasons[0].cause + "\n");
	}

	public static function compile(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			transactionStartedAt:Float, snapshotDoneAt:Float, frontendStartedAt:Float, ?indexSemantics = true,
			?publicationBaseline:compiler.compilation.CompilerPublication.PublishedBaseline):CompileResult {
		var frontend = FrontendCompilation.run(context, entryModule, token, rollbackModules, frontendStartedAt, true, indexSemantics);
		var modules = context.modules, moduleId = context.moduleId;
		var ir = frontend.ir,
			names = frontend.moduleNames,
			typedNew = frontend.typedProgram;
		if (ir == null)
			throw "Build frontend did not produce IR";
		var retyped = frontend.retyped,
			regenerated = frontend.regenerated,
			typerMetrics = frontend.typerMetrics;
		var frontendDoneAt = frontend.frontendDoneAt,
			frontendGraphDoneAt = frontend.frontendGraphDoneAt,
			typingLoweringDoneAt = frontend.typingLoweringDoneAt,
			irAssemblyDoneAt = frontend.irAssemblyDoneAt;
		// A build whose pipeline inputs equal the last plain build's reuses its module too, unless HAXEON_CHECK_REUSE=1 assembles
		// it again to compare.
		var backendKey = BackendAssembly.environmentKey(context),
			reusedFrom = frontend.reused,
			previousBackend = reusedFrom != null
				&& reusedFrom.backend != null
				&& reusedFrom.backendEnvironment == backendKey ? reusedFrom.backend : null,
			checkingReuse = Sys.getEnv("HAXEON_CHECK_REUSE") == "1",
			backendReused = previousBackend != null && !checkingReuse,
			backend = backendReused ? BackendAssembly.reused(previousBackend,
				irAssemblyDoneAt) : BackendAssembly.assemble(context, ir, regenerated, frontend.relocated, token);
		if (previousBackend != null && checkingReuse) {
			var difference = BackendAssembly.difference(previousBackend, backend);
			if (difference != null)
				throw 'HAXEON_CHECK_REUSE: the module reused for equal pipeline inputs differs from a fresh assembly ($difference)';
		}
		var snapshot = context.pipelineSnapshot;
		if (snapshot != null && !backendReused) {
			// A new object: the one in the compiler is the last successful build's, and a build that fails must leave it as it is.
			var next = new PipelineSnapshot(snapshot.inputs, snapshot.ir);
			next.backend = backend;
			next.backendEnvironment = backendKey;
			context.pipelineSnapshot = next;
		}
		var nextAbi = backend.abi,
			reloadReasons = backend.reloadReasons,
			candidateAssembler = backend.assembler,
			assembly = backend.assembly;
		var patchBytes = backend.patchBytes,
			abiPlanningDoneAt = backend.abiPlanningDoneAt,
			backendAssemblyDoneAt = backend.backendAssemblyDoneAt,
			patchEncodingDoneAt = backend.patchEncodingDoneAt;
		var allocationBeforeFinalize = AllocationMeter.sample();
		context.setLastTypedProgram(typedNew);
		context.publishedAbi = nextAbi;
		context.assembler = candidateAssembler;
		context.clearRehydrationBaseline();
		for (name in names) {
			var state:compiler.modules.ModuleState = modules.get(name);
			if (state.lastGoodRevision != state.revision) {
				state = context.writableState(name, rollbackModules);
				state.lastGoodTokens = state.tokens;
				state.lastGoodAst = state.ast;
				state.lastGoodSemanticModel = state.semanticModel;
				state.lastGoodSource = state.source;
				state.lastGoodRevision = state.revision;
			}
		}
		context.compiledOnce = true;
		var finishedAt = Sys.time() * 1000.0;
		var invalidationReasonCount = 0;
		for (artifact in frontend.invalidations)
			invalidationReasonCount += artifact.reasons.length;
		if (Sys.getEnv("HAXEON_EXPLAIN_INVALIDATION") != null)
			explainInvalidation(frontend.invalidations, retyped, regenerated);
		var allocationPhases = frontend.allocationPhases.concat(backend.allocationPhases);
		allocationPhases.push(AllocationMeter.delta("finalize", allocationBeforeFinalize, AllocationMeter.sample()));
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			invalidations: frontend.invalidations,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			reloadReasons: reloadReasons,
			functionIndices: CompilationContext.copyIndices(assembly.functionIndices),
			functionIds: CompilationContext.copyIndices(candidateAssembler.cache.stableIds),
			moduleNames: names,
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.revision, assembly.functionIndices, candidateAssembler.cache.stableIds),
			unchanged: assembly.unchanged
			&& (publicationBaseline == null
				|| (publicationBaseline.backendAvailable && publicationBaseline.revision == assembly.revision)),
			baseRevision: publicationBaseline == null ? assembly.baseRevision : publicationBaseline.revision,
			revision: assembly.revision,
			patchBytes: patchBytes,
			metrics: {
				allocationPhases: allocationPhases,
				elapsedMs: finishedAt - transactionStartedAt,
				transactionSnapshotMs: snapshotDoneAt - transactionStartedAt,
				candidateSetupMs: frontendStartedAt - snapshotDoneAt,
				frontendMs: frontendDoneAt - frontendStartedAt,
				frontendGraphMs: frontendGraphDoneAt - frontendStartedAt,
				graphParseMs: frontend.graphParseMs,
				graphDependencyMs: frontend.graphDependencyMs,
				graphInitializationMs: frontend.graphInitializationMs,
				frontendRestarts: frontend.frontendRestarts,
				frontendPassFunctions: frontend.frontendPassFunctions,
				frontendPassReports: frontend.frontendPassReports,
				semanticAssemblyMs: frontendDoneAt - frontendGraphDoneAt,
				semanticAliasMs: frontend.semanticAliasMs,
				semanticCanonicalizationMs: frontend.semanticCanonicalizationMs,
				semanticContributionReuseMs: frontend.semanticContributionReuseMs,
				semanticContributionRebuildMs: frontend.semanticContributionRebuildMs,
				semanticInvalidationMs: frontend.semanticInvalidationMs,
				semanticAllocatedBytes: frontend.semanticAllocatedBytes,
				typingLoweringMs: typingLoweringDoneAt - frontendDoneAt,
				declarationMs: typerMetrics.declarationMs,
				shapeConnectionMs: typerMetrics.shapeConnectionMs,
				signatureTypingMs: typerMetrics.signatureTypingMs,
				typerSetupMs: typerMetrics.setupMs,
				typerNoReturnMs: typerMetrics.noReturnMs,
				typerMetadataMs: typerMetrics.metadataMs,
				typerBodiesMs: typerMetrics.bodiesMs,
				bodyTransitionMs: typerMetrics.bodyTransitionMs,
				typerAssemblyMs: typerMetrics.assemblyMs,
				finalizationTransitionMs: typerMetrics.finalizationMs,
				irAssemblyMs: irAssemblyDoneAt - typingLoweringDoneAt,
				abiPlanningMs: abiPlanningDoneAt - irAssemblyDoneAt,
				backendAssemblyMs: backendAssemblyDoneAt - abiPlanningDoneAt,
				backendAssemblerCopyMs: backend.assemblerCopyMs,
				backendCachePreparationMs: backendReused ? 0.0 : assembly.cachePreparationMs,
				backendLoweringMs: backendReused ? 0.0 : assembly.loweringMs,
				backendPublicationMs: backendReused ? 0.0 : assembly.publicationMs,
				backendSnapshotMs: backend.snapshotAttachmentMs,
				backendVerificationMs: backendReused ? 0.0 : assembly.verificationMs,
				backendMetadataMs: backendReused ? 0.0 : assembly.metadataMs,
				backendFunctionLoweringMs: backendReused ? 0.0 : assembly.functionLoweringMs,
				backendDebugAssemblyMs: backendReused ? 0.0 : assembly.debugAssemblyMs,
				backendFinalizationMs: backendReused ? 0.0 : assembly.lowerFinalizationMs,
				patchEncodingMs: patchEncodingDoneAt - backendAssemblyDoneAt,
				finalizeMs: finishedAt - patchEncodingDoneAt,
				modules: names.length,
				retypedFunctions: retyped.length,
				invalidatedArtifacts: frontend.invalidations.length,
				invalidationReasons: invalidationReasonCount,
				regeneratedFunctions: regenerated.length,
				changedFunctions: assembly.changedFunctions.length,
				moduleFunctions: assembly.module.functions.length,
				moduleNatives: assembly.module.natives.length,
				patchBytes: patchBytes == null ? 0 : patchBytes.length,
				reuse: reusedFrom == null ? "none (" + frontend.reuseMiss + ")" : backendReused ? "ir+module" : "ir",
				linkedFunctions: backendReused ? 0 : candidateAssembler.reusedFunctions,
				movedFunctions: backendReused ? 0 : candidateAssembler.movedFunctions
			}
		};
	}
}

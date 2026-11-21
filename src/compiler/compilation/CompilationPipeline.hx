package compiler.compilation;

import compiler.Compiler.CompileResult;
import compiler.core.AllocationMeter;
import compiler.core.CancellationToken;
import compiler.core.InternalError;
import compiler.ir.Ir.IrType;
import compiler.modules.ModuleState;
import compiler.types.TypeRegistry;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;

/** Executes the mutable frontend, IR, ABI-planning, and backend candidate phases. */
class CompilationPipeline {
	/**
	 * Writes why an incremental compile redid its work to the compiler's standard error (the worker's log): how many artifacts
	 * each kind of invalidation selected, a sample of them, and how many functions were retyped and regenerated. An edit that
	 * retypes far more than it should shows up here as one kind of invalidation with a large count. Enabled by
	 * `HAXEON_EXPLAIN_INVALIDATION`; see docs/reference/PROFILING.md.
	 */
	static function explainInvalidation(invalidations:Array<compiler.semantic.Invalidation.InvalidatedArtifact>,
			retyped:Array<String>,
			regenerated:Array<String>):Void {
		var counts:Map<String, Int> = [];
		for (artifact in invalidations) {
			var reason = artifact.reasons[0],
				key = Std.string(reason.kind) + (reason.via == null ? "" : " via " + reason.via);
			counts.set(key, (counts.exists(key) ? counts.get(key) : 0) + 1);
		}
		Sys.stderr().writeString("invalidation: " + invalidations.length + " artifacts, retyped " + retyped.length
			+ "\n");
		Sys.stderr().writeString("  regenerated " + regenerated.length + ": " + regenerated.slice(0, 6) + "\n");
		for (key => count in counts)
			Sys.stderr().writeString("  " + count + " " + key + "\n");
		for (artifact in invalidations.slice(0, 12))
			Sys.stderr().writeString("  e.g. " + artifact.artifact + " <- " + artifact.reasons[0].kind + " "
				+ artifact.reasons[0].cause + "\n");
	}

	public static function compile(context:CompilationContext, entryModule:String, token:Null<CancellationToken>,
			rollbackModules:Map<String, ModuleState>,
			transactionStartedAt:Float, snapshotDoneAt:Float, frontendStartedAt:Float, ?indexSemantics = true,
			?publicationBaseline:compiler.compilation.CompilerPublication.PublishedBaseline):CompileResult {
		var frontend = FrontendCompilation.run(context, entryModule, token, rollbackModules, frontendStartedAt, true,
			indexSemantics);
		var modules = context.state.modules;
		var ir = frontend.ir,
			names = frontend.moduleNames,
			typedNew = frontend.typedProgram;
		if (ir == null)
			throw new InternalError("Build frontend did not produce IR");
		var retyped = frontend.retyped,
			regenerated = frontend.regenerated,
			typerMetrics = frontend.typerMetrics;
		var frontendDoneAt = frontend.frontendDoneAt,
			frontendGraphDoneAt = frontend.frontendGraphDoneAt,
			typingLoweringDoneAt = frontend.typingLoweringDoneAt,
			irAssemblyDoneAt = frontend.irAssemblyDoneAt;
		// A build whose pipeline inputs equal the last plain build's reuses its module too, unless the compile checks its reuse
		// (`CompileOptions.checkReuse`) and assembles it again to compare.
		var session = context.state.backend,
			backendKey = session.environmentKey(context),
			reusedFrom = frontend.reused,
			previousBackend = reusedFrom != null
				&& reusedFrom.backend != null
				&& reusedFrom.backendEnvironment == backendKey ? reusedFrom.backend : null,
			checkingReuse = context.options.checkReuse,
			backendReused = previousBackend != null && !checkingReuse;
		// A compile that keeps no session has let the typed program go once the IR tables were assembled.
		if (typedNew == null && context.options.keepSession)
			throw new InternalError("Build frontend did not produce a typed program");
		var nativeTypeDescriptors = frontend.nativeTypeDescriptors;
		// A compile that keeps no session needs only the final IR from here on.
		if (!context.options.keepSession) {
			frontend.typedProgram = null;
			typedNew = null;
			context.state.releaseRetained();
		}
		var backend = backendReused ? session.reuse(previousBackend,
			irAssemblyDoneAt) : session.assemble(context, ir, regenerated, frontend.relocated, token);
		if (previousBackend != null && checkingReuse) {
			var difference = session.difference(previousBackend, backend);
			if (difference != null)
				throw new InternalError('--check-reuse: the module reused for equal pipeline inputs differs from a fresh assembly ($difference)');
		}
		var snapshot = context.state.pipelineSnapshot;
		if (snapshot != null && !backendReused) {
			// A new object: the one in the compiler is the last successful build's, and a build that fails must leave it as it is.
			var next = new PipelineSnapshot(snapshot.inputs, snapshot.ir);
			next.backend = backend;
			next.backendEnvironment = backendKey;
			context.state.pipelineSnapshot = next;
		}
		var nextAbi = backend.abi,
			reloadReasons = backend.reloadReasons,
			timings = backend.timings;
		var abiPlanningDoneAt = backend.abiPlanningDoneAt,
			backendAssemblyDoneAt = backend.backendAssemblyDoneAt,
			patchEncodingDoneAt = backend.patchEncodingDoneAt;
		var allocationBeforeFinalize = AllocationMeter.sample();
		context.state.lastTypedProgram = typedNew;
		context.state.publishedAbi = nextAbi;
		context.state.rehydrationBaseline = null;
		for (name in names) {
			var state:compiler.modules.ModuleState = modules.get(name);
			if (state.lastGoodRevision != state.revision) {
				state = context.state.writableState(name, rollbackModules);
				state.lastGoodTokens = state.tokens;
				state.lastGoodAst = state.ast;
				state.lastGoodSemanticModel = state.semanticModel;
				state.lastGoodSource = state.source;
				state.lastGoodRevision = state.revision;
			}
		}
		context.state.compiledOnce = true;
		var finishedAt = Sys.time() * 1000.0;
		var invalidationReasonCount = 0;
		for (artifact in frontend.invalidations)
			invalidationReasonCount += artifact.reasons.length;
		if (Sys.getEnv("HAXEON_EXPLAIN_INVALIDATION") != null)
			explainInvalidation(frontend.invalidations, retyped, regenerated);
		var allocationPhases = frontend.allocationPhases.concat(backend.allocationPhases),
			patchSize = switch backend.artifact {
				case HashLinkBuild(build):
					var patch = build.patchBytes;
					patch == null ? 0 : patch.length;
				case WasmBuild(_) | HashLinkCBuild(_): 0;
			};
		allocationPhases.push(AllocationMeter.delta("finalize", allocationBeforeFinalize, AllocationMeter.sample()));
		return {
			ir: ir,
			artifact: backend.artifact,
			retyped: retyped,
			invalidations: frontend.invalidations,
			regenerated: regenerated,
			changedFunctions: backend.changedFunctions,
			requiresReload: backend.requiresReload,
			reloadReasons: reloadReasons,
			moduleNames: names,
			nativeTypeDescriptors: nativeTypeDescriptors,
			unchanged: backend.unchanged
				&& (publicationBaseline == null
				|| (publicationBaseline.backendAvailable && publicationBaseline.revision == backend.revision)),
			baseRevision: publicationBaseline == null ? backend.baseRevision : publicationBaseline.revision,
			revision: backend.revision,
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
				irPassCosts: frontend.irPassCosts,
				semanticAssemblyMs: frontendDoneAt - frontendGraphDoneAt,
				semanticAliasMs: frontend.semanticAliasMs,
				semanticCanonicalizationMs: frontend.semanticCanonicalizationMs,
				semanticContributionReuseMs: frontend.semanticContributionReuseMs,
				semanticContributionRebuildMs: frontend.semanticContributionRebuildMs,
				semanticInvalidationMs: frontend.semanticInvalidationMs,
				semanticAllocatedBytes: frontend.semanticAllocatedBytes,
				typingLoweringMs: typingLoweringDoneAt - frontendDoneAt,
				analysisMs: frontend.analysisMs,
				declarationMs: typerMetrics.declarationMs,
				shapeConnectionMs: typerMetrics.shapeConnectionMs,
				signatureTypingMs: typerMetrics.signatureTypingMs,
				typerSetupMs: typerMetrics.setupMs,
				typerNoReturnMs: typerMetrics.noReturnMs,
				typerMetadataMs: typerMetrics.metadataMs,
				typerClassBodiesMs: typerMetrics.classBodiesMs,
				typerFunctionBodiesMs: typerMetrics.functionBodiesMs,
				typerGeneratedMs: typerMetrics.generatedMs,
				bodyTransitionMs: typerMetrics.bodyTransitionMs,
				typerAssemblyMs: typerMetrics.assemblyMs,
				finalizationTransitionMs: typerMetrics.finalizationMs,
				irGenerationMs: frontend.irGenerationMs,
				irAssemblyMs: irAssemblyDoneAt - typingLoweringDoneAt,
				abiPlanningMs: abiPlanningDoneAt - irAssemblyDoneAt,
				backendAssemblyMs: backendAssemblyDoneAt - abiPlanningDoneAt,
				backendAssemblerCopyMs: backend.assemblerCopyMs,
				backendCachePreparationMs: timings.cachePreparationMs,
				backendLoweringMs: timings.loweringMs,
				backendPublicationMs: timings.publicationMs,
				backendSnapshotMs: backend.snapshotAttachmentMs,
				backendVerificationMs: timings.verificationMs,
				backendMetadataMs: timings.metadataMs,
				backendFunctionLoweringMs: timings.functionLoweringMs,
				backendDebugAssemblyMs: timings.debugAssemblyMs,
				backendFinalizationMs: timings.lowerFinalizationMs,
				patchEncodingMs: patchEncodingDoneAt - backendAssemblyDoneAt,
				finalizeMs: finishedAt - patchEncodingDoneAt,
				modules: names.length,
				retypedFunctions: retyped.length,
				invalidatedArtifacts: frontend.invalidations.length,
				invalidationReasons: invalidationReasonCount,
				regeneratedFunctions: regenerated.length,
				changedFunctions: backend.changedFunctions.length,
				moduleFunctions: backend.moduleFunctions,
				moduleNatives: backend.moduleNatives,
				patchBytes: patchSize,
				reuse: reusedFrom == null ? "none (" + frontend.reuseMiss + ")" : backendReused ? "ir+module" : "ir",
				linkedFunctions: backend.linkedFunctions,
				movedFunctions: backend.movedFunctions
			}
		};
	}
}

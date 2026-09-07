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
	public static function compile(context:CompilationContext, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			transactionStartedAt:Float, snapshotDoneAt:Float, ?indexSemantics = true):CompileResult {
		var frontend = FrontendCompilation.run(context, entryModule, token, rollbackModules, snapshotDoneAt, true, indexSemantics);
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
			typingLoweringDoneAt = frontend.typingLoweringDoneAt,
			irAssemblyDoneAt = frontend.irAssemblyDoneAt;
		var backend = BackendAssembly.assemble(context, ir, regenerated, token);
		var nextAbi = backend.abi,
			reloadReasons = backend.reloadReasons,
			candidateAssembler = backend.assembler,
			assembly = backend.assembly;
		var patchBytes = backend.patchBytes,
			abiPlanningDoneAt = backend.abiPlanningDoneAt,
			backendAssemblyDoneAt = backend.backendAssemblyDoneAt,
			patchEncodingDoneAt = backend.patchEncodingDoneAt;
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
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.revision, assembly.functionIndices, candidateAssembler.cache.stableIds),
			revision: assembly.revision,
			patchBytes: patchBytes,
			metrics: {
				elapsedMs: finishedAt - transactionStartedAt,
				transactionSnapshotMs: snapshotDoneAt - transactionStartedAt,
				frontendMs: frontendDoneAt - snapshotDoneAt,
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
				patchBytes: patchBytes == null ? 0 : patchBytes.length
			}
		};
	}
}

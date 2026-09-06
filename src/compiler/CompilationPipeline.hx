package compiler;

import compiler.Ast;
import compiler.Ast.AstExpression;
import compiler.Ast.AstFunction;
import compiler.Ast.AstStatement;
import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Lexer;
import compiler.Parser;
import compiler.Source.SourceFile;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.IrGenerator;
import compiler.types.FieldInference;
import compiler.types.SignatureInference;
import compiler.types.Typer;
import compiler.types.Typer.TyperPhaseMetrics;
import compiler.types.SemanticSignature;
import compiler.types.GenericSpecializationRegistry;
import compiler.types.SemanticProgram;
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
import compiler.abi.NativeRegistry;
import compiler.abi.NativeRegistry.NativeDefinition;
import compiler.CompilerPublication.CompilerSnapshot;
import compiler.CompilerPublication.PublicationStatus;
import compiler.CompilerPublication.ReconnectDecision;
import compiler.CompilerPublication.ReconnectReason;
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
	public static function compile(compiler:Compiler, entryModule:String, token:Null<CancellationToken>, rollbackModules:Map<String, ModuleState>,
			transactionStartedAt:Float, snapshotDoneAt:Float):CompileResult {
		var frontend = ModuleFrontendPipeline.run(compiler, entryModule, token, rollbackModules, snapshotDoneAt);
		var modules = compiler.modules, moduleId = compiler.moduleId;
		var ir = frontend.ir,
			names = frontend.moduleNames,
			typedNew = frontend.typedProgram;
		var retyped = frontend.retyped,
			regenerated = frontend.regenerated,
			typerMetrics = frontend.typerMetrics;
		var frontendDoneAt = frontend.frontendDoneAt,
			typingLoweringDoneAt = frontend.typingLoweringDoneAt,
			irAssemblyDoneAt = frontend.irAssemblyDoneAt;
		var backend = BackendAssembly.assemble(compiler, ir, regenerated, token);
		var nextAbi = backend.abi,
			reloadReasons = backend.reloadReasons,
			candidateAssembler = backend.assembler,
			assembly = backend.assembly;
		var patchBytes = backend.patchBytes,
			abiPlanningDoneAt = backend.abiPlanningDoneAt,
			backendAssemblyDoneAt = backend.backendAssemblyDoneAt,
			patchEncodingDoneAt = backend.patchEncodingDoneAt;
		compiler.lastTypedProgram = typedNew;
		compiler.publishedAbi = nextAbi;
		compiler.assembler = candidateAssembler;
		compiler.rehydrationBaseline = null;
		for (name in names) {
			var state = modules.get(name);
			if (state.lastGoodRevision != state.revision) {
				state = compiler.writableState(name, rollbackModules);
				state.lastGoodTokens = state.tokens;
				state.lastGoodAst = state.ast;
				state.lastGoodSemanticModel = state.semanticModel;
				state.lastGoodSource = state.source;
				state.lastGoodRevision = state.revision;
			}
		}
		compiler.compiledOnce = true;
		var finishedAt = Sys.time() * 1000.0;
		return {
			ir: ir,
			module: assembly.module,
			retyped: retyped,
			regenerated: regenerated,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			reloadReasons: reloadReasons,
			functionIndices: Compiler.copyIndices(assembly.functionIndices),
			functionIds: Compiler.copyIndices(candidateAssembler.cache.stableIds),
			runtimeIdentity: HlRuntimeIdentity.encode(moduleId, assembly.revision, assembly.functionIndices, candidateAssembler.cache.stableIds),
			revision: assembly.revision,
			patchBytes: patchBytes,
			metrics: {
				elapsedMs: finishedAt - transactionStartedAt,
				transactionSnapshotMs: snapshotDoneAt - transactionStartedAt,
				frontendMs: frontendDoneAt - snapshotDoneAt,
				typingLoweringMs: typingLoweringDoneAt - frontendDoneAt,
				typerSetupMs: typerMetrics.setupMs,
				typerNoReturnMs: typerMetrics.noReturnMs,
				typerMetadataMs: typerMetrics.metadataMs,
				typerBodiesMs: typerMetrics.bodiesMs,
				typerAssemblyMs: typerMetrics.assemblyMs,
				irAssemblyMs: irAssemblyDoneAt - typingLoweringDoneAt,
				abiPlanningMs: abiPlanningDoneAt - irAssemblyDoneAt,
				backendAssemblyMs: backendAssemblyDoneAt - abiPlanningDoneAt,
				patchEncodingMs: patchEncodingDoneAt - backendAssemblyDoneAt,
				finalizeMs: finishedAt - patchEncodingDoneAt,
				modules: names.length,
				retypedFunctions: retyped.length,
				regeneratedFunctions: regenerated.length,
				changedFunctions: assembly.changedFunctions.length,
				moduleFunctions: assembly.module.functions.length,
				moduleNatives: assembly.module.natives.length,
				patchBytes: patchBytes == null ? 0 : patchBytes.length
			}
		};
	}
}

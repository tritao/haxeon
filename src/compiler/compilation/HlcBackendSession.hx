package compiler.compilation;

import compiler.abi.RuntimeAbi;
import compiler.backend.Backend.BackendTarget;
import compiler.backend.c.HlcModule;
import compiler.compilation.BackendArtifact;
import compiler.compilation.BackendSession.BackendAssemblyResult;
import compiler.compilation.BackendSession.BackendTimings;
import compiler.core.AllocationMeter;
import compiler.core.CancellationToken;
import compiler.hl.incremental.HlPlainBuild;
import compiler.ir.Ir.IrProgram;

/**
 * The C backend of a compilation session (`--target=hlc`, docs/design/AOT_BACKEND.md). A build assembles the program as a
 * plain HashLink build does, which decides every type, layout, global and slot the runtime sees, then lowers the program that
 * assembly lowered to C against the same symbol table. Nothing is kept between builds yet: each build is revision 1 of a fresh
 * program, and a C build is made incremental by the files it leaves unchanged, not by reuse in the session.
 */
class HlcBackendSession implements BackendSession {
	public function new() {}

	public function backendTarget():BackendTarget
		return HashLinkC;

	public function hashLink():Null<HashLinkBackendSession>
		return null;

	public function wasm():Null<WasmBackendSession>
		return null;

	public function forCandidate():BackendSession
		return new HlcBackendSession();

	public function environmentKey(context:CompilationContext):String
		return "hlc:" + context.options.key();

	public function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>,
			relocated:Array<String>,
			token:Null<CancellationToken>):BackendAssemblyResult {
		var allocationAtStart = AllocationMeter.sample();
		var abi = RuntimeAbi.describe(ir), abiPlanningDoneAt = Sys.time() * 1000.0;
		var allocationAfterAbi = AllocationMeter.sample();
		var plain = HlPlainBuild.reachable(ir, context.options.checkReuse).program,
			assembler = HlPlainBuild.assembler(false);
		assembler.keepsProgram = true;
		var assembly = assembler.assemble(plain, [for (fn in plain.functions) fn.name], Patch);
		var assembledAt = Sys.time() * 1000.0, allocationAfterAssembly = AllocationMeter.sample();
		if (token != null)
			token.check();
		var program = assembler.lastProgram;
		if (program == null)
			throw new compiler.core.InternalError("The HashLink assembly kept no program for the C backend");
		var files = new HlcModule(assembly.module, assembler.symbols, program, assembly.functionIndices,
			context.options.inlineAllocation).emit();
		var builtAt = Sys.time() * 1000.0;
		return {
			artifact: HashLinkCBuild({files: files}),
			assembler: null,
			abi: abi,
			reloadReasons: [],
			changedFunctions: [],
			requiresReload: false,
			unchanged: false,
			baseRevision: 0,
			revision: 1,
			moduleFunctions: assembly.module.functions.length,
			moduleNatives: assembly.module.natives.length,
			linkedFunctions: 0,
			movedFunctions: 0,
			timings: {
				cachePreparationMs: assembly.cachePreparationMs,
				loweringMs: assembly.loweringMs,
				publicationMs: builtAt - assembledAt,
				verificationMs: assembly.verificationMs,
				metadataMs: assembly.metadataMs,
				functionLoweringMs: assembly.functionLoweringMs,
				debugAssemblyMs: 0.0,
				lowerFinalizationMs: assembly.lowerFinalizationMs
			},
			abiPlanningDoneAt: abiPlanningDoneAt,
			backendAssemblyDoneAt: builtAt,
			patchEncodingDoneAt: builtAt,
			assemblerCopyMs: 0.0,
			snapshotAttachmentMs: 0.0,
			allocationPhases: [
				AllocationMeter.delta("abi", allocationAtStart, allocationAfterAbi),
				AllocationMeter.delta("backend-assembly", allocationAfterAbi, allocationAfterAssembly),
				AllocationMeter.delta("c-lowering", allocationAfterAssembly, AllocationMeter.sample())
			].concat(assembly.allocationPhases)
		};
	}

	/** The last build's result for a build with its inputs: the same C sources. */
	public function reuse(previous:BackendAssemblyResult, at:Float):BackendAssemblyResult
		return {
			artifact: previous.artifact,
			assembler: null,
			abi: previous.abi,
			reloadReasons: [],
			changedFunctions: [],
			requiresReload: false,
			unchanged: true,
			baseRevision: previous.baseRevision,
			revision: previous.revision,
			moduleFunctions: previous.moduleFunctions,
			moduleNatives: previous.moduleNatives,
			linkedFunctions: 0,
			movedFunctions: 0,
			timings: noTimings,
			abiPlanningDoneAt: at,
			backendAssemblyDoneAt: at,
			patchEncodingDoneAt: at,
			assemblerCopyMs: 0.0,
			snapshotAttachmentMs: 0.0,
			allocationPhases: []
		};

	public function difference(previous:BackendAssemblyResult, fresh:BackendAssemblyResult):Null<String> {
		var left = BackendArtifacts.c(previous.artifact).files, right = BackendArtifacts.c(fresh.artifact).files;
		if (left.length != right.length)
			return "C file count " + left.length + " -> " + right.length;
		for (index in 0...left.length)
			if (left[index].path != right[index].path || left[index].content != right[index].content)
				return "C file " + right[index].path + " differs";
		return null;
	}

	static final noTimings:BackendTimings = {
		cachePreparationMs: 0.0,
		loweringMs: 0.0,
		publicationMs: 0.0,
		verificationMs: 0.0,
		metadataMs: 0.0,
		functionLoweringMs: 0.0,
		debugAssemblyMs: 0.0,
		lowerFinalizationMs: 0.0
	};
}

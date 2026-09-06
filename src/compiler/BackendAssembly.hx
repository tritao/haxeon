package compiler;

import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.abi.RuntimeAbi;
import compiler.abi.RuntimeAbi.RuntimeAbiDescriptor;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.incremental.HlModuleAssembler.HlAssemblyResult;
import compiler.hl.patch.HlPatchWriter;
import compiler.ir.Ir.IrProgram;
import compiler.service.CancellationToken;
import haxe.io.Bytes;

typedef BackendAssemblyResult = {
	final assembly:HlAssemblyResult;
	final assembler:HlModuleAssembler;
	final abi:RuntimeAbiDescriptor;
	final reloadReasons:Array<AbiChange>;
	final patchBytes:Null<Bytes>;
	final abiPlanningDoneAt:Float;
	final backendAssemblyDoneAt:Float;
	final patchEncodingDoneAt:Float;
}

/** Plans and assembles one IR candidate for the HashLink backend. */
class BackendAssembly {
	public static function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>, token:Null<CancellationToken>):BackendAssemblyResult {
		var nextAbi = RuntimeAbi.describe(ir),
			decision = PatchPlanner.plan(context.publishedAbi, nextAbi),
			reloadReasons:Array<AbiChange> = switch decision {
				case Patch: [];
				case ReloadDomain(reasons): reasons;
				case Reject(diagnostics): throw diagnostics.join("; ");
			};
		reloadReasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		if (reloadReasons.length > 0)
			decision = ReloadDomain(reloadReasons);
		var abiPlanningDoneAt = Sys.time() * 1000.0;
		var candidateAssembler = context.compiledOnce
			&& PatchPlanner.requiresFreshLayout(decision) ? new HlModuleAssembler(CompilationContext.copyIndices(context.assembler.cache.stableIds)) : context.assembler.copy();
		var assembly = candidateAssembler.assemble(ir, context.rehydratedChanges(regenerated, ir), decision);
		var backendAssemblyDoneAt = Sys.time() * 1000.0;
		if (token != null)
			token.check();
		var patchBytes = reloadReasons.length > 0
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, context.moduleId, assembly.changedSlots,
				context.stableIdsBySlot(candidateAssembler, assembly.functionIndices), assembly.revision - 1, assembly.revision, assembly.baseInts,
				assembly.baseFloats, assembly.baseStrings, assembly.baseTypes);
		return {
			assembly: assembly,
			assembler: candidateAssembler,
			abi: nextAbi,
			reloadReasons: reloadReasons,
			patchBytes: patchBytes,
			abiPlanningDoneAt: abiPlanningDoneAt,
			backendAssemblyDoneAt: backendAssemblyDoneAt,
			patchEncodingDoneAt: Sys.time() * 1000.0
		};
	}
}

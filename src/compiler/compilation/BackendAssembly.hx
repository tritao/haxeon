package compiler.compilation;

import compiler.abi.LambdaAlignment;
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
import compiler.hl.HlCode;
import compiler.hl.HlWriter;
import compiler.compilation.AllocationMeter.PhaseAllocation;

typedef BackendAssemblyResult = {
	final assembly:HlAssemblyResult;
	final assembler:HlModuleAssembler;
	final abi:RuntimeAbiDescriptor;
	final reloadReasons:Array<AbiChange>;
	final patchBytes:Null<Bytes>;
	final abiPlanningDoneAt:Float;
	final backendAssemblyDoneAt:Float;
	final patchEncodingDoneAt:Float;
	final assemblerCopyMs:Float;
	final snapshotAttachmentMs:Float;
	final allocationPhases:Array<PhaseAllocation>;
}

/** Plans and assembles one IR candidate for the HashLink backend. */
class BackendAssembly {
	/**
	 * Reserved slots a live HashLink build gives each object (see `HlLower.reservedSlots`): how many fields a session can
	 * add to one class before the edit needs a reload, which lays the slots out afresh. Each costs a pointer per instance.
	 */
	public static var liveFieldReserve:Int = 4;

	public static function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>, relocated:Array<String>,
			token:Null<CancellationToken>):BackendAssemblyResult {
		var allocationAtStart = AllocationMeter.sample();
		var nextAbi = RuntimeAbi.describe(ir), previousAbi = context.publishedAbi, baseAssembler = context.assembler;
		// Lambdas are named by their position among their siblings. When an edit moved those names onto other functions, give
		// the running module's lambdas the names their functions have now (see `LambdaAlignment`), so the plan compares, and
		// the patch replaces, each function with itself. Only an assembler that holds the running layout can rename it.
		if (context.livePatching && !context.isWasmTarget() && baseAssembler.isPublished() && previousAbi != null) {
			var alignment = LambdaAlignment.align(previousAbi.positional, nextAbi.positional, Std.string(baseAssembler.lastRevision() + 1));
			if (alignment.steps.length > 0) {
				baseAssembler = baseAssembler.copy();
				baseAssembler.renameLambdas(alignment.steps);
				previousAbi = LambdaAlignment.renameAbi(previousAbi, alignment.steps);
			}
		}
		// Patch planning describes what a running module must do to adopt this build. Without live patching there is no
		// running module, and the plan would only mix session history into the build.
		var decision = context.livePatching ? PatchPlanner.plan(previousAbi, nextAbi, !context.isWasmTarget(),
				!context.isWasmTarget() && baseAssembler.isPublished()) : PatchDecision.Patch,
			reloadReasons:Array<AbiChange> = switch decision {
				case Patch: [];
				case ReloadDomain(reasons): reasons;
				case Reject(diagnostics): throw diagnostics.join("; ");
			};
		reloadReasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		if (reloadReasons.length > 0)
			decision = ReloadDomain(reloadReasons);
		var abiPlanningDoneAt = Sys.time() * 1000.0;
		var allocationAfterAbi = AllocationMeter.sample();
		// Without live patching nothing addresses this module by slot, symbol index or stable id, so assemble
		// from scratch: the result depends only on the source, never on what the session compiled before.
		var candidateAssembler = !context.livePatching ? new HlModuleAssembler() : context.compiledOnce
			&& PatchPlanner.requiresFreshLayout(decision) ? freshLayout(baseAssembler) : baseAssembler.copy();
		candidateAssembler.fieldReserve = context.livePatching && !context.isWasmTarget() ? liveFieldReserve : 0;
		var assemblerCopiedAt = Sys.time() * 1000.0;
		var allocationAfterCopy = AllocationMeter.sample();
		var assembly = candidateAssembler.assemble(ir, context.rehydratedChanges(regenerated, ir), decision, relocated);
		for (detail in assembly.layoutReasons)
			reloadReasons.push(AssemblyLayoutChanged(detail));
		for (reason in assembly.objectReasons)
			reloadReasons.push(reason);
		var assembledAt = Sys.time() * 1000.0;
		var allocationAfterAssembly = AllocationMeter.sample();
		attachSourceSnapshots(context, assembly.module);
		var backendAssemblyDoneAt = Sys.time() * 1000.0;
		var allocationAfterSnapshots = AllocationMeter.sample();
		if (token != null)
			token.check();
		// The assembler can also fall back to a fresh module on its own (a new runtime native moves every
		// slot), and a patch is only meaningful against the layout the running module has.
		var patchBytes = reloadReasons.length > 0
			|| assembly.requiresReload
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, context.moduleId, assembly.changedSlots,
				context.stableIdsBySlot(candidateAssembler, assembly.functionIndices), assembly.baseRevision, assembly.revision, assembly.baseInts,
				assembly.baseFloats, assembly.baseStrings, assembly.baseTypes, null, assembly.addedFunctions, assembly.baseGlobals,
				assembly.objectLayout);
		var allocationAfterPatch = AllocationMeter.sample();
		return {
			assembly: assembly,
			assembler: candidateAssembler,
			abi: nextAbi,
			reloadReasons: reloadReasons,
			patchBytes: patchBytes,
			assemblerCopyMs: assemblerCopiedAt - abiPlanningDoneAt,
			snapshotAttachmentMs: backendAssemblyDoneAt - assembledAt,
			abiPlanningDoneAt: abiPlanningDoneAt,
			backendAssemblyDoneAt: backendAssemblyDoneAt,
			patchEncodingDoneAt: Sys.time() * 1000.0,
			allocationPhases: [
				AllocationMeter.delta("abi", allocationAtStart, allocationAfterAbi),
				AllocationMeter.delta("assembler-copy", allocationAfterAbi, allocationAfterCopy),
				AllocationMeter.delta("backend-assembly", allocationAfterCopy, allocationAfterAssembly),
				AllocationMeter.delta("source-snapshots", allocationAfterAssembly, allocationAfterSnapshots),
				AllocationMeter.delta("patch", allocationAfterSnapshots, allocationAfterPatch)
			].concat(assembly.allocationPhases)
		};
	}

	/**
	 * A fresh layout for the same module identity. It keeps the stable function ids and continues the revision count: the
	 * module it replaces is still running, and a revision number that starts over would look like an older build of it.
	 */
	static function freshLayout(previous:HlModuleAssembler):HlModuleAssembler {
		var fresh = new HlModuleAssembler(CompilationContext.copyIndices(previous.cache.stableIds));
		fresh.continueRevisions(previous.lastRevision());
		return fresh;
	}

	static function attachSourceSnapshots(context:CompilationContext, code:HlCode):Void {
		var referenced:Map<Int, Bool> = [];
		for (fn in code.functions)
			for (location in fn.debugLocations)
				if (location.sourceHash != 0)
					referenced.set(location.sourceHash, true);
		var byHash:Map<Int, Bytes> = [];
		for (state in context.modules) {
			var source = state.source, hash = source.contentHash();
			if (!referenced.exists(hash))
				continue;
			var content = source.bytes, existing = byHash.get(hash);
			if (existing != null && existing.compare(content) != 0)
				throw 'Source snapshot hash collision for ${source.path}';
			byHash.set(hash, content);
		}
		code.sourceSnapshots = [for (hash => content in byHash) {sourceHash: hash, content: content}];
		code.sourceSnapshots.sort((left, right) -> left.sourceHash < right.sourceHash ? -1 : left.sourceHash > right.sourceHash ? 1 : 0);
		if (code.sourceSnapshots.length > 0)
			code.debugSections.push({
				kind: HlWriter.SOURCE_SNAPSHOTS,
				version: 1,
				flags: 0,
				payload: HlWriter.encodeSourceSnapshots(code.sourceSnapshots)
			});
	}
}

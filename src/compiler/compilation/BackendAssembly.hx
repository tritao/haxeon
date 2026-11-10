package compiler.compilation;

import compiler.abi.LambdaAlignment;
import compiler.abi.RetiredName;
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

	/** What the assembly reads besides the IR: an assembly made in an equal environment from an equal IR is the same module. */
	public static function environmentKey(context:CompilationContext):String
		return [
			"live:" + context.livePatching,
			"wasm:" + context.isWasmTarget(),
			"development:" + context.developmentMetadata,
			"fieldReserve:" + liveFieldReserve
		].join(",");

	/** An earlier result for this build: the module and everything derived from it stay, the timings are this build's (none). */
	public static function reused(previous:BackendAssemblyResult, at:Float):BackendAssemblyResult
		return {
			assembly: previous.assembly,
			assembler: previous.assembler,
			abi: previous.abi,
			reloadReasons: previous.reloadReasons,
			patchBytes: previous.patchBytes,
			abiPlanningDoneAt: at,
			backendAssemblyDoneAt: at,
			patchEncodingDoneAt: at,
			assemblerCopyMs: 0.0,
			snapshotAttachmentMs: 0.0,
			allocationPhases: []
		};

	/** Why a module assembled from the same inputs differs from `previous`, or null when it is the same module. */
	public static function difference(previous:BackendAssemblyResult, fresh:BackendAssemblyResult):Null<String>
		return moduleDifference(previous.assembly.module, fresh.assembly.module);

	/** What the lowering was done for besides the IR; entries made for another environment are not used (see `HlLoweredCache`). */
	static function loweringEnvironment(assembler:HlModuleAssembler, context:CompilationContext):String
		return "fieldReserve:"
			+ assembler.fieldReserve
			+ ",development:"
			+ assembler.developmentMetadata
			+ ",wasm:"
			+ context.isWasmTarget();

	/** Why two modules differ, or null when they encode to the same bytes. */
	public static function moduleDifference(previous:HlCode, fresh:HlCode):Null<String> {
		var left = HlWriter.encode(previous), right = HlWriter.encode(fresh);
		if (left.equals(right))
			return null;
		var functions = previous.functions, others = fresh.functions;
		if (functions.length != others.length)
			return "function count " + functions.length + " -> " + others.length;
		for (index in 0...functions.length)
			if (HlWriter.encodeFunction(functions[index]).compare(HlWriter.encodeFunction(others[index])) != 0)
				return 'function ${functions[index].functionIndex} differs';
		return "module tables or debug sections differ";
	}

	public static function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>, relocated:Array<String>,
			token:Null<CancellationToken>):BackendAssemblyResult {
		var allocationAtStart = AllocationMeter.sample();
		var nextAbi = RuntimeAbi.describe(ir), previousAbi = context.publishedAbi, baseAssembler = context.assembler;
		// Compilation sessions retain a HashLink assembly even when the requested
		// artifact is Wasm. Keep its closure ABI adaptation local to that assembly;
		// the Wasm backend receives the original logical program and builds its own
		// target-specific adapters.
		var assemblyIr = ir;
		if (context.isWasmTarget()) {
			assemblyIr = ir.copy();
			compiler.ir.IrScalarClosures.rewrite(assemblyIr);
		} else if (!context.livePatching) {
			// A plain HashLink build writes only what is reachable from the entry: a function nothing reaches is not lowered or
			// encoded, and a class no reachable function mentions loses its methods. The program in the result keeps everything
			// (other backends and tools read it), and a live module keeps every function too, because its host can call any of
			// them by id and a reachability change must not move its layout.
			assemblyIr = ir.copy();
			var reachable = compiler.ir.IrReachability.withGeneratedRuntimeRoots(ir, ir.entryPoint, null, true);
			compiler.ir.IrReachability.prune(assemblyIr, reachable);
			regenerated = [for (name in regenerated) if (reachable.exists(name)) name];
			relocated = [for (name in relocated) if (reachable.exists(name)) name];
		}
		// Lambdas are named by their position among their siblings. When an edit moved those names onto other functions, give
		// the running module's lambdas the names their functions have now (see `LambdaAlignment`), so the plan compares, and
		// the patch replaces, each function with itself. Only an assembler that holds the running layout can rename it.
		if (context.livePatching && !context.isWasmTarget() && baseAssembler.isPublished() && previousAbi != null) {
			var alignment = LambdaAlignment.align(previousAbi.positional, nextAbi.positional, Std.string(baseAssembler.lastRevision() + 1),
				LambdaAlignment.placesOf(previousAbi, nextAbi));
			if (alignment.steps.length > 0) {
				baseAssembler = baseAssembler.copy();
				baseAssembler.renameLambdas(alignment.steps);
				previousAbi = LambdaAlignment.renameAbi(previousAbi, alignment.steps);
			}
		}
		// Patch planning describes what a running module must do to adopt this build. Without live patching there is no
		// running module, and the plan would only mix session history into the build.
		var decision = context.livePatching ? PatchPlanner.plan(previousAbi, nextAbi,
			!context.isWasmTarget(), !context.isWasmTarget() && baseAssembler.isPublished()) : PatchDecision.Patch,
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
		// A plain build links the functions of the last one whose IR is unchanged instead of lowering them again (see `HlLoweredCache`).
		var loweredCache = context.livePatching ? null : context.loweredCache;
		var candidateAssembler = !context.livePatching ? new HlModuleAssembler(null,
			loweredCache.debug) : context.compiledOnce
			&& PatchPlanner.requiresFreshLayout(decision) ? freshLayout(baseAssembler) : baseAssembler.copy();
		candidateAssembler.fieldReserve = context.livePatching && !context.isWasmTarget() ? liveFieldReserve : 0;
		candidateAssembler.developmentMetadata = context.developmentMetadata || context.livePatching;
		candidateAssembler.irVerified = !context.livePatching;
		candidateAssembler.livePatching = context.livePatching;
		if (loweredCache != null) {
			loweredCache.forEnvironment(loweringEnvironment(candidateAssembler, context));
			candidateAssembler.loweredCache = loweredCache;
		}
		var assemblerCopiedAt = Sys.time() * 1000.0;
		var allocationAfterCopy = AllocationMeter.sample();
		var assembly = candidateAssembler.assemble(assemblyIr, context.rehydratedChanges(regenerated, assemblyIr), decision, relocated,
			PatchPlanner.dispatchedFunctions(previousAbi, nextAbi));
		for (detail in assembly.layoutReasons)
			reloadReasons.push(AssemblyLayoutChanged(detail));
		for (reason in assembly.objectReasons)
			reloadReasons.push(reason);
		var assembledAt = Sys.time() * 1000.0;
		var allocationAfterAssembly = AllocationMeter.sample();
		if (candidateAssembler.developmentMetadata)
			attachSourceSnapshots(context, assembly.module);
		if (loweredCache != null && candidateAssembler.reusedFunctions > 0 && Sys.getEnv("HAXEON_CHECK_REUSE") == "1") {
			// The module with functions linked from the last build must be the module lowering every function gives.
			var fresh = new HlModuleAssembler();
			fresh.fieldReserve = candidateAssembler.fieldReserve;
			fresh.developmentMetadata = candidateAssembler.developmentMetadata;
			fresh.irVerified = candidateAssembler.irVerified;
			fresh.loweredCache = new compiler.hl.incremental.HlLoweredCache();
			var freshAssembly = fresh.assemble(assemblyIr, context.rehydratedChanges(regenerated, assemblyIr), decision, relocated,
				PatchPlanner.dispatchedFunctions(previousAbi, nextAbi));
			if (fresh.developmentMetadata)
				attachSourceSnapshots(context, freshAssembly.module);
			var difference = moduleDifference(assembly.module, freshAssembly.module);
			if (difference != null)
				throw 'HAXEON_CHECK_REUSE: a module with ${candidateAssembler.reusedFunctions} functions linked from the last build differs from one lowered afresh ($difference)';
		}
		if (!context.isWasmTarget())
			compiler.ir.IrOpportunityCensus.reportHashLink(assembly.module, assembly.functionIndices);
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
				assembly.baseFloats, assembly.baseStrings, assembly.baseTypes, null, assembly.addedFunctions, assembly.baseGlobals, assembly.objectLayout, [
					for (guard in assembly.guards)
						if (candidateAssembler.cache.stableIds.exists(guard.name)) {
							stableId: candidateAssembler.cache.stableIds.get(guard.name) ?? 0,
							description: guard.description
						}
				], candidateAssembler.symbols.namedGlobals());
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
	 * Retired functions (`RetiredName`) are left behind: only closures of the running module call them, and the
	 * fresh module replaces it, so keeping their IDs would only let them pile up across reloads.
	 */
	static function freshLayout(previous:HlModuleAssembler):HlModuleAssembler {
		var ids = CompilationContext.copyIndices(previous.cache.stableIds);
		for (name in [for (name in ids.keys()) if (RetiredName.is(name)) name])
			ids.remove(name);
		var fresh = new HlModuleAssembler(ids);
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
			code.debugSections.push(compiler.hl.HlCode.HlDebugSection.lazy(HlWriter.SOURCE_SNAPSHOTS, 1, 0,
				_ -> HlWriter.encodeSourceSnapshots(code.sourceSnapshots)));
	}
}

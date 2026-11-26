package compiler.compilation;

import compiler.core.PeakProbe;
import compiler.core.PhaseCollections;
import compiler.core.AllocationMeter;
import compiler.abi.LambdaAlignment;
import compiler.abi.RetiredName;
import compiler.abi.PatchPlanner;
import compiler.abi.PatchPlanner.AbiChange;
import compiler.abi.PatchPlanner.PatchDecision;
import compiler.abi.RuntimeAbi;
import compiler.core.InternalError;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.hl.incremental.HlLoweredCache;
import compiler.hl.incremental.HlPlainBuild;
import compiler.hl.patch.HlPatchWriter;
import compiler.ir.model.Ir.IrProgram;
import compiler.core.CancellationToken;
import haxe.io.Bytes;
import compiler.hl.HlCode;
import compiler.hl.HlWriter;
import compiler.backend.Backend.BackendTarget;
import compiler.compilation.BackendArtifact;
import compiler.compilation.BackendSession.BackendAssemblyResult;
import compiler.compilation.BackendSession.BackendTimings;
import compiler.hl.persistence.HlRuntimeIdentity;

/**
 * The HashLink backend of a compilation session. It owns what the next HashLink build starts from: the assembler of the last
 * successful build (its layout, stable function ids and revision history, which live patches address) and the lowered functions
 * of the last plain build. A build assembles on the candidate's copy (`forCandidate`), so a failed build leaves both as they were.
 */
class HashLinkBackendSession implements BackendSession {
	/** The assembler of the last successful build. */
	public var assembler:HlModuleAssembler;

	/** The lowered functions of the last plain build (see `HlLoweredCache`). */
	public var loweredCache:HlLoweredCache;

	/** The files the last module's debug locations are placed in (`HlCode.sources`): the module stays right while their texts do. */
	var placedFiles:Map<String, Bool> = [];

	/** Where this session's builds last placed each anchor, for the code a live module keeps of what an edit removed. */
	var placedAnchors = new compiler.core.SourceAnchor.SourceAnchorHistory();

	public function new(assembler:HlModuleAssembler, ?loweredCache:HlLoweredCache) {
		this.assembler = assembler;
		this.loweredCache = loweredCache == null ? new HlLoweredCache() : loweredCache;
	}

	public function backendTarget():BackendTarget
		return HashLink;

	public function hashLink():Null<HashLinkBackendSession>
		return this;

	public function wasm():Null<WasmBackendSession>
		return null;

	/** The same assembler, with a copy of the lowered cache the candidate build can fill. */
	public function forCandidate():BackendSession {
		var candidate = new HashLinkBackendSession(assembler, loweredCache.copy());
		candidate.placedFiles = placedFiles;
		candidate.placedAnchors = placedAnchors;
		return candidate;
	}

	/** A session that assembles a fresh layout with the same stable function ids (`Compiler.compact`). */
	public function compacting():HashLinkBackendSession
		return new HashLinkBackendSession(new HlModuleAssembler(assembler.cache.stableIds), loweredCache);

	/** What the assembly reads besides the IR: an assembly made in an equal environment from an equal IR is the same module. */
	public function environmentKey(context:CompilationContext):String
		return [
			"live:" + context.livePatching,
			"development:" + context.developmentMetadata,
			"options:" + context.options.key(),
			"fieldReserve:" + context.liveFieldReserve,
			// The module places its debug locations in the sources (`HlCode.sources`), which the IR leaves out.
			"sources:" + context.sourcesKey(placedFiles)
		].join(",");

	/** An earlier result for this build: the module and everything derived from it stay, the timings are this build's (none). */
	public function reuse(previous:BackendAssemblyResult, at:Float):BackendAssemblyResult {
		var reusedAssembler = previous.assembler;
		if (reusedAssembler == null)
			throw new InternalError("A HashLink session cannot reuse another backend's result");
		assembler = reusedAssembler;
		return {
			artifact: previous.artifact,
			assembler: reusedAssembler,
			abi: previous.abi,
			reloadReasons: previous.reloadReasons,
			changedFunctions: previous.changedFunctions,
			requiresReload: previous.requiresReload,
			unchanged: previous.unchanged,
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
	}

	/** Why a module assembled from the same inputs differs from `previous`, or null when it is the same module. */
	public function difference(previous:BackendAssemblyResult, fresh:BackendAssemblyResult):Null<String> {
		var before = BackendArtifacts.hashLink(previous.artifact),
			after = BackendArtifacts.hashLink(fresh.artifact),
			sections = before.sections,
			freshSections = after.sections;
		if (sections == null || freshSections == null)
			return sections == null && freshSections == null ? moduleDifference(before.module,
				after.module) : "one of the modules is sectioned";
		return sections.equals(freshSections) ? null : "module sections differ";
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

	/** What the lowering was done for besides the IR; entries made for another environment are not used (see `HlLoweredCache`). */
	static function loweringEnvironment(assembler:HlModuleAssembler, context:CompilationContext):String
		return "fieldReserve:"
			+ assembler.fieldReserve
			+ ",development:"
			+ assembler.developmentMetadata;

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
		return tableDifference(previous, fresh);
	}

	/** The first table entry, constant or debug section in which `previous` and `fresh` differ. */
	static function tableDifference(previous:HlCode, fresh:HlCode):String {
		var found = firstDifference("int", previous.ints, fresh.ints, Std.string);
		found = found ?? firstDifference("float", previous.floats, fresh.floats, Std.string);
		found = found ?? firstDifference("string", previous.strings, fresh.strings, value -> value);
		found = found ?? firstDifference("type", previous.types, fresh.types, Std.string);
		found = found ?? firstDifference("global", previous.globals, fresh.globals, Std.string);
		found = found ?? firstDifference("native", previous.natives, fresh.natives, Std.string);
		found = found ?? firstDifference("constant", previous.constants, fresh.constants, Std.string);
		found = found ?? firstDifference("debug section", previous.debugSections, fresh.debugSections,
			section -> section.kind + "/" + section.payload.length + "/"
			+ build.execution.ContentDigest.makeHex(section.payload.flatten()));
		found = found ?? (previous.entryPoint == fresh.entryPoint
			? null : 'entry point ${previous.entryPoint} -> ${fresh.entryPoint}');
		return found ?? "module tables or debug sections differ";
	}

	/** The first entry of `left` that `show` spells otherwise in `right`, or their counts when one is a prefix of the other. */
	static function firstDifference<T>(what:String, left:Array<T>, right:Array<T>, show:T->String):Null<String> {
		for (index in 0...(left.length < right.length ? left.length : right.length)) {
			var a = show(left[index]), b = show(right[index]);
			if (a != b)
				return '$what $index: $a -> $b';
		}
		return left.length == right.length ? null : '$what count ${left.length} -> ${right.length}';
	}

	/** Assembles `ir`; the session keeps the candidate assembler, which the compiler adopts with the candidate. */
	public function assemble(context:CompilationContext, ir:IrProgram, regenerated:Array<String>,
			token:Null<CancellationToken>):BackendAssemblyResult {
		var allocationAtStart = AllocationMeter.sample();
		PeakProbe.mark("backend-start");
		compiler.ir.analysis.IrReachability.IrReachabilityReport.report("final program", ir);
		var summaries = this.loweredCache.summaries;
		var nextAbi = context.describesRuntimeAbi() ? RuntimeAbi.describe(ir, summaries.abiSignatures) : null,
			previousAbi = context.state.publishedAbi,
			baseAssembler = assembler;
		var assemblyIr = ir;
		if (!context.livePatching) {
			// A plain HashLink build writes only what is reachable from the entry: a function nothing reaches is not lowered or
			// encoded, and a class no reachable function mentions loses its methods. The program in the result keeps everything
			// (other backends and tools read it), and a live module keeps every function too, because its host can call any of
			// them by id and a reachability change must not move its layout.
			var plain = HlPlainBuild.reachable(ir, context.options.checkReuse, summaries),
				reachable = plain.reachable;
			assemblyIr = plain.program;
			regenerated = [for (name in regenerated) if (reachable.exists(name)) name];
		}
		// Lambdas are named by their position among their siblings. When an edit moved those names onto other functions, give
		// the running module's lambdas the names their functions have now (see `LambdaAlignment`), so the plan compares, and
		// the patch replaces, each function with itself. Only an assembler that holds the running layout can rename it.
		if (context.livePatching && baseAssembler.isPublished() && previousAbi != null && nextAbi != null) {
			var alignment = LambdaAlignment.align(previousAbi.positional, nextAbi.positional,
				Std.string(baseAssembler.lastRevision() + 1),
				LambdaAlignment.placesOf(previousAbi, nextAbi));
			if (alignment.steps.length > 0) {
				baseAssembler = baseAssembler.copy();
				baseAssembler.renameLambdas(alignment.steps);
				previousAbi = LambdaAlignment.renameAbi(previousAbi, alignment.steps);
			}
		}
		// Patch planning describes what a running module must do to adopt this build. Without live patching there is no
		// running module, and the plan would only mix session history into the build.
		var decision = context.livePatching && nextAbi != null ? PatchPlanner.plan(previousAbi, nextAbi, true,
			baseAssembler.isPublished()) : PatchDecision.Patch,
			reloadReasons:Array<AbiChange> = switch decision {
				case Patch: [];
				case ReloadDomain(reasons): reasons;
				case Reject(diagnostics): throw new InternalError(diagnostics.join("; "));
			};
		reloadReasons.sort(function(a, b) return Reflect.compare(Std.string(a), Std.string(b)));
		if (reloadReasons.length > 0)
			decision = ReloadDomain(reloadReasons);
		var abiPlanningDoneAt = Sys.time() * 1000.0;
		var allocationAfterAbi = AllocationMeter.sample();
		// Without live patching nothing addresses this module by slot, symbol index or stable id, so assemble
		// from scratch: the result depends only on the source, never on what the session compiled before.
		// A plain build keeps the functions of the last one whose IR is unchanged instead of lowering them again (see `HlLoweredCache`).
		var loweredCache:Null<HlLoweredCache> = context.livePatching ? null : this.loweredCache;
		var candidateAssembler = loweredCache != null ? new HlModuleAssembler(null,
			loweredCache.debug) : context.state.compiledOnce
			&& PatchPlanner.requiresFreshLayout(decision) ? freshLayout(baseAssembler) : baseAssembler.copy();
		candidateAssembler.fieldReserve = context.livePatching ? context.liveFieldReserve : 0;
		candidateAssembler.developmentMetadata = context.developmentMetadata || context.livePatching;
		candidateAssembler.sources = context.sourceAnchors(placedAnchors);
		candidateAssembler.checkReuse = context.options.checkReuse;
		candidateAssembler.irVerified = !context.livePatching;
		candidateAssembler.livePatching = context.livePatching;
		candidateAssembler.keepsLowered = context.options.keepSession;
		if (loweredCache != null) {
			loweredCache.forEnvironment(loweringEnvironment(candidateAssembler, context));
			candidateAssembler.loweredCache = loweredCache;
		}
		var assemblerCopiedAt = Sys.time() * 1000.0;
		var allocationAfterCopy = AllocationMeter.sample();
		// Only a live build keeps slots for the functions prototypes dispatch to; a plain one lays out a fresh module.
		var assembly = candidateAssembler.assemble(assemblyIr, regenerated, decision,
			nextAbi == null || !context.livePatching ? null : PatchPlanner.dispatchedFunctions(previousAbi, nextAbi),
			context.state.rehydrationBaseline);
		summaries.endBuild();
		for (detail in assembly.layoutReasons)
			reloadReasons.push(AssemblyLayoutChanged(detail));
		for (reason in assembly.objectReasons)
			reloadReasons.push(reason);
		var assembledAt = Sys.time() * 1000.0;
		PeakProbe.mark("backend-assembled");
		PhaseCollections.end("backend", context.options.phaseCollections);
		var allocationAfterAssembly = AllocationMeter.sample();
		if (candidateAssembler.developmentMetadata)
			attachSourceSnapshots(context, assembly.module);
		notePlacedFiles(assembly.module);
		// A build with functions kept from the last one must write the sections lowering every function gives: they are compared
		// once written, since the dense tables are numbered as each build asked for their entries.
		var freshModule:Null<HlCode> = null;
		if (loweredCache != null && candidateAssembler.reusedFunctions > 0 && context.options.checkReuse) {
			var fresh = new HlModuleAssembler();
			fresh.fieldReserve = candidateAssembler.fieldReserve;
			fresh.developmentMetadata = candidateAssembler.developmentMetadata;
			fresh.sources = candidateAssembler.sources;
			fresh.irVerified = candidateAssembler.irVerified;
			fresh.loweredCache = new HlLoweredCache();
			var freshAssembly = fresh.assemble(assemblyIr, regenerated, decision,
				nextAbi == null ? null : PatchPlanner.dispatchedFunctions(previousAbi, nextAbi),
				context.state.rehydrationBaseline);
			if (fresh.developmentMetadata)
				attachSourceSnapshots(context, freshAssembly.module);
			freshModule = freshAssembly.module;
		}
		var backendAssemblyDoneAt = Sys.time() * 1000.0;
		var allocationAfterSnapshots = AllocationMeter.sample();
		if (token != null)
			token.check();
		// The assembler can also fall back to a fresh module on its own (a new runtime native moves every
		// slot), and a patch is only meaningful against the layout the running module has.
		var patchBytes = reloadReasons.length > 0
			|| assembly.requiresReload
			|| assembly.changedFunctions.length == 0 ? null : HlPatchWriter.encode(assembly.module, context.moduleId,
			assembly.changedSlots,
			stableIdsBySlot(candidateAssembler, assembly.functionIndices), assembly.baseRevision,
			assembly.revision, assembly.baseInts,
			assembly.baseFloats, assembly.baseStrings, assembly.baseTypes, null, assembly.addedFunctions,
			assembly.baseGlobals, assembly.objectLayout, [for (guard in assembly.guards)
			if (candidateAssembler.cache.stableIds.exists(guard.name)) {
				stableId: candidateAssembler.cache.stableIds.get(guard.name) ?? 0,
				description: guard.description
			}], candidateAssembler.symbols.namedGlobals());
		var allocationAfterPatch = AllocationMeter.sample();
		assembler = candidateAssembler;
		var stableIds = candidateAssembler.cache.stableIds,
			functionIndices = assembly.functionIndices,
			sections:Null<haxeon.io.SegmentedBytes> = null,
			sectionsEncoded:Null<String> = null;
		if (!context.livePatching) {
			// A plain build is written as module sections, which the loader links and numbers itself, and a function's stable id is
			// its index there. A compile that keeps no session memoizes no section for a next build.
			var modules = [for (name => state in context.state.modules) name => state.source.contentHash()],
				kept = candidateAssembler.loweredCache,
				written = compiler.hl.HlSectionWriter.write(assembly.module, modules, context.state.declarationOwners,
					compiler.hl.HlLz4.FAST, context.options.checkReuse, kept == null ? null : kept.sections,
					context.options.keepSession);
			if (kept != null)
				kept.sections = written.cache;
			if (freshModule != null) {
				var afresh = compiler.hl.HlSectionWriter.write(freshModule, modules, context.state.declarationOwners,
					compiler.hl.HlLz4.FAST, false, null, false);
				if (!afresh.bytes.equals(written.bytes))
					throw new InternalError('--check-reuse: the sections of a build with ${candidateAssembler.reusedFunctions} functions kept from the last build differ from the sections of one lowered afresh');
			}
			sectionsEncoded = written.encoded + " of " + written.sections + " (" + written.changed + " changed)";
			sections = written.bytes;
			functionIndices = [];
			for (name => index in assembly.functionIndices) {
				var linked = index < written.linkedIndices.length ? written.linkedIndices[index] : -1;
				if (linked >= 0)
					functionIndices.set(name, linked);
			}
			stableIds = functionIndices;
		}
		compiler.hl.HlOpportunityCensus.report(assembly.module, assembly.functionIndices, sections);
		return {
			artifact: HashLinkBuild({
				module: assembly.module,
				functionIndices: CompilationContext.copyIndices(functionIndices),
				functionIds: CompilationContext.copyIndices(stableIds),
				runtimeIdentity: HlRuntimeIdentity.encode(context.moduleId, assembly.revision, functionIndices,
					stableIds),
				patchBytes: patchBytes,
				sections: sections
			}),
			assembler: candidateAssembler,
			abi: nextAbi,
			reloadReasons: reloadReasons,
			changedFunctions: assembly.changedFunctions,
			requiresReload: assembly.requiresReload,
			unchanged: assembly.unchanged,
			baseRevision: assembly.baseRevision,
			revision: assembly.revision,
			moduleFunctions: assembly.module.functions.length,
			moduleNatives: assembly.module.natives.length,
			linkedFunctions: candidateAssembler.reusedFunctions,
			movedFunctions: candidateAssembler.movedFunctions,
			sectionsEncoded: sectionsEncoded,
			timings: {
				cachePreparationMs: assembly.cachePreparationMs,
				loweringMs: assembly.loweringMs,
				publicationMs: assembly.publicationMs,
				verificationMs: assembly.verificationMs,
				metadataMs: assembly.metadataMs,
				functionLoweringMs: assembly.functionLoweringMs,
				debugAssemblyMs: assembly.debugAssemblyMs,
				lowerFinalizationMs: assembly.lowerFinalizationMs
			},
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

	static function stableIdsBySlot(source:HlModuleAssembler, layout:Map<String, Int>):Map<Int, Int> {
		var result:Map<Int, Int> = [];
		for (name => id in source.cache.stableIds)
			if (layout.exists(name))
				result.set(layout.get(name), id);
		return result;
	}

	/** Records the files `code`'s debug locations are placed in (`placedFiles`). */
	function notePlacedFiles(code:HlCode):Void {
		var files:Map<String, Bool> = [], sources = code.sources;
		for (fn in code.functions)
			for (anchor in fn.anchors())
				files.set(sources.path(anchor), true);
		placedFiles = files;
	}

	static function attachSourceSnapshots(context:CompilationContext, code:HlCode):Void {
		var referenced:Map<Int, Bool> = [], sources = code.sources;
		for (fn in code.functions) {
			var previous = -1;
			for (location in fn.debugLocations)
				if (location.anchor != previous && !location.generatedText) {
					previous = location.anchor;
					var hash = sources.hash(previous);
					if (hash != 0)
						referenced.set(hash, true);
				}
		}
		var byHash:Map<Int, Bytes> = [];
		for (state in context.state.modules) {
			var source = state.source, hash = source.contentHash();
			if (!referenced.exists(hash))
				continue;
			var content = source.bytes, existing = byHash.get(hash);
			if (existing != null && existing.compare(content) != 0)
				throw new InternalError('Source snapshot hash collision for ${source.path}');
			byHash.set(hash, content);
		}
		code.sourceSnapshots = [for (hash => content in byHash) {
			sourceHash: hash, content: content
		}];
		code.sourceSnapshots.sort((left, right) -> left.sourceHash < right.sourceHash ? -1 : left.sourceHash
			> right.sourceHash ? 1 : 0);
		if (code.sourceSnapshots.length > 0)
			code.debugSections.push(compiler.hl.HlCode.HlDebugSection.lazy(HlWriter.SOURCE_SNAPSHOTS, 1, 0,
				_ -> HlWriter.encodeSourceSnapshots(code.sourceSnapshots), compiler.hl.HlLz4.FAST));
	}
}

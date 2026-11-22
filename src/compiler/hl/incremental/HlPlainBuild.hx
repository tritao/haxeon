package compiler.hl.incremental;

import compiler.ir.analysis.IrReachability;
import compiler.ir.model.Ir.IrProgram;

/**
 * A plain HashLink build, which no running module addresses by slot or stable id: it writes only what the entry reaches, from a
 * fresh assembler. `HashLinkBackendSession` assembles every build without live patching this way, and `HlBackend` is the same
 * assembly without a session.
 */
class HlPlainBuild {
	/**
	 * What a plain module is made of: a copy of `program` without the functions the entry does not reach, and without the methods of
	 * a class no reachable function mentions, with the reachable names. `program` keeps everything (other backends and tools read it).
	 * `summaries` keeps what the trim reads of each function.
	 */
	public static function reachable(program:IrProgram, checkReuse:Bool = false, ?summaries:HlFunctionSummaries):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		var pruned = program.copy(),
			walk = IrReachability.walkWithGeneratedRuntimeRoots(program, program.entryPoint, null, true);
		IrReachability.prune(pruned, walk.reachable);
		IrReachability.trimTables(pruned, walk, summaries == null ? null : summaries.trim);
		if (checkReuse)
			IrReachability.checkTables(pruned);
		return {program: pruned, reachable: walk.reachable};
	}

	/** Assembles `program` as a plain build with no session: reachable from the entry, a fresh assembler and an empty lowered cache. */
	public static function assemble(program:IrProgram, developmentMetadata:Bool):HlModuleAssembler.HlAssemblyResult {
		var plain = reachable(program).program;
		return assembler(developmentMetadata).assemble(plain, [for (fn in plain.functions) fn.name], Patch);
	}

	/** The fresh assembler of a plain build, with an empty lowered cache. */
	public static function assembler(developmentMetadata:Bool):HlModuleAssembler {
		var cache = new HlLoweredCache(),
			assembler = new HlModuleAssembler(null, cache.debug);
		assembler.fieldReserve = 0;
		assembler.developmentMetadata = developmentMetadata;
		assembler.irVerified = true;
		assembler.livePatching = false;
		assembler.loweredCache = cache;
		return assembler;
	}
}

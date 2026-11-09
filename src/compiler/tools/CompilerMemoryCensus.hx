package compiler.tools;

import compiler.Compiler;
import compiler.hl.HlWriterCache;
import compiler.hl.incremental.HlLoweredCache;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.ir.IrInliner.IrInlineCache;
import sys.FileSystem;
import sys.io.File;

/**
 * A diagnostic for what a compiler session keeps. With HAXEON_COMPILER_CENSUS=<directory> and HAXEON_COMPILER_CENSUS_TOOL=<hmdtypes> the
 * worker, after its first build, releases the things a session holds one at a time, writing HashLink's memory dump after each and
 * tallying its live blocks by type with the tool. What a step removes from the tally is what only that owner kept alive at that moment,
 * given the owners released before it. This leaves the worker unusable: it has dropped the caches and the modules a build needs, so
 * a diagnostic run is one build followed by the census, and the worker is then discarded.
 */
class CompilerMemoryCensus {
	static var done = false;
	static var builds = 0;

	public static function run(session:CompilerSession):Void {
		#if hl
		var directory = Sys.getEnv("HAXEON_COMPILER_CENSUS"),
			tool = Sys.getEnv("HAXEON_COMPILER_CENSUS_TOOL");
		if (directory == null || tool == null || done)
			return;
		// HAXEON_COMPILER_CENSUS_BUILD=<n> takes the census after the n-th build of the worker (default the first), to see an edited state.
		builds++;
		var wanted = Sys.getEnv("HAXEON_COMPILER_CENSUS_BUILD");
		if (builds < (wanted == null ? 1 : Std.parseInt(wanted)))
			return;
		done = true;
		FileSystem.createDirectory(directory);
		@:privateAccess {
			var compiler:Null<Compiler> = session.compiler;
			if (compiler == null)
				return;
			var steps:Array<{name:String, release:() -> Void}> = [
				{name: "baseline", release: () -> {}},
				{
					name: "cached compile result",
					release: () -> {
						compiler.cachedCompileResult = null;
						compiler.cachedCompileEntry = null;
					}
				},
				{name: "pipeline snapshot (final IR, module)", release: () -> compiler.pipelineSnapshot = null},
				{
					name: "encoded module bytes and writer cache",
					release: () -> {
						session.encodedModule = null;
						session.encodedWasm = null;
						session.writerCache = new HlWriterCache();
					}
				},
				{name: "lowered function cache", release: () -> compiler.loweredCache = new HlLoweredCache()},
				{name: "last assembler (function cache, symbols)", release: () -> compiler.assembler = new HlModuleAssembler()},
				{name: "inline cache", release: () -> compiler.inlineCache = new IrInlineCache()},
				{name: "object cache", release: () -> compiler.objectCache = []},
				{
					name: "last typed program and semantic program",
					release: () -> {
						compiler.lastTypedProgram = null;
						compiler.cachedSemanticProgram = null;
					}
				},
				{
					name: "typed functions of modules",
					release: () -> for (state in compiler.modules) {
						state.typedFunctions = [];
						state.purityQueries = [];
						state.noReturnQueries = [];
						state.keyPathUses = [];
						state.defaultArgumentSources = [];
					}
				},
				{
					name: "IR functions of modules",
					release: () -> for (state in compiler.modules) {
						state.irFunctions = [];
						state.pendingIrFunctions = [];
					}
				},
				{
					name: "canonical declarations of modules",
					release: () -> for (state in compiler.modules) {
						state.canonicalFunctions = [];
						state.canonicalAllFunctions = [];
						state.canonicalProgramFunctions = [];
						state.canonicalClasses = [];
						state.canonicalEnums = [];
						state.canonicalInterfaces = [];
						state.canonicalAbstracts = [];
						state.canonicalAliases = [];
						state.canonicalEnumAbstracts = [];
					}
				},
				{
					name: "semantic models of modules",
					release: () -> for (state in compiler.modules) {
						state.semanticModel = null;
						state.recoveredSemanticModel = null;
						state.lastGoodSemanticModel = null;
					}
				},
				{
					name: "tokens and syntax trees of modules",
					release: () -> for (state in compiler.modules) {
						state.tokens = [];
						state.recoveredTokens = [];
						state.lastGoodTokens = [];
						state.ast = null;
						state.recoveredAst = null;
						state.lastGoodAst = null;
					}
				},
				{
					name: "reachability and declaration owners",
					release: () -> {
						compiler.reachabilityCache = [];
						compiler.declarationOwners = new compiler.semantic.DeclarationOwners();
					}
				},
			];
			var report = File.append(directory + "/census.txt");
			var limit = Sys.getEnv("HAXEON_COMPILER_CENSUS_STEPS");
			for (index in 0...(limit == null ? steps.length : Std.int(Math.min(steps.length, Std.parseInt(limit))))) {
				steps[index].release();
				hl.Gc.major();
				var dump = directory + "/step.dump",
					tally = directory + "/step-" + index + ".tsv";
				hl.Gc.dumpMemory(dump);
				Sys.command("sh", ["-c", tool + " " + dump + " > " + tally]);
				FileSystem.deleteFile(dump);
				report.writeString(index + "\t" + steps[index].name + "\n");
				report.flush();
			}
			report.close();
		}
		#end
	}
}

package compiler.tools;

import compiler.Compiler;
import compiler.hl.incremental.HlModuleAssembler;
import compiler.ir.passes.inlining.IrInliner.IrInlineCache;
import compiler.syntax.TokenTable;
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
	@:processWide("a diagnostic run is one build and one census per process")
	static var done = false;
	@:processWide("a diagnostic run is one build and one census per process")
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
			var steps:Array<{name:String, release:() -> Void}> = [{name: "baseline", release: () -> {}
			},
				{name: "cached compile result",
				release: () -> {
					compiler.cachedCompileResult = null;
					compiler.cachedCompileEntry = null;
				}
			},
				{name: "pipeline snapshot (final IR, module)", release: () -> compiler.state.pipelineSnapshot = null},
				{
					name: "encoded module bytes",
					release: () -> session.encodedModule = null
				},
				{name: "lowered function cache",
				release: () -> {
					var hashLink = compiler.backend.hashLink();
					if (hashLink != null) {
						hashLink.loweredTables = null;
						hashLink.sections = null;
					}
					compiler.state.hlFunctions.lowered.clear();
				}
			},
				{name: "last assembler (function cache, symbols)",
				release: () -> {
					var hashLink = compiler.backend.hashLink();
					if (hashLink != null)
						hashLink.assembler = new HlModuleAssembler();
				}
			},
				{
					name: "inline cache",
					release: () -> compiler.state.inlineCache = new IrInlineCache()
				},
				{name: "objects",
				release: () -> {
					compiler.state.objects = [];
					compiler.state.irObjects.clear();
				}
			},
				{name: "last typed program and semantic program",
				release: () -> {
					compiler.state.lastTypedProgram = null;
					compiler.state.semanticProgram = null;
				}
			},
				{name: "typed functions of modules",
				release: () -> for (state in compiler.modules) {
					state.typedFunctions = [];
					state.keyPathUses = [];
					state.structures = null;
					state.functionEdges = null;
				}
			},
				{name: "IR functions of modules",
				release: () -> {
					for (state in compiler.modules) {
						state.irFunctions = [];
						state.pendingIrFunctions = [];
						state.functionEdges = null;
					}
					compiler.state.irGeneration.clear();
					compiler.state.initializerInputs.clear();
				}
			},
				{name: "canonical declarations of modules",
				release: () -> for (state in compiler.modules) {
					state.canonicalFunctions = [];
					state.canonicalAllFunctions = [];
					state.canonicalProgramFunctions = [];
					state.canonicalClasses = [];
					state.canonicalEnums = [];
					state.canonicalInterfaces = [];
					state.canonicalAbstracts = [];
					state.canonicalAliases = [];
					// Nothing canonical is left to reuse: a later canonicalization starts over.
					state.canonicalRevision = -1;
				}
			},
				{name: "semantic models of modules",
				release: () -> for (state in compiler.modules) {
					state.semanticModel = null;
					state.recoveredSemanticModel = null;
					state.lastGoodSemanticModel = null;
				}
			},
				{name: "tokens and syntax trees of modules",
				release: () -> for (state in compiler.modules) {
					state.tokens = TokenTable.empty;
					state.recoveredTokens = TokenTable.empty;
					state.lastGoodTokens = TokenTable.empty;
					state.ast = null;
					state.recoveredAst = null;
					state.lastGoodAst = null;
				}
			},
				{name: "reachability and declaration owners",
				release: () -> {
					compiler.state.reachabilityCache = [];
					compiler.state.declarationOwners = new compiler.semantic.DeclarationOwners();
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

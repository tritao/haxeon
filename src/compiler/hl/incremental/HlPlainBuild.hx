package compiler.hl.incremental;

import compiler.ir.analysis.IrReachability;
import compiler.ir.analysis.IrReachability.IrBodyEdges;
import compiler.ir.model.Ir.IrObjectTools;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.reuse.IrWalkMemo;

/**
 * A plain HashLink build, which no running module addresses by slot or stable id: it writes only what the entry reaches, from a
 * fresh assembler. `HashLinkBackendSession` assembles every build without live patching this way, and `HlBackend` is the same
 * assembly without a session.
 */
class HlPlainBuild {
	/**
	 * What a plain module is made of: a copy of `program` without the functions the entry does not reach, and without the methods of
	 * a class no reachable function mentions, with the reachable names. `program` keeps everything (other backends and tools read it).
	 * With `queries`, the walk and its trim are the session's step (`HlFunctionQueries.plainReach`), whose names a build takes while
	 * what the walk read of the program is the same; with `checkReuse`, kept names are walked again and compared. The reachable names
	 * are the step's: the caller reads them, never changes them.
	 */
	public static function reachable(program:IrProgram, checkReuse:Bool = false, ?queries:HlFunctionQueries):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		if (queries == null)
			return walk(program, null);
		var step = queries.plainReach,
			database = queries.database,
			kept = step.kept(database, program, program.functions, [program.entryPoint], [], IrBodyEdges.of);
		if (kept != null) {
			var plain = apply(program, kept);
			if (checkReuse) {
				var difference = difference(plain.program, walk(program, null).program);
				if (difference != null)
					throw new compiler.core
						.InternalError('--check-reuse: the plain build reused a reachability walk that differs from walking the program now ($difference)');
				IrReachability.checkTables(plain.program);
			}
			return plain;
		}
		step.begin(database);
		var plain = walk(program, step);
		if (checkReuse)
			IrReachability.checkTables(plain.program);
		step.end(database, {
			reachable: plain.reachable,
			natives: [for (native in plain.program.natives) native.name => true],
			globals: [for (field in plain.program.staticFields) field.name => true],
			classes: [for (object in plain.program.objects) object.name => true]
		});
		return plain;
	}

	/** The walk of `program` from its entry and the trim of its tables, reading each reached function's edges from `step`. */
	static function walk(program:IrProgram, step:Null<IrWalkMemo<IrBodyEdges, HlPlainNames>>):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		var pruned = program.copy(),
			edges = step == null ? null : step.summary,
			walk = IrReachability.walkWithGeneratedRuntimeRoots(program, program.entryPoint, null, true, edges,
				step == null ? null : step.signature);
		IrReachability.prune(pruned, walk.reachable);
		IrReachability.trimTables(pruned, walk, edges);
		return {program: pruned, reachable: walk.reachable};
	}

	/** The plain program a walk that kept `names` makes of `program`, which gives it what it read. */
	static function apply(program:IrProgram, names:HlPlainNames):{program:IrProgram, reachable:Map<String, Bool>} {
		var pruned = program.copy();
		IrReachability.prune(pruned, names.reachable);
		pruned.natives = [for (native in pruned.natives) if (names.natives.exists(native.name)) native];
		pruned.staticFields = [for (field in pruned.staticFields) if (names.globals.exists(field.name)) field];
		pruned.objects = [for (object in pruned.objects) if (names.classes.exists(object.name)) object];
		return {program: pruned, reachable: names.reachable};
	}

	/** Where two plain programs keep different functions or tables, for `--check-reuse`; null when they keep the same. */
	static function difference(left:IrProgram, right:IrProgram):Null<String> {
		function names(label:String, a:Array<String>, b:Array<String>):Null<String>
			return IrObjectTools.sameNames(a, b) ? null : label;
		return names("functions", [for (fn in left.functions) fn.name], [for (fn in right.functions) fn.name])
			?? names("natives", [for (native in left.natives) native.name], [for (native in right.natives) native.name])
			?? names("globals", [for (field in left.staticFields) field.name],
			[for (field in right.staticFields) field.name])
			?? names("classes", [for (object in left.objects) object.name], [for (object in right.objects) object.name])
			?? names("methods", [for (object in left.objects) for (method in object.methods) method.functionName.name],
			[for (object in right.objects) for (method in object.methods) method.functionName.name]);
	}

	/** Assembles `program` as a plain build with no session: reachable from the entry, a fresh assembler that keeps nothing. */
	public static function assemble(program:IrProgram, developmentMetadata:Bool,
			?sources:compiler.core.SourceAnchor.SourceAnchors):HlModuleAssembler.HlAssemblyResult {
		var plain = reachable(program).program, assembler = assembler(developmentMetadata);
		assembler.sources = sources;
		return assembler.assemble(plain, [for (fn in plain.functions) fn.name], Patch);
	}

	/** The fresh assembler of a plain build, which keeps nothing for a next one. */
	public static function assembler(developmentMetadata:Bool):HlModuleAssembler {
		var assembler = new HlModuleAssembler();
		assembler.fieldReserve = 0;
		assembler.developmentMetadata = developmentMetadata;
		assembler.irVerified = true;
		assembler.livePatching = false;
		return assembler;
	}
}

/** What a plain build's walk and trim kept (`HlPlainBuild.reachable`): the reachable functions, and the natives, globals and classes. */
typedef HlPlainNames = {
	final reachable:Map<String, Bool>;
	final natives:Map<String, Bool>;
	final globals:Map<String, Bool>;
	final classes:Map<String, Bool>;
}

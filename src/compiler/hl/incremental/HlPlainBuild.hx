package compiler.hl.incremental;

import compiler.ir.analysis.IrReachability;
import compiler.ir.analysis.IrReachability.IrBodyEdges;
import compiler.ir.model.Ir.IrObjectTools;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.reuse.IrWalkRecord;

/**
 * A plain HashLink build, which no running module addresses by slot or stable id: it writes only what the entry reaches, from a
 * fresh assembler. `HashLinkBackendSession` assembles every build without live patching this way, and `HlBackend` is the same
 * assembly without a session.
 */
class HlPlainBuild {
	/**
	 * What a plain module is made of: a copy of `program` without the functions the entry does not reach, and without the methods of
	 * a class no reachable function mentions, with the reachable names. `program` keeps everything (other backends and tools read it).
	 * `summaries` keeps what the walk and the trim read of each function (`IrBodyEdges`), and the last walk with what it read
	 * (`IrWalkRecord`), which a build reuses while the program gives it the same. The reachable names are the record's: the caller
	 * reads them, never changes them.
	 */
	public static function reachable(program:IrProgram, checkReuse:Bool = false, ?summaries:HlFunctionSummaries):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		var given = [program.entryPoint], last = summaries == null ? null : summaries.reach;
		var kept = last == null || summaries == null ? null : last.holds(program, given, [], program.functions,
			(fn, edges) -> {
				// A function in blocks has no edges to compare: the walk reads its blocks.
				if (fn.body == null)
					return null;
				var now = summaries.walk.get(fn);
				if (now == null) {
					now = IrBodyEdges.of(fn);
					summaries.walk.set(fn, now);
				}
				return IrBodyEdges.same(edges, now) ? now : null;
			});
		if (kept != null && summaries != null) {
			var plain = apply(program, kept.result);
			if (checkReuse) {
				var fresh = walk(program, null);
				var difference = difference(plain.program, fresh.program);
				if (difference != null)
					throw new compiler.core
						.InternalError('--check-reuse: the plain build reused a reachability walk that differs from walking the program now ($difference)');
				IrReachability.checkTables(plain.program);
			}
			summaries.reach = kept;
			return plain;
		}
		if (last != null && summaries != null)
			last.eachSummary((fn, edges) -> if (summaries.walk.get(fn) == null) summaries.walk.set(fn, edges));
		var plain = walk(program, summaries);
		if (checkReuse)
			IrReachability.checkTables(plain.program);
		if (summaries != null)
			summaries.reach = record(program, given, plain.program, plain.reachable, summaries);
		return plain;
	}

	static function walk(program:IrProgram, summaries:Null<HlFunctionSummaries>):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		var pruned = program.copy(),
			memo = summaries == null ? null : summaries.walk,
			walk = IrReachability.walkWithGeneratedRuntimeRoots(program, program.entryPoint, null, true, memo);
		IrReachability.prune(pruned, walk.reachable);
		IrReachability.trimTables(pruned, walk, memo);
		return {program: pruned, reachable: walk.reachable};
	}

	/** The record of the walk of `program` that made `pruned`; null when a reached function's summary was not kept. */
	static function record(program:IrProgram, given:Array<String>, pruned:IrProgram, reachable:Map<String, Bool>,
			summaries:HlFunctionSummaries):Null<IrWalkRecord<IrBodyEdges, HlPlainNames>> {
		var edges:Array<Null<IrBodyEdges>> = [];
		for (fn in program.functions) {
			var walked = reachable.exists(fn.name) ? summaries.walk.get(fn) : null;
			if (walked == null && reachable.exists(fn.name))
				return null;
			edges.push(walked);
		}
		return new IrWalkRecord(program, given, [], program.functions.copy(), edges, {
			reachable: reachable,
			natives: [for (native in pruned.natives) native.name => true],
			globals: [for (field in pruned.staticFields) field.name => true],
			classes: [for (object in pruned.objects) object.name => true]
		});
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

/** What a plain build's walk and trim kept (`HlPlainBuild.reachable`): the reachable functions, and the natives, globals and classes. */
typedef HlPlainNames = {
	final reachable:Map<String, Bool>;
	final natives:Map<String, Bool>;
	final globals:Map<String, Bool>;
	final classes:Map<String, Bool>;
}

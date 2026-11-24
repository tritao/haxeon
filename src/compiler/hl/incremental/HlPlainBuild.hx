package compiler.hl.incremental;

import compiler.ir.analysis.IrReachability;
import compiler.ir.analysis.IrReachability.IrBodyEdges;
import compiler.ir.analysis.IrReachability.IrTrimSummary;
import compiler.ir.analysis.IrTypeAwareWalk.IrWalkRecord;
import compiler.ir.model.Ir.IrCNative;
import compiler.ir.model.Ir.IrEnum;
import compiler.ir.model.Ir.IrInterface;
import compiler.ir.model.Ir.IrNative;
import compiler.ir.model.Ir.IrObject;
import compiler.ir.model.Ir.IrObjectTools;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrStaticField;
import compiler.ir.model.IrFunction;
import compiler.ir.model.IrTypeIdentity;

/**
 * A plain HashLink build, which no running module addresses by slot or stable id: it writes only what the entry reaches, from a
 * fresh assembler. `HashLinkBackendSession` assembles every build without live patching this way, and `HlBackend` is the same
 * assembly without a session.
 */
class HlPlainBuild {
	/**
	 * What a plain module is made of: a copy of `program` without the functions the entry does not reach, and without the methods of
	 * a class no reachable function mentions, with the reachable names. `program` keeps everything (other backends and tools read it).
	 * `summaries` keeps what the trim reads of each function, and the last walk with what it read (`HlReachRecord`), which a build
	 * reuses while the program gives it the same. The reachable names are the record's: the caller reads them, never changes them.
	 */
	public static function reachable(program:IrProgram, checkReuse:Bool = false, ?summaries:HlFunctionSummaries):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		var last = summaries == null ? null : summaries.reach,
			kept = last == null ? null : last.holds(program, summaries);
		if (kept != null) {
			var plain = kept.apply(program);
			if (checkReuse) {
				var fresh = walk(program, null);
				var difference = HlReachRecord.difference(plain.program, fresh.program);
				if (difference != null)
					throw new compiler.core
						.InternalError('--check-reuse: the plain build reused a reachability walk that differs from walking the program now ($difference)');
				IrReachability.checkTables(plain.program);
			}
			summaries.reach = kept;
			return plain;
		}
		var plain = walk(program, summaries);
		if (checkReuse)
			IrReachability.checkTables(plain.program);
		if (summaries != null)
			summaries.reach = HlReachRecord.of(program, plain.program, plain.reachable, summaries);
		return plain;
	}

	static function walk(program:IrProgram, summaries:Null<HlFunctionSummaries>):{
		program:IrProgram,
		reachable:Map<String, Bool>
	} {
		var pruned = program.copy(),
			walk = IrReachability.walkWithGeneratedRuntimeRoots(program, program.entryPoint, null, true,
				summaries == null ? null : summaries.walk);
		IrReachability.prune(pruned, walk.reachable);
		IrReachability.trimTables(pruned, walk, summaries == null ? null : summaries.trim);
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

/**
 * What a plain build's reachability walk and trim (`HlPlainBuild.reachable`) read of the program, and what they kept. They read the
 * entry, the tables (the classes, interfaces, natives, C natives, static fields and enums), each function's name and declaration,
 * and, of each function they reached, its edges (`IrBodyEdges`) and what the trim names (`IrTrimSummary`). A program that gives
 * them the same keeps the same functions, natives, globals and classes: a function the walk did not reach adds nothing through its
 * body.
 */
class HlReachRecord {
	final entry:String;
	final functions:Array<IrFunction>;

	/** By position in `functions`, for a function the walk reached: its edges, or null for one without a body (its blocks are read). */
	final edges:Array<Null<IrBodyEdges>>;

	/** By position in `functions`: what the trim read of a reached function, null for one the walk did not reach. */
	final trims:Array<Null<IrTrimSummary>>;

	final objects:Array<IrObject>;
	final interfaces:Array<IrInterface>;
	final natives:Array<IrNative>;
	final cNatives:Array<IrCNative>;
	final staticFields:Array<IrStaticField>;
	final enums:Array<IrEnum>;

	final reachable:Map<String, Bool>;
	final keptNatives:Map<String, Bool>;
	final keptGlobals:Map<String, Bool>;
	final keptClasses:Map<String, Bool>;

	function new(program:IrProgram, edges:Array<Null<IrBodyEdges>>, trims:Array<Null<IrTrimSummary>>,
			reachable:Map<String, Bool>, keptNatives:Map<String, Bool>, keptGlobals:Map<String, Bool>,
			keptClasses:Map<String, Bool>) {
		entry = program.entryPoint;
		functions = program.functions.copy();
		this.edges = edges;
		this.trims = trims;
		objects = program.objects.copy();
		interfaces = program.interfaces.copy();
		natives = program.natives.copy();
		cNatives = program.cNatives.copy();
		staticFields = program.staticFields.copy();
		enums = program.enums.copy();
		this.reachable = reachable;
		this.keptNatives = keptNatives;
		this.keptGlobals = keptGlobals;
		this.keptClasses = keptClasses;
	}

	/** The record of the walk of `program` that made `pruned`; null when a reached function's summaries were not kept. */
	public static function of(program:IrProgram, pruned:IrProgram, reachable:Map<String, Bool>,
			summaries:HlFunctionSummaries):Null<HlReachRecord> {
		var edges:Array<Null<IrBodyEdges>> = [], trims:Array<Null<IrTrimSummary>> = [];
		for (fn in program.functions) {
			if (!reachable.exists(fn.name)) {
				edges.push(null);
				trims.push(null);
				continue;
			}
			var walked = fn.body == null ? null : summaries.walk.get(fn), trimmed = summaries.trim.get(fn);
			if (fn.body != null && walked == null || trimmed == null)
				return null;
			edges.push(walked);
			trims.push(trimmed);
		}
		return new HlReachRecord(program, edges, trims, reachable, [for (native in pruned.natives) native.name => true],
			[for (field in pruned.staticFields) field.name => true],
			[for (object in pruned.objects) object.name => true]);
	}

	/**
	 * This walk as the record of a walk of `program` now; null when the program gives the walk or the trim something else. The
	 * summaries of the functions it reached are kept for the walk that may come next.
	 */
	public function holds(program:IrProgram, summaries:HlFunctionSummaries):Null<HlReachRecord> {
		var now = program.functions;
		if (program.entryPoint != entry || now.length != functions.length || !sameTables(program))
			return null;
		var keptEdges:Null<Array<Null<IrBodyEdges>>> = null, keptTrims:Null<Array<Null<IrTrimSummary>>> = null;
		for (index in 0...now.length) {
			var fn = now[index], last = functions[index], trimmed = trims[index];
			if (fn == last) {
				if (trimmed != null) {
					var walked = edges[index];
					if (walked != null)
						summaries.walk.set(fn, walked);
					summaries.trim.set(fn, trimmed);
				}
				continue;
			}
			if (fn.name != last.name || !IrWalkRecord.sameDeclaration(fn, last))
				return null;
			if (trimmed == null)
				continue;
			var body = fn.body, walked = edges[index];
			if (body == null || walked == null)
				return null;
			var edgesNow = summaries.walk.get(fn);
			if (edgesNow == null) {
				edgesNow = IrBodyEdges.of(body);
				summaries.walk.set(fn, edgesNow);
			}
			var trimNow = summaries.trim.get(fn);
			if (trimNow == null) {
				trimNow = IrReachability.trimSummary(fn);
				summaries.trim.set(fn, trimNow);
			}
			if (!IrBodyEdges.same(walked, edgesNow) || !IrReachability.sameTrimSummary(trimmed, trimNow))
				return null;
			if (keptEdges == null || keptTrims == null) {
				keptEdges = edges.copy();
				keptTrims = trims.copy();
			}
			keptEdges[index] = edgesNow;
			keptTrims[index] = trimNow;
		}
		return new HlReachRecord(program, keptEdges ?? edges, keptTrims ?? trims, reachable, keptNatives, keptGlobals,
			keptClasses);
	}

	/** The plain program this walk makes of `program`, which gives it what it read. */
	public function apply(program:IrProgram):{program:IrProgram, reachable:Map<String, Bool>} {
		var pruned = program.copy();
		IrReachability.prune(pruned, reachable);
		pruned.natives = [for (native in pruned.natives) if (keptNatives.exists(native.name)) native];
		pruned.staticFields = [for (field in pruned.staticFields) if (keptGlobals.exists(field.name)) field];
		pruned.objects = [for (object in pruned.objects) if (keptClasses.exists(object.name)) object];
		return {program: pruned, reachable: reachable};
	}

	/** Where two plain programs keep different functions or tables, for `--check-reuse`; null when they keep the same. */
	public static function difference(left:IrProgram, right:IrProgram):Null<String> {
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

	/** Whether `program`'s tables give the walk and the trim what these gave them. */
	function sameTables(program:IrProgram):Bool {
		if (program.objects.length != objects.length || program.interfaces.length != interfaces.length
			|| program.natives.length != natives.length || program.cNatives.length != cNatives.length
			|| program.staticFields.length != staticFields.length || program.enums.length != enums.length)
			return false;
		for (index in 0...objects.length)
			if (!IrObjectTools.sameShape(program.objects[index], objects[index]))
				return false;
		for (index in 0...interfaces.length) {
			var left = program.interfaces[index], right = interfaces[index];
			if (left == right)
				continue;
			if (left.name != right.name || !IrObjectTools.sameNames(left.bases, right.bases)
				|| left.methods.length != right.methods.length)
				return false;
			for (method in 0...left.methods.length) {
				var a = left.methods[method], b = right.methods[method];
				if (a.name != b.name || !IrTypeIdentity.same(a.result, b.result)
					|| !IrTypeIdentity.sameList(a.arguments, b.arguments))
					return false;
			}
		}
		for (index in 0...natives.length) {
			var left = program.natives[index], right = natives[index];
			if (left != right
				&& (left.name != right.name || left.symbol != right.symbol
				|| !IrTypeIdentity.same(left.result, right.result)
				|| !IrTypeIdentity.sameList(left.arguments, right.arguments)
				|| !sameOptionalNames(left.generatedFunctionDependencies, right.generatedFunctionDependencies)))
				return false;
		}
		for (index in 0...cNatives.length) {
			var left = program.cNatives[index], right = cNatives[index];
			if (left != right
				&& (left.name != right.name || !IrTypeIdentity.same(left.result, right.result)
				|| !IrTypeIdentity.sameList(left.arguments, right.arguments)))
				return false;
		}
		for (index in 0...staticFields.length) {
			var left = program.staticFields[index], right = staticFields[index];
			if (left != right && (left.name != right.name || !IrTypeIdentity.same(left.type, right.type)))
				return false;
		}
		for (index in 0...enums.length) {
			var left = program.enums[index], right = enums[index];
			if (left == right)
				continue;
			if (left.name != right.name || left.cases.length != right.cases.length)
				return false;
			for (item in 0...left.cases.length)
				if (!IrTypeIdentity.sameList(left.cases[item].params, right.cases[item].params))
					return false;
		}
		return true;
	}

	static function sameOptionalNames(left:Null<Array<String>>, right:Null<Array<String>>):Bool
		return left == null || right == null ? left == right : IrObjectTools.sameNames(left, right);
}

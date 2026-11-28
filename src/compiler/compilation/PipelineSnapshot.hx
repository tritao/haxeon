package compiler.compilation;

import compiler.compilation.BackendSession.BackendAssemblyResult;
import compiler.core.InternalError;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.ir.codec.IrFunctionStateEquality;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.IrDeclarationEquality;
import compiler.ir.model.IrFunction;
import compiler.ir.pipeline.ProgramFacts;
import compiler.ir.pipeline.TargetProfile;
import haxe.io.Bytes;

/**
 * Everything the IR pipeline read for one build, outside the passes' own state: the typed functions' IR, the program tables, and the
 * environment (target, defines, the `IrGenerator` and `IrInliner` state the passes read, ...). The pipeline is a function of these.
 */
typedef PipelineInputs = {
	/** The frontend's IR of every typed function, in program order. */
	final functions:Array<IrFunction>;

	/** The static initializer functions generated for this build. */
	final initializers:Array<IrFunction>;

	/** The program tables, in a program of their own: natives, C natives, objects, interfaces, enums, static fields and the entry. */
	final tables:IrProgram;

	/** What the IR generator knows about the whole typed program, which the passes read through it. */
	final facts:ProgramFacts;

	/** Everything else the passes read, as one comparable text. */
	final environment:String;
}

/**
 * What one plain build produced from its `PipelineInputs`: the final IR and, once assembled, the backend result and the
 * environment it was assembled in. A build whose inputs are equal gets the same final IR and the same module, and runs no
 * pass and no lowering.
 *
 * It is the pipeline's root query, kept by the state the build made rather than as a memo of the session's database: its reads are
 * its inputs, each compared by its parts with the one it was made from (an object the program kept is the same object), so a
 * build that returns to an earlier state after a rejected one finds the earlier state's root. The database's revisions cannot
 * say that, as the inputs the rejected build gave are not taken back.
 */
class PipelineSnapshot {
	public final inputs:PipelineInputs;
	public final ir:IrProgram;

	/** The backend's result for `ir`, set once the build has assembled it; null until then. */
	public var backend:Null<BackendAssemblyResult>;

	/** What the backend read besides `ir`. */
	public var backendEnvironment:String = "";

	public function new(inputs:PipelineInputs, ir:IrProgram) {
		this.inputs = inputs;
		this.ir = ir;
	}

	/** Why `next` cannot reuse a build made from `this.inputs`, or null when it can. */
	public function mismatch(next:PipelineInputs):Null<String>
		return inputsDifference(inputs, next);

	/** What differs between two pipeline inputs, positions included, or null when the pipeline would read the same. */
	public static function inputsDifference(previous:PipelineInputs, next:PipelineInputs):Null<String> {
		if (previous.environment != next.environment)
			return "environment: " + firstDifference(previous.environment, next.environment);
		var tables = tablesDifference(previous.tables, next.tables);
		if (tables != null)
			return 'program tables: $tables';
		var facts = previous.facts.difference(next.facts);
		if (facts != null)
			return 'generator facts: $facts';
		var function_ = differingFunction(previous.functions, next.functions);
		if (function_ != null)
			return 'function $function_';
		var initializer = differingFunction(previous.initializers, next.initializers);
		return initializer == null ? null : 'initializer $initializer';
	}

	/**
	 * `--check-reuse` of the comparison by parts: inputs it found equal must have the same canonical encoding of their tables and the
	 * same text of their facts, which read every part. Throws otherwise.
	 */
	public static function checkEqualInputs(previous:PipelineInputs, next:PipelineInputs, profile:TargetProfile):Void {
		if (CanonicalIrCodec.encodeTables(previous.tables).compare(CanonicalIrCodec.encodeTables(next.tables)) != 0)
			throw new InternalError("--check-reuse: program tables compared equal by their parts encode otherwise");
		var before = previous.facts.inputState(profile), after = next.facts.inputState(profile);
		if (before != after)
			throw new InternalError("--check-reuse: generator facts compared equal by their parts render otherwise ("
				+ firstDifference(before, after) + ")");
	}

	/** The first table entry that differs between two programs' tables, by its kind and name, or null when they read the same. */
	static function tablesDifference(previous:IrProgram, next:IrProgram):Null<String> {
		if (previous.entryPoint != next.entryPoint)
			return "entry";
		return entriesDifference("native", previous.natives, next.natives, IrDeclarationEquality.sameNative,
			native -> native.name)
			?? entriesDifference("C native", previous.cNatives, next.cNatives, IrDeclarationEquality.sameCNative,
			native -> native.name)
			?? entriesDifference("object", previous.objects, next.objects, IrDeclarationEquality.sameObject,
			object -> object.name)
			?? entriesDifference("interface", previous.interfaces, next.interfaces, IrDeclarationEquality.sameInterface,
			interfaceDecl -> interfaceDecl.name)
			?? entriesDifference("enum", previous.enums, next.enums, IrDeclarationEquality.sameEnum,
			enumDecl -> enumDecl.name)
			?? entriesDifference("static field", previous.staticFields, next.staticFields,
			IrDeclarationEquality.sameStaticField, field -> field.name);
	}

	/** The first entry of `next` that differs from `previous`'s at its place, as `label` and its name, or null when none does. */
	static function entriesDifference<T>(label:String, previous:Array<T>, next:Array<T>, same:(T, T) -> Bool,
			name:T->String):Null<String> {
		if (previous.length != next.length)
			return '$label count ${previous.length} -> ${next.length}';
		for (index in 0...next.length)
			if (!same(previous[index], next[index]))
				return '$label ${name(next[index])}';
		return null;
	}

	/** What differs between two final programs, or null when they are equal: the first function that differs, or the tables. */
	public static function irDifference(previous:IrProgram, next:IrProgram):Null<String> {
		var byName:Map<String, IrFunction> = [for (fn in previous.functions) fn.name => fn];
		if (previous.functions.length != next.functions.length)
			return "function count " + previous.functions.length + " -> " + next.functions.length;
		for (fn in next.functions) {
			var old = byName.get(fn.name);
			if (old == null)
				return 'function ${fn.name} is new';
			if (!IrFunctionStateEquality.same(old, fn))
				return 'function ${fn.name} differs';
		}
		return tablesOf(previous).compare(tablesOf(next)) == 0 ? null : "program tables differ";
	}

	static function tablesOf(program:IrProgram):Bytes {
		var tables = new IrProgram(program.entryPoint);
		tables.natives = program.natives;
		tables.cNatives = program.cNatives;
		tables.objects = program.objects;
		tables.interfaces = program.interfaces;
		tables.enums = program.enums;
		tables.staticFields = program.staticFields;
		return CanonicalIrCodec.encodeTables(tables);
	}

	/** The label of the first line of two environment texts that differ. */
	/** For two lists separated by ";" (names of types can hold commas), the first entry only one has (" +name" when added, " -name"
		when removed), " order" when they hold the same entries, and nothing when either is not a list. */
	static function listDifference(previous:String, next:String):String {
		if (previous.indexOf(";") < 0 && next.indexOf(";") < 0)
			return "";
		var before:Map<String, Bool> = [for (entry in previous.split(";")) entry => true],
			after:Map<String, Bool> = [for (entry in next.split(";")) entry => true];
		for (entry in next.split(";"))
			if (!before.exists(entry))
				return ' +$entry';
		for (entry in previous.split(";"))
			if (!after.exists(entry))
				return ' -$entry';
		return " order";
	}

	static function firstDifference(previous:String, next:String):String {
		var left = previous.split("\n"), right = next.split("\n");
		for (index in 0...Std.int(Math.max(left.length, right.length))) {
			var a = index < left.length ? left[index] : "",
				b = index < right.length ? right[index] : "";
			if (a != b) {
				var label = a.length > 0 ? a : b;
				var end = label.indexOf(":");
				var brace = label.indexOf("{");
				if (end < 0 || (brace >= 0 && brace < end))
					end = brace;
				if (end < 0)
					return label.substr(0, 40);
				return label.substr(0, end) + listDifference(a.substr(end + 1), b.substr(end + 1));
			}
		}
		return "length";
	}

	static function count(functions:Array<IrFunction>, name:String):Int {
		var total = 0;
		for (fn in functions)
			if (fn.name == name)
				total++;
		return total;
	}

	static function differingFunction(previous:Array<IrFunction>, next:Array<IrFunction>):Null<String> {
		if (previous.length != next.length) {
			var before:Map<String, Bool> = [for (fn in previous) fn.name => true],
				after:Map<String, Bool> = [for (fn in next) fn.name => true];
			var removed = [for (fn in previous) if (!after.exists(fn.name)) fn.name],
				added = [for (fn in next) if (!before.exists(fn.name)) fn.name];
			var repeated:Array<String> = [], seen:Map<String, Bool> = [];
			for (fn in previous.concat(next)) {
				if (seen.exists(fn.name) && repeated.indexOf(fn.name) < 0
					&& (count(previous, fn.name) > 1 || count(next, fn.name) > 1))
					repeated.push(fn.name);
				seen.set(fn.name, true);
			}
			return "count " + previous.length + " -> " + next.length + " (removed: " + removed.slice(0,
				3).join(", ") + "; added: "
				+ added.slice(0, 3).join(", ") + "; listed twice: " + repeated.slice(0, 3).join(", ") + ")";
		}
		for (index in 0...previous.length)
			if (!IrFunctionStateEquality.same(previous[index], next[index]))
				return next[index].name;
		return null;
	}
}

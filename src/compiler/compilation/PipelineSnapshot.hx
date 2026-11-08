package compiler.compilation;

import compiler.compilation.BackendAssembly.BackendAssemblyResult;
import compiler.ir.Ir.IrProgram;
import compiler.ir.IrFunction;
import compiler.ir.codec.CanonicalIrCodec;
import compiler.ir.codec.IrFunctionStateEquality;
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

	/** The canonical encoding of the program tables: natives, C natives, objects, interfaces, enums and static fields. */
	final tables:Bytes;

	/** Everything else the passes read, as one comparable text. */
	final environment:String;
}

/**
 * What one plain build produced from its `PipelineInputs`: the final IR and, once assembled, the backend result and the
 * environment it was assembled in. A build whose inputs are equal gets the same final IR and the same module, and runs no
 * pass and no lowering.
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
	public function mismatch(next:PipelineInputs):Null<String> {
		if (inputs.environment != next.environment)
			return "environment: " + firstDifference(inputs.environment, next.environment);
		if (inputs.tables.compare(next.tables) != 0)
			return "program tables";
		var function_ = differingFunction(inputs.functions, next.functions);
		if (function_ != null)
			return 'function $function_';
		var initializer = differingFunction(inputs.initializers, next.initializers);
		return initializer == null ? null : 'initializer $initializer';
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
				return end < 0 ? label.substr(0, 40) : label.substr(0, end);
			}
		}
		return "length";
	}

	static function differingFunction(previous:Array<IrFunction>, next:Array<IrFunction>):Null<String> {
		if (previous.length != next.length)
			return "count " + previous.length + " -> " + next.length;
		for (index in 0...previous.length)
			if (!IrFunctionStateEquality.same(previous[index], next[index]))
				return next[index].name;
		return null;
	}
}

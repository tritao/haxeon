package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance;

/**
 * The functions an instrumented build probes: glob patterns over qualified function names (`*` matches any run of
 * characters). A pattern also matches every member of the class or package it names, so `Math` covers `Math.sin` and
 * `haxe.ds` covers `haxe.ds.StringMap.get`. Generated closures match by the function that declares them.
 */
class IrInstrumentationScope {
	public final include:Array<String>;
	public final exclude:Array<String>;

	final includePatterns:Array<EReg>;
	final excludePatterns:Array<EReg>;

	public function new(include:Array<String>, exclude:Array<String>) {
		this.include = include.length == 0 ? ["*"] : include;
		this.exclude = exclude;
		includePatterns = [for (pattern in this.include) compile(pattern)];
		excludePatterns = [for (pattern in exclude) compile(pattern)];
	}

	/** Parses the `haxeon-instrument-include` / `-exclude` define value: patterns separated by commas. */
	public static function patterns(value:Null<String>):Array<String> {
		if (value == null)
			return [];
		return [for (pattern in value.split(",")) if (StringTools.trim(pattern) != "") StringTools.trim(pattern)];
	}

	public function key():String
		return include.join(",") + "|" + exclude.join(",");

	public function covers(functionName:String):Bool {
		var subject = declaringName(functionName);
		for (pattern in excludePatterns)
			if (pattern.match(subject))
				return false;
		for (pattern in includePatterns)
			if (pattern.match(subject))
				return true;
		return false;
	}

	/** `$lambda:pkg.Class.method:local#0` is matched as `pkg.Class.method`. */
	static function declaringName(name:String):String {
		if (!StringTools.startsWith(name, "$"))
			return name;
		var start = name.indexOf(":");
		if (start < 0)
			return name;
		var end = name.indexOf(":", start + 1);
		return end < 0 ? name.substr(start + 1) : name.substring(start + 1, end);
	}

	static function compile(pattern:String):EReg {
		var body = [for (part in pattern.split("*")) escape(part)].join(".*");
		return new EReg("^" + body + "(\\..*)?$", "");
	}

	static function escape(text:String):String {
		var out = new StringBuf();
		for (i in 0...text.length) {
			var c = text.charAt(i);
			if ("\\^$.|?*+()[]{}".indexOf(c) >= 0)
				out.add("\\");
			out.add(c);
		}
		return out.toString();
	}
}

/**
 * Adds profiler probes to a function after inlining, so only functions that remain calls are probed: an enter probe at
 * entry, an exit probe before every return, and, around every try, the instrumentation depth saved before the try and
 * restored in its catch, which closes the slices of the calls a throw skipped. Throws leave no exit probe; the catch
 * that stops them (or the runtime, for one that reaches C) unwinds instead. A function the scope leaves out still saves
 * and restores the depth around its tries, since a throw it catches may have skipped probed calls.
 *
 * Each backend lowers the probes: HashLink calls libhl natives (the x86-64 JIT inlines their recording check), and wasm drops them.
 */
class IrInstrumentation {
	public static inline var Enter = "__prof_enter";
	public static inline var Exit = "__prof_exit";
	public static inline var Depth = "__prof_depth";
	public static inline var Unwind = "__prof_unwind";

	public static function natives():Array<IrNative>
		return [
			{name: Enter, library: "std", symbol: "prof_call_enter", arguments: [], result: Void},
			{name: Exit, library: "std", symbol: "prof_call_exit", arguments: [], result: Void},
			{name: Depth, library: "std", symbol: "prof_call_depth", arguments: [], result: I32},
			{name: Unwind, library: "std", symbol: "prof_call_unwind", arguments: [I32], result: Void}
		];

	public static function isProbe(name:String):Bool
		return name == Enter || name == Exit || name == Depth || name == Unwind;

	/**
	 * The program without probes, for a backend that does not record yet: probe calls go, and a saved depth becomes 0.
	 * Functions without probes are kept as they are.
	 */
	public static function strip(program:IrProgram):IrProgram {
		if (![for (native in program.natives) native.name].contains(Enter))
			return program;
		var functions:Array<IrFunction> = [];
		for (fn in program.functions) {
			var probed = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, name, _) if (isProbe(name)):
							probed = true;
						case _:
					}
			if (!probed) {
				functions.push(fn);
				continue;
			}
			var blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var copy = new IrBlock(block.id);
				for (located in block.instructions)
					switch located.value {
						case Call(output, Depth, _):
							copy.instructions.push(new Located(ConstInt(output, 0), located.provenance));
						case Call(_, name, _) if (isProbe(name)):
						case _:
							copy.instructions.push(located);
					}
				copy.terminator = block.terminator;
				blocks.push(copy);
			}
			functions.push(new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention));
		}
		program.functions = functions;
		program.natives = [for (native in program.natives) if (!isProbe(native.name)) native];
		return program;
	}

	/** The function with probes, or the function itself when the scope leaves it out and it has no try. */
	public static function apply(fn:IrFunction, scope:IrInstrumentationScope):IrFunction {
		if (fn.blocks.length == 0)
			return fn;
		var covered = scope.covers(fn.name);
		if (!covered && !hasTry(fn))
			return fn;
		var nextValue = 0;
		for (argument in fn.arguments)
			if (argument.id >= nextValue)
				nextValue = argument.id + 1;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id >= nextValue)
					nextValue = output.id + 1;
				for (input in IrOperands.inputs(located.value))
					if (input.id >= nextValue)
						nextValue = input.id + 1;
			}
		inline function value(type:IrType):IrValue
			return new IrValue(nextValue++, "$prof", type);
		var provenance = SourceProvenance.generated("profiler probe");
		inline function op(instruction:IrInstruction):Located<IrInstruction>
			return new Located(instruction, provenance);

		// The depth each try saved, by its catch block.
		var savedDepth:Map<Int, IrValue> = [];
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				switch located.value {
					case BeginTry(catchBlock, _):
						var depth = value(I32);
						savedDepth.set(catchBlock, depth);
						copy.instructions.push(op(Call(depth, Depth, [])));
					case _:
				}
				copy.instructions.push(located);
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		for (block in blocks) {
			// A catch block starts with its Catch (after any phis); the unwind follows it.
			for (index in 0...block.instructions.length)
				switch block.instructions[index].value {
					case Catch(_):
						var depth = savedDepth.get(block.id);
						if (depth != null)
							block.instructions.insert(index + 1, op(Call(value(Void), Unwind, [depth])));
						break;
					case _:
				}
			if (covered && block.terminator != null)
				switch block.terminator.value {
					case Return(_):
						block.instructions.push(op(Call(value(Void), Exit, [])));
					case _:
				}
		}
		if (covered) {
			var entry = blocks[0], firstOrdinary = 0;
			while (firstOrdinary < entry.instructions.length && entry.instructions[firstOrdinary].value.match(Phi(_, _)))
				firstOrdinary++;
			entry.instructions.insert(firstOrdinary, op(Call(value(Void), Enter, [])));
		}
		return new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention);
	}

	static function hasTry(fn:IrFunction):Bool {
		for (block in fn.blocks)
			for (located in block.instructions)
				if (located.value.match(BeginTry(_, _)))
					return true;
		return false;
	}
}

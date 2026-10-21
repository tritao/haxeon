package compiler.backend.wasm;

import compiler.ir.Ir;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.ir.IrOperands;
import compiler.ir.SourceProvenance.Located;
import compiler.ir.SourceProvenance;

/**
 * Normalize calls before either Wasm representation is chosen, without modifying cached frontend IR.
 * Dynamic calls adapt a checked callable to the call site's boxed signature. Typed calls only check null.
 * std.make_var_args captures its callback in an ordinary owning object. The resulting closure is marked
 * by its reserved target (linear) or signature -1 (GC); closure casts pack their arguments and call it
 * through VARARGS_CALL at its actual Array<Dynamic> signature, preserving omission versus explicit null.
 */
class WasmDynamicCalls {
	public static inline final VARARGS_TARGET = "__haxeon_varargs_target";
	public static inline final VARARGS_CALL = "__haxeon_varargs_call";
	static inline final CAPTURE = "__haxeon_varargs_capture";

	public static function callbackType():IrType
		return Function([Array(Dyn)], Dyn);

	public static function run(program:IrProgram):IrProgram {
		var result = new IrProgram(program.entryPoint);
		result.objects = program.objects.copy();
		result.interfaces = program.interfaces;
		result.enums = program.enums;
		result.staticFields = program.staticFields;
		result.natives = program.natives.copy();
		result.cNatives = program.cNatives;
		var helpers:Map<String, IrFunction> = [],
			targets:Map<String, IrType> = [],
			varargs = false;
		var makers = [
			for (n in program.natives)
				if (n.library == "std" && n.symbol == "make_var_args") n.name => true
		];
		var isFunction = "__reflect_is_function";
		for (n in program.natives)
			if (n.symbol == isFunction)
				isFunction = n.name;
		var needsFunctionTest = false;
		for (fn in program.functions) {
			var nextId = 0;
			for (arg in fn.arguments)
				nextId = Std.int(Math.max(nextId, arg.id + 1));
			for (block in fn.blocks)
				for (ins in block.instructions) {
					var out = IrOperands.output(ins.value);
					if (out != null)
						nextId = Std.int(Math.max(nextId, out.id + 1));
				}
			function temp(type:IrType):IrValue
				return new IrValue(nextId++, "wasm-call", type);
			var blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var copy = new IrBlock(block.id);
				copy.terminator = block.terminator;
				for (ins in block.instructions) {
					function emit(value:IrInstruction):Void
						copy.instructions.push(new Located(value, ins.provenance));
					switch ins.value {
						case SafeCast(out, _) if (switch out.type {
								case Function(_, _): true;
								default: false;
							}):
							targets.set(Std.string(out.type), out.type);
							copy.instructions.push(ins);
						case Call(out, name, args) if (makers.exists(name)):
							varargs = true;
							var capture = temp(Obj(CAPTURE)),
								closure = temp(callbackType());
							emit(NewObject(capture, CAPTURE));
							emit(FieldSet(capture, "callback", args[0]));
							emit(InstanceClosure(closure, VARARGS_TARGET, capture));
							emit(ToDyn(out, closure));
						case CallClosure(out, closure, args):
							var dynamicCall = closure.type == Dyn;
							if (dynamicCall)
								needsFunctionTest = true;
							var signature:IrType = dynamicCall ? Function([for (a in args) a.type], out.type) : closure.type;
							if (dynamicCall)
								targets.set(Std.string(signature), signature);
							var key = (dynamicCall ? "dynamic:" : "typed:") + Std.string(signature);
							if (!helpers.exists(key))
								helpers.set(key, callHelper("__haxeon_invoke_" + [for (_ in helpers.keys()) 1].length, signature, dynamicCall, isFunction));
							var callee = closure;
							if (dynamicCall) {
								callee = temp(Dyn);
								emit(ToDyn(callee, closure));
							}
							emit(Call(out, helpers.get(key).name, [callee].concat(args)));
						default:
							copy.instructions.push(ins);
					}
				}
				blocks.push(copy);
			}
			result.functions.push(new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention));
		}
		if (needsFunctionTest && !Lambda.exists(result.natives, n -> n.name == isFunction))
			result.natives.push({
				name: isFunction,
				library: "haxeon_runtime",
				symbol: "__reflect_is_function",
				arguments: [Dyn],
				result: Bool
			});
		if (varargs) {
			result.objects.push({
				name: CAPTURE,
				isValue: false,
				base: null,
				interfaces: [],
				fields: [{name: "callback", type: callbackType()}],
				methods: []
			});
			var b = new IrBuilder(),
				capture = b.argument("capture", Obj(CAPTURE)),
				args = b.argument("arguments", Array(Dyn));
			b.returnValue(b.callClosure(b.fieldGet(capture, "callback", callbackType()), [args], Dyn));
			result.functions.push(new IrFunction(VARARGS_TARGET, b.arguments, Dyn, b.blocks));
			if (!Lambda.exists(result.natives, n -> n.name == "__array_alloc_ref"))
				result.natives.push({
					name: "__array_alloc_ref",
					library: "haxeon_runtime",
					symbol: "__array_alloc_ref",
					arguments: [I32],
					result: Array(Dyn)
				});
			var names = [for (key in targets.keys()) key];
			names.sort(Reflect.compare);
			for (key in names)
				result.functions.push(varargsAdapter(varargsAdapterName(targets.get(key)), targets.get(key)));
			result.natives.push({
				name: VARARGS_CALL,
				library: "haxeon_runtime",
				symbol: VARARGS_CALL,
				arguments: [Dyn, Array(Dyn)],
				result: Dyn
			});
		}
		var keys = [for (key in helpers.keys()) key];
		keys.sort(Reflect.compare);
		for (key in keys)
			result.functions.push(helpers.get(key));
		return result;
	}

	public static function varargsAdapterName(type:IrType):String
		return "__haxeon_varargs_adapter_" + Std.string(type);

	public static function varargsAdapter(name:String, type:IrType):IrFunction {
		var b = new IrBuilder(),
			original = b.argument("closure", Dyn),
			params:Array<IrType> = [],
			result:IrType = Void;
		switch type {
			case Function(a, r):
				params = a;
				result = r;
			default:
				throw "Invalid varargs adapter";
		}
		var values = [for (i in 0...params.length) b.argument("argument" + i, params[i])];
		var array = b.call("__array_alloc_ref", [b.constInt(values.length)], Array(Dyn));
		for (i in 0...values.length) {
			var index = b.constInt(i),
				value = values[i].type == Dyn ? values[i] : b.toDyn(values[i]);
			b.currentBlock().instructions.push(new Located(ArraySet(array, index, value), SourceProvenance.generated("wasm-varargs")));
		}
		var called = b.call(VARARGS_CALL, [original, array], Dyn);
		b.returnValue(result == Void ? b.constVoid() : result == Dyn ? called : b.safeCast(called, result));
		return new IrFunction(name, b.arguments, result, b.blocks, null, false, Keep);
	}

	static function callHelper(name:String, type:IrType, dynamicCall:Bool, isFunction:String):IrFunction {
		var b = new IrBuilder(),
			closure = b.argument("closure", dynamicCall ? Dyn : type),
			params:Array<IrType> = [],
			result:IrType = Void;
		switch type {
			case Function(a, r):
				params = a;
				result = r;
			default:
				throw "Invalid closure signature";
		}
		var args = [for (i in 0...params.length) b.argument("argument" + i, params[i])];
		var missing = b.createBlock(), present = b.createBlock();
		b.branch(b.equal(closure, b.constNull(closure.type)), missing, present);
		b.select(missing);
		b.terminate(Throw(b.toDyn(b.constString("Null access"))));
		b.select(present);
		if (dynamicCall) {
			var callable = b.createBlock(), invalid = b.createBlock();
			b.branch(b.call(isFunction, [closure], Bool), callable, invalid);
			b.select(invalid);
			b.terminate(Throw(b.toDyn(b.constString("Cannot call a non-function value"))));
			b.select(callable);
		}
		b.returnValue(b.callClosure(dynamicCall ? b.safeCast(closure, type) : closure, args, result));
		return new IrFunction(name, b.arguments, result, b.blocks);
	}
}

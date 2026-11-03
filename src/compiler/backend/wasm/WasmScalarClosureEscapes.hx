package compiler.backend.wasm;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrBuilder;
import compiler.ir.IrValueInterfaceBoxes;
import compiler.ir.IrCheckedObjectCasts;
import compiler.ir.SourceProvenance.Located;

/** Adapts scalar closures only at Dynamic and exported host boundaries. */
class WasmScalarClosureEscapes {
	public static inline final RESTORE_CALL_PREFIX = "$wasm:closure-restore-call:";
	final program:IrProgram;
	final scalar:Map<String, Bool>;
	final adapters:Map<String, String> = [];
	final restorations:Map<String, String> = [];
	final generatedFunctions:Array<IrFunction> = [];
	final generatedObjects:Array<IrObject> = [];

	public static function rewrite(program:IrProgram, scalar:Map<String, Bool>, exports:Array<String>, exportAdapters:Map<String, String>):IrProgram {
		var pass = new WasmScalarClosureEscapes(program, scalar), result = new IrProgram(program.entryPoint);
		result.functions = [for (fn in program.functions) {
			var rewritten = pass.rewriteFunction(fn);
			if (exports.indexOf(fn.name) >= 0 && pass.exportAdapter(fn, exportAdapters))
				rewritten = new IrFunction(rewritten.name, rewritten.arguments, rewritten.result, rewritten.blocks, rewritten.debugBindings,
					rewritten.inlineHint, Reachable);
			rewritten;
		}];
		result.objects = program.objects.concat(pass.generatedObjects);
		var generated = IrValueInterfaceBoxes.rewrite(pass.generatedFunctions, result.objects, program.interfaces, result.functions);
		generated = IrCheckedObjectCasts.rewrite(generated, result.objects, true, result.functions);
		for (fn in generated) result.functions.push(fn);
		result.natives = program.natives.copy(); result.cNatives = program.cNatives;
		var hasTypeTest = false;
		for (native in result.natives) if (native.name == "__std_is_of_type") hasTypeTest = true;
		if (!hasTypeTest && generated.length > 0) result.natives.push({name: "__std_is_of_type", library: "haxeon_runtime",
			symbol: "__std_is_of_type", arguments: [Dyn, TypeRef], result: Bool});
		result.interfaces = program.interfaces; result.enums = program.enums; result.staticFields = program.staticFields;
		result.positionalFingerprints = program.positionalFingerprints; result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces; result.positionalSources = program.positionalSources;
		return result;
	}

	function exportAdapter(fn:IrFunction, mappings:Map<String, String>):Bool {
		var needs = scalar.exists(Std.string(fn.result));
		for (arg in fn.arguments) if (scalar.exists(Std.string(arg.type))) needs = true;
		if (!needs) return false;
		var name = "$wasm:export-closure:" + fn.name, b = new IrBuilder();
		var args:Array<IrValue> = [];
		for (arg in fn.arguments) {
			if (scalar.exists(Std.string(arg.type))) {
				var value = b.argument(arg.name, Dyn);
				args.push(b.call(restoration(arg.type), [value], arg.type));
			} else args.push(b.argument(arg.name, arg.type));
		}
		var result = b.call(fn.name, args, fn.result), resultType = fn.result;
		if (scalar.exists(Std.string(fn.result))) {
			result = b.call(adapter(fn.result), [result], Dyn);
			resultType = Dyn;
		}
		b.returnValue(result);
		generatedFunctions.push(new IrFunction(name, b.arguments, resultType, b.blocks));
		mappings.set(fn.name, name);
		return true;
	}

	function new(program:IrProgram, scalar:Map<String, Bool>) {
		this.program = program;
		this.scalar = scalar;
	}

	function rewriteFunction(fn:IrFunction):IrFunction {
		var blocks:Array<IrBlock> = [], changed = false;
		for (block in fn.blocks) {
			var rewritten = new IrBlock(block.id);
			for (located in block.instructions) switch located.value {
				case ToDyn(out, input) if (scalar.exists(Std.string(input.type))):
					var maker = adapter(input.type);
					rewritten.instructions.push(new Located(Call(out, maker, [input]), located.provenance));
					changed = true;
				case SafeCast(out, input) if ((switch (input.type) { case Dyn: true; default: false; }) && scalar.exists(Std.string(out.type))):
					var maker = restoration(out.type);
					rewritten.instructions.push(new Located(Call(out, maker, [input]), located.provenance));
					changed = true;
				default: rewritten.instructions.push(located);
			}
			rewritten.terminator = block.terminator;
			blocks.push(rewritten);
		}
		return changed ? new IrFunction(fn.name, fn.arguments, fn.result, blocks, fn.debugBindings, fn.inlineHint, fn.retention) : fn;
	}

	function adapter(type:IrType):String {
		var key = Std.string(type), found = adapters.get(key);
		if (found != null) return found;
		var suffix = haxe.crypto.Sha256.encode(key).substr(0, 32), environment = "$wasm:closure-escape:" + suffix,
			invoke = "$wasm:closure-escape-call:" + suffix, maker = "$wasm:closure-escape-make:" + suffix,
			signature = switch type { case Function(arguments, result): {arguments: arguments, result: result};
				default: throw "A scalar closure escape must have a function type"; };
		adapters.set(key, maker);
		generatedObjects.push({name: environment, isValue: false, base: null, interfaces: [], fields: [{name: "closure", type: type}], methods: []});
		var call = new IrBuilder(), receiver = call.argument("receiver", Obj(environment)),
			arguments = [for (index in 0...signature.arguments.length) call.argument('argument$index', Dyn)],
			closure = call.fieldGet(receiver, "closure", type), adapted:Array<IrValue> = [];
		for (index in 0...arguments.length)
			adapted.push((switch (signature.arguments[index]) { case Dyn: true; default: false; }) ? arguments[index] : call.safeCast(arguments[index], signature.arguments[index]));
		var value = call.callClosure(closure, adapted, signature.result);
		call.returnValue((switch (signature.result) { case Void: true; default: false; }) ? call.constNull(Dyn) : (switch (signature.result) { case Dyn: true; default: false; }) ? value : call.toDyn(value));
		generatedFunctions.push(new IrFunction(invoke, call.arguments, Dyn, call.blocks));
		var make = new IrBuilder(), original = make.argument("closure", type), missing = make.createBlock(), present = make.createBlock();
		make.branch(make.equal(original, make.constNull(type)), missing, present);
		make.select(missing);
		make.returnValue(make.constNull(Dyn));
		make.select(present);
		var captured = make.newObject(environment), erasedType:IrType = Function([for (_ in signature.arguments) Dyn], Dyn);
		make.fieldSet(captured, "closure", original);
		make.returnValue(make.toDyn(make.instanceClosure(invoke, captured, erasedType)));
		generatedFunctions.push(new IrFunction(maker, make.arguments, Dyn, make.blocks));
		return maker;
	}

	/** A restored closure keeps the Dynamic call on its boundary while publishing the typed scalar ABI. */
	function restoration(type:IrType):String {
		var key = Std.string(type), found = restorations.get(key);
		if (found != null) return found;
		var suffix = haxe.crypto.Sha256.encode(key).substr(0, 32), environment = "$wasm:closure-restored:" + suffix,
			invoke = RESTORE_CALL_PREFIX + suffix, maker = "$wasm:closure-restore-make:" + suffix,
			signature = switch type { case Function(arguments, result): {arguments: arguments, result: result};
				default: throw "A restored scalar closure must have a function type"; },
			dynamicType:IrType = Function([for (_ in signature.arguments) Dyn], Dyn);
		restorations.set(key, maker);
		generatedObjects.push({name: environment, isValue: false, base: null, interfaces: [],
			fields: [{name: "closure", type: dynamicType}], methods: []});
		var call = new IrBuilder(), receiver = call.argument("receiver", Obj(environment)),
			arguments = [for (index in 0...signature.arguments.length) call.argument('argument$index', signature.arguments[index])],
			closure = call.fieldGet(receiver, "closure", dynamicType), boxed = [for (argument in arguments) (switch (argument.type) { case Dyn: true; default: false; }) ? argument : call.toDyn(argument)],
			value = call.callClosure(closure, boxed, Dyn);
		if ((switch (signature.result) { case Void: true; default: false; })) call.returnValue(call.constVoid());
		else call.returnValue((switch (signature.result) { case Dyn: true; default: false; }) ? value : call.safeCast(value, signature.result));
		generatedFunctions.push(new IrFunction(invoke, call.arguments, signature.result, call.blocks));
		var make = new IrBuilder(), original = make.argument("closure", Dyn), missing = make.createBlock(), present = make.createBlock();
		make.branch(make.equal(original, make.constNull(Dyn)), missing, present);
		make.select(missing);
		make.returnValue(make.constNull(type));
		make.select(present);
		var decoded = make.safeCast(original, dynamicType), captured = make.newObject(environment);
		make.fieldSet(captured, "closure", decoded);
		make.returnValue(make.instanceClosure(invoke, captured, type));
		generatedFunctions.push(new IrFunction(maker, make.arguments, type, make.blocks));
		return maker;
	}
}

package compiler.backend.wasm.gc;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmLocal;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringKind;
import compiler.backend.wasm.WasmRepresentation.WasmLoweringResult;
import compiler.backend.wasm.WasmTypes.WasmFunctionType;
import compiler.backend.wasm.WasmTypes.WasmInstruction;
import compiler.backend.wasm.WasmTypes.WasmValueType;

/**
 * Casts between function types for Wasm GC closures, as HashLink's dynamic cast wraps a closure.
 *
 * A closure calls its target with `call_indirect` at the call site's function type, which traps unless the target
 * was declared with exactly that type. Haxe converts closures between function types whose values are represented
 * differently (an `Int->Int` lambda stored in an `Int->T` field is called as `(i32)->anyref`), so every closure
 * records the Wasm signature it was created with. A cast to a function type with another signature calls that
 * type's cast function, which wraps the closure in an adapter: an instance closure that converts the arguments,
 * calls the original at its own signature and converts the result.
 */
class WasmGcClosureAdapters {
	final plan:WasmGcTypePlan;
	final module:WasmModule;
	final types:Map<Int, IrType> = [];
	final targets:Array<Int> = [];
	final sources:Array<Int> = [];

	function new(module:WasmModule, plan:WasmGcTypePlan) {
		this.module = module;
		this.plan = plan;
	}

	public static inline function castName(signature:Int):String
		return '__haxeon_closure_cast_$signature';

	static inline function adapterName(source:Int, target:Int):String
		return '__haxeon_closure_adapter_${source}_$target';

	/** The Wasm function type a closure of this type is called with, which identifies its signature. */
	public static function signature(module:WasmModule, plan:WasmGcTypePlan, type:IrType):Int
		return switch type {
			case Function(arguments, result): module.typeIndex(plan.wasmFunctionType(arguments, result));
			default: throw 'Wasm GC closure has a non-function type ${Std.string(type)}';
		};

	/** The function type of an instance closure's target, which takes the receiver first. */
	public static function instanceType(module:WasmModule, plan:WasmGcTypePlan, type:IrType):Int
		return switch type {
			case Function(arguments, result): module.typeIndex({
					parameters: [Ref({nullable: true, heap: Any})].concat([for (argument in arguments) plan.valueType(argument)]),
					results: result == Void ? [] : [plan.valueType(result)]
				});
			default: throw 'Wasm GC closure has a non-function type ${Std.string(type)}';
		};

	/**
	 * Reserves a cast function for every function type a reachable function casts to, and an adapter for every
	 * signature a closure of the same arity may have been created with. Adapters take table slots, so this runs
	 * before the table is built; `define` fills the bodies.
	 */
	public static function reserve(module:WasmModule, plan:WasmGcTypePlan, functions:Map<String, Int>, program:IrProgram,
			reachable:Map<String, Bool>):WasmGcClosureAdapters {
		var adapters = new WasmGcClosureAdapters(module, plan),
			created:Map<Int, Bool> = [],
			castTo:Map<Int, Bool> = [];
		function note(type:IrType, into:Map<Int, Bool>):Void {
			var key = signature(module, plan, type);
			if (!adapters.types.exists(key))
				adapters.types.set(key, type);
			into.set(key, true);
		}
		for (fn in program.functions)
			if (reachable.exists(fn.name))
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case StaticClosure(output, _) | InstanceClosure(output, _, _):
								note(output.type, created);
							case SafeCast(output, _):
								switch output.type {
									case Function(_, _): note(output.type, castTo);
									default:
								}
							default:
						}
		// An adapted closure has its target's signature and may be cast again.
		for (key in castTo.keys())
			created.set(key, true);
		for (key in castTo.keys())
			adapters.targets.push(key);
		for (key in created.keys())
			adapters.sources.push(key);
		adapters.targets.sort((left, right) -> left - right);
		adapters.sources.sort((left, right) -> left - right);
		var closure = plan.valueType(Function([], Void));
		for (target in adapters.targets) {
			functions.set(castName(target), module.addFunction(new WasmFunction(castName(target), {parameters: [closure], results: [closure]})));
			for (source in adapters.adaptable(target)) {
				var name = adapterName(source, target);
				functions.set(name, module.addFunction(new WasmFunction(name, module.functionTypeAt(instanceType(module, plan, adapters.types.get(target))))));
			}
		}
		return adapters;
	}

	/** Created signatures a closure cast to `target` may have and needs adapting from: other ones of the same arity. */
	function adaptable(target:Int):Array<Int>
		return [
			for (source in sources)
				if (source != target && arity(source) == arity(target)) source
		];

	function arity(key:Int):Int
		return switch types.get(key) {
			case Function(arguments, _): arguments.length;
			default: -1;
		};

	public function define(functions:Map<String, Int>, representation:WasmGcRepresentation, tableSlots:Map<String, Int>):Void
		for (target in targets) {
			defineCast(target, functions, tableSlots);
			for (source in adaptable(target))
				defineAdapter(source, target, functions, representation);
		}

	/** Returns the closure unchanged when it already has the target signature, else wraps it in an adapter. */
	function defineCast(target:Int, functions:Map<String, Int>, tableSlots:Map<String, Int>):Void {
		var closureType = plan.closureTypeIndex,
			signatureLocal = 1,
			body:Array<WasmInstruction> = [
				LocalGet(0),
				StructGet(closureType, WasmGcTypePlan.CLOSURE_SIGNATURE_FIELD),
				LocalTee(signatureLocal),
				I32Const(target),
				I32Eq,
				If(null),
				LocalGet(0),
				Return,
				End
			];
		for (source in adaptable(target)) {
			var slot = tableSlots.get(adapterName(source, target));
			if (slot == null)
				throw 'Wasm GC closure adapter ${adapterName(source, target)} has no table slot';
			body = body.concat([
				LocalGet(signatureLocal),
				I32Const(source),
				I32Eq,
				If(null),
				I32Const(slot * 2),
				LocalGet(0),
				I32Const(target),
				StructNew(closureType),
				Return,
				End
			]);
		}
		// No closure of this arity can be converted, as a failed reference cast traps.
		body.push(Unreachable);
		var name = castName(target);
		module.setFunction(functions.get(name), new WasmFunction(name, module.functionType(functions.get(name)), [{type: I32}], body));
	}

	/** Receives the original closure and the target's arguments; converts each way through Dynamic where they differ. */
	function defineAdapter(source:Int, target:Int, functions:Map<String, Int>, representation:WasmGcRepresentation):Void {
		var name = adapterName(source, target),
			type:WasmFunctionType = module.functionType(functions.get(name)),
			sourceType = types.get(source),
			targetType = types.get(target);
		var sourceArguments:Array<IrType> = [],
			sourceResult:IrType = Void,
			targetArguments:Array<IrType> = [],
			targetResult:IrType = Void;
		switch [sourceType, targetType] {
			case [Function(sa, sr), Function(ta, tr)]:
				sourceArguments = sa;
				sourceResult = sr;
				targetArguments = ta;
				targetResult = tr;
			default:
		}
		var locals:Array<WasmLocal> = [], nextLocal = type.parameters.length;
		function allocateLocal(valueType:WasmValueType):Int {
			locals.push({type: valueType});
			return nextLocal++;
		}
		var lowering = representation.forFunction({allocateLocal: allocateLocal, exceptionTag: null, irFunction: null}),
			body:Array<WasmInstruction>;
		try {
			body = adapterBody(lowering, allocateLocal, source, sourceArguments, sourceResult, targetArguments, targetResult);
		} catch (error:String) {
			// A value with no Dynamic form (a borrowed native pointer) cannot cross; such a cast traps.
			locals = [];
			body = [Unreachable];
		}
		module.setFunction(functions.get(name), new WasmFunction(name, type, locals, body));
	}

	function adapterBody(lowering:WasmGcRepresentation, allocateLocal:WasmValueType->Int, source:Int, sourceArguments:Array<IrType>, sourceResult:IrType,
			targetArguments:Array<IrType>, targetResult:IrType):Array<WasmInstruction> {
		var closure = allocateLocal(plan.valueType(Function([], Void))),
			body:Array<WasmInstruction> = [
				LocalGet(0),
				RefCast({nullable: false, heap: Type(plan.closureTypeIndex)}),
				LocalSet(closure)
			];
		var converted = [
			for (index in 0...sourceArguments.length)
				convert(lowering, allocateLocal, body, targetArguments[index], sourceArguments[index], index + 1)
		];
		var result = sourceResult == Void ? -1 : allocateLocal(plan.valueType(sourceResult));
		body = body.concat(handled(lowering.callClosure(source, instanceType(module, plan, types.get(source)),
			[for (argument in sourceArguments) value(argument)], closure, result, converted)));
		if (targetResult != Void) {
			if (sourceResult == Void)
				body = body.concat(lowering.zeroValue(targetResult));
			else
				body.push(LocalGet(convert(lowering, allocateLocal, body, sourceResult, targetResult, result)));
		}
		body.push(Return);
		return body;
	}

	/** Converts a value between closure parameter or result types, through Dynamic when their Wasm types differ. */
	function convert(lowering:WasmGcRepresentation, allocateLocal:WasmValueType->Int, body:Array<WasmInstruction>, from:IrType, to:IrType, local:Int):Int {
		if (Type.enumEq(plan.valueType(from), plan.valueType(to)))
			return local;
		var boxed = local;
		if (from != Dyn) {
			boxed = allocateLocal(plan.valueType(Dyn));
			for (instruction in handled(lowering.toDynamic(value(from), boxed, local)))
				body.push(instruction);
		}
		if (to == Dyn)
			return boxed;
		var output = allocateLocal(plan.valueType(to));
		for (instruction in handled(lowering.safeCast(value(to), value(Dyn), output, boxed)))
			body.push(instruction);
		return output;
	}

	static function value(type:IrType):IrValue
		return new IrValue(-1, "closure-adapter-operand", type);

	static function handled(result:WasmLoweringResult):Array<WasmInstruction>
		return switch result {
			case Handled(instructions): instructions;
			case UseDefault: throw "Wasm GC closure adapter conversion has no lowering";
		};
}

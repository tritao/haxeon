package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.IrBuilder;
import compiler.ir.IrFunction;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmProgramIndex;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

/**
 * Casts between function types for linear-memory closures, as HashLink's dynamic cast wraps a closure.
 *
 * A closure value is a tagged table slot (static target) or a closure object holding a slot and a receiver, and
 * call sites `call_indirect` it at their own type. Int, Bool and Dynamic are all i32 here, so a closure created
 * as `Int->Int` and called as `Int->T` (T erased to Dynamic) does not trap but reads a boxed pointer as an Int,
 * and a Float closure traps. Functions in the table are ordered by their representation key (each argument raw
 * Int, Bool, Int64, Float, F32 or a reference that converts to Dynamic unchanged), so the key query maps a
 * closure's slot to its key. A cast to a function type with another key wraps the closure in an adapter: an
 * instance closure whose receiver is the original closure, converting arguments and result through Dynamic.
 * Casts, adapters and the key query are IR functions so they lower, root and box like any other code; the key
 * query alone gets a Wasm body once the table is laid out.
 */
class WasmLinearClosureAdapters {
	public static inline final KEY_FUNCTION = "__haxeon_closure_key";

	final program:IrProgram;
	final keyIds:Map<String, Int> = [];
	final nativeKeys:Map<String, String> = [];

	function new(program:IrProgram)
		this.program = program;

	public static function castName(type:IrType):String
		return '__haxeon_closure_cast_${closureKey(type)}';

	static function adapterName(source:String, target:String):String
		return '__haxeon_closure_adapter_${source}_$target';

	/** How a value of this type is held: closures agree on these exactly when their call needs no conversion. */
	static function valueKey(type:IrType):String
		return switch type {
			case I32: "i";
			case Bool: "b";
			case I64: "l";
			case F32: "f";
			case F64: "d";
			case Void: "v";
			default: "r";
		};

	static function functionKey(arguments:Array<IrType>, result:IrType):String
		return [for (argument in arguments) valueKey(argument)].join("") + "_" + valueKey(result);

	/** The key a closure of this type is created with when its target is called without a receiver. */
	static function closureKey(type:IrType):String
		return switch type {
			case Function(arguments, result): functionKey(arguments, result);
			default: throw 'Linear Wasm closure has a non-function type ${Std.string(type)}';
		};

	/** The key of an instance closure's target, which takes the receiver (a reference) first. */
	static function instanceKey(type:IrType):String
		return "r" + closureKey(type);

	static function arguments(type:IrType):Array<IrType>
		return switch type {
			case Function(arguments, _): arguments;
			default: [];
		};

	static function result(type:IrType):IrType
		return switch type {
			case Function(_, result): result;
			default: Void;
		};

	/**
	 * Adds a cast function for every function type the program casts to, an adapter from every other closure key
	 * of the same arity, and the key query, all kept so they reach the module without IR calls naming them.
	 */
	public static function generate(program:IrProgram):WasmLinearClosureAdapters {
		var adapters = new WasmLinearClosureAdapters(program);
		for (native in program.natives)
			adapters.nativeKeys.set(native.name, functionKey(native.arguments, native.result));
		if (Lambda.exists(program.functions, fn -> fn.name == KEY_FUNCTION))
			throw "Linear Wasm closure adapters were generated twice for one program";
		var targetTypes:Map<String, IrType> = [],
			sourceTypes:Map<String, IrType> = [];
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case StaticClosure(output, _) | InstanceClosure(output, _, _):
							if (!sourceTypes.exists(closureKey(output.type)))
								sourceTypes.set(closureKey(output.type), output.type);
						case SafeCast(output, _):
							switch output.type {
								case Function(_, _):
									if (!targetTypes.exists(closureKey(output.type))) targetTypes.set(closureKey(output.type), output.type);
								default:
							}
						default:
					}
		// An adapted closure has its target's key and may be cast again.
		for (key => type in targetTypes)
			if (!sourceTypes.exists(key))
				sourceTypes.set(key, type);
		var targets = [for (key in targetTypes.keys()) key],
			sources = [for (key in sourceTypes.keys()) key];
		targets.sort(Reflect.compare);
		sources.sort(Reflect.compare);
		var pairs = [
			for (target in targets)
				{
					target: target,
					sources: [
						for (source in sources)
							if (source != target
								&& arguments(sourceTypes.get(source)).length == arguments(targetTypes.get(target)).length) source
					]
				}
		];
		// Key ids are fixed before the casts that compare against them are built, so collect every key the table can hold.
		var keys:Map<String, Bool> = ["?" => true];
		for (fn in program.functions)
			keys.set(functionKey([for (argument in fn.arguments) argument.type], fn.result), true);
		for (key in adapters.nativeKeys)
			keys.set(key, true);
		keys.set(functionKey([Dyn], Dyn), true);
		keys.set(functionKey([Dyn], I32), true);
		for (pair in pairs)
			keys.set(instanceKey(targetTypes.get(pair.target)), true);
		var ordered = [for (key in keys.keys()) key];
		ordered.sort(Reflect.compare);
		for (index in 0...ordered.length)
			adapters.keyIds.set(ordered[index], index);
		program.functions.push(adapters.keyQuery());
		for (pair in pairs) {
			var targetType = targetTypes.get(pair.target);
			for (source in pair.sources)
				program.functions.push(adapter(sourceTypes.get(source), source, targetType, pair.target));
			program.functions.push(adapters.castFunction(targetType, [for (source in pair.sources) {key: source, type: sourceTypes.get(source)}]));
		}
		return adapters;
	}

	/** A placeholder body; the backend defines the query once table slots are known (see defineKeyQuery). */
	function keyQuery():IrFunction {
		var builder = new IrBuilder();
		builder.argument("closure", Dyn);
		builder.returnValue(builder.constInt(-1));
		return new IrFunction(KEY_FUNCTION, builder.arguments, I32, builder.blocks, null, false, Keep);
	}

	/** A closure's key code: twice its target's key id, plus one when it has a receiver. */
	function code(key:String, instance:Bool):Int {
		var id = keyIds.get(key);
		return id == null ? -2 : id * 2 + (instance ? 1 : 0);
	}

	/** Returns the closure when it already has the target's key, else an adapter around it. */
	function castFunction(targetType:IrType, sources:Array<{key:String, type:IrType}>):IrFunction {
		var builder = new IrBuilder(),
			closure = builder.argument("closure", Dyn),
			key = builder.call(KEY_FUNCTION, [closure], I32);
		function when(codes:Array<Int>, body:Void->Void):Void
			for (value in codes) {
				var matched = builder.createBlock(),
					next = builder.createBlock();
				builder.branch(builder.equal(key, builder.constInt(value)), matched, next);
				builder.select(matched);
				body();
				builder.select(next);
			}
		// Null, a closure of this type, or a value the query does not know is returned unchanged.
		when([-1, code(closureKey(targetType), false), code(instanceKey(targetType), true)], () -> builder.returnValue(closure));
		for (source in sources)
			when([code(source.key, false), code(instanceKey(source.type), true)],
				() -> builder.returnValue(builder.toDyn(builder.instanceClosure(adapterName(source.key, closureKey(targetType)), closure, targetType))));
		builder.returnValue(closure);
		return new IrFunction(castName(targetType), builder.arguments, Dyn, builder.blocks, null, false, Keep);
	}

	/** Receives the original closure and the target's arguments; converts each way through Dynamic. */
	static function adapter(sourceType:IrType, source:String, targetType:IrType, target:String):IrFunction {
		var builder = new IrBuilder(), original = builder.argument("closure", Dyn), targetArguments = [
			for (index => type in arguments(targetType))
				builder.argument('argument$index', type)
		], sourceArguments = arguments(sourceType), callee = builder.safeCast(original, sourceType), converted = [
			for (index in 0...sourceArguments.length)
				convert(builder, targetArguments[index], sourceArguments[index])
			], sourceResult = result(sourceType), targetResult = result(targetType), value = builder.callClosure(callee, converted, sourceResult);
		builder.returnValue(targetResult == Void ? (sourceResult == Void ? value : builder.constVoid()) : sourceResult == Void ? zero(builder,
			targetResult) : convert(builder, value, targetResult));
		return new IrFunction(adapterName(source, target), builder.arguments, targetResult, builder.blocks, null, false, Keep);
	}

	static function convert(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		if (Type.enumEq(value.type, type))
			return value;
		if (type == Dyn)
			return builder.toDyn(value);
		return builder.safeCast(value.type == Dyn ? value : builder.toDyn(value), type);
	}

	static function zero(builder:IrBuilder, type:IrType):IrValue
		return switch type {
			case I32: builder.constInt(0);
			case Bool: builder.constBool(false);
			case F32 | F64: builder.constFloat(0, type);
			default: builder.constNull(type);
		};

	/** Orders table slots by representation key, then name, so each key holds a contiguous slot range. */
	public function slotOrder(name:String):String {
		var fn = WasmProgramIndex.of(program).func(name);
		var key = fn != null ? functionKey([for (argument in fn.arguments) argument.type], fn.result) : nativeKeys.get(name);
		return key != null && keyIds.exists(key) ? key : "?";
	}

	/**
	 * Defines the key query: null gives -1; a tagged slot or a closure object's slot gives its target's key code;
	 * anything else gives -3, which no cast matches.
	 */
	public function defineKeyQuery(module:WasmModule, functions:Map<String, Int>, tableSlots:Map<String, Int>):Void {
		var index = functions.get(KEY_FUNCTION);
		if (index == null)
			return;
		var named = [for (name => slot in tableSlots) {slot: slot, id: keyIds.get(slotOrder(name))}];
		named.sort((left, right) -> left.slot - right.slot);
		var runs:Array<{start:Int, id:Int}> = [];
		for (entry in named)
			if (runs.length == 0 || runs[runs.length - 1].id != entry.id)
				runs.push({start: entry.slot, id: entry.id});
		var slot = 1, instance = 2;
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(-1),
			Return,
			End,
			LocalGet(0),
			I32Const(1),
			I32And,
			If(null),
			LocalGet(0),
			I32Const(1),
			I32ShrU,
			LocalSet(slot),
			Else,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmLayout.CLOSURE_TYPE_ID),
			I32Eq,
			I32Eqz,
			If(null),
			I32Const(-3),
			Return,
			End,
			LocalGet(0),
			I32Load(WasmLayout.CLOSURE_FUNCTION_OFFSET),
			LocalSet(slot),
			I32Const(1),
			LocalSet(instance),
			End
		];
		body = body.concat(lookup(runs, 0, runs.length, slot));
		body = body.concat([I32Const(2), I32Mul, LocalGet(instance), I32Add, Return]);
		module.setFunction(index, new WasmFunction(KEY_FUNCTION, module.functionType(index), [{type: I32}, {type: I32}], body));
	}

	/** Pushes the key id of the run holding `slot`, by binary search over the runs' first slots. */
	static function lookup(runs:Array<{start:Int, id:Int}>, from:Int, to:Int, slot:Int):Array<WasmInstruction> {
		if (to - from <= 1)
			return [I32Const(from < runs.length ? runs[from].id : -2)];
		var middle = (from + to) >> 1;
		return [LocalGet(slot), I32Const(runs[middle].start), I32LtS, If(I32)].concat(lookup(runs, from, middle, slot))
			.concat([Else])
			.concat(lookup(runs, middle, to, slot))
			.concat([End]);
	}
}

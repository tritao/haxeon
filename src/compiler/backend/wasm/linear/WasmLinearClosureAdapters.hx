package compiler.backend.wasm.linear;

import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrValue;
import compiler.ir.Ir.IrBlock;
import compiler.ir.Ir.IrInstruction;
import compiler.ir.IrBuilder;
import compiler.ir.IrReachability;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmModuleSupport;
import compiler.backend.wasm.WasmDynamicCalls;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

/**
 * Casts linear-memory closures by semantic signature. Static closures refer to immutable module
 * descriptors; bound closures keep their signature in the existing header. A Dynamic cast to a
 * different signature creates an adapter, as on the other runtimes.
 */
class WasmLinearClosureAdapters {
	public static inline final SIGNATURE_FUNCTION = "__haxeon_closure_signature";

	public static function staticDescriptorKey(name:String, type:IrType):String
		return haxe.Json.stringify([name, Std.string(type)]);

	final program:IrProgram;
	final signatureIds:Map<String, Int> = [];
	final inlineEnums:Map<String, String> = [];

	function new(program:IrProgram) {
		this.program = program;
		for (declaration in program.enums)
			if (declaration.inlineStorage != null)
				inlineEnums.set(declaration.inlineStorage, declaration.name);
	}

	public function signatureId(type:IrType):Int {
		var id = signatureIds.get(Std.string(type));
		if (id == null)
			throw 'Unplanned Wasm32 closure signature ${Std.string(type)}';
		return id;
	}

	public function castName(type:IrType):String
		return '__haxeon_closure_cast_${signatureId(type)}';

	static function adapterName(source:Int, target:Int):String
		return '__haxeon_closure_adapter_${source}_$target';

	static function closureKey(type:IrType):String
		return Std.string(type);

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

	/** Generate adapters for each semantic source and target of the same arity. */
	public static function generate(program:IrProgram, scalarClosures:Map<String, Bool>, entry:String, roots:Array<String>):WasmLinearClosureAdapters {
		var adapters = new WasmLinearClosureAdapters(program);
		if (Lambda.exists(program.functions, fn -> fn.name == SIGNATURE_FUNCTION))
			throw "Linear Wasm closure adapters were generated twice for one program";
		var targetTypes:Map<String, IrType> = [],
			sourceTypes:Map<String, IrType> = [];
		var signatureTypes:Map<String, Bool> = [];
		function noteType(type:IrType):Void {
			switch type {
				case Function(args, result):
					var text = Std.string(type);
					if (signatureTypes.exists(text))
						return;
					signatureTypes.set(text, true);
					for (arg in args)
						noteType(arg);
					noteType(result);
				case Array(element) | Iterator(element) | Nullable(element):
					noteType(element);
				default:
			}
		}
		var reachable = IrReachability.withGeneratedRuntimeRoots(program, entry, roots);
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case InstanceClosure(_, name, _) if (name == WasmDynamicCalls.VARARGS_TARGET):
						case StaticClosure(output, _) | InstanceClosure(output, _, _):
							noteType(output.type);
							if (reachable.exists(fn.name) && !scalarClosures.exists(Std.string(output.type)))
								sourceTypes.set(closureKey(output.type), output.type);
						case SafeCast(output, _):
							switch output.type {
								case Function(_, _):
									noteType(output.type);
									if (reachable.exists(fn.name)) targetTypes.set(closureKey(output.type), output.type);
								default:
							}
						case TypeValue(_, type):
							switch type {
								case Function(_, _): noteType(type);
								default:
							}
						default:
					}
		var orderedSignatures = [for (key in signatureTypes.keys()) key];
		orderedSignatures.sort(Reflect.compare);
		for (index in 0...orderedSignatures.length)
			adapters.signatureIds.set(orderedSignatures[index], index + 1);
		// Every generated adapter may cast nested function arguments or results, as well as
		// its original closure. Those casts require their own dispatchers and adapters.
		var changed = true;
		while (changed) {
			changed = false;
			for (key => type in targetTypes)
				if (!sourceTypes.exists(key)) {
					sourceTypes.set(key, type);
					changed = true;
				}
			var targetsNow = [for (key in targetTypes.keys()) key],
				sourcesNow = [for (key in sourceTypes.keys()) key];
			for (target in targetsNow)
				for (source in sourcesNow)
					if (source != target && arguments(sourceTypes.get(source)).length == arguments(targetTypes.get(target)).length) {
						var fn = adapters.adapter(sourceTypes.get(source), targetTypes.get(target));
						for (block in fn.blocks)
							for (located in block.instructions)
								switch located.value {
									case SafeCast(output, _):
										switch output.type {
											case Function(_, _):
												var key = closureKey(output.type);
												if (!targetTypes.exists(key)) {
													targetTypes.set(key, output.type);
													changed = true;
												}
											default:
										}
									default:
								}
					}
		}
		var targets = [for (key in targetTypes.keys()) key],
			sources = [for (key in sourceTypes.keys()) key];
		targets.sort(Reflect.compare);
		sources.sort(Reflect.compare);
		if (reachable.exists(WasmDynamicCalls.VARARGS_TARGET)) {
			sources.push("varargs");
			sourceTypes.set("varargs", WasmDynamicCalls.callbackType());
		}
		var pairs = [
			for (target in targets)
				{
					target: target,
					sources: [
						for (source in sources)
							if (source != target
								&& (source == "varargs"
									|| arguments(sourceTypes.get(source)).length == arguments(targetTypes.get(target)).length)) source
					]
				}
		];
		program.functions.push(adapters.signatureQuery());
		adapters.rewriteSignatureChecks();
		for (pair in pairs) {
			var targetType = targetTypes.get(pair.target);
			for (source in pair.sources)
				if (source != "varargs")
					program.functions.push(adapters.adapter(sourceTypes.get(source), targetType));
			program.functions.push(adapters.castFunction(targetType, [for (source in pair.sources) {key: source, type: sourceTypes.get(source)}]));
		}
		return adapters;
	}

	/** Checked erased writes compare the semantic closure signature. */
	public function rewriteSignatureChecks():Void {
		var helpers:Map<String, IrType> = [], rewritten:Array<IrFunction> = [];
		for (fn in program.functions) {
			var types:Map<Int, IrType> = [];
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case TypeValue(out, type):
							types.set(out.id, type);
						default:
					}
			var changed = false, blocks:Array<IrBlock> = [];
			for (block in fn.blocks) {
				var target = new IrBlock(block.id);
				for (located in block.instructions)
					switch located.value {
						case Call(out, "__closure_is_of_type", arguments) if (arguments.length == 2 && types.exists(arguments[1].id)):
							var type = types.get(arguments[1].id),
								name = "$wasm:closure-type-check:" + haxe.crypto.Sha256.encode(Std.string(type)).substr(0, 32);
							helpers.set(name, type);
							target.instructions.push(new Located(IrInstruction.Call(out, name, [arguments[0]]), located.provenance));
							changed = true;
						default:
							target.instructions.push(located);
					}
				target.terminator = block.terminator;
				blocks.push(target);
			}
			rewritten.push(changed ? fn.withBlocks(blocks) : fn);
		}
		var names = [for (name in helpers.keys()) name];
		names.sort(Reflect.compare);
		for (name in names) {
			var type = helpers.get(name),
				b = new IrBuilder(),
				value = b.argument("closure", Dyn),
				signature = b.call(SIGNATURE_FUNCTION, [value], I32);
			b.returnValue(b.equal(signature, b.constInt(signatureId(type))));
			rewritten.push(new IrFunction(name, b.arguments, Bool, b.blocks, GeneratedHelper));
		}
		program.functions = rewritten;
	}

	function signatureQuery():IrFunction {
		var builder = new IrBuilder();
		builder.argument("closure", Dyn);
		builder.returnValue(builder.constInt(0));
		return new IrFunction(SIGNATURE_FUNCTION, builder.arguments, I32, builder.blocks, GeneratedHelper, null, false, Keep);
	}

	public function defineSignatureQuery(module:WasmModule, functions:Map<String, Int>):Void {
		var index = functions.get(SIGNATURE_FUNCTION);
		if (index == null)
			return;
		var body:Array<WasmInstruction> = [
			LocalGet(0),
			I32Eqz,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Const(1),
			I32And,
			If(null),
			LocalGet(0),
			I32Const(-2),
			I32And,
			I32Load(WasmLayout.STATIC_CLOSURE_SIGNATURE_OFFSET),
			Return,
			End,
			LocalGet(0),
			I32Load(0),
			I32Const(WasmLayout.CLOSURE_TYPE_ID),
			I32Eq,
			I32Eqz,
			If(null),
			I32Const(0),
			Return,
			End,
			LocalGet(0),
			I32Load(WasmLayout.CLOSURE_SIGNATURE_OFFSET),
			Return
		];
		module.setFunction(index, new WasmFunction(SIGNATURE_FUNCTION, module.functionType(index), [], body));
	}

	/** Return an already matching closure; adapt a different semantic signature at the cast. */
	function castFunction(targetType:IrType, sources:Array<{key:String, type:IrType}>):IrFunction {
		var builder = new IrBuilder(),
			closure = builder.argument("closure", Dyn),
			signature = builder.call(SIGNATURE_FUNCTION, [closure], I32);
		var missing = builder.createBlock(), present = builder.createBlock();
		builder.branch(builder.equal(closure, builder.constNull(Dyn)), missing, present);
		builder.select(missing);
		builder.returnValue(closure);
		builder.select(present);
		function when(value:Int, body:Void->Void):Void {
			var matched = builder.createBlock(), next = builder.createBlock();
			builder.branch(builder.equal(signature, builder.constInt(value)), matched, next);
			builder.select(matched);
			body();
			builder.select(next);
		}
		when(signatureId(targetType), () -> builder.returnValue(closure));
		for (source in sources)
			when(source.key == "varargs" ? -1 : signatureId(source.type),
				() ->
					builder.returnValue(builder.toDyn(builder.instanceClosure(source.key == "varargs" ? WasmDynamicCalls.varargsAdapterName(targetType) : adapterName(signatureId(source.type),
						signatureId(targetType)),
					closure, targetType))));
		builder.throwValue(builder.toDyn(builder.constString('Cannot cast to ${Std.string(targetType)}')));
		return new IrFunction(castName(targetType), builder.arguments, Dyn, builder.blocks, ClosureCast(targetType), null, false, Reachable);
	}

	/** Receives the original closure and the target's arguments; converts each way through Dynamic. */
	function adapter(sourceType:IrType, targetType:IrType):IrFunction {
		var builder = new IrBuilder(), original = builder.argument("closure", Dyn), targetTypes = arguments(targetType), targetArguments = [
			for (index in 0...targetTypes.length)
				builder.argument('argument$index', targetTypes[index])
		], sourceArguments = arguments(sourceType), callee = builder.safeCast(original, sourceType), converted = [
			for (index in 0...sourceArguments.length)
				convert(builder, targetArguments[index], sourceArguments[index])
			], sourceResult = result(sourceType), targetResult = result(targetType), value = builder.callClosure(callee, converted, sourceResult);
		builder.returnValue((switch (targetResult) {
			case Void: true;
			default: false;
		}) ? ((switch (sourceResult) {
			case Void: true;
			default: false;
		}) ? value : builder.constVoid()) : (switch (sourceResult) {
			case Void: true;
			default: false;
		}) ? zero(builder, targetResult) : convert(builder, value, targetResult));
		return new IrFunction(adapterName(signatureId(sourceType), signatureId(targetType)), builder.arguments, targetResult, builder.blocks,
			ClosureAdapter(sourceType, targetType), null, false, Reachable);
	}

	function convert(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		if (Type.enumEq(value.type, type))
			return value;
		if ((switch (value.type) {
			case I32: true;
			default: false;
		}) && (switch (type) {
			case Bool: true;
			default: false;
		}))
			return builder.equal(builder.equal(value, builder.constInt(0)), builder.constBool(false));
		var dynamicValue = (switch (value.type) {
			case Dyn: true;
			default: false;
		}) ? value : toDynamic(builder, value);
		if ((switch (type) {
			case Dyn: true;
			default: false;
		}))
			return dynamicValue;
		return fromDynamic(builder, dynamicValue, type);
	}

	function toDynamic(builder:IrBuilder, value:IrValue):IrValue {
		switch value.type {
			case EnumTag(name):
				return builder.intrinsic(EnumTagBox(EnumTag(name)), [value], Dyn);
			default:
		}
		var enumName = switch value.type {
			case Obj(name): inlineEnums.get(name);
			default: null;
		};
		return enumName == null ? builder.toDyn(value) : builder.intrinsic(InlineEnumBox(Enum(enumName)), [value], Dyn);
	}

	function fromDynamic(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		switch type {
			case EnumTag(name):
				return builder.intrinsic(EnumTagUnbox(EnumTag(name)), [value], type);
			default:
		}
		var enumName = switch type {
			case Obj(name): inlineEnums.get(name);
			default: null;
		};
		return enumName == null ? builder.safeCast(value, type) : builder.intrinsic(InlineEnumUnbox(Enum(enumName)), [value], type);
	}

	static function zero(builder:IrBuilder, type:IrType):IrValue
		return switch type {
			case I32: builder.constInt(0);
			case I64: builder.constInt(0, I64);
			case Bool: builder.constBool(false);
			case F32 | F64: builder.constFloat(0, type);
			default: builder.constNull(type);
		};
}

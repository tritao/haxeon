package compiler.backend.wasm.linear;
import compiler.ir.model.IrSymbol;

import compiler.core.InternalError;
import compiler.ir.model.IrTypeIdentity;
import compiler.ir.passes.scalars.IrScalarArguments;
import compiler.ir.model.Ir.IrProgram;
import compiler.ir.model.Ir.IrType;
import compiler.ir.model.Ir.IrValue;
import compiler.ir.model.Ir.IrBlock;
import compiler.ir.model.Ir.IrInstruction;
import compiler.ir.model.IrBuilder;
import compiler.ir.analysis.IrReachability;
import compiler.ir.model.IrFunction;
import compiler.ir.model.SourceProvenance.Located;
import compiler.backend.wasm.WasmLayout;
import compiler.backend.wasm.WasmDynamicCalls;
import compiler.backend.wasm.WasmModule.WasmFunction;
import compiler.backend.wasm.WasmModule.WasmModule;
import compiler.backend.wasm.WasmTypes.WasmInstruction;

/**
 * Casts linear-memory closures by semantic signature. Static closures refer to immutable module
 * descriptors; bound closures keep their signature in the existing header. A Dynamic cast to a
 * different signature creates an adapter, as on the other runtimes (see `generate` for its shape).
 */
class WasmLinearClosureAdapters {
	public static inline final SIGNATURE_FUNCTION = "__haxeon_closure_signature";
	static inline final ARITY_FUNCTION = "__haxeon_closure_arity";

	public static function staticDescriptorKey(name:String, type:IrType):String
		return haxe.Json.stringify([name, IrTypeIdentity.text(type)]);

	final program:IrProgram;
	final signatureIds:Map<String, Int> = [];
	/** Signature ids run from 1 to this count. */
	var signatureCount = 0;
	final inlineEnums:Map<String, String> = [];

	function new(program:IrProgram) {
		this.program = program;
		for (declaration in program.enums)
			if (declaration.inlineStorage != null)
				inlineEnums.set(declaration.inlineStorage, declaration.name);
	}

	public function signatureId(type:IrType):Int {
		var id = signatureIds.get(IrTypeIdentity.text(type));
		if (id == null)
			throw new InternalError('Unplanned Wasm32 closure signature ${Std.string(type)}');
		return id;
	}

	public function castName(type:IrType):String
		return '__haxeon_closure_cast_${signatureId(type)}';

	/** The one adapter of a target signature, whatever the source. */
	static function adapterName(target:Int):String
		return '__haxeon_closure_adapter_$target';

	static function invokerName(source:Int):String
		return '__haxeon_closure_invoker_$source';

	static function dispatcherName(arity:Int):String
		return '__haxeon_closure_invoke_$arity';

	/**
	 * Whether a closure of `type` can be boxed, and so reach a dispatcher: not a scalar closure, nor one that takes or gives
	 * one, which the verifier keeps from crossing a Dynamic or cast boundary. Such a signature has no invoker or adapter.
	 */
	static function crossesDynamic(type:IrType):Bool
		return switch type {
			case Function(arguments, result):
				!IrScalarArguments.isPrivateClosureType(type) && crossesDynamic(result)
					&& !Lambda.exists(arguments, argument -> !crossesDynamic(argument));
			case _: true;
		};

	static function closureKey(type:IrType):String
		return IrTypeIdentity.text(type);

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
	 * Plans the closure casts of a program, in code linear in its closure signatures rather than in their pairs.
	 *
	 * A cast to a target signature T returns a closure that already has T, wraps the varargs closure in T's varargs
	 * adapter, and wraps any other closure whose signature has T's arity in T's ONE adapter. That adapter boxes T's
	 * arguments to Dynamic and calls `__haxeon_closure_invoke_<arity>`, which switches on the closure's runtime
	 * signature to that source signature's invoker; the invoker unboxes the arguments to the source's types, calls the
	 * closure at its own signature and boxes the result, which the adapter converts to T's result. Each signature thus
	 * costs one cast, one adapter and one invoker, instead of one adapter per (source, target) pair of the same arity,
	 * which grew to over a million functions for ~2,000 signatures.
	 *
	 * Why every cast still finds its adapter: a closure's runtime signature is written only where the closure is made.
	 * That is a StaticClosure or InstanceClosure in a reachable function (collected below), an adapter made by a cast
	 * function here (its signature is that cast's target, and every target is planned as a source), or the varargs
	 * closure (-1, which the cast handles itself). Generated bodies that cast again (an invoker casting its receiver or
	 * a nested function argument, an adapter its result) add their targets, and the loop below runs until no body adds
	 * one. So every signature a cast can observe has an invoker and an arity entry, and every target has an adapter: the
	 * cast accepts exactly the (source, target) pairs of equal arity that the per-pair adapters accepted, without
	 * enumerating them. Any other signature (0 for a value that is not a closure) throws "Cannot cast" as before.
	 */
	public static function generate(program:IrProgram, scalarClosures:Map<String, Bool>, entry:String,
			roots:Array<String>):WasmLinearClosureAdapters {
		var adapters = new WasmLinearClosureAdapters(program);
		if (Lambda.exists(program.functions, fn -> fn.name == SIGNATURE_FUNCTION))
			throw new InternalError("Linear Wasm closure adapters were generated twice for one program");
		// Every semantic signature a closure may have at runtime, which is also every signature cast to.
		var planned:Map<String, IrType> = [];
		var signatureTypes:Map<String, Bool> = [];
		function noteType(type:IrType):Void {
			switch type {
				case Function(args, result):
					var text = IrTypeIdentity.text(type);
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
						case InstanceClosure(_, name, _) if (name.name == WasmDynamicCalls.VARARGS_TARGET):
						case StaticClosure(output, _) | InstanceClosure(output, _, _):
							noteType(output.type);
							if (reachable.exists(fn.name) && !scalarClosures.exists(IrTypeIdentity.text(output.type))
								&& crossesDynamic(output.type))
								planned.set(closureKey(output.type), output.type);
						case SafeCast(output, _):
							switch output.type {
								case Function(_, _):
									noteType(output.type);
									if (reachable.exists(fn.name) && crossesDynamic(output.type))
										planned.set(closureKey(output.type), output.type);
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
		adapters.signatureCount = orderedSignatures.length;
		// Generated bodies cast nested function arguments and results, and an invoker casts its receiver: those
		// targets need their own cast, adapter and invoker. Each round builds only the signatures added since the last.
		var invokers:Map<String, IrFunction> = [], targetAdapters:Map<String, IrFunction> = [];
		function noteCasts(fn:IrFunction):Bool {
			var added = false;
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case SafeCast(output, _):
							switch output.type {
								case Function(_, _):
									var key = closureKey(output.type);
									if (!planned.exists(key) && crossesDynamic(output.type)) {
										planned.set(key, output.type);
										added = true;
									}
								default:
							}
						default:
					}
			return added;
		}
		var changed = true;
		while (changed) {
			changed = false;
			var keys = [for (key in planned.keys()) key];
			keys.sort(Reflect.compare);
			for (key in keys) {
				if (!invokers.exists(key)) {
					var fn = adapters.invoker(planned.get(key));
					invokers.set(key, fn);
					if (noteCasts(fn))
						changed = true;
				}
				if (!targetAdapters.exists(key)) {
					var fn = adapters.adapter(planned.get(key));
					targetAdapters.set(key, fn);
					if (noteCasts(fn))
						changed = true;
				}
			}
		}
		var keys = [for (key in planned.keys()) key];
		keys.sort(Reflect.compare);
		var varargs = reachable.exists(WasmDynamicCalls.VARARGS_TARGET),
			byArity:Map<Int, Array<IrType>> = [];
		for (key in keys) {
			var type = planned.get(key), arity = arguments(type).length;
			if (!byArity.exists(arity))
				byArity.set(arity, []);
			byArity.get(arity).push(type);
		}
		var arities = [for (arity in byArity.keys()) arity];
		arities.sort((left, right) -> left - right);
		program.functions.push(adapters.signatureQuery());
		adapters.rewriteSignatureChecks();
		program.functions.push(adapters.arityQuery(arities, byArity));
		for (arity in arities)
			program.functions.push(adapters.dispatcher(arity, byArity.get(arity)));
		for (key in keys) {
			program.functions.push(invokers.get(key));
			program.functions.push(targetAdapters.get(key));
			program.functions.push(adapters.castFunction(planned.get(key), varargs));
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
						case Call(out, callTarget,
							arguments) if (callTarget.name == "__closure_is_of_type" && arguments.length == 2
							&& types.exists(arguments[1].id)):
							var type = types.get(arguments[1].id),
								name = "$wasm:closure-type-check:"
									+ compiler.core.TextDigest.sha256(IrTypeIdentity.text(type)).substr(0, 32);
							helpers.set(name, type);
							target.instructions
								.push(new Located(IrInstruction.Call(out, IrSymbol.of(name), [arguments[0]]),
								located.provenance));
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
		return new IrFunction(SIGNATURE_FUNCTION, builder.arguments, I32, builder.blocks, GeneratedHelper, null, false,
			Keep);
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

	/** Return an already matching closure; adapt one of another signature with the same arity at the cast. */
	function castFunction(targetType:IrType, varargs:Bool):IrFunction {
		var builder = new IrBuilder(),
			closure = builder.argument("closure", Dyn),
			signature = builder.call(SIGNATURE_FUNCTION, [closure], I32);
		var missing = builder.createBlock(), present = builder.createBlock();
		builder.branch(builder.equal(closure, builder.constNull(Dyn)), missing, present);
		builder.select(missing);
		builder.returnValue(closure);
		builder.select(present);
		function when(condition:IrValue, body:Void->Void):Void {
			var matched = builder.createBlock(), next = builder.createBlock();
			builder.branch(condition, matched, next);
			builder.select(matched);
			body();
			builder.select(next);
		}
		when(builder.equal(signature, builder.constInt(signatureId(targetType))), () -> builder.returnValue(closure));
		if (varargs)
			when(builder.equal(signature, builder.constInt(-1)),
				() -> builder.returnValue(builder.toDyn(builder.instanceClosure(WasmDynamicCalls.varargsAdapterName(targetType),
				closure, targetType))));
		var arity = builder.call(ARITY_FUNCTION, [signature], I32);
		when(builder.equal(arity, builder.constInt(arguments(targetType).length)),
			() -> builder.returnValue(builder.toDyn(builder.instanceClosure(adapterName(signatureId(targetType)),
			closure,
			targetType))));
		builder.throwValue(builder.toDyn(builder.constString('Cannot cast to ${Std.string(targetType)}')));
		return new IrFunction(castName(targetType), builder.arguments, Dyn, builder.blocks, ClosureCast(targetType),
			null, false, Reachable);
	}

	/** The arity of each planned source signature, or -1 for any other signature (and for 0, not a closure). */
	function arityQuery(arities:Array<Int>, byArity:Map<Int, Array<IrType>>):IrFunction {
		var builder = new IrBuilder(),
			signature = builder.argument("signature", I32),
			start = builder.currentBlock(),
			otherwise = builder.createBlock();
		builder.select(otherwise);
		builder.returnValue(builder.constInt(-1));
		var targets = [for (_ in 0...signatureCount + 1) otherwise.id];
		for (arity in arities) {
			var block = builder.createBlock();
			builder.select(block);
			builder.returnValue(builder.constInt(arity));
			for (type in byArity.get(arity))
				targets[signatureId(type)] = block.id;
		}
		builder.select(start);
		builder.terminate(Switch(signature, targets, otherwise.id));
		return new IrFunction(ARITY_FUNCTION, builder.arguments, I32, builder.blocks, GeneratedHelper, null, false,
			Reachable);
	}

	/** Calls a closure with boxed arguments through the invoker of its runtime signature. */
	function dispatcher(arity:Int, sources:Array<IrType>):IrFunction {
		var builder = new IrBuilder(),
			closure = builder.argument("closure", Dyn),
			boxed = [for (index in 0...arity) builder.argument('argument$index', Dyn)],
			signature = builder.call(SIGNATURE_FUNCTION, [closure], I32),
			start = builder.currentBlock(),
			otherwise = builder.createBlock();
		builder.select(otherwise);
		// Unreachable for planned closures: a cast adapts only signatures the arity query lists for this arity.
		builder.throwValue(builder.toDyn(builder.constString('Cannot call a closure of unplanned signature with $arity arguments')));
		var targets = [for (_ in 0...signatureCount + 1) otherwise.id];
		for (type in sources) {
			var block = builder.createBlock();
			builder.select(block);
			builder.returnValue(builder.call(invokerName(signatureId(type)), [closure].concat(boxed), Dyn));
			targets[signatureId(type)] = block.id;
		}
		builder.select(start);
		builder.terminate(Switch(signature, targets, otherwise.id));
		return new IrFunction(dispatcherName(arity), builder.arguments, Dyn, builder.blocks, GeneratedHelper, null,
			false,
			Reachable);
	}

	/** Unboxes the arguments to the source signature, calls the closure at it and boxes the result (null for Void). */
	function invoker(sourceType:IrType):IrFunction {
		var builder = new IrBuilder(),
			original = builder.argument("closure", Dyn),
			sourceArguments = arguments(sourceType),
			boxed = [
				for (index in 0...sourceArguments.length)
					builder.argument('argument$index', Dyn)
			],
			callee = builder.safeCast(original, sourceType),
			converted = [
				for (index in 0...sourceArguments.length)
					unbox(builder, boxed[index], sourceArguments[index])
			],
			sourceResult = result(sourceType),
			value = builder.callClosure(callee, converted, sourceResult);
		builder.returnValue(isVoid(sourceResult) ? builder.constNull(Dyn) : convert(builder, value, Dyn));
		return new IrFunction(invokerName(signatureId(sourceType)), builder.arguments, Dyn, builder.blocks,
			ClosureAdapter(sourceType, Function([for (_ in sourceArguments) Dyn], Dyn)), null, false, Reachable);
	}

	/** Receives the original closure and the target's arguments; calls it through the dispatcher with them boxed. */
	function adapter(targetType:IrType):IrFunction {
		var builder = new IrBuilder(),
			original = builder.argument("closure", Dyn),
			targetArguments = arguments(targetType),
			values = [
				for (index in 0...targetArguments.length)
					builder.argument('argument$index', targetArguments[index])
			],
			boxed = [for (value in values) convert(builder, value, Dyn)],
			targetResult = result(targetType),
			value = builder.call(dispatcherName(targetArguments.length), [original].concat(boxed), Dyn);
		switch targetResult {
			case Void:
				builder.returnValue(builder.constVoid());
			case Dyn:
				builder.returnValue(value);
			case I64 | F32 | EnumTag(_):
				// A Void source gives null, which these do not unbox: the target's zero, as the per-pair adapters gave.
				var missing = builder.createBlock(), present = builder.createBlock();
				builder.branch(builder.equal(value, builder.constNull(Dyn)), missing, present);
				builder.select(missing);
				builder.returnValue(zero(builder, targetResult));
				builder.select(present);
				builder.returnValue(unbox(builder, value, targetResult));
			default:
				// Int and Float unbox null to 0, Bool (below) to false and references to null.
				builder.returnValue(unbox(builder, value, targetResult));
		}
		return new IrFunction(adapterName(signatureId(targetType)), builder.arguments, targetResult, builder.blocks,
			ClosureVarargs(targetType), null, false, Reachable);
	}

	/**
	 * Converts a boxed value to a typed one. Bool goes through Int, which accepts Bool, Int and Float boxes and null:
	 * a per-pair adapter converted an Int argument or result to Bool by comparing it with 0, which this keeps.
	 */
	function unbox(builder:IrBuilder, value:IrValue, type:IrType):IrValue
		return switch type {
			case Dyn: value;
			case Bool: builder.equal(builder.equal(builder.safeCast(value, I32), builder.constInt(0)),
				builder.constBool(false));
			default: fromDynamic(builder, value, type);
		};

	static function isVoid(type:IrType):Bool
		return switch type {
			case Void: true;
			default: false;
		};

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
		return enumName == null ? builder.safeCast(value, type) : builder.intrinsic(InlineEnumUnbox(Enum(enumName)),
			[value], type);
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

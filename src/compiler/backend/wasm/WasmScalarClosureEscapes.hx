package compiler.backend.wasm;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.IrBuilder;
import compiler.ir.IrValueInterfaceBoxes;
import compiler.ir.IrCheckedDynamicCasts;
import compiler.ir.SourceProvenance.Located;

/** Adapts scalar closures only at Dynamic and exported host boundaries. */
class WasmScalarClosureEscapes {
	public static inline final RESTORE_CALL_PREFIX = "$wasm:closure-restore-call:";
	final program:IrProgram;
	final scalar:Map<String, Bool>;
	final inlineEnums:Map<String, String> = [];
	final adapters:Map<String, String> = [];
	final restorations:Map<String, String> = [];
	final signatureChecks:Map<String, String> = [];
	final generatedFunctions:Array<IrFunction> = [];
	final generatedObjects:Array<IrObject> = [];
	final generatedNatives:Array<IrNative> = [];

	public static function rewrite(program:IrProgram, scalar:Map<String, Bool>, exports:Array<String>, exportAdapters:Map<String, String>):IrProgram {
		var pass = new WasmScalarClosureEscapes(program, scalar), result = new IrProgram(program.entryPoint);
		result.functions = [for (fn in program.functions) {
			var rewritten = pass.rewriteFunction(fn);
			if (exports.indexOf(fn.name) >= 0 && pass.exportAdapter(fn, exportAdapters))
				rewritten = new IrFunction(rewritten.name, rewritten.arguments, rewritten.result, rewritten.blocks, rewritten.kind, rewritten.debugBindings,
					rewritten.inlineHint, Reachable);
			rewritten;
		}];
		result.objects = program.objects.copy();
		var generatedCount = 0, objectCount = 0, hadGenerated = false;
		// An escape/restoration body can itself cross a function boundary. Process
		// those bodies and their varargs dependencies before either backend plans
		// signatures and table slots; each memoized helper is emitted only once.
		while (true) {
			var batch:Array<IrFunction> = [];
			while (generatedCount < pass.generatedFunctions.length)
				batch.push(pass.rewriteFunction(pass.generatedFunctions[generatedCount++]));
			while (objectCount < pass.generatedObjects.length)
				result.objects.push(pass.generatedObjects[objectCount++]);
			if (batch.length > 0) {
				hadGenerated = true;
				batch = IrValueInterfaceBoxes.rewrite(batch, result.objects, program.interfaces, result.functions);
				batch = IrCheckedDynamicCasts.rewrite(batch, result.objects, true, result.functions);
				for (fn in batch) result.functions.push(pass.rewriteFunction(fn));
			}
			if (generatedCount < pass.generatedFunctions.length) continue;
			var missing = WasmDynamicCalls.missingVarargsAdapters(result.functions, program.enums);
			if (missing.length == 0) break;
			for (fn in missing) pass.generatedFunctions.push(fn);
		}
		result.natives = program.natives.concat(pass.generatedNatives); result.cNatives = program.cNatives;
		var hasTypeTest = false;
		for (native in result.natives) if (native.name == "__std_is_of_type") hasTypeTest = true;
		if (!hasTypeTest && hadGenerated) result.natives.push({name: "__std_is_of_type", library: "haxeon_runtime",
			symbol: "__std_is_of_type", arguments: [Dyn, TypeRef], result: Bool});
		result.interfaces = program.interfaces; result.enums = program.enums; result.staticFields = program.staticFields;
		result.positionalFingerprints = program.positionalFingerprints; result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces; result.positionalSources = program.positionalSources;
		compiler.ir.IrEnumTagLowering.escapes(result);
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
		generatedFunctions.push(new IrFunction(name, b.arguments, resultType, b.blocks, GeneratedHelper));
		mappings.set(fn.name, name);
		return true;
	}

	function new(program:IrProgram, scalar:Map<String, Bool>) {
		this.program = program;
		this.scalar = scalar;
		for (declaration in program.enums) if (declaration.inlineStorage != null)
			inlineEnums.set(declaration.inlineStorage, declaration.name);
	}

	static function functionType(type:IrType):Null<IrType>
		return switch type {
			case Function(_, _): type;
			case Nullable(inner): switch inner { case Function(_, _): inner; default: null; };
			default: null;
		};

	function needsAdapter(type:IrType):Bool {
		var signature = functionType(type);
		return signature != null && (scalar.exists(Std.string(type)) || scalar.exists(Std.string(signature)) || hasInlineEnumSignature(signature));
	}

	/** Reflection can synthesize a Dynamic closure escape after the language-level enum pass. */
	function hasInlineEnumSignature(type:IrType):Bool return switch type {
		case Function(arguments, result): Lambda.exists(arguments, isInlineEnumStorage) || isInlineEnumStorage(result);
		default: false;
	};

	function isInlineEnumStorage(type:IrType):Bool return switch type {
		case Obj(name): inlineEnums.exists(name);
		case EnumTag(_): true;
		default: false;
	};

	function toDynamic(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		switch type { case EnumTag(name): return builder.intrinsic(EnumTagBox(EnumTag(name)), [value], Dyn); default: }
		var enumName = switch type { case Obj(name): inlineEnums.get(name); default: null; };
		return enumName == null ? builder.toDyn(value) : builder.intrinsic(InlineEnumBox(Enum(enumName)), [value], Dyn);
	}

	function fromDynamic(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		switch type { case EnumTag(name): return builder.intrinsic(EnumTagUnbox(EnumTag(name)), [value], type); default: }
		var enumName = switch type { case Obj(name): inlineEnums.get(name); default: null; };
		return enumName == null ? builder.safeCast(value, type) : builder.intrinsic(InlineEnumUnbox(Enum(enumName)), [value], type);
	}

	function rewriteFunction(fn:IrFunction):IrFunction {
		var blocks:Array<IrBlock> = [], changed = false;
		var typeValues:Map<Int, IrType> = [];
		for (block in fn.blocks) for (located in block.instructions) switch located.value {
			case TypeValue(out, type): typeValues.set(out.id, type);
			default:
		}
		for (block in fn.blocks) {
			var rewritten = new IrBlock(block.id);
			for (located in block.instructions) switch located.value {
				case Call(out, "__closure_is_of_type", arguments) if (arguments.length == 2 && typeValues.exists(arguments[1].id)
						&& needsAdapter(typeValues.get(arguments[1].id))):
					rewritten.instructions.push(new Located(Call(out, signatureCheck(typeValues.get(arguments[1].id)), [arguments[0]]), located.provenance));
					changed = true;
				case ToDyn(out, input) if (needsAdapter(input.type)):
					var maker = adapter(input.type);
					rewritten.instructions.push(new Located(Call(out, maker, [input]), located.provenance));
					changed = true;
				case SafeCast(out, input) if ((switch (input.type) { case Dyn: true; default: false; }) && needsAdapter(out.type)):
					var maker = restoration(out.type);
					rewritten.instructions.push(new Located(Call(out, maker, [input]), located.provenance));
					changed = true;
				default: rewritten.instructions.push(located);
			}
			rewritten.terminator = block.terminator;
			blocks.push(rewritten);
		}
		return changed ? fn.withBlocks(blocks) : fn;
	}

	/** The escape adapter's target identifies its original scalar closure signature. */
	function signatureCheck(type:IrType):String {
		var signature = functionType(type);
		if (signature == null) throw 'Expected closure signature, got $type';
		var key = Std.string(signature), existing = signatureChecks.get(key);
		if (existing != null) return existing;
		var suffix = haxe.crypto.Sha256.encode(key).substr(0, 32), name = "$wasm:closure-signature-check:" + suffix,
			environment = "$wasm:closure-escape:" + suffix, invoke = "$wasm:closure-escape-call:" + suffix,
			arguments = switch signature { case Function(args, _): args; default: throw "Expected closure signature"; };
		signatureChecks.set(key, name);
		adapter(type);
		var b = new IrBuilder(), closure = b.argument("closure", Dyn),
			probeType:IrType = Function([Obj(environment)].concat([for (_ in arguments) Dyn]), Dyn),
			probe = b.staticClosure(invoke, probeType),
			found = b.call(receiverQuery("$wasm:closure-receiver:signature:" + suffix, Dyn, probeType), [closure, probe], Dyn);
		b.returnValue(b.equal(b.equal(found, b.constNull(Dyn)), b.constBool(false)));
		generatedFunctions.push(new IrFunction(name, b.arguments, Bool, b.blocks, GeneratedHelper));
		return name;
	}

	function receiverQuery(name:String, first:IrType, second:IrType):String {
		if (!Lambda.exists(generatedNatives, native -> native.name == name))
			generatedNatives.push({name: name, library: "haxeon_runtime", symbol: "__closure_receiver_if_match", arguments: [first, second], result: Dyn});
		return name;
	}

	function adapter(type:IrType):String {
		var key = Std.string(type), found = adapters.get(key);
		if (found != null) return found;
		switch type {
			case Nullable(inner):
				if (!(switch inner { case Function(_, _): true; default: false; })) throw "Nullable scalar closure escape requires a function";
				var innerAdapter = adapter(inner), maker = "$wasm:closure-escape-nullable:" + haxe.crypto.Sha256.encode(key).substr(0, 32),
					b = new IrBuilder(), closure = b.argument("closure", type), missing = b.createBlock(), present = b.createBlock();
				adapters.set(key, maker);
				b.branch(b.equal(closure, b.constNull(type)), missing, present);
				b.select(missing); b.returnValue(b.constNull(Dyn));
				b.select(present); b.returnValue(b.call(innerAdapter, [b.safeCast(closure, inner)], Dyn));
				generatedFunctions.push(new IrFunction(maker, b.arguments, Dyn, b.blocks, GeneratedHelper));
				restoration(type);
				return maker;
			case Function(_, _):
			default: throw "A scalar closure escape must have a function type";
		}
		var suffix = haxe.crypto.Sha256.encode(key).substr(0, 32), environment = "$wasm:closure-escape:" + suffix,
			invoke = "$wasm:closure-escape-call:" + suffix, maker = "$wasm:closure-escape-make:" + suffix,
			signature = switch type { case Function(arguments, result): {arguments: arguments, result: result};
				default: throw "A scalar closure escape must have a function type"; };
		adapters.set(key, maker);
		restoration(type);
		generatedObjects.push({name: environment, isValue: false, base: null, interfaces: [], fields: [{name: "closure", type: type}], methods: []});
		var call = new IrBuilder(), receiver = call.argument("receiver", Obj(environment)),
			arguments = [for (index in 0...signature.arguments.length) call.argument('argument$index', Dyn)],
			closure = call.fieldGet(receiver, "closure", type), adapted:Array<IrValue> = [];
		for (index in 0...arguments.length)
			adapted.push((switch (signature.arguments[index]) { case Dyn: true; default: false; }) ? arguments[index] : fromDynamic(call, arguments[index], signature.arguments[index]));
		var value = call.callClosure(closure, adapted, signature.result);
		call.returnValue((switch (signature.result) { case Void: true; default: false; }) ? call.constNull(Dyn) : (switch (signature.result) { case Dyn: true; default: false; }) ? value : toDynamic(call, value, signature.result));
		generatedFunctions.push(new IrFunction(invoke, call.arguments, Dyn, call.blocks, GeneratedHelper));
		var make = new IrBuilder(), original = make.argument("closure", type), missing = make.createBlock(), present = make.createBlock();
		make.branch(make.equal(original, make.constNull(type)), missing, present);
		make.select(missing);
		make.returnValue(make.constNull(Dyn));
		make.select(present);
		var restoredEnvironment = "$wasm:closure-restored:" + suffix, restoredInvoke = RESTORE_CALL_PREFIX + suffix,
			probeType:IrType = Function([Obj(restoredEnvironment)].concat(signature.arguments), signature.result),
			probe = make.staticClosure(restoredInvoke, probeType),
			matchedReceiver = make.call(receiverQuery("$wasm:closure-receiver:typed:" + suffix, type, probeType), [original, probe], Dyn),
			allocate = make.createBlock(), unwrap = make.createBlock(), erasedType:IrType = Function([for (_ in signature.arguments) Dyn], Dyn);
		make.branch(make.equal(matchedReceiver, make.constNull(Dyn)), allocate, unwrap);
		make.select(unwrap);
		make.returnValue(make.toDyn(make.fieldGet(make.safeCast(matchedReceiver, Obj(restoredEnvironment)), "closure", erasedType)));
		make.select(allocate);
		var captured = make.newObject(environment);
		make.fieldSet(captured, "closure", original);
		make.returnValue(make.toDyn(make.instanceClosure(invoke, captured, erasedType)));
		generatedFunctions.push(new IrFunction(maker, make.arguments, Dyn, make.blocks, GeneratedHelper));
		return maker;
	}

	/** A restored closure keeps the Dynamic call on its boundary while publishing the typed scalar ABI. */
	function restoration(type:IrType):String {
		var key = Std.string(type), found = restorations.get(key);
		if (found != null) return found;
		switch type {
			case Nullable(inner):
				if (!(switch inner { case Function(_, _): true; default: false; })) throw "Nullable scalar closure restoration requires a function";
				var innerRestoration = restoration(inner), maker = "$wasm:closure-restore-nullable:" + haxe.crypto.Sha256.encode(key).substr(0, 32),
					b = new IrBuilder(), closure = b.argument("closure", Dyn), missing = b.createBlock(), present = b.createBlock();
				restorations.set(key, maker);
				b.branch(b.equal(closure, b.constNull(Dyn)), missing, present);
				b.select(missing); b.returnValue(b.constNull(type));
				b.select(present); b.returnValue(b.safeCast(b.call(innerRestoration, [closure], inner), type));
				generatedFunctions.push(new IrFunction(maker, b.arguments, type, b.blocks, GeneratedHelper));
				return maker;
			case Function(_, _):
			default: throw "A restored scalar closure must have a function type";
		}
		var suffix = haxe.crypto.Sha256.encode(key).substr(0, 32), environment = "$wasm:closure-restored:" + suffix,
			invoke = RESTORE_CALL_PREFIX + suffix, maker = "$wasm:closure-restore-make:" + suffix,
			signature = switch type { case Function(arguments, result): {arguments: arguments, result: result};
				default: throw "A restored scalar closure must have a function type"; },
			dynamicType:IrType = Function([for (_ in signature.arguments) Dyn], Dyn);
		restorations.set(key, maker);
		adapter(type);
		generatedObjects.push({name: environment, isValue: false, base: null, interfaces: [],
			fields: [{name: "closure", type: dynamicType}], methods: []});
		var call = new IrBuilder(), receiver = call.argument("receiver", Obj(environment)),
			arguments = [for (index in 0...signature.arguments.length) call.argument('argument$index', signature.arguments[index])],
			closure = call.fieldGet(receiver, "closure", dynamicType), boxed = [for (argument in arguments) (switch (argument.type) { case Dyn: true; default: false; }) ? argument : toDynamic(call, argument, argument.type)],
			value = call.callClosure(closure, boxed, Dyn);
		if ((switch (signature.result) { case Void: true; default: false; })) call.returnValue(call.constVoid());
		else call.returnValue((switch (signature.result) { case Dyn: true; default: false; }) ? value : fromDynamic(call, value, signature.result));
		generatedFunctions.push(new IrFunction(invoke, call.arguments, signature.result, call.blocks, WasmClosureRestore));
		var make = new IrBuilder(), original = make.argument("closure", Dyn), missing = make.createBlock(), present = make.createBlock();
		make.branch(make.equal(original, make.constNull(Dyn)), missing, present);
		make.select(missing);
		make.returnValue(make.constNull(type));
		make.select(present);
		var escapedEnvironment = "$wasm:closure-escape:" + suffix, escapedInvoke = "$wasm:closure-escape-call:" + suffix,
			probeType:IrType = Function([Obj(escapedEnvironment)].concat([for (_ in signature.arguments) Dyn]), Dyn),
			probe = make.staticClosure(escapedInvoke, probeType),
			matchedReceiver = make.call(receiverQuery("$wasm:closure-receiver:erased:" + suffix, Dyn, probeType), [original, probe], Dyn),
			allocate = make.createBlock(), unwrap = make.createBlock();
		make.branch(make.equal(matchedReceiver, make.constNull(Dyn)), allocate, unwrap);
		make.select(unwrap);
		make.returnValue(make.fieldGet(make.safeCast(matchedReceiver, Obj(escapedEnvironment)), "closure", type));
		make.select(allocate);
		var decoded = make.safeCast(original, dynamicType), captured = make.newObject(environment);
		make.fieldSet(captured, "closure", decoded);
		make.returnValue(make.instanceClosure(invoke, captured, type));
		generatedFunctions.push(new IrFunction(maker, make.arguments, type, make.blocks, GeneratedHelper));
		return maker;
	}
}

package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrInlineValueLayout.IrInlineValueSlot;
import compiler.ir.SourceProvenance.Located;

/** HashLink's scalar argument/result convention applied to typed, non-erased closures. */
class IrScalarClosures {
	final program:IrProgram;
	final objects:Map<String, IrObject>;
	final inlineEnums:Map<String, String> = [];
	final layouts:IrInlineValueLayout;
	final candidates:Map<String, IrType> = [];
	final excluded:Map<String, Bool> = [];
	final functions:Map<String, IrFunction>;
	final erasures:Map<String, {maker:String, environment:String}> = [];
	final restorations:Map<String, String> = [];
	final signatureChecks:Map<String, String> = [];
	final generatedFunctions:Array<IrFunction> = [];
	final generatedMakers:Array<IrFunction> = [];
	final generatedObjects:Array<IrObject> = [];

	public static function rewrite(program:IrProgram):Void {
		var pass = new IrScalarClosures(program);
		pass.discover();
		if (pass.candidates.keys().hasNext())
			pass.apply();
	}

	function new(program:IrProgram) {
		this.program = program;
		objects = [for (object in program.objects) object.name => object];
		for (declaration in program.enums)
			if (declaration.inlineStorage != null)
				inlineEnums.set(declaration.inlineStorage, declaration.name);
		layouts = new IrInlineValueLayout(IrObjectTable.of(objects));
		functions = [for (fn in program.functions) fn.name => fn];
	}

	function discover():Void {
		for (native in program.natives) {
			for (type in native.arguments)
				excludeNested(type);
			excludeNested(native.result);
		}
		for (native in program.cNatives) {
			for (type in native.arguments)
				excludeNested(type);
			excludeNested(native.result);
		}
		for (fn in program.functions) {
			var signatureQueries:Map<Int, Bool> = [], uses:Map<Int, Int> = [];
			function use(input:IrValue):Void
				uses.set(input.id, (uses.exists(input.id) ? uses.get(input.id) : 0) + 1);
			for (block in fn.blocks) {
				for (located in block.instructions) {
					for (input in IrOperands.inputs(located.value))
						use(input);
					switch located.value {
						case Phi(_, inputs):
							for (input in inputs)
								use(input.value);
						case Call(_, "__closure_is_of_type", arguments) if (arguments.length == 2):
							signatureQueries.set(arguments[1].id, true);
						default:
					}
				}
				if (block.terminator != null)
					switch block.terminator.value {
						case Return(value), Throw(value), Rethrow(value), Branch(value, _, _):
							use(value);
						default:
					}
			}
			if (fn.name == program.entryPoint || fn.retention != Reachable) {
				for (argument in fn.arguments)
					excludeNested(argument.type);
				excludeNested(fn.result);
			}
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case StaticClosure(out, name):
							if (note(out.type) && !functions.exists(IrScalarArguments.PREFIX + name))
								excluded.set(key(out.type), true);
						case InstanceClosure(out, name, receiver):
							if (note(out.type) && (isValue(receiver.type) || !functions.exists(IrScalarArguments.PREFIX + name)))
								excluded.set(key(out.type), true);
						case CallClosure(_, closure, _):
							note(closure.type);
						case ToDyn(_, input):
							var callable = functionType(input.type);
							if (callable != null)
								note(callable);
							else
								excludeNested(input.type);
						case SafeCast(output, input):
							var callable = functionType(output.type);
							if (callable != null && (switch (input.type) {
								case Dyn: true;
								default: false;
							}))
								note(callable);
							else
								excludeNested(output.type);
							excludeNested(input.type);
						case TypeValue(out, type) if (!signatureQueries.exists(out.id) || uses.get(out.id) != 1):
							excludeNested(type);
						default:
					}
		}
		for (name in excluded.keys())
			candidates.remove(name);
	}

	function note(type:IrType):Bool {
		return switch type {
			case Function(arguments, result): var found = isValue(result),
					valid = scalarizable(result); for (argument in arguments) {
					if (isValue(argument))
						found = true;
					if (!scalarizable(argument))
						valid = false;
				} if (found && valid) candidates.set(key(type), type); found && valid;
			default: false;
		};
	}

	function excludeNested(type:IrType):Void {
		switch type {
			case Function(arguments, result):
				excluded.set(key(type), true);
				for (argument in arguments)
					excludeNested(argument);
				excludeNested(result);
			case Array(element), Iterator(element), Nullable(element):
				excludeNested(element);
			default:
		}
	}

	function scalarizable(type:IrType):Bool {
		if (!isValue(type))
			return true;
		for (slot in slots(type)) {
			if (slot.isPresence)
				return false;
			// A recursively self-referential closure layout needs a recursive ABI type, not an eager expansion.
			switch slot.type {
				case Function(_, _):
					return false;
				default:
			}
		}
		return true;
	}

	function apply():Void {
		var rewritten = [for (fn in program.functions) rewriteFunction(fn)],
			generated:Array<IrFunction> = [],
			generatedIndex = 0;
		while (generatedIndex < generatedFunctions.length)
			generated.push(rewriteFunction(generatedFunctions[generatedIndex++]));
		var mappedObjects:Array<IrObject> = [
			for (object in program.objects)
				{
					name: object.name,
					isValue: object.isValue,
					nativeLayout: object.nativeLayout,
					base: object.base,
					interfaces: object.interfaces,
					fields: [
						for (field in object.fields)
							{
								name: field.name,
								type: mapType(field.type),
								nativeLayout: field.nativeLayout,
								scalarStorage: field.scalarStorage,
								nullableScalarStorage: field.nullableScalarStorage
							}
					],
					methods: object.methods
				}
		];
		for (object in generatedObjects)
			mappedObjects.push(object);
		program.objects = mappedObjects;
		program.interfaces = [
			for (interfaceDecl in program.interfaces)
				{
					name: interfaceDecl.name,
					bases: interfaceDecl.bases,
					methods: [
						for (method in interfaceDecl.methods)
							{
								name: method.name,
								arguments: [for (argument in method.arguments) mapType(argument)],
								result: mapType(method.result)
							}
					]
				}
		];
		program.enums = [
			for (entry in program.enums)
				{
					name: entry.name,
					isRecursive: entry.isRecursive,
					inlineStorage: entry.inlineStorage,
					cases: [
						for (item in entry.cases)
							{name: item.name, params: [for (type in item.params) mapType(type)]}
					]
				}
		];
		program.staticFields = [
			for (field in program.staticFields)
				{name: field.name, type: mapType(field.type)}
		];
		generated = IrValueInterfaceBoxes.rewrite(generated.concat(generatedMakers), program.objects, program.interfaces, rewritten);
		generated = IrCheckedDynamicCasts.rewrite(generated, program.objects, false, rewritten);
		program.functions = rewritten.concat(generated);
		var hasTypeTest = false;
		for (native in program.natives)
			if (native.name == "__std_is_of_type")
				hasTypeTest = true;
		if (!hasTypeTest && generated.length > 0)
			program.natives.push({
				name: "__std_is_of_type",
				library: "haxeon_runtime",
				symbol: "__std_is_of_type",
				arguments: [Dyn, TypeRef],
				result: Bool
			});
	}

	/** An ordinary function can still need a boundary bridge for scalar callback arguments/results. */
	function needsBoundaryAdapter(type:IrType):Bool
		return switch type {
			case Function(arguments, result): candidates.exists(key(type)) || Lambda.exists(arguments, needsBoundaryAdapter) || needsBoundaryAdapter(result);
			case Nullable(inner): needsBoundaryAdapter(inner);
			default: false;
		};

	function inlineEnum(type:IrType):Null<String>
		return switch type {
			case Obj(name): inlineEnums.get(name);
			default: null;
		};

	function toDynamic(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		switch type {
			case EnumTag(name): return builder.intrinsic(EnumTagBox(EnumTag(name)), [value], Dyn);
			default:
		}
		var enumName = inlineEnum(type);
		return enumName == null ? builder.toDyn(value) : builder.call(IrInlineEnumEscapes.boxName(enumName), [value], Dyn);
	}

	function fromDynamic(builder:IrBuilder, value:IrValue, type:IrType):IrValue {
		switch type {
			case EnumTag(name): return builder.intrinsic(EnumTagUnbox(EnumTag(name)), [value], type);
			default:
		}
		var enumName = inlineEnum(type);
		return enumName == null ? builder.safeCast(value, type) : builder.call(IrInlineEnumEscapes.unboxName(enumName), [value], type);
	}

	function mapType(type:IrType):IrType
		return switch type {
			case Abstract(_) if (IrHlScalarRef.element(type) != null): IrHlScalarRef.type(mapType(IrHlScalarRef.element(type)));
			case Function(arguments, result) if (candidates.exists(key(type))):
				var physical:Array<IrType> = [];
				for (argument in arguments)
					if (isValue(argument))
						for (slot in slots(argument))
							physical.push(mapType(slot.type));
					else
						physical.push(mapType(argument));
				if (isValue(result))
					for (slot in slots(result))
						physical.push(IrHlScalarRef.type(mapType(slot.type)));
				Function(physical, isValue(result) ? Void : mapType(result));
			case Function(arguments, result): Function([for (argument in arguments) mapType(argument)], mapType(result));
			case Array(element): Array(mapType(element));
			case Iterator(element): Iterator(mapType(element));
			case Nullable(element): Nullable(mapType(element));
			default: type;
		};

	/** The exact recursive type boundary rewritten by mapType. */
	function changesType(type:IrType):Bool
		return switch type {
			case Abstract(_) if (IrHlScalarRef.element(type) != null): changesType(IrHlScalarRef.element(type));
			case Function(arguments, result): candidates.exists(key(type)) || Lambda.exists(arguments, changesType) || changesType(result);
			case Array(element), Iterator(element), Nullable(element): changesType(element);
			default: false;
		};

	function needsRewrite(fn:IrFunction):Bool
		return IrTypePositions.any(fn, changesType);

	function rewriteFunction(fn:IrFunction):IrFunction {
		if (!needsRewrite(fn))
			return fn;
		var next = nextId(fn), values:Map<Int, IrValue> = [];
		var typeValues:Map<Int, IrType> = [];
		for (block in fn.blocks)
			for (located in block.instructions)
				switch located.value {
					case TypeValue(out, type):
						typeValues.set(out.id, type);
					default:
				}
		function map(value:IrValue):IrValue {
			var existing = values.get(value.id);
			if (existing != null)
				return existing;
			var result = new IrValue(value.id, value.name, mapType(value.type));
			values.set(value.id, result);
			return result;
		}
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var rewritten = new IrBlock(block.id);
			for (located in block.instructions)
				switch located.value {
					case Call(out, "__closure_is_of_type", arguments)
						if (arguments.length == 2
							&& typeValues.exists(arguments[1].id)
							&& needsBoundaryAdapter(typeValues.get(arguments[1].id))):
						rewritten.instructions.push(new Located(Call(map(out), ensureSignatureCheck(typeValues.get(arguments[1].id)), [map(arguments[0])]),
							located.provenance));
					case ToDyn(out, input) if (needsBoundaryAdapter(input.type)):
						var erasure = ensureErasure(input.type),
							boxed = new IrValue(next++, "$scalar-closure:erased", erasedType(input.type));
						rewritten.instructions.push(new Located(Call(boxed, erasure.maker, [map(input)]), located.provenance));
						rewritten.instructions.push(new Located(ToDyn(map(out), boxed), located.provenance));
					case SafeCast(out, input) if ((switch (input.type) {
						case Dyn: true;
						default: false;
					}) && needsBoundaryAdapter(out.type)):
						rewritten.instructions.push(new Located(Call(map(out), ensureRestoration(out.type), [map(input)]), located.provenance));
					case StaticClosure(out, name) if (candidates.exists(key(out.type))):
						rewritten.instructions.push(new Located(StaticClosure(map(out), IrScalarArguments.PREFIX + name), located.provenance));
					case InstanceClosure(out, name, receiver) if (candidates.exists(key(out.type))):
						rewritten.instructions.push(new Located(InstanceClosure(map(out), IrScalarArguments.PREFIX + name, map(receiver)), located.provenance));
					case CallClosure(out, closure, arguments) if (candidates.exists(key(closure.type))):
						var expanded:Array<IrValue> = [];
						for (argument in arguments) {
							if (!isValue(argument.type)) {
								expanded.push(map(argument));
								continue;
							}
							for (slot in slots(argument.type)) {
								var current = map(argument),
									logical = argument.type;
								for (part in slot.path) {
									var field = fieldOf(logical, part),
										leaf = new IrValue(next++, "$scalar-closure:field", mapType(field.type));
									rewritten.instructions.push(new Located(FieldGet(leaf, current, part), located.provenance));
									current = leaf;
									logical = field.type;
								}
								expanded.push(current);
							}
						}
						var resultSlots = isValue(out.type) ? slots(out.type) : [],
							references:Array<IrValue> = [];
						for (slot in resultSlots) {
							var type = mapType(slot.type),
								zero = new IrValue(next++, "$scalar-closure:zero", type),
								reference = new IrValue(next++, "$scalar-closure:reference", IrHlScalarRef.type(type));
							var initial:IrInstruction = switch type {
								case I32 | I64: ConstInt(zero, 0);
								case F32 | F64: ConstFloat(zero, 0.0);
								case Bool: ConstBool(zero, false);
								default: ConstNull(zero);
							};
							rewritten.instructions.push(new Located(initial, located.provenance));
							rewritten.instructions.push(new Located(Call(reference, IrHlScalarRef.ADDRESS, [zero]), located.provenance));
							references.push(reference);
							expanded.push(reference);
						}
						if (resultSlots.length == 0)
							rewritten.instructions.push(new Located(CallClosure(map(out), map(closure), expanded), located.provenance));
						else {
							var ignored = new IrValue(next++, "$scalar-closure:call", Void),
								result = map(out),
								name = switch out.type {
									case Obj(value): value;
									default: throw "Invalid scalar closure result";
								};
							rewritten.instructions.push(new Located(CallClosure(ignored, map(closure), expanded), located.provenance));
							rewritten.instructions.push(new Located(NewObject(result, name), located.provenance));
							for (index in 0...resultSlots.length) {
								var slot = resultSlots[index],
									leaf = new IrValue(next++, "$scalar-closure:result", mapType(slot.type)),
									current = result,
									logical = out.type;
								rewritten.instructions.push(new Located(Call(leaf, IrHlScalarRef.LOAD, [references[index]]), located.provenance));
								for (position in 0...slot.path.length - 1) {
									var part = slot.path[position],
										field = fieldOf(logical, part),
										child = new IrValue(next++, part, mapType(field.type));
									rewritten.instructions.push(new Located(FieldGet(child, current, part), located.provenance));
									current = child;
									logical = field.type;
								}
								rewritten.instructions.push(new Located(FieldSet(current, slot.path[slot.path.length - 1], leaf), located.provenance));
							}
						}
					case TypeValue(out, type):
						rewritten.instructions.push(new Located(TypeValue(map(out), mapType(type)), located.provenance));
					default:
						rewritten.instructions.push(new Located(IrInliner.remap(located.value, map, id -> id), located.provenance));
				}
			var terminator = block.terminator;
			if (terminator != null)
				rewritten.terminator = new Located(switch terminator.value {
					case Return(value): Return(map(value));
					case Throw(value): Throw(map(value));
					case Rethrow(value): Rethrow(map(value));
					case Jump(target): Jump(target);
					case Branch(condition, yes, no): Branch(map(condition), yes, no);
				}, terminator.provenance);
			blocks.push(rewritten);
		}
		var debug:Array<compiler.ir.IrFunction.IrDebugBinding> = [
			for (binding in fn.debugBindings)
				{
					identity: binding.identity,
					name: binding.name,
					value: map(binding.value),
					path: binding.path,
					scopeStart: binding.scopeStart,
					scopeEnd: binding.scopeEnd
				}
		];
		return new IrFunction(fn.name, [for (argument in fn.arguments) map(argument)], mapType(fn.result), blocks, fn.kind, debug, fn.inlineHint, fn.retention);
	}

	/** A scalar closure escapes through a signature-specific adapter; only that target proves its original type. */
	function ensureSignatureCheck(type:IrType):String {
		var callable = switch type {
			case Nullable(inner): inner;
			default: type;
		}, signatureKey = key(callable), existing = signatureChecks.get(signatureKey);
		if (existing != null)
			return existing;
		var suffix = haxe.crypto.Sha256.encode(signatureKey).substr(0, 32),
			name = "$scalar-closure:signature-check:" + suffix,
			environment = "$scalar-closure:environment:" + suffix,
			wrapper = "$scalar-closure:erased-call:" + suffix;
		signatureChecks.set(signatureKey, name);
		ensureErasure(callable);
		var b = new IrBuilder(),
			closure = b.argument("closure", Dyn),
			probeType:IrType = switch erasedType(callable) {
				case Function(args, result): Function([Obj(environment)].concat(args), result);
				default: throw "Expected erased closure";
			},
			probe = b.staticClosure(wrapper, probeType),
			found = b.call(receiverQuery("$scalar-closure:receiver:signature:" + suffix, Dyn, probeType), [closure, probe], Dyn);
		b.returnValue(b.equal(b.equal(found, b.constNull(Dyn)), b.constBool(false)));
		generatedMakers.push(new IrFunction(name, b.arguments, Bool, b.blocks, GeneratedHelper));
		return name;
	}

	/** Materialize a boxed closure only at a real Dynamic escape, keeping null and ordinary typed calls unchanged. */
	function ensureErasure(type:IrType):{maker:String, environment:String} {
		var signature = key(type), existing = erasures.get(signature);
		if (existing != null)
			return existing;
		switch type {
			case Nullable(inner):
				if (!(switch inner {
					case Function(_, _): true;
					default: false;
				}))
					throw "Nullable scalar closure erasure requires a function";
				var innerErasure = ensureErasure(inner), suffix = haxe.crypto.Sha256.encode(signature).substr(0, 32),
					maker = "$scalar-closure:erase-nullable:" + suffix, result = {
						maker: maker,
						environment: innerErasure.environment
					};
				erasures.set(signature, result);
				var outputType = erasedType(type),
					b = new IrBuilder(),
					source = b.argument("closure", type),
					absent = b.createBlock(),
					present = b.createBlock();
				b.branch(b.equal(source, b.constNull(type)), absent, present);
				b.select(absent);
				b.returnValue(b.constNull(outputType));
				b.select(present);
				b.returnValue(b.safeCast(b.call(innerErasure.maker, [b.safeCast(source, inner)], erasedType(inner)), outputType));
				generatedMakers.push(new IrFunction(maker, b.arguments, outputType, b.blocks, GeneratedHelper));
				return result;
			case Function(_, _):
			default:
				throw "Scalar closure erasure requires a function";
		}
		var suffix = haxe.crypto.Sha256.encode(signature).substr(0, 32), environment = "$scalar-closure:environment:" + suffix,
			wrapper = "$scalar-closure:erased-call:" + suffix, maker = "$scalar-closure:erase:" + suffix, result = {
				maker: maker,
				environment: environment
			};
		erasures.set(signature, result);
		ensureRestoration(type);
		var logical = switch type {
			case Function(arguments, result): {arguments: arguments, result: result};
			default: throw "Scalar closure erasure requires a function";
		};
		var body = new IrBuilder(), receiver = body.argument("receiver", Obj(environment)),
			arguments = [for (index in 0...logical.arguments.length) body.argument('argument$index', Dyn)], adapted = [
				for (index in 0...logical.arguments.length)
					(switch (logical.arguments[index]) {
						case Dyn: true;
						default: false;
					})
				?arguments[index]:fromDynamic
				(body, arguments[index], logical.arguments[index])
			], closure = body.fieldGet(receiver, "closure", type), call = body.callClosure(closure, adapted, logical.result);
		body.returnValue((switch (logical.result) {
			case Void: true;
			default: false;
		}) ? body.constNull(Dyn) : (switch (logical.result) {
			case Dyn: true;
			default: false;
		}) ? call : toDynamic(body, call, logical.result));
		generatedFunctions.push(new IrFunction(wrapper, body.arguments, Dyn, body.blocks, GeneratedHelper));
		generatedObjects.push({
			name: environment,
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "closure", type: mapType(type)}],
			methods: []
		});
		var make = new IrBuilder(),
			source = make.argument("closure", mapType(type)),
			missing = make.createBlock(),
			present = make.createBlock();
		make.branch(make.equal(source, make.constNull(mapType(type))), missing, present);
		make.select(missing);
		make.returnValue(make.constNull(erasedType(type)));
		make.select(present);
		var restoredEnvironment = "$scalar-closure:restored-environment:" + suffix,
			restoredWrapper = IrScalarArguments.PREFIX + "$scalar-closure:restored-call:" + suffix,
			probeType:IrType = switch mapType(type) {
				case Function(args, result): Function([Obj(restoredEnvironment)].concat(args), result);
				default: throw "Expected scalar closure";
			},
			probe = make.staticClosure(restoredWrapper, probeType),
			found = make.call(receiverQuery("$scalar-closure:receiver:typed:" + suffix, mapType(type), probeType), [source, probe], Dyn),
			allocate = make.createBlock(),
			unwrap = make.createBlock();
		make.branch(make.equal(found, make.constNull(Dyn)), allocate, unwrap);
		make.select(unwrap);
		make.returnValue(make.fieldGet(make.safeCast(found, Obj(restoredEnvironment)), "closure", erasedType(type)));
		make.select(allocate);
		var captured = make.newObject(environment);
		make.fieldSet(captured, "closure", source);
		make.returnValue(make.instanceClosure(wrapper, captured, erasedType(type)));
		generatedMakers.push(new IrFunction(maker, make.arguments, erasedType(type), make.blocks, GeneratedHelper));
		return result;
	}

	function receiverQuery(name:String, first:IrType, second:IrType):String {
		if (!Lambda.exists(program.natives, native -> native.name == name))
			program.natives.push({
				name: name,
				library: "haxeon_runtime",
				symbol: "__closure_receiver_if_match",
				arguments: [first, second],
				result: Dyn
			});
		return name;
	}

	function erasedType(type:IrType):IrType
		return switch type {
			case Function(arguments, _): Function([for (_ in arguments) Dyn], Dyn);
			case Nullable(inner): Nullable(erasedType(inner));
			default: throw "Scalar closure erasure requires a function";
		};

	/** A function arriving from Dynamic keeps its boxed ABI behind one scalar-call adapter. */
	function ensureRestoration(type:IrType):String {
		var signatureKey = key(type),
			existing = restorations.get(signatureKey);
		if (existing != null)
			return existing;
		switch type {
			case Nullable(inner):
				if (!(switch inner {
					case Function(_, _): true;
					default: false;
				}))
					throw "Nullable scalar closure restoration requires a function";
				var innerMaker = ensureRestoration(inner),
					maker = "$scalar-closure:restore-nullable:" + haxe.crypto.Sha256.encode(signatureKey).substr(0, 32),
					b = new IrBuilder(),
					original = b.argument("closure", Dyn),
					missing = b.createBlock(),
					present = b.createBlock();
				restorations.set(signatureKey, maker);
				b.branch(b.equal(original, b.constNull(Dyn)), missing, present);
				b.select(missing);
				b.returnValue(b.constNull(type));
				b.select(present);
				b.returnValue(b.safeCast(b.call(innerMaker, [original], inner), type));
				generatedMakers.push(new IrFunction(maker, b.arguments, type, b.blocks, GeneratedHelper));
				return maker;
			case Function(_, _):
			default:
				throw "Scalar closure restoration requires a function";
		}
		var suffix = haxe.crypto.Sha256.encode(signatureKey).substr(0, 32),
			environment = "$scalar-closure:restored-environment:" + suffix,
			wrapper = IrScalarArguments.PREFIX + "$scalar-closure:restored-call:" + suffix,
			maker = "$scalar-closure:restore:" + suffix,
			scalarOwn = candidates.exists(signatureKey),
			logical = switch type {
				case Function(arguments, result): {arguments: arguments, result: result};
				default: throw "Scalar closure restoration requires a function";
			};
		restorations.set(signatureKey, maker);
		ensureErasure(type);
		generatedObjects.push({
			name: environment,
			isValue: false,
			base: null,
			interfaces: [],
			fields: [{name: "closure", type: erasedType(type)}],
			methods: []
		});
		var call = new IrBuilder(),
			receiver = call.argument("receiver", Obj(environment)),
			arguments:Array<IrValue> = [];
		for (index in 0...logical.arguments.length) {
			var argument = logical.arguments[index];
			if (!scalarOwn || !isValue(argument)) {
				arguments.push(call.argument('argument$index', mapType(argument)));
				continue;
			}
			var name = switch argument {
				case Obj(value): value;
				default: throw "Invalid scalar closure argument";
			}, record = call.newObject(name);
			for (slot in slots(argument)) {
				var scalar = call.argument('argument$index.' + slot.path.join("."), mapType(slot.type)),
					current = record,
					currentType = argument;
				for (position in 0...slot.path.length - 1) {
					var part = slot.path[position],
						field = fieldOf(currentType, part);
					current = call.fieldGet(current, part, mapType(field.type));
					currentType = field.type;
				}
				call.fieldSet(current, slot.path[slot.path.length - 1], scalar);
			}
			arguments.push(record);
		}
		var resultSlots = scalarOwn && isValue(logical.result) ? slots(logical.result) : [],
			references:Array<IrValue> = [];
		for (slot in resultSlots)
			references.push(call.argument("result." + slot.path.join("."), IrHlScalarRef.type(mapType(slot.type))));
		var closure = call.fieldGet(receiver, "closure", erasedType(type)),
			erasedArguments = [
				for (index in 0...arguments.length) {
					var argument = arguments[index], logicalType = logical.arguments[index];
					if (needsBoundaryAdapter(logicalType)) {
						var erased = call.call(ensureErasure(logicalType).maker, [argument], erasedType(logicalType));
						call.toDyn(erased);
					} else (switch (argument.type) {
						case Dyn: true;
						default: false;
					}) ? argument : toDynamic(call, argument, logicalType);
				}
			],
			erasedResult = call.callClosure(closure, erasedArguments, Dyn),
			result = (switch (logical.result) {
				case Void: true;
				default: false;
			}) ? call.constVoid() : (switch (logical.result) {
				case Dyn: true;
				default: false;
			}) ? erasedResult : needsBoundaryAdapter(logical.result) ? call.call(ensureRestoration(logical.result), [erasedResult],
				mapType(logical.result)) : fromDynamic(call, erasedResult, logical.result);
		if (resultSlots.length == 0)
			call.returnValue(result);
		else {
			for (index in 0...resultSlots.length) {
				var slot = resultSlots[index],
					current = result,
					currentType = logical.result;
				for (part in slot.path) {
					var field = fieldOf(currentType, part);
					current = call.fieldGet(current, part, mapType(field.type));
					currentType = field.type;
				}
				call.call(IrHlScalarRef.STORE, [references[index], current], Void);
			}
			call.returnValue(call.constVoid());
		}
		generatedMakers.push(new IrFunction(wrapper, call.arguments, resultSlots.length == 0 ? mapType(logical.result) : Void, call.blocks, ScalarArguments));
		var make = new IrBuilder(),
			boxed = make.argument("closure", Dyn),
			missing = make.createBlock(),
			present = make.createBlock(),
			physical = mapType(type);
		make.branch(make.equal(boxed, make.constNull(Dyn)), missing, present);
		make.select(missing);
		make.returnValue(make.constNull(physical));
		make.select(present);
		var erasedEnvironment = "$scalar-closure:environment:" + suffix,
			erasedWrapper = "$scalar-closure:erased-call:" + suffix,
			probeType:IrType = switch erasedType(type) {
				case Function(args, result): Function([Obj(erasedEnvironment)].concat(args), result);
				default: throw "Expected erased closure";
			},
			probe = make.staticClosure(erasedWrapper, probeType),
			found = make.call(receiverQuery("$scalar-closure:receiver:erased:" + suffix, Dyn, probeType), [boxed, probe], Dyn),
			allocate = make.createBlock(),
			unwrap = make.createBlock();
		make.branch(make.equal(found, make.constNull(Dyn)), allocate, unwrap);
		make.select(unwrap);
		make.returnValue(make.fieldGet(make.safeCast(found, Obj(erasedEnvironment)), "closure", physical));
		make.select(allocate);
		var decoded = make.safeCast(boxed, erasedType(type)),
			captured = make.newObject(environment);
		make.fieldSet(captured, "closure", decoded);
		make.returnValue(make.instanceClosure(wrapper, captured, physical));
		generatedMakers.push(new IrFunction(maker, make.arguments, physical, make.blocks, GeneratedHelper));
		return maker;
	}

	function isValue(type:IrType):Bool
		return switch type {
			case Obj(name): objects.exists(name) && objects.get(name).isValue;
			default: false;
		};

	function slots(type:IrType):Array<IrInlineValueSlot>
		return layouts.slots(type);

	function fieldOf(type:IrType, name:String):IrObjectField {
		var objectName = switch type {
			case Obj(value): value;
			default: throw "Invalid scalar closure field owner";
		}, object = objects.get(objectName);
		if (object != null)
			for (field in object.fields)
				if (field.name == name)
					return field;
		throw 'Missing scalar closure field $objectName.$name';
	}

	static function functionType(type:IrType):Null<IrType>
		return switch type {
			case Function(_, _): type;
			case Nullable(inner): switch inner {
					case Function(_, _): inner;
					default: null;
				};
			default: null;
		};

	static function key(type:IrType):String
		return Std.string(type);

	static function nextId(fn:IrFunction):Int {
		var max = -1;
		for (argument in fn.arguments)
			if (argument.id > max)
				max = argument.id;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && output.id > max)
					max = output.id;
			}
		return max + 1;
	}
}

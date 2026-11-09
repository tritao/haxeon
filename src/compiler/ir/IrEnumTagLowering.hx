package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Select nominal scalar storage independently of payload-enum escape eligibility. */
class IrEnumTagLowering {
	public static function run(program:IrProgram):IrProgram {
		var names:Map<String, Bool> = [
			for (entry in program.enums)
				if (IrEnumTagStorage.eligible(entry)) entry.name => true
		];
		if (!names.keys().hasNext())
			return program;
		function mapped(type:IrType):IrType
			return switch type {
				case Enum(name) if (names.exists(name)): EnumTag(name);
				case Nullable(Enum(name)) if (names.exists(name)): EnumTag(name);
				case Array(inner): Array(mapped(inner));
				case Iterator(inner): Iterator(mapped(inner));
				case Nullable(inner): Nullable(mapped(inner));
				case Function(arguments, result): Function([for (argument in arguments) mapped(argument)], mapped(result));
				default: type;
			};
		var nativeWrappers:Map<String, String> = [],
			generated:Array<IrFunction> = [];
		function nativeWrapper(name:String, arguments:Array<IrType>, result:IrType, cNative:Bool):Void {
			function directTag(type:IrType):Bool
				return switch mapped(type) {
					case EnumTag(_): true;
					default: false;
				};
			if (!Lambda.exists(arguments, directTag) && !directTag(result))
				return;
			var wrapper = "$enum-tag:native:" + name,
				b = new IrBuilder(),
				converted:Array<IrValue> = [];
			for (index in 0...arguments.length) {
				var logical = arguments[index],
					physical = mapped(logical),
					value = b.argument('argument$index', physical);
				converted.push(switch physical {
					case EnumTag(enumName): b.safeCast(b.call(IrEnumTagStorage.boxName(enumName), [value], Dyn), logical);
					default: value;
				});
			}
			var called = cNative ? b.cNativeCall(name, converted, result) : b.call(name, converted, result);
			var returned = switch mapped(result) {
				case EnumTag(enumName): b.call(IrEnumTagStorage.unboxName(enumName), [b.toDyn(called)], mapped(result));
				default: called;
			};
			b.returnValue(returned);
			generated.push(new IrFunction(wrapper, b.arguments, mapped(result), b.blocks));
			nativeWrappers.set(name, wrapper);
		}
		for (native in program.natives)
			nativeWrapper(native.name, native.arguments, native.result, false);
		for (native in program.cNatives)
			nativeWrapper(native.name, native.arguments, native.result, true);
		program.objects = [
			for (object in program.objects)
				{
					name: object.name,
					isValue: object.isValue,
					nativeLayout: object.nativeLayout,
					base: object.base,
					interfaces: object.interfaces,
					methods: object.methods,
					fields: [
						for (field in object.fields)
							{
								name: field.name,
								type: mapped(field.type),
								nativeLayout: field.nativeLayout,
								scalarStorage: field.scalarStorage,
								nullableScalarStorage: field.nullableScalarStorage
							}
					]
				}
		];
		program.staticFields = [for (field in program.staticFields) {name: field.name, type: mapped(field.type)}];
		program.interfaces = [
			for (entry in program.interfaces)
				{
					name: entry.name,
					bases: entry.bases,
					methods: [
						for (method in entry.methods)
							{
								name: method.name,
								arguments: [for (argument in method.arguments) mapped(argument)],
								result: mapped(method.result)
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
						for (constructor in entry.cases)
							{name: constructor.name, params: [for (parameter in constructor.params) mapped(parameter)]}
					]
				}
		];
		program.functions = [
			for (fn in program.functions) {
				var values:Map<Int, IrValue> = [];
				function use(value:IrValue):IrValue {
					if (!values.exists(value.id))
						values.set(value.id, new IrValue(value.id, value.name, mapped(value.type)));
					return values.get(value.id);
				}
				var blocks = [
					for (block in fn.blocks) {
						var result = new IrBlock(block.id);
						for (located in block.instructions) {
							var instruction = IrInliner.remap(located.value, use, id -> id);
							switch located.value {
								case Call(output, name, arguments) | CNativeCall(output, name, arguments) if (nativeWrappers.exists(name)):
									instruction = Call(use(output), nativeWrappers.get(name), [for (argument in arguments) use(argument)]);
								case Call(output, name, arguments) if (StringTools.startsWith(name, IrEnumDynamicDispatch.UNBOX_PREFIX)):
									if (name != IrEnumDynamicDispatch.unboxName(output.type))
										throw "Malformed enum unbox signature";
									switch use(output).type {
										case EnumTag(enumName): instruction = Call(use(output), IrEnumTagStorage.unboxName(enumName),
												[for (argument in arguments) use(argument)]);
										default:
									}
								case TypeValue(output, type):
									// A bare enum descriptor describes its nominal box, not its private scalar carrier.
									instruction = TypeValue(use(output), switch type {
										case Enum(_): type;
										default: mapped(type);
									});
								default:
							}
							result.instructions.push(new Located(instruction, located.provenance));
						}
						if (block.terminator != null) result.terminator = new Located(switch block.terminator.value {
							case Return(value): Return(use(value));
							case Throw(value): Throw(use(value));
							case Rethrow(value): Rethrow(use(value));
							case Jump(id): Jump(id);
							case Branch(condition, yes, no): Branch(use(condition), yes, no);
						}, block.terminator.provenance);
						result;
					}
				];
				new IrFunction(fn.name, [for (argument in fn.arguments) use(argument)], mapped(fn.result), blocks, [
					for (binding in fn.debugBindings)
						{
							identity: binding.identity,
							name: binding.name,
							value: use(binding.value),
							path: binding.path,
							scopeStart: binding.scopeStart,
							scopeEnd: binding.scopeEnd
						}
				], fn.inlineHint, fn.retention);
			}
		];
		program.functions = program.functions.concat(generated);
		return program;
	}

	/** Run again after reflection and other helpers are generated: their escapes need the same checked ABI. */
	public static function escapes(program:IrProgram):Void {
		var required:Map<String, Bool> = [];
		implicitEscapes(program, required);
		var existing = [for (fn in program.functions) fn.name => true],
			adapterEnums:Map<String, String> = [];
		for (entry in program.enums)
			if (IrEnumTagStorage.eligible(entry)) {
				adapterEnums.set(IrEnumTagStorage.boxName(entry.name), entry.name);
				adapterEnums.set(IrEnumTagStorage.unboxName(entry.name), entry.name);
			}
		for (fn in program.functions)
			for (block in fn.blocks)
				for (index in 0...block.instructions.length) {
					var located = block.instructions[index],
						instruction = located.value,
						changed = false;
					switch instruction {
						case Call(_, name, _) if (adapterEnums.exists(name)):
							required.set(adapterEnums.get(name), true);
						case ToDyn(output, value):
							switch value.type {
								case EnumTag(name):
									required.set(name, true);
									instruction = Call(output, IrEnumTagStorage.boxName(name), [value]);
									changed = true;
								default:
							};
						case SafeCast(output, value):
							switch output.type {
								case EnumTag(name):
									required.set(name, true);
									instruction = Call(output, IrEnumTagStorage.unboxName(name), [value]);
									changed = true;
								default:
							};
						default:
					}
					if (changed)
						block.instructions[index] = new Located(instruction, located.provenance);
				}
		var names = [for (name in required.keys()) name];
		names.sort(Reflect.compare);
		if (names.length > 0 && !Lambda.exists(program.natives, native -> native.name == "__std_is_exact_type"))
			program.natives.push({
				name: "__std_is_exact_type",
				library: "haxeon_runtime",
				symbol: "__std_is_exact_type",
				arguments: [Dyn, TypeRef],
				result: Bool
			});
		var declarations = [for (entry in program.enums) entry.name => entry];
		for (name in names)
			if (!existing.exists(IrEnumTagStorage.boxName(name)) || !existing.exists(IrEnumTagStorage.unboxName(name)))
				for (helper in IrEnumTagStorage.adapters(declarations.get(name)))
					if (!existing.exists(helper.name)) {
						existing.set(helper.name, true);
						program.functions.push(helper);
					}
	}

	static function implicitEscapes(program:IrProgram, required:Map<String, Bool>):Void {
		var signatures:Map<String, Array<IrType>> = [],
			objects = [for (object in program.objects) object.name => object],
			globals = [for (field in program.staticFields) field.name => field.type],
			contracts = [for (entry in program.interfaces) entry.name => entry];
		for (fn in program.functions)
			signatures.set(fn.name, [for (argument in fn.arguments) argument.type]);
		for (native in program.natives)
			signatures.set(native.name, native.arguments);
		for (native in program.cNatives)
			signatures.set(native.name, native.arguments);
		function fieldType(type:IrType, field:String):Null<IrType> {
			var name = switch type {
				case Obj(name): name;
				default: return null;
			};
			while (name != null) {
				var object = objects.get(name);
				if (object == null)
					return null;
				for (entry in object.fields)
					if (entry.name == field)
						return entry.type;
				name = object.base;
			}
			return null;
		}
		function interfaceArguments(name:String, method:String):Null<Array<IrType>> {
			var declaration = contracts.get(name);
			if (declaration == null)
				return null;
			for (entry in declaration.methods)
				if (entry.name == method)
					return entry.arguments;
			for (base in declaration.bases) {
				var inherited = interfaceArguments(base, method);
				if (inherited != null)
					return inherited;
			}
			return null;
		}
		function methodArguments(type:IrType, method:String):Null<Array<IrType>> {
			return switch type {
				case Virtual(name): interfaceArguments(name, method);
				case Obj(name):
					var current = name, result:Null<Array<IrType>> = null;
					while (current != null && result == null) {
						var object = objects.get(current);
						if (object == null)
							break;
						for (entry in object.methods)
							if (entry.name == method) {
								var signature = signatures.get(entry.functionName);
								if (signature != null)
									result = signature.slice(1);
								break;
							}
						current = object.base;
					}
					result;
				default: null;
			};
		}

		for (fn in program.functions) {
			var next = 0, hasTags = false;
			for (argument in fn.arguments) {
				switch argument.type {
					case EnumTag(_):
						hasTags = true;
					default:
				}
				if (argument.id >= next)
					next = argument.id + 1;
			}
			for (block in fn.blocks)
				for (located in block.instructions) {
					var output = IrOperands.output(located.value);
					if (output != null) {
						switch output.type {
							case EnumTag(_):
								hasTags = true;
							default:
						}
						if (output.id >= next)
							next = output.id + 1;
					}
				}
			if (!hasTags)
				continue;
			for (block in fn.blocks) {
				var rewritten:Array<Located<IrInstruction>> = [];
				for (located in block.instructions) {
					function adapt(value:IrValue, expected:Null<IrType>):IrValue {
						return switch [value.type, expected] {
							case [EnumTag(name), Dyn]:
								var boxed = new IrValue(next++, "$enum-tag:implicit-box", Dyn);
								required.set(name, true);
								rewritten.push(new Located(Call(boxed, IrEnumTagStorage.boxName(name), [value]), located.provenance));
								boxed;
							default: value;
						};
					}
					var instruction = switch located.value {
						case Call(_, name, arguments) if (StringTools.startsWith(name, "__array_")
							&& arguments.length > 0
							&& (switch arguments[0].type {
								case Array(EnumTag(_)): true;
								default: false;
							})):
								// Typed lane operations consume tags directly in the subsequent array rewrite.
								located.value;
						case Call(output, name, arguments) if (signatures.exists(name)):
							var expected = signatures.get(name);
							Call(output, name, [
								for (index in 0...arguments.length)
									adapt(arguments[index], index < expected.length ? expected[index] : null)
							]);
						case CNativeCall(output, name, arguments) if (signatures.exists(name)):
							var expected = signatures.get(name);
							CNativeCall(output, name, [
								for (index in 0...arguments.length)
									adapt(arguments[index], index < expected.length ? expected[index] : null)
							]);
						case MethodCall(output, owner, method, arguments, terminalReceiver):
							var expected = methodArguments(owner.type, method);
							MethodCall(output, owner, method, [
								for (index in 0...arguments.length)
									adapt(arguments[index], expected != null && index < expected.length ? expected[index] : null)
							], terminalReceiver);
						case CallClosure(output, closure, arguments):
							var expected = switch closure.type {
								case Function(arguments, _): arguments;
								default: [];
							};
							CallClosure(output, closure, [
								for (index in 0...arguments.length)
									adapt(arguments[index], index < expected.length ? expected[index] : null)
							]);
						case FieldSet(object, field, value): FieldSet(object, field, adapt(value, fieldType(object.type, field)));
						case GlobalSet(name, value): GlobalSet(name, adapt(value, globals.get(name)));
						case ArraySet(array, index, value):
							var expected = switch array.type {
								case Array(element): element;
								default: null;
							};
							ArraySet(array, index, adapt(value, expected));
						default: located.value;
					};
					rewritten.push(new Located(instruction, located.provenance));
				}
				block.instructions.resize(0);
				for (located in rewritten)
					block.instructions.push(located);
			}
		}
	}
}

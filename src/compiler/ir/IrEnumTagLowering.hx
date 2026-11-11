package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.SourceProvenance.Located;

/** Select nominal scalar storage independently of payload-enum escape eligibility. */
class IrEnumTagLowering {
	public static function run(program:IrProgram):IrProgram {
		var dynamicUnboxes:Map<String, IrType> = [];
		for (fn in program.functions) switch fn.kind {
			case EnumDynamicUnbox(type): dynamicUnboxes.set(fn.name, type);
			default:
		}
		var names:Map<String,
			Bool> = [for (entry in program.enums) if (IrEnumTagStorage.eligible(entry)) entry.name => true];
		if (!names.keys().hasNext()) return program;
		var tags:Map<String, IrType> = [for (name in names.keys()) name => EnumTag(name)];
		function changes(type:IrType):Bool return switch type {
			case Enum(name):
				names.exists(name);
			case Array(inner), Iterator(inner), Nullable(inner):
				changes(inner);
			case Function(arguments, result):
				var changed = changes(result);
				for (argument in arguments) if (changes(argument)) {
					changed = true;
					break;
				}
				changed;
			default:
				false;
		};
		function mapped(type:IrType):IrType return switch type {
			case Enum(name) if (names.exists(name)):
				tags.get(name);
			case Nullable(Enum(name)) if (names.exists(name)):
				tags.get(name);
			case Array(inner) if (changes(inner)):
				Array(mapped(inner));
			case Iterator(inner) if (changes(inner)):
				Iterator(mapped(inner));
			case Nullable(inner) if (changes(inner)):
				Nullable(mapped(inner));
			case Function(arguments, result) if (changes(type)):
				Function([for (argument in arguments) mapped(argument)], mapped(result));
			default:
				type;
		};
		// Payload-free enums cannot override equality. Their synthesized calls are
		// scalar comparisons even with source inlining disabled.
		var tagEqualities:Map<String, Bool> = [];
		for (fn in program.functions)
			if ((switch fn.kind { case Equality, EnumEquality(_): true; default: false; }) && fn.arguments.length == 2)
				switch mapped(fn.arguments[0].type) {
					case EnumTag(name):
						if (IrVerifier.sameType(mapped(fn.arguments[1].type), EnumTag(name)))
							tagEqualities.set(fn.name, true);
					default:
				}
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
					case EnumTag(enumName): b.safeCast(b.intrinsic(EnumTagBox(EnumTag(enumName)), [value], Dyn), logical);
					default: value;
				});
			}
			var called = cNative ? b.cNativeCall(name, converted, result) : b.call(name, converted, result);
			var returned = switch mapped(result) {
				case EnumTag(enumName): b.intrinsic(EnumTagUnbox(EnumTag(enumName)), [b.toDyn(called)], mapped(result));
				default: called;
			};
			b.returnValue(returned);
			generated.push(new IrFunction(wrapper, b.arguments, mapped(result), b.blocks, GeneratedHelper));
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
		function valueChanges(value:IrValue):Bool return changes(value.type);
		function nonOutputChanges(instruction:IrInstruction):Bool {
			switch instruction {
				case Call(_, name, _) if (tagEqualities.exists(name)):
					return true;
				case Call(_, name, _) | CNativeCall(_, name, _) if (nativeWrappers.exists(name)):
					return true;
				case TypeValue(_, type):
					switch type {
						case Enum(_):
						default:
							if (changes(type)) return true;
					}
				default:
			}
			return false;
		}
		function instructionChanges(instruction:IrInstruction):Bool
			return nonOutputChanges(instruction) || IrOperands.anyValue(instruction, valueChanges);
		function functionChanges(fn:IrFunction):Bool {
			if (changes(fn.result)) return true;
			for (argument in fn.arguments) if (valueChanges(argument)) return true;
			for (binding in fn.debugBindings) if (valueChanges(binding.value)) return true;
			// Valid SSA uses have the type of their definition. Discover changed carriers once per definition;
			// instruction rewriting below still visits every operand, and the verifier checks every use.
			for (block in fn.blocks) for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && valueChanges(output)) return true;
				if (nonOutputChanges(located.value)) return true;
			}
			return false;
		}
		var changedFunctions:Array<IrFunction> = [];
		program.functions = [
			for (fn in program.functions) if (!functionChanges(fn)) fn else {
				var values:Map<Int, IrValue> = [];
				function use(value:IrValue):IrValue {
					if (!valueChanges(value)) return value;
					if (!values.exists(value.id))
						values.set(value.id, new IrValue(value.id, value.name, mapped(value.type)));
					return values.get(value.id);
				}
				var indexTags:Map<Int, IrValue> = [], replacedIndices:Map<Int, Bool> = [];
				for (block in fn.blocks)
					for (located in block.instructions)
						switch located.value {
							case EnumIndex(output, input):
								switch use(input).type {
									case EnumTag(_): indexTags.set(output.id, use(input));
									default:
								}
							default:
						}
				var blocks = [
					for (block in fn.blocks) {
						var result = new IrBlock(block.id);
						for (located in block.instructions) {
							var tagIndexEquality = switch located.value {
								case Equal(_, left, right): indexTags.exists(left.id) && indexTags.exists(right.id);
								default: false;
							};
							if (!tagIndexEquality && !instructionChanges(located.value)) {
								result.instructions.push(located);
								continue;
							}
							var instruction = IrInliner.remap(located.value, use, id -> id);
							switch located.value {
								case Call(output, name, arguments) if (tagEqualities.exists(name)):
									instruction = Equal(use(output), use(arguments[0]), use(arguments[1]));
								case Equal(output, left, right) if (indexTags.exists(left.id) && indexTags.exists(right.id)
									&& IrVerifier.sameType(indexTags.get(left.id).type, indexTags.get(right.id).type)):
									instruction = Equal(use(output), indexTags.get(left.id), indexTags.get(right.id));
									replacedIndices.set(left.id, true);
									replacedIndices.set(right.id, true);
								case Call(output, name, arguments) | CNativeCall(output, name, arguments) if (nativeWrappers.exists(name)):
									instruction = Call(use(output), nativeWrappers.get(name), [for (argument in arguments) use(argument)]);
								case Call(output, name, arguments) if (dynamicUnboxes.exists(name)):
									if (!IrVerifier.sameType(dynamicUnboxes.get(name), output.type))
										throw "Malformed enum unbox signature";
									switch use(output).type {
										case EnumTag(enumName): instruction = Intrinsic(use(output), EnumTagUnbox(EnumTag(enumName)),
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
				if (replacedIndices.keys().hasNext()) {
					var used:Map<Int, Bool> = [];
					for (block in blocks) {
						for (located in block.instructions) {
							for (input in IrOperands.inputs(located.value)) used.set(input.id, true);
							switch located.value {
								case Phi(_, inputs): for (input in inputs) used.set(input.value.id, true);
								default:
							}
						}
						if (block.terminator != null) switch block.terminator.value {
							case Return(value), Throw(value), Rethrow(value), Branch(value, _, _): used.set(value.id, true);
							case Jump(_):
						}
					}
					for (binding in fn.debugBindings) used.set(binding.value.id, true);
					for (block in blocks) {
						var kept = [for (located in block.instructions) if (switch located.value {
							case EnumIndex(output, _): !replacedIndices.exists(output.id) || used.exists(output.id);
							default: true;
						}) located];
						block.instructions.splice(0, block.instructions.length);
						for (located in kept) block.instructions.push(located);
					}
				}
				var rewrittenFunction = new IrFunction(fn.name, [for (argument in fn.arguments) use(argument)], mapped(fn.result), blocks, fn.kind, [
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
				changedFunctions.push(rewrittenFunction);
				rewrittenFunction;
			}
		];
		var retained:Map<String, Bool> = [];
		retained.set(program.entryPoint, true);
		for (fn in program.functions.concat(generated)) {
			if (fn.retention != Reachable) retained.set(fn.name, true);
			for (block in fn.blocks) for (located in block.instructions) switch located.value {
				case Call(_, name, _), StaticClosure(_, name), InstanceClosure(_, name, _): retained.set(name, true);
				default:
			}
		}
		for (object in program.objects) for (method in object.methods) retained.set(method.functionName, true);
		for (native in program.natives) if (native.generatedFunctionDependencies != null)
			for (name in native.generatedFunctionDependencies) retained.set(name, true);
		program.functions = [for (fn in program.functions) if (!tagEqualities.exists(fn.name) || retained.exists(fn.name)) fn];
		program.functions = program.functions.concat(generated);
		// Only rewritten definitions can introduce tag escapes. Finish that representation transition
		// here; the later helper pass checks code generated after this lowering.
		finishEscapes(program, changedFunctions.concat(generated));
		return program;
	}

	/** Run again after reflection and other helpers are generated: their escapes need the same checked ABI. */
	public static function escapes(program:IrProgram):Void {
		finishEscapes(program, program.functions);
	}

	static function finishEscapes(program:IrProgram, changedFunctions:Array<IrFunction>):Void {
		var required:Map<String, Bool> = [];
		var existing = [for (fn in program.functions) fn.name => fn], adapterEnums:Map<String, String> = [];
		var symbols = IrEnumTagStorage.adapterNames(program);
		var boxNames:Map<String, String> = [], unboxNames:Map<String, String> = [];
		for (name => pair in symbols) {
			boxNames.set(name, pair.box);
			unboxNames.set(name, pair.unbox);
		}
		for (fn in program.functions) switch fn.kind {
			case EnumTagAdapter(EnumTag(name), _): adapterEnums.set(fn.name, name);
			default:
		}
		if (!symbols.keys().hasNext()) return;
		rewriteEscapes(program, required, adapterEnums, existing, changedFunctions, boxNames, unboxNames);
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
			if (!existing.exists(boxNames.get(name)) || !existing.exists(unboxNames.get(name)))
				for (helper in IrEnumTagStorage.adapters(declarations.get(name), boxNames.get(name), unboxNames.get(name)))
					if (!existing.exists(helper.name)) {
						existing.set(helper.name, helper);
						program.functions.push(helper);
					}
	}

	static function rewriteEscapes(program:IrProgram,
		required:Map<String, Bool>, adapterEnums:Map<String, String>, functions:Map<String, IrFunction>, selectedFunctions:Array<IrFunction>,
		boxNames:Map<String, String>, unboxNames:Map<String, String>):Void {
		var signatures:Map<String, Array<IrType>> = [],
			objects = [for (object in program.objects) object.name => object],
			globals = [for (field in program.staticFields) field.name => field.type],
			contracts = [for (entry in program.interfaces) entry.name => entry];
		for (native in program.natives) signatures.set(native.name, native.arguments);
		for (native in program.cNatives) signatures.set(native.name, native.arguments);
		function signature(name:String):Null<Array<IrType>> {
			if (signatures.exists(name)) return signatures.get(name);
			var fn = functions.get(name);
			if (fn == null) return null;
			var arguments = [for (argument in fn.arguments) argument.type];
			signatures.set(name, arguments);
			return arguments;
		}
		var fieldTypes:Map<String, Map<String, Null<IrType>>> = [];
		function fieldIndex(name:String):Null<Map<String, Null<IrType>>> {
			var known = fieldTypes.get(name);
			if (known != null) return known;
			var object = objects.get(name);
			if (object == null) return null;
			var index:Map<String, Null<IrType>> = [for (field in object.fields) field.name => field.type];
			fieldTypes.set(name, index);
			return index;
		}
		function fieldType(type:IrType, field:String):Null<IrType> {
			var name = switch type {
				case Obj(name):
					name;
				default:
					return null;
			}, cache = fieldIndex(name);
			if (cache == null) return null;
			if (cache.exists(field)) return cache.get(field);
			var object = objects.get(name), owner = object == null ? null : object.base;
			while (owner != null) {
				var inherited = fieldIndex(owner);
				if (inherited != null && inherited.exists(field)) {
					var type = inherited.get(field);
					cache.set(field, type);
					return type;
				}
				var parent = objects.get(owner);
				owner = parent == null ? null : parent.base;
			}
			cache.set(field, null);
			return null;
		}
		var interfaceMethods:Map<String, Map<String, Null<Array<IrType>>>> = [];
		function interfaceArguments(name:String, method:String):Null<Array<IrType>> {
			var declaration = contracts.get(name);
			if (declaration == null) return null;
			var cache = interfaceMethods.get(name);
			if (cache == null) {
				cache = [for (entry in declaration.methods) entry.name => entry.arguments];
				interfaceMethods.set(name, cache);
			}
			if (cache.exists(method)) return cache.get(method);
			for (base in declaration.bases) {
				var inherited = interfaceArguments(base, method);
				if (inherited != null) {
					cache.set(method, inherited);
					return inherited;
				}
			}
			cache.set(method, null);
			return null;
		}
		var objectMethods:Map<String, Map<String, Null<Array<IrType>>>> = [], methodNames:Map<
			String,
			Map<String, String>> = [];
		function methodIndex(name:String):Null<Map<String, String>> {
			var known = methodNames.get(name);
			if (known != null) return known;
			var object = objects.get(name);
			if (object == null) return null;
			var index = [for (entry in object.methods) entry.name => entry.functionName];
			methodNames.set(name, index);
			return index;
		}
		function methodArguments(type:IrType, method:String):Null<Array<IrType>> {
			var name = switch type {
				case Virtual(name):
					return interfaceArguments(name, method);
				case Obj(name):
					name;
				default:
					return null;
			}, cache = objectMethods.get(name);
			if (cache == null) {
				cache = [];
				objectMethods.set(name, cache);
			}
			if (cache.exists(method)) return cache.get(method);
			var owner:Null<String> = name, result:Null<Array<IrType>> = null;
			while (owner != null) {
				var methods = methodIndex(owner), target = methods == null ? null : methods.get(method);
				if (target != null) {
					var arguments = signature(target);
					if (arguments != null) result = arguments.slice(1);
					break;
				}
				var object = objects.get(owner);
				owner = object == null ? null : object.base;
			}
			cache.set(method, result);
			return result;
		}
		function isTag(value:IrValue):Bool return switch value.type {
			case EnumTag(_):
				true;
			default:
				false;
		};
		function hasTag(arguments:Array<IrValue>):Bool {
			for (argument in arguments) if (isTag(argument)) return true;
			return false;
		}
		function needsArguments(arguments:Array<IrValue>, expected:Null<Array<IrType>>):Bool {
			if (expected == null) return false;
			for (index in 0...arguments.length) if (index < expected.length
				&& isTag(arguments[index]) && (switch expected[index] {
				case Dyn:
					true;
				default:
					false;
			}
			)) return true;
			return false;
		}

		if (selectedFunctions.length == 0) return;
		var currentFunction = selectedFunctions[0], currentBlock = new IrBlock(-1), next = -1, position = 0,
			blockChanged = false, rewritten:Array<Located<IrInstruction>> = [];
		function markChanged():Void {
			if (!blockChanged) {
				rewritten = currentBlock.instructions.slice(0, position);
				blockChanged = true;
			}
		}
		function adapt(value:IrValue, expected:Null<IrType>):IrValue {
			return switch value.type {
				case EnumTag(name) if ((switch expected { case Dyn: true; default: false; })):
					markChanged();
					if (next < 0) {
						next = 0;
						for (argument in currentFunction.arguments)
							if (argument.id >= next) next = argument.id + 1;
						for (block in currentFunction.blocks)
							for (entry in block.instructions) {
								var output = IrOperands.output(entry.value);
								if (output != null && output.id >= next) next = output.id + 1;
							}
					}
					var boxed = new IrValue(next++, "$enum-tag:implicit-box", Dyn);
					required.set(name, true);
					rewritten.push(new Located(Call(boxed, boxNames.get(name), [value]),
						currentBlock.instructions[position].provenance));
					boxed;
				default: value;
			};
		}
		for (fn in selectedFunctions) {
			currentFunction = fn;
			next = -1;
			for (block in fn.blocks) {
				currentBlock = block;
				blockChanged = false;
				for (index in 0...block.instructions.length) {
					position = index;
					var located = block.instructions[index], changed = false;
					var instruction = switch located.value {
						case ToDyn(output, value) if (isTag(value)):
							markChanged();
							changed = true;
							var name = switch value.type {
								case EnumTag(name):
									name;
								default:
									throw "Expected tag";
							};
							required.set(name, true);
							Call(output, boxNames.get(name), [value]);
						case SafeCast(output, value) if (isTag(output)):
							markChanged();
							changed = true;
							var name = switch output.type {
								case EnumTag(name):
									name;
								default:
									throw "Expected tag";
							};
							required.set(name, true);
							Call(output, unboxNames.get(name), [value]);
						case Intrinsic(output, EnumTagBox(EnumTag(name)), arguments):
							if (!boxNames.exists(name) || arguments.length != 1 || !IrVerifier.sameType(arguments[0].type, EnumTag(name))
								|| !IrVerifier.sameType(output.type, Dyn)) throw "Invalid enum tag box signature";
							markChanged(); changed = true; required.set(name, true);
							Call(output, boxNames.get(name), arguments);
						case Intrinsic(output, EnumTagUnbox(EnumTag(name)), arguments):
							if (!unboxNames.exists(name) || arguments.length != 1 || !IrVerifier.sameType(arguments[0].type, Dyn)
								|| !IrVerifier.sameType(output.type, EnumTag(name))) throw "Invalid enum tag unbox signature";
							markChanged(); changed = true; required.set(name, true);
							Call(output, unboxNames.get(name), arguments);
						case Call(output, name, arguments):
							var tagArgument = hasTag(arguments);
							if (!tagArgument && !isTag(output)) located.value else {
								var adapter = adapterEnums.get(name);
								if (adapter != null) {
									required.set(adapter, true);
									located.value;
								} else if (!tagArgument) located.value else {
									// Lane primitives consume tags directly in the subsequent array rewrite.
									var lane = arguments.length > 0 && (switch arguments[0].type {
										case Array(EnumTag(_)): IrArrayRuntimeNatives.isStorage(name);
										default: false;
									});
									var expected = lane ? null : signature(name);
									if (!needsArguments(arguments, expected)) located.value else {
										changed = true;
										Call(output, name, [for (index in 0...arguments.length)
											adapt(arguments[index], expected != null && index < expected.length ? expected[index] : null)]);
									}
								}
							}
						case CNativeCall(output, name, arguments) if (hasTag(arguments) && needsArguments(
							arguments,
							signature(name)
						)):
							var expected = signature(name);
							if (expected == null) throw 'Missing tag escape signature "$name"';
							changed = true;
							CNativeCall(
								output,
								name,
								[for (index in 0...arguments.length) adapt(
									arguments[index],
									index < expected.length ? expected[index] : null
								)]
							);
						case MethodCall(output, owner, method, arguments, terminalReceiver) if (hasTag(arguments)):
							var expected = methodArguments(owner.type, method);
							if (!needsArguments(arguments, expected)) located.value else {
								changed = true;
								MethodCall(
									output,
									owner,
									method,
									[for (index in 0...arguments.length) adapt(
										arguments[index],
										expected != null && index < expected.length ? expected[index] : null
									)],
									terminalReceiver
								);
							}
						case CallClosure(output, closure, arguments) if (hasTag(arguments)):
							var expected = switch closure.type {
								case Function(arguments, _):
									arguments;
								default:
									[];
							};
							if (!needsArguments(arguments, expected)) located.value else {
								changed = true;
								CallClosure(
									output,
									closure,
									[for (index in 0...arguments.length) adapt(
										arguments[index],
										index < expected.length ? expected[index] : null
									)]
								);
							}
						case FieldSet(object, field, value) if (isTag(value)):
							var expected = fieldType(object.type, field);
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							}
							)) {
								changed = true;
								FieldSet(object, field, adapt(value, expected));
							} else located.value;
						case GlobalSet(name, value) if (isTag(value)):
							var expected = globals.get(name);
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							}
							)) {
								changed = true;
								GlobalSet(name, adapt(value, expected));
							} else located.value;
						case ArraySet(array, index, value) if (isTag(value)):
							var expected = switch array.type {
								case Array(element):
									element;
								default:
									null;
							};
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							}
							)) {
								changed = true;
								ArraySet(array, index, adapt(value, expected));
							} else located.value;
						default:
							located.value;
					};
					if (blockChanged) rewritten.push(changed ? new Located(instruction, located.provenance) : located);
				}
				if (blockChanged) {
					block.instructions.resize(0);
					for (located in rewritten) block.instructions.push(located);
				}
			}
		}
	}
}

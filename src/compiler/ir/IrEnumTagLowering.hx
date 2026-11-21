package compiler.ir;

import compiler.core.InternalError;
import compiler.ir.Ir;
import compiler.ir.IrInlineEnumRequests.IrInlineEnumProviders;
import compiler.ir.SourceProvenance.Located;

/** Select nominal scalar storage independently of payload-enum escape eligibility. */
class IrEnumTagLowering {
	public static function run(program:IrProgram):IrProgram {
		var dynamicUnboxes:Map<String, IrType> = [];
		for (fn in program.functions)
			switch fn.kind {
				case EnumDynamicUnbox(type):
					dynamicUnboxes.set(fn.name, type);
				default:
			}
		var names:Map<String, Bool> = [
			for (entry in program.enums)
				if (IrEnumTagStorage.eligible(entry)) entry.name => true
		];
		if (!names.keys().hasNext())
			return program;
		var tags:Map<String, IrType> = [for (name in names.keys()) name => EnumTag(name)];
		function changes(type:IrType):Bool
			return switch type {
				case Enum(name):
					names.exists(name);
				case Array(inner), Iterator(inner), Nullable(inner):
					changes(inner);
				case Function(arguments, result):
					var changed = changes(result);
					for (argument in arguments)
						if (changes(argument)) {
							changed = true;
							break;
						}
					changed;
				default:
					false;
			};
		function mapped(type:IrType):IrType
			return switch type {
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
			if ((switch fn.provides {
				case Serves(_,
					operation): (IrProviders.base(operation) == compiler.core.Provides.ProviderOperation.Equals
					|| IrProviders.base(operation) == compiler.core.Provides.ProviderOperation.ReflectEquals);
				case None: false;
			}) && fn.arguments.length == 2)
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
					case EnumTag(enumName): b.safeCast(b.intrinsic(EnumTagBox(EnumTag(enumName)), [value], Dyn),
						logical);
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
		program.objects = [for (object in program.objects)
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					methods:object.methods,
					fields:[for (field in object.fields)
					{
						name:field.name,
							type:mapped(field.type),
							nativeLayout:field.nativeLayout,
							scalarStorage:field.scalarStorage,
							nullableScalarStorage:field.nullableScalarStorage
					}]
			}];
		program.staticFields = [for (field in program.staticFields) {
			name:field.name, type:mapped(field.type)
		}];
		program.interfaces = [for (entry in program.interfaces)
			{
				name:entry.name,
					bases:entry.bases,
					methods:[for (method in entry.methods)
					{
						name:method.name,
							arguments:[for (argument in method.arguments) mapped(argument)],
							result:mapped(method.result)
					}]
			}];
		program.enums = [for (entry in program.enums)
			{
				name:entry.name,
					isRecursive:entry.isRecursive,
					inlineStorage:entry.inlineStorage,
					cases:[for (constructor in entry.cases)
					{
						name:constructor.name, params:[for (parameter in constructor.params) mapped(parameter)]
					}]
			}];
		function valueChanges(value:IrValue):Bool
			return changes(value.type);
		function nonOutputChanges(instruction:IrInstruction):Bool {
			switch instruction {
				case Call(_, name, _) if (tagEqualities.exists(name.name)):
					return true;
				case Call(_, target, _) if (nativeWrappers.exists(target.name)):
					return true;
				case CNativeCall(_, name, _) if (nativeWrappers.exists(name)):
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
			if (changes(fn.result))
				return true;
			for (argument in fn.arguments)
				if (valueChanges(argument))
					return true;
			for (binding in fn.debugBindings)
				if (valueChanges(binding.value))
					return true;
			// Valid SSA uses have the type of their definition. Discover changed carriers once per definition;
			// instruction rewriting below still visits every operand, and the verifier checks every use.
			for (block in fn.blocks)
				for (located in block.instructions) {
					var output = IrOperands.output(located.value);
					if (output != null && valueChanges(output))
						return true;
					if (nonOutputChanges(located.value))
						return true;
				}
			return false;
		}
		var changedFunctions:Array<IrFunction> = [];
		program.functions = [for (fn in program.functions)
			if (!functionChanges(fn)) fn else {
				var values:Map<Int, IrValue> = [];
				function use(value:IrValue):IrValue {
					if (!valueChanges(value))
						return value;
					if (!values.exists(value.id))
						values.set(value.id, new IrValue(value.id, value.name, mapped(value.type)));
					return values.get(value.id);
				}
				var indexTags:Map<Int, IrValue> = [],
					replacedIndices:Map<Int, Bool> = [];
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
				var blocks = [for (block in fn.blocks) {
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
							case Call(output, name, arguments) if (tagEqualities.exists(name.name)):
								instruction = Equal(use(output), use(arguments[0]), use(arguments[1]));
							case Equal(output, left, right)
								if (indexTags.exists(left.id)
								&& indexTags.exists(right.id)
								&& IrVerifier.sameType(indexTags.get(left.id).type, indexTags.get(right.id).type)):
								instruction = Equal(use(output), indexTags.get(left.id), indexTags.get(right.id));
								replacedIndices.set(left.id, true);
								replacedIndices.set(right.id, true);
							case Call(output, target, arguments) if (nativeWrappers.exists(target.name)):
								instruction = Call(use(output), IrSymbol.of(nativeWrappers.get(target.name)),
									[for (argument in arguments) use(argument)]);
							case CNativeCall(output, name, arguments) if (nativeWrappers.exists(name)):
								instruction = Call(use(output), IrSymbol.of(nativeWrappers.get(name)),
									[for (argument in arguments) use(argument)]);
							case Call(output, name, arguments) if (dynamicUnboxes.exists(name.name)):
								if (!IrVerifier.sameType(dynamicUnboxes.get(name.name), output.type))
									throw new InternalError("Malformed enum unbox signature");
								switch use(output).type {
									case EnumTag(enumName): instruction = Intrinsic(use(output),
										EnumTagUnbox(EnumTag(enumName)),
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
					var terminator = block.terminator;
					if (terminator != null) result.terminator = new Located(switch terminator.value {
						case Unreachable: Unreachable;
						case Return(value): Return(use(value));
						case Throw(value): Throw(use(value));
						case Rethrow(value): Rethrow(use(value));
						case Jump(id): Jump(id);
						case Branch(condition, yes, no): Branch(use(condition), yes, no);
						case Switch(switchValue, switchTargets, switchOtherwise): Switch(use(switchValue),
							switchTargets.copy(), switchOtherwise);
					}, terminator.provenance);
					result;
				}];
				if (replacedIndices.keys().hasNext()) {
					var used:Map<Int, Bool> = [];
					for (block in blocks) {
						for (located in block.instructions) {
							for (input in IrOperands.inputs(located.value))
								used.set(input.id, true);
							switch located.value {
								case Phi(_, inputs):
									for (input in inputs)
										used.set(input.value.id, true);
								default:
							}
						}
						if (block.terminator != null)
							switch block.terminator.value {
								case Return(value), Throw(value), Rethrow(value), Branch(value, _, _),
									Switch(value, _, _):
									used.set(value.id, true);
								case Jump(_), Unreachable:
							}
					}
					for (binding in fn.debugBindings)
						used.set(binding.value.id, true);
					for (block in blocks) {
						var kept = [for (located in block.instructions)
							if (switch located.value {
								case EnumIndex(output, _): !replacedIndices.exists(output.id) || used.exists(output.id);
								default: true;
							}) located];
						block.instructions.splice(0, block.instructions.length);
						for (located in kept)
							block.instructions.push(located);
					}
				}
				var rewrittenFunction = new IrFunction(fn.name, [for (argument in fn.arguments) use(argument)],
					mapped(fn.result), blocks, fn.kind, [for (binding in fn.debugBindings)
					{
						identity:binding.identity,
							name:binding.name,
							value:use(binding.value),
							path:binding.path,
							scopeStart:binding.scopeStart,
							scopeEnd:binding.scopeEnd
					}], fn.inlineHint, fn.retention);
				changedFunctions.push(rewrittenFunction);
				rewrittenFunction;
			}];
		var kept:Map<String, Bool> = [];
		kept.set(program.entryPoint, true);
		for (fn in program.functions.concat(generated)) {
			if (fn.retention != Reachable)
				kept.set(fn.name, true);
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, name, _), StaticClosure(_, name), InstanceClosure(_, name, _):
							kept.set(name.name, true);
						default:
					}
		}
		for (object in program.objects)
			for (method in object.methods)
				kept.set(method.functionName.name, true);
		for (native in program.natives)
			if (native.generatedFunctionDependencies != null)
				for (name in native.generatedFunctionDependencies)
					kept.set(name, true);
		program.functions = [
			for (fn in program.functions)
				if (!tagEqualities.exists(fn.name) || kept.exists(fn.name)) fn
		];
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

	/** Resolve only the operations a late producer has just added, without rescanning earlier functions. */
	public static function resolveGenerated(program:IrProgram, generated:Array<IrFunction>):Void {
		for (fn in generated)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Intrinsic(_, InlineEnumBox(_) | InlineEnumUnbox(_) | EnumTagBox(_) | EnumTagUnbox(_), _):
							finishEscapes(program, generated);
							return;
						default:
					}
	}

	/**
	 * `escapes` on bodies, at the end of assembly (the conversion point, docs/design/IR_CORE_COLUMNS.md) and as the pipeline's
	 * last check before the inliner: each function is read as its body (`bodyIn` with
	 * `types`), and one that changes becomes its edited body: owned by the next stage: edited in
	 * place, or a copy when a cache holds the body. A function nothing changes stays the same object.
	 */
	public static function escapeBodies(program:IrProgram, types:IrTypeIds, builder:IrBodyBuilder):Void {
		var existing = new IrFunctionIndex("enum-tag-lowering", program.functions),
			adapterEnums:Map<String, String> = [];
		var symbols = IrEnumTagStorage.adapterNames(program);
		var boxNames:Map<String, String> = [],
			unboxNames:Map<String, String> = [];
		for (name => pair in symbols) {
			boxNames.set(name, pair.box);
			unboxNames.set(name, pair.unbox);
		}
		for (fn in program.functions)
			switch fn.kind {
				case EnumTagAdapter(EnumTag(name), _):
					adapterEnums.set(fn.name, name);
				default:
			}
		var tags = symbols.keys().hasNext();
		var walk = new IrBodyTagEscapes(program, tags, new IrTagEscapeSignatures(program, existing), adapterEnums,
			boxNames,
			unboxNames);
		var functions = program.functions, result:Null<Array<IrFunction>> = null;
		for (index in 0...functions.length) {
			var fn = functions[index], body = fn.bodyIn(types, builder);
			if (walk.rewrite(body, false)) {
				var edited = body.forEditing(builder);
				walk.rewrite(edited, true);
				if (result == null)
					result = functions.copy();
				var replacement = IrFunction.ofOwnedBody(edited);
				result[index] = replacement;
				existing.set(fn.name, replacement);
			}
		}
		if (result != null)
			program.functions = result;
		if (!tags)
			return;
		addAdapters(program, walk.required, existing, boxNames, unboxNames);
	}

	static function addAdapters(program:IrProgram, required:Map<String, Bool>, existing:IrFunctionIndex,
			boxNames:Map<String, String>, unboxNames:Map<String, String>):Void {
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
				for (helper in IrEnumTagStorage.adapters(declarations.get(name), boxNames.get(name),
					unboxNames.get(name)))
					if (!existing.exists(helper.name)) {
						existing.set(helper.name, helper);
						program.functions.push(helper);
					}
	}

	static function finishEscapes(program:IrProgram, changedFunctions:Array<IrFunction>):Void {
		changedFunctions = IrInlineEnumRequests.resolve(program, changedFunctions);
		var required:Map<String, Bool> = [];
		var existing = new IrFunctionIndex("enum-tag-lowering", program.functions),
			adapterEnums:Map<String, String> = [];
		var symbols = IrEnumTagStorage.adapterNames(program);
		var boxNames:Map<String, String> = [],
			unboxNames:Map<String, String> = [];
		for (name => pair in symbols) {
			boxNames.set(name, pair.box);
			unboxNames.set(name, pair.unbox);
		}
		for (fn in program.functions)
			switch fn.kind {
				case EnumTagAdapter(EnumTag(name), _):
					adapterEnums.set(fn.name, name);
				default:
			}
		if (!symbols.keys().hasNext())
			return;
		rewriteEscapes(program, required, adapterEnums, existing, changedFunctions, boxNames, unboxNames);
		addAdapters(program, required, existing, boxNames, unboxNames);
	}

	static function rewriteEscapes(program:IrProgram, required:Map<String, Bool>, adapterEnums:Map<String, String>,
			functions:IrFunctionIndex,
			selectedFunctions:Array<IrFunction>, boxNames:Map<String, String>, unboxNames:Map<String, String>):Void {
		var lookups = new IrTagEscapeSignatures(program, functions);
		function isTag(value:IrValue):Bool
			return switch value.type {
				case EnumTag(_):
					true;
				default:
					false;
			};
		function hasTag(arguments:Array<IrValue>):Bool {
			for (argument in arguments)
				if (isTag(argument))
					return true;
			return false;
		}
		function needsArguments(arguments:Array<IrValue>, expected:Null<Array<IrType>>):Bool {
			if (expected == null)
				return false;
			for (index in 0...arguments.length)
				if (index < expected.length && isTag(arguments[index]) && (switch expected[index] {
					case Dyn:
						true;
					default:
						false;
				}))
					return true;
			return false;
		}

		if (selectedFunctions.length == 0)
			return;
		var currentFunction = selectedFunctions[0],
			currentBlock = new IrBlock(-1),
			next = -1,
			position = 0,
			blockChanged = false,
			rewritten:Array<Located<IrInstruction>> = [];
		function markChanged():Void {
			if (!blockChanged) {
				rewritten = currentBlock.instructions.slice(0, position);
				blockChanged = true;
			}
		}
		function adapt(value:IrValue, expected:Null<IrType>):IrValue {
			return switch value.type {
				case EnumTag(name) if ((switch expected {
					case Dyn: true;
					default: false;
				})): markChanged();
				if (next < 0)
					next = currentFunction.nextValueId();
				var boxed = new IrValue(next++, "$enum-tag:implicit-box", Dyn);
				required.set(name, true);
				rewritten.push(new Located(Call(boxed, IrSymbol.of(boxNames.get(name)), [value]),
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
									throw new InternalError("Expected tag");
							};
							required.set(name, true);
							Call(output, IrSymbol.of(boxNames.get(name)), [value]);
						case SafeCast(output, value) if (isTag(output)):
							markChanged();
							changed = true;
							var name = switch output.type {
								case EnumTag(name):
									name;
								default:
									throw new InternalError("Expected tag");
							};
							required.set(name, true);
							Call(output, IrSymbol.of(unboxNames.get(name)), [value]);
						case Intrinsic(output, EnumTagBox(EnumTag(name)), arguments):
							if (!boxNames.exists(name)
								|| arguments.length != 1
								|| !IrVerifier.sameType(arguments[0].type, EnumTag(name))
								|| !IrVerifier.sameType(output.type, Dyn))
								throw new InternalError("Invalid enum tag box signature");
							markChanged();
							changed = true;
							required.set(name, true);
							Call(output, IrSymbol.of(boxNames.get(name)), arguments);
						case Intrinsic(output, EnumTagUnbox(EnumTag(name)), arguments):
							if (!unboxNames.exists(name)
								|| arguments.length != 1
								|| !IrVerifier.sameType(arguments[0].type, Dyn)
								|| !IrVerifier.sameType(output.type, EnumTag(name)))
								throw new InternalError("Invalid enum tag unbox signature");
							markChanged();
							changed = true;
							required.set(name, true);
							Call(output, IrSymbol.of(unboxNames.get(name)), arguments);
						case Call(output, name, arguments):
							var tagArgument = hasTag(arguments);
							if (!tagArgument && !isTag(output)) located.value else {
								var adapter = adapterEnums.get(name.name);
								if (adapter != null) {
									required.set(adapter, true);
									located.value;
								} else if (!tagArgument)
									located.value
										else {
										// Lane primitives consume tags directly in the subsequent array rewrite.
										var lane = arguments.length > 0 && (switch arguments[0].type {
											case Array(EnumTag(_)): IrArrayRuntimeNatives.isStorage(name.name);
											default: false;
										});
										var expected = lane ? null : lookups.signature(name.name);
										if (!needsArguments(arguments, expected))
											located.value
												else {
												changed = true;
												Call(output, name, [
													for (index in 0...arguments.length)
														adapt(arguments[index], expected != null
														&& index < expected.length ? expected[index] : null)
												]);
											}
									}
							}
						case CNativeCall(output, name,
							arguments) if (hasTag(arguments) && needsArguments(arguments, lookups.signature(name))):
							var expected = lookups.signature(name);
							if (expected == null)
								throw new InternalError('Missing tag escape signature "$name"');
							changed = true;
							CNativeCall(output, name, [
								for (index in 0...arguments.length)
									adapt(arguments[index], index < expected.length ? expected[index] : null)
							]);
						case MethodCall(output, owner, method, arguments, terminalReceiver) if (hasTag(arguments)):
							var expected = lookups.methodArguments(owner.type, method);
							if (!needsArguments(arguments, expected)) located.value else {
								changed = true;
								MethodCall(output, owner, method, [
									for (index in 0...arguments.length)
										adapt(arguments[index],
										expected != null && index < expected.length ? expected[index] : null)
								], terminalReceiver);
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
								CallClosure(output, closure, [
									for (index in 0...arguments.length)
										adapt(arguments[index], index < expected.length ? expected[index] : null)
								]);
							}
						case FieldSet(object, field, value) if (isTag(value)):
							var expected = lookups.fieldType(object.type, field);
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							})) {
								changed = true;
								FieldSet(object, field, adapt(value, expected));
							} else located.value;
						case GlobalSet(name, value) if (isTag(value)):
							var expected = lookups.global(name);
							if ((switch expected {
								case Dyn:
									true;
								default:
									false;
							})) {
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
							})) {
								changed = true;
								ArraySet(array, index, adapt(value, expected));
							} else located.value;
						default:
							located.value;
					};
					if (blockChanged)
						rewritten.push(changed ? new Located(instruction, located.provenance) : located);
				}
				if (blockChanged) {
					block.instructions.resize(0);
					for (located in rewritten)
						block.instructions.push(located);
				}
			}
		}
	}
}

/** The types an escape check expects where a value leaves its function: arguments of calls, fields, globals. Memoized by name. */
class IrTagEscapeSignatures {
	final functions:IrFunctionIndex;
	final signatures:Map<String, Array<IrType>> = [];
	final objects:Map<String, IrObject>;
	final globals:Map<String, IrType>;
	final contracts:Map<String, IrInterface>;
	final fieldTypes:Map<String, Map<String, Null<IrType>>> = [];
	final interfaceMethods:Map<String, Map<String, Null<Array<IrType>>>> = [];
	final objectMethods:Map<String, Map<String, Null<Array<IrType>>>> = [];
	final methodNames:Map<String, Map<String, String>> = [];

	public function new(program:IrProgram, functions:IrFunctionIndex) {
		this.functions = functions;
		objects = [for (object in program.objects) object.name => object];
		globals = [for (field in program.staticFields) field.name => field.type];
		contracts = [for (entry in program.interfaces) entry.name => entry];
		for (native in program.natives)
			signatures.set(native.name, native.arguments);
		for (native in program.cNatives)
			signatures.set(native.name, native.arguments);
	}

	/** The argument types of the function or native `name`, or null when there is none. */
	public function signature(name:String):Null<Array<IrType>> {
		if (signatures.exists(name))
			return signatures.get(name);
		var fn = functions.get(name);
		if (fn == null)
			return null;
		var arguments = [for (argument in fn.arguments) argument.type];
		signatures.set(name, arguments);
		return arguments;
	}

	public function global(name:String):Null<IrType>
		return globals.get(name);

	function fieldIndex(name:String):Null<Map<String, Null<IrType>>> {
		var known = fieldTypes.get(name);
		if (known != null)
			return known;
		var object = objects.get(name);
		if (object == null)
			return null;
		var index:Map<String, Null<IrType>> = [for (field in object.fields) field.name => field.type];
		fieldTypes.set(name, index);
		return index;
	}

	/** The declared type of `field` on an object of `type`, inherited ones included, or null. */
	public function fieldType(type:IrType, field:String):Null<IrType> {
		var name = switch type {
			case Obj(name):
				name;
			default:
				return null;
		}, cache = fieldIndex(name);
		if (cache == null)
			return null;
		if (cache.exists(field))
			return cache.get(field);
		var object = objects.get(name),
			owner = object == null ? null : object.base;
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

	function interfaceArguments(name:String, method:String):Null<Array<IrType>> {
		var declaration = contracts.get(name);
		if (declaration == null)
			return null;
		var cache = interfaceMethods.get(name);
		if (cache == null) {
			cache = [for (entry in declaration.methods) entry.name => entry.arguments];
			interfaceMethods.set(name, cache);
		}
		if (cache.exists(method))
			return cache.get(method);
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

	function methodIndex(name:String):Null<Map<String, String>> {
		var known = methodNames.get(name);
		if (known != null)
			return known;
		var object = objects.get(name);
		if (object == null)
			return null;
		var index = [for (entry in object.methods) entry.name => entry.functionName.name];
		methodNames.set(name, index);
		return index;
	}

	/** The argument types, receiver left out, of `method` called on a value of `type`, or null. */
	public function methodArguments(type:IrType, method:String):Null<Array<IrType>> {
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
		if (cache.exists(method))
			return cache.get(method);
		var owner:Null<String> = name, result:Null<Array<IrType>> = null;
		while (owner != null) {
			var methods = methodIndex(owner),
				target = methods == null ? null : methods.get(method);
			if (target != null) {
				var arguments = signature(target);
				if (arguments != null)
					result = arguments.slice(1);
				break;
			}
			var object = objects.get(owner);
			owner = object == null ? null : object.base;
		}
		cache.set(method, result);
		return result;
	}
}

/**
 * `IrEnumTagLowering.finishEscapes` on a body: inline-enum requests become calls of their providers, and, when the program has
 * tag adapters (`tags`), a tag that escapes where a `Dyn` is expected is boxed by its adapter, as the object version does. A walk that does not `edit` only says whether one that does would change the body;
 * both record the tags that need adapters in `required`.
 */
class IrBodyTagEscapes {
	public final required:Map<String, Bool> = [];

	final tags:Bool;
	final lookups:IrTagEscapeSignatures;
	final providers:IrInlineEnumProviders;
	final adapterEnums:Map<String, String>;
	final boxNames:Map<String, String>;
	final unboxNames:Map<String, String>;

	var body:IrBody;
	var edit = false;
	var changed = false;

	public function new(program:IrProgram, tags:Bool, lookups:IrTagEscapeSignatures, adapterEnums:Map<String, String>,
			boxNames:Map<String, String>, unboxNames:Map<String, String>) {
		this.tags = tags;
		this.lookups = lookups;
		this.adapterEnums = adapterEnums;
		this.boxNames = boxNames;
		this.unboxNames = unboxNames;
		providers = new IrInlineEnumProviders(program);
		body = null;
	}

	/** Whether `body` changes; it is changed when `edit` is set. */
	public function rewrite(body:IrBody, edit:Bool):Bool {
		this.body = body;
		this.edit = edit;
		changed = false;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var following = body.nextRow(row);
				visit(block, row);
				if (changed && !edit)
					return true;
				row = following;
			}
		}
		return changed;
	}

	static function tagName(type:IrType):Null<String>
		return switch type {
			case EnumTag(name): name;
			default: null;
		};

	static function isDyn(type:Null<IrType>):Bool
		return switch type {
			case Dyn: true;
			default: false;
		};

	inline function isTag(value:IrValueId):Bool
		return tagName(body.valueType(value)) != null;

	function hasTag(row:Int, from:Int):Bool {
		for (index in from...body.operandCount(row))
			if (isTag(body.operand(row, index)))
				return true;
		return false;
	}

	function needsArguments(row:Int, from:Int, expected:Null<Array<IrType>>):Bool {
		if (expected == null)
			return false;
		for (index in from...body.operandCount(row))
			if (index - from < expected.length && isTag(body.operand(row, index)) && isDyn(expected[index - from]))
				return true;
		return false;
	}

	/** Makes `row` a call of `name` with its operands and output. */
	function call(row:Int, name:String):Void {
		changed = true;
		if (edit)
			body.setOperation(row, IrOpcode.Call, IrSymbol.of(name).id);
	}

	/** Boxes each tag operand of `row` from `from` on whose expected type is `Dyn`, in a call before the row. */
	function adapt(block:Int, row:Int, from:Int, expected:Null<Array<IrType>>):Void {
		changed = true;
		if (!edit || expected == null)
			return;
		for (index in from...body.operandCount(row)) {
			var value = body.operand(row, index), name = tagName(body.valueType(value));
			if (name == null || index - from >= expected.length || !isDyn(expected[index - from]))
				continue;
			adaptOne(block, row, index, value, name);
		}
	}

	function adaptOne(block:Int, row:Int, index:Int, value:IrValueId, name:String):Void {
		var boxed = body.newValue("$enum-tag:implicit-box", body.typeId(Dyn));
		required.set(name, true);
		body.beginRow();
		body.pushOperand(value);
		var made = body.endRow(IrOpcode.Call, boxed, IrSymbol.of(boxNames.get(name)).id, body.provenance(row));
		body.linkBefore(block, row, made);
		body.setOperand(row, index, boxed);
	}

	function visit(block:Int, row:Int):Void {
		switch body.opcode(row) {
			case IrOpcode.InlineEnumBox, IrOpcode.InlineEnumUnbox:
				var count = body.operandCount(row);
				call(row, providers.provider(body.opcode(row) == IrOpcode.InlineEnumBox, body.typeOperand(row), count,
					count == 1 ? body.valueType(body.operand(row, 0)) : null, body.valueType(body.output(row))));
			case _ if (!tags):
			case IrOpcode.ToDyn:
				var name = tagName(body.valueType(body.operand(row, 0)));
				if (name != null) {
					required.set(name, true);
					call(row, boxNames.get(name));
				}
			case IrOpcode.SafeCast:
				var name = tagName(body.valueType(body.output(row)));
				if (name != null) {
					required.set(name, true);
					call(row, unboxNames.get(name));
				}
			case IrOpcode.EnumTagBox:
				var name = tagName(body.typeOperand(row));
				if (name != null) {
					if (!boxNames.exists(name)
						|| body.operandCount(row) != 1
						|| !IrVerifier.sameType(body.valueType(body.operand(row, 0)), EnumTag(name))
						|| !IrVerifier.sameType(body.valueType(body.output(row)), Dyn))
						throw new InternalError("Invalid enum tag box signature");
					required.set(name, true);
					call(row, boxNames.get(name));
				}
			case IrOpcode.EnumTagUnbox:
				var name = tagName(body.typeOperand(row));
				if (name != null) {
					if (!unboxNames.exists(name)
						|| body.operandCount(row) != 1
						|| !IrVerifier.sameType(body.valueType(body.operand(row, 0)), Dyn)
						|| !IrVerifier.sameType(body.valueType(body.output(row)), EnumTag(name)))
						throw new InternalError("Invalid enum tag unbox signature");
					required.set(name, true);
					call(row, unboxNames.get(name));
				}
			case IrOpcode.Call:
				var tagArgument = hasTag(row, 0), output = body.output(row);
				if (!tagArgument && (!output.exists() || !isTag(output)))
					return;
				var name = body.symbol(row).name, adapter = adapterEnums.get(name);
				if (adapter != null) {
					required.set(adapter, true);
					return;
				}
				if (!tagArgument)
					return;
				// Lane primitives consume tags directly in the subsequent array rewrite.
				var lane = body.operandCount(row) > 0 && (switch body.valueType(body.operand(row, 0)) {
					case Array(EnumTag(_)): IrArrayRuntimeNatives.isStorage(name);
					default: false;
				});
				var expected = lane ? null : lookups.signature(name);
				if (needsArguments(row, 0, expected))
					adapt(block, row, 0, expected);
			case IrOpcode.CNativeCall:
				if (!hasTag(row, 0))
					return;
				var name = body.symbol(row).name, expected = lookups.signature(name);
				if (needsArguments(row, 0, expected))
					adapt(block, row, 0, expected);
			case IrOpcode.MethodCall:
				if (!hasTag(row, 1))
					return;
				var expected = lookups.methodArguments(body.valueType(body.operand(row, 0)), body.symbol(row).name);
				if (needsArguments(row, 1, expected))
					adapt(block, row, 1, expected);
			case IrOpcode.CallClosure:
				if (!hasTag(row, 1))
					return;
				var expected = switch body.valueType(body.operand(row, 0)) {
					case Function(arguments, _): arguments;
					default: [];
				};
				if (needsArguments(row, 1, expected))
					adapt(block, row, 1, expected);
			case IrOpcode.FieldSet:
				var value = body.operand(row, 1), name = tagName(body.valueType(value));
				if (name != null
					&& isDyn(lookups.fieldType(body.valueType(body.operand(row, 0)), body.symbol(row).name)))
					boxOperand(block, row, 1, value, name);
			case IrOpcode.GlobalSet:
				var value = body.operand(row, 0), name = tagName(body.valueType(value));
				if (name != null && isDyn(lookups.global(body.symbol(row).name)))
					boxOperand(block, row, 0, value, name);
			case IrOpcode.ArraySet:
				var value = body.operand(row, 2), name = tagName(body.valueType(value));
				if (name != null && isDyn(switch body.valueType(body.operand(row, 0)) {
					case Array(element): element;
					default: null;
				}))
					boxOperand(block, row, 2, value, name);
			default:
		}
	}

	function boxOperand(block:Int, row:Int, index:Int, value:IrValueId, name:String):Void {
		changed = true;
		if (edit)
			adaptOne(block, row, index, value, name);
	}
}

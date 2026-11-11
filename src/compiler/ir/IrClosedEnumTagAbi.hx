package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

/** Project an unobserved nominal tag to its integer ABI, including ordinary integer arrays. */
class IrClosedEnumTagAbi {
	final closed:Map<String, Bool>;

	function new(closed:Map<String, Bool>)
		this.closed = closed;

	public static function run(program:IrProgram):IrProgram {
		var closed = select(program);
		if (!closed.keys().hasNext())
			return program;
		var pass = new IrClosedEnumTagAbi(closed);
		program.functions = [for (fn in program.functions) pass.allocations(fn)];
		var typedAllocationUsed = false;
		for (fn in program.functions)
			for (block in fn.blocks)
				for (located in block.instructions)
					switch located.value {
						case Call(_, "__array_alloc_typed_ref", _):
							typedAllocationUsed = true;
						default:
					}
		if (!typedAllocationUsed)
			program.natives = [
				for (native in program.natives)
					if (native.name != "__array_alloc_typed_ref") native
			];
		return pass.project(program);
	}

	/** Recognize the checked factory protocol once per function, with the same single-use proof as lane allocation. */
	function allocations(fn:IrFunction):IrFunction {
		var descriptors:Map<Int, IrType> = [],
			uses:Map<Int, Int> = [],
			changed = false,
			blocks:Array<IrBlock> = [],
			removed:Map<Int, Bool> = [];
		function note(value:IrValue):Void
			uses.set(value.id, (uses.exists(value.id) ? uses.get(value.id) : 0) + 1);
		for (block in fn.blocks) {
			for (located in block.instructions) {
				for (input in IrOperands.inputs(located.value))
					note(input);
				switch located.value {
					case TypeValue(out, type):
						descriptors.set(out.id, type);
					case Phi(_, inputs):
						for (input in inputs)
							note(input.value);
					default:
				}
			}
			if (block.terminator != null)
				switch block.terminator.value {
					case Return(value), Throw(value), Rethrow(value), Branch(value, _, _):
						note(value);
					case Jump(_):
				}
		}
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id), index = 0;
			while (index < block.instructions.length) {
				var located = block.instructions[index],
					instruction = located.value;
				switch instruction {
					case Call(raw, "__array_alloc_typed_ref", arguments) if (arguments.length == 2 && index + 2 < block.instructions.length):
						switch [block.instructions[index + 1].value, block.instructions[index + 2].value] {
							case [ToDyn(boxed, source), SafeCast(out, input)] if (source.id == raw.id && input.id == boxed.id):
								switch out.type {
									case Array(EnumTag(name)) if (closed.exists(name)):
										if (uses.get(raw.id) != 1
											|| uses.get(boxed.id) != 1
											|| !IrVerifier.sameType(descriptors.get(arguments[1].id), Enum(name)))
											throw "Closed enum array allocation escapes or has an incompatible descriptor";
										instruction = Call(out, "__array_alloc_i32", [arguments[0]]);
										removed.set(raw.id, true);
										removed.set(boxed.id, true);
										changed = true;
										index += 2;
									default:
								}
							default:
						}
					default:
				}
				copy.instructions.push(new Located(instruction, located.provenance));
				index++;
			}
			copy.terminator = block.terminator;
			blocks.push(copy);
		}
		return changed ? fn.withBlocks(blocks, [for (binding in fn.debugBindings) if (!removed.exists(binding.value.id)) binding]) : fn;
	}

	function changes(type:IrType):Bool
		return switch type {
			case EnumTag(name): closed.exists(name);
			case Array(inner), Iterator(inner), Nullable(inner): changes(inner);
			case Function(args, result): Lambda.exists(args, changes) || changes(result);
			default: false;
		};

	function physical(type:IrType):IrType
		return switch type {
			case EnumTag(name) if (closed.exists(name)): I32;
			case Array(inner) if (changes(inner)): Array(physical(inner));
			case Iterator(inner) if (changes(inner)): Iterator(physical(inner));
			case Nullable(inner) if (changes(inner)): Nullable(physical(inner));
			case Function(args, result) if (changes(type)): Function([for (arg in args) physical(arg)], physical(result));
			default: type;
		};

	function functionChanges(fn:IrFunction):Bool {
		if (changes(fn.result)
			|| Lambda.exists(fn.arguments, a -> changes(a.type))
			|| Lambda.exists(fn.debugBindings, b -> changes(b.value.type)))
			return true;
		for (block in fn.blocks)
			for (located in block.instructions) {
				var output = IrOperands.output(located.value);
				if (output != null && changes(output.type))
					return true;
				switch located.value {
					case TypeValue(_, type):
						if (changes(type))
							return true;
					default:
				}
			}
		return false;
	}

	static function select(program:IrProgram):Map<String, Bool> {
		var closed = [for (e in program.enums) if (IrEnumTagStorage.eligible(e)) e.name => true],
			objects = [for (o in program.objects) o.name => o],
			enums = [for (e in program.enums) e.name => e],
			seen:Map<String, Bool> = [],
			functions = [for (fn in program.functions) fn.name => fn],
			natives = [for (n in program.natives) n.name => n];
		if (!closed.keys().hasNext())
			return closed;
		var interfaceUsers:Map<String, Array<String>> = [];
		var interfaces = [for (entry in program.interfaces) entry.name => entry];
		function register(name:String, objectName:String, visited:Map<String, Bool>):Void {
			if (visited.exists(name))
				return;
			visited.set(name, true);
			if (!interfaceUsers.exists(name))
				interfaceUsers.set(name, []);
			interfaceUsers.get(name).push(objectName);
			var entry = interfaces.get(name);
			if (entry != null)
				for (base in entry.bases)
					register(base, objectName, visited);
		}
		for (object in program.objects) {
			var seenBases:Map<String, Bool> = [], current = object;
			while (current != null && !seenBases.exists(current.name)) {
				seenBases.set(current.name, true);
				for (name in current.interfaces)
					register(name, object.name, []);
				current = current.base == null ? null : objects.get(current.base);
			}
		}
		function escape(type:IrType):Void {
			var key = Std.string(type);
			if (seen.exists(key))
				return;
			seen.set(key, true);
			switch type {
				case Enum(name), EnumTag(name):
					closed.remove(name);
					var e = enums.get(name);
					if (e != null)
						for (c in e.cases)
							for (t in c.params)
								escape(t);
				case Array(t), Iterator(t), Nullable(t):
					escape(t);
				case Function(args, result):
					for (t in args)
						escape(t);
					escape(result);
				case Obj(name):
					var o = objects.get(name);
					if (o != null) {
						if (o.base != null)
							escape(Obj(o.base));
						for (f in o.fields)
							escape(f.type);
						for (m in o.methods) {
							var fn = functions.get(m.functionName);
							if (fn != null) {
								for (a in fn.arguments)
									escape(a.type);
								escape(fn.result);
							}
						}
					}
				case Virtual(name):
					var users = interfaceUsers.get(name);
					if (users != null)
						for (name in users)
							escape(Obj(name));
				default:
			}
		}
		for (n in program.cNatives) {
			for (a in n.arguments)
				escape(a);
			escape(n.result);
		}
		for (n in program.natives)
			if (!StringTools.startsWith(n.name, "__array_")) {
				for (a in n.arguments)
					escape(a);
				escape(n.result);
			}
		for (fn in program.functions) {
			if (fn.retention == Expose || fn.name == program.entryPoint) {
				for (a in fn.arguments)
					escape(a.type);
				escape(fn.result);
			}
			var factoryDescriptors:Map<Int, Bool> = [],
				factoryCasts:Map<Int, Bool> = [],
				descriptorUses:Map<Int, Int> = [];
			for (block in fn.blocks)
				for (i in 0...block.instructions.length)
					switch block.instructions[i].value {
						case Call(raw, "__array_alloc_typed_ref", args) if (args.length == 2 && i + 2 < block.instructions.length):
							switch [block.instructions[i + 1].value, block.instructions[i + 2].value] {
								case [ToDyn(boxed,
									source), SafeCast(out, input)] if (source.id == raw.id && input.id == boxed.id): factoryCasts.set(out.id, true);
								default:
							}
						default:
					}
			function noteDescriptor(v:IrValue):Void
				descriptorUses.set(v.id, (descriptorUses.exists(v.id) ? descriptorUses.get(v.id) : 0) + 1);
			for (block in fn.blocks) {
				for (located in block.instructions) {
					for (v in IrOperands.inputs(located.value))
						noteDescriptor(v);
					switch located.value {
						case Phi(_, inputs):
							for (input in inputs)
								noteDescriptor(input.value);
						default:
					}
					switch located.value {
						case Call(_, "__array_alloc_typed_ref", args) if (args.length == 2):
							factoryDescriptors.set(args[1].id, true);
						default:
					}
				}
				if (block.terminator != null)
					switch block.terminator.value {
						case Return(v), Throw(v), Rethrow(v), Branch(v, _, _):
							noteDescriptor(v);
						case Jump(_):
					}
			}
			for (binding in fn.debugBindings)
				noteDescriptor(binding.value);
			for (block in fn.blocks) {
				for (located in block.instructions)
					switch located.value {
						case TypeValue(out, type):
							if (!factoryDescriptors.exists(out.id) || descriptorUses.get(out.id) != 1)
								escape(type);
						case ToDyn(_, input):
							escape(input.type);
						case SafeCast(out, input):
							if (!factoryCasts.exists(out.id)) {
								escape(out.type);
								escape(input.type);
							}
						case ToVirtual(_, input):
							escape(input.type);
						case Call(_, name, args):
							var native = natives.get(name);
							if (native != null) {
								if (StringTools.startsWith(name, "__array_") && name != "__array_alloc_typed_ref")
									for (a in args)
										escape(a.type);
								else if (!StringTools.startsWith(name, "__array_"))
									for (a in args)
										escape(a.type);
							} else {
								var target = functions.get(name);
								if (target != null)
									for (index in 0...args.length)
										if (index < target.arguments.length && switch target.arguments[index].type {
												case Dyn: true;
												default: false;
											})
											escape(args[index].type);
							}

						case CNativeCall(_, _, args):
							for (a in args)
								escape(a.type);
						case EnumIndex(_, input):
							escape(input.type);
						case CallClosure(_, closure, args):
							switch closure.type {
								case Dyn: for (a in args)
										escape(a.type);
								default:
							}
						case Phi(_, _), ConstVoid(_), ConstInt(_, _), ConstFloat(_, _), ConstString(_, _), StaticDataAddress(_, _), PointerOffset(_, _, _),
							MemoryLoad(_, _, _, _), MemoryStore(_, _, _), ConstBool(_, _), ConstNull(_), IntToFloat(_, _), IntToInt64(_, _), FloatToInt(_, _),
							FloatToFloat(_, _), BeginTry(_, _, _), EndTry(_, _), Catch(_), GlobalGet(_, _), GlobalSet(_, _), Add(_, _, _), Sub(_, _, _),
							Mul(_, _, _), Div(_, _, _), Mod(_, _, _), BitAnd(_, _, _), BitXor(_, _, _), BitOr(_, _, _), ShiftLeft(_, _, _),
							ShiftRight(_, _, _), UnsignedShiftRight(_, _, _), Less(_, _, _), LessEqual(_, _, _), Equal(_, _, _), StaticClosure(_, _),
							InstanceClosure(_, _, _), Upcast(_, _), MethodCall(_, _, _, _, _), NewObject(_, _), FieldGet(_, _, _), FieldSet(_, _, _),
							ArrayGet(_, _, _), ArraySet(_, _, _), ArraySize(_, _), IteratorNew(_, _), IteratorHasNext(_, _), IteratorNext(_, _),
							MakeEnum(_, _, _, _), EnumField(_, _, _, _):
					}
				if (block.terminator != null)
					switch block.terminator.value {
						case Throw(v), Rethrow(v):
							escape(v.type);
						default:
					}
			}
		}
		return closed;
	}

	function project(program:IrProgram):IrProgram {
		var result = new IrProgram(program.entryPoint);
		result.natives = [for (native in program.natives) projectNative(native)];
		result.cNatives = [for (native in program.cNatives) projectCNative(native)];
		result.functions = [for (fn in program.functions) projectFunction(fn)];
		// Only the selected tag carriers change; native placement and optional payload widths stay intact.
		result.objects = [
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
								type: physical(field.type),
								nativeLayout: field.nativeLayout,
								scalarStorage: field.scalarStorage,
								nullableScalarStorage: field.nullableScalarStorage
							}
					],
					methods: object.methods
				}
		];
		result.interfaces = [
			for (entry in program.interfaces)
				{
					name: entry.name,
					bases: entry.bases,
					methods: [
						for (method in entry.methods)
							{
								name: method.name,
								arguments: [for (argument in method.arguments) physical(argument)],
								result: physical(method.result)
							}
					]
				}
		];
		result.enums = [
			for (entry in program.enums)
				{
					name: entry.name,
					isRecursive: entry.isRecursive,
					inlineStorage: entry.inlineStorage,
					cases: [
						for (enumCase in entry.cases)
							{name: enumCase.name, params: [for (type in enumCase.params) physical(type)]}
					]
				}
		];
		result.staticFields = [
			for (field in program.staticFields)
				{name: field.name, type: physical(field.type)}
		];
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		return result;
	}

	function projectFunction(fn:IrFunction):IrFunction {
		if (!functionChanges(fn))
			return fn;
		var values:Map<Int, IrValue> = [];
		function use(value:IrValue):IrValue {
			var known = values.get(value.id);
			if (known != null)
				return known;
			var replacement = changes(value.type) ? new IrValue(value.id, value.name, physical(value.type)) : value;
			values.set(value.id, replacement);
			return replacement;
		}
		var arguments = [for (argument in fn.arguments) use(argument)];
		var blocks:Array<IrBlock> = [];
		for (block in fn.blocks) {
			var copy = new IrBlock(block.id);
			for (located in block.instructions) {
				var instruction = IrInliner.remap(located.value, use, id -> id);
				switch instruction {
					case MakeEnum(output, name, constructor, []) if (closed.exists(name)):
						instruction = ConstInt(output, constructor + 1);
					case ConstNull(output) if (switch output.type {
							case I32: true;
							default: false;
						}):
						instruction = ConstInt(output, 0);
					case TypeValue(output, type) if (changes(type)):
						instruction = TypeValue(output, physical(type));
					default:
				}
				if (!(switch located.value {
					case TypeValue(_, Enum(name)): closed.exists(name);
					default: false;
				}))
					copy.instructions.push(new Located(instruction, located.provenance));
			}
			var terminator = block.terminator;
			if (terminator != null)
				copy.terminator = new Located(switch terminator.value {
					case Return(value): Return(use(value));
					case Throw(value): Throw(use(value));
					case Rethrow(value): Rethrow(use(value));
					case Jump(target): Jump(target);
					case Branch(condition, whenTrue, whenFalse): Branch(use(condition), whenTrue, whenFalse);
				}, terminator.provenance);
			blocks.push(copy);
		}
		var bindings:Array<IrDebugBinding> = [
			for (binding in fn.debugBindings)
				{
					identity: binding.identity,
					name: binding.name,
					value: use(binding.value),
					path: binding.path,
					scopeStart: binding.scopeStart,
					scopeEnd: binding.scopeEnd
				}
		];
		return new IrFunction(fn.name, arguments, physical(fn.result), blocks, fn.kind, bindings, fn.inlineHint, fn.retention);
	}

	function projectNative(native:IrNative):IrNative
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			arguments: [for (argument in native.arguments) physical(argument)],
			result: physical(native.result),
			generatedFunctionDependencies: native.generatedFunctionDependencies
		};

	function projectCNative(native:IrCNative):IrCNative
		return {
			name: native.name,
			library: native.library,
			symbol: native.symbol,
			signature: native.signature,
			pointerOwnership: native.pointerOwnership,
			pointerRelease: native.pointerRelease,
			pointerLength: native.pointerLength,
			pointerNullable: native.pointerNullable,
			pointerSize: native.pointerSize,
			fixedResult: native.fixedResult,
			arguments: [for (argument in native.arguments) physical(argument)],
			argumentModes: native.argumentModes,
			result: physical(native.result)
		};
}

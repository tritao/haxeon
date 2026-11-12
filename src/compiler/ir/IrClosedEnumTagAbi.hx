package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;
import compiler.ir.SourceProvenance.Located;

/** Project an unobserved nominal tag to its integer ABI, including ordinary integer arrays. */
class IrClosedEnumTagAbi {
	final closed:Map<String, Bool>;

	function new(closed:Map<String, Bool>)
		this.closed = closed;

	public static function run(program:IrProgram, ?reflectableObjects:Array<String>):IrProgram {
		var closed = select(program, reflectableObjects);
		if (!closed.keys().hasNext())
			return program;
		var pass = new IrClosedEnumTagAbi(closed);
		return pass.project(program);
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

	static function select(program:IrProgram, ?reflectableObjects:Array<String>):Map<String, Bool> {
		var closed = [for (e in program.enums) if (IrEnumTagStorage.eligible(e)) e.name => true],
			functions = [for (fn in program.functions) fn.name => fn],
			natives = [for (n in program.natives) n.name => n];
		if (!closed.keys().hasNext())
			return closed;
		var roots:Array<IrType> = [];
		function escape(type:IrType):Void
			roots.push(type);

		for (n in program.cNatives) {
			for (a in n.arguments)
				IrEnumEscapeReach.addNativeRoot(roots, a);
			IrEnumEscapeReach.addNativeRoot(roots, n.result);
		}
		for (n in program.natives)
			if (!IrArrayRuntimeNatives.isStorage(n.name)) {
				for (a in n.arguments)
					IrEnumEscapeReach.addNativeRoot(roots, a);
				IrEnumEscapeReach.addNativeRoot(roots, n.result);
			}
		for (fn in program.functions) {
			switch fn.kind {
				case ClosureAdapter(source, target):
					escape(source);
					escape(target);
				case ClosureCast(target), ClosureVarargs(target):
					escape(target);
				case EnumTagAdapter(type, _):
					escape(type);
				default:
			}
			if (fn.retention == Expose || fn.name == program.entryPoint) {
				for (a in fn.arguments)
					escape(a.type);
				escape(fn.result);
			}

			for (block in fn.blocks) {
				for (located in block.instructions)
					switch located.value {
						case Intrinsic(_, operation, _):
							switch operation {
								case EnumDynamicBox(type), EnumDynamicView(type), EnumTagBox(type), EnumTagUnbox(type), InlineEnumBox(type), InlineEnumUnbox(type): escape(type);
							}
						case TypeValue(out, type):
							escape(type);
						case ToDyn(_, input):
							escape(input.type);
						case SafeCast(out, input):
							escape(out.type);
							escape(input.type);
						case ToVirtual(_, input):
							escape(input.type);
						case Call(_, name, args):
							var native = natives.get(name);
							if (native != null) {
								for (argument in args)
									escape(argument.type);
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
							InstanceClosure(_, _, _), Upcast(_, _), ClassId(_, _), MethodCall(_, _, _, _, _), NewObject(_, _), FieldGet(_, _, _), FieldSet(_, _, _),
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
		if (ObjectReflection.usedByProgram(program)) {
			if (reflectableObjects != null)
				for (name in reflectableObjects)
					escape(Obj(name));
			for (object in program.objects)
				if (object.isValue
					|| compiler.semantic.SemanticSignature.isAnonymousName(object.name)
					|| StringTools.startsWith(object.name, IrValueInterfaceBoxes.BOX_PREFIX))
					escape(Obj(object.name));
		}
		for (name in new IrEnumEscapeReach(program).collect(roots, _ -> false).keys())
			closed.remove(name);

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
				copy.instructions.push(new Located(instruction, located.provenance));
			}
			var terminator = block.terminator;
			if (terminator != null)
				copy.terminator = new Located(switch terminator.value {
					case Unreachable: Unreachable;
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

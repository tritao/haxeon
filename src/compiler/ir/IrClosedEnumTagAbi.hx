package compiler.ir;

import compiler.ir.Ir;
import compiler.ir.IrFunction;

/**
 * Project an unobserved nominal tag to its integer ABI, including ordinary integer arrays. On IR bodies
 * (docs/design/IR_CORE_COLUMNS.md, migration), in release builds. A function's types change in place (`setValueType`,
 * `setResult`).
 */
class IrClosedEnumTagAbi {
	final closed:Map<String, Bool>;
	final types:IrTypeIds;
	final builder:IrBodyBuilder;
	final retained:Bool;

	/** By type id: 1 when the type changes, 0 when not, -1 when not yet known. */
	final changing:Array<Int> = [];

	function new(closed:Map<String, Bool>, types:IrTypeIds, builder:IrBodyBuilder, retained:Bool) {
		this.closed = closed;
		this.types = types;
		this.builder = builder;
		this.retained = retained;
	}

	/**
	 * `program` with the closed tags projected, read from the functions' bodies, made with `types` (those of the program's bodies
	 * when not given). A function that changes becomes its edited body: a frozen copy when a session keeps the stage's functions
	 * (`retained`), else the body edited in place.
	 */
	public static function run(program:IrProgram, ?reflectableObjects:Array<String>, ?types:IrTypeIds,
			?scratch:IrPassScratch, retained = true):IrProgram {
		if (types == null)
			types = IrTypeIds.ofFunctions(program.functions);
		var builder = scratch == null ? new IrBodyBuilder(types) : scratch.bodyBuilder;
		for (fn in program.functions)
			fn.bodyIn(types, builder, retained);
		if (!retained)
			for (fn in program.functions)
				fn.releaseDecoded();
		var closed = select(program, types, builder, reflectableObjects);
		if (!closed.keys().hasNext())
			return program;
		var pass = new IrClosedEnumTagAbi(closed, types, builder, retained);
		return pass.project(program);
	}

	function changes(type:IrType):Bool
		return switch type {
			case EnumTag(name): closed.exists(name);
			case Array(inner), Iterator(inner), Nullable(inner): changes(inner);
			case Function(args, result): Lambda.exists(args, changes) || changes(result);
			default: false;
		};

	function changesId(id:Int):Bool {
		var known = id < changing.length ? changing[id] : -1;
		if (known < 0) {
			known = changes(types.type(id)) ? 1 : 0;
			while (changing.length <= id)
				changing.push(-1);
			changing[id] = known;
		}
		return known == 1;
	}

	function physical(type:IrType):IrType
		return switch type {
			case EnumTag(name) if (closed.exists(name)): I32;
			case Array(inner) if (changes(inner)): Array(physical(inner));
			case Iterator(inner) if (changes(inner)): Iterator(physical(inner));
			case Nullable(inner) if (changes(inner)): Nullable(physical(inner));
			case Function(args, result) if (changes(type)): Function([for (arg in args) physical(arg)],
				physical(result));
			default: type;
		};

	function functionChanges(body:IrBody):Bool {
		if (changesId(body.result))
			return true;
		for (index in 0...body.argumentCount())
			if (changesId(body.valueTypeId(body.argument(index))))
				return true;
		for (index in 0...body.bindingCount())
			if (changesId(body.valueTypeId(body.bindingValue(index))))
				return true;
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				var output = body.output(row);
				if (output.exists() && changesId(body.valueTypeId(output)))
					return true;
				if (body.opcode(row) == IrOpcode.TypeValue && changesId(body.aux(row)))
					return true;
				row = body.nextRow(row);
			}
		}
		return false;
	}

	static function select(program:IrProgram, types:IrTypeIds, builder:IrBodyBuilder,
			?reflectableObjects:Array<String>):Map<String, Bool> {
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

			var body = fn.bodyIn(types, builder);
			for (block in 0...body.blockCount()) {
				var row = body.firstRow(block);
				while (row >= 0) {
					switch body.opcode(row) {
						case IrOpcode.EnumDynamicBox | IrOpcode.EnumDynamicView | IrOpcode.EnumTagBox
							| IrOpcode.EnumTagUnbox
							| IrOpcode.InlineEnumBox | IrOpcode.InlineEnumUnbox | IrOpcode.TypeValue:
							escape(body.typeOperand(row));
						case IrOpcode.ToDyn | IrOpcode.ToVirtual | IrOpcode.EnumIndex | IrOpcode.Throw
							| IrOpcode.Rethrow:
							escape(body.valueType(body.operand(row, 0)));
						case IrOpcode.SafeCast:
							escape(body.valueType(body.output(row)));
							escape(body.valueType(body.operand(row, 0)));
						case IrOpcode.Call:
							var name = body.symbol(row).name;
							if (natives.exists(name)) {
								for (index in 0...body.operandCount(row))
									escape(body.valueType(body.operand(row, index)));
							} else {
								var target = functions.get(name);
								if (target != null)
									for (index in 0...body.operandCount(row))
										if (index < target.arguments.length && switch target.arguments[index].type {
											case Dyn: true;
											default: false;
										})
											escape(body.valueType(body.operand(row, index)));
							}
						case IrOpcode.CNativeCall:
							for (index in 0...body.operandCount(row))
								escape(body.valueType(body.operand(row, index)));
						case IrOpcode.CallClosure:
							switch body.valueType(body.operand(row, 0)) {
								case Dyn: for (index in 1...body.operandCount(row))
									escape(body.valueType(body.operand(row, index)));
								default:
							}
						default:
					}
					row = body.nextRow(row);
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
		result.functions = [for (fn in program.functions) projectFunction(fn, fn.bodyIn(types, builder, retained))];
		// Only the selected tag carriers change; native placement and optional payload widths stay intact.
		result.objects = [for (object in program.objects)
			{
				name:object.name,
					isValue:object.isValue,
					nativeLayout:object.nativeLayout,
					base:object.base,
					interfaces:object.interfaces,
					fields:[for (field in object.fields)
					{
						name:field.name,
							type:physical(field.type),
							nativeLayout:field.nativeLayout,
							scalarStorage:field.scalarStorage,
							nullableScalarStorage:field.nullableScalarStorage
					}],
						methods:object.methods
			}];
		result.interfaces = [for (entry in program.interfaces)
			{
				name:entry.name,
					bases:entry.bases,
					methods:[for (method in entry.methods)
					{
						name:method.name,
							arguments:[for (argument in method.arguments) physical(argument)],
							result:physical(method.result)
					}]
			}];
		result.enums = [for (entry in program.enums)
			{
				name:entry.name,
					isRecursive:entry.isRecursive,
					inlineStorage:entry.inlineStorage,
					cases:[for (enumCase in entry.cases)
					{
						name:enumCase.name, params:[for (type in enumCase.params) physical(type)]
					}]
			}];
		result.staticFields = [for (field in program.staticFields)
			{
				name:field.name, type:physical(field.type)
			}];
		result.positionalFingerprints = program.positionalFingerprints;
		result.parameterDefaults = program.parameterDefaults;
		result.positionalPlaces = program.positionalPlaces;
		result.positionalSources = program.positionalSources;
		return result;
	}

	function projectFunction(fn:IrFunction, source:IrBody):IrFunction {
		if (!functionChanges(source))
			return fn;
		var body = source.forEditing(builder);
		for (value in 0...body.valueLimit()) {
			var id = IrValueId.of(value), type = body.valueTypeId(id);
			if (type >= 0 && changesId(type))
				body.setValueType(id, body.typeId(physical(types.type(type))));
		}
		var i32 = body.typeId(I32);
		for (block in 0...body.blockCount()) {
			var row = body.firstRow(block);
			while (row >= 0) {
				switch body.opcode(row) {
					case IrOpcode.MakeEnum if (body.operandCount(row) == 0 && closed.exists(body.symbol(row).name)):
						body.setOperation(row, IrOpcode.ConstInt, body.auxInt(row, 1) + 1);
					case IrOpcode.ConstNull if (body.valueTypeId(body.output(row)) == i32):
						body.setOperation(row, IrOpcode.ConstInt, 0);
					case IrOpcode.TypeValue if (changesId(body.aux(row))):
						body.setAux(row, body.typeId(physical(body.typeOperand(row))));
					default:
				}
				row = body.nextRow(row);
			}
		}
		body.setResult(body.typeId(physical(types.type(body.result))));
		return retained ? IrFunction.ofBody(body.freeze(true, builder)) : IrFunction.ofOwnedBody(body);
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

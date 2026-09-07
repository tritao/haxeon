package compiler.ir;

import compiler.runtime.RuntimeType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedCaptureSource;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrObjectMethod;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrStaticField;

/** Builds complete IR programs and selects their required runtime surface. */
class IrProgramAssembler {
	public static function generate(typed:TypedProgram):IrProgram {
		return assemble([for (fn in typed.functions) IrGenerator.generateFunction(fn)], nativesFrom(typed), objectsFrom(typed), interfacesFrom(typed),
			enumsFrom(typed), staticFieldsFrom(typed), staticInitializerFrom(typed));
	}

	public static function nativesFrom(typed:TypedProgram):Array<IrNative>
		return [
			for (native in typed.natives)
				{
					name: native.name,
					library: native.library,
					symbol: native.symbol,
					arguments: [for (argument in native.arguments) IrGenerator.lowerType(argument)],
					result: IrGenerator.lowerType(native.result)
				}
		];

	/** Build the module boot function from static field initializers. */
	public static function staticInitializerFrom(typed:TypedProgram, ?classOrder:Array<String>):Null<IrFunction> {
		var statements:Array<TypedStatement> = [],
			spans:Array<compiler.Source.SourceSpan> = [];
		var classes = orderedClasses(typed.classes, classOrder);
		for (classDecl in classes)
			for (field in classDecl.fields) {
				var initializer = field.initializer;
				if (field.isStatic && initializer != null) {
					if (spans.length == 0)
						spans.push(field.span);
					statements.push(TStaticFieldAssign(classDecl.name, field.name, initializer, field.span));
				}
			}
		if (statements.length == 0)
			return null;
		return IrGenerator.generateFunction({
			name: "__init",
			owner: null,
			isStatic: true,
			isConstructor: false,
			arguments: [],
			result: TVoid,
			statements: statements,
			cells: [],
			cellCaptures: [],
			span: spans[0]
		});
	}

	static function orderedClasses(classes:Array<compiler.types.TypedAst.TypedClass>, ?order:Array<String>):Array<compiler.types.TypedAst.TypedClass> {
		if (order == null)
			return classes;
		var byName:Map<String, compiler.types.TypedAst.TypedClass> = [];
		for (classDecl in classes)
			byName.set(classDecl.name, classDecl);
		var result:Array<compiler.types.TypedAst.TypedClass> = [],
			seen:Map<String, Bool> = [];
		for (name in order) {
			if (byName.exists(name)) {
				var classDecl = byName.get(name);
				result.push(classDecl);
				seen.set(name, true);
			}
		}
		for (classDecl in classes)
			if (!seen.exists(classDecl.name))
				result.push(classDecl);
		return result;
	}

	public static function enumsFrom(typed:TypedProgram):Array<IrEnum>
		return [
			for (enumDecl in typed.enums)
				{
					name: enumDecl.name,
					cases: [
						for (caseDecl in enumDecl.cases)
							{name: caseDecl.name, params: [for (param in caseDecl.params) IrGenerator.lowerType(param)]}
					]
				}
		];

	public static function interfacesFrom(typed:TypedProgram):Array<IrInterface> {
		return [
			for (interfaceDecl in typed.interfaces)
				{
					name: interfaceDecl.name,
					bases: interfaceDecl.bases,
					methods: [
						for (method in interfaceDecl.methods)
							{
								name: method.name,
								arguments: [for (argument in method.arguments) IrGenerator.lowerType(argument)],
								result: IrGenerator.lowerType(method.result)
							}
					]
				}
		];
	}

	public static function objectsFrom(typed:TypedProgram):Array<IrObject> {
		var objects:Array<IrObject> = [];
		for (classDecl in typed.classes) {
			var fields:Array<IrObjectField> = [];
			for (field in classDecl.fields)
				if (!field.isStatic && hasPhysicalStorage(field))
					fields.push({name: field.name, type: IrGenerator.lowerType(field.type)});
			var methods:Array<IrObjectMethod> = [];
			for (methodDecl in classDecl.methods)
				if (!methodDecl.isStatic && !methodDecl.isConstructor) {
					var functionName = methodDecl.name;
					var separator = lastSeparator(functionName);
					methods.push({name: functionName.substring(separator + 1, functionName.length), functionName: functionName});
				}
			objects.push({
				name: classDecl.name,
				isValue: classDecl.isValue,
				base: classDecl.base,
				interfaces: classDecl.interfaces,
				fields: fields,
				methods: methods
			});
		}
		for (cell in typed.closurePlan.storage)
			objects.push({
				name: cell.name,
				isValue: false,
				base: null,
				interfaces: [],
				fields: [{name: "value", type: IrGenerator.lowerType(cell.valueType)}],
				methods: []
			});
		for (environment in typed.closurePlan.environments)
			objects.push({
				name: environment.name,
				isValue: false,
				base: null,
				interfaces: [],
				fields: [
					for (capture in environment.captures)
						{
							name: capture.field,
							type: IrGenerator.lowerType(switch capture.source {
								case CaptureCellLocal(_, cellClass), CaptureCellEnvironmentField(_, cellClass):
									TInstance(NominalKind.Class, cellClass, []);
								default: capture.type;
							})
						}
				],
				methods: []
			});
		for (anonymous in typed.anonymousTypes)
			objects.push({
				name: anonymous.name,
				isValue: false,
				base: null,
				interfaces: [],
				fields: [
					for (field in anonymous.fields)
						{name: field.name, type: IrGenerator.lowerType(field.type)}
				],
				methods: []
			});
		return objects;
	}

	static function hasPhysicalStorage(field:compiler.types.TypedAst.TypedField):Bool
		return hasDirectFieldAccess(field.readAccess) || hasDirectFieldAccess(field.writeAccess);

	static function hasDirectFieldAccess(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
		return switch access {
			case GetAccess, SetAccess, NeverAccess: false;
			default: true;
		};

	static function lastSeparator(value:String):Int {
		return lastSeparatorCode(value, 46);
	}

	static function lastSeparatorCode(value:String, separator:Int):Int {
		var index = value.length - 1;
		while (index >= 0 && value.charCodeAt(index) != separator)
			index--;
		return index;
	}

	public static function staticFieldsFrom(typed:TypedProgram):Array<IrStaticField> {
		var result = [];
		for (classDecl in typed.classes)
			for (field in classDecl.fields) {
				if (field.isStatic)
					result.push({name: classDecl.name + "." + field.name, type: IrGenerator.lowerType(field.type)});
			}
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		return result;
	}

	public static function assemble(functions:Array<IrFunction>, ?natives:Array<IrNative>, ?objects:Array<IrObject>, ?interfaces:Array<IrInterface>,
			?enums:Array<IrEnum>, ?staticFields:Array<IrStaticField>, ?staticInitializer:IrFunction, ?entryPoint:String):IrProgram {
		var program = new IrProgram("__entry");
		var needsArrayRuntime = false,
			needsStringRuntime = false,
			needsExceptionRuntime = false,
			mapRuntimeNames:Map<String, Bool> = [];
		for (fn in functions)
			for (block in fn.blocks)
				for (instruction in block.instructions)
					switch instruction.value {
						case Call(_, name, _):
							if (name == "__exception_matches")
								needsExceptionRuntime = true;
							if (StringTools.startsWith(name, "__array_"))
								needsArrayRuntime = true;
							if (name == "__string_concat" || name == "__string_length" || name == "__string_equal" || name == "__string_index_of"
								|| name == "__string_char_at" || name == "__string_char_code_at" || name == "__string_from_char_code"
								|| name == "__string_substring")
								needsStringRuntime = true;
							if (StringTools.startsWith(name, "__map_")) {
								var operationStart = lastSeparatorCode(name, 95);
								if (operationStart > 0)
									mapRuntimeNames.set(name.substring(2, operationStart), true);
							}
						default:
					}
		program.objects = objects == null ? [] : objects;
		program.interfaces = interfaces == null ? [] : interfaces;
		program.enums = enums == null ? [] : enums;
		program.staticFields = staticFields == null ? [] : staticFields;
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [I32],
			result: Void
		});
		if (needsExceptionRuntime)
			program.natives.push({
				name: "__exception_matches",
				library: "realtime_runtime",
				symbol: "__exception_matches",
				arguments: [Dyn, TypeRef],
				result: Bool
			});
		if (needsArrayRuntime) {
			program.natives.push({
				name: "__array_alloc_i32",
				library: "realtime_runtime",
				symbol: "__array_alloc_i32",
				arguments: [I32],
				result: Array(I32)
			});
			program.natives.push({
				name: "__array_alloc_f64",
				library: "realtime_runtime",
				symbol: "__array_alloc_f64",
				arguments: [I32],
				result: Array(F64)
			});
			program.natives.push({
				name: "__array_alloc_bytes",
				library: "realtime_runtime",
				symbol: "__array_alloc_bytes",
				arguments: [I32],
				result: Array(Bytes)
			});
			program.natives.push({
				name: "__array_alloc_bool",
				library: "realtime_runtime",
				symbol: "__array_alloc_bool",
				arguments: [I32],
				result: Array(Bool)
			});
			program.natives.push({
				name: "__array_alloc_ref",
				library: "realtime_runtime",
				symbol: "__array_alloc_ref",
				arguments: [I32],
				result: Array(Dyn)
			});
			var arrayKinds:Array<{name:String, type:IrType}> = [
				{name: "i32", type: I32},
				{name: "f64", type: F64},
				{name: "bytes", type: Bytes},
				{name: "bool", type: Bool},
				{name: "ref", type: Dyn}
			];
			for (entry in arrayKinds) {
				var arrayType:IrType = Array(entry.type);
				program.natives.push({
					name: '__array_copy_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_copy_${entry.name}',
					arguments: [arrayType],
					result: arrayType
				});
				if (entry.name == "bytes")
					program.natives.push({
						name: "__array_join_bytes",
						library: "realtime_runtime",
						symbol: "__array_join_bytes",
						arguments: [arrayType, Bytes],
						result: Bytes
					});
				program.natives.push({
					name: '__array_concat_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_concat_${entry.name}',
					arguments: [arrayType, arrayType],
					result: arrayType
				});
				program.natives.push({
					name: '__array_slice_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_slice_${entry.name}',
					arguments: [arrayType, I32, I32],
					result: arrayType
				});
				if (entry.name != "ref")
					program.natives.push({
						name: '__array_index_of_${entry.name}',
						library: "realtime_runtime",
						symbol: '__array_index_of_${entry.name}',
						arguments: [arrayType, entry.type],
						result: I32
					});
				program.natives.push({
					name: '__array_push_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_push_${entry.name}',
					arguments: [arrayType, entry.type],
					result: I32
				});
				program.natives.push({
					name: '__array_unshift_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_unshift_${entry.name}',
					arguments: [arrayType, entry.type],
					result: I32
				});
				program.natives.push({
					name: '__array_pop_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_pop_${entry.name}',
					arguments: [arrayType],
					result: entry.type
				});
				program.natives.push({
					name: '__array_resize_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_resize_${entry.name}',
					arguments: [arrayType, I32],
					result: Void
				});
				program.natives.push({
					name: '__array_remove_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_remove_${entry.name}',
					arguments: [arrayType, entry.type],
					result: Bool
				});
			}
		}
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_concat",
				library: "realtime_runtime",
				symbol: "__string_concat",
				arguments: [Bytes, Bytes],
				result: Bytes
			});
		var mapNames = [for (name in mapRuntimeNames.keys()) name];
		mapNames.sort(Reflect.compare);
		for (mapName in mapNames) {
			var valueType = RuntimeType.mapValueType(mapName);
			var isReferenceMap = StringTools.endsWith(mapName, "_ref");
			if (valueType == null && !isReferenceMap)
				throw 'Unknown compiler map ABI "$mapName"';
			var keyType = RuntimeType.mapKeyType(mapName);
			if (keyType == null)
				throw 'Unknown compiler map key ABI "$mapName"';
			var mapType:IrType = Abstract(mapName);
			var keyIrType = IrGenerator.lowerType(keyType);
			var valueIrType:IrType = Dyn;
			if (!isReferenceMap) {
				if (valueType == null)
					throw 'Unknown compiler map ABI "$mapName"';
				valueIrType = IrGenerator.lowerType(valueType);
			}
			program.natives.push({
				name: '__${mapName}_alloc',
				library: "realtime_runtime",
				symbol: '__${mapName}_alloc',
				arguments: [],
				result: mapType
			});
			program.natives.push({
				name: '__${mapName}_set',
				library: "realtime_runtime",
				symbol: '__${mapName}_set',
				arguments: [mapType, keyIrType, valueIrType],
				result: Void
			});
			program.natives.push({
				name: '__${mapName}_exists',
				library: "realtime_runtime",
				symbol: '__${mapName}_exists',
				arguments: [mapType, keyIrType],
				result: Bool
			});
			program.natives.push({
				name: '__${mapName}_get',
				library: "realtime_runtime",
				symbol: '__${mapName}_get',
				arguments: [mapType, keyIrType],
				result: valueIrType
			});
			program.natives.push({
				name: '__${mapName}_keys',
				library: "realtime_runtime",
				symbol: '__${mapName}_keys',
				arguments: [mapType],
				result: Array(keyIrType)
			});
			program.natives.push({
				name: '__${mapName}_values',
				library: "realtime_runtime",
				symbol: '__${mapName}_values',
				arguments: [mapType],
				result: Array(valueIrType)
			});
			program.natives.push({
				name: '__${mapName}_remove',
				library: "realtime_runtime",
				symbol: '__${mapName}_remove',
				arguments: [mapType, keyIrType],
				result: Bool
			});
			program.natives.push({
				name: '__${mapName}_clear',
				library: "realtime_runtime",
				symbol: '__${mapName}_clear',
				arguments: [mapType],
				result: Void
			});
			program.natives.push({
				name: '__${mapName}_size',
				library: "realtime_runtime",
				symbol: '__${mapName}_size',
				arguments: [mapType],
				result: I32
			});
		}
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_length",
				library: "realtime_runtime",
				symbol: "__string_length",
				arguments: [Bytes],
				result: I32
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_equal",
				library: "realtime_runtime",
				symbol: "__string_equal",
				arguments: [Bytes, Bytes],
				result: Bool
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_index_of",
				library: "realtime_runtime",
				symbol: "__string_index_of",
				arguments: [Bytes, Bytes],
				result: I32
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_substring",
				library: "realtime_runtime",
				symbol: "__string_substring",
				arguments: [Bytes, I32, I32],
				result: Bytes
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_from_char_code",
				library: "realtime_runtime",
				symbol: "__string_from_char_code",
				arguments: [I32],
				result: Bytes
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_char_at",
				library: "realtime_runtime",
				symbol: "__string_char_at",
				arguments: [Bytes, I32],
				result: Bytes
			});
		if (needsStringRuntime)
			program.natives.push({
				name: "__string_char_code_at",
				library: "realtime_runtime",
				symbol: "__string_char_code_at",
				arguments: [Bytes, I32],
				result: I32
			});
		if (natives != null)
			for (native in natives)
				program.natives.push(native);
		var allFunctions:Array<IrFunction> = [];
		if (staticInitializer != null)
			allFunctions.push(staticInitializer);
		for (fn in functions)
			allFunctions.push(fn);
		for (fn in allFunctions)
			program.functions.push(fn);
		var mainFunction:Null<IrFunction> = null;
		for (fn in allFunctions)
			if (entryPoint == null ? (fn.name == "main" || fn.name == "Main.main") : fn.name == entryPoint)
				mainFunction = fn;
		if (mainFunction == null)
			throw 'IR program has no executable entry point "${entryPoint == null ? "main" : entryPoint}"';
		var entry = new IrBuilder();
		if (staticInitializer != null)
			entry.call("__init", [], Void);
		var result = entry.call(mainFunction.name, [], mainFunction.result);
		if (mainFunction.result == I32)
			result = entry.call("__exit", [result], Void);
		entry.returnValue(result);
		program.functions.push(new IrFunction("__entry", [], Void, entry.blocks));
		return program;
	}
}

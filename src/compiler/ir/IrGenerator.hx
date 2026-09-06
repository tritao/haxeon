package compiler.ir;

import compiler.types.Type.CompilerType;
import compiler.types.RuntimeType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.ir.Cfg.CfgFunction;
import compiler.ir.Cfg.CfgBlock;
import compiler.ir.Cfg.CfgValue;
import compiler.ir.Cfg.CfgArgument;
import compiler.ir.SsaBuilder;
import compiler.ir.IrBuilder;
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrObjectField;
import compiler.ir.Ir.IrObjectMethod;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrStaticField;

/** Active structured-loop targets and the trap depth at their declaration. */
private typedef LoopContext = {
	final breakBlock:CfgBlock;
	final continueBlock:CfgBlock;
	final breakFlag:String;
	final trapDepth:Int;
}

/** Resolved key and value types of a map operation being lowered. */
private typedef MapTypes = {final key:CompilerType; final value:CompilerType;}

/** Lowers typed syntax to a mutable-local CFG; SsaBuilder owns all SSA policy. */
class IrGenerator {
	public static function generate(typed:TypedProgram):IrProgram {
		return assemble([for (fn in typed.functions) generateFunction(fn)], null, objectsFrom(typed), interfacesFrom(typed), enumsFrom(typed),
			staticFieldsFrom(typed), staticInitializerFrom(typed));
	}

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
		return generateFunction({
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
							{name: caseDecl.name, params: [for (param in caseDecl.params) lowerType(param)]}
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
							{name: method.name, arguments: [for (argument in method.arguments) lowerType(argument)], result: lowerType(method.result)}
					]
				}
		];
	}

	public static function objectsFrom(typed:TypedProgram):Array<IrObject> {
		var objects:Array<IrObject> = [];
		for (classDecl in typed.classes) {
			var fields:Array<IrObjectField> = [];
			for (field in classDecl.fields)
				if (!field.isStatic)
					fields.push({name: field.name, type: lowerType(field.type)});
			var methods:Array<IrObjectMethod> = [];
			for (methodDecl in classDecl.methods)
				if (!methodDecl.isStatic && !methodDecl.isConstructor) {
					var functionName = methodDecl.name;
					var separator = IrGenerator.lastSeparator(functionName);
					methods.push({name: functionName.substring(separator + 1, functionName.length), functionName: functionName});
				}
			objects.push({
				name: classDecl.name,
				base: classDecl.base,
				interfaces: classDecl.interfaces,
				fields: fields,
				methods: methods
			});
		}
		for (cell in typed.cells)
			objects.push({
				name: cell.name,
				base: null,
				interfaces: [],
				fields: [{name: "value", type: lowerType(cell.valueType)}],
				methods: []
			});
		for (environment in typed.captureEnvironments)
			objects.push({
				name: environment.name,
				base: null,
				interfaces: [],
				fields: [
					for (field in environment.fields)
						{name: field.name, type: lowerType(field.type)}
				],
				methods: []
			});
		for (anonymous in typed.anonymousTypes)
			objects.push({
				name: anonymous.name,
				base: null,
				interfaces: [],
				fields: [for (field in anonymous.fields) {name: field.name, type: lowerType(field.type)}],
				methods: []
			});
		return objects;
	}

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
					result.push({name: classDecl.name + "." + field.name, type: lowerType(field.type)});
			}
		result.sort(function(a, b) return Reflect.compare(a.name, b.name));
		return result;
	}

	public static function generateFunction(fn:TypedFunction):IrFunction {
		var cfg = generateCfg(fn);
		try {
			return SsaBuilder.build(cfg);
		} catch (error:String) {
			throw 'CFG generation failed for ${fn.name}: $error';
		}
	}

	public static function generateCfg(fn:TypedFunction):CfgFunction {
		var builder = new CfgBuilder(), localTypes:Map<String, IrType> = [];
		for (name => cellClass in fn.cells) {
			var cellType:IrType = Obj(cellClass);
			localTypes.set('__cell:$name', cellType);
			localTypes.set('$' + 'cell:$name', cellType);
		}
		for (name => cellClass in fn.cellCaptures) {
			var cellType:IrType = Obj(cellClass);
			localTypes.set('__capturecell:$name', cellType);
		}
		var arguments:Array<CfgArgument> = [
			for (argument in implicitArguments(fn)) {
				localTypes.set(argument.name, argument.type);
				{name: argument.name, type: argument.type};
			}
		];
		for (argument in fn.arguments) {
			var type = lowerType(argument.type);
			localTypes.set(argument.name, type);
			arguments.push({name: argument.name, type: type});
		}
		for (name => cellClass in fn.cells)
			for (argument in arguments)
				if (argument.name == name) {
					var cell = builder.newObject(cellClass);
					builder.fieldSet(cell, "value", builder.load(name, localTypes.get(name)));
					builder.store('$' + 'cell:$name', cell);
				}
		lowerStatements(fn.statements, builder, localTypes, []);
		if (!builder.isTerminated()) {
			if (lowerType(fn.result) == Void)
				builder.returnVoid();
			else
				throw 'Function ${fn.name} does not return on every path';
		}
		return new CfgFunction(fn.name, arguments, lowerType(fn.result), builder.blocks, localTypes);
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
					switch instruction {
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
								var operationStart = IrGenerator.lastSeparatorCode(name, 95);
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
					result: arrayType
				});
				program.natives.push({
					name: '__array_pop_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_pop_${entry.name}',
					arguments: [arrayType],
					result: entry.type
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
			var keyIrType = lowerType(keyType);
			var valueIrType:IrType = Dyn;
			if (!isReferenceMap) {
				if (valueType == null)
					throw 'Unknown compiler map ABI "$mapName"';
				valueIrType = lowerType(valueType);
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

	static function lowerStatements(statements:Array<TypedStatement>, builder:CfgBuilder, localTypes:Map<String, IrType>, loops:Array<LoopContext>):Void {
		for (statement in statements) {
			if (builder.isTerminated())
				break;
			switch statement {
				case TDeclare(name, type, _):
					localTypes.set(name, lowerType(type));
				case TVar(name, initializer, _):
					var value = lowerExpression(initializer, builder, localTypes);
					var cellKey = '__cell:$name';
					if (!localTypes.exists(cellKey)) {
						localTypes.set(name, lowerType(initializer.type));
						builder.store(name, value);
					} else {
						var cellType = localTypes.get(cellKey);
						var cellClass = switch cellType {
							case Obj(name): name;
							default: throw 'Invalid capture cell type for "$name"';
						};
						var cell = builder.newObject(cellClass);
						builder.fieldSet(cell, "value", value);
						builder.store('$' + 'cell:$name', cell);
					}
				case TAssign(name, value, _):
					builder.store(name, lowerExpression(value, builder, localTypes));
				case TCellAssign(name, cellClass, value, _):
					var loweredValue = lowerExpression(value, builder, localTypes);
					builder.fieldSet(builder.load('$' + 'cell:$name', Obj(cellClass)), "value", loweredValue);
				case TCellCapturedAssign(name, cellClass, value, _):
					var owner = requireLocalType(localTypes, "this", 'Captured assignment "$name" has no environment');
					var loweredValue = lowerExpression(value, builder, localTypes),
						cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass));
					builder.fieldSet(cell, "value", loweredValue);
				case TFieldAssign(object, name, value, _):
					var operands = lowerOperands([object, value], builder, localTypes);
					builder.fieldSet(operands[0], name, operands[1]);
				case TStaticFieldAssign(name, field, value, _):
					builder.globalSet(name + "." + field, lowerExpression(value, builder, localTypes));
				case TIndexAssign(array, index, value, _):
					var operands = lowerOperands([array, index, value], builder, localTypes);
					builder.arraySet(operands[0], operands[1], operands[2]);
				case TMapAssign(map, key, value, _):
					var mapType = switch map.type {
						case TMap(keyType, valueType): {key: keyType, value: valueType};
						default: throw "Map assignment requires a map value";
					};
					var operands = lowerOperands([map, key, value], builder, localTypes);
					lowerMapSet(builder, operands[0], operands[1], operands[2], mapType.key, mapType.value);
				case TReturn(expression, _):
					var returnValue = lowerExpression(expression, builder, localTypes);
					builder.closeTrapsForExit();
					builder.returnValue(returnValue);
				case TReturnVoid(_):
					builder.closeTrapsForExit();
					builder.returnVoid();
				case TThrow(expression, _):
					builder.throwValue(builder.toDyn(lowerExpression(expression, builder, localTypes)));
				case TTry(tryBranch, catches, _):
					var catchBlock = builder.createBlock(),
						afterBlock = builder.createBlock();
					builder.beginTry(catchBlock, afterBlock);
					lowerStatements(tryBranch, builder, localTypes, loops);
					var tryActive = !builder.isTerminated();
					if (!tryActive)
						builder.discardTry();
					else {
						builder.endTry();
						builder.jump(afterBlock);
					}
					builder.select(catchBlock);
					var exception = builder.catchValue(),
						exceptionLocal = '$' + 'exception:${catchBlock}',
						catchActive = false,
						hasDynamicCatch = false;
					var exceptionType:IrType = Dyn;
					localTypes.set(exceptionLocal, exceptionType);
					builder.store(exceptionLocal, exception);
					for (i in 0...catches.length) {
						var catchClause = catches[i],
							catchIrType = lowerType(catchClause.type),
							nextDispatch:Null<CfgBlock> = null;
						if (catchClause.type != TDynamic) {
							var handlerBlock = builder.createBlock(),
								mismatchBlock = builder.createBlock();
							nextDispatch = mismatchBlock;
							builder.branch(builder.call("__exception_matches", [builder.load(exceptionLocal, Dyn), builder.typeValue(catchIrType)], Bool),
								handlerBlock, mismatchBlock);
							builder.select(handlerBlock);
						} else
							hasDynamicCatch = true;
						localTypes.set(catchClause.name, catchIrType);
						var caught = builder.load(exceptionLocal, Dyn);
						builder.store(catchClause.name, catchClause.type == TDynamic ? caught : builder.safeCast(caught, catchIrType));
						lowerStatements(catchClause.statements, builder, localTypes, loops);
						if (!builder.isTerminated()) {
							catchActive = true;
							builder.jump(afterBlock);
						}
						if (nextDispatch != null)
							builder.select(nextDispatch);
					}
					if (!hasDynamicCatch)
						builder.rethrowValue(builder.load(exceptionLocal, Dyn));
					builder.select(afterBlock);
					if (!tryActive && !catchActive)
						builder.markUnreachable();
				case TBreak(_):
					if (loops.length == 0)
						throw "break outside loop";
					var loop = loops[loops.length - 1];
					builder.closeTrapsToDepth(loop.trapDepth);
					builder.store(loop.breakFlag, builder.constBool(true));
					builder.jump(loop.continueBlock);
				case TContinue(_):
					if (loops.length == 0)
						throw "continue outside loop";
					var loop = loops[loops.length - 1];
					builder.closeTrapsToDepth(loop.trapDepth);
					builder.jump(loop.continueBlock);
				case TIncrement(name, delta, _):
					var type = requireLocalType(localTypes, name, 'Missing increment local "$name"');
					var one = type == I32 ? builder.constInt(1) : builder.constFloat(1.0);
					builder.store(name, delta > 0 ? builder.add(builder.load(name, type), one) : builder.sub(builder.load(name, type), one));
				case TCellIncrement(name, cellClass, valueType, delta, _):
					var cell = builder.load('$' + 'cell:$name', Obj(cellClass)),
						value = builder.fieldGet(cell, "value", lowerType(valueType)),
						one = valueType == TInt ? builder.constInt(1) : builder.constFloat(1.0);
					builder.fieldSet(cell, "value", delta > 0 ? builder.add(value, one) : builder.sub(value, one));
				case TCellCapturedIncrement(name, cellClass, valueType, delta, _):
					var owner = requireLocalType(localTypes, "this", 'Captured increment "$name" has no environment');
					var cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass)),
						value = builder.fieldGet(cell, "value", lowerType(valueType)),
						one = valueType == TInt ? builder.constInt(1) : builder.constFloat(1.0);
					builder.fieldSet(cell, "value", delta > 0 ? builder.add(value, one) : builder.sub(value, one));
				case TIf(condition, thenBranch, elseBranch, _):
					var conditionValue = lowerExpression(condition, builder, localTypes),
						thenBlock = builder.createBlock(),
						elseBlock = builder.createBlock();
					builder.branch(conditionValue, thenBlock, elseBlock);
					builder.select(thenBlock);
					lowerStatements(thenBranch, builder, localTypes, loops);
					var thenActive = !builder.isTerminated(),
						thenExit = builder.currentBlock();
					builder.select(elseBlock);
					lowerStatements(elseBranch, builder, localTypes, loops);
					var elseActive = !builder.isTerminated(),
						elseExit = builder.currentBlock(),
						joinBlock = builder.createBlock();
					if (thenActive)
						builder.jumpFrom(thenExit, joinBlock);
					if (elseActive)
						builder.jumpFrom(elseExit, joinBlock);
					if (thenActive || elseActive)
						builder.select(joinBlock);
				case TWhile(condition, body, span):
					var infinite = isTrueLiteral(condition) && !canBreakCurrentLoop(body);
					var breakFlag = '$' + 'while-break:${span.start}';
					localTypes.set(breakFlag, Bool);
					builder.store(breakFlag, builder.constBool(false));
					var conditionBlock = builder.createBlock(),
						checkBlock = builder.createBlock(),
						bodyBlock = builder.createBlock(),
						afterBlock = builder.createBlock();
					builder.jump(conditionBlock);
					builder.select(conditionBlock);
					builder.branch(builder.load(breakFlag, Bool), afterBlock, checkBlock);
					builder.select(checkBlock);
					builder.branch(lowerExpression(condition, builder, localTypes), bodyBlock, afterBlock);
					builder.select(bodyBlock);
					loops.push({
						breakBlock: afterBlock,
						continueBlock: conditionBlock,
						breakFlag: breakFlag,
						trapDepth: builder.trapDepth()
					});
					lowerStatements(body, builder, localTypes, loops);
					loops.pop();
					if (!builder.isTerminated())
						builder.jump(conditionBlock);
					builder.select(afterBlock);
					if (infinite)
						builder.markUnreachable();
				case TDoWhile(body, condition, span):
					var breakFlag = '$' + 'do-while-break:${span.start}';
					localTypes.set(breakFlag, Bool);
					builder.store(breakFlag, builder.constBool(false));
					var conditionBlock = builder.createBlock(),
						conditionCheck = builder.createBlock(),
						bodyBlock = builder.createBlock(),
						afterBlock = builder.createBlock();
					loops.push({
						breakBlock: afterBlock,
						continueBlock: conditionBlock,
						breakFlag: breakFlag,
						trapDepth: builder.trapDepth()
					});
					lowerStatements(body, builder, localTypes, loops);
					loops.pop();
					if (!builder.isTerminated())
						builder.jump(conditionBlock);
					builder.select(conditionBlock);
					builder.branch(builder.load(breakFlag, Bool), afterBlock, conditionCheck);
					builder.select(conditionCheck);
					builder.branch(lowerExpression(condition, builder, localTypes), bodyBlock, afterBlock);
					builder.select(bodyBlock);
					loops.push({
						breakBlock: afterBlock,
						continueBlock: conditionBlock,
						breakFlag: breakFlag,
						trapDepth: builder.trapDepth()
					});
					lowerStatements(body, builder, localTypes, loops);
					loops.pop();
					if (!builder.isTerminated())
						builder.jump(conditionBlock);
					builder.select(afterBlock);
				case TForIn(name, valueName, iterable, body, span):
					var arrayName = '$' + 'for-array:${span.start}',
						mapName = '$' + 'for-map:${span.start}',
						indexName = '$' + 'for-index:${span.start}',
						breakFlag = '$' + 'for-break:${span.start}';
					var mapKey:CompilerType = TVoid,
						mapValue:CompilerType = TVoid;
					switch iterable.type {
						case TMap(key, value):
							mapKey = key;
							mapValue = value;
						default:
					}
					var arrayType:IrType = switch iterable.type {
						case TMap(key, _): Array(lowerType(key));
						default: lowerType(iterable.type);
					};
					var elementType = switch iterable.type {
						case TArray(element): lowerType(element);
						case TRange: I32;
						case TMap(key, _): lowerType(key);
						default: throw 'For-in iterable is not an array';
					};
					localTypes.set(arrayName, arrayType);
					localTypes.set(indexName, I32);
					localTypes.set(breakFlag, Bool);
					localTypes.set(name, elementType);
					if (valueName == null)
						builder.store(arrayName, lowerExpression(iterable, builder, localTypes));
					else {
						var loweredMapType = lowerType(iterable.type);
						localTypes.set(mapName, loweredMapType);
						localTypes.set(valueName, lowerType(mapValue));
						builder.store(mapName, lowerExpression(iterable, builder, localTypes));
						builder.store(arrayName,
							builder.call(RuntimeType.mapNative(mapKey, mapValue, "keys"), [builder.load(mapName, loweredMapType)], arrayType));
					}
					builder.store(indexName, builder.constInt(-1));
					builder.store(breakFlag, builder.constBool(false));
					var conditionBlock = builder.createBlock(),
						checkBlock = builder.createBlock(),
						bodyBlock = builder.createBlock(),
						afterBlock = builder.createBlock();
					builder.jump(conditionBlock);
					builder.select(conditionBlock);
					builder.branch(builder.load(breakFlag, Bool), afterBlock, checkBlock);
					builder.select(checkBlock);
					var indexValue = builder.add(builder.load(indexName, I32), builder.constInt(1));
					builder.store(indexName, indexValue);
					var arrayValue = builder.load(arrayName, arrayType);
					builder.branch(builder.less(indexValue, builder.arraySize(arrayValue)), bodyBlock, afterBlock);
					builder.select(bodyBlock);
					var bodyArray = builder.load(arrayName, arrayType),
						bodyIndex = builder.load(indexName, I32);
					builder.store(name, builder.arrayGet(bodyArray, bodyIndex, elementType));
					if (valueName != null)
						builder.store(valueName,
							lowerMapGet(builder, builder.load(mapName, lowerType(iterable.type)), builder.load(name, elementType), mapKey, mapValue));
					loops.push({
						breakBlock: afterBlock,
						continueBlock: conditionBlock,
						breakFlag: breakFlag,
						trapDepth: builder.trapDepth()
					});
					lowerStatements(body, builder, localTypes, loops);
					loops.pop();
					if (!builder.isTerminated()) {
						builder.jump(conditionBlock);
					}
					builder.select(afterBlock);
				case TSwitch(expression, cases, defaultBranch, hasDefault, span):
					var switchName = '$' + 'switch:${span.start}',
						switchType = lowerType(expression.type),
						exits:Array<CfgBlock> = [];
					localTypes.set(switchName, switchType);
					builder.store(switchName, lowerExpression(expression, builder, localTypes));
					var checkBlock = builder.currentBlock();
					for (switchCase in cases) {
						var matchBlock = builder.createBlock(),
							bodyBlock = switchCase.guard == null ? matchBlock : builder.createBlock(),
							nextBlock = builder.createBlock();
						builder.select(checkBlock);
						var switchValue = switch expression.type {
							case TEnum(_): builder.enumIndex(builder.load(switchName, switchType));
							default: builder.load(switchName, switchType);
						}, caseValue = switchCase.constructorIndex >= 0 ? builder.constInt(switchCase.constructorIndex) : lowerExpression(switchCase.value,
							builder, localTypes);
						builder.branch(builder.equal(switchValue, caseValue), matchBlock, nextBlock);
						builder.select(matchBlock);
						if (switchCase.constructorIndex >= 0)
							for (binding in switchCase.bindings) {
								localTypes.set(binding.name, lowerType(binding.type));
							}
						for (binding in switchCase.bindings)
							builder.store(binding.name,
								builder.enumField(builder.load(switchName, switchType), switchCase.constructorIndex, binding.index, lowerType(binding.type)));
						var guard = switchCase.guard;
						if (guard != null) {
							builder.branch(lowerExpression(guard, builder, localTypes), bodyBlock, nextBlock);
							builder.select(bodyBlock);
						}
						lowerStatements(switchCase.statements, builder, localTypes, loops);
						if (!builder.isTerminated())
							exits.push(builder.currentBlock());
						checkBlock = nextBlock;
					}
					builder.select(checkBlock);
					if (!hasDefault && exhaustiveEnumSwitch(expression.type, cases))
						builder.jump(checkBlock);
					else
						lowerStatements(defaultBranch, builder, localTypes, loops);
					if (!builder.isTerminated())
						exits.push(builder.currentBlock());
					if (exits.length > 0) {
						var joinBlock = builder.createBlock();
						for (exit in exits)
							builder.jumpFrom(exit, joinBlock);
						builder.select(joinBlock);
					}
				case TExpression(expression, _):
					lowerExpression(expression, builder, localTypes);
			}
		}
	}

	static function exhaustiveEnumSwitch(type:CompilerType, cases:Array<TypedSwitchCase>):Bool {
		switch type {
			case TEnum(_):
			default:
				return false;
		}
		return cases.length > 0 && [
			for (switchCase in cases)
				switchCase.constructorIndex >= 0 && switchCase.guard == null
		].indexOf(false) < 0;
	}

	static function isTrueLiteral(expression:TypedExpression):Bool
		return switch expression.expression {
			case TBoolLiteral(value): value;
			default: false;
		};

	static function canBreakCurrentLoop(statements:Array<TypedStatement>):Bool {
		for (statement in statements)
			switch statement {
				case TBreak(_):
					return true;
				case TIf(_, yes, no, _):
					if (canBreakCurrentLoop(yes) || canBreakCurrentLoop(no))
						return true;
				case TTry(tryBranch, catches, _):
					if (canBreakCurrentLoop(tryBranch))
						return true;
					for (catchClause in catches)
						if (canBreakCurrentLoop(catchClause.statements))
							return true;
				case TSwitch(_, cases, fallback, _, _):
					for (switchCase in cases)
						if (canBreakCurrentLoop(switchCase.statements))
							return true;
					if (canBreakCurrentLoop(fallback))
						return true;
				case TWhile(_, _, _), TDoWhile(_, _, _), TForIn(_, _, _, _, _):
				default:
			}
		return false;
	}

	static function lowerOperands(expressions:Array<TypedExpression>, builder:CfgBuilder, localTypes:Map<String, IrType>):Array<CfgValue> {
		var temporaries:Array<{name:String, type:IrType}> = [];
		for (expression in expressions) {
			var value = lowerExpression(expression, builder, localTypes),
				name = '$' + 'operand:${expression.span.start}:${value.id}';
			localTypes.set(name, value.type);
			builder.store(name, value);
			temporaries.push({name: name, type: value.type});
		}
		return [for (temporary in temporaries) builder.load(temporary.name, temporary.type)];
	}

	static function lowerMapGet(builder:CfgBuilder, map:CfgValue, key:CfgValue, keyType:CompilerType, valueType:CompilerType):CfgValue {
		var name = RuntimeType.requireMapName(keyType, valueType);
		return builder.call('__${name}_get', [map, key], lowerType(valueType));
	}

	static function lowerMapSet(builder:CfgBuilder, map:CfgValue, key:CfgValue, value:CfgValue, keyType:CompilerType, valueType:CompilerType):CfgValue {
		var name = RuntimeType.requireMapName(keyType, valueType);
		return builder.call('__${name}_set', [map, key, value], Void);
	}

	static function lowerExpression(expression:TypedExpression, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue
		return switch expression.expression {
			case TIntLiteral(value): builder.constInt(value);
			case TFloatLiteral(value): builder.constFloat(value);
			case TStringLiteral(value): builder.constString(value);
			case TBoolLiteral(value): builder.constBool(value);
			case TEnumLiteral(name, index): builder.makeEnum(name, index, []);
			case TEnumConstruct(name, index, arguments): builder.makeEnum(name, index, lowerOperands(arguments, builder, localTypes));
			case TNullLiteral: throw "Uncoerced null literal";
			case TUnreachable: unreachableValue(lowerType(expression.type), builder);
			case TNoReturn(value):
				var lowered = lowerExpression(value, builder, localTypes);
				builder.markUnreachable();
				lowered;
			case TClassRef(_): throw "Class references are only valid for static members";
			case TStaticField(name, field): builder.globalGet(name + "." + field, lowerType(expression.type));
			case TNullableWrap(value):
				switch value.expression {
					case TNullLiteral: builder.constNull(lowerType(expression.type));
					default: lowerExpression(value, builder, localTypes);
				}
			case TToDynamic(value): builder.toDyn(lowerExpression(value, builder, localTypes));
			case TLocal(name):
				var type = requireLocalType(localTypes, name, 'Missing typed local "$name"');
				builder.load(name, type);
			case TCellLocal(name, cellClass):
				var cell = builder.load('$' + 'cell:$name', Obj(cellClass));
				builder.fieldGet(cell, "value", lowerType(expression.type));
			case TCaptured(name):
				var owner = requireLocalType(localTypes, "this", 'Captured value "$name" has no environment');
				builder.fieldGet(builder.load("this", owner), name, lowerType(expression.type));
			case TCellCaptured(name, cellClass):
				var owner = requireLocalType(localTypes, "this", 'Captured value "$name" has no environment');
				var cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass));
				builder.fieldGet(cell, "value", lowerType(expression.type));
			case TFunctionRef(name): builder.staticClosure(name, lowerType(expression.type));
			case TLambda(name, environment, captures):
				if (environment == null) builder.staticClosure(name, lowerType(expression.type)); else {
					var object = builder.newObject(environment);
					for (capture in captures) {
						var cellKey = '__cell:$capture',
							capturedCellKey = '__capturecell:$capture';
						var value:CfgValue;
						if (localTypes.exists(cellKey))
							value = builder.load('$' + 'cell:$capture', localTypes.get(cellKey));
						else if (localTypes.exists(capturedCellKey))
							value = builder.fieldGet(builder.load("this", requireLocalType(localTypes, "this", "Capture has no environment")), capture,
								localTypes.get(capturedCellKey));
						else
							value = builder.load(capture, requireLocalType(localTypes, capture, 'Missing captured local "$capture"'));
						builder.fieldSet(object, capture, value);
					}
					builder.instanceClosure(name, object, lowerType(expression.type));
				}
			case TAdd(a, b):
				var operands = lowerOperands([a, b], builder, localTypes),
					left = operands[0],
					right = operands[1];
				lowerType(expression.type) == Bytes ? builder.call("__string_concat", [left, right], Bytes) : builder.add(left, right);
			case TSub(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.sub(values[0], values[1]);
			case TMul(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.mul(values[0], values[1]);
			case TDiv(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.div(values[0], values[1]);
			case TMod(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.mod(values[0], values[1]);
			case TBitAnd(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.bitAnd(values[0], values[1]);
			case TBitXor(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.bitXor(values[0], values[1]);
			case TBitOr(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.bitOr(values[0], values[1]);
			case TShiftLeft(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.shiftLeft(values[0], values[1]);
			case TShiftRight(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.shiftRight(values[0], values[1]);
			case TUnsignedShiftRight(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.unsignedShiftRight(values[0], values[1]);
			case TNegate(value):
				var typed = lowerExpression(value, builder, localTypes);
				value.type == TInt ? builder.sub(builder.constInt(0), typed) : builder.sub(builder.constFloat(0.0), typed);
			case TLess(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.less(values[0], values[1]);
			case TLessEqual(a, b):
				var values = lowerOperands([a, b], builder, localTypes);
				builder.lessEqual(values[0], values[1]);
			case TNot(value): builder.equal(lowerExpression(value, builder, localTypes), builder.constBool(false));
			case TAnd(left, right): lowerLogical(left, right, true, builder, localTypes);
			case TOr(left, right): lowerLogical(left, right, false, builder, localTypes);
			case TEqual(a, b):
				var operands = lowerOperands([a, b], builder, localTypes),
					left = operands[0],
					right = operands[1];
				var isEnum = switch a.type {
					case TEnum(_): true;
					default: false;
				};
				if (isEnum) {
					left = builder.enumIndex(left);
					right = builder.enumIndex(right);
				}
				lowerType(a.type) == Bytes ? builder.call("__string_equal", [left, right], Bool) : builder.equal(left, right);
			case TCall(name, args): builder.call(name, lowerOperands(args, builder, localTypes), lowerType(expression.type));
			case TCollectionCall(receiver, operation, args):
				var nativeName = switch receiver.type {
					case TArray(element): RuntimeType.arrayNative(element, operation);
					case TMap(key, value): RuntimeType.mapNative(key, value, operation);
					default: throw "Collection operation requires an Array or Map receiver";
				};
				var operands:Array<TypedExpression> = [receiver];
				for (argument in args)
					operands.push(argument);
				var lowered = lowerOperands(operands, builder, localTypes);
				switch receiver.type {
					case TMap(key, value) if (operation == "set"): lowerMapSet(builder, lowered[0], lowered[1], lowered[2], key, value);
					default: builder.call(nativeName, lowered, lowerType(expression.type));
				}
			case TConditional(condition, whenTrue, whenFalse):
				var yesBlock = builder.createBlock(),
					noBlock = builder.createBlock(),
					afterBlock = builder.createBlock(),
					localName = '$' + 'conditional:${expression.span.start}:${afterBlock.id}',
					resultType = lowerType(expression.type);
				localTypes.set(localName, resultType);
				builder.branch(lowerExpression(condition, builder, localTypes), yesBlock, noBlock);
				builder.select(yesBlock);
				var yesValue = lowerExpression(whenTrue, builder, localTypes);
				if (!builder.isTerminated()) {
					builder.store(localName, yesValue);
					builder.jump(afterBlock);
				}
				builder.select(noBlock);
				var noValue = lowerExpression(whenFalse, builder, localTypes);
				if (!builder.isTerminated()) {
					builder.store(localName, noValue);
					builder.jump(afterBlock);
				}
				builder.select(afterBlock);
				builder.load(localName, resultType);
			case TBlockExpression(statements, result):
				var placeholder = unreachableValue(lowerType(expression.type), builder);
				lowerStatements(statements, builder, localTypes, []);
				if (builder.isTerminated()) placeholder; else lowerExpression(result, builder, localTypes);
			case TThrowExpression(value):
				var placeholder = unreachableValue(lowerType(expression.type), builder);
				builder.throwValue(builder.toDyn(lowerExpression(value, builder, localTypes)));
				placeholder;
			case TCast(value):
				var source = lowerExpression(value, builder, localTypes),
					target = lowerType(expression.type);
				if (source.type == target) source; else if (source.type == Dyn) builder.safeCast(source,
					target); else if (target == Dyn) builder.toDyn(source); else throw 'Unsupported cast from ${source.type} to $target';
			case TSwitchExpression(subject, cases, defaultExpression):
				var subjectName = '$' + 'switch-expression-subject:${expression.span.start}',
					resultName = '$' + 'switch-expression-result:${expression.span.start}',
					subjectType = lowerType(subject.type),
					resultType = lowerType(expression.type),
					entryBlock = builder.currentBlock();
				var bodyBlocks:Array<CfgBlock> = [];
				var matchBlocks:Array<CfgBlock> = [];
				var checkBlocks:Array<CfgBlock> = [entryBlock];
				for (caseIndex in 0...cases.length) {
					var matchBlock = builder.createBlock();
					matchBlocks.push(matchBlock);
					bodyBlocks.push(cases[caseIndex].guard == null ? matchBlock : builder.createBlock());
					if (caseIndex + 1 < cases.length)
						checkBlocks.push(builder.createBlock());
				}
				// Keep all case and fallback blocks before their shared join. HashLink
				// treats a backward branch as a loop edge and requires its target to
				// dominate the branch.
				var fallbackBlock = builder.createBlock(),
					afterBlock = builder.createBlock();
				builder.select(entryBlock);
				localTypes.set(subjectName, subjectType);
				localTypes.set(resultName, resultType);
				builder.store(subjectName, lowerExpression(subject, builder, localTypes));
				if (defaultExpression != null)
					switch subject.type {
						case TEnum(_):
							var firstCheck = builder.createBlock(),
								subjectValue = builder.load(subjectName, subjectType);
							builder.branch(builder.equal(subjectValue, builder.constNull(subjectType)), fallbackBlock, firstCheck);
							checkBlocks[0] = firstCheck;
						default:
					}
				for (caseIndex in 0...cases.length) {
					var switchCase = cases[caseIndex],
						isExhaustiveFinalCase = defaultExpression == null && caseIndex == cases.length - 1 && switchCase.guard == null,
						bodyBlock = bodyBlocks[caseIndex],
						nextBlock = caseIndex + 1 < cases.length ? checkBlocks[caseIndex + 1] : (defaultExpression == null ? afterBlock : fallbackBlock);
					builder.select(checkBlocks[caseIndex]);
					var subjectValue = builder.load(subjectName, subjectType),
						comparisonValue = switch subject.type {
							case TEnum(_): builder.enumIndex(subjectValue);
							default: subjectValue;
						};
					var caseValue = switchCase.constructorIndex >= 0 ? builder.constInt(switchCase.constructorIndex) : lowerExpression(switchCase.value,
						builder, localTypes),
						matches = subject.type == TString ? builder.call("__string_equal", [comparisonValue, caseValue],
							Bool) : builder.equal(comparisonValue, caseValue);
					var matchBlock = matchBlocks[caseIndex];
					if (isExhaustiveFinalCase)
						builder.jump(bodyBlock);
					else
						builder.branch(matches, matchBlock, nextBlock);
					builder.select(matchBlock);
					for (binding in switchCase.bindings) {
						localTypes.set(binding.name, lowerType(binding.type));
						builder.store(binding.name,
							builder.enumField(builder.load(subjectName, subjectType), switchCase.constructorIndex, binding.index, lowerType(binding.type)));
					}
					var guard = switchCase.guard;
					if (guard != null) {
						builder.branch(lowerExpression(guard, builder, localTypes), bodyBlock, nextBlock);
						builder.select(bodyBlock);
					}
					var caseResult = lowerExpression(switchCase.result, builder, localTypes);
					if (!builder.isTerminated()) {
						builder.store(resultName, caseResult);
						builder.jump(afterBlock);
					}
				}
				var fallback = defaultExpression;
				if (fallback != null) {
					builder.select(fallbackBlock);
					var fallbackResult = lowerExpression(fallback, builder, localTypes);
					if (!builder.isTerminated()) {
						builder.store(resultName, fallbackResult);
						builder.jump(afterBlock);
					}
				}
				builder.select(afterBlock);
				builder.load(resultName, resultType);
			case TClosureCall(callee, args):
				var operands:Array<TypedExpression> = [callee];
				for (argument in args)
					operands.push(argument);
				var loweredOperands = lowerOperands(operands, builder, localTypes),
					loweredArguments:Array<CfgValue> = [];
				for (index in 1...loweredOperands.length)
					loweredArguments.push(loweredOperands[index]);
				builder.callClosure(loweredOperands[0], loweredArguments, lowerType(expression.type));
			case TToInterface(value, name):
				builder.toVirtual(lowerExpression(value, builder, localTypes), Virtual(name));
			case TNew(typeName, args, hasConstructor):
				var object = builder.newObject(typeName),
					objectType:IrType = Obj(typeName),
					objectName = '$' + 'new-object:${expression.span.start}:${object.id}';
				localTypes.set(objectName, objectType);
				builder.store(objectName, object);
				if (hasConstructor) {
					var loweredArguments = lowerOperands(args, builder, localTypes),
						constructorArgs:Array<CfgValue> = [builder.load(objectName, objectType)];
					for (argument in loweredArguments)
						constructorArgs.push(argument);
					builder.call('$typeName.new', constructorArgs, Void);
				}
				builder.load(objectName, objectType);
			case TObjectLiteral(typeName, fields):
				var object = builder.newObject(typeName),
					objectType:IrType = Obj(typeName),
					objectName = '$' + 'object-literal:${expression.span.start}:${object.id}';
				localTypes.set(objectName, objectType);
				builder.store(objectName, object);
				for (field in fields) {
					var fieldValue = lowerExpression(field.value, builder, localTypes);
					builder.fieldSet(builder.load(objectName, objectType), field.name, fieldValue);
				}
				builder.load(objectName, objectType);
			case TArrayLiteral(values):
				var element = switch expression.type {
					case TArray(element): element;
					default: throw "Array literal requires an array type";
				}, arrayType:IrType = Array(lowerType(element)), array = builder.call(arrayAllocatorName(element), [builder.constInt(values.length)],
					arrayType), arrayName = '$' + 'array-literal:${expression.span.start}:${array.id}';
				localTypes.set(arrayName, arrayType);
				builder.store(arrayName, array);
				for (index in 0...values.length) {
					var elementValue = lowerExpression(values[index], builder, localTypes);
					builder.arraySet(builder.load(arrayName, arrayType), builder.constInt(index), elementValue);
				}
				builder.load(arrayName, arrayType);
			case TMapLiteral(entries):
				var types = switch expression.type {
					case TMap(key, value): {key: key, value: value};
					default: throw "Map literal requires a map type";
				}, resultType = lowerType(expression.type), map = builder.call(RuntimeType.mapNative(types.key, types.value, "alloc"), [],
					resultType), mapName = '$' + 'map-literal:${expression.span.start}:${map.id}';
				localTypes.set(mapName, resultType);
				builder.store(mapName, map);
				for (entry in entries) {
					var entryValues = lowerOperands([entry.key, entry.value], builder, localTypes),
						callArguments:Array<CfgValue> = [builder.load(mapName, resultType)];
					for (entryValue in entryValues)
						callArguments.push(entryValue);
					lowerMapSet(builder, callArguments[0], callArguments[1], callArguments[2], types.key, types.value);
				}
				builder.load(mapName, resultType);
			case TArrayComprehension(keyName, valueName, iterable, condition, value):
				var inputName = '$' + 'comprehension-input:${expression.span.start}',
					mapName = '$' + 'comprehension-map:${expression.span.start}',
					resultName = '$' + 'comprehension-result:${expression.span.start}',
					indexName = '$' + 'comprehension-index:${expression.span.start}',
					mapTypes = mapTypesOrVoid(iterable.type),
					keyType = valueName == null ? switch iterable.type {
						case TArray(element): element;
						case TRange: TInt;
						default: throw "Array comprehension requires an array iterable";
					} : mapTypes.key,
					inputType:IrType = Array(lowerType(keyType)),
					resultElement = switch expression.type {
						case TArray(element): element;
						default: throw "Array comprehension requires an array result";
					},
					resultType:IrType = Array(lowerType(resultElement));
				localTypes.set(inputName, inputType);
				localTypes.set(resultName, resultType);
				localTypes.set(indexName, I32);
				localTypes.set(keyName, lowerType(keyType));
				if (valueName == null)
					builder.store(inputName, lowerExpression(iterable, builder, localTypes));
				else {
					var loweredMapType = lowerType(iterable.type);
					localTypes.set(mapName, loweredMapType);
					localTypes.set(valueName, lowerType(mapTypes.value));
					builder.store(mapName, lowerExpression(iterable, builder, localTypes));
					builder.store(inputName,
						builder.call(RuntimeType.mapNative(mapTypes.key, mapTypes.value, "keys"), [builder.load(mapName, loweredMapType)], inputType));
				}
				var capacity = condition == null ? builder.arraySize(builder.load(inputName, inputType)) : builder.constInt(0);
				builder.store(resultName, builder.call(arrayAllocatorName(resultElement), [capacity], resultType));
				builder.store(indexName, builder.constInt(0));
				var conditionBlock = builder.createBlock(),
					bodyBlock = builder.createBlock(),
					afterBlock = builder.createBlock();
				builder.jump(conditionBlock);
				builder.select(conditionBlock);
				var index = builder.load(indexName, I32);
				builder.branch(builder.less(index, builder.arraySize(builder.load(inputName, inputType))), bodyBlock, afterBlock);
				builder.select(bodyBlock);
				builder.store(keyName, builder.arrayGet(builder.load(inputName, inputType), builder.load(indexName, I32), lowerType(keyType)));
				if (valueName != null)
					builder.store(valueName,
						lowerMapGet(builder, builder.load(mapName, lowerType(iterable.type)), builder.load(keyName, lowerType(keyType)), mapTypes.key,
							mapTypes.value));
				var conditionValue = condition;
				if (conditionValue == null) {
					var loweredValue = lowerExpression(value, builder, localTypes);
					builder.arraySet(builder.load(resultName, resultType), builder.load(indexName, I32), loweredValue);
				} else {
					var includeBlock = builder.createBlock(),
						excludeBlock = builder.createBlock(),
						nextBlock = builder.createBlock();
					builder.branch(lowerExpression(conditionValue, builder, localTypes), includeBlock, excludeBlock);
					builder.select(excludeBlock);
					builder.jump(nextBlock);
					builder.select(includeBlock);
					var loweredValue = lowerExpression(value, builder, localTypes);
					var grown = builder.call(RuntimeType.arrayNative(resultElement, "push"), [builder.load(resultName, resultType), loweredValue], resultType);
					builder.store(resultName, grown);
					builder.jump(nextBlock);
					builder.select(nextBlock);
				}
				builder.store(indexName, builder.add(builder.load(indexName, I32), builder.constInt(1)));
				builder.jump(conditionBlock);
				builder.select(afterBlock);
				builder.load(resultName, resultType);
			case TMapComprehension(keyName, valueName, iterable, condition, key, value):
				var inputName = '$' + 'map-comprehension-input:${expression.span.start}',
					sourceMapName = '$' + 'map-comprehension-source:${expression.span.start}',
					resultName = '$' + 'map-comprehension-result:${expression.span.start}',
					indexName = '$' + 'map-comprehension-index:${expression.span.start}',
					sourceMapTypes = mapTypesOrVoid(iterable.type),
					itemType = valueName == null ? switch iterable.type {
						case TArray(element): element;
						case TRange: TInt;
						default: throw "Map comprehension requires an array iterable";
					} : sourceMapTypes.key,
					inputType:IrType = Array(lowerType(itemType)),
					resultTypes:MapTypes = switch expression.type {
						case TMap(mapKey, mapValue): {key: mapKey, value: mapValue};
						default: throw "Map comprehension requires a map result";
					},
					resultType = lowerType(expression.type);
				localTypes.set(inputName, inputType);
				localTypes.set(resultName, resultType);
				localTypes.set(indexName, I32);
				localTypes.set(keyName, lowerType(itemType));
				if (valueName == null)
					builder.store(inputName, lowerExpression(iterable, builder, localTypes));
				else {
					var sourceMapType = lowerType(iterable.type);
					localTypes.set(sourceMapName, sourceMapType);
					localTypes.set(valueName, lowerType(sourceMapTypes.value));
					builder.store(sourceMapName, lowerExpression(iterable, builder, localTypes));
					builder.store(inputName,
						builder.call(RuntimeType.mapNative(sourceMapTypes.key, sourceMapTypes.value, "keys"), [builder.load(sourceMapName, sourceMapType)],
							inputType));
				}
				builder.store(resultName, builder.call(RuntimeType.mapNative(resultTypes.key, resultTypes.value, "alloc"), [], resultType));
				builder.store(indexName, builder.constInt(0));
				var conditionBlock = builder.createBlock(),
					bodyBlock = builder.createBlock(),
					afterBlock = builder.createBlock();
				builder.jump(conditionBlock);
				builder.select(conditionBlock);
				builder.branch(builder.less(builder.load(indexName, I32), builder.arraySize(builder.load(inputName, inputType))), bodyBlock, afterBlock);
				builder.select(bodyBlock);
				builder.store(keyName, builder.arrayGet(builder.load(inputName, inputType), builder.load(indexName, I32), lowerType(itemType)));
				if (valueName != null)
					builder.store(valueName,
						lowerMapGet(builder, builder.load(sourceMapName, lowerType(iterable.type)), builder.load(keyName, lowerType(itemType)),
							sourceMapTypes.key, sourceMapTypes.value));
				var conditionValue = condition;
				if (conditionValue == null) {
					setComprehensionMapEntry(builder, localTypes, resultTypes, resultName, resultType, key, value);
				} else {
					var includeBlock = builder.createBlock(),
						excludeBlock = builder.createBlock(),
						nextBlock = builder.createBlock();
					builder.branch(lowerExpression(conditionValue, builder, localTypes), includeBlock, excludeBlock);
					builder.select(excludeBlock);
					builder.jump(nextBlock);
					builder.select(includeBlock);
					setComprehensionMapEntry(builder, localTypes, resultTypes, resultName, resultType, key, value);
					builder.jump(nextBlock);
					builder.select(nextBlock);
				}
				builder.store(indexName, builder.add(builder.load(indexName, I32), builder.constInt(1)));
				builder.jump(conditionBlock);
				builder.select(afterBlock);
				builder.load(resultName, resultType);
			case TRange(start, end):
				var startName = '$' + 'range-start:${expression.span.start}',
					endName = '$' + 'range-end:${expression.span.start}',
					differenceName = '$' + 'range-difference:${expression.span.start}',
					lengthName = '$' + 'range-length:${expression.span.start}',
					resultName = '$' + 'range-result:${expression.span.start}',
					indexName = '$' + 'range-index:${expression.span.start}',
					resultType:IrType = Array(I32);
				for (name in [startName, endName, differenceName, lengthName, indexName])
					localTypes.set(name, I32);
				localTypes.set(resultName, resultType);
				builder.store(startName, lowerExpression(start, builder, localTypes));
				builder.store(endName, lowerExpression(end, builder, localTypes));
				builder.store(differenceName, builder.sub(builder.load(endName, I32), builder.load(startName, I32)));
				var positiveLength = builder.createBlock(),
					emptyLength = builder.createBlock(),
					allocateBlock = builder.createBlock();
				builder.branch(builder.less(builder.load(differenceName, I32), builder.constInt(0)), emptyLength, positiveLength);
				builder.select(emptyLength);
				builder.store(lengthName, builder.constInt(0));
				builder.jump(allocateBlock);
				builder.select(positiveLength);
				builder.store(lengthName, builder.load(differenceName, I32));
				builder.jump(allocateBlock);
				builder.select(allocateBlock);
				builder.store(resultName, builder.call(arrayAllocatorName(TInt), [builder.load(lengthName, I32)], resultType));
				builder.store(indexName, builder.constInt(0));
				var conditionBlock = builder.createBlock(),
					bodyBlock = builder.createBlock(),
					afterBlock = builder.createBlock();
				builder.jump(conditionBlock);
				builder.select(conditionBlock);
				builder.branch(builder.less(builder.load(indexName, I32), builder.load(lengthName, I32)), bodyBlock, afterBlock);
				builder.select(bodyBlock);
				builder.arraySet(builder.load(resultName, resultType), builder.load(indexName, I32),
					builder.add(builder.load(startName, I32), builder.load(indexName, I32)));
				builder.store(indexName, builder.add(builder.load(indexName, I32), builder.constInt(1)));
				builder.jump(conditionBlock);
				builder.select(afterBlock);
				builder.load(resultName, resultType);
			case TNewArray(element, length):
				builder.call(arrayAllocatorName(element), [lowerExpression(length, builder, localTypes)], Array(lowerType(element)));
			case TNewMap(key, value): builder.call(RuntimeType.mapNative(key, value, "alloc"), [], lowerType(expression.type));
			case TField(object, name): builder.fieldGet(lowerExpression(object, builder, localTypes), name, lowerType(expression.type));
			case TMethodCall(object, name, args):
				var operands:Array<TypedExpression> = [object];
				for (argument in args)
					operands.push(argument);
				var loweredOperands = lowerOperands(operands, builder, localTypes),
					receiver = loweredOperands[0],
					callArgs:Array<CfgValue> = [];
				for (index in 1...loweredOperands.length)
					callArgs.push(loweredOperands[index]);
				var separator = IrGenerator.lastSeparator(name);
				builder.methodCall(receiver, name.substring(separator + 1, name.length), callArgs, lowerType(expression.type));
			case TSuperCall(owner, args):
				builder.call(owner + ".new", [builder.load("this", localTypes.get("this"))].concat([
					for (arg in args)
						lowerExpression(arg, builder, localTypes)
				]), Void);
			case TIndex(array, index):
				var operands = lowerOperands([array, index], builder, localTypes);
				builder.arrayGet(operands[0], operands[1], lowerType(expression.type));
			case TPostfixLocal(name, delta):
				var type = lowerType(expression.type),
					oldValue = builder.load(name, type),
					one = incrementOne(expression.type, builder);
				builder.store(name, delta > 0 ? builder.add(oldValue, one) : builder.sub(oldValue, one));
				oldValue;
			case TPostfixCellLocal(name, cellClass, delta):
				var cell = builder.load('$' + 'cell:$name', Obj(cellClass)),
					oldValue = builder.fieldGet(cell, "value", lowerType(expression.type)),
					one = incrementOne(expression.type, builder);
				builder.fieldSet(cell, "value", delta > 0 ? builder.add(oldValue, one) : builder.sub(oldValue, one));
				oldValue;
			case TPostfixCellCaptured(name, cellClass, delta):
				var owner = requireLocalType(localTypes, "this", 'Captured increment "$name" has no environment');
				var cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass)),
					oldValue = builder.fieldGet(cell, "value", lowerType(expression.type)),
					one = incrementOne(expression.type, builder);
				builder.fieldSet(cell, "value", delta > 0 ? builder.add(oldValue, one) : builder.sub(oldValue, one));
				oldValue;
			case TPostfixStaticField(owner, name, delta):
				var oldValue = builder.globalGet(owner + "." + name, lowerType(expression.type)),
					one = incrementOne(expression.type, builder);
				builder.globalSet(owner + "." + name, delta > 0 ? builder.add(oldValue, one) : builder.sub(oldValue, one));
				oldValue;
			case TPostfixField(object, name, delta):
				var receiver = lowerExpression(object, builder, localTypes),
					oldValue = builder.fieldGet(receiver, name, lowerType(expression.type)),
					one = incrementOne(expression.type, builder);
				builder.fieldSet(receiver, name, delta > 0 ? builder.add(oldValue, one) : builder.sub(oldValue, one));
				oldValue;
			case TPostfixIndex(array, index, delta):
				var receiver = lowerExpression(array, builder, localTypes),
					offset = lowerExpression(index, builder, localTypes),
					oldValue = builder.arrayGet(receiver, offset, lowerType(expression.type)),
					one = incrementOne(expression.type, builder);
				builder.arraySet(receiver, offset, delta > 0 ? builder.add(oldValue, one) : builder.sub(oldValue, one));
				oldValue;
			case TMapGet(map, key):
				var mapType = switch map.type {
					case TMap(keyType, valueType): {key: keyType, value: valueType};
					default: throw "Map read requires a map value";
				};
				var operands = lowerOperands([map, key], builder, localTypes);
				lowerMapGet(builder, operands[0], operands[1], mapType.key, mapType.value);
			case TArrayLength(array):
				builder.arraySize(lowerExpression(array, builder, localTypes));
			case TStringLength(value):
				builder.call("__string_length", [lowerExpression(value, builder, localTypes)], I32);
			case TStringIndexOf(value, needle):
				builder.call("__string_index_of", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(needle, builder, localTypes)
				], I32);
			case TStringCharCodeAt(value, index):
				builder.call("__string_char_code_at", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(index, builder, localTypes)
				], I32);
			case TStringCharAt(value, index):
				builder.call("__string_char_at", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(index, builder, localTypes)
				], Bytes);
			case TStringFromCharCode(code):
				builder.call("__string_from_char_code", [lowerExpression(code, builder, localTypes)], Bytes);
			case TStringSubstring(value, start, end):
				builder.call("__string_substring", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(start, builder, localTypes),
					lowerExpression(end, builder, localTypes)
				], Bytes);
			case TArrayPush(array, value):
				var element = switch array.type {
					case TArray(valueType): valueType;
					default: throw "Array.push requires an array value";
				}, operands = lowerOperands([array, value], builder, localTypes);
				var pushed = builder.call(RuntimeType.arrayNative(element, "push"), operands, Array(lowerType(element)));
				switch array.expression {
					case TLocal(name): builder.store(name, pushed);
					case TCellLocal(name, cellClass):
						var cell = builder.load('$' + 'cell:$name', Obj(cellClass));
						builder.fieldSet(cell, "value", pushed);
					case TField(object, name): builder.fieldSet(lowerExpression(object, builder, localTypes), name, pushed);
					default: throw "Array.push requires a mutable local or field array";
				}
				builder.arraySize(pushed);
			case TArrayPop(array):
				var element = switch array.type {
					case TArray(valueType): valueType;
					default: throw "Array.pop requires an array value";
				}, resultType = lowerType(element), loweredArray = lowerExpression(array, builder, localTypes);
				builder.call(RuntimeType.arrayNative(element, "pop"), [loweredArray], resultType);
			case TArraySort(array, comparator): lowerArraySort(array, comparator, expression.span, builder, localTypes);
		}

	static function lowerArraySort(array:TypedExpression, comparator:TypedExpression, span:compiler.Source.SourceSpan, builder:CfgBuilder,
			localTypes:Map<String, IrType>):CfgValue {
		var element = switch array.type {
			case TArray(value): value;
			default: throw "Array.sort requires an array";
		};
		var elementType = lowerType(element),
			comparatorType = lowerType(comparator.type),
			suffix = Std.string(span.start);
		var arrayType:IrType = Array(elementType);
		var arrayName = '$' + 'sort-array:$suffix',
			comparatorName = '$' + 'sort-comparator:$suffix',
			indexName = '$' + 'sort-index:$suffix',
			keyName = '$' + 'sort-key:$suffix',
			scanName = '$' + 'sort-scan:$suffix';
		var locals:Array<{name:String, type:IrType}> = [
			{name: arrayName, type: arrayType},
			{name: comparatorName, type: comparatorType},
			{name: indexName, type: I32},
			{name: keyName, type: elementType},
			{name: scanName, type: I32}
		];
		for (entry in locals)
			localTypes.set(entry.name, entry.type);
		builder.store(arrayName, lowerExpression(array, builder, localTypes));
		builder.store(comparatorName, lowerExpression(comparator, builder, localTypes));
		builder.store(indexName, builder.constInt(1));
		var outerCondition = builder.createBlock(),
			outerBody = builder.createBlock(),
			innerCondition = builder.createBlock(),
			compare = builder.createBlock(),
			move = builder.createBlock(),
			insert = builder.createBlock(),
			done = builder.createBlock();
		builder.jump(outerCondition);
		builder.select(outerCondition);
		builder.branch(builder.less(builder.load(indexName, I32), builder.arraySize(builder.load(arrayName, arrayType))), outerBody, done);
		builder.select(outerBody);
		builder.store(keyName, builder.arrayGet(builder.load(arrayName, arrayType), builder.load(indexName, I32), elementType));
		builder.store(scanName, builder.sub(builder.load(indexName, I32), builder.constInt(1)));
		builder.jump(innerCondition);
		builder.select(innerCondition);
		builder.branch(builder.lessEqual(builder.constInt(0), builder.load(scanName, I32)), compare, insert);
		builder.select(compare);
		var order = builder.callClosure(builder.load(comparatorName, comparatorType), [
			builder.arrayGet(builder.load(arrayName, arrayType), builder.load(scanName, I32), elementType),
			builder.load(keyName, elementType)
		], I32);
		builder.branch(builder.less(builder.constInt(0), order), move, insert);
		builder.select(move);
		var scan = builder.load(scanName, I32);
		builder.arraySet(builder.load(arrayName, arrayType), builder.add(scan, builder.constInt(1)),
			builder.arrayGet(builder.load(arrayName, arrayType), scan, elementType));
		builder.store(scanName, builder.sub(scan, builder.constInt(1)));
		builder.jump(innerCondition);
		builder.select(insert);
		builder.arraySet(builder.load(arrayName, arrayType), builder.add(builder.load(scanName, I32), builder.constInt(1)), builder.load(keyName, elementType));
		builder.store(indexName, builder.add(builder.load(indexName, I32), builder.constInt(1)));
		builder.jump(outerCondition);
		builder.select(done);
		return builder.constVoid();
	}

	static function implicitArguments(fn:TypedFunction):Array<CfgArgument> {
		var owner = fn.owner;
		if (owner == null || fn.isStatic)
			return [];
		return [{name: "this", type: Obj(owner)}];
	}

	static function requireLocalType(localTypes:Map<String, IrType>, name:String, message:String):IrType {
		if (!localTypes.exists(name))
			throw message;
		return localTypes.get(name);
	}

	static function setComprehensionMapEntry(builder:CfgBuilder, localTypes:Map<String, IrType>, types:MapTypes, resultName:String, resultType:IrType,
			key:TypedExpression, value:TypedExpression):Void {
		var operands = lowerOperands([key, value], builder, localTypes);
		lowerMapSet(builder, builder.load(resultName, resultType), operands[0], operands[1], types.key, types.value);
	}

	static function mapTypesOrVoid(type:CompilerType):MapTypes
		return switch type {
			case TMap(key, value): {key: key, value: value};
			default: {key: TVoid, value: TVoid};
		};

	public static function lowerType(type:CompilerType):IrType
		return switch type {
			case TInt: I32;
			case TBool: Bool;
			case TFloat: F64;
			case TString: Bytes;
			case TBytes: Abstract("realtime_bytes");
			case THlBytes: Bytes;
			case TDynamic: Dyn;
			case TNativeAbstract(name): Abstract(name);
			case TNever: throw "Never must be coerced before lowering";
			case TRange: Array(I32);
			case TVoid: Void;
			case TClass(name): name == "haxe.io.Eof" ? Dyn : Obj(name);
			case TMap(key, value): Abstract(RuntimeType.requireMapName(key, value));
			case TInterface(name): Virtual(name);
			case TEnum(name): Enum(name);
			case TNull: Void;
			case TNullable(element): lowerType(element);
			case TArray(element): Array(lowerType(element));
			case TFunction(arguments, result): Function([for (argument in arguments) lowerType(argument)], lowerType(result));
			case TAnonymous(name, _): Obj(name);
		};

	static function unreachableValue(type:IrType, builder:CfgBuilder):CfgValue
		return switch type {
			case I32: builder.constInt(0);
			case Bool: builder.constBool(false);
			case F64: builder.constFloat(0.0);
			default: builder.constNull(type);
		};

	static function incrementOne(type:CompilerType, builder:CfgBuilder):CfgValue
		return type == TInt ? builder.constInt(1) : builder.constFloat(1.0);

	static function lowerLogical(left:TypedExpression, right:TypedExpression, and:Bool, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue {
		var resultName = '$' + 'logical:${left.span.start}:${right.span.end}';
		localTypes.set(resultName, Bool);
		var leftValue = lowerExpression(left, builder, localTypes),
			rightBlock = builder.createBlock(),
			shortBlock = builder.createBlock();
		if (and)
			builder.branch(leftValue, rightBlock, shortBlock);
		else
			builder.branch(leftValue, shortBlock, rightBlock);
		builder.select(rightBlock);
		var rightValue = lowerExpression(right, builder, localTypes),
			rightActive = !builder.isTerminated(),
			rightExit = builder.currentBlock();
		if (rightActive)
			builder.store(resultName, rightValue);
		builder.select(shortBlock);
		builder.store(resultName, builder.constBool(and ? false : true));
		var shortActive = !builder.isTerminated(),
			shortExit = builder.currentBlock(),
			joinBlock = builder.createBlock();
		if (rightActive)
			builder.jumpFrom(rightExit, joinBlock);
		if (shortActive)
			builder.jumpFrom(shortExit, joinBlock);
		builder.select(joinBlock);
		return builder.load(resultName, Bool);
	}

	static function arrayAllocatorName(element:CompilerType):String
		return "__array_alloc_" + RuntimeType.requireArrayName(element);
}

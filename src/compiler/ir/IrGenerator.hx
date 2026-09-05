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
import compiler.ir.Ir.IrProgram;
import compiler.ir.Ir.IrType;
import compiler.ir.Ir.IrNative;
import compiler.ir.Ir.IrObject;
import compiler.ir.Ir.IrInterface;
import compiler.ir.Ir.IrEnum;
import compiler.ir.Ir.IrStaticField;

/** Lowers typed syntax to a mutable-local CFG; SsaBuilder owns all SSA policy. */
class IrGenerator {
	public static function generate(typed:TypedProgram):IrProgram {
		return assemble([for (fn in typed.functions) generateFunction(fn)], null, objectsFrom(typed), interfacesFrom(typed), enumsFrom(typed),
			staticFieldsFrom(typed), staticInitializerFrom(typed));
	}

	/** Build the module boot function from static field initializers. */
	public static function staticInitializerFrom(typed:TypedProgram, ?classOrder:Array<String>):Null<IrFunction> {
		var statements:Array<TypedStatement> = [], firstSpan = null;
		var classes = orderedClasses(typed.classes, classOrder);
		for (classDecl in classes)
			for (field in classDecl.fields)
				if (field.isStatic && field.initializer != null) {
					if (firstSpan == null)
						firstSpan = field.span;
					statements.push(TStaticFieldAssign(classDecl.name, field.name, field.initializer, field.span));
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
			span: firstSpan
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
			var classDecl = byName.get(name);
			if (classDecl != null) {
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
		var objects:Array<IrObject> = [
			for (classDecl in typed.classes)
				{
					name: classDecl.name,
					base: classDecl.base,
					interfaces: classDecl.interfaces,
					fields: [
						for (field in classDecl.fields)
							if (!field.isStatic) {name: field.name, type: lowerType(field.type)}
					],
					methods: [
						for (method in classDecl.methods)
							if (!method.isStatic && !method.isConstructor) {
								name: method.name.substr(method.name.lastIndexOf(".") + 1),
								functionName: method.name
							}
					]
				}
		];
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

	public static function generateFunction(fn:TypedFunction):IrFunction
		return SsaBuilder.build(generateCfg(fn));

	public static function generateCfg(fn:TypedFunction):CfgFunction {
		var builder = new CfgBuilder(), localTypes:Map<String, IrType> = [];
		for (name => cellClass in fn.cells) {
			var cellType = Obj(cellClass);
			localTypes.set('__cell:$name', cellType);
			localTypes.set('$' + 'cell:$name', cellType);
		}
		for (name => cellClass in fn.cellCaptures)
			localTypes.set('__capturecell:$name', Obj(cellClass));
		var arguments = [
			for (argument in implicitArguments(fn)) {
				localTypes.set(argument.name, argument.type);
				{name: argument.name, type: argument.type};
			}
		];
		arguments = arguments.concat([
			for (argument in fn.arguments) {
				var type = lowerType(argument.type);
				localTypes.set(argument.name, type);
				{name: argument.name, type: type};
			}
		]);
		for (name => cellClass in fn.cells)
			for (argument in arguments)
				if (argument.name == name) {
					var cell = builder.newObject(cellClass);
					builder.fieldSet(cell, "value", builder.load(name, localTypes.get(name)));
					builder.store('$' + 'cell:$name', cell);
				}
		lowerStatements(fn.statements, builder, localTypes);
		if (!builder.isTerminated()) {
			if (lowerType(fn.result) == Void)
				builder.returnVoid();
			else
				throw 'Function ${fn.name} does not return on every path';
		}
		return new CfgFunction(fn.name, arguments, lowerType(fn.result), builder.blocks, localTypes);
	}

	public static function assemble(functions:Array<IrFunction>, ?natives:Array<IrNative>, ?objects:Array<IrObject>, ?interfaces:Array<IrInterface>,
			?enums:Array<IrEnum>, ?staticFields:Array<IrStaticField>, ?staticInitializer:IrFunction):IrProgram {
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
								|| name == "__string_substring")
								needsStringRuntime = true;
							if (StringTools.startsWith(name, "__map_")) {
								var operationStart = name.lastIndexOf("_");
								if (operationStart > 0)
									mapRuntimeNames.set(name.substr(2, operationStart - 2), true);
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
			for (entry in [
				{name: "i32", type: I32},
				{name: "f64", type: F64},
				{name: "bytes", type: Bytes},
				{name: "bool", type: Bool},
				{name: "ref", type: Dyn}
			]) {
				var arrayType = Array(entry.type);
				program.natives.push({
					name: '__array_copy_${entry.name}',
					library: "realtime_runtime",
					symbol: '__array_copy_${entry.name}',
					arguments: [arrayType],
					result: arrayType
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
			var mapType = Abstract(mapName),
				keyIrType = lowerType(keyType),
				valueIrType = isReferenceMap ? Dyn : lowerType(valueType);
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
		if (natives != null)
			for (native in natives)
				program.natives.push(native);
		var allFunctions = functions.copy();
		if (staticInitializer != null)
			allFunctions.unshift(staticInitializer);
		for (fn in allFunctions)
			program.functions.push(fn);
		var entry = new IrBuilder();
		if (staticInitializer != null)
			entry.call("__init", [], Void);
		var result = entry.call("main", [], I32);
		var exited = entry.call("__exit", [result], Void);
		entry.returnValue(exited);
		program.functions.push(new IrFunction("__entry", [], Void, entry.blocks));
		return program;
	}

	static function lowerStatements(statements:Array<TypedStatement>, builder:CfgBuilder, localTypes:Map<String, IrType>, ?loops:Array<{
		breakBlock:CfgBlock,
		continueBlock:CfgBlock,
		breakFlag:String,
		trapDepth:Int
	}>):Void {
		if (loops == null)
			loops = [];
		for (statement in statements) {
			if (builder.isTerminated())
				break;
			switch statement {
				case TDeclare(name, type, _):
					localTypes.set(name, lowerType(type));
				case TVar(name, initializer, _):
					var value = lowerExpression(initializer, builder, localTypes),
						cellType = localTypes.get('__cell:$name');
					if (cellType == null) {
						localTypes.set(name, lowerType(initializer.type));
						builder.store(name, value);
					} else {
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
					builder.fieldSet(builder.load('$' + 'cell:$name', Obj(cellClass)), "value", lowerExpression(value, builder, localTypes));
				case TCellCapturedAssign(name, cellClass, value, _):
					var owner = localTypes.get("this");
					if (owner == null)
						throw 'Captured assignment "$name" has no environment';
					var cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass));
					builder.fieldSet(cell, "value", lowerExpression(value, builder, localTypes));
				case TFieldAssign(object, name, value, _):
					builder.fieldSet(lowerExpression(object, builder, localTypes), name, lowerExpression(value, builder, localTypes));
				case TStaticFieldAssign(name, field, value, _):
					builder.globalSet(name + "." + field, lowerExpression(value, builder, localTypes));
				case TIndexAssign(array, index, value, _):
					builder.arraySet(lowerExpression(array, builder, localTypes), lowerExpression(index, builder, localTypes),
						lowerExpression(value, builder, localTypes));
				case TMapAssign(map, key, value, _):
					var mapType = switch map.type {
						case TMap(keyType, valueType): {key: keyType, value: valueType};
						default: throw "Map assignment requires a map value";
					};
					lowerExpression(new TypedExpression(TCall(RuntimeType.mapNative(mapType.key, mapType.value, "set"), [map, key, value]), TVoid, map.span),
						builder, localTypes);
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
					localTypes.set(exceptionLocal, Dyn);
					builder.store(exceptionLocal, exception);
					for (i in 0...catches.length) {
						var catchClause = catches[i],
							catchIrType = lowerType(catchClause.type),
							nextDispatch:CfgBlock = null;
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
					var type = localTypes.get(name);
					if (type == null)
						throw 'Missing increment local "$name"';
					var one = type == I32 ? builder.constInt(1) : builder.constFloat(1);
					builder.store(name, delta > 0 ? builder.add(builder.load(name, type), one) : builder.sub(builder.load(name, type), one));
				case TCellIncrement(name, cellClass, valueType, delta, _):
					var cell = builder.load('$' + 'cell:$name', Obj(cellClass)),
						value = builder.fieldGet(cell, "value", lowerType(valueType)),
						one = valueType == TInt ? builder.constInt(1) : builder.constFloat(1);
					builder.fieldSet(cell, "value", delta > 0 ? builder.add(value, one) : builder.sub(value, one));
				case TCellCapturedIncrement(name, cellClass, valueType, delta, _):
					var owner = localTypes.get("this");
					if (owner == null)
						throw 'Captured increment "$name" has no environment';
					var cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass)),
						value = builder.fieldGet(cell, "value", lowerType(valueType)),
						one = valueType == TInt ? builder.constInt(1) : builder.constFloat(1);
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
					var breakFlag = '$' + 'while-break:' + span.start;
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
				case TDoWhile(body, condition, span):
					var breakFlag = '$' + 'do-while-break:' + span.start;
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
				case TForIn(name, iterable, body, span):
					var arrayName = '$' + 'for-array:' + span.start,
						indexName = '$' + 'for-index:' + span.start,
						breakFlag = '$' + 'for-break:' + span.start,
						arrayType = lowerType(iterable.type),
						elementType = switch iterable.type {
							case TArray(element): lowerType(element);
							default: throw 'For-in iterable is not an array';
						};
					localTypes.set(arrayName, arrayType);
					localTypes.set(indexName, I32);
					localTypes.set(breakFlag, Bool);
					localTypes.set(name, elementType);
					builder.store(arrayName, lowerExpression(iterable, builder, localTypes));
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
					var switchName = '$' + 'switch:' + span.start,
						switchType = lowerType(expression.type),
						exits:Array<CfgBlock> = [];
					localTypes.set(switchName, switchType);
					builder.store(switchName, lowerExpression(expression, builder, localTypes));
					var checkBlock = builder.currentBlock();
					for (switchCase in cases) {
						var bodyBlock = builder.createBlock(),
							nextBlock = builder.createBlock();
						builder.select(checkBlock);
						var switchValue = switch expression.type {
							case TEnum(_): builder.enumIndex(builder.load(switchName, switchType));
							default: builder.load(switchName, switchType);
						}, caseValue = switchCase.constructorIndex >= 0 ? builder.constInt(switchCase.constructorIndex) : lowerExpression(switchCase.value,
							builder, localTypes);
						builder.branch(builder.equal(switchValue, caseValue), bodyBlock, nextBlock);
						builder.select(bodyBlock);
						if (switchCase.constructorIndex >= 0)
							for (binding in switchCase.bindings) {
								localTypes.set(binding.name, lowerType(binding.type));
							}
						for (binding in switchCase.bindings)
							builder.store(binding.name,
								builder.enumField(builder.load(switchName, switchType), switchCase.constructorIndex, binding.index, lowerType(binding.type)));
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
		return cases.length > 0 && [for (switchCase in cases) switchCase.constructorIndex >= 0].indexOf(false) < 0;
	}

	static function lowerExpression(expression:TypedExpression, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue
		return switch expression.expression {
			case TIntLiteral(value): builder.constInt(value);
			case TFloatLiteral(value): builder.constFloat(value);
			case TStringLiteral(value): builder.constString(value);
			case TBoolLiteral(value): builder.constBool(value);
			case TEnumLiteral(name, index): builder.makeEnum(name, index, []);
			case TEnumConstruct(name, index,
				arguments): builder.makeEnum(name, index, [for (argument in arguments) lowerExpression(argument, builder, localTypes)]);
			case TNullLiteral: throw "Uncoerced null literal";
			case TClassRef(_): throw "Class references are only valid for static members";
			case TStaticField(name, field): builder.globalGet(name + "." + field, lowerType(expression.type));
			case TNullableWrap(value):
				switch value.expression {
					case TNullLiteral: builder.constNull(lowerType(expression.type));
					default: lowerExpression(value, builder, localTypes);
				}
			case TToDynamic(value): builder.toDyn(lowerExpression(value, builder, localTypes));
			case TLocal(name):
				var type = localTypes.get(name);
				if (type == null)
					throw 'Missing typed local "$name"';
				builder.load(name, type);
			case TCellLocal(name, cellClass):
				var cell = builder.load('$' + 'cell:$name', Obj(cellClass));
				builder.fieldGet(cell, "value", lowerType(expression.type));
			case TCaptured(name):
				var owner = localTypes.get("this");
				if (owner == null)
					throw 'Captured value "$name" has no environment';
				builder.fieldGet(builder.load("this", owner), name, lowerType(expression.type));
			case TCellCaptured(name, cellClass):
				var owner = localTypes.get("this");
				if (owner == null)
					throw 'Captured value "$name" has no environment';
				var cell = builder.fieldGet(builder.load("this", owner), name, Obj(cellClass));
				builder.fieldGet(cell, "value", lowerType(expression.type));
			case TFunctionRef(name): builder.staticClosure(name, lowerType(expression.type));
			case TLambda(name, environment, captures):
				if (environment == null) builder.staticClosure(name, lowerType(expression.type)); else {
					var object = builder.newObject(environment);
					for (capture in captures) {
						var cellType = localTypes.get('__cell:$capture');
						var capturedCellType = localTypes.get('__capturecell:$capture');
						var value = cellType == null ? (capturedCellType == null ? builder.load(capture,
							localTypes.get(capture)) : builder.fieldGet(builder.load("this", localTypes.get("this")), capture,
								capturedCellType)) : builder.load('$' + 'cell:$capture', cellType);
						builder.fieldSet(object, capture, value);
					}
					builder.instanceClosure(name, object, lowerType(expression.type));
				}
			case TAdd(a, b):
				var left = lowerExpression(a, builder, localTypes),
					right = lowerExpression(b, builder, localTypes);
				lowerType(expression.type) == Bytes ? builder.call("__string_concat", [left, right], Bytes) : builder.add(left, right);
			case TSub(a, b): builder.sub(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TMul(a, b): builder.mul(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TDiv(a, b): builder.div(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TMod(a, b): builder.mod(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TNegate(value):
				var typed = lowerExpression(value, builder, localTypes);
				value.type == TInt ? builder.sub(builder.constInt(0), typed) : builder.sub(builder.constFloat(0), typed);
			case TLess(a, b): builder.less(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TLessEqual(a, b): builder.lessEqual(lowerExpression(a, builder, localTypes), lowerExpression(b, builder, localTypes));
			case TNot(value): builder.equal(lowerExpression(value, builder, localTypes), builder.constBool(false));
			case TAnd(left, right): lowerLogical(left, right, true, builder, localTypes);
			case TOr(left, right): lowerLogical(left, right, false, builder, localTypes);
			case TEqual(a, b):
				var left = lowerExpression(a, builder, localTypes),
					right = lowerExpression(b, builder, localTypes);
				var isEnum = switch a.type {
					case TEnum(_): true;
					default: false;
				};
				if (isEnum) {
					left = builder.enumIndex(left);
					right = builder.enumIndex(right);
				}
				lowerType(a.type) == Bytes ? builder.call("__string_equal", [left, right], Bool) : builder.equal(left, right);
			case TCall(name, args): builder.call(name, [for (arg in args) lowerExpression(arg, builder, localTypes)], lowerType(expression.type));
			case TCollectionCall(receiver, operation, args):
				var nativeName = switch receiver.type {
					case TArray(element): RuntimeType.arrayNative(element, operation);
					case TMap(key, value): RuntimeType.mapNative(key, value, operation);
					default: throw "Collection operation requires an Array or Map receiver";
				};
				builder.call(nativeName, [lowerExpression(receiver, builder, localTypes)].concat([
					for (arg in args)
						lowerExpression(arg, builder, localTypes)
				]), lowerType(expression.type));
			case TConditional(condition, whenTrue, whenFalse):
				var yesBlock = builder.createBlock(),
					noBlock = builder.createBlock(),
					afterBlock = builder.createBlock(),
					localName = '$' + 'conditional:${expression.span.start}:${afterBlock.id}',
					resultType = lowerType(expression.type);
				localTypes.set(localName, resultType);
				builder.branch(lowerExpression(condition, builder, localTypes), yesBlock, noBlock);
				builder.select(yesBlock);
				builder.store(localName, lowerExpression(whenTrue, builder, localTypes));
				builder.jump(afterBlock);
				builder.select(noBlock);
				builder.store(localName, lowerExpression(whenFalse, builder, localTypes));
				builder.jump(afterBlock);
				builder.select(afterBlock);
				builder.load(localName, resultType);
			case TBlockExpression(statements, result):
				lowerStatements(statements, builder, localTypes, []);
				lowerExpression(result, builder, localTypes);
			case TSwitchExpression(subject, cases, defaultExpression):
				var subjectName = '$' + 'switch-expression-subject:${expression.span.start}',
					resultName = '$' + 'switch-expression-result:${expression.span.start}',
					subjectType = lowerType(subject.type),
					resultType = lowerType(expression.type),
					entryBlock = builder.currentBlock(),
					bodyBlocks = [],
					checkBlocks = [entryBlock];
				for (caseIndex in 0...cases.length) {
					bodyBlocks.push(builder.createBlock());
					if (caseIndex + 1 < cases.length)
						checkBlocks.push(builder.createBlock());
				}
				var fallbackBlock = defaultExpression == null ? null : builder.createBlock(),
					afterBlock = builder.createBlock();
				builder.select(entryBlock);
				localTypes.set(subjectName, subjectType);
				localTypes.set(resultName, resultType);
				builder.store(subjectName, lowerExpression(subject, builder, localTypes));
				for (caseIndex in 0...cases.length) {
					var switchCase = cases[caseIndex],
						isExhaustiveFinalCase = defaultExpression == null && caseIndex == cases.length - 1,
						bodyBlock = bodyBlocks[caseIndex],
						nextBlock = caseIndex + 1 < cases.length ? checkBlocks[caseIndex + 1] : fallbackBlock;
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
					if (isExhaustiveFinalCase)
						builder.jump(bodyBlock);
					else
						builder.branch(matches, bodyBlock, nextBlock);
					builder.select(bodyBlock);
					for (binding in switchCase.bindings) {
						localTypes.set(binding.name, lowerType(binding.type));
						builder.store(binding.name,
							builder.enumField(builder.load(subjectName, subjectType), switchCase.constructorIndex, binding.index, lowerType(binding.type)));
					}
					builder.store(resultName, lowerExpression(switchCase.result, builder, localTypes));
					builder.jump(afterBlock);
				}
				if (defaultExpression != null) {
					builder.select(fallbackBlock);
					builder.store(resultName, lowerExpression(defaultExpression, builder, localTypes));
					builder.jump(afterBlock);
				}
				builder.select(afterBlock);
				builder.load(resultName, resultType);
			case TClosureCall(callee, args):
				builder.callClosure(lowerExpression(callee, builder, localTypes), [for (arg in args) lowerExpression(arg, builder, localTypes)],
					lowerType(expression.type));
			case TToInterface(value, name):
				builder.toVirtual(lowerExpression(value, builder, localTypes), Virtual(name));
			case TNew(typeName, args, hasConstructor):
				var object = builder.newObject(typeName);
				if (hasConstructor) {
					var constructorArgs = [object];
					for (arg in args)
						constructorArgs.push(lowerExpression(arg, builder, localTypes));
					builder.call('$typeName.new', constructorArgs, Void);
				}
				object;
			case TObjectLiteral(typeName, fields):
				var object = builder.newObject(typeName);
				for (field in fields)
					builder.fieldSet(object, field.name, lowerExpression(field.value, builder, localTypes));
				object;
			case TArrayLiteral(values):
				var element = switch expression.type {
					case TArray(element): element;
					default: throw "Array literal requires an array type";
				}, array = builder.call(arrayAllocatorName(element), [builder.constInt(values.length)], Array(lowerType(element)));
				for (index in 0...values.length)
					builder.arraySet(array, builder.constInt(index), lowerExpression(values[index], builder, localTypes));
				array;
			case TNewArray(element, length):
				builder.call(arrayAllocatorName(element), [lowerExpression(length, builder, localTypes)], Array(lowerType(element)));
			case TNewMap(key, value): builder.call(RuntimeType.mapNative(key, value, "alloc"), [], Abstract(RuntimeType.mapName(key, value)));
			case TField(object, name): builder.fieldGet(lowerExpression(object, builder, localTypes), name, lowerType(expression.type));
			case TMethodCall(object, name, args):
				var receiver = lowerExpression(object, builder, localTypes),
					callArgs = [for (arg in args) lowerExpression(arg, builder, localTypes)];
				builder.methodCall(receiver, name.substr(name.lastIndexOf(".") + 1), callArgs, lowerType(expression.type));
			case TIndex(array, index):
				builder.arrayGet(lowerExpression(array, builder, localTypes), lowerExpression(index, builder, localTypes), lowerType(expression.type));
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
				var owner = localTypes.get("this");
				if (owner == null)
					throw 'Captured increment "$name" has no environment';
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
				builder.call(RuntimeType.mapNative(mapType.key, mapType.value, "get"), [
					lowerExpression(map, builder, localTypes),
					lowerExpression(key, builder, localTypes)
				], lowerType(expression.type));
			case TArrayLength(array):
				builder.arraySize(lowerExpression(array, builder, localTypes));
			case TStringLength(value):
				builder.call("__string_length", [lowerExpression(value, builder, localTypes)], I32);
			case TStringIndexOf(value, needle):
				builder.call("__string_index_of", [
					lowerExpression(value, builder, localTypes),
					lowerExpression(needle, builder, localTypes)
				], I32);
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
				}, pushed = builder.call(RuntimeType.arrayNative(element, "push"), [
					lowerExpression(array, builder, localTypes),
					lowerExpression(value, builder, localTypes)
					], Array(lowerType(element)));
				switch array.expression {
					case TLocal(name): builder.store(name, pushed);
					case TField(object, name): builder.fieldSet(lowerExpression(object, builder, localTypes), name, pushed);
					default: throw "Array.push requires a mutable local or field array";
				}
				builder.arraySize(pushed);
			case TArrayPop(array):
				var element = switch array.type {
					case TArray(valueType): valueType;
					default: throw "Array.pop requires an array value";
				};
				builder.call(RuntimeType.arrayNative(element, "pop"), [lowerExpression(array, builder, localTypes)], lowerType(element));
		}

	static function implicitArguments(fn:TypedFunction):Array<{name:String, type:IrType}> {
		if (fn.owner == null || fn.isStatic)
			return [];
		return [{name: "this", type: Obj(fn.owner)}];
	}

	public static function lowerType(type:CompilerType):IrType
		return switch type {
			case TInt: I32;
			case TBool: Bool;
			case TFloat: F64;
			case TString: Bytes;
			case TDynamic: Dyn;
			case TVoid: Void;
			case TClass(name): Obj(name);
			case TMap(key, value): Abstract(RuntimeType.mapName(key, value));
			case TInterface(name): Virtual(name);
			case TEnum(name): Enum(name);
			case TNull: Void;
			case TNullable(element): lowerType(element);
			case TArray(element): Array(lowerType(element));
			case TFunction(arguments, result): Function([for (argument in arguments) lowerType(argument)], lowerType(result));
			case TAnonymous(name, _): Obj(name);
		};

	static function incrementOne(type:CompilerType, builder:CfgBuilder):CfgValue
		return type == TInt ? builder.constInt(1) : builder.constFloat(1);

	static function lowerLogical(left:TypedExpression, right:TypedExpression, and:Bool, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue {
		var resultName = '$' + 'logical:' + left.span.start + ':' + right.span.end;
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
		return switch element {
			case TInt: "__array_alloc_i32";
			case TFloat: "__array_alloc_f64";
			case TString: "__array_alloc_bytes";
			case TBool: "__array_alloc_bool";
			case TClass(_), TInterface(_), TArray(_), TFunction(_): "__array_alloc_ref";
			default: throw "Compiler-owned allocation currently supports primitive and reference arrays";
		};
}

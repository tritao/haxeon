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

/** Lowers typed syntax to a mutable-local CFG; SsaBuilder owns all SSA policy. */
class IrGenerator {
	public static function generate(typed:TypedProgram):IrProgram {
		return assemble([for (fn in typed.functions) generateFunction(fn)], null, objectsFrom(typed), interfacesFrom(typed), enumsFrom(typed));
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
		return [
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
	}

	public static function generateFunction(fn:TypedFunction):IrFunction
		return SsaBuilder.build(generateCfg(fn));

	public static function generateCfg(fn:TypedFunction):CfgFunction {
		var builder = new CfgBuilder(), localTypes:Map<String, IrType> = [];
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
			?enums:Array<IrEnum>):IrProgram {
		var program = new IrProgram("__entry");
		var needsArrayRuntime = false,
			needsStringRuntime = false,
			mapRuntimeNames:Map<String, Bool> = [];
		for (fn in functions)
			for (block in fn.blocks)
				for (instruction in block.instructions)
					switch instruction {
						case Call(_, name, _):
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
		program.natives.push({
			name: "__exit",
			library: "std",
			symbol: "sys_exit",
			arguments: [I32],
			result: Void
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
			if (valueType == null)
				throw 'Unknown compiler map ABI "$mapName"';
			var keyType = RuntimeType.mapKeyType(mapName);
			if (keyType == null)
				throw 'Unknown compiler map key ABI "$mapName"';
			var mapType = Abstract(mapName),
				keyIrType = lowerType(keyType),
				valueIrType = lowerType(valueType);
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
		for (fn in functions)
			program.functions.push(fn);
		var entry = new IrBuilder();
		var result = entry.call("main", [], I32);
		var exited = entry.call("__exit", [result], Void);
		entry.returnValue(exited);
		program.functions.push(new IrFunction("__entry", [], Void, entry.blocks));
		return program;
	}

	static function lowerStatements(statements:Array<TypedStatement>, builder:CfgBuilder, localTypes:Map<String, IrType>,
			?loops:Array<{breakBlock:CfgBlock, continueBlock:CfgBlock, breakFlag:String}>):Void {
		if (loops == null)
			loops = [];
		for (statement in statements) {
			if (builder.isTerminated())
				break;
			switch statement {
				case TVar(name, initializer, _):
					localTypes.set(name, lowerType(initializer.type));
					builder.store(name, lowerExpression(initializer, builder, localTypes));
				case TAssign(name, value, _):
					builder.store(name, lowerExpression(value, builder, localTypes));
				case TFieldAssign(object, name, value, _):
					builder.fieldSet(lowerExpression(object, builder, localTypes), name, lowerExpression(value, builder, localTypes));
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
					builder.returnValue(lowerExpression(expression, builder, localTypes));
				case TReturnVoid(_):
					builder.returnVoid();
				case TBreak(_):
					if (loops.length == 0)
						throw "break outside loop";
					var loop = loops[loops.length - 1];
					builder.store(loop.breakFlag, builder.constBool(true));
					builder.jump(loop.continueBlock);
				case TContinue(_):
					if (loops.length == 0)
						throw "continue outside loop";
					builder.jump(loops[loops.length - 1].continueBlock);
				case TIncrement(name, delta, _):
					var type = localTypes.get(name);
					if (type == null)
						throw 'Missing increment local "$name"';
					var one = type == I32 ? builder.constInt(1) : builder.constFloat(1);
					builder.store(name, delta > 0 ? builder.add(builder.load(name, type), one) : builder.sub(builder.load(name, type), one));
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
					loops.push({breakBlock: afterBlock, continueBlock: conditionBlock, breakFlag: breakFlag});
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
					loops.push({breakBlock: afterBlock, continueBlock: conditionBlock, breakFlag: breakFlag});
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
							for (binding in switchCase.bindings)
								localTypes.set(binding.name, lowerType(binding.type));
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
			case TNullableWrap(value):
				switch value.expression {
					case TNullLiteral: builder.constNull(lowerType(expression.type));
					default: lowerExpression(value, builder, localTypes);
				}
			case TLocal(name):
				var type = localTypes.get(name);
				if (type == null)
					throw 'Missing typed local "$name"';
				builder.load(name, type);
			case TCaptured(name):
				var owner = localTypes.get("this");
				if (owner == null)
					throw 'Captured value "$name" has no environment';
				builder.fieldGet(builder.load("this", owner), name, lowerType(expression.type));
			case TFunctionRef(name): builder.staticClosure(name, lowerType(expression.type));
			case TLambda(name, environment, captures):
				if (environment == null) builder.staticClosure(name, lowerType(expression.type)); else {
					var object = builder.newObject(environment);
					for (capture in captures)
						builder.fieldSet(object, capture, builder.load(capture, localTypes.get(capture)));
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
			case TVoid: Void;
			case TClass(name): Obj(name);
			case TMap(key, value): Abstract(RuntimeType.mapName(key, value));
			case TInterface(name): Virtual(name);
			case TEnum(name): Enum(name);
			case TNull: Void;
			case TNullable(element): lowerType(element);
			case TArray(element): Array(lowerType(element));
			case TFunction(arguments, result): Function([for (argument in arguments) lowerType(argument)], lowerType(result));
		};

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

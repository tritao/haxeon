package compiler.ir;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypeRelations;
import compiler.runtime.RuntimeType;
import compiler.types.analysis.ControlFlow;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedProgram;
import compiler.types.TypedAst.TypedFunction;
import compiler.types.TypedAst.TypedStatement;
import compiler.types.TypedAst.TypedSwitchCase;
import compiler.types.TypedAst.TypedSwitchPredicate;
import compiler.types.TypedAst.TypedCaptureSource;
import compiler.ir.cfg.Cfg.CfgFunction;
import compiler.ir.cfg.Cfg.CfgBlock;
import compiler.ir.cfg.Cfg.CfgValue;
import compiler.ir.cfg.Cfg.CfgArgument;
import compiler.ir.cfg.CfgBuilder;
import compiler.ir.cfg.SsaBuilder;
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
	public static function generate(typed:TypedProgram):IrProgram
		return IrProgramAssembler.generate(typed);

	public static function staticInitializerFrom(typed:TypedProgram, ?classOrder:Array<String>):Null<IrFunction>
		return IrProgramAssembler.staticInitializerFrom(typed, classOrder);

	public static function enumsFrom(typed:TypedProgram):Array<IrEnum>
		return IrProgramAssembler.enumsFrom(typed);

	public static function interfacesFrom(typed:TypedProgram):Array<IrInterface>
		return IrProgramAssembler.interfacesFrom(typed);

	public static function objectsFrom(typed:TypedProgram):Array<IrObject>
		return IrProgramAssembler.objectsFrom(typed);

	public static function staticFieldsFrom(typed:TypedProgram):Array<IrStaticField>
		return IrProgramAssembler.staticFieldsFrom(typed);

	public static function assemble(functions:Array<IrFunction>, ?natives:Array<IrNative>, ?objects:Array<IrObject>, ?interfaces:Array<IrInterface>,
			?enums:Array<IrEnum>, ?staticFields:Array<IrStaticField>, ?staticInitializer:IrFunction, ?entryPoint:String):IrProgram
		return IrProgramAssembler.assemble(functions, natives, objects, interfaces, enums, staticFields, staticInitializer, entryPoint);

	static function lastSeparator(value:String):Int {
		var index = value.length - 1;
		while (index >= 0 && value.charCodeAt(index) != 46)
			index--;
		return index;
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
			builder.debugLocal(argument.name, fn.span, fn.span.end);
		}
		for (name => cellClass in fn.cells)
			for (argument in arguments)
				if (argument.name == name) {
					var cell = builder.newObject(cellClass);
					builder.fieldSet(cell, "value", builder.load(name, localTypes.get(name)));
					builder.store('$' + 'cell:$name', cell);
				}
		lowerStatements(fn.statements, builder, localTypes, [], fn.span.end);
		if (!builder.isTerminated()) {
			if (lowerType(fn.result) == Void)
				builder.returnVoid();
			else
				throw 'Function ${fn.name} does not return on every path';
		}
		return new CfgFunction(fn.name, arguments, lowerType(fn.result), builder.blocks, localTypes, builder.valueCount(), builder.debugLocals);
	}

	static function lowerStatements(statements:Array<TypedStatement>, builder:CfgBuilder, localTypes:Map<String, IrType>, loops:Array<LoopContext>,
			scopeEnd:Int):Void {
		for (statement in statements) {
			if (builder.isTerminated())
				break;
			builder.at(typedStatementSpan(statement));
			switch statement {
				case TDeclare(name, type, span):
					localTypes.set(name, lowerType(type));
					builder.debugLocal(name, span, scopeEnd);
				case TVar(name, initializer, span):
					builder.debugLocal(name, span, scopeEnd);
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
				case TTry(tryBranch, catches, span):
					var catchBlock = builder.createBlock(),
						afterBlock = builder.createBlock();
					builder.beginTry(catchBlock, afterBlock);
					lowerStatements(tryBranch, builder, localTypes, loops, statementsScopeEnd(tryBranch, span.end));
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
						builder.debugLocal(catchClause.name, catchClause.span, catchClause.span.end);
						var caught = builder.load(exceptionLocal, Dyn);
						builder.store(catchClause.name, catchClause.type == TDynamic ? caught : builder.safeCast(caught, catchIrType));
						lowerStatements(catchClause.statements, builder, localTypes, loops, catchClause.span.end);
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
				case TIf(condition, thenBranch, elseBranch, span):
					var conditionValue = lowerExpression(condition, builder, localTypes),
						thenBlock = builder.createBlock(),
						elseBlock = builder.createBlock();
					builder.branch(conditionValue, thenBlock, elseBlock);
					builder.select(thenBlock);
					lowerStatements(thenBranch, builder, localTypes, loops, statementsScopeEnd(thenBranch, span.end));
					var thenActive = !builder.isTerminated(),
						thenExit = builder.currentBlock();
					builder.select(elseBlock);
					lowerStatements(elseBranch, builder, localTypes, loops, statementsScopeEnd(elseBranch, span.end));
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
					var infinite = ControlFlow.isInfiniteLoop(condition, body);
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
					lowerStatements(body, builder, localTypes, loops, statementsScopeEnd(body, span.end));
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
					lowerStatements(body, builder, localTypes, loops, statementsScopeEnd(body, span.end));
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
					lowerStatements(body, builder, localTypes, loops, statementsScopeEnd(body, span.end));
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
					builder.debugLocal(name, span, statementsScopeEnd(body, span.end));
					if (valueName == null)
						builder.store(arrayName, lowerExpression(iterable, builder, localTypes));
					else {
						var loweredMapType = lowerType(iterable.type);
						localTypes.set(mapName, loweredMapType);
						localTypes.set(valueName, lowerType(mapValue));
						builder.debugLocal(valueName, span, statementsScopeEnd(body, span.end));
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
					lowerStatements(body, builder, localTypes, loops, statementsScopeEnd(body, span.end));
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
						var subjectValue = builder.load(switchName, switchType);
						if (isNullableEnumType(expression.type) && switchCase.constructorIndex >= 0) {
							var nonNullBlock = builder.createBlock();
							builder.branch(builder.equal(subjectValue, builder.constNull(switchType)), nextBlock, nonNullBlock);
							builder.select(nonNullBlock);
							subjectValue = builder.load(switchName, switchType);
						}
						var switchValue = switchCase.constructorIndex >= 0
							&& isEnumType(expression.type) ? builder.enumIndex(subjectValue) : subjectValue,
							caseValue = switchCase.constructorIndex >= 0 ? builder.constInt(switchCase.constructorIndex) : lowerExpression(switchCase.value,
								builder, localTypes);
						var predicateBlock = switchCase.predicates.length == 0 ? matchBlock : builder.createBlock();
						builder.branch(builder.equal(switchValue, caseValue), predicateBlock, nextBlock);
						if (switchCase.predicates.length > 0)
							lowerEnumPredicates(switchName, switchType, switchCase.constructorIndex, switchCase.predicates, predicateBlock, matchBlock,
								nextBlock, builder, localTypes);
						builder.select(matchBlock);
						if (switchCase.constructorIndex >= 0)
							for (binding in switchCase.bindings) {
								localTypes.set(binding.name, lowerType(binding.type));
								builder.debugLocal(binding.name, switchCase.span, switchCase.span.end);
							}
						for (binding in switchCase.bindings)
							builder.store(binding.name,
								abiBoundaryCast(builder,
									builder.enumField(builder.load(switchName, switchType), switchCase.constructorIndex, binding.index,
										lowerType(binding.storageType)),
									lowerType(binding.type)));
						var guard = switchCase.guard;
						if (guard != null) {
							builder.branch(lowerExpression(guard, builder, localTypes), bodyBlock, nextBlock);
							builder.select(bodyBlock);
						}
						lowerStatements(switchCase.statements, builder, localTypes, loops, switchCase.span.end);
						if (!builder.isTerminated())
							exits.push(builder.currentBlock());
						checkBlock = nextBlock;
					}
					builder.select(checkBlock);
					if (!hasDefault && isEnumType(expression.type))
						builder.markUnreachable();
					else
						lowerStatements(defaultBranch, builder, localTypes, loops, statementsScopeEnd(defaultBranch, span.end));
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

	static function typedStatementSpan(statement:TypedStatement):compiler.Source.SourceSpan
		return switch statement {
			case TDeclare(_, _, span), TVar(_, _, span), TAssign(_, _, span), TCellAssign(_, _, _, span), TCellCapturedAssign(_, _, _, span),
				TFieldAssign(_, _, _, span), TStaticFieldAssign(_, _, _, span), TIndexAssign(_, _, _, span), TMapAssign(_, _, _, span), TReturn(_, span),
				TReturnVoid(span), TThrow(_, span), TTry(_, _, span), TIf(_, _, _, span), TWhile(_, _, span), TDoWhile(_, _, span), TForIn(_, _, _, _, span),
				TBreak(span), TContinue(span), TSwitch(_, _, _, _, span), TIncrement(_, _, span), TCellIncrement(_, _, _, _, span),
				TCellCapturedIncrement(_, _, _, _, span), TExpression(_, span):
				span;
		};

	static function statementsScopeEnd(statements:Array<TypedStatement>, fallback:Int):Int
		return statements.length == 0 ? fallback : typedStatementSpan(statements[statements.length - 1]).end;

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
		var name = RuntimeType.requireMapName(keyType, valueType),
			target = lowerType(valueType);
		var value = builder.call('__${name}_get', [map, key], StringTools.endsWith(name, "_ref") ? Dyn : target);
		return abiBoundaryCast(builder, value, target);
	}

	static function lowerMapSet(builder:CfgBuilder, map:CfgValue, key:CfgValue, value:CfgValue, keyType:CompilerType, valueType:CompilerType):CfgValue {
		var name = RuntimeType.requireMapName(keyType, valueType);
		var stored = StringTools.endsWith(name, "_ref") && requiresDynamicBox(value.type) ? abiBoundaryCast(builder, value, Dyn) : value;
		return builder.call('__${name}_set', [map, key, stored], Void);
	}

	/**
	 * Values whose HashLink representation does not begin with an `hl_type *`
	 * must be boxed before crossing a native `_DYN` parameter. GC-managed
	 * references already have the dynamic header and must retain their identity.
	 */
	static function requiresDynamicBox(type:IrType):Bool
		return switch type {
			case Abstract(_), Bytes, TypeRef: true;
			default: false;
		};

	static function abiBoundaryCast(builder:CfgBuilder, value:CfgValue, target:IrType):CfgValue {
		if (sameIrType(value.type, target))
			return value;
		if (target == Dyn)
			return builder.toDyn(value);
		if (value.type == Dyn)
			return builder.safeCast(value, target);
		throw 'Unsupported ABI boundary cast from ${value.type} to $target';
	}

	static function referenceResultCast(builder:CfgBuilder, value:CfgValue, target:IrType):CfgValue {
		if (sameIrType(value.type, target))
			return value;
		return abiBoundaryCast(builder, value.type == Dyn ? value : builder.toDyn(value), target);
	}

	static function sameIrType(left:IrType, right:IrType):Bool
		return switch left {
			case Obj(name): switch right {
					case Obj(other): name == other;
					default: false;
				};
			case Enum(name): switch right {
					case Enum(other): name == other;
					default: false;
				};
			case Abstract(name): switch right {
					case Abstract(other): name == other;
					default: false;
				};
			case Virtual(name): switch right {
					case Virtual(other): name == other;
					default: false;
				};
			case Array(element): switch right {
					case Array(other): sameIrType(element, other);
					default: false;
				};
			case Function(arguments, result): switch right {
					case Function(otherArguments, otherResult):
						if (arguments.length != otherArguments.length || !sameIrType(result, otherResult)) false; else {
							var same = true;
							for (index in 0...arguments.length)
								if (!sameIrType(arguments[index], otherArguments[index]))
									same = false;
							same;
						}
					default: false;
				};
			default: left == right;
		};

	static function lowerExpression(expression:TypedExpression, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue {
		var previous = builder.enterSource(expression.span);
		try {
			var result = lowerExpressionAt(expression, builder, localTypes);
			builder.restoreSource(previous);
			return result;
		} catch (error:Dynamic) {
			builder.restoreSource(previous);
			throw error;
		}
	}

	static function lowerExpressionAt(expression:TypedExpression, builder:CfgBuilder, localTypes:Map<String, IrType>):CfgValue
		return switch expression.expression {
			case TIntLiteral(value): builder.constInt(value);
			case TFloatLiteral(value): builder.constFloat(value);
			case TStringLiteral(value): builder.constString(value);
			case TBoolLiteral(value): builder.constBool(value);
			case TEnumLiteral(name, index): builder.makeEnum(name, index, []);
			case TEnumConstruct(name, index, arguments): builder.makeEnum(name, index, lowerOperands(arguments, builder, localTypes));
			case TNullLiteral: throw "Uncoerced null literal";
			case TUnreachable:
				var placeholder = unreachableValue(lowerType(expression.type), builder);
				builder.markUnreachable();
				placeholder;
			case TNoReturn(value):
				var lowered = lowerExpression(value, builder, localTypes);
				builder.markUnreachable();
				lowered;
			case TClassRef(_): throw "Class references are only valid for static members";
			case TStaticField(name, field): builder.globalGet(name + "." + field, lowerType(expression.type));
			case TNullableWrap(value):
				switch value.expression {
					case TNullLiteral: builder.constNull(lowerType(expression.type));
					default:
						var lowered = lowerExpression(value, builder, localTypes),
							target = lowerType(expression.type);
						sameIrType(lowered.type, target) ? lowered : abiBoundaryCast(builder, lowered, target);
				}
			case TToDynamic(value): builder.toDyn(lowerExpression(value, builder, localTypes));
			case TLocal(name):
				var type = requireLocalType(localTypes, name, 'Missing typed local "$name"');
				abiBoundaryCast(builder, builder.load(name, type), lowerType(expression.type));
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
			case TMethodRef(object, name): builder.instanceClosure(name, lowerExpression(object, builder, localTypes), lowerType(expression.type));
			case TLambda(name, environment, captures):
				if (environment == null) builder.staticClosure(name, lowerType(expression.type)); else {
					var object = builder.newObject(environment);
					for (capture in captures) {
						var value = switch capture.source {
							case CaptureLocal(bindingId):
								builder.load(bindingId, requireLocalType(localTypes, bindingId, 'Missing captured binding "$bindingId"'));
							case CaptureReceiver:
								builder.load("this", requireLocalType(localTypes, "this", "Captured receiver has no ABI local"));
							case CaptureCellLocal(localName, cellClass):
								builder.load('$' + 'cell:$localName', Obj(cellClass));
							case CaptureEnvironmentField(field):
								builder.fieldGet(builder.load("this", requireLocalType(localTypes, "this", "Capture has no environment")), field,
									lowerType(capture.type));
							case CaptureCellEnvironmentField(field, cellClass):
								builder.fieldGet(builder.load("this", requireLocalType(localTypes, "this", "Capture has no environment")), field,
									Obj(cellClass));
						};
						builder.fieldSet(object, capture.field, value);
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
				if (isNullableEnumExpression(a) || isNullableEnumExpression(b))
					return lowerNullableEnumEquality(a, b, left, right, builder, localTypes);
				var isEnum = isDirectEnumType(a.type) && !isNullExpression(a) && !isNullExpression(b);
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
					case TArray(element): lowerArrayNativeCall(builder, element, operation, lowered, lowerType(expression.type));
					case TMap(key, value) if (operation == "set"): lowerMapSet(builder, lowered[0], lowered[1], lowered[2], key, value);
					default:
						var resultType = lowerType(expression.type);
						builder.call(nativeName, lowered, resultType);
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
				lowerStatements(statements, builder, localTypes, [], expression.span.end);
				if (builder.isTerminated()) placeholder; else lowerExpression(result, builder, localTypes);
			case TThrowExpression(value):
				var placeholder = unreachableValue(lowerType(expression.type), builder);
				builder.throwValue(builder.toDyn(lowerExpression(value, builder, localTypes)));
				placeholder;
			case TCast(value), TAbiCast(value):
				var source = lowerExpression(value, builder, localTypes),
					target = lowerType(expression.type);
				if (sameIrType(source.type,
					target)) source; else if (source.type == Dyn) builder.safeCast(source,
					target); else if (target == Dyn) builder.toDyn(source); else
					throw 'Unsupported cast from ${source.type} to $target at ${expression.span.file.path}:${expression.span.start}';
			case TSwitchExpression(subject, cases, defaultExpression):
				var subjectName = '$' + 'switch-expression-subject:${expression.span.start}',
					resultName = '$' + 'switch-expression-result:${expression.span.start}',
					subjectType = lowerType(subject.type),
					resultType = lowerType(expression.type);
				localTypes.set(subjectName, subjectType);
				localTypes.set(resultName, resultType);
				builder.store(subjectName, lowerExpression(subject, builder, localTypes));
				var entryBlock = builder.currentBlock();
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
				for (caseIndex in 0...cases.length) {
					var switchCase = cases[caseIndex],
						isExhaustiveFinalCase = defaultExpression == null && caseIndex == cases.length - 1 && switchCase.guard == null,
						bodyBlock = bodyBlocks[caseIndex],
						nextBlock = caseIndex + 1 < cases.length ? checkBlocks[caseIndex + 1] : (defaultExpression == null ? afterBlock : fallbackBlock);
					builder.select(checkBlocks[caseIndex]);
					var subjectValue = builder.load(subjectName, subjectType);
					if (isNullableEnumType(subject.type)
						&& switchCase.constructorIndex >= 0
						&& !(isExhaustiveFinalCase && switchCase.predicates.length == 0)) {
						var nonNullBlock = builder.createBlock();
						builder.branch(builder.equal(subjectValue, builder.constNull(subjectType)), nextBlock, nonNullBlock);
						builder.select(nonNullBlock);
						subjectValue = builder.load(subjectName, subjectType);
					}
					var comparisonValue = switchCase.constructorIndex >= 0
						&& isEnumType(subject.type) ? builder.enumIndex(subjectValue) : subjectValue;
					var caseValue = switchCase.constructorIndex >= 0 ? builder.constInt(switchCase.constructorIndex) : lowerExpression(switchCase.value,
						builder, localTypes),
						matches = subject.type == TString ? builder.call("__string_equal", [comparisonValue, caseValue],
							Bool) : builder.equal(comparisonValue, caseValue);
					var matchBlock = matchBlocks[caseIndex];
					if (isExhaustiveFinalCase && switchCase.predicates.length == 0)
						builder.jump(bodyBlock);
					else {
						var predicateBlock = switchCase.predicates.length == 0 ? matchBlock : builder.createBlock();
						builder.branch(matches, predicateBlock, nextBlock);
						if (switchCase.predicates.length > 0)
							lowerEnumPredicates(subjectName, subjectType, switchCase.constructorIndex, switchCase.predicates, predicateBlock, matchBlock,
								nextBlock, builder, localTypes);
					}
					builder.select(matchBlock);
					for (binding in switchCase.bindings) {
						localTypes.set(binding.name, lowerType(binding.type));
						builder.store(binding.name,
							abiBoundaryCast(builder,
								builder.enumField(builder.load(subjectName, subjectType), switchCase.constructorIndex, binding.index,
									lowerType(binding.storageType)),
								lowerType(binding.type)));
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
				var physicalName = switch expression.type {
					case TAnonymous(name, _): name;
					default: typeName;
				}, object = builder.newObject(physicalName), objectType:IrType = Obj(physicalName), objectName = '$'
					+ 'object-literal:${expression.span.start}:${object.id}';
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
				}, arrayType:IrType = Array(lowerType(element)), array = lowerArrayAllocation(builder, element,
					builder.constInt(values.length)), arrayName = '$' + 'array-literal:${expression.span.start}:${array.id}';
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
				builder.store(resultName, lowerArrayAllocation(builder, resultElement, capacity));
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
					lowerArrayNativeCall(builder, resultElement, "push", [builder.load(resultName, resultType), loweredValue], I32);
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
				builder.store(resultName, lowerArrayAllocation(builder, TInt, builder.load(lengthName, I32)));
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
				lowerArrayAllocation(builder, element, lowerExpression(length, builder, localTypes));
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
				var loweredValue = lowerExpression(value, builder, localTypes),
					loweredEnd = end == null ? builder.call("__string_length", [loweredValue], I32) : lowerExpression(end, builder, localTypes);
				builder.call("__string_substring", [loweredValue, lowerExpression(start, builder, localTypes), loweredEnd], Bytes);
			case TArrayPush(array, value):
				var element = switch array.type {
					case TArray(valueType): valueType;
					default: throw "Array.push requires an array value";
				}, operands = lowerOperands([array, value], builder, localTypes);
				lowerArrayNativeCall(builder, element, "push", operands, I32);
			case TArrayUnshift(array, value):
				var element = switch array.type {
					case TArray(valueType): valueType;
					default: throw "Array.unshift requires an array value";
				}, operands = lowerOperands([array, value], builder, localTypes);
				lowerArrayNativeCall(builder, element, "unshift", operands, I32);
			case TArrayPop(array):
				var element = switch array.type {
					case TArray(valueType): valueType;
					default: throw "Array.pop requires an array value";
				}, resultType = lowerType(element), loweredArray = lowerExpression(array, builder, localTypes);
				lowerArrayNativeCall(builder, element, "pop", [loweredArray], resultType);
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
		var comparatorArguments = switch comparatorType {
			case Function(arguments, _): arguments;
			default: throw "Array.sort comparator must be a function";
		};
		var order = builder.callClosure(builder.load(comparatorName, comparatorType), [
			abiBoundaryCast(builder, builder.arrayGet(builder.load(arrayName, arrayType), builder.load(scanName, I32), elementType), comparatorArguments[0]),
			abiBoundaryCast(builder, builder.load(keyName, elementType), comparatorArguments[1])
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

	static function lowerEnumPredicates(subjectName:String, subjectType:IrType, constructorIndex:Int, predicates:Array<TypedSwitchPredicate>,
			firstBlock:CfgBlock, matchBlock:CfgBlock, nextBlock:CfgBlock, builder:CfgBuilder, localTypes:Map<String, IrType>):Void {
		var checkBlock = firstBlock;
		for (index in 0...predicates.length) {
			var predicate = predicates[index];
			builder.select(checkBlock);
			var field = abiBoundaryCast(builder,
				builder.enumField(builder.load(subjectName, subjectType), constructorIndex, predicate.index, lowerType(predicate.storageType)),
				lowerType(predicate.type));
			var matches = if (predicate.arrayLength >= 0) builder.equal(builder.arraySize(field), builder.constInt(predicate.arrayLength)); else {
				var predicateValue = predicate.value;
				if (predicateValue == null)
					throw "Equality payload predicate has no value";
				var expected = lowerExpression(predicateValue, builder, localTypes);
				isStringPatternType(predicate.type) ? builder.call("__string_equal", [field, expected], Bool) : builder.equal(field, expected);
			}
			checkBlock = index + 1 == predicates.length ? matchBlock : builder.createBlock();
			builder.branch(matches, checkBlock, nextBlock);
		}
	}

	static function isStringPatternType(type:CompilerType):Bool
		return switch type {
			case TString: true;
			case TAbstract(_, _, representation): isStringPatternType(representation);
			default: false;
		};

	static function isNullableEnumType(type:CompilerType):Bool
		return switch type {
			case TNullable(inner): isDirectEnumType(inner);
			default: false;
		};

	static function isEnumType(type:CompilerType):Bool
		return isDirectEnumType(type) || isNullableEnumType(type);

	static function isDirectEnumType(type:CompilerType):Bool
		return switch type {
			case TInstance(Enum, _, _): true;
			default: false;
		};

	static function isNullExpression(expression:TypedExpression):Bool
		return switch expression.expression {
			case TNullLiteral: true;
			case TNullableWrap(value), TCast(value), TAbiCast(value): isNullExpression(value);
			default: false;
		};

	static function isNullableEnumExpression(expression:TypedExpression):Bool
		return if (isNullableEnumType(expression.type)) true; else switch expression.expression {
			case TCast(value), TAbiCast(value): isNullableEnumExpression(value);
			default: false;
		};

	static function lowerNullableEnumEquality(a:TypedExpression, b:TypedExpression, left:CfgValue, right:CfgValue, builder:CfgBuilder,
			localTypes:Map<String, IrType>):CfgValue {
		var leftName = '$' + 'nullable-enum-left:${left.id}',
			rightName = '$' + 'nullable-enum-right:${right.id}',
			resultName = '$' + 'nullable-enum-equal:${left.id}',
			leftNull = isNullableEnumExpression(a),
			rightNull = isNullableEnumExpression(b),
			nullBlock = builder.createBlock(),
			nonNullBlock = builder.createBlock();
		var otherNullBlock = leftNull && rightNull ? builder.createBlock() : null,
			bothNonNullBlock = leftNull && rightNull ? builder.createBlock() : null,
			joinBlock = builder.createBlock();
		localTypes.set(leftName, left.type);
		localTypes.set(rightName, right.type);
		localTypes.set(resultName, Bool);
		builder.store(leftName, left);
		builder.store(rightName, right);
		var nullableValue = leftNull ? builder.load(leftName, left.type) : builder.load(rightName, right.type);
		builder.branch(builder.equal(nullableValue, builder.constNull(nullableValue.type)), nullBlock, nonNullBlock);
		builder.select(nullBlock);
		var nullResult = if (leftNull && rightNull) {
			var other = leftNull ? builder.load(rightName, right.type) : builder.load(leftName, left.type);
			builder.equal(other, builder.constNull(other.type));
		} else builder.constBool(false);
		builder.store(resultName, nullResult);
		builder.jump(joinBlock);
		builder.select(nonNullBlock);
		if (leftNull && rightNull) {
			var other = builder.load(rightName, right.type);
			builder.branch(builder.equal(other, builder.constNull(other.type)), otherNullBlock, bothNonNullBlock);
			builder.select(otherNullBlock);
			builder.store(resultName, builder.constBool(false));
			builder.jump(joinBlock);
			builder.select(bothNonNullBlock);
			builder.store(resultName,
				builder.equal(builder.enumIndex(builder.load(leftName, left.type)), builder.enumIndex(builder.load(rightName, right.type))));
			builder.jump(joinBlock);
		} else {
			builder.store(resultName,
				builder.equal(builder.enumIndex(builder.load(leftName, left.type)), builder.enumIndex(builder.load(rightName, right.type))));
			builder.jump(joinBlock);
		}
		builder.select(joinBlock);
		return builder.load(resultName, Bool);
	}

	static function mapTypesOrVoid(type:CompilerType):MapTypes
		return switch type {
			case TMap(key, value): {key: key, value: value};
			default: {key: TVoid, value: TVoid};
		};

	public static function lowerType(type:CompilerType):IrType
		return switch type {
			case TAbstract(_, _, representation): lowerType(representation);
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
			case TTypeParameter(owner, name): throw 'Unsubstituted type parameter "$owner.$name" reached IR lowering';
			case TInstance(kind, name, _):
				switch kind {
					case NominalKind.Class: Std.string(name) == "haxe.io.Eof" ? Dyn : Obj(name);
					case NominalKind.Interface: Virtual(name);
					case NominalKind.Enum: Enum(name);
					default: throw 'Unknown nominal kind $kind';
				}
			case TMap(key, value): Abstract(RuntimeType.requireMapName(key, value));
			case TNull: Void;
			case TNullable(element): TypeRelations.isReference(element) ? lowerType(element) : Dyn;
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

	static function lowerArrayAllocation(builder:CfgBuilder, element:CompilerType, length:CfgValue):CfgValue {
		var elementType = lowerType(element), arrayType = Array(elementType);
		return builder.call(arrayAllocatorName(element), [length], arrayType);
	}

	static function lowerArrayNativeCall(builder:CfgBuilder, element:CompilerType, operation:String, arguments:Array<CfgValue>, resultType:IrType):CfgValue {
		var nativeName = RuntimeType.arrayNative(element, operation);
		var nativeResult = RuntimeType.requireArrayName(element) == "ref" ? switch resultType {
			case Array(_): return builder.call(nativeName, arguments, resultType);
			case Obj(_), Enum(_), Abstract(_), Virtual(_), Function(_, _): Dyn;
			default: resultType;
		} : resultType;
		return referenceResultCast(builder, builder.call(nativeName, arguments, nativeResult), resultType);
	}
}

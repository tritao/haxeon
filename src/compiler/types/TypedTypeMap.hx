package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst;

/**
 * A copy of typed code with every type in it passed through `map`: the types of expressions, declarations, captures, switch
 * patterns and catches, and the types inside the functions a body made (its lambdas). The typer uses it to replace the type
 * variables a body filled (`Monomorphs`) once the body is typed, so no type variable reaches what follows the typer.
 */
class TypedTypeMap {
	final map:CompilerType->CompilerType;

	public function new(map:CompilerType->CompilerType)
		this.map = map;

	public function type(value:CompilerType):CompilerType
		return map(value);

	public function statements(list:Array<TypedStatement>):Array<TypedStatement>
		return [for (item in list) statement(item)];

	public function typedFunction(fn:TypedFunction):TypedFunction
		return {name: fn.name,
			role: switch fn.role {
				case ProviderFunction(subject, operation): ProviderFunction(map(subject), operation);
				default: fn.role;
			},
				origin: fn.origin,
				originKind: fn.originKind,
				typeArguments: fn.typeArguments == null ? null : [for (argument in fn.typeArguments) map(argument)],
				owner: fn.owner,
				physicalOwner: fn.physicalOwner,
				isStatic: fn.isStatic,
				isConstructor: fn.isConstructor,
				isInline: fn.isInline,
				isKept: fn.isKept,
				isExposed: fn.isExposed,
				arguments: [for (argument in fn.arguments) {
			name:argument.name, type:map(argument.type)
		}],
			result: map(fn.result),
			dispatchEntry: fn.dispatchEntry,
			statements: statements(fn.statements),
			cells: fn.cells,
			cellCaptures: fn.cellCaptures,
			span: fn.span,
			warnings: fn.warnings};

	public function capture(item:TypedCapture):TypedCapture
		return {field: item.field,
			bindingId: item.bindingId,
			type: map(item.type),
			storageType: map(item.storageType),
			source: switch item.source {
				case CaptureExpression(value): CaptureExpression(expression(value));
				default: item.source;
			}
		};

	public function statement(item:TypedStatement):TypedStatement
		return switch item {
			case TDeclare(name, type, span): TDeclare(name, map(type), span);
			case TVar(name, initializer, span): TVar(name, expression(initializer), span);
			case TAssign(name, value, span): TAssign(name, expression(value), span);
			case TCellAssign(name, cellClass, value, span): TCellAssign(name, cellClass, expression(value), span);
			case TCellCapturedAssign(name, cellClass, value, span): TCellCapturedAssign(name, cellClass,
				expression(value), span);
			case TFieldAssign(object, name, value, span): TFieldAssign(expression(object), name, expression(value),
				span);
			case TStaticFieldAssign(name, field, value, span): TStaticFieldAssign(name, field, expression(value), span);
			case TIndexAssign(array, index, value, span): TIndexAssign(expression(array), expression(index),
				expression(value),
				span);
			case TMapAssign(target, key, value, span): TMapAssign(expression(target), expression(key),
				expression(value), span);
			case TReturn(value, span): TReturn(expression(value), span);
			case TReturnVoid(_), TBreak(_), TContinue(_), TIncrement(_, _, _): item;
			case TThrow(value, span): TThrow(expression(value), span);
			case TDefer(body, span, scopedDisposal): TDefer(statements(body), span, scopedDisposal);
			case TTry(tryBranch, catches, span): TTry(statements(tryBranch), [for (caught in catches)
				{
						name:caught.name,
							type:map(caught.type),
							subject:caught.subject,
							statements:statements(caught.statements),
							span:caught.span
					}], span);
			case TIf(condition, thenBranch, elseBranch, span): TIf(expression(condition), statements(thenBranch),
				statements(elseBranch), span);
			case TWhile(condition, body, span): TWhile(expression(condition), statements(body), span);
			case TDoWhile(body, condition, span): TDoWhile(statements(body), expression(condition), span);
			case TForIn(keyName, valueName, iterable, body, span): TForIn(keyName, valueName, expression(iterable),
				statements(body), span);
			case TSwitch(subject, cases, defaultBranch, hasDefault, span): TSwitch(expression(subject),
				[for (switchCase in cases)
				{
						arm:switchArm(switchCase.arm), statements:statements(switchCase.statements)
					}], statements(defaultBranch), hasDefault, span);
			case TCellIncrement(name, cellClass, valueType, delta, span): TCellIncrement(name, cellClass,
				map(valueType), delta,
				span);
			case TCellCapturedIncrement(name, cellClass, valueType, delta, span): TCellCapturedIncrement(name,
				cellClass,
				map(valueType), delta, span);
			case TExpression(value, span): TExpression(expression(value), span);
		};

	public function expression(item:TypedExpression):TypedExpression {
		var type = map(item.type), expression = switch [item.expression, type] {
			// An object literal's record is its structure's, named when the structure closes (`MonomorphFrames`).
			case [TObjectLiteral(_, fields, false), TAnonymous(name, _)]: TObjectLiteral(name, objectFields(fields),
				false);
			default: kind(item.expression);
		};
		return new TypedExpression(expression, type, item.span, item.stableFlowValue,
			item.mapKeySource == null ? null : this.expression(item.mapKeySource),
			item.storageType == null ? null : map(item.storageType),
			item.semanticReference);
	}

	function objectFields(fields:Array<TypedObjectField>):Array<TypedObjectField>
		return [for (field in fields) {
			name:field.name, value:expression(field.value)
		}];

	function switchArm(arm:TypedSwitchArm):TypedSwitchArm
		return {
			value: expression(arm.value),
			subjectBinding: arm.subjectBinding,
			arrayPattern: arrayPattern(arm.arrayPattern),
			isCatchAll: arm.isCatchAll,
			guard: optional(arm.guard),
			enumName: arm.enumName,
			constructorIndex: arm.constructorIndex,
			bindings: bindings(arm.bindings),
			predicates: predicates(arm.predicates),
			span: arm.span
		};

	function optional(item:Null<TypedExpression>):Null<TypedExpression>
		return item == null ? null : expression(item);

	function expressions(list:Array<TypedExpression>):Array<TypedExpression>
		return [for (item in list) expression(item)];

	function kind(item:TypedExpressionKind):TypedExpressionKind
		return switch item {
			case TIntLiteral(_), TFloatLiteral(_), TStringLiteral(_), TRuntimeDataAddress(_), TBoolLiteral(_),
				TEnumLiteral(_, _),
				TNullLiteral, TUnreachable, TVoidLiteral, TLocal(_), TCellLocal(_, _), TCaptured(_),
				TCellCaptured(_, _),
				TClassRef(_), TStaticField(_, _), TFunctionRef(_), TPostfixLocal(_, _), TPostfixCellLocal(_, _, _),
				TPostfixCellCaptured(_, _, _), TPostfixStaticField(_, _, _): item;
			case TEnumConstruct(name, index, arguments): TEnumConstruct(name, index, expressions(arguments));
			case TEnumIndex(value): TEnumIndex(expression(value));
			case TEnumField(value, constructor, field): TEnumField(expression(value), constructor, field);
			case TNullableWrap(value): TNullableWrap(expression(value));
			case TCopy(value, layout): TCopy(expression(value), copyLayout(layout));
			case TIntToFloat(value): TIntToFloat(expression(value));
			case TIntToInt64(value): TIntToInt64(expression(value));
			case TFloatToInt(value): TFloatToInt(expression(value));
			case TToDynamic(value): TToDynamic(expression(value));
			case TMethodRef(object, functionName): TMethodRef(expression(object), functionName);
			case TLambda(name, environment, captures): TLambda(name, environment,
				[for (item in captures) capture(item)]);
			case TAdd(left, right): TAdd(expression(left), expression(right));
			case TSub(left, right): TSub(expression(left), expression(right));
			case TMul(left, right): TMul(expression(left), expression(right));
			case TDiv(left, right): TDiv(expression(left), expression(right));
			case TMod(left, right): TMod(expression(left), expression(right));
			case TBitAnd(left, right): TBitAnd(expression(left), expression(right));
			case TBitXor(left, right): TBitXor(expression(left), expression(right));
			case TBitOr(left, right): TBitOr(expression(left), expression(right));
			case TShiftLeft(left, right): TShiftLeft(expression(left), expression(right));
			case TShiftRight(left, right): TShiftRight(expression(left), expression(right));
			case TUnsignedShiftRight(left, right): TUnsignedShiftRight(expression(left), expression(right));
			case TNegate(value): TNegate(expression(value));
			case TLess(left, right): TLess(expression(left), expression(right));
			case TLessEqual(left, right): TLessEqual(expression(left), expression(right));
			case TEqual(left, right): TEqual(expression(left), expression(right));
			case TNot(value): TNot(expression(value));
			case TAnd(left, right): TAnd(expression(left), expression(right));
			case TOr(left, right): TOr(expression(left), expression(right));
			case TConditional(condition, whenTrue, whenFalse): TConditional(expression(condition), expression(whenTrue),
				expression(whenFalse));
			case TBlockExpression(body, result): TBlockExpression(statements(body), expression(result));
			case TThrowExpression(value): TThrowExpression(expression(value));
			case TNoReturn(value): TNoReturn(expression(value));
			case TCast(value): TCast(expression(value));
			case TAbiCast(value): TAbiCast(expression(value));
			case TSwitchExpression(subject, cases, defaultExpression): TSwitchExpression(expression(subject),
				[for (switchCase in cases)
				{
						arm:switchArm(switchCase.arm), result:expression(switchCase.result)
					}], optional(defaultExpression));
			case TObjectLiteral(name, fields, isDynamic): TObjectLiteral(name, objectFields(fields), isDynamic);
			case TArrayLiteral(values): TArrayLiteral(expressions(values));
			case TTuple(values): TTuple(expressions(values));
			case TMapLiteral(entries): TMapLiteral([for (entry in entries) {
					key:expression(entry.key), value:expression(entry.value)
				}]);
			case TArrayComprehension(keyName, valueName, iterable, condition, value,
				flattened): TArrayComprehension(keyName,
				valueName, expression(iterable), optional(condition), expression(value), flattened);
			case TMapComprehension(keyName, valueName, iterable, condition, key, value): TMapComprehension(keyName,
				valueName,
				expression(iterable), optional(condition), expression(key), expression(value));
			case TRange(start, end): TRange(expression(start), expression(end));
			case TCall(name, arguments): TCall(name, expressions(arguments));
			case TCNativeCall(name, arguments): TCNativeCall(name, expressions(arguments));
			case TCollectionCall(receiver, operation, arguments): TCollectionCall(expression(receiver), operation,
				expressions(arguments));
			case TClosureCall(callee, arguments): TClosureCall(expression(callee), expressions(arguments));
			case TToInterface(value, name): TToInterface(expression(value), name);
			case TNew(typeName, arguments, hasConstructor): TNew(typeName, expressions(arguments), hasConstructor);
			case TNewArray(element, length): TNewArray(map(element), expression(length));
			case TNewMap(key, value): TNewMap(map(key), map(value));
			case TField(object, name): TField(expression(object), name);
			case TMethodCall(object, functionName, arguments): TMethodCall(expression(object), functionName,
				expressions(arguments));
			case TSuperCall(owner, arguments): TSuperCall(owner, expressions(arguments));
			case TIndex(array, index): TIndex(expression(array), expression(index));
			case TPostfixField(object, name, delta): TPostfixField(expression(object), name, delta);
			case TPostfixIndex(array, index, delta): TPostfixIndex(expression(array), expression(index), delta);
			case TMapGet(target, key): TMapGet(expression(target), expression(key));
			case TArrayLength(array): TArrayLength(expression(array));
			case TStringLength(value): TStringLength(expression(value));
			case TStringIndexOf(value, needle): TStringIndexOf(expression(value), expression(needle));
			case TStringCharAt(value, index): TStringCharAt(expression(value), expression(index));
			case TStringCharCodeAt(value, index): TStringCharCodeAt(expression(value), expression(index));
			case TStringFromCharCode(code): TStringFromCharCode(expression(code));
			case TStringSubstring(value, start, end): TStringSubstring(expression(value), expression(start),
				optional(end));
			case TArrayPush(array, value): TArrayPush(expression(array), expression(value));
			case TArrayUnshift(array, value): TArrayUnshift(expression(array), expression(value));
			case TArrayPop(array): TArrayPop(expression(array));
			case TArraySort(array, comparator): TArraySort(expression(array), expression(comparator));
			case TEnumDynamicBox(value, enumType): TEnumDynamicBox(expression(value), map(enumType));
			case TEnumDynamicView(array, enumType): TEnumDynamicView(expression(array), map(enumType));
		};

	function copyLayout(layout:ValueCopyLayout):ValueCopyLayout
		return {name: layout.name,
			fields: [for (field in layout.fields)
			{
				name:field.name, type:map(field.type), nested:field.nested == null ? null : copyLayout(field.nested)
			}]};

	function arrayPattern(pattern:Null<TypedSwitchArrayPattern>):Null<TypedSwitchArrayPattern>
		return pattern == null ? null : {elements: [for (element in pattern.elements)
			{
				type:map(element.type),
					value:optional(element.value),
					equalityFunction:element.equalityFunction,
					subjectBinding:element.subjectBinding,
					isCatchAll:element.isCatchAll,
					constructorIndex:element.constructorIndex,
					bindings:bindings(element.bindings),
					predicates:predicates(element.predicates)
			}]};

	function bindings(list:Array<TypedSwitchBinding>):Array<TypedSwitchBinding>
		return [for (binding in list)
			{
				name:binding.name,
					type:map(binding.type),
					storageType:map(binding.storageType),
					fieldStorageType:map(binding.fieldStorageType),
					index:binding.index,
					arrayIndex:binding.arrayIndex,
					nestedPath:fieldPath(binding.nestedPath)
			}];

	function predicates(list:Array<TypedSwitchPredicate>):Array<TypedSwitchPredicate>
		return [for (predicate in list)
			{
				value:optional(predicate.value),
					arrayLength:predicate.arrayLength,
					type:map(predicate.type),
					storageType:map(predicate.storageType),
					fieldStorageType:map(predicate.fieldStorageType),
					index:predicate.index,
					arrayIndex:predicate.arrayIndex,
					nestedPath:fieldPath(predicate.nestedPath),
					objectPath:predicate.objectPath == null ? null : [for (access in predicate.objectPath)
					{
						name:access.name, storageType:map(access.storageType)
					}],
						nestedConstructorIndex:predicate.nestedConstructorIndex
			}];

	function fieldPath(path:Null<Array<TypedSwitchFieldAccess>>):Null<Array<TypedSwitchFieldAccess>>
		return path == null ? null : [for (access in path)
			{
				enumType:map(access.enumType), constructorIndex:access.constructorIndex, fieldIndex:access.fieldIndex,
					storageType:map(access.storageType)
			}];
}

package compiler.types;

import compiler.types.TypedAst;

/**
 * The direct children of typed code: the expressions and statement lists one node holds, in evaluation order. For an analysis
 * that walks typed code and cares about a few kinds of node, which it matches itself before handing the rest here.
 */
class TypedChildren {
	public static function ofStatement(item:TypedStatement, expression:TypedExpression->Void,
			statements:Array<TypedStatement>->Void):Void
		switch item {
			case TDeclare(_, _, _), TReturnVoid(_), TBreak(_), TContinue(_), TIncrement(_, _, _, _),
				TCapturedIncrement(_, _, _, _):
			case TVar(_, value, _), TAssign(_, value, _), TCapturedAssign(_, value, _),
				TStaticFieldAssign(_, _, value, _),
				TReturn(value, _), TThrow(value, _), TExpression(value, _):
				expression(value);
			case TFieldAssign(object, _, value, _):
				expression(object);
				expression(value);
			case TIndexAssign(array, index, value, _), TMapAssign(array, index, value, _):
				expression(array);
				expression(index);
				expression(value);
			case TDefer(body, _, _):
				statements(body);
			case TTry(tryBranch, catches, _):
				statements(tryBranch);
				for (caught in catches)
					statements(caught.statements);
			case TIf(condition, thenBranch, elseBranch, _):
				expression(condition);
				statements(thenBranch);
				statements(elseBranch);
			case TWhile(condition, body, _):
				expression(condition);
				statements(body);
			case TDoWhile(body, condition, _):
				statements(body);
				expression(condition);
			case TForIn(_, _, iterable, body, _):
				expression(iterable);
				statements(body);
			case TSwitch(subject, cases, defaultBranch, _, _):
				expression(subject);
				for (switchCase in cases) {
					for (arm in switchCase.arms)
						if (arm.guard != null)
							expression(arm.guard);
					statements(switchCase.statements);
				}
				statements(defaultBranch);
		}

	public static function ofExpression(item:TypedExpressionKind, expression:TypedExpression->Void,
			statements:Array<TypedStatement>->Void):Void
		switch item {
			case TIntLiteral(_), TFloatLiteral(_), TStringLiteral(_), TRuntimeDataAddress(_), TBoolLiteral(_),
				TEnumLiteral(_, _), TNullLiteral, TUnreachable, TBreakExpression, TContinueExpression, TVoidLiteral,
				TLocal(_), TCaptured(_), TClassRef(_),
				TStaticField(_, _), TFunctionRef(_), TPostfixLocal(_, _), TPostfixCaptured(_, _),
				TPostfixStaticField(_, _, _), TNewMap(_, _):
			case TLambda(_, _, captures):
				for (capture in captures)
					switch capture.source {
						case CaptureExpression(value): expression(value);
						default:
					}
			case TEnumIndex(value), TEnumField(value, _, _), TNullableWrap(value), TCopy(value, _), TIntToFloat(value),
				TIntToInt64(value), TFloatToInt(value), TToDynamic(value), TMethodRef(value, _), TNegate(value),
				TNot(value), TThrowExpression(value), TNoReturn(value), TCast(value), TParameterConversion(value, _),
				TAbiCast(value), TToInterface(value, _), TNewArray(_, value), TField(value, _),
				TPostfixField(value, _, _),
				TArrayLength(value), TStringLength(value), TStringFromCharCode(value), TArrayPop(value),
				TEnumDynamicBox(value, _), TEnumDynamicView(value, _):
				expression(value);
			case TAdd(left, right), TSub(left, right), TMul(left, right), TDiv(left, right), TMod(left, right),
				TBitAnd(left, right), TBitXor(left, right), TBitOr(left, right), TShiftLeft(left, right),
				TShiftRight(left, right), TUnsignedShiftRight(left, right), TLess(left, right), TLessEqual(left, right),
				TEqual(left, right), TAnd(left, right), TOr(left, right), TRange(left, right), TIndex(left, right),
				TPostfixIndex(left, right, _), TMapGet(left, right), TStringIndexOf(left, right),
				TStringCharAt(left, right), TStringCharCodeAt(left, right), TArrayPush(left, right),
				TArrayUnshift(left, right), TArraySort(left, right):
				expression(left);
				expression(right);
			case TConditional(condition, whenTrue, whenFalse):
				expression(condition);
				expression(whenTrue);
				expression(whenFalse);
			case TBlockExpression(body, result):
				statements(body);
				expression(result);
			case TEnumConstruct(_, _, values), TParameterOperation(_, values), TArrayLiteral(values), TTuple(values),
				TCall(_, values), TCNativeCall(_, values), TNew(_, values, _), TSuperCall(_, values):
				for (value in values)
					expression(value);
			case TSwitchExpression(subject, cases, defaultExpression):
				expression(subject);
				for (switchCase in cases) {
					for (arm in switchCase.arms)
						if (arm.guard != null)
							expression(arm.guard);
					expression(switchCase.result);
				}
				if (defaultExpression != null)
					expression(defaultExpression);
			case TObjectLiteral(_, fields, _):
				for (field in fields)
					expression(field.value);
			case TMapLiteral(entries):
				for (entry in entries) {
					expression(entry.key);
					expression(entry.value);
				}
			case TArrayComprehension(_, _, iterable, condition, value, _):
				expression(iterable);
				if (condition != null)
					expression(condition);
				expression(value);
			case TMapComprehension(_, _, iterable, condition, key, value):
				expression(iterable);
				if (condition != null)
					expression(condition);
				expression(key);
				expression(value);
			case TCollectionCall(receiver, _, values), TClosureCall(receiver, values), TMethodCall(receiver, _, values):
				expression(receiver);
				for (value in values)
					expression(value);
			case TStringSubstring(value, start, end):
				expression(value);
				expression(start);
				if (end != null)
					expression(end);
		}
}

package compiler.semantic;

import compiler.types.TypedAst.TypedCaptureSource;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.TypedAst.TypedStatement;

/**
 * The structural child traversal for the typed AST.
 *
 * Semantic passes should attach facts in callbacks and leave ownership of
 * child discovery here. Keeping this switch exhaustive makes adding a typed
 * expression a compile-time review point instead of another easy-to-miss
 * indexing path.
 */
class TypedAstChildren {
	public static function statements(items:Array<TypedStatement>, onStatement:TypedStatement->Void,
			onExpression:TypedExpression->Void):Void {
		for (statement in items) {
			onStatement(statement);
			switch statement {
				case TVar(_, value, _), TReturn(value, _), TThrow(value, _), TExpression(value, _):
					expression(value, onStatement, onExpression);
				case TAssign(_, value, _), TCellAssign(_, _, value, _), TCellCapturedAssign(_, _, value, _):
					expression(value, onStatement, onExpression);
				case TFieldAssign(object, _, value, _):
					expression(object, onStatement, onExpression);
					expression(value, onStatement, onExpression);
				case TStaticFieldAssign(_, _, value, _):
					expression(value, onStatement, onExpression);
				case TIndexAssign(array, index, value, _), TMapAssign(array, index, value, _):
					expression(array, onStatement, onExpression);
					expression(index, onStatement, onExpression);
					expression(value, onStatement, onExpression);
				case TIf(condition, thenBranch, elseBranch, _):
					expression(condition, onStatement, onExpression);
					statements(thenBranch, onStatement, onExpression);
					statements(elseBranch, onStatement, onExpression);
				case TWhile(condition, body, _):
					expression(condition, onStatement, onExpression);
					statements(body, onStatement, onExpression);
				case TDoWhile(body, condition, _):
					statements(body, onStatement, onExpression);
					expression(condition, onStatement, onExpression);
				case TForIn(_, _, iterable, body, _):
					expression(iterable, onStatement, onExpression);
					statements(body, onStatement, onExpression);
				case TTry(body, catches, _):
					statements(body, onStatement, onExpression);
					for (caught in catches)
						statements(caught.statements, onStatement, onExpression);
				case TSwitch(value, cases, fallback, _, _):
					expression(value, onStatement, onExpression);
					for (item in cases) {
						expression(item.value, onStatement, onExpression);
						if (item.guard != null)
							expression(item.guard, onStatement, onExpression);
						statements(item.statements, onStatement, onExpression);
					}
					statements(fallback, onStatement, onExpression);
			case TDeclare(_, _, _), TIncrement(_, _, _), TCellIncrement(_, _, _, _, _), TCellCapturedIncrement(_, _, _, _, _), TBreak(_), TContinue(_), TReturnVoid(_):
			}
		}
	}

	public static function expression(value:TypedExpression, onStatement:TypedStatement->Void,
			onExpression:TypedExpression->Void):Void {
		onExpression(value);
		switch value.expression {
			case TEnumConstruct(_, _, arguments):
				for (argument in arguments)
					expression(argument, onStatement, onExpression);
			case TEnumIndex(child), TEnumField(child, _, _):
				expression(child, onStatement, onExpression);
			case TNullableWrap(child), TIntToFloat(child), TIntToInt64(child), TFloatToInt(child), TToDynamic(child), TNegate(child), TNot(child),
				TThrowExpression(child), TNoReturn(child), TCast(child), TAbiCast(child), TToInterface(child, _), TArrayLength(child), TStringLength(child),
				TStringFromCharCode(child), TArrayPop(child):
				expression(child, onStatement, onExpression);
			case TAdd(left, right), TSub(left, right), TMul(left, right), TDiv(left, right), TMod(left, right), TBitAnd(left, right), TBitXor(left, right),
				TBitOr(left, right), TShiftLeft(left, right), TShiftRight(left, right), TUnsignedShiftRight(left, right), TLess(left, right),
				TLessEqual(left, right), TEqual(left, right), TAnd(left, right), TOr(left, right), TIndex(left, right), TMapGet(left, right),
				TStringIndexOf(left, right), TStringCharAt(left, right), TStringCharCodeAt(left, right), TArrayPush(left, right), TArrayUnshift(left, right):
				expression(left, onStatement, onExpression);
				expression(right, onStatement, onExpression);
			case TPostfixIndex(array, index, _):
				expression(array, onStatement, onExpression);
				expression(index, onStatement, onExpression);
			case TConditional(condition, whenTrue, whenFalse):
				expression(condition, onStatement, onExpression);
				expression(whenTrue, onStatement, onExpression);
				expression(whenFalse, onStatement, onExpression);
			case TBlockExpression(body, result):
				statements(body, onStatement, onExpression);
				expression(result, onStatement, onExpression);
			case TMethodRef(object, _), TField(object, _), TPostfixField(object, _, _):
				expression(object, onStatement, onExpression);
			case TMethodCall(object, _, arguments), TCollectionCall(object, _, arguments):
				expression(object, onStatement, onExpression);
				for (argument in arguments)
					expression(argument, onStatement, onExpression);
			case TCall(_, arguments), TCNativeCall(_, arguments):
				for (argument in arguments)
					expression(argument, onStatement, onExpression);
			case TClosureCall(callee, arguments):
				expression(callee, onStatement, onExpression);
				for (argument in arguments)
					expression(argument, onStatement, onExpression);
			case TNew(_, arguments, _), TSuperCall(_, arguments):
				for (argument in arguments)
					expression(argument, onStatement, onExpression);
			case TSwitchExpression(subject, cases, fallback):
				expression(subject, onStatement, onExpression);
				for (item in cases) {
					expression(item.value, onStatement, onExpression);
					if (item.guard != null)
						expression(item.guard, onStatement, onExpression);
					expression(item.result, onStatement, onExpression);
				}
				if (fallback != null)
					expression(fallback, onStatement, onExpression);
			case TObjectLiteral(_, fields):
				for (field in fields)
					expression(field.value, onStatement, onExpression);
			case TArrayLiteral(values):
				for (item in values)
					expression(item, onStatement, onExpression);
			case TMapLiteral(entries):
				for (entry in entries) {
					expression(entry.key, onStatement, onExpression);
					expression(entry.value, onStatement, onExpression);
				}
			case TArrayComprehension(_, _, iterable, condition, item):
				expression(iterable, onStatement, onExpression);
				if (condition != null)
					expression(condition, onStatement, onExpression);
				expression(item, onStatement, onExpression);
			case TMapComprehension(_, _, iterable, condition, key, item):
				expression(iterable, onStatement, onExpression);
				if (condition != null)
					expression(condition, onStatement, onExpression);
				expression(key, onStatement, onExpression);
				expression(item, onStatement, onExpression);
			case TRange(start, end):
				expression(start, onStatement, onExpression);
				expression(end, onStatement, onExpression);
			case TNewArray(_, length):
				expression(length, onStatement, onExpression);
			case TStringSubstring(string, start, end):
				expression(string, onStatement, onExpression);
				expression(start, onStatement, onExpression);
				if (end != null)
					expression(end, onStatement, onExpression);
			case TArraySort(array, comparator):
				expression(array, onStatement, onExpression);
				expression(comparator, onStatement, onExpression);
			case TLambda(_, _, captures):
				for (capture in captures)
					switch capture.source {
						case CaptureExpression(child): expression(child, onStatement, onExpression);
						default:
					}
			case TIntLiteral(_), TFloatLiteral(_), TStringLiteral(_), TRuntimeDataAddress(_), TBoolLiteral(_), TEnumLiteral(_, _), TNullLiteral, TVoidLiteral,
				TUnreachable, TLocal(_), TCellLocal(_, _), TCaptured(_), TCellCaptured(_, _), TClassRef(_), TStaticField(_, _), TFunctionRef(_),
				TPostfixLocal(_, _), TPostfixCellLocal(_, _, _), TPostfixCellCaptured(_, _, _), TPostfixStaticField(_, _, _), TNewMap(_, _):
			}
		}
}

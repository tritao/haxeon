package compiler.types;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

private enum InlineConstantValue {
	Integer(value:Int);
	Floating(value:Float);
	Text(value:String);
	Boolean(value:Bool);
	NullValue;
}

/** Evaluates the side-effect-free expression subset allowed in inline fields. */
class InlineConstantEvaluator {
	public static function evaluate(expression:TypedExpression):Null<TypedExpression> {
		var value = evaluateValue(expression);
		if (value == null)
			return null;
		return literal(value, expression.span, expression.type);
	}

	static function evaluateValue(expression:TypedExpression):Null<InlineConstantValue> {
		return switch expression.expression {
			case TIntLiteral(number): InlineConstantValue.Integer(number);
			case TFloatLiteral(number): InlineConstantValue.Floating(number);
			case TStringLiteral(text): InlineConstantValue.Text(text);
			case TBoolLiteral(flag): InlineConstantValue.Boolean(flag);
			case TNullLiteral: InlineConstantValue.NullValue;
			case TIntToFloat(inner):
				switch evaluateValue(inner) {
					case InlineConstantValue.Integer(number): InlineConstantValue.Floating(number);
					case InlineConstantValue.Floating(number): InlineConstantValue.Floating(number);
					default: null;
				}
			case TIntToInt64(inner): evaluateValue(inner);
			case TNullableWrap(inner), TCast(inner), TAbiCast(inner): evaluateValue(inner);
			case TAdd(left, right): add(evaluateValue(left), evaluateValue(right));
			case TSub(left, right): numericBinary(evaluateValue(left), evaluateValue(right), 1);
			case TMul(left, right): numericBinary(evaluateValue(left), evaluateValue(right), 2);
			case TDiv(left, right): numericBinary(evaluateValue(left), evaluateValue(right), 3);
			case TMod(left, right): numericBinary(evaluateValue(left), evaluateValue(right), 4);
			case TBitAnd(left, right): integerBinary(evaluateValue(left), evaluateValue(right), 0);
			case TBitXor(left, right): integerBinary(evaluateValue(left), evaluateValue(right), 1);
			case TBitOr(left, right): integerBinary(evaluateValue(left), evaluateValue(right), 2);
			case TShiftLeft(left, right): integerBinary(evaluateValue(left), evaluateValue(right), 3);
			case TShiftRight(left, right): integerBinary(evaluateValue(left), evaluateValue(right), 4);
			case TUnsignedShiftRight(left, right): integerBinary(evaluateValue(left), evaluateValue(right), 5);
			case TNegate(inner): negate(evaluateValue(inner));
			case TLess(left, right): compare(evaluateValue(left), evaluateValue(right), 0);
			case TLessEqual(left, right): compare(evaluateValue(left), evaluateValue(right), 1);
			case TEqual(left, right): compare(evaluateValue(left), evaluateValue(right), 2);
			case TNot(inner):
				switch evaluateValue(inner) {
					case InlineConstantValue.Boolean(flag): InlineConstantValue.Boolean(!flag);
					default: null;
				}
			case TAnd(left, right): booleanBinary(evaluateValue(left), evaluateValue(right), true);
			case TOr(left, right): booleanBinary(evaluateValue(left), evaluateValue(right), false);
			case TConditional(condition, whenTrue, whenFalse):
				switch evaluateValue(condition) {
					case InlineConstantValue.Boolean(flag): evaluateValue(flag ? whenTrue : whenFalse);
					default: null;
				}
			default: null;
		};
	}

	static function literal(value:InlineConstantValue, span:compiler.Source.SourceSpan, type:CompilerType):TypedExpression {
		return switch value {
			case InlineConstantValue.Integer(number): new TypedExpression(TIntLiteral(number), type == TInt64 ? TInt64 : TInt, span);
			case InlineConstantValue.Floating(number): new TypedExpression(TFloatLiteral(number), TFloat, span);
			case InlineConstantValue.Text(text): new TypedExpression(TStringLiteral(text), TString, span);
			case InlineConstantValue.Boolean(flag): new TypedExpression(TBoolLiteral(flag), TBool, span);
			case InlineConstantValue.NullValue: new TypedExpression(TNullLiteral, TNull, span);
		};
	}

	static function add(left:Null<InlineConstantValue>, right:Null<InlineConstantValue>):Null<InlineConstantValue> {
		var leftText = textValue(left), rightText = textValue(right);
		if (leftText != null && rightText != null)
			return InlineConstantValue.Text(leftText + rightText);
		return numericBinary(left, right, 0);
	}

	static function negate(value:Null<InlineConstantValue>):Null<InlineConstantValue>
		return switch value {
			case InlineConstantValue.Integer(number): InlineConstantValue.Integer(-number);
			case InlineConstantValue.Floating(number): InlineConstantValue.Floating(-number);
			default: null;
		};

	static function numericBinary(left:Null<InlineConstantValue>, right:Null<InlineConstantValue>, operation:Int):Null<InlineConstantValue> {
		var leftInteger = integerValue(left),
			rightInteger = integerValue(right);
		if (operation != 3 && leftInteger != null && rightInteger != null)
			return switch operation {
				case 0: InlineConstantValue.Integer(leftInteger + rightInteger);
				case 1: InlineConstantValue.Integer(leftInteger - rightInteger);
				case 2: InlineConstantValue.Integer(leftInteger * rightInteger);
				case 4: rightInteger == 0 ? null : InlineConstantValue.Integer(leftInteger % rightInteger);
				default: null;
			};
		var leftNumber = numberValue(left), rightNumber = numberValue(right);
		if (leftNumber == null || rightNumber == null || operation == 4 || (rightNumber == 0.0 && operation == 3))
			return null;
		return switch operation {
			case 0: InlineConstantValue.Floating(leftNumber + rightNumber);
			case 1: InlineConstantValue.Floating(leftNumber - rightNumber);
			case 2: InlineConstantValue.Floating(leftNumber * rightNumber);
			case 3: InlineConstantValue.Floating(leftNumber / rightNumber);
			default: null;
		};
	}

	static function integerBinary(left:Null<InlineConstantValue>, right:Null<InlineConstantValue>, operation:Int):Null<InlineConstantValue> {
		var leftInteger = integerValue(left),
			rightInteger = integerValue(right);
		if (leftInteger == null || rightInteger == null)
			return null;
		return switch operation {
			case 0: InlineConstantValue.Integer(leftInteger & rightInteger);
			case 1: InlineConstantValue.Integer(leftInteger ^ rightInteger);
			case 2: InlineConstantValue.Integer(leftInteger | rightInteger);
			case 3: InlineConstantValue.Integer(leftInteger << rightInteger);
			case 4: InlineConstantValue.Integer(leftInteger >> rightInteger);
			case 5: InlineConstantValue.Integer(leftInteger >>> rightInteger);
			default: null;
		};
	}

	static function compare(left:Null<InlineConstantValue>, right:Null<InlineConstantValue>, operation:Int):Null<InlineConstantValue> {
		var leftNumber = numberValue(left), rightNumber = numberValue(right);
		if (leftNumber != null && rightNumber != null)
			return
				InlineConstantValue.Boolean(operation == 0 ? leftNumber < rightNumber : operation == 1 ? leftNumber <= rightNumber : leftNumber == rightNumber);
		var leftText = textValue(left), rightText = textValue(right);
		if (leftText != null && rightText != null) {
			var order = Reflect.compare(leftText, rightText);
			return InlineConstantValue.Boolean(operation == 0 ? order < 0 : operation == 1 ? order <= 0 : order == 0);
		}
		return switch left {
			case InlineConstantValue.Boolean(leftFlag):
				switch right {
					case InlineConstantValue.Boolean(rightFlag):
						operation == 2 ? InlineConstantValue.Boolean(leftFlag == rightFlag) : null;
					default: null;
				};
			case InlineConstantValue.NullValue:
				switch right {
					case InlineConstantValue.NullValue: operation == 2 ? InlineConstantValue.Boolean(true) : null;
					default: null;
				};
			default: null;
		};
	}

	static function booleanBinary(left:Null<InlineConstantValue>, right:Null<InlineConstantValue>, and:Bool):Null<InlineConstantValue>
		return switch left {
			case InlineConstantValue.Boolean(leftFlag):
				switch right {
					case InlineConstantValue.Boolean(rightFlag):
						InlineConstantValue.Boolean(and ? leftFlag && rightFlag : leftFlag || rightFlag);
					default: null;
				};
			default: null;
		};

	static function integerValue(value:Null<InlineConstantValue>):Null<Int>
		return switch value {
			case InlineConstantValue.Integer(number): number;
			default: null;
		};

	static function numberValue(value:Null<InlineConstantValue>):Null<Float>
		return switch value {
			case InlineConstantValue.Integer(number): number;
			case InlineConstantValue.Floating(number): number;
			default: null;
		};

	static function textValue(value:Null<InlineConstantValue>):Null<String>
		return switch value {
			case InlineConstantValue.Text(text): text;
			default: null;
		};
}

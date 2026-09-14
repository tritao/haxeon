package compiler.types.typing;

import compiler.Diagnostic;
import compiler.Diagnostic.CompileError;
import compiler.Source.SourceSpan;
import compiler.syntax.Ast.AstExpression;
import compiler.types.analysis.FlowAnalysis;
import compiler.types.analysis.Scope;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.TypedExpressionKind;
import compiler.types.Type.CompilerType;
import compiler.types.TypeRelations;

typedef ExpressionTypeCallback = (AstExpression, Scope, Null<CompilerType>, Bool) -> TypedExpression;
typedef ExpressionCoerceCallback = (TypedExpression, CompilerType, String, String) -> TypedExpression;

/** Types literals and operator expressions through explicit expression/conversion callbacks. */
class ExpressionTyper {
	final session:TypingSession;
	final typeExpression:ExpressionTypeCallback;
	final coerce:ExpressionCoerceCallback;

	public function new(session:TypingSession, typeExpression:ExpressionTypeCallback, coerce:ExpressionCoerceCallback) {
		this.session = session;
		this.typeExpression = typeExpression;
		this.coerce = coerce;
	}

	public function typeLiteral(expression:AstExpression, expectedType:Null<CompilerType>):TypedExpression
		return switch expression {
			case IntegerLiteral(value, span):
				var type = expectedType == TInt64 ? TInt64 : TInt;
				new TypedExpression(TIntLiteral(value), type, span);
			case FloatLiteral(value, span): new TypedExpression(TFloatLiteral(value), TFloat, span);
			case StringLiteral(value, span): new TypedExpression(TStringLiteral(value), TString, span);
			case BoolLiteral(value, span): new TypedExpression(TBoolLiteral(value), TBool, span);
			case NullLiteral(span): new TypedExpression(TNullLiteral, TNull, span);
			case Unreachable(span): new TypedExpression(TUnreachable, TNever, span);
			case ErrorExpression(span): new TypedExpression(TNullLiteral, TDynamic, span);
			default: throw "ExpressionTyper.typeLiteral requires a literal expression";
		};

	public function arithmetic(a:AstExpression, b:AstExpression, scope:Scope, add:Bool, span:SourceSpan, expected:Null<CompilerType>):TypedExpression {
		var left = typeExpression(a, scope, null, false),
			right = typeExpression(b, scope, null, false);
		if (expected != null && isNumeric(expected)) {
			if (left.type == TDynamic)
				left = coerce(left, expected, "arithmetic operand", "E1010");
			if (right.type == TDynamic)
				right = coerce(right, expected, "arithmetic operand", "E1010");
		}
		if (left.type == TNever && isNumeric(right.type))
			left = coerce(left, right.type, "arithmetic operand", "E1009");
		if (right.type == TNever && isNumeric(left.type))
			right = coerce(right, left.type, "arithmetic operand", "E1009");
		if (add && (isStringConvertible(left.type) || isStringConvertible(right.type))) {
			left = stringify(left);
			right = stringify(right);
			return new TypedExpression(TAdd(left, right), TString, span);
		}
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		return new TypedExpression(add ? TAdd(promoted.left, promoted.right) : TSub(promoted.left, promoted.right), promoted.type, span);
	}

	public function logical(a:AstExpression, b:AstExpression, scope:Scope, and:Bool, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope, null, false),
			rightScope = FlowAnalysis.narrowedScope(scope, left, and),
			right = typeExpression(b, rightScope, null, false);
		if (!sameType(left.type, TBool) || !sameType(right.type, TBool))
			fail("E1011", "Logical operators require Bool operands", span);
		return new TypedExpression(and ? TAnd(left, right) : TOr(left, right), TBool, span);
	}

	public function numeric(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope, null, false),
			right = typeExpression(b, scope, null, false);
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Arithmetic requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span, operation != 2);
		return new TypedExpression(operation == 2 ? TMul(promoted.left, promoted.right) : TDiv(promoted.left, promoted.right), promoted.type, span);
	}

	public function modulo(a:AstExpression, b:AstExpression, scope:Scope, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope, null, false),
			right = typeExpression(b, scope, null, false);
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1010", "Modulo requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		return sameType(promoted.type, TInt)
			|| sameType(promoted.type,
				TInt64) ? new TypedExpression(TMod(promoted.left, promoted.right), promoted.type,
				span) : new TypedExpression(TCall("__math_fmod", [promoted.left, promoted.right]), TFloat, span);
	}

	public function bitwise(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope, null, false),
			right = typeExpression(b, scope, null, false);
		if (operation >= 3) {
			if (!sameType(left.type, TInt) && !sameType(left.type, TInt64))
				fail("E1010", "Shift operators require an Int or Int64 value", span);
			if (!sameType(right.type, TInt))
				fail("E1010", "Shift counts must be Int values", span);
			var shift:TypedExpressionKind = switch operation {
				case 3: TShiftLeft(left, right);
				case 4: TShiftRight(left, right);
				default: TUnsignedShiftRight(left, right);
			};
			return new TypedExpression(shift, left.type, span);
		}

		if ((!sameType(left.type, TInt) && !sameType(left.type, TInt64)) || (!sameType(right.type, TInt) && !sameType(right.type, TInt64)))
			fail("E1010", "Bitwise operators require integer operands", span);
		var operandType = sameType(left.type, TInt64) || sameType(right.type, TInt64) ? TInt64 : TInt;
		left = coerce(left, operandType, "bitwise operand", "E1010");
		right = coerce(right, operandType, "bitwise operand", "E1010");
		var expression:TypedExpressionKind = switch operation {
			case 0: TBitAnd(left, right);
			case 1: TBitXor(left, right);
			case 2: TBitOr(left, right);
			default: throw "Unknown bitwise operation";
		};
		return new TypedExpression(expression, operandType, span);
	}

	public function comparison(a:AstExpression, b:AstExpression, scope:Scope, operation:Int, span:SourceSpan):TypedExpression {
		var left = typeExpression(a, scope, null, false),
			right = typeExpression(b, scope, left.type, false);
		if (operation == 2) {
			if (sameType(left.type, TNull) && isNullable(right.type))
				left = coerce(left, right.type, "null comparison", "E1009");
			else if (sameType(right.type, TNull) && isNullable(left.type))
				right = coerce(right, left.type, "null comparison", "E1009");
		}
		if (operation == 2 && sameType(left.type, TString) && sameType(right.type, TString))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && sameType(left.type, TBool) && sameType(right.type, TBool))
			return new TypedExpression(TEqual(left, right), TBool, span);
		if (operation == 2 && session.relations.isAssignable(left.type, right.type)) {
			left = coerce(left, right.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && session.relations.isAssignable(right.type, left.type)) {
			right = coerce(right, left.type, "equality comparison", "E1011");
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2
			&& ((sameType(left.type, TNull) && TypeRelations.isReference(right.type))
				|| (sameType(right.type, TNull) && TypeRelations.isReference(left.type)))) {
			if (sameType(left.type, TNull))
				left = new TypedExpression(TNullableWrap(left), right.type, left.span);
			else
				right = new TypedExpression(TNullableWrap(right), left.type, right.span);
			return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && (sameType(left.type, TNull) || sameType(right.type, TNull))) {
			var nullableComparison = switch left.type {
				case TNull:
					switch right.type {
						case TNullable(_): true;
						default: false;
					}
				case TNullable(_):
					switch right.type {
						case TNull, TNullable(_): true;
						default: false;
					}
				default: false;
			};
			if (nullableComparison)
				return new TypedExpression(TEqual(left, right), TBool, span);
		}
		if (operation == 2 && sameType(left.type, right.type))
			switch left.type {
				case TDynamic, TNativeAbstract(_), TAbstract(_, _, _), TInstance(Class, _, []), TInstance(Interface, _, []), TInstance(Enum, _, _),
					TNullable(_), TArray(_), TIterator(_), TMap(_, _), TFunction(_, _), TAnonymous(_, _):
					return new TypedExpression(TEqual(left, right), TBool, span);
				default:
			}
		if (!isNumeric(left.type) || !isNumeric(right.type))
			fail("E1011", "Comparison requires matching numeric operands", span);
		var promoted = promoteNumericOperands(left, right, span);
		left = promoted.left;
		right = promoted.right;
		return new TypedExpression(switch operation {
			case 0: TLess(left, right);
			case 1: TLessEqual(left, right);
			default: TEqual(left, right);
		}, TBool, span);
	}

	public function isNumeric(type:CompilerType):Bool
		return sameType(type, TInt) || sameType(type, TInt64) || sameType(type, TFloat);

	function promoteNumericOperands(left:TypedExpression, right:TypedExpression, span:SourceSpan, forceFloat:Bool = false):{
		left:TypedExpression,
		right:TypedExpression,
		type:CompilerType
	} {
		var hasInt64 = sameType(left.type, TInt64) || sameType(right.type, TInt64);
		var hasFloat = sameType(left.type, TFloat) || sameType(right.type, TFloat);
		if (hasInt64 && hasFloat)
			fail("E1010", "Int64 and Float arithmetic requires an explicit conversion", span);
		var type = hasInt64 ? TInt64 : forceFloat || hasFloat ? TFloat : TInt;
		return {left: coerce(left, type, "numeric operand", "E1010"), right: coerce(right, type, "numeric operand", "E1010"), type: type};
	}

	function isStringConvertible(type:CompilerType):Bool
		return switch type {
			case TString: true;
			case TAbstract(_, _, _): session.relations.isAssignable(type, TString);
			default: false;
		};

	function stringify(value:TypedExpression):TypedExpression {
		if (isStringConvertible(value.type))
			return coerce(value, TString, "string concatenation", "E1010");
		if (sameType(value.type, TFloat) || sameType(value.type, TDynamic)) {
			var functionName = session.currentContext.name,
				dependencies = session.runtimeDependencies.get(functionName);
			if (dependencies == null) {
				dependencies = [];
				session.runtimeDependencies.set(functionName, dependencies);
			}
			dependencies.set("Std", true);
			var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
			return new TypedExpression(TCall("Std.string", [dynamicValue]), TString, value.span);
		}
		var dynamicValue = coerce(value, TDynamic, "string concatenation", "E1010");
		return new TypedExpression(TCall("__std_string", [dynamicValue]), TString, value.span);
	}

	static function sameType(left:CompilerType, right:CompilerType):Bool
		return TypeRelations.equals(left, right);

	static function isNullable(type:CompilerType):Bool
		return switch type {
			case TNullable(_): true;
			default: false;
		};

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}

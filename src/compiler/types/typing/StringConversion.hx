package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

/**
 * The one rule for turning a typed value into a String. Concatenation (`"a" + value`), `Std.string(value)` and string
 * interpolation (which lowers to `Std.string`) all use it, so a value prints the same way through each:
 * - an enum abstract that names its values (`RawRepresentable`, `Flags`) prints its name, and a nullable one `null`;
 * - a String, or an abstract that converts to one, is itself;
 * - Float and Dynamic values go through `Std.string`, and everything else through the runtime's boxed conversion.
 */
class StringConversion {
	/** Whether a value of `type` is a String or converts to one implicitly. */
	public static function isStringConvertible(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TString: true;
			case TAbstract(_, _, _): session.relations.isAssignable(type, TString);
			default: false;
		};

	public static function convert(session:TypingSession, value:TypedExpression,
			bodyTyper:BodyTyping):TypedExpression {
		var named = name(session, value);
		if (named != null)
			return named;
		if (isStringConvertible(session, value.type))
			return bodyTyper.coerce(value, TString, "string conversion", "E1010");
		switch value.type {
			// A Null<String> is the same reference as a String; conversion itself writes null as "null".
			case TNullable(inner) if (TypeRelations.equals(inner, TString)):
				return new TypedExpression(TCast(value), TString, value.span);
			default:
		}
		var dynamicValue = bodyTyper.coerce(value, TDynamic, "string conversion", "E1010");
		if (TypeRelations.equals(value.type, TFloat) || TypeRelations.equals(value.type, TDynamic)) {
			session.runtimeDependencyTracker.record(session.currentContext.name, "Std");
			return new TypedExpression(TCall("Std.string", [dynamicValue]), TString, value.span);
		}
		return new TypedExpression(TCall("__std_string", [dynamicValue]), TString, value.span);
	}

	/** The name of a naming enum abstract value, or `null` for a nullable one that holds none; null for other types. */
	static function name(session:TypingSession, value:TypedExpression):Null<TypedExpression> {
		var span = value.span;
		switch value.type {
			case TNullable(inner = TAbstract(_, _, _)):
				var present = EnumAbstractValues.nameOf(session, new TypedExpression(TCast(value), inner, span), span);
				if (present == null)
					return null;
				var absent = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)),
					value.type, span),
					isAbsent = new TypedExpression(TEqual(value, absent), TBool, span);
				return new TypedExpression(TConditional(isAbsent,
					new TypedExpression(TStringLiteral("null"), TString, span), present), TString, span);
			case TNullable(_):
				return null;
			default:
				return EnumAbstractValues.nameOf(session, value, span);
		}
	}
}

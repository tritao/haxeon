package compiler.types.typing;

import compiler.core.DiagnosticCode;
import compiler.core.StdlibNames;
import compiler.syntax.Ast.TemporaryLocal;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.analysis.Scope;

/**
 * The one rule for turning a typed value into a String. Concatenation (`"a" + value`), `Std.string(value)` and string
 * interpolation (which lowers to `Std.string`) all use it, so a value prints the same way through each:
 * - an abstract with a `toString()` method, where its type is known (not through a type parameter), calls it, private or
 *   not, and a nullable one that holds null is `null`, as Haxe does;
 * - an enum abstract that names its values (a raw-value enum, `Flags`) prints its name, and a nullable one `null`;
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

	public static function convert(session:TypingSession, value:TypedExpression, bodyTyper:BodyTyping,
			scope:Scope):TypedExpression {
		// A type parameter's value converts as its representation does: the elaboration pass chooses how (`GenericElaboration`).
		if (TypeRepresentation.mentionsTypeParameter(value.type))
			return new TypedExpression(TParameterOperation(ToString, [value]), TString, value.span);
		var called = abstractToString(session, value, bodyTyper, scope);
		return called != null ? called : convertValue(session, value, bodyTyper);
	}

	/**
	 * `value.toString()` for a value of an abstract that declares an instance `toString` taking no arguments, or null. A
	 * nullable value is held once and tested for null first. Haxe makes this call only where the abstract is the static
	 * type, so a value converted through a type parameter prints its underlying value instead.
	 */
	static function abstractToString(session:TypingSession, value:TypedExpression, bodyTyper:BodyTyping,
			scope:Scope):Null<TypedExpression> {
		var span = value.span, nullable = false, abstractType = value.type;
		switch value.type {
			case TNullable(inner = TAbstract(_, _, _)):
				nullable = true;
				abstractType = inner;
			default:
		}
		var declaration = switch abstractType {
			case TAbstract(name, _, _): session.declarations.abstractDeclaration(name);
			default: null;
		};
		if (declaration == null || !Lambda.exists(declaration.methods, method -> method.name == "toString"
			&& !method.isStatic && method.arguments.length == 0))
			return null;
		var inner = new Scope(scope);
		function hold(name:String, held:TypedExpression):{
			statement:compiler.types.TypedAst.TypedStatement,
			local:TypedExpression,
			temporary:TemporaryLocal
		} {
			var temporary = new TemporaryLocal(name + span.start),
				binding = inner.define(temporary.name, held.type, span, true, null, false, null, null, temporary);
			bodyTyper.bindCell(binding, held.type);
			return {
				statement: TVar(binding.id, held, span),
				local: new TypedExpression(TLocal(binding.id), held.type, span),
				temporary: temporary
			};
		}
		var whole = hold("__haxeon_string_held", value),
			present = nullable ? hold("__haxeon_string_present", new TypedExpression(TCast(whole.local), abstractType,
				span)) : whole,
			call =
				bodyTyper.coerce(bodyTyper.typeExpression(AnnotatedExpression(PrivateAccess,
				MethodCall(TemporaryVariable(present.temporary,
				span), "toString", [], span), span), inner, TString), TString, "string conversion",
				DiagnosticCode.OPERATOR_OR_STRING_CONVERSION);
		if (!nullable)
			return new TypedExpression(TBlockExpression([whole.statement], call), TString, span);
		var absent = new TypedExpression(TNullableWrap(new TypedExpression(TNullLiteral, TNull, span)), value.type,
			span),
			isAbsent = new TypedExpression(TEqual(whole.local, absent), TBool, span);
		return new TypedExpression(TBlockExpression([whole.statement],
			new TypedExpression(TConditional(isAbsent, new TypedExpression(TStringLiteral("null"), TString, span),
			new TypedExpression(TBlockExpression([present.statement], call), TString, span)), TString, span)),
			TString, span);
	}

	/** `value`, whose type mentions no type parameter, as a String. */
	public static function convertValue(session:TypingSession, value:TypedExpression,
			bodyTyper:BodyTyping):TypedExpression {
		// A native map handle does not retain its source key and value types.
		switch value.type {
			case TMap(_, _) | TNullable(TMap(_, _)):
				var mapString = bodyTyper.stringifyMap(value);
				if (mapString != null)
					return mapString;
			default:
		}
		var named = name(session, value);
		if (named != null)
			return named;
		if (isStringConvertible(session, value.type))
			return bodyTyper.coerce(value, TString, "string conversion", DiagnosticCode.OPERATOR_OR_STRING_CONVERSION);
		switch value.type {
			// A Null<String> is the same reference as a String; conversion itself writes null as "null".
			case TNullable(inner) if (TypeRelations.equals(inner, TString)):
				return new TypedExpression(TCast(value), TString, value.span);
			default:
		}
		var dynamicValue = bodyTyper.coerce(value, TDynamic, "string conversion",
			DiagnosticCode.OPERATOR_OR_STRING_CONVERSION);
		if (TypeRelations.equals(value.type, TFloat) || TypeRelations.equals(value.type, TDynamic)) {
			session.runtimeDependencyTracker.record(session.currentContext.name, StdlibNames.STD);
			return new TypedExpression(TCall(StdlibNames.STD_STRING, [dynamicValue]), TString, value.span);
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

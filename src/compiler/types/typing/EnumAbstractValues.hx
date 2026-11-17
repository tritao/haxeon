package compiler.types.typing;

import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstEnumAbstract;
import compiler.syntax.Ast.AstEnumAbstractValue;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.analysis.Scope;

/** Constants keep their abstract identity; only declaration initializers read their raw storage. */
@:access(compiler.types.typing.BodyTyper)
class EnumAbstractValues {
	public static function switchable(session:TypingSession, type:CompilerType):Bool
		return switch type {
			case TAbstract(name, _, representation) if (session.enumAbstractDecls.exists(name)):
				switch representation {
					case TInt, TString: true;
					default: false;
				};
			default: false;
		};

	public static function raw(typer:BodyTyper, declaration:AstEnumAbstract,
			value:AstEnumAbstractValue):TypedExpression {
		var session = typer.session,
			key = declaration.name + "." + value.name,
			known = session.constants.enumAbstractConstants.get(key);
		if (known != null)
			return known;
		if (session.constants.enumAbstractConstantsInProgress.exists(key))
			BodyTyper.fail("E1002", 'Cyclic enum abstract constant "$key"', value.span);
		session.constants.enumAbstractConstantsInProgress.set(key, true);
		var previous = session.constants.enumAbstractConstantOwner;
		session.constants.enumAbstractConstantOwner = declaration.name;
		try {
			var storage = typer.lowerType(declaration.underlying, declaration.span);
			// The initializer is the abstract's own code, typed where a value is first used, which may be another class.
			var expression = MemberAccess.allowed(session,
				() -> typer.coerce(typer.typeExpression(value.value, new Scope(),
				storage), storage, 'enum abstract value "$key"', "E1002"));
			session.constants.enumAbstractConstantOwner = previous;
			session.constants.enumAbstractConstantsInProgress.remove(key);
			session.constants.enumAbstractConstants.set(key, expression);
			return expression;
		} catch (error:haxe.Exception) {
			session.constants.enumAbstractConstantOwner = previous;
			session.constants.enumAbstractConstantsInProgress.remove(key);
			throw error;
		}
	}

	/**
	 * The text of an enum abstract value that names its values (`RawRepresentable` or `Flags`), or null for any other value.
	 * String conversion uses it, so `"Role: " + role` and `Std.string(role)` print a name as an enum constructor does.
	 */
	public static function nameOf(session:TypingSession, value:TypedExpression, span:SourceSpan):Null<TypedExpression> {
		var owner = switch value.type {
			case TAbstract(name, _, _): name;
			default: null;
		};
		var declaration = owner == null ? null : session.enumAbstractDecls.get(owner);
		if (declaration == null)
			return null;
		if (FlagsGenerator.conforms(session, declaration))
			return new TypedExpression(TCall(FlagsGenerator.request(session, owner, "toString", span), [value]),
				TString, span);
		if (RawRepresentableGenerator.conforms(session, declaration))
			return new TypedExpression(TCall(RawRepresentableGenerator.request(session, owner, "toString", span),
				[value]), TString, span);
		return null;
	}

	/** The value at a use site: the cached constant, typed as the abstract and located at `span`, where it is used. */
	public static function typed(typer:BodyTyper, declaration:AstEnumAbstract, value:AstEnumAbstractValue,
			span:SourceSpan):TypedExpression {
		typer.recordInlineConstantDependency(declaration.name);
		var expression = raw(typer, declaration, value);
		return typer.session.constants.enumAbstractConstantOwner == declaration.name
			? new TypedExpression(expression.expression,
			expression.type,
			span) : new TypedExpression(TAbiCast(expression), TAbstract(declaration.name, [], expression.type), span);
	}
}

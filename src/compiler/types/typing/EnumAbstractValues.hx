package compiler.types.typing;

import compiler.syntax.Ast.AstEnumAbstract;
import compiler.types.analysis.Scope;
import compiler.syntax.Ast.AstEnumAbstractValue;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

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

	public static function raw(typer:BodyTyper, declaration:AstEnumAbstract, value:AstEnumAbstractValue):TypedExpression {
		var session = typer.session,
			key = declaration.name + "." + value.name,
			known = session.enumAbstractConstants.get(key);
		if (known != null)
			return known;
		if (session.enumAbstractConstantsInProgress.exists(key))
			BodyTyper.fail("E1002", 'Cyclic enum abstract constant "$key"', value.span);
		session.enumAbstractConstantsInProgress.set(key, true);
		var previous = session.enumAbstractConstantOwner;
		session.enumAbstractConstantOwner = declaration.name;
		try {
			var storage = typer.lowerType(declaration.underlying);
			var expression = typer.coerce(typer.typeExpression(value.value, new Scope(), storage), storage, 'enum abstract value "$key"', "E1002");
			session.enumAbstractConstantOwner = previous;
			session.enumAbstractConstantsInProgress.remove(key);
			session.enumAbstractConstants.set(key, expression);
			return expression;
		} catch (error:Dynamic) {
			session.enumAbstractConstantOwner = previous;
			session.enumAbstractConstantsInProgress.remove(key);
			throw error;
		}
	}

	public static function typed(typer:BodyTyper, declaration:AstEnumAbstract, value:AstEnumAbstractValue):TypedExpression {
		var expression = raw(typer, declaration, value);
		return typer.session.enumAbstractConstantOwner == declaration.name ? expression : new TypedExpression(TAbiCast(expression),
			TAbstract(declaration.name, [], expression.type), expression.span);
	}
}

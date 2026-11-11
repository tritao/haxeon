package compiler.types.typing;

import compiler.syntax.Ast.AstExpression;
import compiler.syntax.Ast.AstType;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;

/**
 * Enum abstracts lower to their underlying type, so where a bare value name such as `Red` is expected the
 * type alone cannot say which abstract is meant, and two abstracts over `Int` sharing the name compete. A
 * declared type still says it: a parameter, local, field or call result declared as `Colour` is the hint.
 * Wherever the declared type of the other side is known, the bare name is typed with that abstract as a hint.
 */
class EnumAbstractHints {
	/** The enum abstract a declared type names, or null. */
	public static function named(session:TypingSession, type:Null<AstType>):Null<String> {
		if (type == null)
			return null;
		return switch type {
			case NamedType(name), AppliedType(name, _): session.enumAbstractDecls.exists(name) ? name : null;
			default: null;
		};
	}

	/** The enum abstract `expression` was declared as, read from the declaration of the local, field or function behind it. */
	public static function declaredAs(session:TypingSession, expression:TypedExpression):Null<String> {
		return switch expression.expression {
			case TLocal(id), TCellLocal(id, _), TCaptured(id), TCellCaptured(id, _): session.currentContext.declaredAbstracts.get(id);
			case TField(object, name): fieldDeclaredAs(session, object.type, name);
			case TStaticField(owner, name): fieldOfClass(session, owner, name);
			case TCall(name, _), TMethodCall(_, name, _): functionResult(session, name);
			case TNullableWrap(value), TCast(value), TAbiCast(value): declaredAs(session, value);
			default: null;
		};
	}

	/** Types `value` with `abstractName` as the hint when it is a bare name; `run` does the typing. */
	public static function typed(session:TypingSession, abstractName:Null<String>, value:AstExpression, run:() -> TypedExpression):TypedExpression {
		var bare = abstractName != null && switch value {
			case Variable(name, _): name.indexOf(".") < 0;
			default: false;
		};
		if (!bare)
			return run();
		var previous = session.abstractHint;
		session.abstractHint = abstractName;
		try {
			var result = run();
			session.abstractHint = previous;
			return result;
		} catch (error:Dynamic) {
			session.abstractHint = previous;
			throw error;
		}
	}

	static function fieldDeclaredAs(session:TypingSession, receiver:CompilerType, name:String):Null<String> {
		return switch receiver {
			case TInstance(_, declaration, _): fieldOfClass(session, declaration, name);
			case TNullable(TInstance(_, declaration, _)): fieldOfClass(session, declaration, name);
			default: null;
		};
	}

	static function fieldOfClass(session:TypingSession, owner:String, name:String):Null<String> {
		var seen:Map<String, Bool> = [], current:Null<String> = owner;
		while (current != null && !seen.exists(current)) {
			seen.set(current, true);
			var declaration = session.classDecls.get(current);
			if (declaration == null)
				return null;
			for (field in declaration.fields)
				if (field.name == name)
					return named(session, field.type);
			current = switch declaration.base {
				case NamedType(base), AppliedType(base, _): base;
				default: null;
			};
		}
		return null;
	}

	static function functionResult(session:TypingSession, name:String):Null<String> {
		var signature = session.signatures.get(name);
		return signature == null ? null : named(session, signature.result);
	}
}

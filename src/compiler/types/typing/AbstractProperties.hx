package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstAbstract;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.types.Type.CompilerType;

/** A property of an abstract and the abstract that declares it. */
typedef AbstractProperty = {
	final declaration:AstAbstract;
	final field:AstField;
}

/**
 * An abstract's properties, `var length(get, never):Int`: an abstract stores nothing but its underlying value, so, as in Haxe, a
 * property is only its accessors. A read calls `get_length` and a write `set_length` on the abstract value; `never` forbids the
 * access. Only instance properties for now: a static variable of an abstract is not supported yet.
 */
class AbstractProperties {
	/** The instance property `name` of the abstract `type` is a value of, or null. */
	public static function find(session:TypingSession, type:CompilerType, name:String):Null<AbstractProperty> {
		switch type {
			case TAbstract(abstractName, _, _):
				var declaration = session.declarations.abstracts.get(abstractName);
				if (declaration != null)
					for (field in declaration.fields)
						if (field.name == name && !field.isStatic)
							return {declaration: declaration, field: field};
			default:
		}
		return null;
	}

	/** The property's type for a value of `type`, the abstract with its type arguments. */
	public static function typeOf(session:TypingSession, type:CompilerType, property:AbstractProperty):CompilerType {
		var arguments = switch type {
			case TAbstract(_, typeArguments, _): typeArguments;
			default: [];
		};
		return session.declarations.types.fieldType(property.declaration.name, property.field,
			session.representation.typeParameterSubstitutions(property.declaration.typeParameters, arguments));
	}

	/** The accessor a read (`get_x`) or write (`set_x`) of `property` calls, after checking that source may reach it. */
	public static function accessor(session:TypingSession, property:AbstractProperty, read:Bool,
			span:SourceSpan):String {
		MemberAccess.abstractProperty(session, property.declaration, property.field, span);
		var access = read ? property.field.readAccess : property.field.writeAccess;
		if (access != (read ? GetAccess : SetAccess))
			throw new CompileError(new Diagnostic("E1024",
				'This expression cannot be accessed for ${read ? "reading" : "writing"}', span));
		return (read ? "get_" : "set_") + property.field.name;
	}

	/** Haxe's checks of an abstract's variables (typeloadFields), in Haxe's words. */
	public static function validate(session:TypingSession, declaration:AstAbstract):Void {
		for (field in declaration.fields) {
			if (field.isStatic)
				fail("E1021", 'Static variable "${declaration.name}.${field.name}" of an abstract is not supported yet',
					field.span);
			if (field.readAccess == null)
				fail("E1002", "Cannot declare member variable in abstract", field.span);
			if (!isAccessor(field.readAccess, GetAccess) || !isAccessor(field.writeAccess, SetAccess))
				fail("E1002", "Member property accessors must be get/set or never", field.span);
			if (field.initializer != null)
				fail("E1002", "on field that is not a real variable", field.span);
			if (field.readAccess == GetAccess)
				requireAccessor(session, declaration, field, "get_" + field.name);
			if (field.writeAccess == SetAccess)
				requireAccessor(session, declaration, field, "set_" + field.name);
		}
	}

	static function isAccessor(access:Null<AstFieldAccess>, call:AstFieldAccess):Bool
		return access == call || access == NeverAccess;

	static function requireAccessor(session:TypingSession, declaration:AstAbstract, field:AstField, name:String):Void {
		for (method in declaration.methods)
			if (method.name == name && !method.isStatic)
				return;
		fail("E1002", 'Method $name required by property ${field.name} is missing', field.span);
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}

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
 * access. Only instance properties for now: a static property with an accessor is not supported yet (a static variable is
 * stored in the abstract's storage class, `AbstractStatics`).
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

	/**
	 * The accessor a read (`get_x`) or write (`set_x`) of `property` calls, after checking that source may reach it. Its errors are
	 * at the property's name, as Haxe reports them (`length` in `stack.length = 0`).
	 */
	public static function accessor(session:TypingSession, property:AbstractProperty, read:Bool,
			span:SourceSpan):String {
		span = nameSpan(span, property.field.name, read);
		MemberAccess.abstractProperty(session, property.declaration, property.field, span);
		var access = read ? property.field.readAccess : property.field.writeAccess;
		if (access != (read ? GetAccess : SetAccess))
			throw new CompileError(new Diagnostic("E1024",
				'This expression cannot be accessed for ${read ? "reading" : "writing"}', span));
		return (read ? "get_" : "set_") + property.field.name;
	}

	/**
	 * Where `name` is written in `span`, an access of it: the end of a read's expression (`stack.length`), or the name after the
	 * receiver in a write's statement (`stack.length = 0`); `span` itself for a bare name (`length` in the abstract's methods).
	 */
	static function nameSpan(span:SourceSpan, name:String, read:Bool):SourceSpan {
		var size = haxe.io.Bytes.ofString(name).length;
		if (read)
			return span.end - size >= span.start && span.file.slice(span.end - size, span.end) == name
				? new SourceSpan(span.file, span.end - size, span.end) : span;
		var text = span.file.slice(span.start, span.end), dot = text.indexOf("." + name);
		if (dot < 0)
			return span;
		var start = span.start + haxe.io.Bytes.ofString(text.substr(0, dot + 1)).length;
		return new SourceSpan(span.file, start, start + size);
	}

	/** Haxe's checks of an abstract's variables (typeloadFields), in Haxe's words. */
	public static function validate(session:TypingSession, declaration:AstAbstract):Void {
		for (field in declaration.fields) {
			// A static with storage is its storage class's (`AbstractStatics`); one left here has an accessor.
			if (field.isStatic)
				fail("E1021", 'Static property "${declaration.name}.${field.name}" of an abstract is not supported yet',
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

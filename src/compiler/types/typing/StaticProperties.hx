package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.AbstractStatics;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.types.Type.CompilerType;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.analysis.Scope;

/**
 * Static properties with accessors, `static var count(get, set):Int`, of a class or an abstract (whose statics its storage class
 * keeps, `AbstractStatics`). As in Haxe, a read calls the static `get_count` and a write `set_count`, wherever source names the
 * property (`Counter.count`, a bare `count` in its class, `count += 1`, `count++`); inside its own accessor the name is the
 * variable itself (Haxe's `@:isVar` storage). `default`, `null` and `never` sides are not accessors: `PropertyWriteRules` and the
 * stored variable handle them.
 */
class StaticProperties {
	/**
	 * The function a read (`get_x`) or write (`set_x`) of the static `name` of `owner` calls, or null when that side reads or
	 * writes the variable. An abstract's accessors are the abstract's static methods.
	 */
	public static function accessor(session:TypingSession, owner:String, name:String, read:Bool):Null<String> {
		var field = staticField(session, owner, name);
		if (field == null || (read ? field.readAccess : field.writeAccess) != (read ? GetAccess : SetAccess))
			return null;
		var accessor = (AbstractStatics.abstractOf(owner) ?? owner) + "." + (read ? "get_" : "set_") + name;
		return accessor == session.currentContext.functionName ? null : accessor;
	}

	/**
	 * Requires that the static `name` of `owner` may be read (`read`) or written: a `never` side may not, outside the property's
	 * own accessors, as in Haxe ("This expression cannot be accessed for writing", at the name).
	 */
	public static function requireAccess(session:TypingSession, owner:String, name:String, read:Bool,
			span:SourceSpan):Void {
		var field = staticField(session, owner, name);
		if (field == null || (read ? field.readAccess : field.writeAccess) != NeverAccess)
			return;
		var accessorOwner = (AbstractStatics.abstractOf(owner) ?? owner) + ".",
			functionName = session.currentContext.functionName;
		if (functionName == accessorOwner + "get_" + name || functionName == accessorOwner + "set_" + name)
			return;
		throw new CompileError(new Diagnostic("E1024",
			'This expression cannot be accessed for ${read ? "reading" : "writing"}',
			AbstractProperties.nameSpan(span, name, read)));
	}

	/** Haxe's check of a class's static properties (typeloadFields): each accessor they name is declared, as a static method. */
	public static function validate(session:TypingSession, declaration:AstClass):Void {
		var abstractName = AbstractStatics.abstractOf(declaration.name),
			abstractDeclaration = abstractName == null ? null : session.declarations.abstracts.get(abstractName),
			methods = abstractDeclaration != null ? abstractDeclaration.methods : declaration.methods;
		for (field in declaration.fields)
			if (field.isStatic)
				for (side in [
					{access: field.readAccess, call: GetAccess, prefix: "get_"},
					{access: field.writeAccess, call: SetAccess, prefix: "set_"}
				])
					if (side.access == side.call) {
						var name = side.prefix + field.name, declared = false;
						for (method in methods)
							if (method.name == name && method.isStatic)
								declared = true;
						if (!declared)
							throw new CompileError(new Diagnostic("E1002",
								'Method $name required by property ${field.name} is missing', field.span));
					}
	}

	static function staticField(session:TypingSession, owner:String, name:String):Null<AstField> {
		var declaration = session.classDecls.get(owner);
		if (declaration != null)
			for (field in declaration.fields)
				if (field.isStatic && field.name == name)
					return field;
		return null;
	}

	/** A read of the static `name` of `owner` that calls its getter, or null when it reads the variable. */
	public static function read(session:TypingSession, bodyTyper:BodyTyping, owner:String, name:String,
			type:CompilerType, span:SourceSpan, scope:Null<Scope>):Null<TypedExpression> {
		requireAccess(session, owner, name, true, span);
		var getter = accessor(session, owner, name, true);
		if (getter == null)
			return null;
		var method = session.signatures.get(getter);
		if (method == null)
			return null;
		if (scope != null)
			session.invalidateCallEffects(getter, scope);
		var call = new TypedExpression(TCall(getter, []), bodyTyper.functionResultType(method, method.span), span);
		return bodyTyper.coerce(call, type, 'property "$name"', "E1002");
	}

	/** A write of `value` (of the property's type) to the static `name` of `owner` that calls its setter, or null. */
	public static function write(session:TypingSession, bodyTyper:BodyTyping, owner:String, name:String,
			value:TypedExpression, span:SourceSpan, scope:Scope):Null<TypedExpression> {
		var setter = accessor(session, owner, name, false);
		if (setter == null)
			return null;
		var method = session.signatures.get(setter);
		if (method == null)
			return null;
		var argumentTypes = bodyTyper.argumentTypesOf(method);
		if (argumentTypes.length != 1)
			return null;
		session.invalidateCallEffects(setter, scope);
		scope.invalidateExpression('static:$owner.$name');
		return new TypedExpression(TCall(setter,
			[bodyTyper.coerce(value, argumentTypes[0], 'property "$name"', "E1002")]),
			bodyTyper.functionResultType(method, method.span), span);
	}
}

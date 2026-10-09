package compiler.types.typing;

import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;
import compiler.types.TypedAst.ValueCopyLayout;

/**
 * Value classes have value semantics: binding an instance to a new location (a variable, argument, return value or
 * field) gives that location its own copy. Without it, HashLink's inline slots and Wasm's heap objects alias
 * differently, and the same program means two things. This includes immutable instances: a packed field read can
 * point inside its parent, so sharing that address with a new location would not give the location owned storage.
 * Scalar replacement and copy elision remove copies when the uses prove that sharing is safe.
 */
class ValueCopy {
	/** `value` as bound to a location of `type`: wrapped in a copy unless it is fresh. */
	public static function bind(session:TypingSession, value:TypedExpression, type:CompilerType):TypedExpression {
		if (isFresh(value))
			return value;
		var layout = layoutOf(session, type, []);
		return layout == null ? value : new TypedExpression(TCopy(value, layout), value.type, value.span);
	}

	/** Results of these are new, unshared instances. */
	static function isFresh(value:TypedExpression):Bool
		return switch value.expression {
			case TNew(_, _, _), TCall(_, _), TCNativeCall(_, _), TMethodCall(_, _, _), TClosureCall(_, _), TSuperCall(_, _), TObjectLiteral(_, _, _),
				TArrayPop(_), TCopy(_, _): true;
			default: false;
		};

	static function layoutOf(session:TypingSession, type:CompilerType, visiting:Array<String>):Null<ValueCopyLayout> {
		var name = switch type {
			case TInstance(NominalKind.Class, className, _): className;
			default: return null;
		};
		var declaration = session.declarations.classes.get(name);
		if (declaration == null
			|| !hasMetadata(declaration, "value")
			|| hasMetadata(declaration, "repr")
			|| declaration.typeParameters.length > 0
			|| visiting.indexOf(name) >= 0)
			return null;
		var fields:Array<{name:String, type:CompilerType, nested:Null<ValueCopyLayout>}> = [];
		for (field in declaration.fields) {
			if (field.isStatic || !hasStorage(field))
				continue;
			var fieldType = session.declarations.resolve(session.declarations.resolvedFieldType(name, field), field.span);
			var nested = layoutOf(session, fieldType, visiting.concat([name]));
			fields.push({name: field.name, type: fieldType, nested: nested});
		}
		return {name: name, fields: fields};
	}

	static function hasMetadata(declaration:compiler.syntax.Ast.AstClass, name:String):Bool {
		for (entry in declaration.metadata)
			if (entry.name == name)
				return true;
		return false;
	}

	static function hasStorage(field:compiler.syntax.Ast.AstField):Bool {
		if (hasDirectAccess(field.readAccess) || hasDirectAccess(field.writeAccess))
			return true;
		for (entry in field.metadata)
			if (entry.name == "isVar")
				return true;
		return false;
	}

	static function hasDirectAccess(access:Null<compiler.syntax.Ast.AstFieldAccess>):Bool
		return switch access {
			case GetAccess, SetAccess, NeverAccess: false;
			default: true;
		};
}

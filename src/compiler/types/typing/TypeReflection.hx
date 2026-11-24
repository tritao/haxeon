package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstExpression;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;
import compiler.types.TypedAst.TypedExpression;

/**
 * The class and enum part of Haxe's `Type` API on a class or enum named where it is called (`Type.getClassName(Child)`), which
 * needs no runtime type information: the names and field lists are the declaration's, and `createInstance` and
 * `createEmptyInstance` construct the named class. The functions that take or give a class or enum held as a value
 * (`getClass`, `getSuperClass`, `getEnum`, `resolveClass`, `resolveEnum`, `typeof`) need classes and enums as runtime values
 * (`docs/design/TYPE_VALUES.md`), so they are a compile error, as a call with a class or enum held in a variable is.
 *
 * The field lists are HashLink's: a class's instance fields are its methods, then its variables, each in declaration order, then
 * its base's; an override is listed with the base that declares it, and a property without storage is not listed. A class's
 * fields are its statics in declaration order. Unlike HashLink, no runtime slot (an interface's cache) is listed.
 */
class TypeReflection {
	public static function handles(name:String):Bool
		return switch name {
			case "Type.getClassName", "Type.getEnumName", "Type.getEnumConstructs", "Type.getInstanceFields",
				"Type.getClassFields", "Type.createInstance", "Type.createEmptyInstance", "Type.getClass",
				"Type.getSuperClass", "Type.getEnum", "Type.resolveClass", "Type.resolveEnum", "Type.typeof": true;
			default: false;
		};

	/** The call of the `Type` function `name`; `typeExpression` types an expression it is written out as. */
	public static function type(session:TypingSession, name:String, arguments:Array<AstExpression>, span:SourceSpan,
			typeExpression:AstExpression->TypedExpression):TypedExpression {
		var expected = switch name {
			case "Type.createInstance": 2;
			default: 1;
		};
		if (arguments.length != expected)
			fail("E1008",
				'Function "$name" expects $expected argument${expected == 1 ? "" : "s"}, got ${arguments.length}',
				span);
		switch name {
			case "Type.getClassName":
				var className = namedClass(session, arguments[0], true);
				if (className == null)
					unsupported(name, "a class named where it is called", span);
				return typeExpression(StringLiteral(className, span));
			case "Type.getEnumName":
				return typeExpression(StringLiteral(namedEnum(session, name, arguments[0], span), span));
			case "Type.getEnumConstructs":
				var declaration = session.enumDecls.get(namedEnum(session, name, arguments[0], span));
				return typeExpression(ArrayLiteral([
					for (enumCase in declaration.cases)
						StringLiteral(enumCase.name, span)
				], span));
			case "Type.getInstanceFields", "Type.getClassFields":
				var className = namedClass(session, arguments[0], false);
				if (className == null)
					unsupported(name, "a class named where it is called", span);
				var fields = name == "Type.getClassFields"
					? classFields(session.classDecls.get(className)) : instanceFields(session,
					className);
				return typeExpression(CheckType(ArrayLiteral([for (field in fields) StringLiteral(field, span)], span),
					ArrayType(StringType), span));
			case "Type.createInstance":
				var className = namedClass(session, arguments[0], false);
				if (className == null)
					unsupported(name, "a class named where it is called", span);
				return switch arguments[1] {
					case ArrayLiteral(values, _): typeExpression(New(className, values, span));
					default:
						unsupported(name, "its arguments written as an array literal", span);
						null;
				};
			case "Type.createEmptyInstance":
				var className = namedClass(session, arguments[0], false);
				if (className == null)
					unsupported(name, "a class named where it is called", span);
				var declaration = session.classDecls.get(className);
				if (declaration.typeParameters.length > 0)
					fail("E1009", '$name of a generic class is not supported yet', span);
				// The object is made without running its constructor, so its variables hold their type's default, null for a
				// reference: a field is never-null only where every object of the class is constructed (`IrNonNullFields`).
				return new TypedExpression(TNew(className, [], false), TInstance(NominalKind.Class, className, []),
					span);
			default:
				fail("E1009",
					'$name needs classes and enums as runtime values (Class<T>, Enum<T>), which Haxeon does not have yet',
					span);
				return null;
		}
	}

	/** The class `value` names, a declared class, or with `interfaces` an interface or `String` too; null for anything else. */
	static function namedClass(session:TypingSession, value:AstExpression, interfaces:Bool):Null<String>
		return switch value {
			case Variable(name, _) if (session.classDecls.exists(name)): name;
			case Variable(name, _) if (interfaces && (session.interfaceDecls.exists(name) || name == "String")): name;
			default: null;
		};

	static function namedEnum(session:TypingSession, name:String, value:AstExpression, span:SourceSpan):String
		return switch value {
			case Variable(enumName, _) if (session.enumDecls.exists(enumName)): enumName;
			default:
				unsupported(name, "an enum named where it is called", span);
				"";
		};

	static function instanceFields(session:TypingSession, className:String):Array<String> {
		var fields:Array<String> = [], current:Null<String> = className;
		while (current != null) {
			var declaration = session.classDecls.get(current);
			for (method in declaration.methods)
				if (!method.isStatic && method.name != "new" && method.isOverride != true)
					fields.push(method.name);
			for (field in declaration.fields)
				if (!field.isStatic && compiler.types.StructProperties.hasStorage(field))
					fields.push(field.name);
			current = declaration.base == null ? null : BodyTyper.inheritanceName(declaration.base);
		}
		return fields;
	}

	static function classFields(declaration:AstClass):Array<String> {
		var members:Array<{name:String, start:Int}> = [];
		for (method in declaration.methods)
			if (method.isStatic)
				members.push({name: method.name, start: method.span.start});
		for (field in declaration.fields)
			if (field.isStatic && (field.isInline || compiler.types.StructProperties.hasStorage(field)))
				members.push({name: field.name, start: field.span.start});
		members.sort((left, right) -> left.start - right.start);
		return [for (member in members) member.name];
	}

	static function unsupported(name:String, what:String, span:SourceSpan):Void
		fail("E1009",
			'$name needs $what; a class or enum held as a value needs classes and enums as runtime values, which Haxeon does not have yet',
			span);

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}

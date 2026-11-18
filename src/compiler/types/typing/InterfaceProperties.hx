package compiler.types.typing;

import compiler.core.Diagnostic;
import compiler.core.Diagnostic.CompileError;
import compiler.core.Source.SourceSpan;
import compiler.semantic.InterfaceFieldAccessors;
import compiler.syntax.Ast.AstClass;
import compiler.syntax.Ast.AstField;
import compiler.syntax.Ast.AstFieldAccess;
import compiler.syntax.Ast.AstInterface;
import compiler.types.Type.CompilerType;
import compiler.types.Type.NominalKind;

/** A variable or property of an interface and the interface that declares it. */
typedef InterfaceProperty = {
	final declaration:AstInterface;
	final field:AstField;
}

/**
 * An interface's variables and properties, `var x:Int`, `var area(get, never):Int`, as Haxe types them (typeloadCheck's
 * `check_interface`, `unify_kind`):
 *
 * - an implementing class has each, public, as a variable (or property) whose access unifies with the interface's: each side is
 *   the same, or the interface's is `null` or `never`; and of the same type. A `get` or `set` side's accessor is a field of the
 *   interface too, which the class has ("Field get_x needed by I is missing"), whatever its visibility;
 * - a read or write through the interface calls the interface method of that side (`InterfaceFieldAccessors`), so it reaches the
 *   object's accessor or variable; a `never` side, and a `null` one, cannot be accessed through it.
 */
class InterfaceProperties {
	/** The variable or property `name` of the interface `type` is a value of, its own or a base interface's, or null. */
	public static function find(session:TypingSession, type:CompilerType, name:String):Null<InterfaceProperty>
		return switch type {
			case TInstance(NominalKind.Interface, interfaceName, _): findIn(session, interfaceName, name, []);
			default: null;
		};

	static function findIn(session:TypingSession, interfaceName:String, name:String,
			visited:Array<String>):Null<InterfaceProperty> {
		var declaration = session.interfaceDecls.get(interfaceName);
		if (declaration == null || visited.indexOf(interfaceName) >= 0)
			return null;
		visited.push(interfaceName);
		for (field in declaration.fields)
			if (field.name == name && !field.isStatic)
				return {declaration: declaration, field: field};
		for (base in declaration.bases) {
			var found = findIn(session, BodyTyper.inheritanceName(base), name, visited);
			if (found != null)
				return found;
		}
		return null;
	}

	/** The property's type for a value of `type`, an interface that declares it or extends one that does. */
	public static function typeOf(session:TypingSession, type:CompilerType, property:InterfaceProperty):CompilerType {
		var projected = session.declarations.inheritance.project(type, property.declaration.name);
		return session.declarations.types.fieldType(property.declaration.name, property.field,
			session.representation.nominalSubstitutions(projected == null ? type : projected));
	}

	/**
	 * The method (`I.get_x`, `I.$set_x`) a read (`read`) or write of `property` calls, after checking that source may reach it,
	 * with Haxe's errors at the property's name.
	 */
	public static function accessor(session:TypingSession, property:InterfaceProperty, read:Bool,
			span:SourceSpan):String {
		span = AbstractProperties.nameSpan(span, property.field.name, read);
		MemberAccess.interfaceProperty(session, property.declaration, property.field, span);
		var name = InterfaceFieldAccessors.accessorName(property.field, read);
		if (name == null)
			throw new CompileError(new Diagnostic("E1024",
				'This expression cannot be accessed for ${read ? "reading" : "writing"}', span));
		return property.declaration.name + "." + name;
	}

	/** Haxe's checks of an interface's variables (typeloadFields), in Haxe's words. */
	public static function validate(declaration:AstInterface):Void
		for (field in declaration.fields) {
			if (field.isStatic)
				fail("E1002", "You can only declare static fields in extern interfaces",
					field.declarationSpan ?? field.span);
			var initializer = field.initializer;
			if (initializer != null)
				fail("E1002", "Initialization on field of interface",
					compiler.syntax.Parser.expressionSpan(initializer));
			if (field.type == null)
				fail("E1002", "Variable requires type-hint or initialization", field.span);
		}

	/**
	 * Haxe's check that `classDecl` has the variables and properties of `interfaceDecl` (`check_interface`): first that each is
	 * there, with the accessors its `get` and `set` sides make fields of the interface, then that each matches.
	 * `interfaceSubstitutions` are the interface's type arguments as `classDecl` implements it.
	 */
	public static function validateImplementation(session:TypingSession, bodyTyper:BodyTyper, classDecl:AstClass,
			interfaceDecl:AstInterface, interfaceSubstitutions:Map<String, CompilerType>):Void {
		var interfaceName = interfaceDecl.name;
		for (field in interfaceDecl.fields) {
			if (field.isStatic)
				continue;
			for (read in [true, false])
				switch InterfaceFieldAccessors.sideOf(field, read) {
					case GetAccess, SetAccess, DynamicAccess:
						var name = (read ? "get_" : "set_") + field.name,
							method = MemberAccess.methodInfo(session, classDecl.name, name);
						if (method == null || method.isStatic)
							fail("E1007", 'Field $name needed by $interfaceName is missing', classNameSpan(classDecl));
					default:
				}
			if (MemberAccess.classField(session, classDecl.name, field.name, false) == null
				&& !hasInstanceMethod(session, classDecl, field.name))
				fail("E1007", 'Field ${field.name} needed by $interfaceName is missing', classNameSpan(classDecl));
		}
		for (field in interfaceDecl.fields) {
			if (field.isStatic)
				continue;
			var found = MemberAccess.classField(session, classDecl.name, field.name, false);
			if (found == null) {
				var method = MemberAccess.methodInfo(session, classDecl.name, field.name),
					declared = method == null ? null : session.signatures.get(method.owner + "." + field.name);
				fail("E1007",
					'Field ${field.name} has different property access than in $interfaceName (method should be ${kindOf(field)})',
					declared == null ? classNameSpan(classDecl) : nameSpan(declared.span, field.name));
				return;
			}
			var at = nameSpan(found.field.span, field.name);
			if (!isPublic(found.field))
				fail("E1007", 'Field ${field.name} should be public as requested by $interfaceName', at);
			if (!unifiesKind(found.field, field))
				fail("E1007",
					'Field ${field.name} has different property access than in $interfaceName (${kindOf(found.field)} should be ${kindOf(field)})',
					at);
			var classType = TInstance(NominalKind.Class, classDecl.name, [
				for (parameter in classDecl.typeParameters)
					TTypeParameter(classDecl.name, parameter)
			]),
				actual = bodyTyper.findFieldType(classType, field.name),
				expected = session.declarations.types.fieldType(interfaceDecl.name, field, interfaceSubstitutions);
			if (actual == null || !TypeRelations.equals(actual, expected))
				fail("E1003", 'Field ${field.name} has different type than in $interfaceName', at);
		}
	}

	/** Whether the class declares or inherits an instance method `name`: an interface variable it would be in Haxe's words. */
	static function hasInstanceMethod(session:TypingSession, classDecl:AstClass, name:String):Bool {
		var method = MemberAccess.methodInfo(session, classDecl.name, name);
		return method != null && !method.isStatic;
	}

	/**
	 * A class's field is public as written, or, with no modifier, in an extern class or one with `@:publicFields` (`MemberAccess`
	 * has the rule; a class's field without one is private).
	 */
	static function isPublic(field:AstField):Bool
		return field.isPublic == true;

	/** Haxe's `unify_kind` of two variables: each side of the class's unifies with the interface's (`unify_access`). */
	static function unifiesKind(actual:AstField, expected:AstField):Bool {
		for (read in [true, false]) {
			var have = access(actual, read), want = access(expected, read);
			if (have != want && want != "null" && want != "never")
				return false;
		}
		return true;
	}

	/** A side's access in Haxe's words (`s_access`): `default`, `null`, `never`, `get` or `set`, and `ctor` for a final's write. */
	static function access(field:AstField, read:Bool):String {
		var written = read ? field.readAccess : field.writeAccess;
		if (written == null)
			return !read && field.isFinal ? "ctor" : "default";
		return switch written {
			case DefaultAccess: "default";
			case NullAccess: "null";
			case NeverAccess: "never";
			case GetAccess, SetAccess, DynamicAccess: read ? "get" : "set";
		};
	}

	/** A variable's kind in Haxe's words (`s_kind`): `var`, else its two sides, `(get,never)`. */
	static function kindOf(field:AstField):String {
		var read = access(field, true), write = access(field, false);
		return read == "default" && write == "default" ? "var" : '($read,$write)';
	}

	/** The span of `name` in a declaration's `span`, after its `var` or `final`: where Haxe reports a field (`cf_name_pos`). */
	static function nameSpan(span:SourceSpan, name:String):SourceSpan {
		var text = span.file.slice(span.start, span.end);
		for (keyword in ["var ", "final ", "function "]) {
			var at = text.indexOf(keyword);
			if (at < 0)
				continue;
			var found = text.indexOf(name, at + keyword.length);
			if (found < 0)
				continue;
			var start = span.start + haxe.io.Bytes.ofString(text.substr(0, found)).length;
			return new SourceSpan(span.file, start, start + haxe.io.Bytes.ofString(name).length);
		}
		return span;
	}

	/** Where Haxe reports a method: its name. */
	public static function methodNameSpan(method:compiler.syntax.Ast.AstFunction):SourceSpan
		return nameSpan(method.span, method.name);

	/** Where Haxe reports a field a class lacks: the class's name, after its `class` keyword. */
	static function classNameSpan(classDecl:AstClass):SourceSpan {
		var span = classDecl.span,
			text = span.file.slice(span.start, span.end),
			simple = classDecl.name.substr(classDecl.name.lastIndexOf(".") + 1),
			at = text.indexOf(" ");
		while (at >= 0 && at < text.length && StringTools.isSpace(text, at))
			at++;
		if (at < 0 || text.substr(at, simple.length) != simple)
			return span;
		var start = span.start + haxe.io.Bytes.ofString(text.substr(0, at)).length;
		return new SourceSpan(span.file, start, start + haxe.io.Bytes.ofString(simple).length);
	}

	static function fail(code:String, message:String, span:SourceSpan):Void
		throw new CompileError(new Diagnostic(code, message, span));
}
